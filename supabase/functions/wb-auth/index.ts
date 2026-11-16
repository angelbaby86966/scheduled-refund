/**
 * wb-auth —— 工作台服务端鉴权网关
 *
 * 解决的问题（2026-11-16 加固）：
 *   1. app_users.password 明文存表 + anon 可读全表 → 任何人都能拖库拿全部账号密码；
 *   2. user_data 全表 anon 可读（含每个账号的 AK/SK）→ 改一下 ?su= 就能拉别人的凭证；
 *   3. 裸 su 参数无签名 → 手改网址即可冒用他人身份。
 *
 * 设计：
 *   - 前端不再持有能读全表的凭据，所有敏感读写都经本函数中转；
 *   - 身份凭证是服务端签发的 HMAC 短时票据，绑定 username，无法篡改；
 *   - service_role 只存在于服务端环境变量（平台自动注入），前端永远拿不到；
 *   - 表结构不变、三套定时退订执行器读表路径不变（仅凭据来源改为服务端强凭据）。
 *
 * 票据格式： base64url(payload_json) + "." + base64url(HMAC-SHA256(payload, WB_AUTH_SECRET))
 *   payload = { u: username, r: role, e: exp_epoch_ms, n: nonce, s: scope }
 *   scope: "session"（工作台登录态，默认 12h）/ "tool"（批量命令工具页，10min）
 */

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, x-wb-auth",
  "Access-Control-Max-Age": "86400",
};

const SB_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
const SERVICE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  (() => {
    try {
      return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").default ?? "";
    } catch {
      return "";
    }
  })();
const AUTH_SECRET = Deno.env.get("WB_AUTH_SECRET") ?? "";

const SESSION_TTL_MS = 12 * 60 * 60 * 1000; // 12 小时
const TOOL_TTL_MS = 10 * 60 * 1000; // 10 分钟
const ADMIN_USER = "zhangruiyao";

// ===================== 工具 =====================
function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlDecode(s: string): Uint8Array {
  const t = s.replace(/-/g, "+").replace(/_/g, "/");
  const pad = t.length % 4 ? "=".repeat(4 - (t.length % 4)) : "";
  const raw = atob(t + pad);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}
async function hmac(payload: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(AUTH_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(payload));
  return b64url(new Uint8Array(sig));
}
function randomId(): string {
  const a = new Uint8Array(16);
  crypto.getRandomValues(a);
  return Array.from(a).map((x) => x.toString(16).padStart(2, "0")).join("");
}

async function signTicket(username: string, role: string, scope: string, ttlMs: number) {
  const payload = {
    u: username,
    r: role,
    e: Date.now() + ttlMs,
    n: randomId(),
    s: scope,
  };
  const body = b64url(new TextEncoder().encode(JSON.stringify(payload)));
  const sig = await hmac(body);
  return { ticket: `${body}.${sig}`, expiresAt: payload.e, scope };
}

async function verifyTicket(ticket: string, wantScope?: string) {
  if (!ticket || !AUTH_SECRET) return null;
  const parts = ticket.split(".");
  if (parts.length !== 2) return null;
  const [body, sig] = parts;
  const expect = await hmac(body);
  // 定长比较，避免时序侧信道
  if (sig.length !== expect.length) return null;
  let diff = 0;
  for (let i = 0; i < sig.length; i++) diff |= sig.charCodeAt(i) ^ expect.charCodeAt(i);
  if (diff !== 0) return null;
  let payload: any;
  try {
    payload = JSON.parse(new TextDecoder().decode(b64urlDecode(body)));
  } catch {
    return null;
  }
  if (!payload || typeof payload.u !== "string" || !payload.u) return null;
  if (typeof payload.e !== "number" || Date.now() > payload.e) return null;
  if (wantScope && payload.s !== wantScope) return null;
  return payload;
}

// ===================== Supabase REST =====================
async function rest(method: string, path: string, body?: unknown, extra?: Record<string, string>) {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    apikey: SERVICE_KEY,
  };
  // secret key（sb_secret_）不是 JWT，不能放进 Authorization Bearer；legacy service_role JWT 可以
  if (!SERVICE_KEY.startsWith("sb_secret_")) headers["Authorization"] = "Bearer " + SERVICE_KEY;
  if (extra) Object.assign(headers, extra);
  const resp = await fetch(`${SB_URL}/rest/v1/${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const txt = await resp.text();
  if (!resp.ok) {
    throw new Error(`Supabase ${resp.status}: ${txt.substring(0, 200)}`);
  }
  if (!txt.trim()) return null;
  try {
    return JSON.parse(txt);
  } catch {
    return txt;
  }
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// ===================== 业务 =====================
async function loadUser(username: string) {
  const rows = await rest(
    "GET",
    `app_users?username=eq.${encodeURIComponent(username)}&select=username,password,role,created_by,created_at`,
  );
  return Array.isArray(rows) && rows.length ? rows[0] : null;
}

function roleOf(row: any, username: string): string {
  if (username === ADMIN_USER) return "admin";
  return row?.role === "admin" ? "admin" : "user";
}

/** 校验目标账号归属：普通用户只能碰自己；管理员可跨账号 */
function canAccess(payload: any, target: string): boolean {
  if (!target) return false;
  if (payload.r === "admin") return true;
  return payload.u === target;
}

async function handle(p: any) {
  const action = String(p?.action ?? "");

  // ---------- 登录：用账号密码换票据 ----------
  if (action === "login") {
    const username = String(p?.username ?? "").trim();
    const password = String(p?.password ?? "");
    if (!username || !password) return json({ ok: false, error: "请填写账号和密码" }, 400);
    if (!/^[A-Za-z0-9_]{1,32}$/.test(username)) {
      return json({ ok: false, error: "账号不存在或密码错误" }, 401);
    }
    const row = await loadUser(username);
    // 统一错误文案：不区分「账号不存在」与「密码错误」，避免账号枚举
    if (!row || String(row.password ?? "") !== password) {
      return json({ ok: false, error: "账号不存在或密码错误" }, 401);
    }
    const role = roleOf(row, username);
    const t = await signTicket(username, role, "session", SESSION_TTL_MS);
    return json({ ok: true, username, role, ticket: t.ticket, expiresAt: t.expiresAt });
  }

  // ---------- 健康探针（无需票据）：给未登录的诊断页用 ----------
  if (action === "ping") {
    return json({ ok: true, service: "wb-auth", serverTime: Date.now() });
  }

  // ---------- 其余动作一律需要票据 ----------
  const ticket = String(p?.ticket ?? "").trim();
  const scope = action === "tool_ticket" || action === "tool_user_data" ? "tool" : "session";
  const payload = await verifyTicket(ticket, scope);
  if (!payload) {
    return json({ ok: false, error: "登录已失效，请重新登录" }, 401);
  }

  // ---------- 换工具页票据（工作台 → 批量命令页） ----------
  if (action === "tool_ticket") {
    const t = await signTicket(payload.u, payload.r, "tool", TOOL_TTL_MS);
    return json({ ok: true, username: payload.u, role: payload.r, ticket: t.ticket, expiresAt: t.expiresAt });
  }

  // ---------- 会话自检 ----------
  if (action === "session") {
    return json({ ok: true, username: payload.u, role: payload.r, expiresAt: payload.e });
  }

  // ---------- 读自己（或管理员指定账号）的用户数据 ----------
  if (action === "get_user_data" || action === "tool_user_data") {
    const target = String(p?.username ?? payload.u).trim();
    if (!canAccess(payload, target)) {
      return json({ ok: false, error: "无权访问其他账号的数据" }, 403);
    }
    const rows = await rest(
      "GET",
      `user_data?username=eq.${encodeURIComponent(target)}&select=username,data,updated_at`,
    );
    const row = Array.isArray(rows) && rows.length ? rows[0] : null;
    return json({
      ok: true,
      username: target,
      data: row?.data ?? {},
      updated_at: row?.updated_at ?? null,
    });
  }

  // ---------- 写用户数据（只允许写自己；管理员可写他人） ----------
  if (action === "set_user_data" || action === "tool_set_user_data") {
    const target = String(p?.username ?? payload.u).trim();
    if (!canAccess(payload, target)) {
      return json({ ok: false, error: "无权修改其他账号的数据" }, 403);
    }
    const data = p?.data;
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      return json({ ok: false, error: "数据格式不正确" }, 400);
    }
    const body = { username: target, data, updated_at: Date.now() };
    const upd = await rest(
      "PATCH",
      `user_data?username=eq.${encodeURIComponent(target)}`,
      body,
      { Prefer: "return=representation" },
    );
    if (Array.isArray(upd) && upd.length) return json({ ok: true, username: target });
    await rest("POST", "user_data", body, { Prefer: "return=representation" });
    return json({ ok: true, username: target });
  }

  // ---------- 用户列表（仅管理员） ----------
  if (action === "list_users") {
    if (payload.r !== "admin") return json({ ok: false, error: "仅管理员可查看用户列表" }, 403);
    const rows = await rest(
      "GET",
      "app_users?select=username,role,created_by,created_at&order=username.asc",
    );
    const users: Record<string, any> = {};
    let admin = ADMIN_USER;
    for (const r of rows ?? []) {
      if (r.role === "admin") admin = r.username;
      else {
        // ⚠️ 2026-11-16：不再下发 password —— 前端（含「导出用户库」）已不需要明文口令，
        //    更不该把全账号口令缓存进 localStorage（那等于把整张口令表留在浏览器里）。
        users[r.username] = {
          createdBy: r.created_by,
          createdAt: r.created_at,
        };
      }
    }
    return json({ ok: true, admin, users };
  }

  // ---------- 新增用户（仅管理员） ----------
  if (action === "add_user") {
    if (payload.r !== "admin") return json({ ok: false, error: "仅管理员可新增用户" }, 403);
    const username = String(p?.username ?? "").trim();
    const password = String(p?.password ?? "");
    if (!/^[A-Za-z0-9_]{1,32}$/.test(username) || password.length < 1) {
      return json({ ok: false, error: "用户名或密码不合法" }, 400);
    }
    if (await loadUser(username)) return json({ ok: false, error: "账号已存在" }, 409);
    await rest("POST", "app_users", {
      username,
      password,
      role: "user",
      created_by: payload.u,
      created_at: Date.now(),
    });
    return json({ ok: true, username });
  }

  // ---------- 删除用户（仅管理员） ----------
  if (action === "delete_user") {
    if (payload.r !== "admin") return json({ ok: false, error: "仅管理员可删除用户" }, 403);
    const username = String(p?.username ?? "").trim();
    if (!username) return json({ ok: false, error: "缺少账号" }, 400);
    if (username === payload.u) return json({ ok: false, error: "不能删除当前登录账号" }, 400);
    const del = await rest(
      "DELETE",
      `app_users?username=eq.${encodeURIComponent(username)}`,
      undefined,
      { Prefer: "return=representation" },
    );
    if (Array.isArray(del) && del.length) return json({ ok: true, username });
    // 0 行 = 被 RLS/权限拦下或本来就不存在
    const still = await loadUser(username);
    if (still) return json({ ok: false, error: "云端删除失败（权限拦截）" }, 403);
    return json({ ok: true, username });
  }

  // ---------- 修改密码（本人或管理员） ----------
  if (action === "set_password") {
    const target = String(p?.username ?? payload.u).trim();
    if (!canAccess(payload, target)) {
      return json({ ok: false, error: "无权修改其他账号的密码" }, 403);
    }
    const password = String(p?.password ?? "");
    if (!password) return json({ ok: false, error: "密码不能为空" }, 400);
    const upd = await rest(
      "PATCH",
      `app_users?username=eq.${encodeURIComponent(target)}`,
      { password },
      { Prefer: "return=representation" },
    );
    if (Array.isArray(upd) && upd.length) return json({ ok: true, username: target });
    return json({ ok: false, error: "密码修改失败" }, 403);
  }

  return json({ ok: false, error: "未知操作：" + action }, 400);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "只支持 POST" }, 405);
  if (!SB_URL || !SERVICE_KEY) {
    return json({ ok: false, error: "服务端未配置 Supabase 凭据" }, 500);
  }
  if (!AUTH_SECRET) {
    return json({ ok: false, error: "服务端未配置 WB_AUTH_SECRET" }, 500);
  }
  let p: any = {};
  try {
    p = await req.json();
  } catch {
    return json({ ok: false, error: "请求格式错误" }, 400);
  }
  try {
    return await handle(p);
  } catch (e: any) {
    console.error("[wb-auth] error:", e?.message ?? e);
    return json({ ok: false, error: "服务端处理失败：" + String(e?.message ?? e).substring(0, 160) }, 500);
  }
});

// 阿里云 SWAS API 代理 + 定时退订（零依赖版，避免 esm.sh BOOT_ERROR）

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
// ⚠️ 2026-11-16 加固：改用**服务端强凭据**（service_role）。
// 平台（Supabase Edge）会自动注入 SUPABASE_SERVICE_ROLE_KEY；
// 前端改走 wb-auth 服务端网关后，anon 对 user_data 的访问会被收紧，
// 云端退订执行器必须用 service_role（具 BYPASSRLS）才能继续读表。
const SUPABASE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";

/** 统一的 Supabase 请求头。sb_secret_ 不是 JWT，不能放进 Authorization: Bearer。 */
function sbHeaders(extra?: Record<string, string>): Record<string, string> {
  const h: Record<string, string> = { apikey: SUPABASE_KEY };
  if (SUPABASE_KEY && !SUPABASE_KEY.startsWith("sb_secret_")) {
    h["Authorization"] = `Bearer ${SUPABASE_KEY}`;
  }
  return extra ? { ...h, ...extra } : h;
}

// 阿里云 SWAS-OPEN 所有 API（包括 CreateOrder）都用地域 endpoint（swas.${regionId}.aliyuncs.com）
// 没有 swas-open.aliyuncs.com 这个中心 endpoint（NXDOMAIN）
function regionEndpoint(r: string) { return `https://swas.${r}.aliyuncs.com/`; }

// 阿里云 BSS（计费）中心 endpoint —— 用于真正的退订（RefundInstance），能退款到原账户
// 走 ProductCode 区分产品，SWAS 试 "swas"；不在地域里，是全局 endpoint
const BSS_ENDPOINT = "https://business.aliyuncs.com/";
const BSS_VERSION = "2017-12-14";
const SWAS_PRODUCT_CODE = "swas";   // SWAS（轻量应用服务器）的 product code
// 如果上面错了就改回来。备选："swas-open"、"simpleappserver"

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

// ====== 黄金机 硬保护（网页退订路径）======
// ⚠️ 现役 2 台黄金机（cn-shanghai），任何情况下都不得退订 / 释放 / 重置：
//    ① 1341164c82ed49a6ae0ab8c89b7eed37（公网 IP 47.116.51.223）
//    ② f05cf2489e41413382dfc944773386b8（公网 IP 47.101.145.6）
// 曾经的黄金机（杭州 9f2adaf7…）账号已注销，按用户要求「 former 不管」，不纳入保护。
// 双保险：实例 ID + 公网 IP。与 scheduled_refund.py / index.js(FC) 保持同源常量。
const GOLDEN_INSTANCE_IDS = new Set([
  "1341164c82ed49a6ae0ab8c89b7eed37",
  "f05cf2489e41413382dfc944773386b8",
]);
const GOLDEN_PUBLIC_IPS = new Set([
  "47.116.51.223",
  "47.101.145.6",
]);

// ====== 排除实例统一保护（2026-11-09 事故根治 / 2026-11-16 按账号隔离）======
// 单一事实来源：Supabase user_data.data.schedule_exclude_instance_ids。
// 任何调用 BSS RefundInstance 的路径都必须过 assertNotExcluded()；
// 名单读取失败一律抛错 → 一台都不退（fail-closed）。
//
// ⚠️ 2026-11-16 改造（修「几个账号的定时退订互相干扰」）：
//   旧实现把所有用户的排除 ID **全局合并**成一张名单，且任一账号字段异常
//   就让**所有**账号一起 fail-closed —— 一个账号配置脏/缺失会拖垮其他账号。
//   新实现按账号隔离：
//     · 每个账号用自己的排除名单；
//     · 某账号没配排除清单 → 视作「该账号未配置」，**不牵连其他账号**；
//     · 某账号排除字段类型脏 → **只**该账号 fail-closed；
//     · 整表读取失败 → 全局 fail-closed（名单读不到，谁都不退）。
let EXCLUDE_BY_USER: Map<string, Set<string>> = new Map();
let EXCLUDE_DIRTY_USERS: Set<string> = new Set();
let AK_OWNER: Map<string, string> = new Map();   // ak_id → username（零成本归属解析）
let EXCLUDE_CACHE_AT = 0;
let EXCLUDE_PENDING: Promise<Map<string, Set<string>>> | null = null;
const EXCLUDE_TTL_MS = 30_000;

function normalizeExclude(raw: any): string[] {
  if (Array.isArray(raw)) return raw.filter(x => typeof x === "string" && x.trim()).map((x: string) => x.trim());
  if (typeof raw === "string") return raw.split(/[\s,;，；]+/).map(x => x.trim()).filter(Boolean);
  if (raw && typeof raw === "object") return Object.keys(raw).filter(k => raw[k] && k.trim()).map(k => k.trim());
  return [];
}

async function fetchExcludeMap(): Promise<Map<string, Set<string>>> {
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/user_data?select=username,data`, {
    headers: sbHeaders(),
  });
  if (!resp.ok) throw new Error(`排除名单读取失败: HTTP ${resp.status}（拒绝执行任何退订）`);
  const rows: any[] = await resp.json();
  if (!Array.isArray(rows)) throw new Error("排除名单返回格式异常（拒绝执行任何退订）");
  const byUser = new Map<string, Set<string>>();
  const dirty = new Set<string>();
  const owners = new Map<string, string>();
  let total = 0;
  for (const r of rows) {
    const username = String(r?.username || "");
    const ak = r?.data?.ak_id;
    if (ak) owners.set(String(ak), username);
    const raw = r?.data?.schedule_exclude_instance_ids;
    if (raw === undefined || raw === null) {
      // 该账号没配排除清单 → 视作「未配置」，不牵连其他账号
      byUser.set(username, new Set());
      continue;
    }
    // 与 FC / Actions 三套统一：脏类型不能静默当空名单（否则会漏保护该用户配置的实例）
    const t = typeof raw;
    if (t !== "string" && !Array.isArray(raw) && !(raw && t === "object")) {
      dirty.add(username);
      byUser.set(username, new Set());
      continue;
    }
    if (Array.isArray(raw) && raw.some((x: any) => typeof x !== "string")) {
      dirty.add(username);
      byUser.set(username, new Set());
      continue;
    }
    const ids = new Set(normalizeExclude(raw));
    byUser.set(username, ids);
    total += ids.size;
  }
  EXCLUDE_BY_USER = byUser;
  EXCLUDE_DIRTY_USERS = dirty;
  AK_OWNER = owners;
  EXCLUDE_CACHE_AT = Date.now();
  console.log(`[protect] 🛡️ 排除名单已加载：${byUser.size} 个账号 / ${total} 个实例 ID（脏账号 ${dirty.size} 个）`);
  return byUser;
}

async function loadExcludeMap(): Promise<Map<string, Set<string>>> {
  if (EXCLUDE_CACHE_AT && Date.now() - EXCLUDE_CACHE_AT < EXCLUDE_TTL_MS) return EXCLUDE_BY_USER;
  // 50 台并发退订时合并成一次请求，避免同时打 Supabase 50 次
  if (!EXCLUDE_PENDING) EXCLUDE_PENDING = fetchExcludeMap();
  try {
    return await EXCLUDE_PENDING;
  } finally {
    EXCLUDE_PENDING = null;
  }
}

/** 全局合并名单（归属未知时使用，最保守）。 */
function globalExcludeIds(map: Map<string, Set<string>>): Set<string> {
  const all = new Set<string>();
  for (const s of map.values()) for (const id of s) all.add(id);
  return all;
}

/**
 * 解析某账号应当使用的排除名单。
 *   - username 为空（归属未知，例如手工传入未登记的 AK）→ 用全局合并名单（最保守）
 *   - 该账号排除字段类型脏 → deny=true（该账号一台都不退）
 *   - 正常 → 该账号自己的名单
 */
function resolveExcludes(username: string, map: Map<string, Set<string>>): { deny: boolean; ids: Set<string> } {
  if (!username) return { deny: false, ids: globalExcludeIds(map) };
  if (EXCLUDE_DIRTY_USERS.has(username)) return { deny: true, ids: new Set() };
  return { deny: false, ids: EXCLUDE_BY_USER.get(username) ?? new Set() };
}

/** 由 ak_id 反查归属账号（读名单时顺带建表，零额外请求）。 */
function usernameForAk(ak?: string): string {
  if (!ak) return "";
  return AK_OWNER.get(String(ak)) || "";
}

/** 所有退订路径的统一闸门；名单读取失败时抛错（fail-closed）。 */
async function assertNotExcluded(iid: string, username?: string): Promise<boolean> {
  const map = await loadExcludeMap();
  const v = resolveExcludes(username || "", map);
  if (v.deny) {
    console.log(`[protect] 🛡 账号 ${username} 的排除名单配置异常，拒绝退订任何实例`);
    return false;
  }
  if (v.ids.has(iid)) {
    console.log(`[protect] 🛡 跳过排除实例 ${iid}，绝不退订`);
    return false;
  }
  return true;
}

const REGION_INFO: Record<string, string> = {
  "cn-hangzhou": "杭州","cn-shanghai": "上海","cn-beijing": "北京",
  "cn-shenzhen": "深圳","cn-guangzhou": "广州","cn-nanjing": "南京",
  "cn-fuzhou": "福州","cn-wuhan": "武汉","cn-chengdu": "成都",
  "cn-heyuan": "河源","cn-huhehaote": "呼和浩特","cn-wulanchabu": "乌兰察布",
  "cn-zhangjiakou": "张家口","cn-hongkong": "中国香港",
  "ap-northeast-1": "东京","ap-northeast-2": "首尔",
  "ap-southeast-1": "新加坡","ap-southeast-2": "悉尼",
  "ap-southeast-3": "吉隆坡","ap-southeast-5": "雅加达",
  "ap-southeast-7": "曼谷","ap-south-1": "孟买",
  "us-west-1": "硅谷","us-east-1": "弗吉尼亚",
  "eu-west-1": "伦敦","eu-central-1": "法兰克福","me-east-1": "迪拜",
};

// ====== 签名 ======
function pe(s: string): string {
  return encodeURIComponent(s)
    .replace(/!/g,"%21").replace(/'/g,"%27")
    .replace(/\(/g,"%28").replace(/\)/g,"%29")
    .replace(/\*/g,"%2A").replace(/\+/g,"%20")
    .replace(/%7E/g,"~");
}
async function hmac(key: string, data: string): Promise<string> {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey("raw", enc.encode(key), {name:"HMAC",hash:"SHA-1"}, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, enc.encode(data));
  return btoa(String.fromCharCode(...new Uint8Array(sig)));
}

// V3 签名（OpenAPI 3.0）专用 - 用于必须使用 V3 的 API（如 CreateOrder）
// 阿里云 SWAS-OPEN CreateOrder 同时要求：(1) ACS3-HMAC-SHA256 签名 (2) Commodity 用 flat 格式 (3) form-urlencoded body
async function callAliyunV3(endpoint: string, action: string, params: Record<string, unknown>, ak: string, sk: string): Promise<any> {
  // 把 params 拍平成 form-urlencoded (OpenAPI 3.0 map format: Parent.Field=value)
  const flat: string[] = [];
  function flatObj(prefix: string, obj: any) {
    for (const k of Object.keys(obj||{})) {
      const v = obj[k];
      if (v === undefined || v === null) continue;
      if (typeof v === "object" && !Array.isArray(v)) {
        flatObj(prefix + k + ".", v);
      } else if (Array.isArray(v)) {
        v.forEach((it,i) => flatObj(prefix + k + "." + (i+1) + ".", it));
      } else {
        flat.push(prefix + k + "=" + encodeURIComponent(String(v)));
      }
    }
  }
  flatObj("", params);
  const form = flat.join("&");
  const formHash = await sha256Hex(form);

  const url = new URL(endpoint);
  const host = url.host;

  const headers: Record<string, string> = {
    "host": host,
    "x-acs-action": action,
    "x-acs-content-sha256": formHash,
    "x-acs-date": new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    "x-acs-version": "2020-06-01",
  };

  const sortedKeys = Object.keys(headers).sort();
  const canonicalHeaders = sortedKeys.map(k => `${k}:${headers[k].trim()}\n`).join("");
  const canonicalRequest = `POST\n${url.pathname}\n\n${canonicalHeaders}\n${sortedKeys.join(";")}\n${formHash}`;
  const crHash = await sha256Hex(canonicalRequest);
  const sts = `ACS3-HMAC-SHA256\n${crHash}`;

  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey("raw", enc.encode(sk), {name:"HMAC",hash:"SHA-256"}, false, ["sign"]);
  const sigBytes = await crypto.subtle.sign("HMAC", k, enc.encode(sts));
  const signature = Array.from(new Uint8Array(sigBytes)).map(b => b.toString(16).padStart(2,"0")).join("");

  const reqHeaders: Record<string, string> = {
    "host": host,
    "x-acs-action": action,
    "x-acs-content-sha256": formHash,
    "x-acs-date": headers["x-acs-date"],
    "x-acs-version": "2020-06-01",
    "content-type": "application/x-www-form-urlencoded",
    "Authorization": `ACS3-HMAC-SHA256 Credential=${ak},SignedHeaders=${sortedKeys.join(";")},Signature=${signature}`,
  };

  const resp = await fetch(endpoint, {
    method: "POST",
    headers: reqHeaders,
    body: form,
  });
  const text = await resp.text();
  let data: any;
  try { data = JSON.parse(text); } catch { throw new Error(`HTTP ${resp.status}: ${text.slice(0,300)}`); }
  if (data?.Code || data?.Message || data?.code || data?.message) {
    throw new Error(data.Message || data.message || data.Code || data.code || `HTTP ${resp.status}`);
  }
  return data;
}

async function sha256Hex(text: string): Promise<string> {
  const enc = new TextEncoder();
  const bytes = await crypto.subtle.digest("SHA-256", enc.encode(text));
  return Array.from(new Uint8Array(bytes)).map(b => b.toString(16).padStart(2,"0")).join("");
}

async function callAliyun(endpoint: string, action: string, params: Record<string, unknown>, ak: string, sk: string, version: string = "2020-06-01"): Promise<any> {
  const common: Record<string,string> = {
    AccessKeyId: ak, Action: action, Format: "JSON",
    SignatureMethod: "HMAC-SHA1", SignatureNonce: crypto.randomUUID(),
    SignatureVersion: "1.0",
    Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/,"Z"),
    Version: version,
  };
  const all: Record<string,string> = { ...common };
  for (const k of Object.keys(params||{})) {
    const v = (params as any)[k];
    if (v === undefined || v === null) continue;
    // V1 签名风格：嵌套对象直接 JSON 字符串（listInstances/listPlans/listImages/deleteInstance 这类 API 工作正常）
    all[k] = typeof v === "string" ? v : JSON.stringify(v);
  }
  const keys = Object.keys(all).sort();
  const parts = keys.map(k => pe(k)+"="+pe(all[k]));
  const cq = parts.join("&");
  const sts = "POST&"+pe("/")+"&"+pe(cq);
  const sig = await hmac(sk+"&", sts);
  const fq = cq+"&"+pe("Signature")+"="+pe(sig);

  // DEBUG: 打印发到 aliyun 的参数键
  console.log("[aliyun-proxy] action=", action, " keys=", keys.filter(k=>k.startsWith("Commodity")||k.startsWith("Region")).join(","), " hasCommodity=", !!keys.find(k=>k.startsWith("Commodity.")));

  const resp = await fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: fq,
  });
  let data: any;
  try { data = await resp.json(); } catch { data = {}; }
  if (data?.Code || data?.Message) {
    throw new Error(data.Message || data.Code || `HTTP ${resp.status}`);
  }
  return data;
}

// ====== 退订 ======
const LOCKED = [
  // BSS API 错误码
  "MissingRefundAmount","InvalidPayMethod","CannotDeleteInstance","RefundFailed","NoFullRefund",
  "NoApplicable","NotApplicable","ExceedRefundQuota","ExistUnPaidOrder","ExistRefundingOrder",
  "NoRestValue","AmbassadorOrderLimit","ActivityForbidden","CommodityNotSupported",
  "ProductCheckError","ResourceStatusError","NotAuthorized",
  // 中文关键词
  "非全额退款","非全额退订","订单未到期","订单到期","尚未结算",
  "InstanceHasUnsettledBill","PayMethodNotSupported","请先退订订单",
];
const isLock = (m:string)=>LOCKED.some(p=>m.includes(p));
const isNF = (m:string)=>m.includes("NotFound")||m.includes("InvalidInstance")||m.includes("ResourceNotExists")||m.includes("不存在");

async function listAll(ak:string,sk:string) {
  const all: Array<{regionId:string;instanceId:string}> = [];
  for (const rid of Object.keys(REGION_INFO)) {
    try {
      const p = await callAliyun(regionEndpoint(rid),"ListInstances",{PageSize:"100",PageNumber:"1"},ak,sk);
      let ins = p.Instances||[];
      const total = p.TotalCount||0;
      if (total>100) {
        for (let pg=2; pg<=Math.ceil(total/100); pg++) {
          const np = await callAliyun(regionEndpoint(rid),"ListInstances",{PageSize:"100",PageNumber:String(pg)},ak,sk);
          ins = ins.concat(np.Instances||[]);
        }
      }
      for (const i of ins) all.push({regionId:rid,instanceId:i.InstanceId});
    } catch(_) {}
  }
  return all;
}

async function cancelOne(rid:string,iid:string,ak:string,sk:string,username?:string): Promise<string> {
  // 🛡 黄金机硬保护（防御性兜底；runFullCancel 已先过滤，这里再保险一层）
  if (GOLDEN_INSTANCE_IDS.has(iid)) {
    console.log(`[refund] 🛡 跳过黄金机 ${iid}（${rid}），绝不退订`);
    return "protected";
  }
  // 🛡 排除实例统一闸门（2026-11-09 根治 / 2026-11-16 按账号隔离）：
  //    名单读不到会抛错 → 一台都不退；按 username 取该账号自己的名单
  if (!await assertNotExcluded(iid, username)) return "protected";
  // 用 BSS RefundInstance 真正退订（能退款到原账户，不只是删除）
  // RefundInstance 是中心 endpoint，不分地域；地域信息仅用于日志
  // 自动尝试多个 ProductCode（swas / simpleappserver / swas-open）
  const TRIED_CODES = ["swas", "simpleappserver", "swas-open", "simpleAppserver"];
  let lastErr: any = null;
  for (const code of TRIED_CODES) {
    try {
      await callAliyun(BSS_ENDPOINT,"RefundInstance",{
        InstanceId: iid,
        ProductCode: code,
        ProductType: "",
        ImmediatelyRelease: "1",  // 1=立即释放；0=先停机按停机策略停
        ClientToken: crypto.randomUUID(),
      },ak,sk,BSS_VERSION);
      return "ok";  // 成功！
    } catch(e: any) {
      lastErr = e;
      const m = e?.message || String(e);
      if (m.includes("CommodityNotSupported") || m.includes("ProductCheckError")) {
        continue;  // 试下一个 code
      }
      throw e;  // 其他错误直接抛
    }
  }
  throw lastErr || new Error("所有 ProductCode 都不支持");
}

async function batchCancel(insts:Array<{regionId:string;instanceId:string}>,ak:string,sk:string,username?:string) {
  const C = 50;
  let s=0,sk2=0,l=0,f=0;
  for (let i=0;i<insts.length;i+=C) {
    const slice = insts.slice(i,i+C);
    const rs = await Promise.all(slice.map(async x=>{
      try { const cr = await cancelOne(x.regionId,x.instanceId,ak,sk,username); return cr === "protected" ? "p" : "s"; }
      catch(e:any){
        const m=e?.message||"";
        console.log(`[refund] ${x.regionId}/${x.instanceId} 失败: ${m}`);
        if(isLock(m)) return "l"; if(isNF(m)) return "k"; return "f";
      }
    }));
    for (const r of rs) { if(r==="s")s++; else if(r==="k"||r==="p")sk2++; else if(r==="l")l++; else f++; }
    // BSS 限流 20/1s，保守间隔避免触发
    if (i+C<insts.length) await new Promise(r=>setTimeout(r,300));
  }
  return {success:s,skipped:sk2,locked:l,failed:f};
}

async function runFullCancel(ak:string,sk:string,username?:string) {
  // 🛡 fail-closed：保护名单读不到就抛错，绝不进入退订流程
  // ⚠️ 2026-11-16 按账号隔离：只取该账号自己的排除名单；
  //    归属未知（username 为空）→ 用全局合并名单（最保守）
  const map = await loadExcludeMap();
  const verdict = resolveExcludes(username || "", map);
  if (verdict.deny) {
    throw new Error(`账号 ${username} 的排除名单配置异常，拒绝执行任何退订`);
  }
  const excluded = verdict.ids;
  const raw = await listAll(ak,sk);
  // 🛡 黄金机 + 排除实例硬保护：从待退订清单中剔除，绝不退订
  const golden = raw.filter(x => GOLDEN_INSTANCE_IDS.has(x.instanceId));
  const excludedList = raw.filter(x => excluded.has(x.instanceId));
  if (golden.length) console.log(`[refund] 🛡 已剔除 ${golden.length} 台黄金机，绝不退订: ${golden.map(x=>x.instanceId).join(", ")}`);
  if (excludedList.length) console.log(`[refund] 🛡 已剔除 ${excludedList.length} 台排除实例，绝不退订: ${excludedList.map(x=>x.instanceId).join(", ")}`);
  const all = raw.filter(x => !GOLDEN_INSTANCE_IDS.has(x.instanceId) && !excluded.has(x.instanceId));
  if (all.length===0) return {success:0,skipped:golden.length,locked:0,failed:0,message:"无实例", goldenSkipped: golden.length};
  const r1 = await batchCancel(all,ak,sk,username);
  let res:any = {...r1, firstRoundInstances: all.length, goldenSkipped: golden.length, excludedSkipped: excludedList.length};
  if (r1.failed>0) {
    await new Promise(r=>setTimeout(r,10*60*1000));
    const remRaw = await listAll(ak,sk);
    const remGolden = remRaw.filter(x => GOLDEN_INSTANCE_IDS.has(x.instanceId));
    const rem = remRaw.filter(x => !GOLDEN_INSTANCE_IDS.has(x.instanceId) && !excluded.has(x.instanceId));
    if (rem.length>0) {
      const r2 = await batchCancel(rem,ak,sk,username);
      res = {success:r1.success+r2.success,skipped:r1.skipped+r2.skipped,locked:r1.locked+r2.locked,failed:r2.failed,firstRound:r1,secondRound:r2,goldenSkipped: golden.length+remGolden.length};
    }
  }
  return res;
}

// 用 fetch 直接读 user_data 表（无需 supabase-js）
async function loadCredsForUsers(akHint?:string, skHint?:string) {
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/user_data?select=username,data`, {
    headers: sbHeaders(),
  });
  if (!resp.ok) throw new Error("读取用户凭证失败: HTTP "+resp.status);
  const rows: any[] = await resp.json();
  const all = rows
    .filter(r => r.data?.ak_id && r.data?.ak_secret)
    .map(r => ({username:r.username, ak:r.data.ak_id, sk:r.data.ak_secret}));
  // ⚠️ 2026-11-16：不再直接信任调用方传入的 AK/SK，而是回表匹配归属账号，
  //    这样退订能落到「该账号自己的排除名单」上（按账号隔离的根）。
  //    匹配不到（手工传入未登记的 AK）→ username 留空 → 走全局合并名单（最保守）。
  if (!akHint) return all;
  const hit = all.filter(u => u.ak === akHint);
  if (hit.length) return hit;
  return [{username:"", ak:akHint, sk:skHint || ""}];
}

/** 读取某账号当前最新的 data（写回前用，避免用旧快照覆盖用户新配置）。 */
async function fetchLatestData(username:string): Promise<any | null> {
  // ⚠️ 归属未知（空 username）时必须拒绝：URL 会变成 username=eq. → 匹配到第一行，
  //    把别人行的 data 写回去。宁可跳过写回，也不能写错行。
  if (!username) return null;
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/user_data?username=eq.${encodeURIComponent(username)}&select=data`, {
    headers: sbHeaders(),
  });
  if (!resp.ok) return null;
  const rows: any[] = await resp.json();
  if (!Array.isArray(rows) || !rows.length) return null;
  return rows[0]?.data || {};
}

/**
 * 写回某账号的 data。
 * ⚠️ PostgREST 对 jsonb 列的 PATCH 是**顶层替换**而不是深度合并
 *    （实测：PATCH {"data":{"x":1}} 会把 {"data":{"probe":true}} 变成 {"data":{"x":1}}）。
 *    所以必须整体写回完整的 data，绝不能只 PATCH 一个字段。
 */
async function patchUserData(username:string, data:any) {
  if (!username) return;
  await fetch(`${SUPABASE_URL}/rest/v1/user_data?username=eq.${encodeURIComponent(username)}`, {
    method: "PATCH",
    headers: sbHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({ data }),
  });
}

function json(body:unknown, status=200) {
  return new Response(JSON.stringify(body), {status, headers:{...CORS,"Content-Type":"application/json"}});
}

Deno.serve(async (req:Request)=>{
  if (req.method==="OPTIONS") return new Response("ok",{headers:CORS});
  let p:any = {};
  try { p = await req.json(); } catch {}
  const action = p?.action;
  console.log("[aliyun-proxy] method=", req.method, " action=", JSON.stringify(action), " keys=", Object.keys(p||{}).join(","));
  try {
    switch (action) {
      case "createOrder": {
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params) return json({error:"缺少 params"},400);
        const regionId = params.RegionId || "cn-hangzhou";
        // 阿里云 SWAS-OPEN CreateOrder 要求 OpenAPI V3 签名 + JSON body（嵌套 Commodity 结构）
        const data = await callAliyunV3(regionEndpoint(regionId), "CreateOrder", params, ak_id, ak_secret);
        return json({success:true,data});
      }
      case "ListPlans":
      case "listPlans": {
        const {ak_id,ak_secret,regionId} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        const data = await callAliyun(regionEndpoint(regionId||"cn-hangzhou"),"ListPlans",{RegionId:regionId||"cn-hangzhou"},ak_id,ak_secret);
        return json({success:true,data});
      }
      case "listImages":
      case "ListImages": {
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        const regionId = params?.RegionId || p.regionId || "cn-hangzhou";
        const queryParams: any = {RegionId: regionId};
        if (params?.PageSize) queryParams.PageSize = params.PageSize;
        if (params?.PageNumber) queryParams.PageNumber = params.PageNumber;
        const data = await callAliyun(regionEndpoint(regionId),"ListImages",queryParams,ak_id,ak_secret);
        return json({success:true,data});
      }
      case "createCustomImage":
      case "CreateCustomImage": {
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params?.RegionId || !params?.InstanceId || !params?.ImageName) {
          return json({error:"缺少 params.RegionId/InstanceId/ImageName"},400);
        }
        const data = await callAliyun(regionEndpoint(params.RegionId),"CreateCustomImage",{
          RegionId: params.RegionId,
          InstanceId: params.InstanceId,
          ImageName: params.ImageName,
        },ak_id,ak_secret);
        return json({success:true,data});
      }
      case "createInstances":
      case "CreateInstances": {
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params?.RegionId || !params?.ImageId || !params?.PlanId) {
          return json({error:"缺少 params.RegionId/ImageId/PlanId"},400);
        }
        const apiParams: any = {
          RegionId: params.RegionId,
          ImageId: params.ImageId,
          PlanId: params.PlanId,
          Amount: params.Amount ?? 1,
          Period: params.Period ?? 1,
          PeriodUnit: params.PeriodUnit || "Month",
        };
        // SWAS CreateInstances 没有 AutoPay 参数，文档明确：调用前需确保账户余额充足，否则创建失败
        if (params.ClientToken) apiParams.ClientToken = params.ClientToken;
        const data = await callAliyun(regionEndpoint(params.RegionId),"CreateInstances",apiParams,ak_id,ak_secret);
        return json({success:true,data});
      }
      case "CreateOrder": {
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params?.RegionId || !params?.ImageId || !params?.PlanId) {
          return json({error:"缺少 params.RegionId/ImageId/PlanId"},400);
        }
        // SWAS CreateOrder 只下单、不扣费（AutoPay=false），余额不足也能生成待支付订单
        const commodity: any = {
          Period: params.Period ?? 1,
          PeriodUnit: params.PeriodUnit || "Month",
          PayType: "Prepaid",
          CommodityType: "Server",
          PlanId: params.PlanId,
          ImageId: params.ImageId,
          Amount: params.Amount ?? 1,
          DataDiskSize: params.DataDiskSize ?? 0,
          AutoPay: false,
          AutoRenew: false,
        };
        const apiParams: any = {
          RegionId: params.RegionId,
          OrderType: "Buy",
          Commodity: commodity,
        };
        if (params.ClientToken) apiParams.ClientToken = params.ClientToken;

        // CreateOrder 要求 V3 签名 + flat 参数格式，优先走 V3；失败回退 V1（Commodity 用 JSON 串）
        const ep = regionEndpoint(params.RegionId);
        let data: any, lastErr = "";
        try {
          data = await callAliyunV3(ep,"CreateOrder",apiParams,ak_id,ak_secret);
        } catch (e1) {
          lastErr = String((e1 as Error)?.message || e1);
          console.log("[aliyun-proxy] CreateOrder V3 failed:", lastErr, "-> fallback V1");
          const v1Params: any = { ...apiParams, Commodity: JSON.stringify(commodity) };
          data = await callAliyun(ep,"CreateOrder",v1Params,ak_id,ak_secret);
        }
        return json({success:true,data});
      }
      case "deleteCustomImage":
      case "DeleteCustomImage": {
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params?.RegionId || !params?.ImageId) {
          return json({error:"缺少 params.RegionId/ImageId"},400);
        }
        const data = await callAliyun(regionEndpoint(params.RegionId),"DeleteCustomImage",{
          RegionId: params.RegionId,
          ImageId: params.ImageId,
        },ak_id,ak_secret);
        return json({success:true,data});
      }
      case "ListInstances": case "listInstances": {
        // 通用 ListInstances 转发（带分页参数透传）
        const {ak_id,ak_secret,regionId,params:bp} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        const rid = regionId || bp?.RegionId || "cn-hangzhou";
        const queryParams:any = {RegionId:rid};
        if (bp?.PageSize) queryParams.PageSize = bp.PageSize;
        if (bp?.PageNumber) queryParams.PageNumber = bp.PageNumber;
        if (bp?.InstanceId) queryParams.InstanceId = bp.InstanceId;
        if (bp?.Status) queryParams.Status = bp.Status;
        if (bp?.Tags && Array.isArray(bp.Tags)) {
          bp.Tags.forEach((t:any,i:number) => {
            if (t.Key) queryParams[`Tag.${i+1}.Key`] = t.Key;
            if (t.Value) queryParams[`Tag.${i+1}.Value`] = t.Value;
          });
        }
        const data = await callAliyun(regionEndpoint(rid),"ListInstances",queryParams,ak_id,ak_secret);
        return json({success:true,data});
      }
      case "RunCommand":
      case "runCommand": {
        // 在指定地域的某一台实例上执行一条命令
        // params: { RegionId, InstanceId, CommandContent, Type, WorkingDir?, Timeout?, Name?, EnableParameter?, Parameters? }
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params) return json({error:"缺少 params"},400);
        const regionId = params.RegionId;
        if (!regionId) return json({error:"缺少 params.RegionId"},400);
        if (!params.InstanceId) return json({error:"缺少 params.InstanceId"},400);
        if (!params.CommandContent) return json({error:"缺少 params.CommandContent"},400);
        if (!params.Type) return json({error:"缺少 params.Type（RunShellScript/RunPowerShellScript/RunBatScript）"},400);
        const data = await callAliyun(regionEndpoint(regionId),"RunCommand",params,ak_id,ak_secret);
        return json({success:true,data});
      }
      case "RebootInstance":
      case "rebootInstance": {
        // 重启单台实例
        // params: { RegionId, InstanceId }
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params) return json({error:"缺少 params"},400);
        const regionId = params.RegionId;
        const instanceId = params.InstanceId;
        if (!regionId) return json({error:"缺少 params.RegionId"},400);
        if (!instanceId) return json({error:"缺少 params.InstanceId"},400);
        const data = await callAliyun(regionEndpoint(regionId),"RebootInstance",{
          RegionId: regionId,
          InstanceId: instanceId,
          ClientToken: crypto.randomUUID(),
          Force: false,  // false=优雅重启；true=强制重启
        },ak_id,ak_secret);
        return json({success:true,data});
      }
      case "RefundInstance":
      case "refundInstance": {
        // BSS 真正的退订（能退款），不是 SWAS 的 DeleteInstance
        // ProductCode 尝试顺序（按 SWAS 历史命名规范）：swas -> simpleappserver -> swas-open -> simpleAppserver
        // 第一个不报 CommodityNotSupported/ProductCheckError 的就是正确的
        // params: { InstanceId, ProductCode?, ProductType?, ImmediatelyRelease? }
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params) return json({error:"缺少 params"},400);
        if (!params.InstanceId) return json({error:"缺少 params.InstanceId"},400);

        // 🛡 黄金机硬保护：单实例退订也绝不退订
        if (GOLDEN_INSTANCE_IDS.has(params.InstanceId) || (params.PublicIpAddress && GOLDEN_PUBLIC_IPS.has(params.PublicIpAddress))) {
          console.log(`[refundInstance] 🛡 跳过黄金机 ${params.InstanceId}，绝不退订`);
          return json({success:false, skipped:true, reason:"golden-machine-protected", instanceId: params.InstanceId});
        }
        // 🛡 排除实例保护：单实例退订同样受云端保护名单约束
        if (!await assertNotExcluded(params.InstanceId, usernameForAk(p.ak_id))) {
          return json({success:false, skipped:true, reason:"exclude-list-protected", instanceId: params.InstanceId});
        }

        const TRIED_CODES = params.ProductCode
          ? [params.ProductCode]   // 用户指定就只试这个
          : ["swas", "simpleappserver", "swas-open", "simpleAppserver"];

        let lastErr: any = null;
        for (const code of TRIED_CODES) {
          try {
            const data = await callAliyun(BSS_ENDPOINT,"RefundInstance",{
              InstanceId: params.InstanceId,
              ProductCode: code,
              ProductType: params.ProductType || "",
              ImmediatelyRelease: params.ImmediatelyRelease || "1",
              ClientToken: crypto.randomUUID(),
            },ak_id,ak_secret,BSS_VERSION);
            // 成功！记录这个 productCode 后面默认用
            console.log(`[refundInstance] ✅ ${params.InstanceId} ProductCode="${code}" 成功`);
            return json({success:true, data, productCode: code});
          } catch(e: any) {
            lastErr = e;
            const m = e?.message || String(e);
            console.log(`[refundInstance] ❌ ${params.InstanceId} ProductCode="${code}" 失败: ${m.slice(0, 200)}`);
            // 商品不支持 / 产品预校验失败：试下一个 code
            if (m.includes("CommodityNotSupported") || m.includes("ProductCheckError")) {
              continue;
            }
            // 其他错误（NotAuthorized, NotApplicable 等）直接抛
            throw e;
          }
        }
        // 所有 code 都试过还不支持，抛最后一个错误
        throw lastErr;
      }
      case "ProbeProductCode":
      case "probeProductCode": {
        // 诊断：试多个 ProductCode 看哪个不返回 CommodityNotSupported
        // params: { InstanceId: string }
        const {ak_id, ak_secret, params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        // 🛡 黄金机硬保护：诊断探测也不对黄金机下手（探测会停机）
        if (params?.InstanceId && (GOLDEN_INSTANCE_IDS.has(params.InstanceId) || (params.PublicIpAddress && GOLDEN_PUBLIC_IPS.has(params.PublicIpAddress)))) {
          return json({success:false, skipped:true, reason:"golden-machine-protected", instanceId: params.InstanceId});
        }
        if (params?.InstanceId && !await assertNotExcluded(params.InstanceId, usernameForAk(p.ak_id))) {
          return json({success:false, skipped:true, reason:"exclude-list-protected", instanceId: params.InstanceId});
        }
        if (!params?.InstanceId) return json({error:"缺少 params.InstanceId"},400);
        const CODES = ["swas", "simpleappserver", "swas-open", "simpleAppserver", "SimpleApplicationServer", "simpleappserverpre"];
        const trials: any[] = [];
        for (const code of CODES) {
          try {
            const data = await callAliyun(BSS_ENDPOINT,"RefundInstance",{
              InstanceId: params.InstanceId,
              ProductCode: code,
              ProductType: "",
              ImmediatelyRelease: "0",  // 探测用 0（按停机策略停），避免误删实例
              ClientToken: crypto.randomUUID(),
            },ak_id,ak_secret,BSS_VERSION);
            trials.push({code, ok: true, data});
            // 找到第一个可用的
            break;
          } catch(e: any) {
            const m = e?.message || String(e);
            const isCommodityError = m.includes("CommodityNotSupported") || m.includes("ProductCheckError");
            trials.push({
              code,
              ok: false,
              error: m.length > 300 ? m.slice(0, 300) + '...' : m,
              commodityError: isCommodityError,  // 这个错意味着不是真正的 code 错误，可以试下一个
            });
            if (!isCommodityError) break;  // 其他错就别继续试了
          }
          await new Promise(r => setTimeout(r, 200));  // 限流
        }
        return json({success: true, trials});
      }
      case "replaceSystemDisk":
      case "resetSystem":
      case "ResetSystem": {
        // SWAS 重置系统（实际 API 名是 ResetSystem，不是 ReplaceSystemDisk 那是 ECS 的）
        // 【修复】前端 resetSystem() 发送 action:'ResetSystem'，此前代理无此 case → 落入 default 心跳分支，
        // 返回 200 无 success 字段，前端误判"失败：HTTP 200"且根本没执行重置。此处与 replaceSystemDisk 合并。
        // 注意：实例必须处于 Stopped 状态。如果 Status=Running 自动先停机再重置
        // params: { RegionId, InstanceId, ImageId, autoStopIfRunning?: bool }
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params) return json({error:"缺少 params"},400);
        const regionId = params.RegionId;
        const instanceId = params.InstanceId;
        const imageId = params.ImageId;
        const autoStop = params.autoStopIfRunning !== false;  // 默认 true
        if (!regionId) return json({error:"缺少 params.RegionId"},400);
        if (!instanceId) return json({error:"缺少 params.InstanceId"},400);
        if (!imageId) return json({error:"缺少 params.ImageId"},400);
        const endpoint = regionEndpoint(regionId);

        // 1. 查询并确保实例处于 Stopped 状态（ResetSystem 前置条件）
        let stoppedFirst = false;
        if (autoStop) {
          try {
            const desc = await callAliyun(endpoint,"ListInstances",{
              RegionId: regionId,
              InstanceId: instanceId,
            },ak_id,ak_secret);
            const inst = (desc.Instances || [])[0];
            if (!inst) {
              return json({success:false, error:"未找到指定实例"},404);
            }
            const status = inst.Status;
            let needWait = false;
            if (status === "Stopped") {
              // 已停机，直接重置
            } else if (status === "Running" || status === "RunningException") {
              console.log("[resetSystem] 实例运行中:", status, "→ 先停机");
              await callAliyun(endpoint,"StopInstance",{
                RegionId: regionId,
                InstanceId: instanceId,
                Force: false,
                ClientToken: crypto.randomUUID(),
              },ak_id,ak_secret);
              stoppedFirst = true;
              needWait = true;
            } else if (status === "Stopping") {
              console.log("[resetSystem] 实例正在停机:", status, "→ 等待完成");
              needWait = true;
            } else {
              return json({success:false, error:`实例状态 ${status} 不支持重置系统`},400);
            }

            // 停机是异步，最多等 5 分钟（60×5s），必须确认 Stopped 才继续
            if (needWait) {
              let becameStopped = false;
              for (let i = 0; i < 60; i++) {
                await new Promise(r => setTimeout(r, 5000));
                const desc2 = await callAliyun(endpoint,"ListInstances",{
                  RegionId: regionId,
                  InstanceId: instanceId,
                },ak_id,ak_secret);
                const st = (desc2.Instances || [])[0]?.Status;
                console.log("[resetSystem] 等待停机:", i, "status=", st);
                if (st === "Stopped") {
                  becameStopped = true;
                  break;
                }
              }
              if (!becameStopped) {
                return json({success:false, error:"等待实例停机超时（5分钟），未执行重置"},408);
              }
            }
          } catch (e:any) {
            console.log("[resetSystem] 检查/停机实例失败:", e.message);
            return json({success:false, error:"检查/停机实例失败: " + e.message},500);
          }
        }

        // 2. 重置系统
        const data = await callAliyun(endpoint,"ResetSystem",{
          RegionId: regionId,
          InstanceId: instanceId,
          ImageId: imageId,
          ClientToken: crypto.randomUUID(),
        },ak_id,ak_secret);
        return json({success:true, data, stoppedFirst});
      }
      case "CreateQuotaApplication":
      case "createQuotaApplication": {
        // 阿里云配额中心：创建配额提升申请
        // params: {
        //   ProductCode?: "swas",
        //   QuotaActionCode?: "q_z3sbl5",
        //   DesireValue?: 500,
        //   RegionId?: "cn-hangzhou",
        //   Reason?: "业务扩展",
        //   NoticeType?: 0,
        //   QuotaCategory?: "CommonQuota"
        // }
        const {ak_id, ak_secret, params} = p;
        if (!ak_id || !ak_secret) return json({error: "缺少凭证"}, 400);
        if (!params) return json({error: "缺少 params"}, 400);
        const regionId = params.RegionId || "cn-hangzhou";
        const productCode = params.ProductCode || "swas";
        const quotaActionCode = params.QuotaActionCode || "q_z3sbl5";
        const desireValue = params.DesireValue ?? 500;
        const reason = params.Reason || "业务扩展，需提升实例数量上限";
        const noticeType = params.NoticeType ?? 0;
        const quotaCategory = params.QuotaCategory || "CommonQuota";

        const qParams: Record<string, string> = {
          ProductCode: productCode,
          QuotaActionCode: quotaActionCode,
          DesireValue: String(desireValue),
          Reason: reason,
          NoticeType: String(noticeType),
          QuotaCategory: quotaCategory,
          "Dimensions.1.Key": "regionId",
          "Dimensions.1.Value": regionId,
        };
        // 如果用户传了自定义维度，覆盖默认
        if (params.Dimensions && Array.isArray(params.Dimensions) && params.Dimensions.length > 0) {
          for (let i = 0; i < params.Dimensions.length; i++) {
            const dim = params.Dimensions[i];
            if (dim.Key !== undefined) qParams[`Dimensions.${i + 1}.Key`] = String(dim.Key);
            if (dim.Value !== undefined) qParams[`Dimensions.${i + 1}.Value`] = String(dim.Value);
          }
        }

        const QUOTA_ENDPOINT = "https://quotas.aliyuncs.com/"; // 2026-09-26 修复：原 quotacenter.aliyuncs.com 为拼写错误（NXDOMAIN），致提额全失败
        const QUOTA_VERSION = "2020-05-10";
        const data = await callAliyun(QUOTA_ENDPOINT, "CreateQuotaApplication", qParams, ak_id, ak_secret, QUOTA_VERSION);
        return json({success: true, data});
      }
      case "RunCancelNow":
      case "runCancelNow": {
        const users = await loadCredsForUsers(p.ak_id,p.ak_secret);
        const results:Record<string,any> = {};
        for (const u of users) {
          try { results[u.username] = await runFullCancel(u.ak,u.sk,u.username); }
          catch(e:any){ results[u.username] = {error:e.message}; }
        }
        return json({success:true,results,time:new Date().toISOString()});
      }
      case "RunScheduledCancel":
      case "runScheduledCancel": {
        // 🕐 自检时间模式（由 cron-job.org 每分钟调用一次）
        // 只对当前北京时间匹配 schedule_hour:schedule_minute 的用户执行退订
        // 用 ±2 分钟窗口避免 cron 延迟导致漏触发
        // 同一天内只执行一次（通过 schedule_last_executed_date 去重）
        const now = new Date();
        // 北京时间 = UTC+8
        const beijingMs = now.getTime() + 8 * 60 * 60 * 1000;
        const beijingTime = new Date(beijingMs);
        const curHour = beijingTime.getUTCHours();
        const curMinute = beijingTime.getUTCMinutes();
        const curTotalMin = curHour * 60 + curMinute;
        const todayStr = beijingTime.toISOString().slice(0, 10); // YYYY-MM-DD

        // 读取所有 user_data
        const resp = await fetch(`${SUPABASE_URL}/rest/v1/user_data?select=username,data`, {
          headers: sbHeaders(),
        });
        if (!resp.ok) throw new Error("读取用户凭证失败: HTTP " + resp.status);
        const rows: any[] = await resp.json();

        // 🛡 读取仍存在的登录账号集合（app_users）：账号已注销的，其残留排程不再执行。
        //    读表失败 → 抛错 fail-closed（绝不"读不到就当全部有效"，那等于放行已注销账号）。
        const usersResp = await fetch(`${SUPABASE_URL}/rest/v1/app_users?select=username`, {
          headers: sbHeaders(),
        });
        if (!usersResp.ok) throw new Error("读取账号库失败: HTTP " + usersResp.status);
        const userRows: any[] = await usersResp.json();
        const activeUsers = new Set<string>(
          (Array.isArray(userRows) ? userRows : [])
            .map((u: any) => String(u?.username || ""))
            .filter((x: string) => !!x),
        );
        console.log(`[runScheduledCancel] 账号库有效账号数: ${activeUsers.size}`);

        const results: Record<string, any> = {};
        let triggered = 0, skipped = 0;
        for (const r of rows) {
          const d = r.data || {};
          if (!d.ak_id || !d.ak_secret) continue;
          // 已注销账号：登录账号已从 app_users 删除，但 user_data 里残留的排程
          // 仍会让定时任务替一个没人能登录的账号持续做「花钱」的退订 → 跳过。
          if (!activeUsers.has(String(r.username || ""))) {
            results[r.username] = {skipped: true, reason: "account_removed"};
            skipped++;
            console.log(`[runScheduledCancel] ⛔ ${r.username} 登录账号已注销，跳过定时退订`);
            continue;
          }
          if (!d.schedule_enabled) {
            results[r.username] = {skipped: true, reason: "schedule_disabled"};
            skipped++;
            continue;
          }
          const sh = d.schedule_hour;
          const sm = d.schedule_minute;
          if (sh === undefined || sm === undefined || sh === null || sm === null) {
            results[r.username] = {skipped: true, reason: "no_schedule_set"};
            skipped++;
            continue;
          }
          // 同一天去重
          if (d.schedule_last_executed_date === todayStr) {
            results[r.username] = {skipped: true, reason: "already_executed_today", last_executed: d.schedule_last_executed_date};
            skipped++;
            continue;
          }
          const targetTotalMin = sh * 60 + sm;
          const diff = Math.abs(curTotalMin - targetTotalMin);
          // ±2 分钟窗口（允许 cron 延迟最多 2 分钟）
          if (diff <= 2) {
            // 时间匹配 → 执行退订
            triggered++;
            console.log(`[runScheduledCancel] ⏰ ${r.username} 时间匹配 (now=${curHour}:${curMinute}, target=${sh}:${sm}) → 执行退订`);
            try {
              const cancelRes = await runFullCancel(d.ak_id, d.ak_secret, r.username);
              // 成功后写入今天日期（防同天重复）
              // ⚠️ 2026-11-16：PostgREST 对 jsonb 是**顶层替换**，只 PATCH 一个字段会清空
              //    该用户全部其它配置；且不能用循环开始时的旧快照 d（会把用户刚加的排除
              //    实例冲掉 → 下一轮可能误退）。→ 先读最新 data，只改这一个键，整体写回。
              const latest = await fetchLatestData(r.username);
              if (latest) {
                await patchUserData(r.username, { ...latest, schedule_last_executed_date: todayStr })
                  .catch(() => {}); // 写日期失败不影响退订结果
              }
              results[r.username] = { ...cancelRes, executed_at: todayStr + " " + String(curHour).padStart(2,'0') + ":" + String(curMinute).padStart(2,'0') };
            } catch(e:any) {
              results[r.username] = {error: e.message};
            }
          } else {
            skipped++;
            results[r.username] = {
              skipped: true,
              scheduled: String(sh).padStart(2,'0') + ":" + String(sm).padStart(2,'0'),
              now: String(curHour).padStart(2,'0') + ":" + String(curMinute).padStart(2,'0'),
              diff_min: diff,
            };
          }
        }
        return json({
          success: true,
          results,
          time: now.toISOString(),
          beijingTime: String(curHour).padStart(2,'0') + ":" + String(curMinute).padStart(2,'0'),
          triggered,
          skipped,
          hint: triggered > 0 ? "已触发退订" : "未到执行时间，跳过",
        });
      }
      case "RunScheduleNow":
      case "runScheduleNow": {
        // 🚀 立即触发：忽略时间窗口，立即为当前用户执行退订（不受同天去重限制）
        // 适用于「定时时间过了但没退订成功」的场景
        const users = await loadCredsForUsers(p.ak_id, p.ak_secret);
        const now = new Date();
        const beijingTime = new Date(now.getTime() + 8 * 60 * 60 * 1000);
        const curHour = beijingTime.getUTCHours();
        const curMinute = beijingTime.getUTCMinutes();
        const todayStr = beijingTime.toISOString().slice(0, 10);
        const results: Record<string, any> = {};
        for (const u of users) {
          try {
            console.log(`[runScheduleNow] 🚀 立即触发 ${u.username} 退订`);
            const cancelRes = await runFullCancel(u.ak, u.sk, u.username);
            // 写今天日期（标记为已执行）—— 读-改-写，不清空该账号的其它配置
            const latest = await fetchLatestData(u.username);
            if (latest) {
              await patchUserData(u.username, { ...latest, schedule_last_executed_date: todayStr })
                .catch(() => {});
            }
            results[u.username] = { ...cancelRes, executed_at: todayStr + " " + String(curHour).padStart(2,'0') + ":" + String(curMinute).padStart(2,'0'), mode: "manual" };
          } catch(e:any) {
            results[u.username] = {error: e.message};
          }
        }
        return json({
          success: true,
          results,
          time: now.toISOString(),
          beijingTime: String(curHour).padStart(2,'0') + ":" + String(curMinute).padStart(2,'0'),
          mode: "manual",
          hint: "立即触发模式（已忽略时间窗口和同天去重）",
        });
      }
      case "CheckSchedule":
      case "checkSchedule": {
        // 轻量探测：只读 schedule 配置，不执行退订（给前端用来显示"下次执行时间"）
        const resp = await fetch(`${SUPABASE_URL}/rest/v1/user_data?select=username,data`, {
          headers: sbHeaders(),
        });
        if (!resp.ok) throw new Error("读取用户凭证失败: HTTP " + resp.status);
        const rows: any[] = await resp.json();
        const now = new Date();
        const beijingTime = new Date(now.getTime() + 8 * 60 * 60 * 1000);
        const curHour = beijingTime.getUTCHours();
        const curMinute = beijingTime.getUTCMinutes();
        const list = rows.map(r => {
          const d = r.data || {};
          return {
            username: r.username,
            schedule_enabled: !!d.schedule_enabled,
            schedule_time: (d.schedule_hour !== undefined && d.schedule_minute !== undefined)
              ? String(d.schedule_hour).padStart(2,'0') + ":" + String(d.schedule_minute).padStart(2,'0')
              : null,
            last_executed_date: d.schedule_last_executed_date || null,
            has_credentials: !!(d.ak_id && d.ak_secret),
          };
        });
        return json({
          success: true,
          beijingTime: String(curHour).padStart(2,'0') + ":" + String(curMinute).padStart(2,'0'),
          schedules: list,
        });
      }
      default:
        return json({ok:true,hint:"aliyun-proxy alive",received_action:action, action_type:typeof action, raw:JSON.stringify(p).slice(0,200)});
    }
  } catch (err:any) {
    return json({success:false,error:err.message},500);
  }
});

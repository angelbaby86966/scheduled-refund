#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wb-auth 鉴权网关 —— 阿里云函数计算（FC）境内镜像版

为什么要有这个版本（2026-11-17）：
  主网关在 Supabase Edge Function，域名 opauwtkivhjxlijfqaix.supabase.co
  解析到 Cloudflare 国际 IP（104.18.38.10 / 172.64.149.246）。
  部分中国大陆运营商线路到该 IP 不通，浏览器直接抛 "Failed to fetch"，
  用户看到的是登录失败（且前端一度误报成「账号或密码错误」）。
  → 本函数部署在阿里云（境内节点），作为**境内可达的备选入口**。

与 Edge 版的关系：
  · 用**同一个** WB_AUTH_SECRET 签发票据 → 两端签发的票互相通用，
    用户走哪条路登录都不影响后续换 tool 票、读数据。
  · scope 规则完全一致：session(12h) / tool(10min)。
  · 票据消费端只认「签名 + scope + 归属」，不认签发来源。

依赖：零第三方（只用 Python 标准库 hmac/hashlib/base64/urllib）。
"""

import base64
import hashlib
import hmac
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

# ====== 配置 ======
SB_URL = (os.environ.get("SUPABASE_URL") or
          "https://opauwtkivhjxlijfqaix.supabase.co").rstrip("/")
SERVICE_KEY = (os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or
               os.environ.get("SUPABASE_ANON_KEY") or "").strip()
AUTH_SECRET = (os.environ.get("WB_AUTH_SECRET") or "").strip()

SESSION_TTL_MS = 12 * 60 * 60 * 1000
TOOL_TTL_MS = 10 * 60 * 1000
ADMIN_USER = "zhangruiyao"

CORS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type, x-wb-auth",
    "Access-Control-Max-Age": "86400",
}


# ====== 工具 ======
def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64url_decode(s: str) -> bytes:
    t = s.replace("-", "+").replace("_", "/")
    pad = "=" * (-len(t) % 4)
    return base64.urlsafe_b64decode(t + pad)


def hmac_sha256(payload: str) -> str:
    key = AUTH_SECRET.encode("utf-8")
    sig = hmac.new(key, payload.encode("utf-8"), hashlib.sha256).digest()
    return b64url(sig)


def sign_ticket(username: str, role: str, scope: str, ttl_ms: int) -> dict:
    payload = {
        "u": username,
        "r": role,
        "e": int(time.time() * 1000) + ttl_ms,
        "n": os.urandom(16).hex(),
        "s": scope,
    }
    body = b64url(json.dumps(payload, separators=(",", ":"),
                            ensure_ascii=False).encode("utf-8"))
    sig = hmac_sha256(body)
    return {"ticket": body + "." + sig, "expiresAt": payload["e"], "scope": scope}


def verify_ticket(ticket: str, want_scope: str = ""):
    """校验 HMAC 票据。返回 payload 或 None。定长比较，避免时序侧信道。"""
    if not ticket or not AUTH_SECRET:
        return None
    parts = ticket.split(".")
    if len(parts) != 2:
        return None
    body, sig = parts
    expect = hmac_sha256(body)
    if len(sig) != len(expect):
        return None
    if not hmac.compare_digest(sig, expect):
        return None
    try:
        payload = json.loads(b64url_decode(body).decode("utf-8"))
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    if not isinstance(payload.get("u"), str) or not payload.get("u"):
        return None
    if not isinstance(payload.get("e"), (int, float)):
        return None
    if time.time() * 1000 > payload["e"]:
        return None
    if want_scope and payload.get("s") != want_scope:
        return None
    return payload


# ====== Supabase REST ======
def rest(method: str, path: str, body=None, extra=None):
    headers = {"Content-Type": "application/json", "apikey": SERVICE_KEY}
    # secret key（sb_secret_）不是 JWT，不能放进 Authorization Bearer；legacy service_role JWT 可以
    if SERVICE_KEY and not SERVICE_KEY.startswith("sb_secret_"):
        headers["Authorization"] = "Bearer " + SERVICE_KEY
    if extra:
        headers.update(extra)
    url = SB_URL + "/rest/v1/" + path
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            txt = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        txt = e.read().decode("utf-8", "replace")
        raise RuntimeError("Supabase %s: %s" % (e.code, txt[:200]))
    if not txt.strip():
        return None
    try:
        return json.loads(txt)
    except Exception:
        return txt


def load_user(username: str):
    rows = rest(
        "GET",
        "app_users?username=eq.%s&select=username,password,role,created_by,created_at"
        % urllib.parse.quote(username, safe=""),
    )
    return rows[0] if isinstance(rows, list) and rows else None


def role_of(row, username: str) -> str:
    if username == ADMIN_USER:
        return "admin"
    return "admin" if (row or {}).get("role") == "admin" else "user"


def can_access(payload, target: str) -> bool:
    if not target:
        return False
    if payload.get("r") == "admin":
        return True
    return payload.get("u") == target


# ====== 业务 ======
def handle(p: dict) -> tuple:
    action = str((p or {}).get("action") or "")

    # ---------- 登录：账号密码换票据 ----------
    if action == "login":
        username = str(p.get("username") or "").strip()
        password = str(p.get("password") or "")
        if not username or not password:
            return {"ok": False, "error": "请填写账号和密码"}, 400
        if not _valid_username(username):
            return {"ok": False, "error": "账号不存在或密码错误"}, 401
        try:
            row = load_user(username)
        except Exception:
            # 读表失败 ≠ 密码错误：如实报告，避免误导用户反复改密码
            return {"ok": False, "error": "服务端暂时无法校验，请稍后重试"}, 503
        # 统一错误文案：不区分「账号不存在」与「密码错误」，避免账号枚举
        if not row or str(row.get("password") or "") != password:
            return {"ok": False, "error": "账号不存在或密码错误"}, 401
        role = role_of(row, username)
        t = sign_ticket(username, role, "session", SESSION_TTL_MS)
        return {"ok": True, "username": username, "role": role,
                "ticket": t["ticket"], "expiresAt": t["expiresAt"]}, 200

    # ---------- 健康探针（无需票据）----------
    if action == "ping":
        return {"ok": True, "service": "wb-auth-fc", "serverTime": int(time.time() * 1000)}, 200

    # ---------- 其余动作需要票据 ----------
    ticket = str(p.get("ticket") or "").strip()
    # ⚠️ scope 映射铁律（与 Edge 版一致）：
    #   tool_ticket 是「session 票 → tool 票」的**兑换入口**，验证时按 session scope；
    #   只有真正消费 tool 票的 tool_user_data / tool_set_user_data 才按 tool scope。
    #   若把 tool_ticket 也算成 tool → session 票永远换不到 tool 票 → 工具页死锁。
    scope = "tool" if action in ("tool_user_data", "tool_set_user_data") else "session"
    payload = verify_ticket(ticket, scope)
    if not payload:
        return {"ok": False, "error": "登录已失效，请重新登录"}, 401

    # ---------- 换工具页票据 ----------
    if action == "tool_ticket":
        t = sign_ticket(payload["u"], payload.get("r") or "user", "tool", TOOL_TTL_MS)
        return {"ok": True, "username": payload["u"], "role": payload.get("r"),
                "ticket": t["ticket"], "expiresAt": t["expiresAt"]}, 200

    # ---------- 会话自检 ----------
    if action == "session":
        return {"ok": True, "username": payload["u"], "role": payload.get("r"),
                "expiresAt": payload.get("e")}, 200

    # ---------- 读用户数据 ----------
    if action in ("get_user_data", "tool_user_data"):
        target = str(p.get("username") or payload["u"]).strip()
        if not can_access(payload, target):
            return {"ok": False, "error": "无权访问其他账号的数据"}, 403
        rows = rest(
            "GET",
            "user_data?username=eq.%s&select=username,data,updated_at"
            % urllib.parse.quote(target, safe=""),
        )
        row = rows[0] if isinstance(rows, list) and rows else None
        return {"ok": True, "username": target,
                "data": (row or {}).get("data") or {},
                "updated_at": (row or {}).get("updated_at")}, 200

    # ---------- 写用户数据（读-改-写，避免 jsonb 顶层替换冲掉其它配置）----------
    if action in ("set_user_data", "tool_set_user_data"):
        target = str(p.get("username") or payload["u"]).strip()
        if not can_access(payload, target):
            return {"ok": False, "error": "无权修改其他账号的数据"}, 403
        data = p.get("data")
        if not isinstance(data, dict):
            return {"ok": False, "error": "数据格式不正确"}, 400
        try:
            latest = rest(
                "GET",
                "user_data?username=eq.%s&select=username,data"
                % urllib.parse.quote(target, safe=""),
            )
            current = {}
            if isinstance(latest, list) and latest:
                current = latest[0].get("data") or {}
            merged = dict(current) if isinstance(current, dict) else {}
            merged.update(data)
            body = {"username": target, "data": merged,
                    "updated_at": int(time.time() * 1000)}
            upd = rest(
                "PATCH",
                "user_data?username=eq.%s" % urllib.parse.quote(target, safe=""),
                body, {"Prefer": "return=representation"},
            )
            if not (isinstance(upd, list) and upd):
                rest("POST", "user_data", body, {"Prefer": "return=representation"})
        except Exception as e:
            return {"ok": False, "error": "写入失败：%s" % str(e)[:160]}, 500
        return {"ok": True, "username": target}, 200

    # ---------- 用户列表（仅管理员，不下发 password）----------
    if action == "list_users":
        if payload.get("r") != "admin":
            return {"ok": False, "error": "仅管理员可查看用户列表"}, 403
        rows = rest("GET", "app_users?select=username,role,created_by,created_at&order=username.asc")
        users = {}
        admin = ADMIN_USER
        for r in (rows or []):
            if r.get("role") == "admin":
                admin = r.get("username")
            else:
                users[r.get("username")] = {
                    "createdBy": r.get("created_by"),
                    "createdAt": r.get("created_at"),
                }
        return {"ok": True, "admin": admin, "users": users}, 200

    # ---------- 新增用户（仅管理员）----------
    if action == "add_user":
        if payload.get("r") != "admin":
            return {"ok": False, "error": "仅管理员可新增用户"}, 403
        username = str(p.get("username") or "").strip()
        password = str(p.get("password") or "")
        if not _valid_username(username) or not password:
            return {"ok": False, "error": "用户名或密码不合法"}, 400
        try:
            if load_user(username):
                return {"ok": False, "error": "账号已存在"}, 409
            rest("POST", "app_users", {
                "username": username, "password": password, "role": "user",
                "created_by": payload["u"], "created_at": int(time.time() * 1000),
            })
        except Exception as e:
            return {"ok": False, "error": "新增失败：%s" % str(e)[:160]}, 500
        return {"ok": True, "username": username}, 200

    # ---------- 删除用户（仅管理员）----------
    if action == "delete_user":
        if payload.get("r") != "admin":
            return {"ok": False, "error": "仅管理员可删除用户"}, 403
        username = str(p.get("username") or "").strip()
        if not _valid_username(username):
            return {"ok": False, "error": "用户名不合法"}, 400
        try:
            rest("DELETE", "app_users?username=eq.%s"
                 % urllib.parse.quote(username, safe=""))
        except Exception as e:
            return {"ok": False, "error": "删除失败：%s" % str(e)[:160]}, 500
        return {"ok": True, "username": username}, 200

    # ---------- 重设密码（仅管理员）----------
    if action == "set_password":
        if payload.get("r") != "admin":
            return {"ok": False, "error": "仅管理员可重设密码"}, 403
        username = str(p.get("username") or "").strip()
        password = str(p.get("password") or "")
        if not _valid_username(username) or not password:
            return {"ok": False, "error": "用户名或密码不合法"}, 400
        try:
            rest("PATCH", "app_users?username=eq.%s"
                 % urllib.parse.quote(username, safe=""),
                 {"password": password}, {"Prefer": "return=representation"})
        except Exception as e:
            return {"ok": False, "error": "重设失败：%s" % str(e)[:160]}, 500
        return {"ok": True, "username": username}, 200

    return {"ok": False, "error": "未知操作：%s" % action[:60]}, 400


def _valid_username(u: str) -> bool:
    if not u or len(u) > 32:
        return False
    return all(ch.isalnum() and ch.isascii() or ch == "_" for ch in u)


# ====== FC HTTP 入口 ======
def _reply(body, code=200, headers=None):
    """返回 FC HTTP 触发器的响应体。

    ⚠️ 2026-11-17 实测：阿里云 FC **python3.10 runtime** 的 HTTP 触发器
       会把 handler 返回的 dict 当作「响应头映射」处理 —— 返回
       {"statusCode":..,"headers":..,"body":..} 会变成
       `statusCodeheadersbodyisBase64Encoded` 这种键名拼接的畸形响应。
       正确形态是 **(body, statusCode, headers) 元组**，由 FC 运行时识别为
       「响应体 + 状态码 + 响应头」。
    """
    hdrs = dict(CORS)
    hdrs["Content-Type"] = "application/json; charset=utf-8"
    if headers:
        hdrs.update(headers)
    return (body, code, hdrs)


def handler(event, context):
    """阿里云 FC HTTP 触发器入口。event 可能是 bytes/str/dict。"""
    # OPTIONS 预检
    raw = event
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8", "replace")
    if isinstance(raw, str):
        raw = raw.strip()
        try:
            raw = json.loads(raw) if raw else {}
        except Exception:
            raw = {}
    if not isinstance(raw, dict):
        raw = {}

    # FC 的 HTTP 触发器把请求信息放在 headers/query/body
    method = str((raw.get("httpMethod") or raw.get("method") or "POST")).upper()
    headers = raw.get("headers") or {}
    if isinstance(headers, list):  # 部分运行时给的是 [{key,value}]
        headers = {str(h.get("key")).lower(): h.get("value")
                   for h in headers if isinstance(h, dict)}
    else:
        headers = {str(k).lower(): v for k, v in headers.items()}

    if method == "OPTIONS":
        return _reply({"ok": True}, 200)

    # 解析 body
    p = {}
    if isinstance(raw.get("body"), (str, bytes, bytearray)):
        b = raw["body"]
        if isinstance(b, (bytes, bytearray)):
            b = b.decode("utf-8", "replace")
        b = b.strip()
        if b:
            try:
                p = json.loads(b)
            except Exception:
                p = {}
    elif isinstance(raw.get("body"), dict):
        p = raw["body"]
    if not p:
        # form 编码兜底
        q = raw.get("queryParameters") or raw.get("queryStringParameters") or {}
        if isinstance(q, dict) and q:
            p = dict(q)
    if not isinstance(p, dict):
        p = {}

    try:
        body, code = handle(p)
    except Exception as e:
        body, code = {"ok": False, "error": "服务端异常：%s" % str(e)[:160]}, 500
    return _reply(body, code)


if __name__ == "__main__":
    # 本地自测
    print(json.dumps(handle({"action": "ping"}), ensure_ascii=False))

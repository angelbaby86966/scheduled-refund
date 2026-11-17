#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
部署 wb-auth 鉴权网关的**境内镜像**到阿里云函数计算（FC）。

背景（2026-11-17）：
  主网关在 Supabase Edge Function（域名解析到 Cloudflare 国际 IP），
  部分中国大陆运营商线路不通 → 浏览器 "Failed to fetch" → 用户登不进去。
  本函数部署在阿里云境内节点，作为境内可达的备选入口。

与退订执行器的关系：
  · 复用同一个 FC 服务（scheduled-refund-svc），但**独立函数**（auth），
    独立 HTTP 触发器，互不影响。
  · 复用同一套凭据注入机制（merge_environment）：SUPABASE_SERVICE_ROLE_KEY
    + WB_AUTH_SECRET 从 GitHub Secrets 注入，绝不落源码。

用法：
  python3 ops/deploy_fc_auth.py --mode probe    # 只探测，不改动
  python3 ops/deploy_fc_auth.py --mode deploy   # 部署代码 + 建 HTTP 触发器
  python3 ops/deploy_fc_auth.py --mode disable  # 删除 HTTP 触发器（止血）
"""

import base64
import datetime
import hashlib
import hmac
import io
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

SERVICE = "scheduled-refund-svc"
FUNCTION = "auth"
HTTP_TRIGGER = "auth-http"
SRC_FILE = "fc/auth/auth_main.py"
CODE_ENTRY = "auth_main.py"
DESC = ("wb-auth 鉴权网关境内镜像（FC，HTTP 触发器）"
        "与 Edge 版共用 WB_AUTH_SECRET，票据互通 2026-11-17")

REGIONS = ["cn-hangzhou", "cn-shanghai", "cn-beijing", "cn-shenzhen",
           "cn-guangzhou", "cn-chengdu"]


def log(msg, level="INFO"):
    print("[%s] %s" % (level, msg), flush=True)


def pct(s):
    return urllib.parse.quote(str(s), safe="-_.~")


def build_code_zip(src_path):
    """把 Python 入口打成 zip（FC 要求 zipFile 为 zip 包，入口文件名必须是 auth_main.py）。

    ⚠️ fc2 SDK 的 codeZipFile 参数要的是**文件路径**，不能传 bytes
       （传 bytes 会报 "[Errno 36] File name too long"）。
    """
    if not os.path.isfile(src_path):
        raise SystemExit("找不到源码 %s" % src_path)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(src_path, arcname=CODE_ENTRY)
    out = "/tmp/fc_auth_python_code.zip"
    with open(out, "wb") as f:
        f.write(buf.getvalue())
    log("代码包已生成：%d 字节（入口 %s，零第三方依赖）" % (os.path.getsize(out), CODE_ENTRY))
    return out


def sts_account_id(ak, sk):
    """通过 STS GetCallerIdentity 取主账号 UID，用于构造 <uid>.<region>.fc.aliyuncs.com。

    ⚠️ 直接复用 deploy_fc_refund.py 里**已线上验证可用**的实现（阿里云官方简化签名：
    key = sk + "&"，不是 AWS 风格的派生 key）。不要重写。
    """
    params = {
        "Action": "GetCallerIdentity",
        "Version": "2015-04-01",
        "Format": "JSON",
        "AccessKeyId": ak,
        "SignatureMethod": "HMAC-SHA1",
        "SignatureNonce": uuid.uuid4().hex,
        "SignatureVersion": "1.0",
        "Timestamp": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    canonical = "&".join(pct(k) + "=" + pct(v) for k, v in sorted(params.items()))
    sts = "GET&" + pct("/") + "&" + pct(canonical)
    sig = base64.b64encode(
        hmac.new((sk + "&").encode(), sts.encode(), hashlib.sha1).digest()).decode()
    url = "https://sts.aliyuncs.com/?" + canonical + "&Signature=" + pct(sig)
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            data = json.loads(r.read().decode())
        return str(data.get("AccountId") or "")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        log("STS 返回 HTTP %s（用于判断 AK/SK 是否有效）：%s" % (e.code, body), "WARN")
        return ""
    except Exception as e:
        log("STS 取 AccountId 失败：%s: %s" % (type(e).__name__, e), "WARN")
        return ""


def find_function(ak, sk, fc2, want=None):
    """遍历地域 × endpoint 候选，返回 (client, region, info)。

    ⚠️ 关键：auth 是**新函数**，get_function 会 404 → 不能用「函数是否存在」
       来判断 endpoint 是否可达。改为：先用 DNS 过滤出可解析的 endpoint，
       再对每个 endpoint 调 get_service（服务必然存在）验证连通性。
    """
    uid = sts_account_id(ak, sk)
    if uid:
        log("STS AccountId 已获取（%s***）" % uid[:4])

    targets = [want] if want else REGIONS
    endpoints = []
    for region in targets:
        endpoints.append((region, "https://fc-open.%s.aliyuncs.com" % region))
        if uid:
            endpoints.append((region, "https://%s.%s.fc.aliyuncs.com" % (uid, region)))

    # DNS 预过滤：解析不了的 host 直接跳过，避免 urllib3 指数退避白等
    reachable = []
    for region, ep in endpoints:
        host = ep.split("//")[1]
        try:
            socket.gethostbyname(host)
            reachable.append((region, ep))
        except socket.gaierror:
            log("  × %s / %s: DNS 不解析，跳过" % (region, host), "DEBUG")
    log("可解析的 FC endpoint：%d 个" % len(reachable))

    for region, ep in reachable:
        try:
            client = fc2.Client(endpoint=ep, accessKeyID=ak,
                                accessKeySecret=sk, timeout=8)
            # 用 get_service 探活（服务一定存在），而不是 get_function
            client.get_service(SERVICE)
            log("✅ endpoint 可用：region=%s endpoint=%s" % (region, ep))
            try:
                info = client.get_function(SERVICE, FUNCTION)
                log("   函数 %s 已存在" % FUNCTION)
            except Exception:
                info = None
                log("   函数 %s 尚不存在（将新建）" % FUNCTION)
            return client, region, info
        except Exception as e:
            msg = str(e)[:200].replace(ak, "***").replace(sk, "***")
            log("  × %s / %s: %s %s" % (region, ep.split("//")[1],
                                        type(e).__name__, msg), "DEBUG")
    raise SystemExit(
        "所有可解析的 FC endpoint 都未命中服务 %s。\n"
        "可能原因：① ALIYUN_AK/SK 失效或无 FC 权限；② 服务已删除；"
        "③ 服务在其它地域，可在 REGIONS 常量补充。" % SERVICE)


def merge_environment(client, ak, sk):
    """注入环境变量：service_role + WB_AUTH_SECRET（都来自 GitHub Secrets）。"""
    env = {}
    try:
        cur = client.get_function(SERVICE, FUNCTION)
        for e in (getattr(cur, "data", {}) or {}).get("environmentVariables", {}) or {}:
            env[str(e.get("key"))] = str(e.get("value") or "")
    except Exception:
        pass

    srk = (os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or "").strip()
    if srk:
        env["SUPABASE_SERVICE_ROLE_KEY"] = srk
        log("service_role=已注入")
    else:
        log("⚠️ 未提供 SUPABASE_SERVICE_ROLE_KEY，沿用 FC 上已有值", "WARN")

    wbs = (os.environ.get("WB_AUTH_SECRET") or "").strip()
    if wbs:
        env["WB_AUTH_SECRET"] = wbs
        log("WB_AUTH_SECRET=已注入")
    else:
        log("⚠️ 未提供 WB_AUTH_SECRET，沿用 FC 上已有值", "WARN")

    env.setdefault("SUPABASE_URL", "https://opauwtkivhjxlijfqaix.supabase.co")
    return env


def ensure_http_trigger(client, region):
    """确保 HTTP 触发器存在（公网匿名访问，走 CORS）。"""
    try:
        client.delete_trigger(SERVICE, FUNCTION, HTTP_TRIGGER)
        log("已删除同名旧触发器（幂等）")
    except Exception:
        pass
    resp = client.create_trigger(
        SERVICE, FUNCTION, HTTP_TRIGGER,
        triggerType="http",
        triggerConfig={
            "authType": "anonymous",
            "disableInternet": False,
            "methods": ["POST", "OPTIONS"],
            "headers": [],
        },
    )
    data = getattr(resp, "data", {}) or {}
    log("✅ HTTP 触发器已创建：%s url=%s" % (HTTP_TRIGGER, data.get("url")))


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["probe", "deploy", "disable"], default="deploy")
    args = ap.parse_args()

    ak = os.environ.get("ALIYUN_AK", "").strip()
    sk = os.environ.get("ALIYUN_SK", "").strip()
    if not ak or not sk:
        raise SystemExit("缺少 ALIYUN_AK / ALIYUN_SK（GitHub Actions Secrets）")

    try:
        import fc2
    except ImportError:
        raise SystemExit("缺少 aliyun-fc2，请 pip install aliyun-fc2==2.5.2")

    client, region, info = find_function(ak, sk, fc2)
    data = getattr(info, "data", {}) or {} if info is not None else {}
    log("函数当前配置：runtime=%s handler=%s codeSize=%s"
        % (data.get("runtime"), data.get("handler"), data.get("codeSize")))

    if args.mode == "probe":
        log("探测完成（未改动线上代码）", "SUCCESS")
        return

    if args.mode == "disable":
        try:
            client.delete_trigger(SERVICE, FUNCTION, HTTP_TRIGGER)
            log("已删除 HTTP 触发器 %s" % HTTP_TRIGGER, "SUCCESS")
        except Exception as e:
            log("删除失败（可能已不存在）：%s" % str(e)[:120], "WARN")
        return

    src = os.path.join(os.getcwd(), SRC_FILE)
    code = build_code_zip(src)

    env = merge_environment(client, ak, sk)

    # 首次部署时函数可能还不存在 → 先建后更
    try:
        resp = client.update_function(SERVICE, FUNCTION, codeZipFile=code,
                                      environmentVariables=env, description=DESC)
        d = getattr(resp, "data", {}) or {}
        log("✅ FC 代码已更新：codeSize=%s checksum=%s handler=%s runtime=%s"
            % (d.get("codeSize"), d.get("codeChecksum"), d.get("handler"), d.get("runtime")))
    except Exception as e:
        log("update_function 失败（%s），尝试创建新函数" % str(e)[:120], "WARN")
        resp = client.create_function(
            SERVICE, FUNCTION,
            runtime="python3.10",
            handler="auth_main.handler",
            codeZipFile=code,
            environmentVariables=env,
            description=DESC,
        )
        d = getattr(resp, "data", {}) or {}
        log("✅ FC 函数已创建：codeSize=%s handler=%s" % (d.get("codeSize"), d.get("handler")))

    ensure_http_trigger(client, region)
    log("境内镜像版鉴权网关部署完成", "SUCCESS")


if __name__ == "__main__":
    main()

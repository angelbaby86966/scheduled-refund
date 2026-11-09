#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 fc/refund/fc_main.py 部署到阿里云 FC 的 scheduled-refund-svc/refund。

2026-11-09 二次根治（重要纠偏）：
  FC 线上实际是 **python3.10 / handler=fc_main.handler**，不是 nodejs20。
  旧版脚本会打包 Node 版 fc/refund/index.js 推上去，函数会直接跑不起来。
  线上真实代码是 46KB 的 Python 全功能版，且**不读排除名单**，DRY_RUN=false，
  23:35 主触发器 + 23:50 fallback 触发器都启用 —— 这才是 11-08 晚误退排除实例的真凶。

本脚本现在做三件事：
  1) 用仓库 Secrets 的 ALIYUN_AK / ALIYUN_SK（2026-11-09 起为「张瑞瑶61」）探测函数；
  2) 上传修补版 fc_main.py（排除实例保护三层拦截 + fail-closed + IMMEDIATE 残留修复）；
  3) 同步函数环境变量：新 AK/SK，以及从 Supabase 实时读取的「排除文本框」名单快照。
     ⚠️ 该快照只用于日志核对/诊断，**不参与放行**：三套执行器一律以 Supabase
     实时名单为准，否则用户在前端删掉某台后 FC 仍按旧快照保护，行为不一致。

用法（由 .github/workflows/deploy-fc-refund.yml 调用）：
  python3 ops/deploy_fc_refund.py --mode probe           # 只探测函数所在地域/endpoint
  python3 ops/deploy_fc_refund.py --mode deploy          # 上传修补版代码 + 同步环境变量
  python3 ops/deploy_fc_refund.py --mode disable-trigger # 兜底：删除两个定时触发器（止血）

绝不打印 AK/SK 明文。
"""
import argparse
import base64
import datetime
import hashlib
import hmac
import io
import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

SERVICE = "scheduled-refund-svc"
FUNCTION = "refund"
TRIGGERS = ["refund-trigger", "refund-trigger-fallback"]
SRC_FILE = "fc/refund/fc_main.py"
CODE_ENTRY = "fc_main.py"
DEFAULT_ANON_KEY = "sb_publishable_SM9yvpcOBqvVPH2oGwTmFg_BZ1Lz9Xd"
DESC = "定时退订(张瑞瑶61) 排除实例保护 v2026-11-09b（凭证按 Supabase 档案，DRY_RUN=false）"

# 只探测 FC 实际开通的主要地域；小地域的 fc-open 域名根本不解析，
# 老版脚本逐台等 DNS 重试会白跑 10 分钟。
REGIONS = ["cn-hangzhou", "cn-shanghai", "cn-beijing", "cn-shenzhen",
           "cn-guangzhou", "cn-chengdu"]


def log(msg, level="INFO"):
    print(f"[{level}] {msg}", flush=True)


def pct(s):
    return urllib.parse.quote(str(s), safe="-_.~")


def sts_account_id(ak, sk):
    """通过 STS GetCallerIdentity 取主账号 UID，用于构造 <uid>.<region>.fc.aliyuncs.com。"""
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
    sig = base64.b64encode(hmac.new((sk + "&").encode(), sts.encode(), hashlib.sha1).digest()).decode()
    url = "https://sts.aliyuncs.com/?" + canonical + "&Signature=" + pct(sig)
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            data = json.loads(r.read().decode())
        return str(data.get("AccountId") or "")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        log(f"STS 返回 HTTP {e.code}（用于判断 AK/SK 是否有效）：{body}", "WARN")
        return ""
    except Exception as e:
        log(f"STS 取 AccountId 失败（不影响后续探测）：{type(e).__name__}: {e}", "WARN")
        return ""


def build_code_zip(src_path):
    """把 Python 入口打成 zip（FC 要求 zipFile 为 zip 包，入口文件名必须是 fc_main.py）。"""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(src_path, arcname=CODE_ENTRY)
    out = "/tmp/fc_refund_python_code.zip"
    with open(out, "wb") as f:
        f.write(buf.getvalue())
    return out


def find_function(ak, sk, fc2):
    """遍历地域 × endpoint 候选，返回 (client, region, info)。"""
    uid = sts_account_id(ak, sk)
    if uid:
        log(f"STS AccountId 已获取（{uid[:4]}***）")
    # 先用 DNS 过滤：解析不了的 host 直接跳过，避免 urllib3 5 次指数退避白等 30 秒
    endpoints = []
    for region in REGIONS:
        endpoints.append((region, f"https://fc-open.{region}.aliyuncs.com"))
        if uid:
            endpoints.append((region, f"https://{uid}.{region}.fc.aliyuncs.com"))
    reachable = []
    for region, ep in endpoints:
        host = ep.split("//")[1]
        try:
            socket.gethostbyname(host)
            reachable.append((region, ep))
        except socket.gaierror:
            log(f"  × {region} / {host}: DNS 不解析，跳过", "DEBUG")
    log(f"可解析的 FC endpoint：{len(reachable)} 个")

    for region, ep in reachable:
        try:
            client = fc2.Client(endpoint=ep, accessKeyID=ak,
                                accessKeySecret=sk, Timeout=8)
            info = client.get_function(SERVICE, FUNCTION)
            log(f"✅ 找到函数：region={region} endpoint={ep}")
            return client, region, info
        except Exception as e:
            msg = str(e)[:300].replace(ak, "***").replace(sk, "***")
            log(f"  × {region} / {ep.split('//')[1]}: {type(e).__name__} {msg}", "DEBUG")
    raise RuntimeError(
        "所有可解析的 FC endpoint 都未找到 scheduled-refund-svc/refund。\n"
        "可能原因：① 仓库 Secrets 的 ALIYUN_AK/SK 已失效或无 FC 读权限；"
        "② FC 服务/函数已被删除；③ 函数在其它地域，可在脚本 REGIONS 常量里补充。\n"
        "兜底：到 FC 控制台把 fc_main.py 替换为仓库 fc/refund/fc_main.py，"
        "或停用 refund-trigger / refund-trigger-fallback。")


def fetch_exclude_ids(anon_key, supabase_url):
    """实时读取前端「排除实例」文本框内容（全局合并所有用户）。"""
    url = supabase_url.rstrip("/") + "/rest/v1/user_data?select=username,data"
    req = urllib.request.Request(url, headers={
        "apikey": anon_key, "Authorization": "Bearer " + anon_key})
    with urllib.request.urlopen(req, timeout=15) as r:
        rows = json.loads(r.read().decode())
    ids = set()
    for row in rows or []:
        raw = ((row or {}).get("data") or {}).get("schedule_exclude_instance_ids")
        if isinstance(raw, list):
            ids |= {str(x).strip() for x in raw if isinstance(x, str) and x.strip()}
        elif isinstance(raw, str):
            ids |= {x.strip() for x in raw.replace("；", ",").replace("，", ",").split(",") if x.strip()}
        elif isinstance(raw, dict):
            ids |= {str(k).strip() for k in raw if str(k).strip()}
    return ids


def merge_environment(client, ak, sk):
    """回读现有环境变量并合并新凭证 + 文本框兜底名单（FC 是全量替换，必须带原值）。"""
    cur = getattr(client.get_function(SERVICE, FUNCTION), "data", {}) or {}
    env = dict(cur.get("environmentVariables") or {})
    anon = env.get("SUPABASE_ANON_KEY") or os.environ.get("SUPABASE_ANON_KEY") or DEFAULT_ANON_KEY
    supa = env.get("SUPABASE_URL") or "https://opauwtkivhjxlijfqaix.supabase.co"
    ids = fetch_exclude_ids(anon, supa)
    if not ids:
        raise RuntimeError("Supabase 未读到任何排除实例 ID，拒绝部署（避免上线一份没有兜底的版本）")
    env.update({
        "ALIYUN_AK": ak,
        "ALIYUN_SK": sk,
        "EXCLUDE_INSTANCE_IDS": ",".join(sorted(ids)),
        "EXCLUDE_PROTECT_VERSION": "2026-11-09-fc-python-v2",
    })
    log(f"环境变量合并完成：共 {len(env)} 项，文本框排除 ID {len(ids)} 个；"
        f"DRY_RUN={env.get('DRY_RUN')}")
    return env, len(ids), cur


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["probe", "deploy", "disable-trigger"], default="deploy")
    args = ap.parse_args()

    ak = os.environ.get("ALIYUN_AK", "").strip()
    sk = os.environ.get("ALIYUN_SK", "").strip()
    if not ak or not sk:
        log("缺少 ALIYUN_AK / ALIYUN_SK 环境变量（GitHub Actions Secrets）", "ERROR")
        sys.exit(1)

    try:
        import fc2
    except ImportError:
        log("缺少 aliyun-fc2，请先 pip install aliyun-fc2==2.5.2", "ERROR")
        sys.exit(1)

    client, region, info = find_function(ak, sk, fc2)
    data = getattr(info, "data", {}) or {}
    log(f"函数当前配置：runtime={data.get('runtime')} handler={data.get('handler')} "
        f"codeSize={data.get('codeSize')}")
    if data.get("runtime") != "python3.10" or data.get("handler") != "fc_main.handler":
        raise RuntimeError("线上 runtime/handler 与 Python 修补版不匹配，拒绝部署（防止推错代码）")

    if args.mode == "probe":
        log("探测完成（未改动线上代码）", "SUCCESS")
        return

    if args.mode == "disable-trigger":
        for name in TRIGGERS:
            try:
                client.delete_trigger(SERVICE, FUNCTION, name)
                log(f"已删除触发器 {name}", "SUCCESS")
            except Exception as e:
                log(f"删除触发器 {name} 失败（可能已不存在）：{type(e).__name__} {str(e)[:120]}", "WARN")
        log("FC 两个定时触发器已停用，定时退订由已修复的 Actions / Edge Function 接管", "SUCCESS")
        return

    src = os.path.join(os.getcwd(), SRC_FILE)
    if not os.path.isfile(src):
        log(f"找不到源码 {src}", "ERROR")
        sys.exit(1)
    zip_path = build_code_zip(src)
    log(f"代码包已生成：{os.path.getsize(zip_path)} 字节（入口 {CODE_ENTRY}，零第三方依赖）")

    env, n, _cur = merge_environment(client, ak, sk)
    resp = client.update_function(SERVICE, FUNCTION, codeZipFile=zip_path,
                                  environmentVariables=env, description=DESC)
    d = getattr(resp, "data", {}) or {}
    log(f"✅ FC 代码已更新：codeSize={d.get('codeSize')} checksum={d.get('codeChecksum')} "
        f"handler={d.get('handler')} runtime={d.get('runtime')}", "SUCCESS")
    log(f"✅ 排除文本框 {n} 个实例 ID 已写入 EXCLUDE_INSTANCE_IDS（部署快照，仅供核对）")
    log("修补版：三层拦截 + fail-closed + 分页/空转修复 + IMMEDIATE 残留修复；"
        "权威名单始终是 Supabase 实时数据")


if __name__ == "__main__":
    main()

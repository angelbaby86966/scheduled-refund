#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 fc/refund/index.js 部署到阿里云 FC 的 scheduled-refund-svc/refund 函数。

用途（2026-11-09 事故根治）：FC 是独立于仓库的第三套定时退订执行器，代码不会随
GitHub 自动更新。本脚本通过官方 aliyun-fc2 SDK 用仓库 Secrets 的 AK/SK 上传修补版代码，
让 FC 也读取 schedule_exclude_instance_ids 并 fail-closed 保护排除实例。

用法（由 .github/workflows/deploy-fc-refund.yml 调用）：
  python3 ops/deploy_fc_refund.py --mode probe           # 只探测函数所在地域/endpoint
  python3 ops/deploy_fc_refund.py --mode deploy          # 上传修补版代码
  python3 ops/deploy_fc_refund.py --mode disable-trigger # 兜底：删除定时触发器（止血）

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
TRIGGER = "refund-trigger"
SRC_FILE = "fc/refund/index.js"

# 只探测 FC 实际开通的主要地域；小地域的 fc-open 域名根本不解析，
# 老版脚本逐台等 DNS 重试会白跑 10 分钟。
REGIONS = ["cn-hangzhou", "cn-shanghai", "cn-beijing", "cn-shenzhen",
           "cn-guangzhou", "cn-chengdu"]


def log(msg, level="INFO"):
    print(f"[{level}] {msg}", flush=True)


def pct(s):
    return urllib.parse.quote(str(s), safe="-_.~")


def sts_account_id(ak, sk):
    """可选：通过 STS GetCallerIdentity 取主账号 UID，用于构造 <uid>.<region>.fc.aliyuncs.com。"""
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
    """把单个 index.js 打成一个 zip（FC 要求 zipFile 为 zip 包 base64）。"""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(src_path, arcname="index.js")
    out = "/tmp/fc_refund_code.zip"
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
                                accessKeySecret=sk, Timeout=5)
            info = client.get_function(SERVICE, FUNCTION)
            log(f"✅ 找到函数：region={region} endpoint={ep}")
            return client, region, info
        except Exception as e:
            msg = str(e)[:300].replace(ak, "***").replace(sk, "***")
            log(f"  × {region} / {ep.split('//')[1]}: {type(e).__name__} {msg}", "DEBUG")
    raise RuntimeError(
        "所有可解析的 FC endpoint 都未找到 scheduled-refund-svc/refund。\n"
        "可能原因：① 仓库 Secrets 的 ALIYUN_AK/SK 已失效或无 FC 读权限；"
        "② FC 服务/函数已被删除（心跳停在 2026-09-15，很可能已停跑）；"
        "③ 函数在其它地域，可用 --regions 指定。\n"
        "兜底：到 FC 控制台把 refund 函数代码替换为 "
        "https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@9e94c2ff9c226035a9a04088f02023d871dabb52/fc/refund/index.js "
        "或直接停用 refund-trigger。")


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

    if args.mode == "probe":
        log("探测完成（未改动线上代码）", "SUCCESS")
        return

    if args.mode == "disable-trigger":
        client.delete_trigger(SERVICE, FUNCTION, TRIGGER)
        log(f"已删除触发器 {TRIGGER} —— FC 定时退订停止，由已修复的 Actions / Edge Function 接管", "SUCCESS")
        return

    src = os.path.join(os.getcwd(), SRC_FILE)
    if not os.path.isfile(src):
        log(f"找不到源码 {src}", "ERROR")
        sys.exit(1)
    zip_path = build_code_zip(src)
    log(f"代码包已生成：{os.path.getsize(zip_path)} 字节（单文件 index.js，零第三方依赖）")

    # 只传 codeZipFile：SDK 只序列化非空字段，不会清空 runtime / handler / 环境变量
    resp = client.update_function(SERVICE, FUNCTION, codeZipFile=zip_path)
    d = getattr(resp, "data", {}) or {}
    log(f"✅ FC 代码已更新：codeSize={d.get('codeSize')} checksum={d.get('codeChecksum')} "
        f"handler={d.get('handler')} runtime={d.get('runtime')}", "SUCCESS")
    log("修补版已读取 schedule_exclude_instance_ids，且名单读取失败时拒绝任何退订（fail-closed）")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
定时退订脚本（服务端版 / GitHub Actions 驱动）

功能：
  1. 读取 Supabase `user_data` 中所有「已开启定时退订」的用户
  2. 对每个用户，用其阿里云 AK/SK 列出全部地域的轻量应用服务器实例
  3. 调用 BSS OpenAPI `RefundInstance`（ProductCode=ace_eweb）退订，退款到原账户
  4. 退订成功后把 `schedule_last_executed_date` 写为当天（北京时间），防止同日重复

设计要点（与前端 app.js / aliyun-client-v2.js 完全一致）：
  - 阿里云签名：HMAC-SHA1，待签串 'POST&' + encode('/') + '&' + encode(canonical)
  - 所有地域并行、每批 50 台、批间间隔 3 秒
  - BSS 「锁定/不可退」错误不再重试，已退订/不存在视为跳过
  - 时间口径统一用【北京时间 Asia/Shanghai】

安全说明：
  - 仅用前端公开的 Supabase anon key 读写 `user_data`（与浏览器行为一致，无新密钥）
  - AK/SK 从用户云端 data 中读，脚本只读取并执行，与前端做的事完全一致
  - 不打印任何 AK/SK 明文

依赖：仅 Python 3.8+ 标准库（urllib / hmac / hashlib / base64 / json / uuid / datetime）
"""

import os
import sys
import json
import time
import uuid
import datetime
import hmac
import hashlib
import base64
import fcntl
import urllib.parse
import urllib.request
import urllib.error

# ===================== 配置 =====================
SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://vgddxxgjcogxcpiycsej.supabase.co")
SUPABASE_ANON_KEY = os.environ.get(
    "SUPABASE_ANON_KEY", "sb_publishable_AqRbhxlzaDzPNR1nZTw-4A_c1VQ1Nch"
)
REST_BASE = SUPABASE_URL.rstrip("/") + "/rest/v1"

# 支持的地域（与前端 REGION_INFO 一致）
REGION_INFO = {
    "cn-hangzhou": "杭州",
    "cn-beijing": "北京",
    "cn-shanghai": "上海",
    "cn-shenzhen": "深圳",
    "cn-chengdu": "成都",
    "cn-guangzhou": "广州",
}

# BSS 退订（锁定）错误模式（与前端 BSS_LOCKED_PATTERNS 一致）
BSS_LOCKED_PATTERNS = [
    "NoApplicable", "NotApplicable", "ExceedRefundQuota", "ExistUnPaidOrder",
    "ExistRefundingOrder", "NoRestValue", "AmbassadorOrderLimit", "ActivityForbidden",
    "CommodityNotSupported", "ProductCheckError", "MissingRefundAmount", "InvalidPayMethod",
    "CannotDeleteInstance", "RefundFailed", "NoFullRefund", "非全额退款", "非全额退订",
    "订单未到期", "订单到期", "尚未结算", "InstanceHasUnsettledBill", "PayMethodNotSupported",
    "请先退订订单",
]
# 已退订 / 不存在 视为跳过
BSS_SKIP_PATTERNS = ["ResourceNotExists", "已退订", "不存在", "InvalidInstanceId", "InstanceNotExists"]


# ===================== 工具 =====================
def log(msg, level="INFO"):
    ts = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime("%H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", flush=True)


def beijing_now():
    return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))


def beijing_date_str():
    return beijing_now().strftime("%Y-%m-%d")


def percent_encode(s):
    # 与前端 encodeURIComponent 后替换 ! ' ( ) * 等价：仅保留 - _ . ~ 不编码
    return urllib.parse.quote(str(s), safe="-_.~")


def sign(secret, string_to_sign):
    key = (secret + "&").encode("utf-8")
    raw = string_to_sign.encode("utf-8")
    digest = hmac.new(key, raw, hashlib.sha1).digest()
    return base64.b64encode(digest).decode("ascii")


def iso_timestamp():
    # 与前端 new Date().toISOString().replace(/\.\d{3}Z$/, 'Z') 一致
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def classify(err_msg):
    for p in BSS_SKIP_PATTERNS:
        if p in err_msg:
            return "skipped"
    for p in BSS_LOCKED_PATTERNS:
        if p in err_msg:
            return "locked"
    return "fail"


# ===================== 阿里云 RPC =====================
def rpc(ak, sk, endpoint, action, version, params):
    """通用阿里云 RPC 调用（POST + form-urlencoded），返回解析后的 JSON dict。"""
    common = {
        "AccessKeyId": ak,
        "Format": "JSON",
        "SignatureMethod": "HMAC-SHA1",
        "SignatureNonce": str(uuid.uuid4()),
        "SignatureVersion": "1.0",
        "Timestamp": iso_timestamp(),
        "Version": version,
        "Action": action,
    }
    all_params = dict(common)
    all_params.update(params)

    parts = []
    for k in sorted(all_params.keys()):
        v = all_params[k]
        if v is None:
            continue
        parts.append(percent_encode(k) + "=" + percent_encode(v))
    canonical = "&".join(parts)
    string_to_sign = "POST&" + percent_encode("/") + "&" + percent_encode(canonical)
    signature = sign(sk, string_to_sign)
    body = canonical + "&" + percent_encode("Signature") + "=" + percent_encode(signature)

    req = urllib.request.Request(
        endpoint,
        data=body.encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
    try:
        return json.loads(raw)
    except Exception:
        return {"_raw": raw, "Code": "ParseError"}


def swas_endpoint(region_id):
    return f"https://swas.{region_id}.aliyuncs.com/"


def list_instances(ak, sk, region_id):
    """分页列出某地域全部实例，返回 [{regionId, instanceId}, ...]"""
    out = []
    page = 1
    while True:
        data = rpc(ak, sk, swas_endpoint(region_id), "ListInstances", "2020-06-01",
                   {"PageNumber": page, "PageSize": 100})
        if data.get("Code") and data.get("Code") not in ("200", "Success", None):
            raise RuntimeError(f"ListInstances 失败: {data.get('Message') or data.get('Code')}")
        insts = data.get("Instances") or []
        for it in insts:
            iid = it.get("InstanceId")
            if iid:
                out.append({"regionId": region_id, "instanceId": iid})
        total = data.get("TotalCount") or 0
        if not insts or len(out) >= total:
            break
        page += 1
    return out


def refund_instance(ak, sk, region_id, instance_id):
    """调用 BSS RefundInstance（与前端 refundInstance 完全一致）。返回 (ok, kind, msg)。"""
    params = {
        "InstanceId": instance_id,
        "ProductCode": "ace_eweb",
        "ProductType": "",  # 与前端保持一致：空串也参与签名
        "ImmediatelyRelease": "1",
        "ClientToken": "wb-" + str(int(time.time() * 1000)) + "-" + uuid.uuid4().hex[:7],
    }
    data = rpc(ak, sk, "https://business.aliyuncs.com/", "RefundInstance", "2017-12-14", params)
    # 成功判定（与前端一致）：Success 为真，或 Code==ResourceNotExists（已退/不存在）
    if data.get("Success") or data.get("Code") == "ResourceNotExists":
        return True, "ok", data.get("Message") or "success"
    code = data.get("Code") or "Unknown"
    msg = data.get("Message") or code
    kind = classify(msg)
    return False, kind, msg


# ===================== Supabase =====================
def supabase_get_all_user_data():
    url = REST_BASE + "/user_data?select=username,data"
    req = urllib.request.Request(url, headers={
        "apikey": SUPABASE_ANON_KEY,
        "Authorization": "Bearer " + SUPABASE_ANON_KEY,
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def supabase_patch_schedule_date(username, full_data, today_str):
    url = REST_BASE + "/user_data?username=eq." + urllib.parse.quote(username)
    body = json.dumps({
        "username": username,
        "data": full_data,
        "updated_at": int(time.time() * 1000),
    }).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="PATCH", headers={
        "apikey": SUPABASE_ANON_KEY,
        "Authorization": "Bearer " + SUPABASE_ANON_KEY,
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    })
    try:
        urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as e:
        log(f"  更新 {username} 执行日期失败: HTTP {e.code}", "WARN")


# ===================== 凭证解析 =====================
def resolve_ak_sk(data):
    """从 user_data.data 解析出当前生效的 AK/SK（与前端 getActiveProfile 逻辑一致）。"""
    profiles = data.get("ak_profiles")
    if isinstance(profiles, list) and profiles:
        active = data.get("ak_active")
        p = next((x for x in profiles if x.get("name") == active), profiles[0])
        return p.get("ak_id", ""), p.get("ak_secret", "")
    return data.get("ak_id", ""), data.get("ak_secret", "")


# ===================== 主流程 =====================
def build_credentials(data):
    """返回 [(label, ak, sk), ...]：遍历 ak_profiles 全部凭证并按 AK 去重（重复凭证只退一次），否则退回 legacy 单凭证。"""
    creds = []
    seen_ak = set()
    dup = 0
    profiles = data.get("ak_profiles")
    if isinstance(profiles, list):
        for p in profiles:
            ak = (p.get("ak_id") or "").strip()
            sk = (p.get("ak_secret") or "").strip()
            if ak and sk:
                if ak in seen_ak:
                    dup += 1
                    continue
                seen_ak.add(ak)
                creds.append((p.get("name") or "?", ak, sk))
    if not creds:
        ak = (data.get("ak_id") or "").strip()
        sk = (data.get("ak_secret") or "").strip()
        if ak and sk:
            creds.append(("legacy", ak, sk))
    if dup:
        log(f"  ⚠️ 该账号存在 {dup} 个重复凭证（相同 AK），已去重，仅退一次", "WARN")
    return creds


def drain_credential(username, label, ak, sk, max_rounds=12):
    """退单凭证：每轮「列出全部地域实例 → 批量退订 → 复查」。
    直到该凭证名下再无实例，才返回 —— 即「先把这一个凭证退干净，再退下一个凭证」，
    避免退到一半被窗口关闭打断导致同账号内有的凭证退完、有的没退。
    """
    total = {"success": 0, "skipped": 0, "locked": 0, "fail": 0}
    for rnd in range(1, max_rounds + 1):
        # 1) 列出本轮该凭证的全部实例
        all_instances = []
        for rid in REGION_INFO.keys():
            try:
                insts = list_instances(ak, sk, rid)
                all_instances.extend(insts)
            except Exception as e:
                log(f"  ⚠️ [{label}][{REGION_INFO[rid]}] 列举失败: {e}", "WARN")

        if not all_instances:
            log(f"  ✅ 凭证「{label}」第 {rnd} 轮复查：已无实例（退订完成）", "SUCCESS")
            break

        # 2) 批量退订本轮查到的实例
        by_region = {}
        for it in all_instances:
            by_region.setdefault(it["regionId"], []).append(it)

        round_success = 0
        BATCH = 50
        for rid, arr in by_region.items():
            region_name = REGION_INFO.get(rid, rid)
            log(f"  🌏 [{label}][{region_name}] 第 {rnd} 轮：{len(arr)} 台，分 { (len(arr)+BATCH-1)//BATCH } 批退订", "INFO")
            for i in range(0, len(arr), BATCH):
                slice_ = arr[i:i + BATCH]
                for it in slice_:
                    try:
                        ok, kind, msg = refund_instance(ak, sk, rid, it["instanceId"])
                    except Exception as e:
                        ok, kind, msg = False, "fail", str(e)
                    if kind == "skipped":
                        total["skipped"] += 1
                        log(f"  ⚪ [{label}][{region_name}] {it['instanceId']}: 已退订/不存在，跳过", "INFO")
                    elif kind == "locked":
                        total["locked"] += 1
                        log(f"  🔒 [{label}][{region_name}] {it['instanceId']}: {msg}（跳过，不再重试）", "WARN")
                    elif ok:
                        total["success"] += 1
                        round_success += 1
                        log(f"  ✅ [{label}][{region_name}] {it['instanceId']} 退订成功", "SUCCESS")
                    else:
                        total["fail"] += 1
                        log(f"  ❌ [{label}][{region_name}] {it['instanceId']}: {msg}", "ERROR")
                if i + BATCH < len(arr):
                    time.sleep(3)

        # 3) 复查：本轮退完，先让阿里云侧状态刷新，下一轮再列出看是否还有剩余
        log(f"  🔁 凭证「{label}」第 {rnd} 轮：退订 {round_success} 台，累计成功 {total['success']}（继续复查…）", "INFO")
        time.sleep(2)
    else:
        log(f"  ⚠️ 凭证「{label}」达到最大轮数 {max_rounds} 仍有实例，停止本轮以免死循环", "WARN")

    log(f"🏁 凭证「{label}」退订完成：成功 {total['success']} 跳过 {total['skipped']} 锁定 {total['locked']} 失败 {total['fail']}",
        "SUCCESS" if total["fail"] == 0 else "WARN")
    return total


def process_user(row):
    username = row.get("username")
    data = row.get("data") or {}
    if not data.get("schedule_enabled"):
        return
    hour = data.get("schedule_hour")
    minute = data.get("schedule_minute")
    if hour is None or minute is None:
        log(f"用户 {username}: 未配置定时时间，跳过", "WARN")
        return

    # 定时时间只允许 23:35–23:59，其余时间不执行
    if not (int(hour) == 23 and 35 <= int(minute) <= 59):
        log(f"用户 {username}: 定时时间 {int(hour):02d}:{int(minute):02d} 不在允许范围(23:35–23:59)，跳过", "WARN")
        return

    now_bj = beijing_now()
    # 仅允许在 23:35–23:59 窗口内执行
    if not (now_bj.hour == 23 and now_bj.minute >= 35):
        return

    scheduled_dt = now_bj.replace(hour=int(hour), minute=int(minute), second=0, microsecond=0)
    if now_bj < scheduled_dt:
        # 窗口内但还没到用户设定的具体分钟，本次 run 不执行（下次 cron tick 再说）
        return

    creds = build_credentials(data)
    if not creds:
        log(f"用户 {username}: 缺少 AK/SK，跳过", "WARN")
        return

    log(f"▶ 用户 {username} 北京时间 {now_bj.strftime('%H:%M')} 触发定时退订（设定 {int(hour):02d}:{int(minute):02d}），共 {len(creds)} 个凭证", "WARN")

    grand = {"success": 0, "skipped": 0, "locked": 0, "fail": 0}
    executed_any = False
    for (label, ak, sk) in creds:
        try:
            # 逐个凭证「退干净再退下一个」：drain_credential 内部会复查直到该凭证无实例
            t = drain_credential(username, label, ak, sk)
            executed_any = True
            for k in grand:
                grand[k] += t.get(k, 0)
        except Exception as e:
            log(f"  ❌ 凭证「{label}」处理异常: {e}", "ERROR")

    log(f"🏁 用户 {username} 全部凭证退订完成：成功 {grand['success']} 跳过 {grand['skipped']} 锁定 {grand['locked']} 失败 {grand['fail']}",
        "SUCCESS" if (grand["fail"] == 0 and executed_any) else ("WARN" if executed_any else "ERROR"))

    # 记录最后执行日期（仅用于监控，不再作为「每天只跑一次」的闸门）
    if executed_any:
        supabase_patch_schedule_date(username, {**data, "schedule_last_executed_date": beijing_date_str()}, beijing_date_str())


def main():
    # 防重叠锁：同一时刻只允许一个实例在跑（定时任务可能被上一次还没结束的 tick 再次触发）
    lock_path = "/tmp/scheduled-refund.lock"
    try:
        lock_fd = open(lock_path, "w")
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (IOError, OSError):
        print("[LOCK] 已有实例在运行，本次跳过", flush=True)
        sys.exit(0)

    log("===== 定时退订任务启动（北京时间 " + beijing_now().strftime("%Y-%m-%d %H:%M:%S") + "）=====", "WARN")
    try:
        rows = supabase_get_all_user_data()
    except Exception as e:
        log(f"读取 user_data 失败: {e}", "ERROR")
        sys.exit(1)
    log(f"共读取 {len(rows)} 个用户配置", "INFO")

    due_count = 0
    for row in rows:
        try:
            before = (row.get("data") or {}).get("schedule_last_executed_date")
            process_user(row)
            after = beijing_date_str()
            # 粗略判断本用户是否本次执行了（用于计数日志）
            if (row.get("data") or {}).get("schedule_enabled") and before != after:
                due_count += 1
        except Exception as e:
            uname = row.get("username", "?")
            log(f"用户 {uname} 处理异常: {e}", "ERROR")

    log(f"===== 本次任务结束，触发执行的用户数: {due_count} =====", "WARN")


if __name__ == "__main__":
    main()

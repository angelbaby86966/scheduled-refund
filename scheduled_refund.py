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
  - 同一账号逐凭证「退干净再退下一个」；凭证内采用【波次 + 每地区并行】模型提速：
    每波 6 个地区并行列举、各地区各自一批(默认 50 台)并行退订、地区间互不干扰，波次间隔(默认 3s)后进入下一波直到退完
  - 并发控制：地区内/地区间线程池并行 + 全局令牌桶平滑到 ~BSS_QPS 次/秒，避免触发阿里云 Throttling 限流
  - 限流/服务不可用自动指数退避重试，且复用同一 ClientToken 保证幂等（不会重复退款）
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
import threading
import datetime
import hmac
import hashlib
import base64
import fcntl
import urllib.parse
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

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

# ===================== 并发 / 限流配置 =====================
# 每波每个地区并行退订的实例数（用户要求：各地区各自一批 50 台并行退）。
# 地区内部用线程池开到该数量，地区之间互不干扰、同时开退。
BATCH_PER_REGION = int(os.environ.get("REFUND_BATCH_PER_REGION", "50"))

# 波次间隔（秒）：每波退完后等待，再各地区退下一批（用户要求：过 3 秒再退）。
# 同时给阿里云侧状态刷新留时间，下一波再列举看是否还有剩余。
WAVE_INTERVAL = int(os.environ.get("REFUND_WAVE_INTERVAL", "3"))

# 退订请求同时最多在飞的数量（每地区线程池上限）。开到 BATCH_PER_REGION 让单地区真能 50 路并行。
CONCURRENCY = int(os.environ.get("REFUND_CONCURRENCY", "50"))

# 阿里云 BSS 每秒最多约多少次 RefundInstance（令牌桶平滑目标，账号级 QPS 上限）。
# 这是真正的提速开关：原默认 8/s 太保守导致退订像一台台退；提到 20/s 明显更快。
# 调太高（如 >30）会触发 Throttling 反而更慢（已有退避重试兜底，不会重复退），按需微调。
BSS_QPS = int(os.environ.get("BSS_QPS", "20"))

# 单实例退订遇到限流时的最大重试次数（每次重试复用同一 ClientToken，幂等）
REFUND_MAX_RETRY = int(os.environ.get("REFUND_MAX_RETRY", "6"))

# 最大波次（兜底防死循环）：50 台/地区/波 × 6 地区 × 60 波 容量足够，到达上限仍有实例则告警停止。
MAX_WAVES = int(os.environ.get("REFUND_MAX_WAVES", "60"))


class TokenBucket:
    """简单令牌桶：平滑请求速率，避免瞬时并发触发服务端限流。线程安全。"""

    def __init__(self, rate, capacity):
        self.rate = float(rate)          # 每秒补充令牌数
        self.capacity = float(capacity)  # 桶容量
        self.tokens = float(capacity)
        self.last = time.time()
        self.lock = threading.Lock()

    def acquire(self, n=1):
        while True:
            with self.lock:
                now = time.time()
                self.tokens = min(self.capacity, self.tokens + (now - self.last) * self.rate)
                self.last = now
                if self.tokens >= n:
                    self.tokens -= n
                    return
                deficit = n - self.tokens
                sleep_for = deficit / self.rate
            time.sleep(sleep_for)


# BSS RefundInstance 专用令牌桶（全局单例，因同一时刻仅有单一 AK 在处理）
BSS_BUCKET = TokenBucket(BSS_QPS, BSS_QPS)

# 日志在多线程下也尽量不串行错乱
_log_lock = threading.Lock()


# ===================== 工具 =====================
def log(msg, level="INFO"):
    ts = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime("%H:%M:%S")
    with _log_lock:
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


def stable_client_token(region_id, instance_id):
    """按 region+instance 派生的稳定幂等 Token：同一实例在任意进程/轮次/定时执行中永远用同一
    ClientToken，使阿里云服务端将其视为同一请求（保留期内幂等），杜绝网络抖动/进程重启/定时
    重复执行导致的重复退款。这是「幂等去重兜底」的核心。"""
    return "wb-" + hashlib.sha1((region_id + ":" + instance_id).encode("utf-8")).hexdigest()[:16]


def refund_instance(ak, sk, region_id, instance_id, client_token=None):
    """调用 BSS RefundInstance（与前端 refundInstance 完全一致）。返回 (ok, kind, msg)。
    client_token 可传入以复用；默认按 region+instance 派生稳定 Token，跨执行幂等。
    """
    if client_token is None:
        client_token = stable_client_token(region_id, instance_id)
    params = {
        "InstanceId": instance_id,
        "ProductCode": "ace_eweb",
        "ProductType": "",  # 与前端保持一致：空串也参与签名
        "ImmediatelyRelease": "1",
        "ClientToken": client_token,
    }
    data = rpc(ak, sk, "https://business.aliyuncs.com/", "RefundInstance", "2017-12-14", params)
    # 成功判定（与前端一致）：Success 为真，或 Code==ResourceNotExists（已退/不存在）
    if data.get("Success") or data.get("Code") == "ResourceNotExists":
        return True, "ok", data.get("Message") or "success"
    code = data.get("Code") or "Unknown"
    msg = data.get("Message") or code
    kind = classify(msg)
    return False, kind, msg


# 触发退避重试的限流/瞬时错误特征（这类不是业务失败，重试即可，且复用同一 ClientToken 幂等）
_THROTTLE_HINTS = ("Throttling", "throttled", "ServiceUnavailable",
                   "Forbidden.RiskControl", "InternalError", "SystemBusy", "RequestTimeout")


def refund_instance_retry(ak, sk, region_id, instance_id, max_retry=None):
    """带限流退避重试的退订。ClientToken 固定，重试幂等，不会重复退款。
    返回 (ok, kind, msg)。"""
    if max_retry is None:
        max_retry = REFUND_MAX_RETRY
    # 稳定幂等 Token：按 region+instance 派生，跨轮次/跨进程/跨定时执行同一实例永远同一 token
    client_token = stable_client_token(region_id, instance_id)
    backoff = 1.0
    last_kind, last_msg = "fail", "unknown"
    for attempt in range(1, max_retry + 1):
        # 令牌桶平滑：把 BSS 请求速率限制在 ~BSS_QPS/秒，避免瞬时并发触发 Throttling
        BSS_BUCKET.acquire()
        try:
            ok, kind, msg = refund_instance(ak, sk, region_id, instance_id, client_token)
        except Exception as e:
            ok, kind, msg = False, "fail", str(e)
        last_kind, last_msg = kind, msg
        if kind in ("ok", "skipped", "locked"):
            return ok, kind, msg
        # 限流/服务瞬时不可用：退避重试（仍走令牌桶，复用同一 client_token）
        if attempt < max_retry and any(h in msg for h in _THROTTLE_HINTS):
            log(f"    ⏳ 限流重试 {attempt}/{max_retry}: {instance_id} → {msg[:70]}", "WARN")
            time.sleep(backoff)
            backoff = min(backoff * 2, 20)
            continue
        return ok, kind, msg
    return False, last_kind, last_msg


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


def _refund_region_batch(username, label, ak, sk, rid, items):
    """退单个地区的一批实例：地区内部开线程池并行退（上限 BATCH_PER_REGION 台），
    每笔退订仍走全局 BSS_BUCKET 令牌桶（账号级 QPS 兜底）+ 限流退避重试 + 幂等 ClientToken。
    返回本地区的统计 dict。"""
    res = {"success": 0, "skipped": 0, "locked": 0, "fail": 0}
    batch = items[:BATCH_PER_REGION]
    if not batch:
        return res
    region_name = REGION_INFO.get(rid, rid)
    workers = max(1, min(CONCURRENCY, len(batch)))
    with ThreadPoolExecutor(max_workers=workers) as rex:
        rfuts = {rex.submit(refund_instance_retry, ak, sk, rid, it["instanceId"]): it["instanceId"] for it in batch}
        for rf in as_completed(rfuts):
            iid = rfuts[rf]
            try:
                ok, kind, msg = rf.result()
            except Exception as e:
                ok, kind, msg = False, "fail", str(e)
            if kind == "skipped":
                res["skipped"] += 1
                log(f"  ⚪ [{label}][{region_name}] {iid}: 已退订/不存在，跳过", "INFO")
            elif kind == "locked":
                res["locked"] += 1
                log(f"  🔒 [{label}][{region_name}] {iid}: {msg}（跳过，不再重试）", "WARN")
            elif ok:
                res["success"] += 1
                log(f"  ✅ [{label}][{region_name}] {iid} 退订成功", "SUCCESS")
            else:
                res["fail"] += 1
                log(f"  ❌ [{label}][{region_name}] {iid}: {msg}", "ERROR")
    return res


def drain_credential(username, label, ak, sk, max_waves=MAX_WAVES):
    """退单凭证（波次 + 每地区并行模型）：

    每一波：
      1) 6 个地区并行列举实例（独立 endpoint，互不干扰）；
      2) 各地区各自取前 BATCH_PER_REGION(默认 50) 台，开本地区线程池并行退订；
         6 个地区由外层线程池同时开退，地区之间互不干扰；
      3) 波次间隔 WAVE_INTERVAL(默认 3 秒)，再列举下一波，直到所有地区都无实例。

    效率与限流的平衡：
      - 地区内并行 + 地区间并行：结构上就是「各地区一批 50 台并行退、互不干扰」。
      - 全局令牌桶 BSS_BUCKET 仍按账号级 QPS（BSS_QPS）平滑总速率，避免触发阿里云 Throttling；
        这是真正的提速开关，默认 20/s（原 8/s 太慢），可用环境变量调。
      - 限流自动指数退避重试 + 复用同一 ClientToken 保证幂等（不会重复退款）。
    """
    total = {"success": 0, "skipped": 0, "locked": 0, "fail": 0}
    for wave in range(1, max_waves + 1):
        # 1) 每地区并行列举本轮实例
        inst_by_region = {}
        with ThreadPoolExecutor(max_workers=len(REGION_INFO)) as ex:
            futs = {ex.submit(list_instances, ak, sk, rid): rid for rid in REGION_INFO}
            for fut in as_completed(futs):
                rid = futs[fut]
                try:
                    inst_by_region[rid] = fut.result()
                except Exception as e:
                    inst_by_region[rid] = []
                    log(f"  ⚠️ [{label}][{REGION_INFO[rid]}] 列举失败: {e}", "WARN")

        remaining = sum(len(v) for v in inst_by_region.values())
        if remaining == 0:
            log(f"  ✅ 凭证「{label}」第 {wave} 波复查：已无实例（退订完成）", "SUCCESS")
            break

        # 2) 各地区并行退订（每地区一批 BATCH_PER_REGION，地区间互不干扰）
        log(f"  🌊 凭证「{label}」第 {wave} 波：剩余 {remaining} 台，各地区各取前 {BATCH_PER_REGION} 台并行退订", "INFO")
        with ThreadPoolExecutor(max_workers=len(REGION_INFO)) as rpool:
            rfuts = {rpool.submit(_refund_region_batch, username, label, ak, sk, rid, items): rid
                     for rid, items in inst_by_region.items() if items}
            for rf in as_completed(rfuts):
                rid = rfuts[rf]
                try:
                    r = rf.result()
                except Exception as e:
                    r = {"success": 0, "skipped": 0, "locked": 0, "fail": 0}
                    log(f"  ❌ 凭证「{label}」[{REGION_INFO[rid]}] 退订异常: {e}", "ERROR")
                for k in total:
                    total[k] += r.get(k, 0)

        # 3) 波次间隔：让阿里云侧状态刷新，下一波再列举看是否还有剩余
        if wave < max_waves:
            time.sleep(WAVE_INTERVAL)
    else:
        log(f"  ⚠️ 凭证「{label}」达到最大波次 {max_waves} 仍有实例，停止以免死循环", "WARN")

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

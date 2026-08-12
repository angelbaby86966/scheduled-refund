#!/usr/bin/env python3
"""云端定时退订脚本 - cron 每分钟运行一次（幂等、支持过期补跑）"""
import hmac, hashlib, base64, uuid, urllib.request, urllib.parse, json, time, threading
from datetime import datetime, timezone, timedelta

SUPABASE_URL = "https://vgddxxgjcogxcpiycsej.supabase.co"
SUPABASE_ANON_KEY = "sb_publishable_AqRbhxlzaDzPNR1nZTw-4A_c1VQ1Nch"
BSS_ENDPOINT = "https://business.aliyuncs.com/"
BSS_VERSION = "2017-12-14"
PRODUCT_CODE = "ace_eweb"
LOG_FILE = "refund_cron.log"

REGIONS = {
    "cn-hangzhou": "杭州", "cn-beijing": "北京", "cn-shanghai": "上海",
    "cn-shenzhen": "深圳", "cn-chengdu": "成都", "cn-guangzhou": "广州",
}
RETRY_GAP_MIN = 10
MAX_OVERDUE_HOURS = 24
BATCH_SIZE = 50
BATCH_INTERVAL = 3
MAX_RETRIES = 2          # 第1轮退完后最多再检查2次


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def sign(ak_id, ak_secret, action, version, params):
    common = {
        "AccessKeyId": ak_id, "Action": action, "Format": "JSON",
        "SignatureMethod": "HMAC-SHA1", "SignatureNonce": str(uuid.uuid4()),
        "SignatureVersion": "1.0",
        "Timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "Version": version,
    }
    all_p = {**common, **params}
    keys = sorted(all_p.keys())
    canonical = "&".join(urllib.parse.quote(k, safe='') + "=" + urllib.parse.quote(str(all_p[k]), safe='') for k in keys)
    sign_str = "POST&" + urllib.parse.quote("/", safe='') + "&" + urllib.parse.quote(canonical, safe='')
    sig = base64.b64encode(hmac.new((ak_secret + "&").encode(), sign_str.encode(), hashlib.sha1).digest()).decode()
    all_p["Signature"] = sig
    return "&".join(urllib.parse.quote(k, safe='') + "=" + urllib.parse.quote(str(v), safe='') for k, v in all_p.items())


def api_call(endpoint, body):
    req = urllib.request.Request(endpoint, data=body.encode(), headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=15).read())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read())
        except Exception:
            return {"Code": "HttpError", "Message": str(e)}
    except Exception as e:
        return {"Code": "NetworkError", "Message": str(e)}


def refund_instance(ak_id, ak_secret, instance_id):
    return api_call(BSS_ENDPOINT, sign(ak_id, ak_secret, "RefundInstance", BSS_VERSION, {
        "InstanceId": instance_id, "ProductCode": PRODUCT_CODE,
        "ProductType": "", "ImmediatelyRelease": "1", "ClientToken": str(uuid.uuid4()),
    }))


def list_instances(ak_id, ak_secret, region_id):
    return api_call(f"https://swas.{region_id}.aliyuncs.com/", sign(ak_id, ak_secret, "ListInstances", "2020-06-01", {}))


def get_all_users():
    try:
        req = urllib.request.Request(
            f"{SUPABASE_URL}/rest/v1/user_data?select=*",
            headers={"apikey": SUPABASE_ANON_KEY, "Authorization": f"Bearer {SUPABASE_ANON_KEY}"})
        return json.loads(urllib.request.urlopen(req, timeout=10).read())
    except Exception as e:
        log(f"  查询用户列表失败: {e}")
        return []


def update_user_data(username, updates):
    try:
        req = urllib.request.Request(
            f"{SUPABASE_URL}/rest/v1/user_data?username=eq.{urllib.parse.quote(username)}&select=*",
            headers={"apikey": SUPABASE_ANON_KEY, "Authorization": f"Bearer {SUPABASE_ANON_KEY}"})
        rows = json.loads(urllib.request.urlopen(req, timeout=10).read())
        if not rows:
            return
        data = rows[0].get("data", {}) or {}
        if isinstance(data, str):
            data = json.loads(data)
        data.update(updates)
        body = json.dumps({"data": data}).encode()
        req = urllib.request.Request(
            f"{SUPABASE_URL}/rest/v1/user_data?username=eq.{urllib.parse.quote(username)}",
            data=body, method="PATCH",
            headers={"apikey": SUPABASE_ANON_KEY, "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
                     "Content-Type": "application/json", "Prefer": "return=minimal"})
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        log(f"  更新用户数据失败: {e}")


def _collect_region(ak_id, ak_secret, rid, per_region):
    try:
        result = list_instances(ak_id, ak_secret, rid)
        for inst in (result.get("Instances") or []):
            per_region[rid].append((inst["InstanceId"], inst.get("InstanceName", "")))
    except Exception as e:
        log(f"    ⚠️ {REGIONS[rid]}: 查询失败 - {e}")


def _refund_region(ak_id, ak_secret, rid, instances, stats):
    batches = [instances[i:i + BATCH_SIZE] for i in range(0, len(instances), BATCH_SIZE)]
    log(f"    🌏 {REGIONS[rid]}: 共 {len(instances)} 台，分 {len(batches)} 批并行退订（每批 {BATCH_SIZE} 台并发，批间 {BATCH_INTERVAL}s）")
    s = f = k = 0
    for bi, batch in enumerate(batches):
        batch_results = [None] * len(batch)
        threads = []
        def _refund_one(idx, iid):
            try:
                result = refund_instance(ak_id, ak_secret, iid)
                code = result.get("Code", "")
                if code == "200" or result.get("Success"):
                    batch_results[idx] = ('ok', iid, '')
                elif code in ("ResourceNotExists", "InvalidInstanceId.NotFound"):
                    batch_results[idx] = ('skip', iid, '')
                else:
                    batch_results[idx] = ('fail', iid, result.get('Message', code))
            except Exception as e:
                batch_results[idx] = ('fail', iid, str(e))
        for idx, (iid, name) in enumerate(batch):
            t = threading.Thread(target=_refund_one, args=(idx, iid))
            threads.append(t)
            t.start()
        for t in threads:
            t.join()
        for r in batch_results:
            if r[0] == 'ok':
                s += 1
                log(f"    ✅ [{REGIONS[rid]}] {r[1]} 退订成功")
            elif r[0] == 'skip':
                k += 1
                log(f"    ⚪ [{REGIONS[rid]}] {r[1]} 已不存在，跳过")
            else:
                f += 1
                log(f"    ❌ [{REGIONS[rid]}] {r[1]} 失败: {r[2]}")
        if bi < len(batches) - 1:
            time.sleep(BATCH_INTERVAL)
    stats[rid] = [s, f, k]


def execute_refund_for_user(username, ak_id, ak_secret, round_label):
    log(f"  👤 {username}: {round_label} - 并行查询各地区实例...")
    per_region = {rid: [] for rid in REGIONS}
    collectors = []
    for rid in REGIONS:
        t = threading.Thread(target=_collect_region, args=(ak_id, ak_secret, rid, per_region))
        collectors.append(t)
        t.start()
    for t in collectors:
        t.join()
    total = sum(len(v) for v in per_region.values())
    if total == 0:
        log(f"  👤 {username}: 无实例，跳过")
        return {"success": 0, "fail": 0, "skip": 0}
    log(f"  👤 {username}: 共 {total} 台实例，开始并行退订（每地区每批 {BATCH_SIZE} 台，批间间隔 {BATCH_INTERVAL}s）...")
    stats = {}
    workers = []
    for rid, insts in per_region.items():
        if not insts:
            continue
        t = threading.Thread(target=_refund_region, args=(ak_id, ak_secret, rid, insts, stats))
        workers.append(t)
        t.start()
    for t in workers:
        t.join()
    success = sum(v[0] for v in stats.values())
    fail = sum(v[1] for v in stats.values())
    skip = sum(v[2] for v in stats.values())
    log(f"  👤 {username}: {round_label} 完成 - 成功{success} 跳过{skip} 失败{fail}")
    return {"success": success, "fail": fail, "skip": skip}


def main(now_override=None):
    if now_override is not None:
        bj = now_override
    else:
        now_utc = datetime.now(timezone.utc)
        bj = now_utc + timedelta(hours=8)
    today = bj.strftime("%Y-%m-%d")
    current_hm = bj.strftime("%H:%M")
    now_bj = bj
    log(f"⏰ 检查 - 北京时间 {current_hm}")
    users = get_all_users()
    if not users:
        log("  无用户数据")
        return
    ran_any = False
    for ud in users:
        username = ud.get("username", "")
        d = ud.get("data", {}) or {}
        if isinstance(d, str):
            try:
                d = json.loads(d)
            except Exception:
                d = {}
        enabled = d.get("schedule_enabled")
        h = d.get("schedule_hour")
        m = d.get("schedule_minute")
        last_date = d.get("schedule_last_executed_date", "")
        retry_at = d.get("schedule_retry_at", "")
        retry_done = d.get("schedule_retry_done", False)
        if not enabled or h is None or m is None:
            continue
        ak_id = d.get("ak_id", "")
        ak_secret = d.get("ak_secret", "")
        if not ak_id or not ak_secret:
            log(f"  👤 {username}: 已开启定时但缺少 AK/SK，跳过")
            continue
        if last_date == today:
            if retry_at or not retry_done:
                update_user_data(username, {"schedule_retry_at": "", "schedule_retry_done": True})
            continue
        schedule_dt = bj.replace(hour=int(h), minute=int(m), second=0, microsecond=0)
        if MAX_OVERDUE_HOURS is not None:
            overdue = (now_bj - schedule_dt).total_seconds() / 3600.0
            if overdue > MAX_OVERDUE_HOURS:
                continue
        if now_bj < schedule_dt:
            # Before today's scheduled time.
            # Check if yesterday's schedule was missed (GitHub Actions cron runs
            # every 2-4 hours, might have skipped the window between yesterday's
            # scheduled time and midnight — this is the core bug that caused
            # "browser closed = no refund").
            yesterday_dt = bj - timedelta(days=1)
            yesterday_str = yesterday_dt.strftime("%Y-%m-%d")
            if last_date != yesterday_str:
                y_schedule_dt = schedule_dt - timedelta(days=1)
                y_overdue = (now_bj - y_schedule_dt).total_seconds() / 3600.0
                if 0 <= y_overdue <= MAX_OVERDUE_HOURS:
                    ran_any = True
                    log(f"  👤 {username}: 🔄 补跑昨天({yesterday_str})漏掉的 {int(h):02d}:{int(m):02d} 定时退订（现在 {current_hm}）")
                    result = execute_refund_for_user(username, ak_id, ak_secret, f"补跑{yesterday_str}")
                    if result["fail"] == 0:
                        log(f"  👤 {username}: ✅ 补跑成功，标记 {yesterday_str} 已完成")
                    else:
                        log(f"  👤 {username}: ⚠️ 补跑完成但有 {result['fail']} 台失败（不再重试，已标记完成）")
                    update_user_data(username, {
                        "schedule_last_executed_date": yesterday_str,
                        "schedule_retry_at": "",
                        "schedule_retry_done": True,
                    })
            continue
        # ===== 定时退订：第1轮 + 2次重试（每次间隔10分钟，全部在本次执行内完成） =====
        ran_any = True
        log(f"  👤 {username}: 🕐 第1轮退订 ({int(h):02d}:{int(m):02d}，北京时间 {current_hm})")
        result = execute_refund_for_user(username, ak_id, ak_secret, "第1轮")
        total_fail = result["fail"]
        for retry_i in range(1, MAX_RETRIES + 1):
            if total_fail == 0:
                break
            log(f"  👤 {username}: ⏳ 第{retry_i}轮有 {total_fail} 台失败，等待 {RETRY_GAP_MIN} 分钟后重试...")
            time.sleep(RETRY_GAP_MIN * 60)
            log(f"  👤 {username}: 🔄 第{retry_i + 1}轮重试开始")
            result = execute_refund_for_user(username, ak_id, ak_secret, f"第{retry_i + 1}轮重试")
            total_fail = result["fail"]
        if total_fail == 0:
            log(f"  👤 {username}: ✅ 全部退订成功，今日任务完成")
        else:
            log(f"  👤 {username}: ⚠️ 已重试 {MAX_RETRIES} 次，仍有 {total_fail} 台未退订，不再检查")
        update_user_data(username, {
            "schedule_last_executed_date": today,
            "schedule_retry_at": "",
            "schedule_retry_done": True,
        })
        continue
    if not ran_any:
        log("  无账号需要执行")


if __name__ == "__main__":
    main()

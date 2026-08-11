#!/usr/bin/env python3
"""
云端定时退订脚本 - cron 每分钟运行一次（幂等、支持过期补跑）

核心设计（解决"关浏览器/关电脑就不退"）：
  1. 不再要求 cron 在「精确的那个分钟」触发。只要当天任意时刻脚本运行到，
     且北京时间已 >= 设定的定时时间，且今天还没执行过 → 立即补跑。
  2. 因此 cron 宿主（云 VM / 本机）短暂休眠、错过整点、甚至当天晚些时候才上线，
     都不会漏掉当天的退订。
  3. 每天最多执行一次（schedule_last_executed_date 守卫）。
  4. 第 1 轮有失败 → 2 分钟后第 2 轮重试；若已错过重试窗口则本轮直接连跑第 2 轮。

依赖：cron 每分钟调用一次，例如
  * * * * * /usr/bin/python3 /workspace/scheduled_refund.py >> /workspace/refund_cron.log 2>&1
"""
import hmac, hashlib, base64, uuid, urllib.request, urllib.parse, json, time
from datetime import datetime, timezone, timedelta
from concurrent.futures import ThreadPoolExecutor

SUPABASE_URL = "https://vgddxxgjcogxcpiycsej.supabase.co"
SUPABASE_ANON_KEY = "sb_publishable_AqRbhxlzaDzPNR1nZTw-4A_c1VQ1Nch"
BSS_ENDPOINT = "https://business.aliyuncs.com/"
BSS_VERSION = "2017-12-14"
PRODUCT_CODE = "ace_eweb"
LOG_FILE = "refund_cron.log"  # 相对当前目录，Mac / GitHub runner 均可写

REGIONS = {
    "cn-hangzhou": "杭州", "cn-beijing": "北京", "cn-shanghai": "上海",
    "cn-shenzhen": "深圳", "cn-chengdu": "成都", "cn-guangzhou": "广州",
}

RETRY_GAP_MIN = 2  # 第 1 轮失败后的重试间隔（分钟）

# 退订并发参数（提速核心）
BATCH_SIZE = 50        # 每个地区每批「并行」退订的实例数（≤50 一批）
BATCH_GAP_SEC = 3      # 同一地区每批退完后，间隔多少秒再退下一批
REGION_WORKERS = len(REGIONS)  # 6 个地区之间「并行」退订（不用串行）

# 当日窗口上限：设定时间之后多久之内允许补跑（防止"几天没开机"后突然退订造成困惑）。
# 设为 24 小时 = 只要当天任意时刻上线都补跑。None 表示不限制。
MAX_OVERDUE_HOURS = 24


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
    """HMAC-SHA1 签名"""
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
    return api_call(f"https://swas.{region_id}.aliyuncs.com/",
                    sign(ak_id, ak_secret, "ListInstances", "2020-06-01", {}))


def get_all_users():
    try:
        req = urllib.request.Request(f"{SUPABASE_URL}/rest/v1/user_data?select=*",
            headers={"apikey": SUPABASE_ANON_KEY, "Authorization": f"Bearer {SUPABASE_ANON_KEY}"})
        return json.loads(urllib.request.urlopen(req, timeout=10).read())
    except Exception as e:
        log(f"获取用户数据失败: {e}")
        return []


def update_user_data(username, updates):
    """合并更新用户 data 字段（不覆盖其他字段）"""
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


def execute_refund_for_user(username, ak_id, ak_secret, round_label):
    """对单个用户执行退订，返回 {success, fail, skip}

    提速设计（用户要求）：
      - 查询阶段：6 个地区「并行」查询实例；
      - 退订阶段：6 个地区「并行」退订（不再串行）；
      - 地区内：每 BATCH_SIZE(50) 台「并发」退一批，批间间隔 BATCH_GAP_SEC(3s) 再退下一批。
    退订请求本身带 ClientToken，天然幂等，重试轮重跑安全。
    """
    log(f"  👤 {username}: {round_label} - 并行查询 {REGION_WORKERS} 个地区实例...")

    # ---- 查询阶段：各地区并行 ----
    region_instances = {}  # rid -> [(iid, name), ...]

    def fetch_region(rid):
        try:
            result = list_instances(ak_id, ak_secret, rid)
            insts = [(inst["InstanceId"], inst.get("InstanceName", ""))
                     for inst in (result.get("Instances") or [])]
            return rid, insts
        except Exception as e:
            log(f"    ⚠️ {REGIONS[rid]}: 查询失败 - {e}")
            return rid, []

    with ThreadPoolExecutor(max_workers=REGION_WORKERS) as ex:
        for rid, insts in ex.map(fetch_region, list(REGIONS.keys())):
            region_instances[rid] = insts

    total = sum(len(v) for v in region_instances.values())
    if total == 0:
        log(f"  👤 {username}: 无实例，跳过")
        return {"success": 0, "fail": 0, "skip": 0}
    log(f"  👤 {username}: 共 {total} 台实例，开始地区并行退订（每地区每批{BATCH_SIZE}台并发，批间{BATCH_GAP_SEC}s）...")

    # ---- 退订阶段：地区内分批并发、地区间并行 ----
    def refund_one(rid, iid, name):
        try:
            result = refund_instance(ak_id, ak_secret, iid)
            code = result.get("Code", "")
            if code == "200" or result.get("Success"):
                log(f"    ✅ [{REGIONS[rid]}] {iid} 退订成功")
                return 1
            elif code in ("ResourceNotExists", "InvalidInstanceId.NotFound"):
                log(f"    ⚪ [{REGIONS[rid]}] {iid} 已不存在，跳过")
                return 2
            else:
                log(f"    ❌ [{REGIONS[rid]}] {iid} 失败: {result.get('Message', code)}")
                return 0
        except Exception as e:
            log(f"    ❌ [{REGIONS[rid]}] {iid} 异常: {e}")
            return 0

    def refund_region(rid):
        insts = region_instances[rid]
        s = f = sk = 0
        n = len(insts)
        for i in range(0, n, BATCH_SIZE):
            batch = insts[i:i + BATCH_SIZE]
            with ThreadPoolExecutor(max_workers=len(batch)) as ex:
                rs = list(ex.map(lambda t: refund_one(rid, t[0], t[1]), batch))
            for r in rs:
                if r == 1: s += 1
                elif r == 2: sk += 1
                else: f += 1
            if i + BATCH_SIZE < n:
                log(f"    ⏳ [{REGIONS[rid]}] 本批 {len(batch)} 台已退，{BATCH_GAP_SEC}s 后再退下一批")
                time.sleep(BATCH_GAP_SEC)
        return rid, s, f, sk

    success, fail, skip = 0, 0, 0
    with ThreadPoolExecutor(max_workers=REGION_WORKERS) as ex:
        for rid, s, f, sk in ex.map(refund_region, list(REGIONS.keys())):
            success += s; fail += f; skip += sk
            log(f"  🏁 [{REGIONS[rid]}] 完成 - 成功{s} 跳过{sk} 失败{f}")

    log(f"  👤 {username}: {round_label} 完成 - 成功{success} 跳过{skip} 失败{fail}")
    return {"success": success, "fail": fail, "skip": skip}


def main(now_override=None):
    # now_override: 可选的"北京时间"datetime，仅供测试注入时钟用；生产(cron)不传，用真实时间
    if now_override is not None:
        bj = now_override
    else:
        now_utc = datetime.now(timezone.utc)
        bj = now_utc + timedelta(hours=8)
    today = bj.strftime("%Y-%m-%d")
    current_hm = bj.strftime("%H:%M")
    # 当前北京时间（datetime，用于比较）
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

        # 今天已执行 → 清理残留 retry 标记后跳过
        if last_date == today:
            if retry_at or not retry_done:
                update_user_data(username, {"schedule_retry_at": "", "schedule_retry_done": True})
            continue

        # 设定时间（北京时间今天）
        schedule_dt = bj.replace(hour=int(h), minute=int(m), second=0, microsecond=0)
        retry_dt = schedule_dt + timedelta(minutes=RETRY_GAP_MIN)

        # 过期补跑上限：超过窗口则不再补跑（避免多日未开机后突然退订）
        if MAX_OVERDUE_HOURS is not None:
            overdue = (now_bj - schedule_dt).total_seconds() / 3600.0
            if overdue > MAX_OVERDUE_HOURS:
                continue

        # === 还没到设定时间 → 不跑（等整点） ===
        if now_bj < schedule_dt:
            continue

        ran_any = True

        # ===== 第 1 轮：已到点到 → 执行 =====
        log(f"  👤 {username}: 🕐 第1轮触发 ({int(h):02d}:{int(m):02d}，北京时间 {current_hm})")
        result = execute_refund_for_user(username, ak_id, ak_secret, "第1轮")

        if result["fail"] == 0:
            log(f"  👤 {username}: ✅ 全部成功，今日任务完成")
            update_user_data(username, {
                "schedule_last_executed_date": today,
                "schedule_retry_at": "",
                "schedule_retry_done": True,
            })
            continue

        # 有失败：是否已进入重试窗口？
        if now_bj >= retry_dt:
            # 直接连跑第 2 轮（已错过等待窗口）
            log(f"  👤 {username}: 🔄 第2轮重试触发（已过等待窗口，立即补跑）")
            execute_refund_for_user(username, ak_id, ak_secret, "第2轮重试")
            update_user_data(username, {
                "schedule_last_executed_date": today,
                "schedule_retry_at": "",
                "schedule_retry_done": True,
            })
        else:
            # 安排 2 分钟后重试（下一轮 cron 会捕获）
            retry_str = retry_dt.strftime("%H:%M")
            log(f"  👤 {username}: ⚠️ {result['fail']}台失败，{RETRY_GAP_MIN}分钟后({retry_str})重试")
            update_user_data(username, {
                "schedule_retry_at": retry_str,
                "schedule_retry_done": False,
            })
        continue

    if not ran_any:
        log("  无账号需要执行")


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# IPES 一键部署 r20 裸版（no-tune：不做任何系统调优，happy 进程 9）
# 用法：
#   curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/inline_deploy_r20_oss.sh | bash -s -- \
#     --ak 06d78b19bd0d9fc0aa300c6d \
#     --sk 16d6c46443308e62bb51f22c074a90ed \
#     --jwt eyJ... \
#     --isp 联通 [--province 浙江 --city 杭州 --num-dirs 12 --usbw 200]
# 未传 --province/--city 时，自动按本机公网 IP 识别；识别失败兜底为 浙江/杭州。
set +e
# [REV] wrapper-notune9-20260927（裸版：无任何系统调优，happy=9）
# [REV] wrapper-notune9-limit1-20261004（部署完成后自动融合限速 run_limit.sh，默认 23:59→18:45）

AK=""; SK=""; JWT=""; ISP="联通"; PROVINCE=""; CITY=""; NUM_DIRS=9; USBW=200; BW_NUM=1
# 【limit1】部署完成后自动执行限速脚本：窗口内限速 4Mbps、窗口外全速冲刺（跨天窗口自动处理）
LIMIT_START="23:59"; LIMIT_END="18:45"; LIMIT_ENABLE=1
NODE_NAT_TYPE="public"; NODE_RESOURCE_TYPE=2; NODE_DIAL_TYPE="staticNetSingle"; NODE_SINGLE_IP_RADIO=0
ADMIN_API_HOST="https://admin.zhouyi.top"; BUSINESS_ID=41
# 【r20-finish】--finish-only：存量机「原地补齐」模式（透传给 full 脚本）
#   跳过安装/注册/容器重建，只补 [5.6]~[13]；容器不重建 → SN/身份不变 → 不掉量。
FINISH_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ak) AK="$2"; shift 2 ;;
    --sk) SK="$2"; shift 2 ;;
    --jwt|--token|--node-activate-token) JWT="$2"; shift 2 ;;
    --isp) ISP="$2"; shift 2 ;;
    --province) PROVINCE="$2"; shift 2 ;;
    --city) CITY="$2"; shift 2 ;;
    --num-dirs) NUM_DIRS="$2"; shift 2 ;;
    --usbw) USBW="$2"; shift 2 ;;
    --bw-num) BW_NUM="$2"; shift 2 ;;
    --business-id) BUSINESS_ID="$2"; shift 2 ;;
    --admin-host) ADMIN_API_HOST="$2"; shift 2 ;;
    --finish-only) FINISH_ONLY=1; shift ;;
    --limit-start) LIMIT_START="$2"; shift 2 ;;
    --limit-end) LIMIT_END="$2"; shift 2 ;;
    --no-limit) LIMIT_ENABLE=0; shift ;;
    *) echo "[WARN] 未知参数: $1"; shift ;;
  esac
done

if [ "${FINISH_ONLY:-0}" != "1" ] && [[ -z "$AK" || -z "$SK" || -z "$JWT" ]]; then
  echo "[ERROR] 缺少 --ak / --sk / --jwt，必须提供（--finish-only 原地补齐模式不注册设备，可免）"
  echo "示例：curl -fsSL ... | bash -s -- --ak <ak> --sk <sk> --jwt <jwt> --isp 联通"
  exit 1
fi

# 自动识别省份/城市（若未显式传入）
get_location_info() {
  local ip_info=$(curl -s myip.ipip.net 2>/dev/null)
  if [ -n "$ip_info" ]; then
    local p=$(echo "$ip_info" | awk -F ' ' '{print $4}' | tr -d ',')
    local c=$(echo "$ip_info" | awk -F ' ' '{print $5}' | tr -d ',')
    if [ -n "$p" ] && [ "$p" != "null" ] && [ "$p" != " " ]; then PROVINCE="$p"; fi
    if [ -n "$c" ] && [ "$c" != "null" ] && [ "$c" != " " ]; then CITY="$c"; fi
  fi
  # 兜底：识别失败仍用浙江/杭州
  [ -z "$PROVINCE" ] && PROVINCE="浙江"
  [ -z "$CITY" ] && CITY="杭州"
}
if [ -z "$PROVINCE" ] || [ -z "$CITY" ]; then
  echo "[INFO] 未提供 --province/--city，尝试根据公网 IP 自动识别..."
  get_location_info
  echo "[INFO] 使用地理位置: $PROVINCE / $CITY"
fi

# 【r20-fix6】移除 NOTRACK：iptables raw NOTRACK 会让回包脱离 conntrack，与 firewalld(nftables/iptables) 共存时
# 导致已建立连接回包被 INPUT 丢弃 → 云助手/SSH 断连（即此前"一跑脚本就断网"根因）。全脚本统一不再使用 NOTRACK。

# ============ B) 完整部署（r20：用真实 nodeId 绑定，根治业务没落盘） ============
# 【r20-fix11】分发通道去缓存（2026-09-19 真机实测）：
#   ghproxy.net 会把同一 path 的旧版本长期缓存住，`?t=<ts>` **无效**（CDN 忽略 query），
#   而它原本排在 SRC1 且循环「首个 curl 成功即 break」⇒ 旧版永远胜出 ⇒「改好了 full 也不生效」。
#   实测（乌兰察布 1f9921de…）：raw 直连 / gh-proxy.com / jsDelivr 均为最新，ghproxy.net 为旧版。
#   注：单靠体积区分不了新旧（旧版 137253 > 阈值），所以「谁不缓存」比「校验多严」更关键，
#       权威源 raw 排第一（短超时，不通就下一条），gh-proxy.com 次之，jsDelivr 兜底。
#   三条全失败 → 显式报错退出，绝不静默退回旧版。
SRC1="https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/r20-live/ipes_deploy_full.sh"
SRC2="https://gh-proxy.com/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/r20-live/ipes_deploy_full.sh"
SRC3="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@r20-live/ipes_deploy_full.sh"
# 【r20-fix18 排雷】除体积/singleIpRadius/--finish-only 校验外，强制校验 docker 安装硬化标记
#   harden_yum_conf（仅 fix18 加固版具备）。缺此标记即旧版（yum install 无超时/重试，会 CLOSE-WAIT 卡死），
#   宁可换源/报错也绝不用旧版去部署。
FULL_OK=0; FULL_SRC=""
# 【OSS/分块投递版 2026-09-26】机器国际出口不通时，full 脚本经云助手分块预置到 /root/ipes_full.sh，
#   这里优先校验使用预置文件（同一套硬化标记校验，不放松标准）。
if [ -f /root/ipes_full.sh ] \
   && [ "$(wc -c </root/ipes_full.sh 2>/dev/null | tr -d ' ')" -gt 100000 ] \
   && grep -q singleIpRadio /root/ipes_full.sh \
   && grep -q -- '--finish-only' /root/ipes_full.sh \
   && grep -q 'harden_yum_conf' /root/ipes_full.sh && grep -q 'lite_fused_tune' /root/ipes_full.sh && grep -q 'r20f 根治瞬态值' /root/ipes_full.sh; then
  FULL_OK=1; FULL_SRC="pre-staged(/root/ipes_full.sh)"
  echo "[INFO] 使用预置 full 脚本（云助手分块投递）：$(wc -c </root/ipes_full.sh | tr -d ' ') 字节 / sha256:$(sha256sum /root/ipes_full.sh 2>/dev/null | cut -c1-12)"
fi
if [ "$FULL_OK" != "1" ]; then
for u in "$SRC1" "$SRC2" "$SRC3"; do
  if curl -fsSL -m 25 "$u" -o /root/ipes_full.sh 2>/dev/null \
     && [ "$(wc -c </root/ipes_full.sh 2>/dev/null | tr -d ' ')" -gt 100000 ] \
     && grep -q singleIpRadio /root/ipes_full.sh \
     && grep -q -- '--finish-only' /root/ipes_full.sh; then
    if grep -q 'harden_yum_conf' /root/ipes_full.sh && grep -q 'lite_fused_tune' /root/ipes_full.sh && grep -q 'r20f 根治瞬态值' /root/ipes_full.sh; then
      FULL_OK=1; FULL_SRC="$u"; break
    else
      echo "[WARN] $u 返回的 full 脚本缺 harden_yum_conf 标记（旧版/CDN 缓存），换源重试"
    fi
  else
    echo "[WARN] $u 未取到有效 full 脚本，换源重试"
  fi
done
fi
if [ "$FULL_OK" != "1" ]; then
  echo "[ERROR] 三个通道都没取到「硬化版」ipes_deploy_full.sh（缺 harden_yum_conf：CDN 缓存旧版或网络不通）"
  echo "        手动兜底： curl -fsSL -m 60 \"$SRC2\" -o /root/ipes_full.sh"
  exit 1
fi
echo "[INFO] ipes_deploy_full.sh 就绪：$(wc -c </root/ipes_full.sh | tr -d ' ') 字节 / sha256:$(sha256sum /root/ipes_full.sh 2>/dev/null | cut -c1-12) / $(grep -m1 '^SCRIPT_VERSION=' /root/ipes_full.sh | cut -d\" -f2) / 通道 ${FULL_SRC%%/https*}"
sed -i 's|^mirrorlist=|#mirrorlist=|g;s|^#\?baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
export NODE_ACTIVATE_TOKEN="$JWT"

# ============ B2) 单机互斥锁（r20-fix7） ============
# 背景：2026-09-17 上海新机事故 —— 同一台机上两份部署并发在跑（一份来自控制台、一份来自本次派发），
#   两者共用 /tmp/.ecache_patched.sh，补丁写到一半被另一份覆盖 → `line 582: syntax error`
#   → 后续 docker 自愈步骤错过窗口 → dockerd 因 sysconfig flag 与 daemon.json 冲突起不来 → 容器全停。
# 做法：flock 单机互斥。锁由后台部署进程持有，直到 full 脚本整体跑完才释放；
#   重复调用（含控制台/他人误触）会直接退出，绝不产生第二份部署。
LOCK_FILE="/var/run/ipes_deploy.lock"
if ! flock -n "$LOCK_FILE" true 2>/dev/null; then
  echo "[ERROR] 本机已有部署在运行（$LOCK_FILE 被占用），本次退出以避免两份互踩"
  echo "        确认前一份确已结束/卡死时可清理： rm -f $LOCK_FILE"
  exit 1
fi
( flock -n 9 || { echo "[ERROR] 抢锁失败：已有部署在运行，本次退出"; exit 1; }
  echo "已获取部署锁 $LOCK_FILE"
  [ "${FINISH_ONLY:-0}" = "1" ] && echo "[INFO] --finish-only 原地补齐模式（透传给 full 脚本：跳过安装/注册/容器重建）"
  FINISH_ARG=""
  [ "${FINISH_ONLY:-0}" = "1" ] && FINISH_ARG="--finish-only"
  exec setsid bash /root/ipes_full.sh --ak "$AK" --sk "$SK" --isp "$ISP" --num-dirs "$NUM_DIRS" --no-tune --skip-olmt $FINISH_ARG >/var/log/ipes_nohup.log 2>&1 </dev/null
) 9>"$LOCK_FILE" &
DEPLOY_PID=$!
echo "已后台启动部署 PID=$DEPLOY_PID（已持锁 $LOCK_FILE，互斥生效）"

# ============ B3) 部署完成后自动限速（limit1：融合 run_limit.sh） ============
# 跟随器：阻塞等待 $LOCK_FILE 锁释放（= ipes_full.sh 整体跑完）→ 等 120s 让容器/watchdog 稳定
#   → 执行 run_limit.sh 装限速（幂等，自装 cron：窗口内每10min补挂 + 结束清除 + @reboot 180s 自恢复）
# 日志：/var/log/ipes_limit_bg.log；--no-limit 可跳过；--limit-start/--limit-end 自定义窗口
if [ "$LIMIT_ENABLE" = "1" ]; then
  cat > /root/ipes_limit_after_deploy.sh <<LIM
#!/bin/bash
# 由 inline_deploy wrapper 生成：部署结束后自动限速
sleep 120
echo "[\$(date +'%F %T')] deploy finished, applying limit ($LIMIT_START -> $LIMIT_END) ..." >> /var/log/ipes_limit_bg.log
curl -fsSL -m 90 https://zyy-go.oss-cn-beijing.aliyuncs.com/script/limit/run_limit.sh | tr -d '\r' | bash -s -- "$LIMIT_START" "$LIMIT_END" >> /var/log/ipes_limit_bg.log 2>&1
echo "[\$(date +'%F %T')] limit done, exit=\$?" >> /var/log/ipes_limit_bg.log
LIM
  chmod +x /root/ipes_limit_after_deploy.sh
  ( flock "$LOCK_FILE" /root/ipes_limit_after_deploy.sh ) &
  LIMIT_PID=$!
  echo "已挂限速跟随器 PID=$LIMIT_PID：部署结束后自动执行 run_limit.sh（$LIMIT_START → $LIMIT_END），日志 /var/log/ipes_limit_bg.log"
else
  echo "[INFO] --no-limit：本次跳过自动限速"
fi

# ============ C) 业务绑定自修复（r20-fix4 根治版） ============
# 三大修复：
#   1) is_bound 读 nodeInfo（vendor/usbw 真正所在），不再读 nominalInfo（恒 0，导致永远误判未绑定→反复重绑）
#   2) 节点匹配优先用本机 device_code（32hex nodeID）精确匹配；按 IP 兜底时排除 status=offline 的孤儿记录
#   3) stateflow 的 hostname 必须用 76hex 真业务SN（ipes_sn），绝不用后台 sn 字段（那是 UUID，会毁掉业务标签）
cat > /root/ipes_repair_binding.py <<'PY'
import json, os, re, ssl, sys, time, urllib.request, urllib.error

JWT = os.environ.get('NODE_ACTIVATE_TOKEN','')
if not JWT:
    print("[ERROR] NODE_ACTIVATE_TOKEN 未设置"); sys.exit(1)

BASE = os.environ.get('ADMIN_API_HOST','https://admin.zhouyi.top')
BUSINESS_ID = int(os.environ.get('BUSINESS_ID','41'))
ISP = os.environ.get('ISP','联通')
PROVINCE = os.environ.get('PROVINCE','')
CITY = os.environ.get('CITY','')
NODE_NAT_TYPE = os.environ.get('NODE_NAT_TYPE','public')
NODE_RESOURCE_TYPE = int(os.environ.get('NODE_RESOURCE_TYPE','2'))
NODE_DIAL_TYPE = os.environ.get('NODE_DIAL_TYPE','staticNetSingle')
NODE_SINGLE_IP_RADIO = int(os.environ.get('NODE_SINGLE_IP_RADIO','0'))
NODE_USBW = int(os.environ.get('NODE_USBW','200'))
NODE_BW_NUM = int(os.environ.get('NODE_BW_NUM','1'))
DEPLOY_PID_FILE = os.environ.get('DEPLOY_PID_FILE','/var/run/ipes_deploy.pid')
# 等 Phase B 完整部署进程结束（8~20 分钟），最长 25 分钟；避免与它抢 stateflow
WAIT_DEPLOY_SEC = int(os.environ.get('REPAIR_WAIT_DEPLOY','1500'))
# 等节点注册 + 76hex 业务SN 就绪，最长 30 分钟；SN 只在容器起来后才有
WAIT_READY_SEC = int(os.environ.get('REPAIR_WAIT_READY','1800'))

CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE

def log(msg): print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

def admin_call(path, body=None, method="GET"):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("x-token", JWT)
    if body is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(body).encode()
    try:
        r = urllib.request.urlopen(req, context=CTX, timeout=30)
        return r.getcode(), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def get_public_ip():
    for url in ["http://myip.ipip.net","http://ip.sb","http://checkip.amazonaws.com"]:
        try:
            r = urllib.request.urlopen(url, timeout=5)
            ips = re.findall(r'\d+\.\d+\.\d+\.\d+', r.read().decode().strip())
            if ips: return ips[0]
        except Exception: continue
    return None

def get_local_node_id():
    # edge_client 的 device_code 即后台 32hex nodeID（r19+ 已验证）
    for f in ["/usr/local/edge_zycloud/device_code"]:
        try:
            v = open(f).read().strip()
            if re.fullmatch(r'[0-9a-f]{32}', v): return v
        except Exception: pass
    return None

def get_real_sn():
    # 76hex 业务SN：只认容器内 ipes_sn / 宿主 IPES_SN，绝不用后台 sn（UUID）
    for cmd in ["docker exec ipes cat /app/ipes/bin/ipes_sn",
                "cat /opt/soft/disk/IPES_SN"]:
        try:
            v = os.popen(cmd + " 2>/dev/null").read().strip()
            if len(v) >= 60: return v
        except Exception: pass
    return None

def fetch_all_nodes(max_pages=80):
    out = []
    for page in range(1, max_pages + 1):
        code, txt = admin_call(f"/api/edgeNode/getEdgeNodeList?page={page}&pageSize=200")
        if code != 200:
            log(f"getEdgeNodeList page {page} failed HTTP {code}: {txt[:200]}"); break
        d = json.loads(txt)
        arr = (d.get('data') or {}).get('list', [])
        total = (d.get('data') or {}).get('total', 0)
        out.extend(arr)
        if page * 200 >= total: break
        time.sleep(0.15)
    return out

def pick_node(pubip, local_nid):
    nodes = fetch_all_nodes()
    if local_nid:
        for it in nodes:
            if it.get('nodeID') == local_nid:
                log(f"按 device_code 精确匹配到本机节点: {local_nid}")
                return it
        log(f"device_code={local_nid} 尚未出现在后台，等待注册...")
        return None
    # 兜底：按 IP 匹配，排除 offline 孤儿，优先 inService
    cands = [it for it in nodes if it.get('publicIP') == pubip and it.get('status') != 'offline']
    if not cands: return None
    stage_rank = {'inService': 3, 'configured': 2, 'waitAudit': 1}
    cands.sort(key=lambda x: (stage_rank.get(x.get('stage'), 0), x.get('nodeUpdateTime') or x.get('UpdatedAt') or ''), reverse=True)
    return cands[0]

def is_bound(ni):
    if not ni: return False
    if ni.get('stage') != 'inService': return False
    info = ni.get('nodeInfo') or {}          # ★ 绑定信息在 nodeInfo，nominalInfo 恒空是正常形态
    return info.get('vendorSuggestCustomers') == BUSINESS_ID and info.get('usbw') == NODE_USBW

def tag_ok(ni, sn):
    tags = ni.get('business_tags') or []
    return bool(tags) and any(t.get('hostName') == sn for t in tags)

def do_bind(node_id, sn, pubip, local_nid, max_try=6):
    for attempt in range(1, max_try + 1):
        log(f"为本机节点 {node_id} 补绑业务 {BUSINESS_ID}（第 {attempt}/{max_try} 次）")
        # 1) 先降到 configured（平台规则：inService/waitAudit 下 updateEdgeNominalInfo 返 code:7，必须先降）
        for _ in range(2):
            code, txt = admin_call("/api/edgeNode/stateflow", {"nodes": [node_id], "stage": "configured", "hostname": sn or ""}, "POST")
            log(f"  -> configured: HTTP {code} {txt[:120]}")
            time.sleep(1)
        # 2) 写 nodeInfo（唯一写通道）
        body = {
            "nodeId": node_id, "province": PROVINCE or "浙江", "city": CITY or "杭州",
            "isp": ISP, "natType": NODE_NAT_TYPE, "resourceType": NODE_RESOURCE_TYPE,
            "dialType": NODE_DIAL_TYPE, "singleIpRadio": NODE_SINGLE_IP_RADIO,
            "usbw": NODE_USBW, "bwNum": NODE_BW_NUM, "transMode": 0,
            "transModeStr": "cm:0,ct:0,cu:0", "transProvRate": 0, "isTransProv": True,
            "isIPv6Schedule": False, "isCrossNetwork": False, "crossNetworkIsp": None,
            "vendorSuggestCustomers": BUSINESS_ID
        }
        code, txt = admin_call("/api/edgeNode/updateEdgeNominalInfo", body, "POST")
        log(f"  -> updateEdgeNominalInfo: HTTP {code} {txt[:120]}")
        time.sleep(1)
        # 3) 升回服务中，携带真 76hex SN（hostname 绝不能用 UUID/空串，否则后台写占位符毁标签）
        code, txt = admin_call("/api/edgeNode/stateflow", {"nodes": [node_id], "stage": "inService", "hostname": sn or ""}, "POST")
        log(f"  -> inService: HTTP {code} {txt[:120]}")
        time.sleep(3)
        ni = pick_node(pubip, local_nid)
        if ni and is_bound(ni) and (not sn or tag_ok(ni, sn)):
            log(f"[OK] 修复成功（第 {attempt} 次）")
            return True
        time.sleep(5)
    log("[ERROR] 多次重试仍未达标")
    return False

def deploy_still_running():
    # Phase B 完整部署（ipes_full.sh）进程是否还在；不在则视为部署结束
    try:
        pid = int(open(DEPLOY_PID_FILE).read().strip())
    except Exception:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

def wait_for(predicate, total_sec, step_sec, label):
    waited = 0
    while waited < total_sec:
        if predicate():
            return True
        if waited % 60 == 0:
            log(f"等待{label}... ({waited}/{total_sec}s)")
        time.sleep(step_sec)
        waited += step_sec
    return predicate()

def main():
    pubip = get_public_ip()
    if not pubip: log("[ERROR] 无法获取公网 IP"); sys.exit(1)
    log(f"本机公网 IP: {pubip}")
    local_nid = get_local_node_id()
    log(f"本机 device_code(nodeID): {local_nid or '未读到，走IP兜底'}")

    # 1) 等 Phase B 完整部署进程结束（避免与它抢 stateflow；部署 8~20 分钟）
    if wait_for(lambda: not deploy_still_running(), WAIT_DEPLOY_SEC, 5, "部署进程结束"):
        log("部署进程已结束，进入绑定核验")
    else:
        log("[警告] 等待部署进程超时，仍继续尝试绑定核验")

    # 2) 等节点注册 + 76hex 业务SN 就绪（SN 只在容器起来后才有）
    sn = None
    ni = None
    deadline = time.time() + WAIT_READY_SEC
    while time.time() < deadline:
        if not sn:
            sn = get_real_sn()
            if sn: log(f"本机 76hex 业务SN: {sn[:20]}...{sn[-12:]}")
        ni = pick_node(pubip, local_nid)
        if ni and sn: break
        time.sleep(10)
    # ★ 关键：SN 缺失绝不流转——否则后台写占位符 ZHOUYI_XIAODU 毁掉业务标签
    if not ni or not sn:
        log(f"[ERROR] 超时仍未就绪（node={'有' if ni else '无'} sn={'有' if sn else '无'}），放弃（不绑定空 SN）")
        sys.exit(1)

    info = ni.get('nodeInfo') or {}
    log(f"节点: {ni.get('nodeID')} stage={ni.get('stage')} status={ni.get('status')} nodeInfo.vendor={info.get('vendorSuggestCustomers')} usbw={info.get('usbw')}")
    if is_bound(ni) and (not sn or tag_ok(ni, sn)):
        log("[OK] 已绑定且业务标签正确，无需修复"); sys.exit(0)
    ok = do_bind(ni.get('nodeID'), sn, pubip, local_nid)
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()

PY

# 持久化自修复环境（供重启后自愈钩子复用；含 JWT，属敏感，权限收紧）
umask 077
cat > /root/.ipes_repair_env <<ENV
export NODE_ACTIVATE_TOKEN='${JWT}'
export ADMIN_API_HOST='${ADMIN_API_HOST}'
export BUSINESS_ID='${BUSINESS_ID}'
export ISP='${ISP}'
export PROVINCE='${PROVINCE}'
export CITY='${CITY}'
export NODE_NAT_TYPE='${NODE_NAT_TYPE}'
export NODE_RESOURCE_TYPE='${NODE_RESOURCE_TYPE}'
export NODE_DIAL_TYPE='${NODE_DIAL_TYPE}'
export NODE_SINGLE_IP_RADIO='${NODE_SINGLE_IP_RADIO}'
export NODE_USBW='${NODE_USBW}'
export NODE_BW_NUM='${NODE_BW_NUM}'
export DEPLOY_PID_FILE='/var/run/ipes_deploy.pid'
ENV
chmod 600 /root/.ipes_repair_env

# 重启后自愈：部署末尾若触发内核升级重启，Phase C 进程会被 kill 而留下「待配置」。
# 这里装一个 @reboot 钩子，开机 60s 后重新跑绑定自修复（仅当节点尚未服务中才真正流转）。
cat > /root/ipes_repair_once.sh <<'WRAP'
#!/bin/bash
export PATH=/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin:$PATH
flock -n /var/lock/ipes_repair_once.lock true || exit 0
. /root/.ipes_repair_env 2>/dev/null || true
[ -n "$NODE_ACTIVATE_TOKEN" ] || exit 0
# @reboot 调用时等 60s 让网络/容器就绪；周期 cron 调用时传 nowait 跳过等待
[ "$1" = "nowait" ] || sleep 60
cd /root
python3 /root/ipes_repair_binding.py >>/var/log/ipes_repair_reboot.log 2>&1
WRAP
chmod 700 /root/ipes_repair_once.sh
# 幂等安装 @reboot + 周期任务（先清旧的再装，避免重复）
# @reboot：覆盖「内核升级重启 kill 掉 Phase C」场景
# */10 * * * *：覆盖「容器重建/业务 ID 漂移但宿主机未重启」场景
( crontab -l 2>/dev/null | grep -v 'ipes_repair_once.sh' ; \
  echo '@reboot /bin/bash /root/ipes_repair_once.sh' ; \
  echo '*/10 * * * * /bin/bash /root/ipes_repair_once.sh nowait' ) | crontab -

export NODE_ACTIVATE_TOKEN="$JWT" ADMIN_API_HOST BUSINESS_ID ISP PROVINCE CITY \
       NODE_NAT_TYPE NODE_RESOURCE_TYPE NODE_DIAL_TYPE NODE_SINGLE_IP_RADIO \
       NODE_USBW NODE_BW_NUM

nohup setsid python3 /root/ipes_repair_binding.py >/var/log/ipes_repair.log 2>&1 </dev/null &
REPAIR_PID=$!
echo "已后台启动绑定自修复 PID=$REPAIR_PID"
echo ""
echo "部署日志：  tail -f /var/log/ipes_nohup.log"
echo "修复日志：  tail -f /var/log/ipes_repair.log"

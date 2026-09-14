#!/usr/bin/env bash
# IPES 一键部署 r21（OSS 短链版：调优 + 部署）
# 用法：
#   curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/inline_deploy_r21_oss.sh | bash -s -- \
#     --ak 06d78b19bd0d9fc0aa300c6d \
#     --sk 16d6c46443308e62bb51f22c074a90ed \
#     --jwt eyJ... \
#     --isp 电信 [--province 浙江 --city 杭州 --num-dirs 12 --usbw 200]
# 未传 --province/--city 时，自动按本机公网 IP 识别；识别失败兜底为 浙江/杭州。
set +e

AK=""; SK=""; JWT=""; ISP="电信"; PROVINCE=""; CITY=""; NUM_DIRS=12; USBW=200; BW_NUM=1
NODE_NAT_TYPE="public"; NODE_RESOURCE_TYPE=2; NODE_DIAL_TYPE="staticNetSingle"; NODE_SINGLE_IP_RADIO=0
ADMIN_API_HOST="https://admin.zhouyi.top"; BUSINESS_ID=41

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
    *) echo "[WARN] 未知参数: $1"; shift ;;
  esac
done

if [[ -z "$AK" || -z "$SK" || -z "$JWT" ]]; then
  echo "[ERROR] 缺少 --ak / --sk / --jwt，必须提供"
  echo "示例（注意：值要写裸值，不要带尖括号 <>，否则会被 shell 当成输入重定向）："
  echo "  curl -fsSL ... | bash -s -- --ak 你的渠道AK --sk 你的渠道SK --jwt 你的JWT --isp 电信"
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

# ============ A) 系统调优（r21：磁盘吞吐 + 上下行）============
#   独立脚本 ipes_tune.sh：磁盘队列 / 挂载参数 / 内核 sysctl / 网卡 / nofile
#   幂等、可重复执行、装机后由 ipes-tune.service 开机自动重放
#   主脚本 r21 内嵌同一份调优作兜底（这里先跑一遍，后面所有步骤都受益）
TUNE_SHA="4082428fe8df7c9fcbf5ac524d6af2249eafd871"
TUNE1="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_tune.sh?t=$(date +%s)"
TUNE2="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@${TUNE_SHA}/ipes_tune.sh"
TUNE_OK=0
for u in "$TUNE1" "$TUNE2"; do
  curl -fsSL -m 30 "$u" -o /root/ipes_tune.sh 2>/dev/null && grep -q "IPES TUNE" /root/ipes_tune.sh && { TUNE_OK=1; break; }
done
if [ "$TUNE_OK" = "1" ]; then
  echo "[tune] $(grep -o 'TUNE_VER=\"[^\"]*\"' /root/ipes_tune.sh | head -1) applying ..."
  bash /root/ipes_tune.sh 2>&1 | tail -30
else
  echo "[tune][WARN] 调优脚本下载失败；主脚本 r21 内嵌同一份，部署时会补做"
fi

# ============ B) 完整部署（r21：真实 nodeId 绑定 + 内嵌调优兜底）============
SRC_SHA="4082428fe8df7c9fcbf5ac524d6af2249eafd871"
SRC1="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_deploy_full.sh?t=$(date +%s)"
SRC2="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@${SRC_SHA}/ipes_deploy_full.sh"
for u in "$SRC1" "$SRC2"; do
  curl -fsSL -m 60 "$u" -o /root/ipes_full.sh && grep -q singleIpRadio /root/ipes_full.sh && break
done
sed -i 's|^mirrorlist=|#mirrorlist=|g;s|^#\?baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
export NODE_ACTIVATE_TOKEN="$JWT"
nohup setsid bash /root/ipes_full.sh --ak "$AK" --sk "$SK" --isp "$ISP" --num-dirs "$NUM_DIRS" --skip-olmt >/var/log/ipes_nohup.log 2>&1 </dev/null &
DEPLOY_PID=$!
echo "已后台启动部署 PID=$DEPLOY_PID"

# ============ C) 业务绑定自修复 ============
cat > /root/ipes_repair_binding.py <<'PY'
import json, os, re, ssl, subprocess, sys, time, urllib.request, urllib.error

JWT = os.environ.get('NODE_ACTIVATE_TOKEN','')
if not JWT:
    print("[ERROR] NODE_ACTIVATE_TOKEN 未设置"); sys.exit(1)

BASE = os.environ.get('ADMIN_API_HOST','https://admin.zhouyi.top')
BUSINESS_ID = int(os.environ.get('BUSINESS_ID','41'))
ISP = os.environ.get('ISP','电信')
PROVINCE = os.environ.get('PROVINCE','')
CITY = os.environ.get('CITY','')
NODE_NAT_TYPE = os.environ.get('NODE_NAT_TYPE','public')
NODE_RESOURCE_TYPE = int(os.environ.get('NODE_RESOURCE_TYPE','2'))
NODE_DIAL_TYPE = os.environ.get('NODE_DIAL_TYPE','staticNetSingle')
NODE_SINGLE_IP_RADIO = int(os.environ.get('NODE_SINGLE_IP_RADIO','0'))
NODE_USBW = int(os.environ.get('NODE_USBW','200'))
NODE_BW_NUM = int(os.environ.get('NODE_BW_NUM','1'))

CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE

def log(msg): print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

def get_ipes_sn():
    """读容器内真正的 IPES 业务 SN（76 位 hex），不要用后台 UUID sn。"""
    for path in ['/app/ipes/bin/ipes_sn', '/opt/soft/disk/IPES_SN']:
        try:
            out = subprocess.check_output(['docker','exec','ipes','cat',path], stderr=subprocess.DEVNULL, timeout=10)
            sn = out.decode('utf-8','replace').strip()
            if sn: return sn
        except Exception: continue
    return ''

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

def find_node_by_ip(pubip, max_pages=80):
    candidates = []
    for page in range(1, max_pages + 1):
        code, txt = admin_call(f"/api/edgeNode/getEdgeNodeList?page={page}&pageSize=200")
        if code != 200:
            log(f"getEdgeNodeList page {page} failed HTTP {code}: {txt[:200]}"); break
        d = json.loads(txt)
        arr = (d.get('data') or {}).get('list', [])
        total = (d.get('data') or {}).get('total', 0)
        for it in arr:
            if it.get('publicIP') == pubip:
                candidates.append(it)
        if page * 200 >= total: break
        time.sleep(0.15)
    if not candidates: return None
    stage_rank = {'inService': 3, 'configured': 2, 'waitAudit': 1}
    candidates.sort(key=lambda x: (stage_rank.get(x.get('stage'), 0), x.get('nodeUpdateTime') or x.get('UpdatedAt') or ''), reverse=True)
    return candidates[0]

def is_bound(ni):
    if not ni: return False
    if ni.get('stage') != 'inService': return False
    info = ni.get('nominalInfo') or {}
    return info.get('vendorSuggestCustomers') == BUSINESS_ID and info.get('usbw') == NODE_USBW

def do_bind(node_id):
    log(f"为活跃节点 {node_id} 补绑业务 {BUSINESS_ID}")
    # 业务 ID 必须取容器内 76hex IPES SN，否则后台会写 UUID 占位符
    biz_sn = get_ipes_sn()
    log(f"  -> 容器 IPES SN: {biz_sn[:16]}...{biz_sn[-12:]} (len={len(biz_sn)})")
    for stage in ['configured','configured']:
        code, txt = admin_call("/api/edgeNode/stateflow", {"nodes": [node_id], "stage": stage}, "POST")
        log(f"  -> {stage}: HTTP {code} {txt[:120]}")
        time.sleep(1)
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
    code, txt = admin_call("/api/edgeNode/stateflow", {"nodes": [node_id], "stage": "inService", "hostname": biz_sn}, "POST")
    log(f"  -> inService: HTTP {code} {txt[:120]}")

def main():
    pubip = get_public_ip()
    if not pubip: log("[ERROR] 无法获取公网 IP"); sys.exit(1)
    log(f"本机公网 IP: {pubip}")
    ni = None
    for i in range(48):
        ni = find_node_by_ip(pubip)
        if ni: break
        log(f"等待节点出现在后台... ({i+1}/48)"); time.sleep(10)
    if not ni: log("[ERROR] 8 分钟未找到节点，放弃"); sys.exit(1)
    log(f"找到节点: {ni.get('nodeID')} stage={ni.get('stage')} vendor={(ni.get('nominalInfo') or {}).get('vendorSuggestCustomers')} usbw={(ni.get('nominalInfo') or {}).get('usbw')}")
    if is_bound(ni): log("[OK] 已绑定，无需修复"); sys.exit(0)
    do_bind(ni.get('nodeID'))
    time.sleep(2)
    ni = find_node_by_ip(pubip)
    if is_bound(ni): log("[OK] 修复成功"); sys.exit(0)
    else: log("[ERROR] 修复后仍未达标"); sys.exit(1)

if __name__ == '__main__':
    main()
PY

export NODE_ACTIVATE_TOKEN="$JWT" ADMIN_API_HOST BUSINESS_ID ISP PROVINCE CITY \
       NODE_NAT_TYPE NODE_RESOURCE_TYPE NODE_DIAL_TYPE NODE_SINGLE_IP_RADIO \
       NODE_USBW NODE_BW_NUM

nohup setsid python3 /root/ipes_repair_binding.py >/var/log/ipes_repair.log 2>&1 </dev/null &
REPAIR_PID=$!
echo "已后台启动绑定自修复 PID=$REPAIR_PID"
echo ""
echo "部署日志：  tail -f /var/log/ipes_nohup.log"
echo "修复日志：  tail -f /var/log/ipes_repair.log"

# ============ D) 部署后容器调优 + 健康看门狗（后台等容器起来再应用） ============
cat > /root/ipes_postopt.sh <<'EOF3'
#!/bin/bash
# 等 ipes 容器起来（最多 5 分钟）
for i in $(seq 1 60); do
  docker inspect ipes >/dev/null 2>&1 && break
  sleep 5
done
# 容器 I/O/CPU 优先级（live 生效，不重建容器、不动缓存）
docker update --blkio-weight 1000 --cpu-shares 1024 ipes 2>/dev/null
# 健康看门狗：容器挂了自动拉起 + /data 超 85% 告警
cat > /usr/local/bin/ipes-health.sh <<'HEOF'
#!/bin/bash
running=$(docker inspect -f '{{.State.Running}}' ipes 2>/dev/null)
if [ "$running" != "true" ]; then
  logger -t ipes-health "ipes not running -> restart"
  docker start ipes 2>/dev/null || { systemctl restart docker >/dev/null 2>&1; docker start ipes 2>/dev/null; }
fi
use=$(df -P /data 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
[ -n "$use" ] && [ "$use" -ge 85 ] && logger -t ipes-health "WARN /data usage ${use}% >= 85%"
HEOF
chmod +x /usr/local/bin/ipes-health.sh
cat > /etc/systemd/system/ipes-health.service <<'HEOF'
[Unit]
Description=IPES health & disk watchdog
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ipes-health.sh
HEOF
cat > /etc/systemd/system/ipes-health.timer <<'HEOF'
[Unit]
Description=Run IPES health watchdog every 2 min
[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
HEOF
systemctl daemon-reload 2>/dev/null
systemctl enable --now ipes-health.timer 2>/dev/null
echo "[postopt] blkio/cpu-priority + health watchdog applied at $(date)"
EOF3
chmod +x /root/ipes_postopt.sh
nohup setsid bash /root/ipes_postopt.sh >/var/log/ipes_postopt.log 2>&1 </dev/null &
echo "已后台启动容器调优/看门狗 PID=$!"

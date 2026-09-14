#!/usr/bin/env bash
# IPES 一键部署 r20（OSS 短链版）
# 用法：
#   curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/inline_deploy_r20_oss.sh | bash -s -- \
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
  echo "示例：curl -fsSL ... | bash -s -- --ak <ak> --sk <sk> --jwt <jwt> --isp 电信"
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

# ============ A) 系统调优 ============
# 单一权威 sysctl 文件（合并 NAT/uplink + 性能项，避免多文件冲突导致重启后值漂移）
cat > /etc/sysctl.d/99-ipes.conf <<'EOF'
# ===== IPES PCDN 专属调优 (单一权威文件) =====
# --- TCP/UDP 缓冲 ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
# --- 连接队列/并发 ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 100000
net.core.netdev_budget = 1000
net.core.netdev_budget_usecs = 4000
net.ipv4.tcp_max_syn_backlog = 65535
net.core.rps_sock_flow_entries = 32768
net.core.busy_poll = 50
net.core.busy_read = 50
# --- TCP 行为 ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_max_orphans = 65536
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_retries2 = 10
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_mem = 36134 72268 144537
net.ipv4.tcp_congestion_control = cubic
# --- 端口/路由/邻居表 ---
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.route.max_size = 2097152
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 16384
net.ipv4.neigh.default.gc_thresh3 = 65536
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
# --- conntrack ---
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 300
net.netfilter.nf_conntrack_udp_timeout_stream = 600
net.netfilter.nf_conntrack_generic_timeout = 600
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 60
# --- qdisc ---
net.core.default_qdisc = fq
# --- 文件/进程句柄 ---
fs.file-max = 4000000
fs.aio-max-nr = 1048576
fs.inotify.max_user_watches = 1048576
kernel.pid_max = 4194304
# --- 内存/脏页 ---
vm.swappiness = 0
vm.overcommit_memory = 1
vm.vfs_cache_pressure = 10
vm.dirty_ratio = 40
vm.dirty_background_ratio = 30
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 50
vm.zone_reclaim_mode = 0
vm.min_free_kbytes = 65536
EOF
rm -f /etc/sysctl.d/98-ipes-nat.conf /etc/sysctl.d/99-ipes-perf.conf 2>/dev/null
modprobe nf_conntrack 2>/dev/null
sysctl -e -p /etc/sysctl.d/99-ipes.conf
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null
nic=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [ -n "$nic" ]; then ncpu=$(nproc); mask=$(printf '%x' $(( (1<<ncpu)-1 ))); for q in /sys/class/net/$nic/queues/rx-*; do echo "$mask" > "$q/rps_cpus" 2>/dev/null; echo 4096 > "$q/rps_flow_cnt" 2>/dev/null; done; tc qdisc replace dev "$nic" root fq 2>/dev/null; fi
# 磁盘识别为SSD + 调度器/nomerges/read_ahead 优化(缓存读写更低延迟)
for d in /sys/block/vd* /sys/block/sd* /sys/block/xvd*; do
  [ -d "$d" ] || continue
  echo 0 > "$d/queue/rotational" 2>/dev/null
  echo none > "$d/queue/scheduler" 2>/dev/null
  echo 2048 > "$d/queue/read_ahead_kb" 2>/dev/null
  echo 1024 > "$d/queue/nr_requests" 2>/dev/null
  echo 2 > "$d/queue/nomerges" 2>/dev/null
done
# 开机自启: 重放磁盘+队列调优(避免重启回到默认)
cat > /usr/local/bin/ipes-tune.sh <<'EOF2'
#!/bin/bash
# IPES 磁盘/队列/RPS 调优 - 每次开机重放，避免重启回默认
for d in /sys/block/vd* /sys/block/sd* /sys/block/xvd* /sys/block/nvme*; do
  [ -d "$d" ] || continue
  echo 0 > "$d/queue/rotational" 2>/dev/null
  echo none > "$d/queue/scheduler" 2>/dev/null
  echo 2048 > "$d/queue/read_ahead_kb" 2>/dev/null
  echo 1024 > "$d/queue/nr_requests" 2>/dev/null
  echo 2 > "$d/queue/nomerges" 2>/dev/null
done
# 拥塞控制：能开 BBR 就开，CentOS7 3.10 内核无 tcp_bbr 则回落 cubic
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null
# 所有业务网卡：fq 队列(pacing) + RPS 收包绑全核(单队列 virtio 必做，否则重启丢)
ncpu=$(nproc); mask=$(printf '%x' $(( (1<<ncpu)-1 )))
for dev in $(ls /sys/class/net/ 2>/dev/null); do
  case "$dev" in lo|docker*|veth*|br-*|cni*|flannel*|virbr*) continue;; esac
  tc qdisc replace dev "$dev" root fq 2>/dev/null || true
  for q in /sys/class/net/$dev/queues/rx-*; do
    [ -d "$q" ] || continue
    echo "$mask" > "$q/rps_cpus" 2>/dev/null
    echo 4096 > "$q/rps_flow_cnt" 2>/dev/null
  done
done
EOF2
chmod +x /usr/local/bin/ipes-tune.sh
cat > /etc/systemd/system/ipes-tune.service <<'EOF2'
[Unit]
Description=IPES disk and qdisc tuning
After=network.target local-fs.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ipes-tune.sh

[Install]
WantedBy=multi-user.target
EOF2
systemctl daemon-reload 2>/dev/null
systemctl enable ipes-tune.service 2>/dev/null
iptables -t raw -A PREROUTING -j NOTRACK 2>/dev/null; iptables -t raw -A OUTPUT -j NOTRACK 2>/dev/null

# ============ B) 完整部署（r20：用真实 nodeId 绑定，根治业务没落盘） ============
SRC1="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_deploy_full.sh?t=$(date +%s)"
SRC2="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@a214464/ipes_deploy_full.sh"
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
if [ -n "$use" ] && [ "$use" -ge 85 ] 2>/dev/null; then
  logger -t ipes-health "WARN /data usage ${use}% >= 85%"
fi
# ★必须显式 exit 0★：Type=oneshot 以脚本退出码判定成败，否则磁盘 <85% 时服务恒被判 failed
exit 0
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

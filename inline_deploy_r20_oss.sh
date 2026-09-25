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
# [REV] wrapper-finish-passthrough-20260919b-chancache

AK=""; SK=""; JWT=""; ISP="电信"; PROVINCE=""; CITY=""; NUM_DIRS=12; USBW=200; BW_NUM=1
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
    *) echo "[WARN] 未知参数: $1"; shift ;;
  esac
done

if [ "${FINISH_ONLY:-0}" != "1" ] && [[ -z "$AK" || -z "$SK" || -z "$JWT" ]]; then
  echo "[ERROR] 缺少 --ak / --sk / --jwt，必须提供（--finish-only 原地补齐模式不注册设备，可免）"
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

# ============ A) 系统调优（v2 小内存机型上行强化，2026-09-19） ============
# 文件句柄上限：容器需 dockerd 继承；FINISH_ONLY 模式不重启 docker 以免掉量
tune_fd_limits(){
  local nr_open=$(cat /proc/sys/fs/nr_open 2>/dev/null || echo 1048576)
  local LIM=$(( nr_open < 1048576 ? nr_open : 1048576 ))
  cat > /etc/security/limits.d/99-ipes.conf <<EOF
* soft nofile $LIM
* hard nofile $LIM
root soft nofile $LIM
root hard nofile $LIM
EOF
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/limits.conf <<EOF
[Service]
LimitNOFILE=$LIM
LimitNPROC=$LIM
EOF
  systemctl daemon-reload >/dev/null 2>&1
  local cur=$(systemctl show docker -p LimitNOFILE --value 2>/dev/null)
  if [ "$cur" != "$LIM" ] && systemctl is-active docker >/dev/null 2>&1; then
    if [ "${FINISH_ONLY:-0}" = "1" ]; then
      echo "[INFO] dockerd LimitNOFILE=$cur≠$LIM，FINISH_ONLY 模式跳过重启（下次 docker 重启自然生效）"
    else
      echo "[INFO] dockerd LimitNOFILE=$cur≠$LIM，重载 docker 使容器继承新句柄上限（约数秒掉上行）"
      systemctl restart docker >/dev/null 2>&1
    fi
  else
    echo "[INFO] dockerd 句柄上限已一致（$cur），无需重启"
  fi
}

# 磁盘队列 + 文件系统（快速缓存下行）；仅动 root 盘，幂等（哨兵标记）
tune_disk(){
  [ -f /var/lib/.ipes_disk_tuned ] && { echo "[INFO] 磁盘调优已做过，跳过"; return 0; }
  local disk=$(lsblk -ndo NAME,MOUNTPOINT 2>/dev/null | awk '$2=="/"{print $1}' | head -1)
  [ -z "$disk" ] && disk=vda
  if [ -b "/sys/block/$disk" ]; then
    echo none > /sys/block/$disk/queue/scheduler 2>/dev/null
    echo 0    > /sys/block/$disk/queue/rotational 2>/dev/null
    echo 0    > /sys/block/$disk/queue/add_random 2>/dev/null
    echo 0    > /sys/block/$disk/queue/nomerges 2>/dev/null
    echo 2    > /sys/block/$disk/queue/rq_affinity 2>/dev/null
    # read_ahead_kb 保持 256：实测并发读随预读增大单调下降（4M 时 -30%）
  fi
  local fstype=$(findmnt -no FSTYPE / 2>/dev/null)
  if echo "$fstype" | grep -q ext4; then
    mount -o remount,commit=60,barrier=0 / 2>/dev/null
    if [ -f /etc/fstab ]; then
      cp -a /etc/fstab "/etc/fstab.ipes-bak.$(date +%s)" 2>/dev/null
      # 修正：把 commit=60,barrier=0 写进第4列(挂载选项)，并复位第5/6列，避免污染 pass 字段导致重启后根分区只读
      grep -q '# ipes-tuned' /etc/fstab || awk 'BEGIN{OFS="\t"} {if($2=="/"&&$3=="ext4"){$4="defaults,noatime,nodiratime,commit=60,barrier=0";$5="1";$6="1"} print}' /etc/fstab >/etc/fstab.new && mv /etc/fstab.new /etc/fstab 2>/dev/null
    fi
  elif echo "$fstype" | grep -q xfs; then
    mount -o remount,logbsize=256k / 2>/dev/null
  fi
  echo "[INFO] 磁盘调优完成"
  touch /var/lib/.ipes_disk_tuned
}

# 按内存动态计算 tcp/udp 内存上限：小内存机不被压住，大内存机按规格放宽
_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
_PG=$(( _MB * 256 ))
_T1=$(( _PG*15/100 )) _T2=$(( _PG*30/100 )) _T3=$(( _PG*60/100 ))

cat > /etc/sysctl.d/99-ipes.conf <<EOF
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mem = ${_T1} ${_T2} ${_T3}
net.ipv4.udp_mem = ${_T1} ${_T2} ${_T3}
net.ipv4.udp_rmem_min = 32768
net.ipv4.udp_wmem_min = 32768
net.ipv4.tcp_limit_output_bytes = 1048576
net.ipv4.tcp_autocorking = 0
net.core.default_qdisc = fq
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 100000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_ecn = 0
fs.file-max = 4000000
fs.aio-max-nr = 1048576
fs.inotify.max_user_watches = 524288
vm.swappiness = 0
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
vm.vfs_cache_pressure = 10
vm.min_free_kbytes = 65536
vm.overcommit_memory = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.core.netdev_budget = 3000
net.core.netdev_budget_usecs = 4000
net.core.rps_sock_flow_entries = 32768
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
net.core.optmem_max = 16777216
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_retries2 = 8
kernel.pid_max = 4194304
EOF
modprobe nf_conntrack 2>/dev/null
sysctl -e -p /etc/sysctl.d/99-ipes.conf
nic=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [ -n "$nic" ]; then
  ncpu=$(nproc); mask=$(printf '%x' $(( (1<<ncpu)-1 )))
  for q in /sys/class/net/$nic/queues/rx-*; do
    echo "$mask" > "$q/rps_cpus" 2>/dev/null
    echo 4096 > "$q/rps_flow_cnt" 2>/dev/null
  done
  tc qdisc replace dev "$nic" root fq 2>/dev/null
  ethtool -G "$nic" rx 4096 tx 4096 2>/dev/null
  ip link set "$nic" txqueuelen 10000 2>/dev/null
fi
# CPU 调度器锁定 performance：SWAS 单核机默认常驻 powersave/ondemand，
# 频率升降引入抖动、压不稳 200M 上行持续吞吐；锁定后去抖、稳定跑量（重启即失，靠开机重放）。
for _g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$_g" 2>/dev/null
done
# 透明大页关闭：减少内存分配延迟抖动（PCDN 海量小缓存/小包场景）
for _t in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
  echo never > "$_t" 2>/dev/null
done
# 开机重放（/sys 重启即失）：沿用脚本内 pcdn-disk-tune.service 同款做法
if command -v systemctl >/dev/null 2>&1; then
  cat > /etc/systemd/system/ipes-gov-tuned.service <<'GOV_EOF'
[Unit]
Description=IPES CPU governor(performance) + THP(never) replay on boot
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g 2>/dev/null; done; for t in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do echo never > $t 2>/dev/null; done'
[Install]
WantedBy=multi-user.target
GOV_EOF
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable ipes-gov-tuned.service >/dev/null 2>&1
fi
tune_fd_limits
tune_disk
# ============ A2) 上行优先脏页方案（方案 A：覆盖 99-pcdn-disk.conf 的 30/50） ============
# ipes_deploy_full.sh 会生成 99-pcdn-disk.conf(dirty=30/vfs=50)，按字母序晚于 99-ipes.conf 会覆盖上行方案。
# 这里用排序最后的 conf(99z > 99p)复述 20/10，保证「上行稳定优先」在运行期与开机后都生效（幂等，重跑安全）。
cat > /etc/sysctl.d/99z-ipes-uplink.conf <<'EOF'
vm.dirty_background_ratio = 10
vm.dirty_ratio = 20
vm.vfs_cache_pressure = 10
EOF
sysctl -e -p /etc/sysctl.d/99z-ipes-uplink.conf >/dev/null 2>&1
echo "[INFO] 上行优先脏页方案(20/10)已锁定，覆盖 99-pcdn-disk.conf 的 30/50"
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
for u in "$SRC1" "$SRC2" "$SRC3"; do
  if curl -fsSL -m 25 "$u" -o /root/ipes_full.sh 2>/dev/null \
     && [ "$(wc -c </root/ipes_full.sh 2>/dev/null | tr -d ' ')" -gt 100000 ] \
     && grep -q singleIpRadio /root/ipes_full.sh \
     && grep -q -- '--finish-only' /root/ipes_full.sh; then
    if grep -q 'harden_yum_conf' /root/ipes_full.sh && grep -q 'lite_fused_tune' /root/ipes_full.sh; then
      FULL_OK=1; FULL_SRC="$u"; break
    else
      echo "[WARN] $u 返回的 full 脚本缺 harden_yum_conf 标记（旧版/CDN 缓存），换源重试"
    fi
  else
    echo "[WARN] $u 未取到有效 full 脚本，换源重试"
  fi
done
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
  exec setsid bash /root/ipes_full.sh --ak "$AK" --sk "$SK" --isp "$ISP" --num-dirs "$NUM_DIRS" --skip-olmt $FINISH_ARG >/var/log/ipes_nohup.log 2>&1 </dev/null
) 9>"$LOCK_FILE" &
DEPLOY_PID=$!
echo "已后台启动部署 PID=$DEPLOY_PID（已持锁 $LOCK_FILE，互斥生效）"

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
ISP = os.environ.get('ISP','电信')
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

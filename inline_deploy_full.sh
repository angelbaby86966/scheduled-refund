#!/usr/bin/env bash
# =============================================================================
# inline_deploy_full.sh  ——  IPES/PCDN 一键部署（融合版）
#   ① 自包含部署：Docker + 清理旧节点 + 12 路 custom.yml(:1.3.0) + 起容器 + 保活
#      （不依赖任何 zyy-go OSS 旧链接，唯一外网依赖是 Docker 镜像仓库 + 可选对齐脚本）
#   ② 平台绑定：用 JWT 把本机节点绑定到业务 BUSINESS_ID(默认41)，写 nominalInfo
#   ③ 流转服务中：stateflow 把节点从 待配置 → 服务中，并把 76hex 业务SN 写进业务标签
#
# 用法（一条命令）：
#   curl -fsSL <本脚本URL> | bash -s -- \
#     --ak <渠道ak> --sk <渠道sk> --jwt <平台JWT> --isp 电信 \
#     [--province 浙江 --city 杭州 --num-dirs 12 --usbw 200 --t 2]
#
#   --t 2 = 省外镜像(youkai-latest)    --t 3 = 省内镜像(youkai-sp-latest)   默认 2
#   --num-dirs/-n  happ 路数（默认 12，拉满）
#   --no-align      跳过末尾对齐阶段（预热调优/全锥NAT/tc/cache 对齐）
#   --bind-only     只跑「绑定+流转服务中」（部署已就绪、仅补绑定时用）
#   镜像锁定 :1.3.0
# =============================================================================
trap '' HUP   # 终端断开(SIGHUP)不杀进程；Ctrl-C(INT)仍可中断

# ----------------------------- 参数解析 -----------------------------
AK=""; SK=""; JWT=""; ISP=""; PROVINCE=""; CITY=""
NUM_DIRS=12; USBW=200; BW_NUM=1; IMG_CHOICE=2
BUSINESS_ID=41; ADMIN_API_HOST="https://admin.zhouyi.top"
NO_ALIGN=0; BIND_ONLY=0
NODE_NAT_TYPE="public"; NODE_RESOURCE_TYPE=2; NODE_DIAL_TYPE="staticNetSingle"; NODE_SINGLE_IP_RADIO=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ak) AK="$2"; shift 2;;
    --sk) SK="$2"; shift 2;;
    --jwt|--token|--node-activate-token) JWT="$2"; shift 2;;
    --isp) ISP="$2"; shift 2;;
    --reg-isp|-i) REG_ISP="$2"; shift 2;;
    --t) IMG_CHOICE="$2"; shift 2;;
    --num-dirs|-n) NUM_DIRS="$2"; shift 2;;
    --usbw) USBW="$2"; shift 2;;
    --bw-num) BW_NUM="$2"; shift 2;;
    --province) PROVINCE="$2"; shift 2;;
    --city) CITY="$2"; shift 2;;
    --business-id) BUSINESS_ID="$2"; shift 2;;
    --admin-host) ADMIN_API_HOST="$2"; shift 2;;
    --no-align) NO_ALIGN=1; shift;;
    --bind-only) BIND_ONLY=1; shift;;
    *) echo "[WARN] 未知参数: $1"; shift;;
  esac
done

[ -z "$JWT" ] && { echo "[ERROR] 缺少 --jwt（平台激活 JWT）"; exit 1; }
[[ -z "$ISP" && -z "$REG_ISP" ]] && { echo "[ERROR] 必须指定 --isp 电信/联通/移动 或 --reg-isp 1/2/3"; exit 1; }
case "$ISP" in
  电信) REG_ISP=1;; 联通) REG_ISP=2;; 移动) REG_ISP=3;;
  1|2|3) [[ -z "$REG_ISP" ]] && REG_ISP=$ISP;;
esac
[[ -z "$REG_ISP" ]] && REG_ISP=1
case "$IMG_CHOICE" in
  2) DOCKER_IMAGE="ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:1.3.0";;
  3) DOCKER_IMAGE="ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-sp-latest:1.3.0";;
  *) echo "[ERROR] --t 仅支持 2(省外)/3(省内)"; exit 1;;
esac

# 自动识别省份/城市（未显式传入时）
get_location_info() {
  local ip_info=$(curl -s myip.ipip.net 2>/dev/null)
  if [ -n "$ip_info" ]; then
    local p=$(echo "$ip_info" | awk -F ' ' '{print $4}' | tr -d ',')
    local c=$(echo "$ip_info" | awk -F ' ' '{print $5}' | tr -d ',')
    [ -n "$p" ] && [ "$p" != "null" ] && [ "$p" != " " ] && PROVINCE="$p"
    [ -n "$c" ] && [ "$c" != "null" ] && [ "$c" != " " ] && CITY="$c"
  fi
  [ -z "$PROVINCE" ] && PROVINCE="浙江"
  [ -z "$CITY" ] && CITY="杭州"
}
if [ -z "$PROVINCE" ] || [ -z "$CITY" ]; then
  echo "[INFO] 未提供 --province/--city，按公网 IP 自动识别..."
  get_location_info
  echo "[INFO] 地理位置: $PROVINCE / $CITY"
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info(){ echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $1"; }
[ "$(id -u)" -ne 0 ] && { log_error "需 root 运行：sudo bash $0"; exit 1; }

# ============================ A) 系统调优（本地，无 AK） ============================
sys_tune(){
  log_info "=== 系统调优：conntrack / bbr / 端口 / RPS ==="
  # 按内存动态计算 tcp/udp 内存上限：小内存机不被压住，大内存机按规格放宽
  local _mb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  local _pg=$(( _mb * 256 ))   # 每 MB = 256 个 4KB 页
  local _t1=$(( _pg*15/100 )) _t2=$(( _pg*30/100 )) _t3=$(( _pg*60/100 ))
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
net.ipv4.tcp_mem = ${_t1} ${_t2} ${_t3}
net.ipv4.udp_mem = ${_t1} ${_t2} ${_t3}
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
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_available_congestion_control = bbr cubic reno
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.core.netdev_budget = 3000
net.core.netdev_budget_usecs = 4000
net.core.rps_sock_flow_entries = 32768
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
EOF
  modprobe nf_conntrack tcp_bbr 2>/dev/null
  sysctl -e -p /etc/sysctl.d/99-ipes.conf >/dev/null 2>&1
  sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null
  local nic=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -n "$nic" ]; then
    local ncpu=$(nproc); local mask=$(printf '%x' $(( (1<<ncpu)-1 )))
    for q in /sys/class/net/$nic/queues/rx-*; do
      echo "$mask" > "$q/rps_cpus" 2>/dev/null
      echo 4096 > "$q/rps_flow_cnt" 2>/dev/null
    done
    tc qdisc replace dev "$nic" root fq 2>/dev/null
    ethtool -G "$nic" rx 4096 tx 4096 2>/dev/null
    ip link set "$nic" txqueuelen 10000 2>/dev/null
  fi
  tune_fd_limits
  tune_disk
  # 【r20-fix6】不再使用 iptables raw NOTRACK：会让回包脱离 conntrack，与 firewalld 共存时
  # 导致已建立连接回包被 INPUT 丢弃 → SSH/云助手断连（即此前“一跑脚本就断网”根因）。
  log_info "系统调优完成"
}

tune_fd_limits(){
  # 文件句柄上限（PCDN 高并发连接，最易被忽略；默认 ulimit 仅 4096）。容器需 dockerd 继承。
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
  # 仅当 dockerd 当前 LimitNOFILE 与配置不一致才重启（避免跑量时误重启，重启会短暂掉上行）
  local cur=$(systemctl show docker -p LimitNOFILE --value 2>/dev/null)
  if [ "$cur" != "$LIM" ] && systemctl is-active docker >/dev/null 2>&1; then
    log_info "dockerd LimitNOFILE=$cur≠$LIM，重载 docker 使容器继承新句柄上限（约数秒掉上行）"
    systemctl restart docker >/dev/null 2>&1
  fi
}

tune_disk(){
  # 磁盘队列 + 文件系统（快速缓存下行：大块并发写盘）。仅动 root 盘，幂等。
  [ -f /var/lib/.ipes_disk_tuned ] && { log_info "磁盘调优已做过，跳过"; return 0; }
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
      grep -q '# ipes-tuned' /etc/fstab || sed -i -E 's|(.*ext4.*defaults.*)|\1,commit=60,barrier=0 # ipes-tuned|' /etc/fstab 2>/dev/null
    fi
  elif echo "$fstype" | grep -q xfs; then
    mount -o remount,logbsize=256k / 2>/dev/null
  fi
  log_info "磁盘调优完成"
  touch /var/lib/.ipes_disk_tuned
}

# ============================ B) 自包含部署（复用 ecache_onekey_deploy 逻辑） ============================
version_compare(){
  if [[ $1 == $2 ]]; then echo 0; return; fi
  local IFS=.; local i v1=($1) v2=($2)
  for ((i=${#v1[@]}; i<${#v2[@]}; i++)); do v1[i]=0; done
  for ((i=0; i<${#v1[@]}; i++)); do
    [[ -z ${v2[i]} ]] && v2[i]=0
    ((10#${v1[i]} > 10#${v2[i]})) && { echo 1; return; }
    ((10#${v1[i]} < 10#${v2[i]})) && { echo -1; return; }
  done; echo 0
}
detect_os(){
  if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; VER=$VERSION_ID;
  elif [ -f /etc/centos-release ]; then OS=centos; VER=$(grep -oE '[0-9]+' /etc/centos-release|head -1);
  elif [ -f /etc/debian_version ]; then OS=debian; VER=$(cat /etc/debian_version);
  else OS=unknown; fi; echo "$OS"
}
install_docker_centos(){
  local cv=$1
  [ "$cv" -eq 8 ] && { dnf module enable -y container-tools 2>/dev/null || true; }
  [ "$cv" -eq 7 ] && find /etc/yum.repos.d/ -type f -name "*.repo" -delete 2>/dev/null
  cat > /etc/yum.repos.d/CentOS-Base.repo <<EOF
[base]
name=CentOS-\$releasever - Base - aliyun
baseurl=http://mirrors.aliyun.com/centos/\$releasever/os/\$basearch/
gpgcheck=1
gpgkey=http://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
enabled=1
[extras]
name=CentOS-\$releasever - Extras - aliyun
baseurl=http://mirrors.aliyun.com/centos/\$releasever/extras/\$basearch/
gpgcheck=1
gpgkey=http://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
enabled=1
EOF
  cat > /etc/yum.repos.d/docker-ce.repo <<EOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/docker-ce/linux/centos/gpg
EOF
  yum install -y yum-utils device-mapper-persistent-data lvm2
  yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}
install_docker_debian(){
  local dv=$1
  case $dv in
    bookworm|bullseye|buster)
      tee /etc/apt/sources.list <<EOF
deb https://mirrors.aliyun.com/debian/ $dv main non-free contrib
deb https://mirrors.aliyun.com/debian-security/ $dv-security main
EOF
      ;;
    *) log_error "不支持的 Debian 版本: $dv"; return 1;;
  esac
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl gnupg iproute2
  curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian $dv stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}
configure_docker_mirror(){
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["https://stxam7vz.mirror.aliyuncs.com"]
}
EOF
  systemctl daemon-reload 2>/dev/null || true
}
ensure_docker(){
  if command -v docker &>/dev/null; then
    local cur=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    log_info "已安装 Docker: $cur"
    if [ "$(version_compare "$cur" "23.0.0")" -lt 0 ]; then
      log_warn "版本 < 23.0.0，重装"; yum remove -y docker\* 2>/dev/null || apt-get remove -y docker-ce\* 2>/dev/null || true
    else
      if [ ! -f /etc/docker/daemon.json ] || ! grep -q "stxam7vz" /etc/docker/daemon.json 2>/dev/null; then
        configure_docker_mirror; systemctl restart docker 2>/dev/null || true
      fi
      return 0
    fi
  fi
  local OS=$(detect_os)
  if [ "$OS" = "centos" ]; then
    local cv=$([ -f /etc/centos-release ] && grep -oE '[0-9]+' /etc/centos-release|head -1 || echo 7)
    install_docker_centos "$cv" || { log_error "Docker 安装失败"; exit 1; }
  elif [ "$OS" = "debian" ]; then
    local dv=$(cat /etc/debian_version)
    case $dv in 11*) dv=bullseye;; 12*) dv=bookworm;; 10*) dv=buster;; esac
    install_docker_debian "$dv" || { log_error "Docker 安装失败"; exit 1; }
  else log_error "不支持的系统: $OS"; exit 1; fi
  configure_docker_mirror
  systemctl enable --now docker 2>/dev/null || { service docker start 2>/dev/null || true; }
  log_info "Docker 安装完成: $(docker --version)"
}
cleanup_old(){
  log_info "=== 清理旧 IPES / Docker 容器 ==="
  if [ "$(docker ps -q 2>/dev/null)" ]; then docker stop $(docker ps -q) >/dev/null 2>&1; fi
  if [ "$(docker ps -aq 2>/dev/null)" ]; then docker rm $(docker ps -aq) >/dev/null 2>&1; fi
  docker container prune -f >/dev/null 2>&1
  local pids=$(ps aux | grep -i ipes | grep -v grep | awk '{print $2}')
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null
  if command -v crontab &>/dev/null && crontab -l 2>/dev/null | grep -qi ipes; then
    crontab -l 2>/dev/null | grep -vi ipes | crontab - 2>/dev/null || true
  fi
  [ -d /tmp/ipes ] && rm -rf /tmp/ipes
  find / -type d -path "*/data*/happ" 2>/dev/null | grep -E '/data[0-9]*/happ$' | while read d; do rm -rf "$d"; done
  [ -d /data/happ ] && rm -rf /data/happ
  log_info "清理完成"
}
get_data_dirs(){
  local m=$(findmnt -n -o TARGET 2>/dev/null | grep -E '^/data[0-9]*$' | sort)
  [ -z "$m" ] && m=$(ls -d /data* 2>/dev/null | grep -E '^/data[0-9]*$' | sort)
  [ -z "$m" ] && [ -d /data ] && m=/data
  echo "$m"
}
create_dirs(){
  mkdir -p /data/happ
  for ((i=0;i<NUM_DIRS;i++)); do
    mkdir -p "/data/happ/happ.$i/hdata/cache" "/data/happ/happ.$i/hdata/config"
    touch "/data/happ/happ.$i/xycould_base_info"
  done
  TOTAL_DIRS=$NUM_DIRS
  mkdir -p /opt/ipes/var/db/ipes/happ-conf
  local yml=/opt/ipes/var/db/ipes/happ-conf/custom.yml; : > "$yml"
  echo "args:" >> "$yml"
  for ((i=0;i<TOTAL_DIRS;i++)); do echo "  - /data/happ/happ.$i" >> "$yml"; done
  echo "reg_isp: $REG_ISP" >> "$yml"
  log_info "custom.yml 已生成（${TOTAL_DIRS} 路, reg_isp=$REG_ISP）: $yml"
  cat "$yml"
}
gen_docker_cmd(){
  local cmd="docker run -itd --restart=always --name=ipes --network=host"
  for ((i=0;i<NUM_DIRS;i++)); do
    cmd+=" -v /data/happ/happ.$i/hdata/cache:/data/happ/happ.$i/hdata/cache"
    cmd+=" -v /data/happ/happ.$i/hdata/config:/data/happ/happ.$i/hdata/config"
    cmd+=" -v /data/happ/happ.$i/xycould_base_info:/data/happ/happ.$i/xycould_base_info"
  done
  cmd+=" -v /opt/ipes/var/db/ipes/happ-conf/custom.yml:/app/ipes/var/db/ipes/happ-conf/custom.yml"
  cmd+=" $DOCKER_IMAGE sh -c '/app/ipes/bin/ipes start && tail -f /dev/null'"
  echo "$cmd"
}
insert_base_info(){
  for ((i=0;i<NUM_DIRS;i++)); do
    local f="/data/happ/happ.$i/xycould_base_info"
    [ -f "$f" ] && cat > "$f" <<EOF
disk_limit:300
mem_limit:300
cpu_core:0.25
EOF
  done
  log_info "xycould_base_info 注入完成（${NUM_DIRS} 路）"
}
install_health(){
  local SP=/usr/local/bin/ipes_health_check.sh; local LF=/var/log/ipes_health.log
  cat > "$SP" <<'HEALTH_EOF'
#!/usr/bin/env bash
# IPES 健康检查（融合版）：容器停则 docker start 拉起；在跑则 ./bin/ipes health 探测，
# 真正异常时才 docker restart 恢复；带 10 分钟重启冷却，避免探测抖动引发重启风暴。
LOG=/var/log/ipes_health.log
C=ipes
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
echo "[$(ts)] 检查开始" >> "$LOG"
if ! docker ps --format '{{.Names}}' | grep -qx "$C"; then
  echo "[$(ts)] 容器未运行，尝试 docker start（SN 不变）" >> "$LOG"
  docker start "$C" >> "$LOG" 2>&1 && echo "[$(ts)] 已启动" >> "$LOG" || echo "[$(ts)] 启动失败，请检查" >> "$LOG"
  exit 0
fi
OUT=$(docker exec "$C" ./bin/ipes health 2>&1); RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qiE 'OCI runtime|exec: "|No such file|command not found'; then
  echo "[$(ts)] 健康探测命令不可用，跳过重启($OUT)" >> "$LOG"
  exit 0
fi
if [ "$RC" -ne 0 ] || echo "$OUT" | grep -qiE 'connection refused|get services failed|unhealthy|not healthy|panic|refused to connect'; then
  LR=/var/lib/ipes-preheat/.last_health_restart
  now_ts=$(date +%s)
  last_ts=$(cat "$LR" 2>/dev/null || echo 0)
  if [ $((now_ts - last_ts)) -lt 600 ]; then
    echo "[$(ts)] 检测到异常但处于重启冷却期(10分钟)，本次跳过 ($OUT)" >> "$LOG"
    exit 0
  fi
  echo "$now_ts" > "$LR" 2>/dev/null || true
  echo "[$(ts)] 检测到服务异常，准备 docker restart ($OUT)" >> "$LOG"
  docker restart "$C" >> "$LOG" 2>&1 && echo "[$(ts)] 已重启恢复" >> "$LOG" || echo "[$(ts)] 重启失败，请检查" >> "$LOG"
  exit 0
fi
echo "[$(ts)] 服务正常" >> "$LOG"
HEALTH_EOF
  chmod +x "$SP"; touch "$LF"; chmod 644 "$LF"
  cat > /etc/logrotate.d/ipes <<'LR_EOF'
/var/log/ipes_health.log
/var/log/batch_preheat_*.log {
    missingok
    notifempty
    size 5M
    rotate 3
    compress
    delaycompress
    copytruncate
}
LR_EOF
  rpm -q cronie >/dev/null 2>&1 || timeout 120 yum -y -q install cronie >/dev/null 2>&1 || true
  local cur=$(crontab -l 2>/dev/null || true)
  cur=$(echo "$cur" | grep -v "$SP")
  cur=$(printf "%s\n* * * * * %s > /dev/null 2>&1\n" "$cur" "$SP" | sed '/^$/d')
  echo "$cur" | crontab -
  timeout 20 systemctl enable --now crond >/dev/null 2>&1 || timeout 20 systemctl enable --now cronie >/dev/null 2>&1 || true
  log_info "保活(健康检查)已安装: $SP（每分钟，含重启冷却）"
  "$SP" >/dev/null 2>&1 && log_info "保活自测通过"
}

# ============================ C) 对齐阶段（调仓库里的 ipes_onekey.sh） ============================
ALIGN_URL_1="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_onekey.sh"
ALIGN_URL_2="https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_onekey.sh"
run_align(){
  log_info "========== 对齐阶段：预热调优 + 全锥/NAT/tc/cache/happ对齐 =========="
  local pf=/tmp/ipes_onekey_$$.sh ok=0
  for u in "$ALIGN_URL_1" "$ALIGN_URL_2"; do
    if curl -fsSL --connect-timeout 15 --max-time 120 "$u" -o "$pf" 2>/dev/null && [ -s "$pf" ] && head -1 "$pf" | grep -q '^#!/bin/bash' && bash -n "$pf" 2>/dev/null; then
      log_info "已取得对齐脚本: $u"
      export TARGET_HAPP="$NUM_DIRS"; export TARGET_TAG="1.3.0"
      if bash "$pf"; then ok=1; log_info "对齐阶段执行完成"; break
      else log_warn "对齐脚本返回非0（个别内核键不支持可忽略），继续"; ok=1; break; fi
    else log_warn "拉取失败，换源: $u"; fi
  done
  [ "$ok" -eq 1 ] || log_error "对齐阶段未能执行（节点可能无外网）；基础部署已就绪，可稍后手动跑 ipes_onekey.sh"
}

# ============================ D) 写 device_code 供精确匹配 ============================
write_device_code(){
  local CID=$(cat /data*/happ/happ.*/hdata/config/infos.json 2>/dev/null \
              | grep -oE '"client_id":"[0-9a-f]{32}"' | head -1 | grep -oE '[0-9a-f]{32}')
  mkdir -p /usr/local/edge_zycloud
  if [ -n "$CID" ]; then
    echo "$CID" > /usr/local/edge_zycloud/device_code
    log_info "device_code 已写入（精确匹配用）: $CID"
  else
    log_warn "未读到 client_id，绑定阶段将走公网 IP 兜底匹配"
  fi
}

# ============================ E) 绑定 + 流转服务中 ============================
run_binding(){
  log_info "========== 绑定 + 流转服务中（JWT 鉴权，X-Token） =========="
  export NODE_ACTIVATE_TOKEN="$JWT" ADMIN_API_HOST BUSINESS_ID ISP PROVINCE CITY \
         NODE_NAT_TYPE NODE_RESOURCE_TYPE NODE_DIAL_TYPE NODE_SINGLE_IP_RADIO \
         NODE_USBW="$USBW" NODE_BW_NUM="$BW_NUM"
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
    for f in ["/usr/local/edge_zycloud/device_code", "/usr/local/edge/device_code", "/etc/edge/device_code"]:
        try:
            v = open(f).read().strip()
            if re.fullmatch(r'[0-9a-f]{32}', v): return v
        except Exception: pass
    return None

def get_real_sn():
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
    cands = [it for it in nodes if it.get('publicIP') == pubip and it.get('status') != 'offline']
    if not cands: return None
    stage_rank = {'inService': 3, 'configured': 2, 'waitAudit': 1}
    cands.sort(key=lambda x: (stage_rank.get(x.get('stage'), 0), x.get('nodeUpdateTime') or x.get('UpdatedAt') or ''), reverse=True)
    return cands[0]

def is_bound(ni):
    if not ni: return False
    if ni.get('stage') != 'inService': return False
    info = ni.get('nodeInfo') or {}
    return info.get('vendorSuggestCustomers') == BUSINESS_ID and info.get('usbw') == NODE_USBW

def tag_ok(ni, sn):
    tags = ni.get('business_tags') or []
    return bool(tags) and any(t.get('hostName') == sn for t in tags)

def do_bind(node_id, sn):
    log(f"为本机节点 {node_id} 补绑业务 {BUSINESS_ID}")
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
    code, txt = admin_call("/api/edgeNode/stateflow", {"nodes": [node_id], "stage": "inService", "hostname": sn or ""}, "POST")
    log(f"  -> inService: HTTP {code} {txt[:120]}")

def main():
    pubip = get_public_ip()
    if not pubip: log("[ERROR] 无法获取公网 IP"); sys.exit(1)
    log(f"本机公网 IP: {pubip}")
    local_nid = get_local_node_id()
    log(f"本机 device_code(nodeID): {local_nid or '未读到，走IP兜底'}")
    sn = None; ni = None
    for i in range(48):
        if not sn:
            sn = get_real_sn()
            if sn: log(f"本机 76hex 业务SN: {sn[:20]}...{sn[-12:]}")
        ni = pick_node(pubip, local_nid)
        if ni and sn: break
        log(f"等待节点注册/SN就绪... ({i+1}/48)"); time.sleep(10)
    if not ni: log("[ERROR] 8 分钟未找到节点，放弃"); sys.exit(1)
    info = ni.get('nodeInfo') or {}
    log(f"节点: {ni.get('nodeID')} stage={ni.get('stage')} status={ni.get('status')} nodeInfo.vendor={info.get('vendorSuggestCustomers')} usbw={info.get('usbw')}")
    if is_bound(ni) and (not sn or tag_ok(ni, sn)):
        log("[OK] 已绑定且业务标签正确，无需修复"); sys.exit(0)
    do_bind(ni.get('nodeID'), sn or "")
    time.sleep(3)
    ni = pick_node(pubip, local_nid)
    if is_bound(ni) and (not sn or tag_ok(ni, sn)):
        log("[OK] 修复成功，已流转服务中"); sys.exit(0)
    else: log("[ERROR] 修复后仍未达标"); sys.exit(1)

if __name__ == '__main__':
    main()
PY
  if python3 /root/ipes_repair_binding.py; then
    log_info "绑定 + 流转服务中 完成"
  else
    log_error "绑定/流转未达标，查看 /var/log/ipes_repair.log 或重跑: bash <本脚本> --bind-only --jwt <jwt>"
  fi
}

# ============================ 主流程 ============================
SN_WAIT=90
log_info "========== 0/5 系统调优 =========="
sys_tune

if [ "$BIND_ONLY" -ne 1 ]; then
  log_info "========== 1/5 确保 Docker =========="
  ensure_docker
  log_info "========== 2/5 清理旧节点 =========="
  cleanup_old
  log_info "========== 3/5 建目录 + custom.yml（${NUM_DIRS}路） =========="
  create_dirs
  log_info "========== 4/5 拉起容器（镜像 $DOCKER_IMAGE, reg_isp=$REG_ISP） =========="
  DOCKER_CMD=$(gen_docker_cmd)
  log_info "执行: $DOCKER_CMD"
  eval "$DOCKER_CMD" || { log_error "容器启动失败"; exit 1; }
  echo "$DOCKER_CMD" > /opt/ipes/docker_run; chmod +x /opt/ipes/docker_run
  log_info "docker_run 已保存: /opt/ipes/docker_run"
  insert_base_info
  log_info "========== 5/5 安装保活(健康检查) =========="
  install_health
  if [ "$NO_ALIGN" -eq 0 ]; then run_align; else log_info "跳过对齐阶段（--no-align）"; fi
  log_info "等待容器注册生成 SN（${SN_WAIT}s）..."
  sleep "$SN_WAIT"
  if docker ps | grep -q ipes; then
    SN=$(docker exec ipes cat bin/ipes_sn 2>/dev/null)
    [ -n "$SN" ] && { log_info "设备SN: $SN"; echo "IQIYI_ECACHE_DEVICE_ID:$SN"; } || log_warn "未读取到 SN，稍后: docker exec ipes cat bin/ipes_sn"
    CID=$(cat /data*/happ/happ.*/hdata/config/infos.json 2>/dev/null | grep client_id | awk -F'"' '{print $4}' | sort -u | head -1)
    [ -n "$CID" ] && { log_info "clientid: $CID"; echo "IQIYI_ECACHE_CLIENT_ID:$CID"; }
  else
    log_error "ipes 容器未运行，请排查"
  fi
  write_device_code
fi

run_binding

log_info "========== 全部完成 =========="
log_info "镜像: $DOCKER_IMAGE | reg_isp=$REG_ISP | happ路数=$NUM_DIRS | 业务=$BUSINESS_ID | 绑定+服务中已执行"
log_info "查看绑定日志: tail -f /var/log/ipes_repair.log"

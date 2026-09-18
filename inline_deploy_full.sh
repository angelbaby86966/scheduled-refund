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
#   --bind-first    先绑定(注册+提交41+流转服务中)，再慢慢部署业务【默认开启】
#   --no-bind-first 关闭先绑定，退回"先部署后绑定"旧顺序
#   镜像锁定 :1.3.0
#
# 【r20-fix17 默认流程】容器拉起→节点自注册→立即绑定(提交41+服务中,SN未就绪则空hostname)
#   → 对齐/预热等慢步骤 → 末尾用真实 76hex SN 覆盖 business_tags.hostName。
#   目的：让节点尽早被平台接纳(避免慢部署阶段节点"丢失")，与"完整模式"设计一致。
# =============================================================================
trap '' HUP   # 终端断开(SIGHUP)不杀进程；Ctrl-C(INT)仍可中断

# ----------------------------- 参数解析 -----------------------------
AK=""; SK=""; JWT=""; ISP=""; PROVINCE=""; CITY=""
NUM_DIRS=12; USBW=200; BW_NUM=1; IMG_CHOICE=2
BUSINESS_ID=41; ADMIN_API_HOST="https://admin.zhouyi.top"
NO_ALIGN=0; BIND_ONLY=0; BIND_FIRST=1
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
    --bind-first) BIND_FIRST=1; shift;;
    --no-bind-first) BIND_FIRST=0; shift;;
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
  cat > /etc/sysctl.d/99-ipes.conf <<'EOF'
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
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_ecn = 0
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
vm.swappiness = 0
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.overcommit_memory = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_available_congestion_control = bbr cubic reno
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.core.netdev_budget = 600
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
  fi
  # 【r20-fix6】不再使用 iptables raw NOTRACK：会让回包脱离 conntrack，与 firewalld 共存时
  # 导致已建立连接回包被 INPUT 丢弃 → SSH/云助手断连（即此前“一跑脚本就断网”根因）。
  log_info "系统调优完成"
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
  # 一次性缓存元数据，后续安装走缓存；去掉冲突-prone 的 yum-utils/dm/lvm2（docker-ce-stable 自带依赖）
  yum makecache fast >/dev/null 2>&1 || true
  yum install -y -q --setopt=timeout=30 --setopt=retries=2 docker-ce docker-ce-cli containerd.io
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
# IPES 健康检查（融合版 + r20-fix11 硬自愈）：容器级 docker start 兜底 + 应用层 ./bin/ipes health 探测，
# 真正异常时才 docker restart 恢复；非交互、并对「探测命令不存在」做了跳过处理避免每分钟重启抖动。
# 容器 docker start 失败时，先执行 fix11_heal（xycould_base_info 目录/缺失 → 43B 文件）再重试启动。
LOG=/var/log/ipes_health.log
C=ipes
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
# 日志瘦身：超过 2MB 只留尾部 500 行（每分钟一条，约 60KB/天）
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
fi
echo "[$(ts)] 检查开始" >> "$LOG"

# ---------------------------------------------------------------------------
# 【r20-fix11 硬自愈】保证每个 /data/happ/happ.N/xycould_base_info 是 43B 文件而非目录。
#   根因：ecache/docker 会把缺失的挂载源自动补成【空目录】；docker-ce 对挂载类型校验严格，
#         目录会让容器 OCI create failed: not a directory → Exited(127)，此后 docker start
#         永远失败 → 节点"缓存还在但完全没有上下行"（2026-09-18 66d9ff7c 实测即此）。
#   修复：以 happ.0 的同名 43B 文件为模板，去掉坏目录后 cp 回来（幂等、不动缓存、不动 SN）。
#   内容只是每个 worker 的资源配额（disk_limit/mem_limit/cpu_core），各 happ 完全一致。
# ---------------------------------------------------------------------------
fix11_heal(){
  local ref=/data/happ/happ.0/xycould_base_info d p fixed=0
  [ -s "$ref" ] || return 1
  for d in /data/happ/happ.*; do
    [ -d "$d" ] || continue
    p="$d/xycould_base_info"
    if [ -d "$p" ]; then
      # 坏目录：为空则 rmdir；非空兜底 rm -rf（该路径是挂载源，正常必为 43B 文件，绝不会是数据目录）
      rmdir "$p" 2>/dev/null || rm -rf "$p" 2>/dev/null
    fi
    if [ ! -e "$p" ]; then
      # 缺失 / 刚删掉 → 用 happ.0 模板补回 43B 文件
      cp -f "$ref" "$p" 2>/dev/null && fixed=$((fixed+1))
    fi
  done
  if [ "$fixed" -gt 0 ]; then
    echo "[$(ts)] [fix11] 已修复 $fixed 个 xycould_base_info（目录/缺失 → 文件），准备重试启动" >> "$LOG"
    return 0
  fi
  return 1
}

if ! docker ps --format '{{.Names}}' | grep -qx "$C"; then
  echo "[$(ts)] 容器未运行，尝试 docker start（SN 不变）" >> "$LOG"
  if docker start "$C" >> "$LOG" 2>&1; then
    echo "[$(ts)] 已启动" >> "$LOG"
  else
    # docker start 失败 → 先查 fix11 挂载类型异常；修好再重试一次
    if fix11_heal; then
      if docker start "$C" >> "$LOG" 2>&1; then
        echo "[$(ts)] [fix11] 修复挂载后已启动" >> "$LOG"
      else
        echo "[$(ts)] [fix11] 修复后仍启动失败：$(docker inspect -f '{{.State.Error}}' "$C" 2>/dev/null | head -c 200)" >> "$LOG"
      fi
    else
      echo "[$(ts)] 启动失败且未发现 fix11 挂载异常，请检查" >> "$LOG"
    fi
  fi
  exit 0
fi
# 容器在跑，做应用层健康探测（./bin/ipes health 为 IPES 内部命令）
OUT=$(docker exec "$C" ./bin/ipes health 2>&1); RC=$?
# 探测命令本身不可用（容器内缺该命令 / exec 失败）-> 不重启，避免每分钟抖动
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qiE 'OCI runtime|exec: "|No such file|command not found'; then
  echo "[$(ts)] 健康探测命令不可用，跳过重启($OUT)" >> "$LOG"
  exit 0
fi
# 真正的服务异常 -> 重启容器恢复（同时恢复进程与容器内服务）
# 注意：正则只用【明确的失败特征】，绝不用裸 'error'（健康 JSON 常含 "errors":[] 会被误判，导致每分钟重启风暴）
if [ "$RC" -ne 0 ] || echo "$OUT" | grep -qiE 'connection refused|get services failed|unhealthy|not healthy|panic|refused to connect'; then
  # 重启冷却：10 分钟内只重启一次，避免健康探测偶发抖动引发每分钟重启、打断缓存写入
  LR=/var/lib/ipes-preheat/.last_health_restart
  now_ts=$(date +%s)
  last_ts=$(cat "$LR" 2>/dev/null || echo 0)
  if [ $((now_ts - last_ts)) -lt 600 ]; then
    echo "[$(ts)] 检测到异常但处于重启冷却期(10分钟)，本次跳过 ($OUT)" >> "$LOG"
    exit 0
  fi
  mkdir -p /var/lib/ipes-preheat 2>/dev/null
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
  local t1=/tmp/ipes_ok1_$$.sh t2=/tmp/ipes_ok2_$$.sh
  # 【r20-fix16】双源并发竞速：谁先下载并通过校验就用谁，
  # 避免串行各等 120s（最坏 240s≈4 分钟）的长停顿。
  ( curl -fsSL --connect-timeout 10 --max-time 60 "${ALIGN_URL_1}" -o "$t1" >/dev/null 2>&1 ) &
  local p1=$!
  ( curl -fsSL --connect-timeout 10 --max-time 60 "${ALIGN_URL_2}" -o "$t2" >/dev/null 2>&1 ) &
  local p2=$!
  local winner="" probe
  for probe in $(seq 1 30); do   # 最多 60s（30×2s）
    if [ -z "$winner" ] && [ -s "$t1" ] && head -1 "$t1" | grep -q '^#!/bin/bash' && bash -n "$t1" 2>/dev/null; then winner="$t1"; fi
    if [ -z "$winner" ] && [ -s "$t2" ] && head -1 "$t2" | grep -q '^#!/bin/bash' && bash -n "$t2" 2>/dev/null; then winner="$t2"; fi
    [ -n "$winner" ] && break
    sleep 2
  done
  kill $p1 $p2 2>/dev/null; wait 2>/dev/null
  if [ -n "$winner" ]; then
    cp "$winner" "$pf"
    log_info "已取得对齐脚本（竞速命中: $([ "$winner" = "$t1" ] && echo ghproxy || echo raw)）"
    export TARGET_HAPP="$NUM_DIRS"; export TARGET_TAG="1.3.0"
    if bash "$pf"; then ok=1; log_info "对齐阶段执行完成"
    else log_warn "对齐脚本返回非0（个别内核键不支持可忽略），继续"; ok=1; fi
  else
    log_error "对齐阶段两源均未能拉取（节点可能无外网）；基础部署已就绪，可稍后手动跑 ipes_onekey.sh"
  fi
  rm -f "$t1" "$t2"
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
    # 【r20-fix17】仅当拿到真实 76hex SN 才带 hostname；容器未起/未就绪时省略 hostname，
    # 让平台按"容器未起不带 hostname"的设计接纳节点（稍后由后置绑定用真 SN 覆盖 business_tags.hostName）。
    sf_body = {"nodes": [node_id], "stage": "inService"}
    if sn:
        sf_body["hostname"] = sn
    code, txt = admin_call("/api/edgeNode/stateflow", sf_body, "POST")
    log(f"  -> inService: HTTP {code} {txt[:120]}")

def main():
    # 【r20-fix17】BIND_REQUIRE_SN=0 时（先绑定模式）：节点自注册即绑定，SN 未就绪也继续（空 hostname 流转），
    # 由末尾后置绑定用真实 SN 覆盖；默认=1（仅绑定/后置绑定）要求 SN 就绪。
    REQUIRE_SN = os.environ.get('BIND_REQUIRE_SN', '1') != '0'
    pubip = get_public_ip()
    if not pubip: log("[ERROR] 无法获取公网 IP"); sys.exit(1)
    log(f"本机公网 IP: {pubip}  | 绑定模式: {'要求SN就绪' if REQUIRE_SN else '节点注册即绑(可空SN)'}")
    local_nid = get_local_node_id()
    log(f"本机 device_code(nodeID): {local_nid or '未读到，走IP兜底'}")
    sn = None; ni = None
    for i in range(48):
        if not sn:
            sn = get_real_sn()
            if sn: log(f"本机 76hex 业务SN: {sn[:20]}...{sn[-12:]}")
        ni = pick_node(pubip, local_nid)
        if ni and (sn or not REQUIRE_SN): break
        log(f"等待节点注册/SN就绪... ({i+1}/48)"); time.sleep(5)
    if not ni: log("[ERROR] 4 分钟未找到节点，放弃"); sys.exit(1)
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

# 【r20-fix17】--bind-only：跳过全部部署，仅做绑定+流转服务中（要求 SN 就绪）
if [ "$BIND_ONLY" -eq 1 ]; then
  log_info ">>> [仅绑定] 跳过部署，直接绑定+流转服务中"
  run_binding
  log_info "========== 全部完成（仅绑定）=========="
  log_info "查看绑定日志: tail -f /var/log/ipes_repair.log"
  exit 0
fi

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

# 【r20-fix17】先绑定：节点自注册后立即提交业务41+流转服务中（SN 未就绪则空 hostname），
# 让平台尽早接纳节点；慢速的对齐/预热在之后跑，最后用真 SN 覆盖。
if [ "$BIND_FIRST" -eq 1 ]; then
  log_info ">>> [先绑定] 节点自注册后立即绑定（SN 未就绪可空 hostname 流转服务中）"
  BIND_REQUIRE_SN=0 run_binding
fi

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

# 【r20-fix17】后置绑定：用真实 76hex SN 覆盖 business_tags.hostName（先绑定时若 SN 未就绪，此处补齐）
if [ "$BIND_FIRST" -eq 1 ]; then
  log_info ">>> [绑定后置] 用真实 76hex SN 覆盖业务标签(hostName)"
  BIND_REQUIRE_SN=1 run_binding
fi

log_info "========== 全部完成 =========="
log_info "镜像: $DOCKER_IMAGE | reg_isp=$REG_ISP | happ路数=$NUM_DIRS | 业务=$BUSINESS_ID | 绑定+服务中已执行"
log_info "查看绑定日志: tail -f /var/log/ipes_repair.log"

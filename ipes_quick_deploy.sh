#!/bin/bash
# =============================================================================
# ipes_quick_deploy.sh —— 轻量 IPES 边缘节点部署（Q2_test 优化版 + 性能/健康调优）
# -----------------------------------------------------------------------------
# 优化点（相对原始 Q2_test 三段 curl|bash）:
#   1) 单文件一键；happ 目录数/运营商/镜像均可参数化（默认 9 目录）
#   2) 镜像固定版本号（勿用 :latest，可复现）
#   3) 安全护栏: 检测到已有 ipes 容器默认拒绝重跑（避免清缓存/换 SN）
#   4) 系统调优 tune_system():
#        - sysctl: 连接跟踪表/端口范围/socket 缓冲/队列/文件句柄/内存（消掉丢包与 fd 耗尽）
#        - 200M 上行专属: TCP BBR 拥塞控制 / cwnd 保活 / TFO 快开 / netdev 预算 / RPS 多核分发
#          （把 200M 物理上行用满，让 iQiyi 实测看到"真健康"）
#        - /data 挂载 noatime + I/O 调度器 mq-deadline（磁盘吞吐更猛、缓存写入更快）
#        - 可挂独立数据盘(--data-disk)专用缓存，盘大自然能容更多缓存
#   5) 容器层: --ulimit nofile（海量连接）、--blkio-weight/--cpu-shares（I/O 与 CPU 优先）、--restart=always
#   6) 可选自动绑定: 设了 NODE_ACTIVATE_TOKEN 则部署后自动"提交业务41+流转服务中"
#   7) 部署后自检: /data 余量<15% 告警（避免 94% 满导致 iQiyi 不再派量）
#
# 用法:
#   NODE_ACTIVATE_TOKEN="<JWT>" bash ipes_quick_deploy.sh                # 9目录+电信+自动绑
#   bash ipes_quick_deploy.sh --dirs 9 --isp 1 --data-disk /dev/vdb      # 挂新数据盘做缓存
#   bash ipes_quick_deploy.sh --force      # 重跑清旧容器（丢缓存，谨慎）
#   bash ipes_quick_deploy.sh --notrack    # 纯 PCDN 节点: 关 conntrack 跟踪(IPES 高 PPS 不再被表满限流)
#   bash ipes_quick_deploy.sh --tune-only  # 仅应用 OS 调优(sysctl/BBR/RPS/NOTRACK)，不动容器/磁盘/绑定
# =============================================================================
set -uo pipefail

# ---------- 可配置参数 ----------
DIRS="${DIRS:-9}"                 # happ 缓存分片数（默认 9；磁盘够大可 9~12）
REG_ISP="${REG_ISP:-1}"           # 1=电信 2=联通 3=移动
IMAGE="${IMAGE:-ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:1.3.0}"
HEALTH_CHECK_URL="${HEALTH_CHECK_URL:-https://zyy-go.oss-cn-beijing.aliyuncs.com/script/Q2_test/install_health_check.sh}"
DATA_DISK="${DATA_DISK:-}"        # 例如 /dev/vdb：全新空数据盘，格式化 XFS 挂 /data 专做缓存
FORCE=0
NOTRACK=0
TUNE_ONLY=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --dirs)  DIRS="$2"; shift 2 ;;
    --isp)   REG_ISP="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --data-disk) DATA_DISK="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --notrack) NOTRACK=1; shift ;;
    --tune-only) TUNE_ONLY=1; shift ;;
    --skip-health) HEALTH_CHECK_URL=""; shift ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 0) 安全护栏 ----------
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx ipes; then
  if [ "$FORCE" -ne 1 ]; then
    echo -e "\033[0;31m[阻止]\033[0m 已有 ipes 容器，重跑会清缓存/换 SN。确认覆盖请加 --force"
    exit 1
  fi
  echo -e "\033[1;33m[警告]\033[0m --force: 停止并删除现有 ipes 容器（缓存会丢）"
  docker rm -f ipes >/dev/null 2>&1 || true
fi

# ---------- 系统调优 ----------
tune_system() {
  echo "[调优] 写入 /etc/sysctl.d/99-ipes.conf 并生效（网络/连接跟踪/文件句柄/内存）"
  cat > /etc/sysctl.d/99-ipes.conf <<'EOF'
# ===== PCDN / IPES 性能与健康调优 =====
# 1) 连接跟踪表（海量短连接，表满即丢包→iQiyi 探测失败→降权）
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
# 2) 本地端口范围（避免 outbound 端口耗尽）
net.ipv4.ip_local_port_range = 1024 65535
# 3) socket 缓冲（上行吞吐）
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
# 4) 队列与 TIME_WAIT 复用
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_ecn = 0
# 5) 文件句柄（海量小文件缓存）
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
# 6) 内存（缓存服务：少 swap、写缓冲更激进）
vm.swappiness = 0
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.overcommit_memory = 1
# 7) 200M 上行专属（把物理上行用满，iQiyi 实测高吞吐=健康）
#    (注: tcp_congestion_control 不写进本文件——CentOS7/3.10 内核无 BBR 模块，
#     写进持久文件会致重启报红；改由下方 7a 运行时探测，支持才启用并单独持久化)
#    空闲后不清空 cwnd: PCDN 突发短连接保持热拥塞窗口，避免每次慢启动掉速
net.ipv4.tcp_slow_start_after_idle = 0
#    TCP Fast Open: 短连接省一次 RTT（PCDN 海量短连接收益明显）
net.ipv4.tcp_fastopen = 3
#    SYN 队列 + FIN 回收: 高并发连接不排队丢
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
#    每轮 NAPI 多收包 + 延长预算: 提升 PPS 上限，200M 上行不卡软中断
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000
#    RFS 流表: 配合下方 RPS 把同一条流固定到同核，降低 cache 抖动
net.core.rps_sock_flow_entries = 32768
#    MTU 黑洞探测: 个别运营商路径 PMTU 异常时自动降探测，避免大包卡死
net.ipv4.tcp_mtu_probing = 1
#    窗口缩放必须开（200M×RTT 的 BDP 远超 64KB 默认窗口）
net.ipv4.tcp_window_scaling = 1
EOF
  # -e: 忽略本机未加载模块的项；先尝试加载 conntrack 再应用
  sysctl -e -p /etc/sysctl.d/99-ipes.conf >/dev/null 2>&1 || true
  modprobe nf_conntrack 2>/dev/null || true
  sysctl -e -p /etc/sysctl.d/99-ipes.conf >/dev/null 2>&1 || true

  # 7a) BBR 拥塞控制（模块可能未编入内核，需 modprobe；失败则回退 cubic）
  #     - CentOS7 默认 3.10 内核无 BBR，会回退 cubic（仍可用，吞吐略低）
  #     - 内核>=4.9 才支持；支持时立即启用，并单独持久化(modprobe.d+sysctl.d)以便重启保持
  modprobe tcp_bbr 2>/dev/null || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
     && sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    echo "[调优] TCP 拥塞控制=bbr (已启用)"
    # 持久化：开机自动加载模块 + 设 bbr（仅本机确实支持时才写，避免不支持的内核重启报红）
    echo "tcp_bbr" > /etc/modprobe.d/tcp_bbr.conf 2>/dev/null || true
    echo "net.ipv4.tcp_congestion_control = bbr" > /etc/sysctl.d/99-ipes-bbr.conf 2>/dev/null || true
  else
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    echo -e "\033[1;33m[提示]\033[0m 内核不支持 BBR(需>=4.9)，已用 cubic（200M 干净链路仍可跑满）"
  fi

  # 7b) RPS: 把网卡收包软中断摊到所有 CPU（云主机多为单队列 virtio 网卡，
  #      不摊核则单核软中断打满→吞吐上不去。CPU 掩码按核数生成）
  nic=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -n "$nic" ] && [ -d "/sys/class/net/$nic/queues" ]; then
    ncpu=$(nproc)
    # 生成全 1 掩码（ncpu<=32 为单 word，足够覆盖常见 2~8 核 VM）
    mask=$(printf '%x' $(( (1 << ncpu) - 1 )) )
    for q in /sys/class/net/$nic/queues/rx-*; do
      echo "$mask" > "$q/rps_cpus" 2>/dev/null || true
      echo 4096 > "$q/rps_flow_cnt" 2>/dev/null || true
    done
    echo "[调优] RPS 已开启 ($nic, $ncpu 核分摊收包)"
  fi

  # /data 是独立挂载才 remount noatime（减少元数据写，缓存写入更快）
  if mountpoint -q /data 2>/dev/null; then
    mount -o remount,noatime,nodiratime /data 2>/dev/null && echo "[调优] /data 已 remount noatime" || true
  fi

  # I/O 调度器：非 NVMe 设 mq-deadline（更稳吞吐），NVMe 设 none
  dev=$(df --output=source /data 2>/dev/null | tail -1 | sed 's/[0-9]*$//')
  if [ -n "$dev" ] && [ -b "$dev" ]; then
    sched=$(cat /sys/block/${dev##*/}/queue/scheduler 2>/dev/null)
    if echo "$sched" | grep -q mq-deadline; then
      echo mq-deadline > /sys/block/${dev##*/}/queue/scheduler 2>/dev/null && echo "[调优] $dev 调度器=mq-deadline" || true
    elif echo "$sched" | grep -q none; then
      echo none > /sys/block/${dev##*/}/queue/scheduler 2>/dev/null && echo "[调优] $dev 调度器=none(NVMe)" || true
    fi
  fi
}

# ---------- 可选: 纯 PCDN 节点关 conntrack（高 PPS 不再被连接跟踪表限流） ----------
bypass_conntrack() {
  [ "$NOTRACK" -ne 1 ] && return 0
  if ! command -v iptables >/dev/null 2>&1; then
    echo -e "\033[1;33m[notrack]\033[0m 无 iptables，跳过"; return 0
  fi
  # 安全自检: 若 filter 表存在依赖 conntrack 的 DROP/REJECT 规则，跳过以免断网（误伤）
  if iptables -S 2>/dev/null | grep -E '(-m state|-m conntrack)' | grep -E 'DROP|REJECT' >/dev/null; then
    echo -e "\033[1;33m[notrack]\033[0m 检测到依赖 conntrack 的 DROP/REJECT 规则，跳过以免断网"
    return 0
  fi
  # raw 表: 进出流量都不做连接跟踪。纯 PCDN 节点无 NAT、无本机状态防火墙(安全组在平台侧)，
  # 关掉后 conntrack 表永不再满 → 高 PPS 下不再丢包 → iQiyi 探测稳定=健康
  iptables -t raw -A PREROUTING -j NOTRACK 2>/dev/null || true
  iptables -t raw -A OUTPUT -j NOTRACK 2>/dev/null || true
  echo "[调优] NOTRACK 已启用（raw 表 PREROUTING/OUTPUT 全放过，conntrack 不再跟踪）"
  # 持久化: 若装了 iptables-save 服务则存一份（重启后 raw 规则需重设，否则开机失效）
  if command -v iptables-save >/dev/null 2>&1; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
}

# ---------- 可选: 全新数据盘挂 /data 专做缓存 ----------
setup_data_disk() {
  [ -z "$DATA_DISK" ] && return 0
  if mountpoint -q /data 2>/dev/null; then
    echo "[数据盘] /data 已是挂载点，跳过格式化（不破坏现有数据）"; return 0
  fi
  if ! [ -b "$DATA_DISK" ]; then echo "[错误] 数据盘 $DATA_DISK 不存在"; exit 1; fi
  echo "[数据盘] 格式化 $DATA_DISK 为 XFS 并挂 /data（仅全新空盘！）"
  mkfs.xfs -f "$DATA_DISK"
  mkdir -p /data
  echo "$DATA_DISK /data xfs noatime,nodiratime 0 0" >> /etc/fstab
  mount -o noatime,nodiratime "$DATA_DISK" /data
}

# 【r20-fix18】docker 安装根治：避免 aliyun 镜像 CLOSE-WAIT 挂死永久卡住（张瑞瑶32 事故）
harden_yum_conf() {
    local f=/etc/yum.conf
    [ -f "$f" ] || return 0
    grep -qE '^timeout=' "$f" || echo 'timeout=30' >> "$f"
    grep -qE '^retries=' "$f" || echo 'retries=3' >> "$f"
    grep -qE '^metadata_expire=' "$f" || echo 'metadata_expire=300' >> "$f"
}
install_docker_hardened() {
    harden_yum_conf
    cat > /etc/yum.repos.d/docker-ce.repo <<EOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/docker-ce/linux/centos/gpg
EOF
    local try rc
    for try in 1 2 3; do
        echo "[1/5] docker-ce 在线安装 第 ${try}/3 次 (timeout 600) ..."
        timeout 600 yum install -y --setopt=timeout=30 --setopt=retries=3 \
            docker-ce docker-ce-cli containerd.io docker-compose-plugin > /tmp/docker_install.log 2>&1
        rc=$?
        tail -n 20 /tmp/docker_install.log
        [ "$rc" -eq 0 ] && return 0
        echo "[1/5] 第 ${try}/3 次失败(rc=$rc)，10s 后重试"
        sleep 10
    done
    echo "[错误] docker-ce 安装失败（已重试 3 次）"
    return 1
}

# ---------- 1) Docker ----------
if ! command -v docker >/dev/null 2>&1; then
  echo "[1/5] 安装 Docker ..."
  install_docker_hardened
fi
systemctl enable --now docker 2>/dev/null || true
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || { echo "[错误] Docker 未就绪"; exit 1; }

# ---------- tune-only: 仅应用 OS 调优，不动数据盘/容器/绑定 ----------
if [ "$TUNE_ONLY" -eq 1 ]; then
  echo "[tune-only] 仅应用 OS 调优（sysctl/BBR/RPS/NOTRACK），跳过部署"
  tune_system
  bypass_conntrack
  echo "[tune-only] 完成。验证: sysctl net.ipv4.tcp_congestion_control ; iptables -t raw -L -n"
  exit 0
fi

setup_data_disk
tune_system
bypass_conntrack

# ---------- 2) 拉镜像 ----------
echo "[2/5] 拉取 IPES 镜像: $IMAGE"
docker pull "$IMAGE"

# ---------- 3) happ 目录 + custom.yml ----------
echo "[3/5] 创建 $DIRS 个 happ 缓存分片 (reg_isp=$REG_ISP)"
rm -rf /data/happ
mkdir -p /data/happ
ARGS=()
for i in $(seq 0 $((DIRS-1))); do
  mkdir -p /data/happ/happ.$i/hdata/cache /data/happ/happ.$i/hdata/config /data/happ/happ.$i/xycould_base_info
  ARGS+=("/data/happ/happ.$i")
done
mkdir -p /opt/ipes/var/db/ipes/happ-conf
{
  echo "args:"
  for d in "${ARGS[@]}"; do echo "  - $d"; done
  echo "reg_isp: $REG_ISP"
} > /opt/ipes/var/db/ipes/happ-conf/custom.yml
echo "  custom.yml:"; sed 's/^/    /' /opt/ipes/var/db/ipes/happ-conf/custom.yml

# ---------- 4) 启动容器（I/O/CPU 优先 + 海量 fd） ----------
echo "[4/5] 启动 IPES 容器 ..."
MOUNTS=""
for i in $(seq 0 $((DIRS-1))); do
  MOUNTS+=" -v /data/happ/happ.$i/hdata/cache:/data/happ/happ.$i/hdata/cache"
  MOUNTS+=" -v /data/happ/happ.$i/hdata/config:/data/happ/happ.$i/hdata/config"
  MOUNTS+=" -v /data/happ/happ.$i/xycould_base_info:/data/happ/happ.$i/xycould_base_info"
done
docker rm -f ipes >/dev/null 2>&1 || true
# shellcheck disable=SC2086
docker run -itd --restart=always --name=ipes --network=host \
  --ulimit nofile=1048576:1048576 \
  --ulimit nproc=65535:65535 \
  --blkio-weight 1000 \
  --cpu-shares 1024 \
  -v /opt/ipes/var/db/ipes/happ-conf/custom.yml:/app/ipes/var/db/ipes/happ-conf/custom.yml \
  $MOUNTS "$IMAGE" sh -c '/app/ipes/bin/ipes start && tail -f /dev/null'
echo "  容器 ID: $(docker ps -q -f name=ipes)"

sleep 5
echo "  ---- 设备身份 ----"
docker exec ipes cat /bin/ipses_sn 2>/dev/null | sed 's/^/  SN: /' || \
  docker logs --tail 20 ipes 2>/dev/null | grep -iE 'SN|clientid' | sed 's/^/  /'

# 缓存余量自检（iQiyi 不因盘满停派量）
used_pct=$(df -P /data | awk 'NR==2{print $5}' | tr -d '%')
if [ "${used_pct:-0}" -gt 85 ]; then
  echo -e "\033[1;33m[告警]\033[0m /data 已用 ${used_pct}%，缓存将很快写满→iQiyi 停止派量。建议扩盘或减 --dirs。"
fi

# ---------- 5) 健康检查 ----------
if [ -n "$HEALTH_CHECK_URL" ]; then
  echo "[5/5] 安装 IPES 健康检查 cron ..."
  curl -fsSL -m 60 "$HEALTH_CHECK_URL" | bash || echo "[警告] 健康检查安装失败，可手动补"
else
  echo "[5/5] 跳过健康检查安装"
fi

# ---------- 6) 可选自动绑定 ----------
if [ -n "${NODE_ACTIVATE_TOKEN:-}" ]; then
  echo "== 自动补完: 提交业务41 + 流转服务中 =="
  sleep 20
  curl -fsSL -m 60 "https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/complete_node.sh" -o /tmp/complete_node.sh \
    && bash /tmp/complete_node.sh
else
  echo "== 未设 NODE_ACTIVATE_TOKEN：部署完成未绑定。"
  echo "   绑定: NODE_ACTIVATE_TOKEN='<JWT>' bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/complete_node.sh)"
fi

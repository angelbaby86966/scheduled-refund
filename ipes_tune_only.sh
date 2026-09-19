#!/bin/bash
# =============================================================================
# ipes_tune_only.sh —— IPES/PCDN 存量机「只跑调优段、不重装」热更新补丁
# 版本: v1.0 (2026-09-19)
# 来源: 从 inline_deploy_full.sh (r20-live 3550c918) 的 sys_tune/tune_fd_limits/tune_disk
#       原样抽出，逻辑与一键部署脚本完全一致。
#
# 适用: 已部署 IPES 的存量机（41 台口径），不重装、不动容器、不动绑定。
# 行为:
#   1) /etc/sysctl.d/99-ipes.conf 全量内核调优（UDP缓冲/autocorking/fq/dirty20-10/动态mem）
#   2) 网卡 RPS + tc fq + ring 4096 + txqueuelen
#   3) 文件句柄上限 limits.d + dockerd LimitNOFILE（仅不一致才重启 docker，约数秒掉上行）
#   4) 磁盘队列 scheduler=none/rq_affinity=2 + ext4 commit=60（幂等，/var/lib/.ipes_disk_tuned 标记）
#   5) 上行优先脏页方案 99z-ipes-uplink.conf(20/10) 覆盖 99-pcdn-disk.conf 的 30/50（方案 A）
#
# 用法: curl -fsSL "<本脚本URL>" | bash   或   bash ipes_tune_only.sh [--skip-docker-restart]
#   --skip-docker-restart  跑量高峰时跳过 dockerd 重启（句柄上限下次重启自然生效）
# =============================================================================
set -u
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info(){ echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $1"; }
[ "$(id -u)" -ne 0 ] && { log_error "需 root 运行：sudo bash $0"; exit 1; }

SKIP_DOCKER_RESTART=0
for a in "$@"; do
  case "$a" in
    --skip-docker-restart) SKIP_DOCKER_RESTART=1 ;;
    *) log_warn "未知参数: $a（忽略）" ;;
  esac
done

# ----------------------------- 1) 内核调优 -----------------------------
sys_tune(){
  log_info "=== 系统调优：conntrack / bbr / 端口 / RPS / UDP缓冲 ==="
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
  # 【r20-fix6】不使用 iptables raw NOTRACK（与 firewalld 共存会断 SSH/云助手）
  log_info "sysctl + 网卡调优完成"
}

# ----------------------------- 2) 文件句柄上限 -----------------------------
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
    if [ "$SKIP_DOCKER_RESTART" = "1" ]; then
      log_warn "dockerd LimitNOFILE=$cur≠$LIM，已按 --skip-docker-restart 跳过重启（下次 docker 重启自然生效）"
    else
      log_info "dockerd LimitNOFILE=$cur≠$LIM，重载 docker 使容器继承新句柄上限（约数秒掉上行）"
      systemctl restart docker >/dev/null 2>&1
    fi
  else
    log_info "dockerd 句柄上限已一致（$cur），无需重启"
  fi
}

# ----------------------------- 3) 磁盘队列 -----------------------------
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
      awk 'BEGIN{OFS="\t"} {if($2=="/"&&$3=="ext4"){$4="defaults,noatime,nodiratime,commit=60,barrier=0"; $5="1"; $6="1"} print}' /etc/fstab >/etc/fstab.new && mv /etc/fstab.new /etc/fstab
    fi
  elif echo "$fstype" | grep -q xfs; then
    mount -o remount,logbsize=256k / 2>/dev/null
  fi
  log_info "磁盘调优完成"
  touch /var/lib/.ipes_disk_tuned
}

# ----------------------------- 4) 上行优先脏页方案（覆盖 99-pcdn-disk.conf 的 30/50） -----------------------------
finalize_uplink(){
  # ipes_deploy_full.sh 部署时会生成 99-pcdn-disk.conf(dirty=30/vfs=50)，按字母序晚于 99-ipes.conf 会覆盖上行方案。
  # 用排序最后的 conf(99z > 99p)复述 20/10，保证「上行稳定优先」运行期与开机后都生效（幂等）。
  cat > /etc/sysctl.d/99z-ipes-uplink.conf <<'EOF'
vm.dirty_background_ratio = 10
vm.dirty_ratio = 20
vm.vfs_cache_pressure = 10
EOF
    sysctl -e -p /etc/sysctl.d/99z-ipes-uplink.conf >/dev/null 2>&1
    log_info "上行优先脏页方案(20/10)已锁定，覆盖 99-pcdn-disk.conf 的 30/50"
  }

  # ----------------------------- 0) fstab 自检前置（修复旧版写坏的 fstab，避免重启变只读/节点宕） -----------------------------
  fstab_selfcheck(){
    log_info "=== fstab 自检：检查是否被旧版脚本把 commit=60/barrier=0 写错列 ==="
    local rootline=$(awk '$2=="/"{print; exit}' /etc/fstab 2>/dev/null)
    [ -z "$rootline" ] && { log_info "未找到根挂载行，跳过自检"; return 0; }
    local broken=0
    if echo "$rootline" | grep -qE 'commit=60|barrier=0'; then
      local opt4=$(echo "$rootline" | awk '{print $4}')
      echo "$opt4" | grep -q 'commit=60' || broken=1
    fi
    if [ "$broken" -eq 0 ]; then
      log_info "fstab 根行正常（commit=60 已在第4列），无需修复"
      return 0
    fi
    log_warn "检测到旧版写坏的 fstab 根行，开始修复"
    log_warn "  坏: $rootline"
    cp -a /etc/fstab "/etc/fstab.ipes-bak.$(date +%s)" 2>/dev/null
    awk 'BEGIN{OFS="\t"} {if($2=="/"&&$3=="ext4"){$4="defaults,noatime,nodiratime,commit=60,barrier=0"; $5="1"; $6="1"} print}' /etc/fstab >/etc/fstab.new && mv /etc/fstab.new /etc/fstab
    log_info "  已修正：commit=60,barrier=0 写入第4列挂载选项，第5/6列复位为 1 1"
    if mount | grep ' on / ' | grep -qE '\(ro[,)]'; then
      log_warn "当前根分区为只读，立即 remount rw"
      if mount -o remount,rw / 2>/dev/null; then
        log_info "remount rw 成功"
        if ! systemctl is-active --quiet docker; then
          log_warn "docker 未运行，尝试拉起（best-effort）"
          systemctl restart containerd 2>/dev/null; systemctl start docker 2>/dev/null
          sleep 3; systemctl is-active --quiet docker && log_info "docker 已拉起" || log_error "docker 拉起失败，请手动处理"
        fi
      else
        log_error "remount rw 失败，请手动处理（fstab 已修，重启即可恢复 rw）"
      fi
    fi
    return 0
  }

  # ----------------------------- 主流程 -----------------------------
log_info "========== IPES 存量机调优补丁（不重装/不动容器/不动绑定） =========="
fstab_selfcheck
sys_tune
tune_fd_limits
tune_disk
finalize_uplink
log_info "========== 调优补丁完成 =========="
log_info "验收: sysctl net.ipv4.udp_rmem_min net.ipv4.tcp_limit_output_bytes vm.dirty_ratio"
log_info "      ulimit -n（新 shell）; cat /sys/block/vda/queue/scheduler; ls /var/lib/.ipes_disk_tuned"

#!/bin/bash
# =============================================================================
# IPES 预热调优 + 健康检查 融合版
# -----------------------------------------------------------------------------
# 融合来源：
#   1) fast-preheat.sh            —— OS/IO/网络 激进调优（核心，占 1~4 步）
#   2) install_ipes_health_check.sh —— 健康检查安装（仅取其"装完验证"思路，
#                                      健康检查逻辑改用第 1 个脚本里更稳的版本）
#
# 说明：
#   - 脚本 1 的 5/5 已包含健康检查安装，且其逻辑优于脚本 2（有重启冷却、
#     探测命令缺失跳过、容器停则 docker start 拉起、异常才 docker restart）。
#   - 脚本 2 的已知 bug 已剔除：docker exec 做 restart、@reboot stop 反逻辑、
#     交互式 read 提示、crontab 变量误用、set -e 整脚本退出。
#   - 幂等，可重复执行；仅做 OS 级调优 + 健康拉起，不动 IPES 版本、不重建容器。
# 用法：
#   bash ipes_preheat_and_health.sh
set -uo pipefail
export LC_ALL=C
shopt -s nullglob 2>/dev/null || true
LOG="/var/log/batch_preheat_$(date +%Y%m%d_%H%M%S).log"
# 清理 7 天前的历史预热日志，避免重复执行时日志无限堆积
find /var/log -maxdepth 1 -name 'batch_preheat_*.log' -mtime +7 -delete 2>/dev/null || true
# 状态目录：标记「系统垃圾是否已清理」，避免每次执行都跑 yum clean / journalctl vacuum（这是反复执行时的主要耗时项）
STATE_DIR=/var/lib/ipes-preheat
mkdir -p "$STATE_DIR" 2>/dev/null || true
CLEANED_FLAG="$STATE_DIR/.cleaned_v1"
exec > >(tee -a "$LOG") 2>&1
log(){ echo -e "\033[0;32m[$(date +%T)] INFO\033[0m $*"; }
warn(){ echo -e "\033[0;33m[$(date +%T)] WARN\033[0m $*"; }
err(){ echo -e "\033[0;31m[$(date +%T)] ERROR\033[0m $*"; }
fail(){ err "$*"; echo "PREHEAT_RESULT=FAIL LOG=$LOG"; exit 1; }
[[ $EUID -eq 0 ]] || fail "请使用 root 执行（云助手默认 root）"
command -v curl >/dev/null 2>&1 || timeout 60 yum -y -q --setopt=timeout=10 --setopt=retries=2 install curl >/dev/null 2>&1 || fail "curl 不可用"

# ===================== 1/5 清理系统垃圾 + 挂载项激进化 =====================
free_space_and_mount(){
  log "===== 1/5 清理系统垃圾 + 挂载项 noatime 化 ====="
  # 反复执行时，yum clean all / journalctl vacuum 是主要耗时项；仅在「从未清理」或「超过 7 天」时才做，
  # 且用更轻的 expire-cache 替代 clean all（只刷新过期元数据，不扫描全部），其余执行直接跳过以加速
  if [ ! -f "$CLEANED_FLAG" ] || [ -n "$(find "$CLEANED_FLAG" -mtime +7 2>/dev/null)" ]; then
    timeout 30 yum -q clean expire-cache >/dev/null 2>&1 || true
    timeout 30 journalctl --vacuum-size=200M >/dev/null 2>&1 || true
    touch "$CLEANED_FLAG" 2>/dev/null || true
  else
    log "系统垃圾 7 天内已清理，本次跳过以加速执行"
  fi
  local jc=/etc/systemd/journald.conf
  if ! grep -q '^SystemMaxUse=500M' "$jc" 2>/dev/null; then
    sed -i.bak 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' "$jc" 2>/dev/null && rm -f "$jc.bak" || true
    grep -q '^SystemMaxUse=' "$jc" || echo 'SystemMaxUse=500M' >> "$jc"
    timeout 20 systemctl restart systemd-journald >/dev/null 2>&1 || true
  fi
  # 给缓存盘与根盘加 noatime / nodiratime，减少无谓写盘、降低 IO 抖动
  # 只对「真正的挂载点」操作，跳过非挂载点目录（如 /data 在根盘上时无需独立 remount）
  is_mount(){ [ "$(findmnt -n -o TARGET "$1" 2>/dev/null)" = "$1" ]; }
  # 解析 /data 真实所在挂载点（可能是 /data 独立盘，也可能在根盘上），只 remount 真正的挂载点
  local data_mp mps
  data_mp=$(findmnt -n -o TARGET -T /data 2>/dev/null) || data_mp=
  mps="/"
  # 仅当 /data 在独立挂载点（非根盘）时，额外加入该挂载点；避免与 / 重复导致重复 remount
  [ -n "$data_mp" ] && [ "$data_mp" != "/" ] && mps="$mps $data_mp"
  for mp in $mps; do
    [ -d "$mp" ] || continue
    is_mount "$mp" || continue
    mount -o remount,noatime,nodiratime "$mp" >/dev/null 2>&1 \
      && log "已 remount noatime: $mp" || warn "$mp remount noatime 失败（不影响）"
  done
  log "清理完成，/data 可用: $(df -h /data 2>/dev/null | awk 'NR==2{print $4}')"
}

# ===================== 2/5 Docker 日志/句柄调优（不重建容器） =====================
tune_docker(){
  log "===== 2/5 Docker 日志轮转与句柄上限（不动容器） ====="
  if ! command -v docker >/dev/null 2>&1; then warn "未检测到 docker，跳过 Docker 调优"; return 0; fi
  mkdir -p /etc/docker /etc/systemd/system/docker.service.d
  local need_restart=0
  # registry-mirror 仅在「可达」时才写入，避免个别节点连不上该镜像导致将来 docker pull 失败
  # （已配置过该镜像的节点不再联网探测，保持 1-2s 重跑速度）
  local mirror_json="" want_mirror=0
  if [ -f /etc/docker/daemon.json ] && grep -q 'stxam7vz.mirror.aliyuncs.com' /etc/docker/daemon.json 2>/dev/null; then
    want_mirror=1
  else
    if curl -sS --connect-timeout 8 --max-time 15 -o /dev/null "https://stxam7vz.mirror.aliyuncs.com/v2/" 2>/dev/null; then
      want_mirror=1
    else
      warn "aliyun 镜像不可达，跳过 registry-mirror（保留 Docker 官方源，避免 docker pull 失败）"
    fi
  fi
  [ "$want_mirror" -eq 1 ] && mirror_json='  "registry-mirrors": ["https://stxam7vz.mirror.aliyuncs.com"],'
  cat > /tmp/preheat_daemon.json <<EOF
{
$mirror_json
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" },
  "storage-driver": "overlay2",
  "live-restore": true
}
EOF
  if ! cmp -s /tmp/preheat_daemon.json /etc/docker/daemon.json 2>/dev/null; then
    cp /tmp/preheat_daemon.json /etc/docker/daemon.json; need_restart=1
  fi
  rm -f /tmp/preheat_daemon.json
  cat > /tmp/preheat_limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
EOF
  if ! cmp -s /tmp/preheat_limits.conf /etc/systemd/system/docker.service.d/limits.conf 2>/dev/null; then
    cp /tmp/preheat_limits.conf /etc/systemd/system/docker.service.d/limits.conf; need_restart=1
  fi
  rm -f /tmp/preheat_limits.conf
  if [ "$need_restart" -eq 1 ]; then
    timeout 30 systemctl daemon-reload >/dev/null 2>&1 || true; timeout 30 systemctl restart docker >/dev/null 2>&1 || warn "Docker 重启失败（不影响 IPES 运行态）"
  else
    log "Docker 配置未变化，跳过重启"
  fi
  log "Docker 日志轮转已开启（<=20M×3），句柄上限 1048576"
}

# ===================== 3/5 内核/网络 激进调优 =====================
tune_system_aggressive(){
  log "===== 3/5 内核/网络 激进调优（更大缓冲、更激进脏页、关 swap） ====="
  # 按物理内存缩放 TCP 总内存池：low/press/max ≈ 15%/30%/60% 内存（page=4KB），max 封顶 16G，避免低内存机型 OOM
  local mem_kb mem_mb ram_pages tp_low tp_press tp_max
  mem_kb=$(grep -m1 MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
  mem_mb=$(( ${mem_kb:-8388608} / 1024 ))
  ram_pages=$(( mem_mb * 256 ))
  tp_low=$(( ram_pages * 15 / 100 )); tp_press=$(( ram_pages * 30 / 100 )); tp_max=$(( ram_pages * 60 / 100 ))
  [ "$tp_max" -gt 4194304 ] && tp_max=4194304
  cat > /etc/sysctl.d/99-ipes.conf <<'EOF'
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.netdev_max_backlog = 100000
net.core.somaxconn = 65535
net.core.netdev_budget = 1000
net.core.rps_sock_flow_entries = 32768
# 默认 qdisc 改用 fq_codel：海量并发连接下比默认 pfifo_fast 更抗 bufferbloat（仅影响新建/重启后的网卡，旧网卡不变）
net.core.default_qdisc = fq_codel
net.ipv4.tcp_rmem = 4096 163840 33554432
net.ipv4.tcp_wmem = 4096 163840 33554432
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_orphans = 65536
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1
# tcp_timestamps=1 才能与下方 tcp_tw_reuse 配合安全复用 TIME_WAIT（PCDN 海量出向连接关键）
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_mem = 786432 2097152 4194304
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_retries2 = 10
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_no_metrics_save = 1
# 关闭 ECN，避免部分中间设备/老旧网络导致连接建立失败（P2P 连接更稳）
net.ipv4.tcp_ecn = 0
net.netfilter.nf_conntrack_max = 1048576
net.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
fs.file-max = 4000000
fs.aio-max-nr = 1048576
kernel.pid_max = 4194304
# —— 激进缓存预热参数（PCDN 缓存可重拉，丢失脏页可接受） ——
vm.swappiness = 0
vm.dirty_ratio = 40
vm.dirty_background_ratio = 30
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 50
vm.vfs_cache_pressure = 30
vm.zone_reclaim_mode = 0
vm.overcommit_memory = 1
vm.min_free_kbytes = 65536
vm.extra_free_kbytes = 65536
fs.inotify.max_user_watches = 1048576
EOF
  if modprobe tcp_bbr 2>/dev/null && grep -q tcp_bbr /proc/modules 2>/dev/null; then
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/99-ipes.conf
    log "已启用 BBR 拥塞控制"
  else
    echo "net.ipv4.tcp_congestion_control = cubic" >> /etc/sysctl.d/99-ipes.conf
    warn "内核不支持 BBR，使用 cubic（如需 BBR 请升级内核）"
  fi
  sed -i "s#^net.ipv4.tcp_mem = .*#net.ipv4.tcp_mem = $tp_low $tp_press $tp_max#" /etc/sysctl.d/99-ipes.conf 2>/dev/null || true
  modprobe nf_conntrack 2>/dev/null || true
  # 老内核(如 3.10)可能无 vm.extra_free_kbytes，存在才保留；否则删掉该行，
  # 避免 sysctl -p 因未知键报错并回退到慢速的 sysctl --system
  [ -f /proc/sys/vm/extra_free_kbytes ] || sed -i '/^vm.extra_free_kbytes/d' /etc/sysctl.d/99-ipes.conf
  # 持久化内核模块：重启后 systemd-sysctl 应用 99-ipes.conf 前需先加载模块，
  # 否则 nf_conntrack_max / tcp_congestion_control=bbr 等键会因模块未加载而失效
  local ml=/etc/modules-load.d/ipes.conf
  echo "nf_conntrack" > "$ml" 2>/dev/null || true
  grep -q tcp_bbr /proc/modules 2>/dev/null && echo "tcp_bbr" >> "$ml" 2>/dev/null || true
  # 应用并回显失败项（不静默吞掉，方便排查内核不支持的键）
  if ! sysctl -p /etc/sysctl.d/99-ipes.conf 2>/tmp/ipes_sysctl.err; then
    warn "部分 sysctl 键未生效（多为内核不支持，已忽略）: $(grep -iE 'unknown|error|cannot|invalid' /tmp/ipes_sysctl.err 2>/dev/null | head -3 | tr '\n' ' ')"
    sysctl --system >/dev/null 2>&1 || true
  fi
  rm -f /tmp/ipes_sysctl.err
  # 关闭 swap：避免缓存页被换出拖慢命中速度
  if swapon --show 2>/dev/null | grep -q '^/'; then
    swapoff -a 2>/dev/null && log "已关闭 swap（临时）" || warn "swapoff 失败"
    sed -i.bak '/\bswap\b/s/^/#/' /etc/fstab 2>/dev/null && rm -f /etc/fstab.bak || true
  else
    log "系统无 swap，跳过"
  fi
  cat > /etc/security/limits.d/99-ipes.conf <<'EOF'
* soft nofile 1000000
* hard nofile 1000000
* soft nproc 1000000
* hard nproc 1000000
EOF
  # ⚠️ 防火墙（firewalld）保留，不在此脚本处理；端口开放由你单独的开防火墙脚本负责
  setenforce 0 >/dev/null 2>&1 || true
  sed -i.bak 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config 2>/dev/null && rm -f /etc/selinux/config.bak || true
  log "已放开文件句柄、关闭 SELinux、应用激进网络/内存调优（防火墙保持开启，由外部脚本处理）"
}

# ===================== 4/5 性能调优：CPU/网卡/磁盘/时钟 =====================
tune_perf(){
  log "===== 4/5 性能调优：CPU/网卡/磁盘/时钟 ====="
  cat > /usr/local/bin/ipes-boot-tune.sh <<'EOF'
#!/usr/bin/env bash
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$f" 2>/dev/null
  done
else
  echo "cpufreq 接口不可用，跳过 CPU 性能模式设置（虚拟化 CPU 常见，无影响）"
fi
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
for d in /sys/block/*; do
  dev=$(basename "$d")
  rot=$(cat "$d/queue/rotational" 2>/dev/null)
  if [ "$rot" = "0" ]; then echo none > "$d/queue/scheduler" 2>/dev/null
  else echo mq-deadline > "$d/queue/scheduler" 2>/dev/null; fi
  echo 256 > "$d/queue/read_ahead_kb" 2>/dev/null
  echo 1024 > "$d/queue/nr_requests" 2>/dev/null
  echo 0 > "$d/queue/add_random" 2>/dev/null
done
ncpu=$(nproc)
ndigits=$(( (ncpu + 3) / 4 ))
if [ "$ncpu" -lt 64 ]; then val=$(( (1 << ncpu) - 1 )); else val=18446744073709551615; fi
mask=$(printf "%0*x" "$ndigits" "$val")
sysctl -w net.core.rps_sock_flow_entries=32768 >/dev/null 2>&1
for dev in /sys/class/net/*; do
  d=$(basename "$dev"); [ "$d" = "lo" ] && continue
  qdir=/sys/class/net/$d/queues
  [ -d "$qdir" ] || continue
  for q in "$qdir"/rx-*; do
    echo "$mask" > "$q/rps_cpus" 2>/dev/null
    echo 4096 > "$q/rps_flow_cnt" 2>/dev/null
  done
done
EOF
  chmod +x /usr/local/bin/ipes-boot-tune.sh
  /usr/local/bin/ipes-boot-tune.sh
  grep -q ipes-boot-tune /etc/rc.d/rc.local 2>/dev/null || echo '/usr/local/bin/ipes-boot-tune.sh' >> /etc/rc.d/rc.local
  chmod +x /etc/rc.d/rc.local 2>/dev/null || true
  # 确保 rc-local 服务开机启动，否则重启后 RPS/磁盘调度/THP/CPU 性能模式等运行时调优会丢失
  timeout 20 systemctl enable rc-local >/dev/null 2>&1 || true
  rpm -q irqbalance >/dev/null 2>&1 || timeout 120 yum -y -q --setopt=timeout=10 --setopt=retries=2 install irqbalance >/dev/null 2>&1 || true
  timeout 20 systemctl enable --now irqbalance >/dev/null 2>&1 || true
  rpm -q chrony >/dev/null 2>&1 || timeout 120 yum -y -q --setopt=timeout=10 --setopt=retries=2 install chrony >/dev/null 2>&1 || true
  timeout 30 systemctl enable --now chronyd >/dev/null 2>&1 || true
  log "CPU 性能模式 / 关 THP / 磁盘调度 / 网卡 RPS-RFS / irqbalance / 时间同步 已配置并持久化"
}

# ===================== 5/5 温和健康检查 + 确保 IPES 在跑（不重建） =====================
# 注：本函数整合了两个脚本的健康检查需求。脚本 2 的 exec-start / @reboot-stop /
#     交互 read / crontab 变量 bug 均已剔除，统一用此稳版。
install_healthcheck(){
  log "===== 5/5 安装温和健康检查（容器级拉起 + 应用层探测，不重建业务） ====="
  cat > /usr/local/bin/ipes_health_check.sh <<'EOF'
#!/usr/bin/env bash
# IPES 健康检查（融合版）：容器级 docker start 兜底 + 应用层 ./bin/ipes health 探测，
# 真正异常时才 docker restart 恢复；非交互、并对「探测命令不存在」做了跳过处理避免每分钟重启抖动。
LOG=/var/log/ipes_health.log
C=ipes
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
echo "[$(ts)] 检查开始" >> "$LOG"
if ! docker ps --format '{{.Names}}' | grep -qx "$C"; then
  echo "[$(ts)] 容器未运行，尝试 docker start（SN 不变）" >> "$LOG"
  docker start "$C" >> "$LOG" 2>&1 && echo "[$(ts)] 已启动" >> "$LOG" || echo "[$(ts)] 启动失败，请检查" >> "$LOG"
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
  echo "$now_ts" > "$LR" 2>/dev/null || true
  echo "[$(ts)] 检测到服务异常，准备 docker restart ($OUT)" >> "$LOG"
  docker restart "$C" >> "$LOG" 2>&1 && echo "[$(ts)] 已重启恢复" >> "$LOG" || echo "[$(ts)] 重启失败，请检查" >> "$LOG"
  exit 0
fi
echo "[$(ts)] 服务正常" >> "$LOG"
EOF
  chmod +x /usr/local/bin/ipes_health_check.sh
  touch /var/log/ipes_health.log
  # 最小系统可能未预装 cronie，crontab 命令缺失会导致健康检查无法定时；先确保安装
  rpm -q cronie >/dev/null 2>&1 || timeout 120 yum -y -q --setopt=timeout=10 --setopt=retries=2 install cronie >/dev/null 2>&1 || true
  # 日志轮转：避免健康检查日志与预热日志无限增长（copytruncate 对正在写入的日志安全）
  cat > /etc/logrotate.d/ipes <<'EOF'
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
EOF
  ( crontab -l 2>/dev/null | grep -v 'ipes_health_check.sh'; \
    echo '* * * * * /usr/local/bin/ipes_health_check.sh > /dev/null 2>&1' ) | crontab -
  timeout 20 systemctl enable --now crond >/dev/null 2>&1 || timeout 20 systemctl enable --now cronie >/dev/null 2>&1 || true
  if docker ps --format '{{.Names}}' | grep -qx ipes; then
    log "IPES 容器当前运行中（镜像: $(docker inspect -f '{{.Config.Image}}' ipes 2>/dev/null)），未重建"
  else
    # 先尝试拉起「已存在但已停止」的容器：docker start 可恢复，避免 docker_run 因同名冲突失败
    if docker start ipes >/dev/null 2>&1; then
      log "已拉起已停止的 IPES 容器（未重建，SN 不变）"
    elif [ -f /opt/ipes/docker_run ]; then
      warn "未见运行中的 ipes 容器，尝试按 /opt/ipes/docker_run 创建并拉起"
      bash /opt/ipes/docker_run >/dev/null 2>&1 \
        && log "已按 /opt/ipes/docker_run 拉起 IPES" || warn "拉起失败，请手动检查"
    else
      warn "未见 ipes 容器且无 /opt/ipes/docker_run，请手动检查"
    fi
  fi
  log "健康检查已安装（每分钟：容器停则 docker start 拉起；在跑则 ./bin/ipes health 探测，异常才 docker restart；不影响 SN）"
  # —— 取自脚本 2 的「装完验证」思路：跑一次确认脚本可执行、日志可写 ——
  if /usr/local/bin/ipes_health_check.sh >/dev/null 2>&1; then
    log "健康检查脚本验证通过（已跑一次，日志见 /var/log/ipes_health.log）"
  else
    warn "健康检查脚本首次运行返回非 0（多为容器未运行，属正常），详见 /var/log/ipes_health.log"
  fi
}

main(){
  SECONDS=0
  log "########## IPES 预热调优 + 健康检查 融合版开始（仅调优，不动版本/不重建） ##########"
  free_space_and_mount
  tune_docker
  tune_system_aggressive
  tune_perf
  install_healthcheck
  log "########## 预热调优 + 健康检查安装完成 ##########"
  log "当前 IPES 镜像: $(docker inspect -f '{{.Config.Image}}' ipes 2>/dev/null || echo '（无运行容器）')"
  log "缓存占用: $(df -h /data 2>/dev/null | awk 'NR==2{print $5" 已用 / "$2" 总"}')"
  log "⚠️ 说明：脚本已把 OS 级写入/网络吞吐拉满，但缓存涨速仍取决于平台派量与上行带宽；脚本无法强制拉满到 90%。"
  log "总耗时: ${SECONDS}s"
  echo "PREHEAT_RESULT=OK LOG=$LOG"
}
main "$@"

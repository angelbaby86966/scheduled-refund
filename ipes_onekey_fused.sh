#!/bin/bash
# =============================================================================
# ipes_onekey_fused.sh  v2.0-lite  (2026-09-26)
# 精简版三合一（自包含，不再下载子脚本），仅保留 6 个模块：
#   [1] 网卡：RPS 全核 + fq 队列 + ring buffer 4096 + txqueuelen 10000
#   [2] CPU：governor=performance + THP=never（含开机重放 service）
#   [3] 句柄：nofile 4096 → 1048576（默认不重启 docker，prlimit 热提升）
#   [4] 健康检查：crontab 每分钟巡检（容器挂 docker start；应用异常才 restart）
#   [5] 防火墙：iptables 全量放行 TCP+UDP 1-65535（rc.local 持久化）
#   [6] 缓存扩容：磁盘有未分配空间就在线扩分区+文件系统
# 已移除（用户指定）：fstab 自检 / sysctl 权威文件 / 冲突让位 / 脏页 99z / ipes-tune.service
#                    开机重放 / 清垃圾 / docker 日志轮转 / 内核激进调优 / 快照 / NAT
#                    tc 探测 / 预热复用 / 容器对齐(happ 拉满/镜像重建)
# 全程：不动 device_code/ipes_sn 身份、不重建容器、不重启机器
# =============================================================================
set -uo pipefail
export LC_ALL=C
FUSED_REV="20260926-fused-v20-lite"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;36m'; N='\033[0m'
LOG=/var/log/ipes_fused_lite.log
_log(){ printf '%s\n' "$1" >>"$LOG" 2>/dev/null; }
info(){ echo -e "${G}[INFO]${N} $1"; _log "[INFO] $1"; }
warn(){ echo -e "${Y}[WARN]${N} $1"; _log "[WARN] $1"; }
step(){ echo -e "\n${B}--- [$1] $2 ---${N}"; _log "--- [$1] $2 ---"; }

[[ $EUID -eq 0 ]] || { echo -e "${R}[ERROR]${N} 请使用 root 执行"; exit 1; }
echo -e "\033[1;36m########## IPES 精简融合脚本（网卡/CPU/句柄/健康检查/防火墙/扩盘） $FUSED_REV ##########\033[0m"

# =============================================================================
# [1] 网卡：RPS 全核 + fq + ring 4096 + txqueuelen（取自 tune_only net_tune）
# =============================================================================
net_tune(){
  step "1/6" "网卡 RPS / fq / ring / txqueuelen"
  local nic; nic=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -z "$nic" ] && nic=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
  [ -z "$nic" ] && { warn "未识别默认网卡，跳过"; return 0; }
  local ncpu mask; ncpu=$(nproc); mask=$(printf '%x' $(( (1<<ncpu)-1 )))
  local q
  for q in /sys/class/net/$nic/queues/rx-*; do
    [ -e "$q" ] || continue
    echo "$mask" >"$q/rps_cpus" 2>/dev/null
    echo 4096 >"$q/rps_flow_cnt" 2>/dev/null
  done
  tc qdisc replace dev "$nic" root fq 2>/dev/null
  ethtool -G "$nic" rx 4096 tx 4096 2>/dev/null
  ip link set "$nic" txqueuelen 10000 2>/dev/null
  info "网卡 $nic：RPS mask=$mask，txqueuelen=$(cat /sys/class/net/$nic/tx_queue_len 2>/dev/null)，qdisc=$(tc qdisc show dev "$nic" 2>/dev/null | head -1)"
}

# =============================================================================
# [2] CPU：governor=performance + THP=never（含开机重放 service）
# =============================================================================
gov_tune(){
  step "2/6" "CPU governor=performance + THP=never"
  local n=0 g t
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -e "$g" ] || continue
    echo performance >"$g" 2>/dev/null && n=$((n+1))
  done
  for t in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
    [ -e "$t" ] && echo never >"$t" 2>/dev/null
  done
  if [ "$n" -gt 0 ]; then
    info "governor=performance（$n 个核，热写 /sys）；THP=never"
  else
    info "本机无 cpufreq（虚拟化机型常见），governor 跳过；THP=never"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    cat >/etc/systemd/system/ipes-gov-tuned.service <<'GOV'
[Unit]
Description=IPES CPU governor(performance) + THP(never) replay on boot
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g 2>/dev/null; done; for t in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do echo never > $t 2>/dev/null; done'
[Install]
WantedBy=multi-user.target
GOV
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable ipes-gov-tuned.service >/dev/null 2>&1
    info "已注册 ipes-gov-tuned.service（开机重放 governor/THP）"
  fi
}

# =============================================================================
# [3] 句柄：nofile → 1048576（默认不重启 docker，prlimit 热提升零中断）
# =============================================================================
get_dockerd_nofile(){
  local v pid
  v=$(systemctl show docker -p LimitNOFILE 2>/dev/null | sed -n 's/^LimitNOFILE=//p')
  if [ -z "$v" ]; then
    pid=$(pgrep -x dockerd 2>/dev/null | head -1)
    [ -n "$pid" ] && v=$(awk '/Max open files/{print $4}' /proc/$pid/limits 2>/dev/null)
  fi
  printf '%s' "$v"
}

fd_limits(){
  step "3/6" "nofile 上限（容器需 dockerd 继承）"
  local nr_open LIM cur p
  nr_open=$(cat /proc/sys/fs/nr_open 2>/dev/null || echo 1048576)
  LIM=$(( nr_open < 1048576 ? nr_open : 1048576 ))
  cur=$(get_dockerd_nofile)
  cat >/etc/security/limits.d/99-ipes.conf <<EOF
# OWNER: ipes_fused_lite (v2.0)
*     soft nofile $LIM
*     hard nofile $LIM
root  soft nofile $LIM
root  hard nofile $LIM
EOF
  mkdir -p /etc/systemd/system/docker.service.d
  cat >/etc/systemd/system/docker.service.d/limits.conf <<EOF
[Service]
LimitNOFILE=$LIM
LimitNPROC=$LIM
EOF
  systemctl daemon-reload >/dev/null 2>&1
  info "配置已写 $LIM（dockerd 当前生效=${cur:-取不到}，fs.nr_open=$nr_open）"
  # prlimit 热提升已在跑的 dockerd/containerd（零中断）
  if command -v prlimit >/dev/null 2>&1; then
    for p in $(pgrep -x dockerd 2>/dev/null) $(pgrep -x containerd 2>/dev/null); do
      prlimit --pid "$p" --nofile="$LIM:$LIM" >/dev/null 2>&1 && info "  已对 pid=$p 热提升 nofile=$LIM（无需重启）"
    done
  fi
  if [ -z "$cur" ]; then
    warn "读不到 dockerd 生效值：配置已写好，待 docker 启动/重启后生效"
  elif [ "$cur" != "$LIM" ]; then
    warn "生效值($cur)≠配置值($LIM)：已保持【不重启】零掉量；等下次 docker/机器重启自动生效"
  else
    info "dockerd 生效值已一致（$cur），无需重启"
  fi
}

# =============================================================================
# [4] 健康检查：crontab 每分钟巡检（取自 preheat 5/5 稳版）
# =============================================================================
install_healthcheck(){
  step "4/6" "安装温和健康检查（容器级拉起 + 应用层探测，不重建业务）"
  cat > /usr/local/bin/ipes_health_check.sh <<'EOF'
#!/usr/bin/env bash
# IPES 健康检查：容器级 docker start 兜底 + 应用层 ./bin/ipes health 探测，
# 真正异常时才 docker restart 恢复（10 分钟冷却）；探测命令不存在则跳过，避免每分钟抖动。
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
EOF
  chmod +x /usr/local/bin/ipes_health_check.sh
  touch /var/log/ipes_health.log
  rpm -q cronie >/dev/null 2>&1 || timeout 120 yum -y -q --setopt=timeout=10 --setopt=retries=2 install cronie >/dev/null 2>&1 || true
  cat > /etc/logrotate.d/ipes-health <<'EOF'
/var/log/ipes_health.log {
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
    info "IPES 容器运行中（镜像: $(docker inspect -f '{{.Config.Image}}' ipes 2>/dev/null)），未重建"
  else
    if docker start ipes >/dev/null 2>&1; then
      info "已拉起已停止的 IPES 容器（未重建，SN 不变）"
    elif [ -f /opt/ipes/docker_run ]; then
      warn "未见运行中的 ipes 容器，尝试按 /opt/ipes/docker_run 创建并拉起"
      bash /opt/ipes/docker_run >/dev/null 2>&1 && info "已按 /opt/ipes/docker_run 拉起 IPES" || warn "拉起失败，请手动检查"
    else
      warn "未见 ipes 容器且无 /opt/ipes/docker_run，请手动检查"
    fi
  fi
  if /usr/local/bin/ipes_health_check.sh >/dev/null 2>&1; then
    info "健康检查已安装并验证通过（每分钟巡检，日志 /var/log/ipes_health.log）"
  else
    warn "健康检查已安装；首次运行非 0（多为容器未运行，属正常）"
  fi
}

# =============================================================================
# [5] 防火墙：全量放行 TCP+UDP 1-65535（取自 align 1/6，rc.local 持久化）
# =============================================================================
fw_open(){
  step "5/6" "主机防火墙全量放行 TCP+UDP 1-65535"
  for s in firewalld iptables ip6tables; do
    systemctl disable --now "$s" >/dev/null 2>&1 || true
  done
  if command -v nft >/dev/null 2>&1; then
    nft flush ruleset >/dev/null 2>&1 || true
  fi
  cat > /usr/local/bin/ipes-fw-open.sh <<'EOS'
#!/bin/bash
# PCDN 全锥 NAT 前置：入向 TCP/UDP 全放行（IPv4+IPv6）。
# 只做「插入 ACCEPT + 默认策略 ACCEPT」，不 -F（避免清掉 Docker 自己的链）。
set -uo pipefail
IPTS=$(command -v iptables  || echo /sbin/iptables)
IP6TS=$(command -v ip6tables || echo /sbin/ip6tables)
ins(){ local b="$1"; shift; "$b" -C "$@" >/dev/null 2>&1 || "$b" -I "$@" >/dev/null 2>&1 || true; }
for T in "$IPTS" "$IP6TS"; do
  [ -x "$T" ] || continue
  "$T" -P INPUT ACCEPT   2>/dev/null
  "$T" -P FORWARD ACCEPT 2>/dev/null
  "$T" -P OUTPUT ACCEPT  2>/dev/null
  ins "$T" INPUT -i lo -j ACCEPT
  ins "$T" INPUT -p tcp --dport 1:65535 -j ACCEPT
  ins "$T" INPUT -p udp --dport 1:65535 -j ACCEPT
  ins "$T" INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
done
exit 0
EOS
  chmod +x /usr/local/bin/ipes-fw-open.sh
  /usr/local/bin/ipes-fw-open.sh
  local ok4 ok6
  ok4=$(iptables -S INPUT 2>/dev/null | grep -c -- '--dport 1:65535' || true)
  ok6=$(ip6tables -S INPUT 2>/dev/null | grep -c -- '--dport 1:65535' || true)
  info "已放行：IPv4 规则 $ok4 条 / IPv6 规则 $ok6 条（默认策略 ACCEPT）"
  if ! grep -q 'ipes-fw-open.sh' /etc/rc.d/rc.local 2>/dev/null; then
    echo '/usr/local/bin/ipes-fw-open.sh' >> /etc/rc.d/rc.local 2>/dev/null || true
  fi
  chmod +x /etc/rc.d/rc.local 2>/dev/null || true
  timeout 20 systemctl enable rc-local >/dev/null 2>&1 || true
  info "已写入 /etc/rc.d/rc.local 并 enable rc-local（重启后自动重新放行）"
}

# =============================================================================
# [6] 缓存扩容：磁盘有未分配空间就在线扩分区+文件系统（取自 align 5/6）
# =============================================================================
cache_used_mb(){
  local s
  s=$(timeout 90 du -sm /data/happ/*/hdata/cache 2>/dev/null | awk '{t+=$1} END{print t+0}')
  echo "${s:-0}"
}

align_cache(){
  step "6/6" "缓存容量对齐（在线扩盘 + 缓存占用报告）"
  local root_dev root_disk fs disk_bytes part_bytes
  root_dev=$(findmnt -n -o SOURCE / 2>/dev/null)
  fs=$(findmnt -n -o FSTYPE / 2>/dev/null)
  info "/data 可用: $(df -h /data 2>/dev/null | awk 'NR==2{print $4"/"$2" ("$5" 已用)"}')"
  info "缓存占用: $(cache_used_mb)MB（/data/happ/*/hdata/cache）"
  case "$root_dev" in
    /dev/mapper/*|/dev/dm-*) warn "根盘在 LVM 上，不做自动扩分区（需手动 lvextend+resize）"; return 0 ;;
    "") warn "取不到根设备，跳过扩盘"; return 0 ;;
  esac
  root_disk=${root_dev%%[0-9]*}
  disk_bytes=$(lsblk -b -d -n -o SIZE "$root_disk" 2>/dev/null || echo 0)
  part_bytes=$(lsblk -b -n -o SIZE "$root_dev" 2>/dev/null || echo 0)
  if [ "${disk_bytes:-0}" -gt "${part_bytes:-0}" ] 2>/dev/null; then
    info "磁盘比分区大 $(( (disk_bytes - part_bytes) / 1024 / 1024 ))MiB，开始在线扩容"
    local grow_ok=0
    if command -v growpart >/dev/null 2>&1; then
      growpart "$root_disk" "${root_dev##*[^0-9]}" >/dev/null 2>&1 && grow_ok=1 || true
    fi
    if [ "$grow_ok" -eq 0 ]; then
      parted -s "$root_disk" resizepart "${root_dev##*[^0-9]}" 100% >/dev/null 2>&1 && grow_ok=1 || true
    fi
    if [ "$grow_ok" -eq 1 ]; then
      case "$fs" in
        ext4|ext3|ext2) resize2fs "$root_dev" >/dev/null 2>&1 || warn "resize2fs 失败" ;;
        xfs)            xfs_growfs / >/dev/null 2>&1 || warn "xfs_growfs 失败" ;;
        *)              warn "未知文件系统 ${fs}，未扩容" ;;
      esac
      info "在线扩容后 /data 可用: $(df -h /data 2>/dev/null | awk 'NR==2{print $4"/"$2}')"
    else
      warn "分区扩展失败（未动数据，安全）"
    fi
  else
    info "磁盘与分区已等大，无需扩容"
  fi
}

# =============================================================================
# 主流程
# =============================================================================
net_tune
gov_tune
fd_limits
install_healthcheck
fw_open
align_cache

echo
echo -e "\033[1;42;30m ✔ 精简融合执行完毕（6 模块，$FUSED_REV） \033[0m"

# 平台感知的放行提示（主机层已放行，云端实例级还需控制台操作）
_iid=$(curl -s --max-time 3 http://100.100.100.200/latest/meta-data/instance-id 2>/dev/null | tr -d '\r\n')
case "$_iid" in
  i-*) PLATFORM="ECS" ;;
  "")  PLATFORM="未知" ;;
  *)   PLATFORM="轻量应用服务器(SWAS)" ;;
esac
echo "   实例ID=${_iid:-N/A}   平台=$PLATFORM"
echo "   ⚠ 主机防火墙已放行，但【云端实例级】放行不随镜像继承，需在控制台操作："
case "$_iid" in
  i-*) echo "     · ECS：控制台 → 本实例 → 安全组 → 入方向 添加「TCP+UDP / 1/65535 / 0.0.0.0/0」" ;;
  *)   echo "     · 轻量服务器：控制台 → 本实例 → 防火墙 → 添加规则（或工作台「防火墙模板」批量应用）" ;;
esac
exit 0

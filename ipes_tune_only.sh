#!/bin/bash
# =============================================================================
#  ipes_tune_only.sh   v2.1   (2026-09-19)
#  存量机「纯优化」热补丁 —— 不重装 / 不重建容器 / 不动身份绑定 / 不重启机器
# -----------------------------------------------------------------------------
#  v2.1 变更（SWAS CentOS7 + 上海节点真机验证后修正）：
#   · 修 dockerd nofile 取值：CentOS7 的 systemd 219 不支持 `systemctl show --value`（返回空），
#     旧写法让"生效值≠配置值"永远成立 ⇒ 每次部署都白重启一遍 docker 打断容器。
#     现改为 `systemctl show -p LimitNOFILE | sed` + 回读 /proc/<dockerd>/limits 双保险。
#   · 验收表修正：scheduler 取 `[]` 内当前值（不再因 "none mq-deadline kyber" 误报 FAIL）；
#     无 cpufreq 的虚拟化机型 governor 记 n/a 而非 FAIL；dockerd 期望值改用实际 LIM。
#   · 无 cpufreq 时明确提示"跳过 governor"，不再打印"0 个核"。
#   · guard 断言不符时先重跑 sysctl 让位再重放（防 /etc/sysctl.conf 又被写回）。
#
#  做什么（全部幂等，可反复执行）：
#   [0] fstab 自检：修复旧版把 commit=60/barrier=0 写错列的问题；根分区只读则 remount rw
#   [1] 内核 sysctl 全量调优（单权威文件 /etc/sysctl.d/99-ipes.conf，带归属标记 + 按内存缩放）
#   [2] sysctl 冲突让位：把 /etc/sysctl.conf 等文件里【同名异值】的行就地注释，防止被 sysctl --system 打回
#   [3] 网卡：RPS 全核 + rps_flow_cnt + tc fq + ring 4096 + txqueuelen 10000
#   [4] CPU governor=performance + 透明大页=never（含开机重放 service）
#   [5] 文件句柄上限 4096 → 1048576（limits.d + dockerd；默认【不重启 docker】）
#   [6] 磁盘队列 + 挂载参数（大块顺序写盘 / 并发读缓存；预读保持 256K — 实测调大是负优化）
#   [7] 上行优先脏页方案 99z-ipes-uplink.conf(20/10)，压过 99-pcdn-disk.conf 的 30/50
#   [8] 自安装 /usr/local/bin/ipes-tune.sh + ipes-tune.service（开机自动重放，重启不回退）
#   [9] 关键键断言自愈 + 验收表 + IPES 容器/happy 只读体检
#
#  不做（与一键部署脚本的本质区别）：
#   × 不下载/安装 IPES、不注册节点、不改 device_code / IPES_SN
#   × 不重建、不重启 IPES 容器（无绑定改动 ⇒ 不掉量）
#   × 不做 fio/dd 基准压测（跑量机上压测有 OOM 拖垮 happy 的风险）
#
#  用法：
#     curl -fsSL "<本脚本URL>" | bash
#     bash ipes_tune_only.sh [--skip-docker-restart|--restart-docker] [--data-writeback] [--no-service]
#  参数：
#     --skip-docker-restart  显式跳过 dockerd 重启（默认行为就是不重启，兼容旧调用）
#     --restart-docker       立即重启 dockerd，让容器内的 nofile 上限立刻生效（约数秒掉上行）
#     --data-writeback       额外把根分区改成 data=writeback（写盘更快，代价是崩溃一致性变弱）
#     --no-service           不安装 ipes-tune.service 开机重放
#     --replay               内部用：由 systemd 开机调用，静默模式，不自安装
# =============================================================================
set +e
TUNE_ONLY_VERSION="2.1"
# ★版本指纹★：自安装时回读远端文件必须含这一行，否则判定拿到旧版（CDN 缓存）并放弃安装。
TUNE_ONLY_REV="20260919-tuneonly-v21c"
SELF_URLS="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/r20-live/ipes_tune_only.sh
https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@r20-live/ipes_tune_only.sh
https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/r20-live/ipes_tune_only.sh"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;36m'; N='\033[0m'
LOG=/var/log/ipes_tune_only.log
_log(){ printf '%s\n' "$1" >>"$LOG" 2>/dev/null; }
info(){ echo -e "${G}[INFO]${N} $1"; _log "[INFO] $1"; }
warn(){ echo -e "${Y}[WARN]${N} $1"; _log "[WARN] $1"; }
err(){  echo -e "${R}[ERR ]${N} $1"; _log "[ERR ] $1"; }
step(){ echo -e "\n${B}--- [$1] $2 ---${N}"; _log "--- [$1] $2 ---"; }

SKIP_DOCKER_RESTART=0; FORCE_DOCKER_RESTART=0; DATA_WRITEBACK=0; NO_SERVICE=0; REPLAY=0
for a in "$@"; do
  case "$a" in
    --skip-docker-restart) SKIP_DOCKER_RESTART=1 ;;
    --restart-docker)      FORCE_DOCKER_RESTART=1 ;;
    --data-writeback)      DATA_WRITEBACK=1 ;;
    --no-service)          NO_SERVICE=1 ;;
    --replay)              REPLAY=1; SKIP_DOCKER_RESTART=1 ;;
    *) warn "未知参数: $a（忽略）" ;;
  esac
done

[ "$(id -u)" -ne 0 ] && { err "需要 root 运行：sudo bash $0"; exit 1; }

if [ "$REPLAY" -eq 0 ]; then
  echo ""
  echo "=============================================================="
  echo " IPES 存量机纯优化补丁  v${TUNE_ONLY_VERSION}   $(date '+%F %T')"
  echo " host=$(hostname 2>/dev/null)  ncpu=$(nproc 2>/dev/null||echo 1)  mem=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))MB"
  echo " 不重装 / 不重建容器 / 不动身份绑定"
  echo "=============================================================="
fi

# =============================================================================
# [0] fstab 自检 —— 旧版把 commit=60/barrier=0 写错列会导致重启后根分区只读
# =============================================================================
FSTAB_EXTRA=""
[ "$DATA_WRITEBACK" = "1" ] && FSTAB_EXTRA=",data=writeback"
FSTAB_OPTS="defaults,noatime,nodiratime,commit=60,barrier=0${FSTAB_EXTRA}"

# 把根行第4列规范化为 FSTAB_OPTS，保留原有其它选项（seclabel 等），只剔除本脚本管理的键；$5/$6 复位为 1 1
fix_fstab_root(){
  [ -f /etc/fstab ] || return 1
  awk -v OPTS="$FSTAB_OPTS" 'BEGIN{OFS="\t"}
    $2=="/" && $3=="ext4" {
      n=split($4,a,","); keep=""
      for(i=1;i<=n;i++){
        o=a[i]
        if(o==""||o=="defaults"||o=="noatime"||o=="nodiratime") continue
        if(o ~ /^commit=/) continue
        if(o ~ /^barrier=/) continue
        if(o ~ /^data=/) continue
        keep=(keep==""?o:keep","o)
      }
      $4=OPTS (keep==""?"":","keep); $5="1"; $6="1"
    }
    {print}' /etc/fstab >/etc/fstab.ipesnew && mv /etc/fstab.ipesnew /etc/fstab
}

fstab_selfcheck(){
  step "0/9" "fstab 自检"
  local rootline opt4 broken=0
  rootline=$(awk '$2=="/"{print; exit}' /etc/fstab 2>/dev/null)
  [ -z "$rootline" ] && { warn "未找到根挂载行，跳过自检"; return 0; }
  opt4=$(echo "$rootline" | awk '{print $4}')
  # 坏法：commit=60/barrier=0 出现在行里、却没落在第4列（被写进 pass 字段）→ 重启后根分区可能只读
  if echo "$rootline" | grep -qE 'commit=60|barrier=0'; then
    echo "$opt4" | grep -q 'commit=60' || broken=1
  fi
  if [ "$broken" -eq 0 ]; then
    info "fstab 根行正常（第4列：$opt4）"
  else
    warn "检测到异常 fstab 根行，自动修复"
    warn "  before: $rootline"
    cp -a /etc/fstab "/etc/fstab.ipes-bak.$(date +%s)" 2>/dev/null
    if fix_fstab_root; then
      info "  after : $(awk '$2=="/"{print; exit}' /etc/fstab)"
    else
      err "  fstab 修复失败，请人工检查"
    fi
  fi
  # 根分区只读救援（旧脚本写坏 fstab 后重启进 ro 的现场）
  if mount 2>/dev/null | grep ' on / ' | grep -qE '\(ro[,)]'; then
    warn "根分区当前为只读，尝试 remount rw"
    if mount -o remount,rw / 2>/dev/null; then
      info "remount rw 成功"
      if ! systemctl is-active --quiet docker 2>/dev/null; then
        warn "docker 未运行，best-effort 拉起"
        systemctl restart containerd 2>/dev/null; systemctl start docker 2>/dev/null
        sleep 3
        systemctl is-active --quiet docker && info "docker 已拉起" || err "docker 拉起失败，请人工处理"
      fi
    else
      err "remount rw 失败（fstab 已修好，重启即可恢复）"
    fi
  fi
}

# =============================================================================
# [1] 内核 sysctl —— 单权威文件
# =============================================================================
SYSCTL_CONF=/etc/sysctl.d/99-ipes.conf

bbr_available(){
  modprobe tcp_bbr 2>/dev/null
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

sys_tune(){
  step "1/9" "内核 sysctl（单权威文件）"
  # 按内存动态算 TCP/UDP 内存上限（page=4KB ⇒ 每 MB = 256 pages）；上限等效 16G
  local _mb _pg _t1 _t2 _t3
  _mb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  _pg=$(( _mb * 256 ))
  _t1=$(( _pg*15/100 )); _t2=$(( _pg*30/100 )); _t3=$(( _pg*60/100 ))
  [ "$_t3" -gt 4194304 ] && { _t3=4194304; _t2=$(( _t3*50/100 )); _t1=$(( _t3*25/100 )); }
  [ "$_t1" -lt 4096 ] && _t1=4096
  local CC="cubic"
  if bbr_available; then CC="bbr"; else warn "本机内核无 tcp_bbr（SWAS 镜像常见），拥塞控制回落 cubic"; fi

  [ -f "$SYSCTL_CONF" ] && [ ! -f "${SYSCTL_CONF}.ipes-bak" ] && cp -p "$SYSCTL_CONF" "${SYSCTL_CONF}.ipes-bak" 2>/dev/null

  cat > "$SYSCTL_CONF" <<EOF
# OWNER: ipes_tune (tune-only v${TUNE_ONLY_VERSION}) —— 内核调优【唯一权威文件】
#   ★其它脚本（preheat / align_uplink 等）必须先 grep 这一行判断归属；
#     凡本文件已定义的键一律不得再写，避免后跑者把值打回旧值。
# ===== IPES PCDN 调优（小内存机型上行强化）=====
# --- TCP/UDP 缓冲：高并发 + 高 BDP，缓冲要够大才跑得满 ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mem = ${_t1} ${_t2} ${_t3}
net.ipv4.udp_mem = ${_t1} ${_t2} ${_t3}
net.ipv4.udp_rmem_min = 32768
net.ipv4.udp_wmem_min = 32768
# 高 BDP 链路单流发送上限（默认 256K 会压住上行）
net.ipv4.tcp_limit_output_bytes = 1048576
# 上行小包立即发出，降延迟
net.ipv4.tcp_autocorking = 0
# --- 队列 / 软中断预算 ---
net.core.default_qdisc = fq
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 100000
net.core.netdev_budget = 3000
net.core.netdev_budget_usecs = 4000
net.core.rps_sock_flow_entries = 32768
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.ip_local_port_range = 1024 65535
# --- TCP 行为 ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_congestion_control = ${CC}
# --- conntrack（PCDN 海量短连接）---
#   注意：不使用 iptables raw NOTRACK —— 与 firewalld 共存会丢回包，导致 SSH/云助手断连
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
# --- 文件系统 / 内存 ---
fs.file-max = 4000000
fs.aio-max-nr = 1048576
fs.inotify.max_user_watches = 524288
vm.swappiness = 0
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
vm.vfs_cache_pressure = 10
vm.min_free_kbytes = 65536
vm.overcommit_memory = 1
kernel.pid_max = 4194304
EOF

  modprobe nf_conntrack 2>/dev/null
  sysctl -e -p "$SYSCTL_CONF" >/dev/null 2>&1
  info "已写入并应用 ${SYSCTL_CONF}（CC=${CC}，tcp/udp_mem=${_t1}/${_t2}/${_t3}）"
}

# =============================================================================
# [2] sysctl 冲突让位 —— /etc/sysctl.conf 是"最后写入者"，靠文件名压不过它
# =============================================================================
deconflict_sysctl_files(){
  step "2/9" "sysctl 冲突让位"
  local mine=$SYSCTL_CONF
  [ -f "$mine" ] || { warn "缺 $mine，跳过"; return 0; }
  local kvf=/tmp/ipes_mine_kv.$$
  : >"$kvf"
  awk -F= '/^[ \t]*[A-Za-z0-9._-]+[ \t]*=/{
      k=$1; gsub(/^[ \t]+|[ \t]+$/,"",k);
      v=substr($0,index($0,"=")+1); gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/[ \t]+/," ",v);
      print k "\t" v }' "$mine" >"$kvf" 2>/dev/null
  local total; total=$(wc -l <"$kvf" 2>/dev/null | tr -d ' ')
  info "本文件声明 $total 个键，开始比对其它 sysctl 文件"
  local files="/etc/sysctl.conf" f
  while IFS= read -r f; do files="$files $f"; done < <(find /etc/sysctl.d -maxdepth 1 -name '*.conf' -type f 2>/dev/null | sort)
  local cf=0 ck=0 n
  for f in $files; do
    [ -f "$f" ] || continue
    [ "$f" = "$mine" ] && continue
    awk -v MAP="$kvf" -v TAG="# [ipes-tune 接管] " '
      BEGIN{ while((getline l < MAP) > 0){ i=index(l,"\t"); if(i>0){ m[substr(l,1,i-1)]=substr(l,i+1) } } }
      { t=$0; sub(/^[ \t]+/,"",t)
        if (t!="" && t !~ /^#/ && t ~ /^[A-Za-z0-9._-]+[ \t]*=/) {
          k=t; sub(/[ \t]*=.*/,"",k)
          v=t; sub(/^[A-Za-z0-9._-]+[ \t]*=/,"",v)
          gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/[ \t]+/," ",v)
          if ((k in m) && v != m[k]) { print TAG $0; next } }
        print }' "$f" >/tmp/ipes_deconf.$$ 2>/dev/null
    if ! cmp -s /tmp/ipes_deconf.$$ "$f" 2>/dev/null; then
      [ -f "$f.ipes-bak" ] || cp -p "$f" "$f.ipes-bak" 2>/dev/null
      cat /tmp/ipes_deconf.$$ >"$f" 2>/dev/null
      n=$(grep -c '^# \[ipes-tune 接管\]' "$f" 2>/dev/null || echo 0)
      info "已让位: $f （注释 $n 行，原文件备份 $f.ipes-bak）"
      cf=$((cf+1)); ck=$((ck+n))
    fi
  done
  rm -f /tmp/ipes_deconf.$$ "$kvf" 2>/dev/null
  if [ "$cf" -eq 0 ]; then info "无冲突键需要让位（其它文件均不与本文件冲突）"
  else info "共处理 $cf 个文件 / $ck 个键：今后 sysctl --system 不会再打回"; fi
  sysctl -e -p "$mine" >/dev/null 2>&1
}

# =============================================================================
# [3] 网卡 + [4] CPU governor / THP
# =============================================================================
net_tune(){
  step "3/9" "网卡 RPS / fq / ring / txqueuelen"
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

gov_tune(){
  step "4/9" "CPU governor=performance + THP=never"
  local n=0 g t
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -e "$g" ] || continue
    echo performance >"$g" 2>/dev/null && n=$((n+1))
  done
  for t in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
    [ -e "$t" ] && echo never >"$t" 2>/dev/null
  done
  if [ "$n" -gt 0 ]; then
    info "governor=performance（$n 个核，热写 /sys，不重启进程）；THP=never"
  else
    info "本机无 cpufreq（虚拟化机型常见），governor 无从设置，跳过；THP=never"
  fi
  if [ "$NO_SERVICE" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
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
# [5] 文件句柄上限（默认不重启 docker）
# =============================================================================
# ★CentOS7 的 systemd 219 不支持 `systemctl show --value`（返回空）★
#   空值会让"生效值≠配置值"永远成立 ⇒ 旧部署脚本每次都会白重启一遍 docker 打断容器。
#   双保险：systemctl 取值失败则回读 dockerd 进程 /proc/<pid>/limits。
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
  step "5/9" "nofile 上限（容器需 dockerd 继承）"
  local nr_open LIM cur p
  nr_open=$(cat /proc/sys/fs/nr_open 2>/dev/null || echo 1048576)
  LIM=$(( nr_open < 1048576 ? nr_open : 1048576 ))
  cur=$(get_dockerd_nofile)
  cat >/etc/security/limits.d/99-ipes.conf <<EOF
# OWNER: ipes_tune (tune-only v${TUNE_ONLY_VERSION})
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

  # 热提升已在跑的 dockerd/containerd（best-effort、零中断；此后新建的容器可继承到新上限）
  if command -v prlimit >/dev/null 2>&1; then
    for p in $(pgrep -x dockerd 2>/dev/null) $(pgrep -x containerd 2>/dev/null); do
      prlimit --pid "$p" --nofile="$LIM:$LIM" >/dev/null 2>&1 && info "  已对 pid=$p 热提升 nofile=$LIM（无需重启）"
    done
  fi

  if [ -z "$cur" ]; then
    warn "读不到 dockerd 生效值（docker 未运行或进程名不同）：配置已写好，待 docker 启动/重启后生效"
  elif [ "$cur" != "$LIM" ]; then
    if [ "$FORCE_DOCKER_RESTART" = "1" ]; then
      warn "重启 docker 让容器内的 nofile 立即生效（约数秒掉上行）"
      systemctl restart docker >/dev/null 2>&1
      sleep 5
      info "容器内 nofile 现为：$(docker exec ipes sh -c 'ulimit -n' 2>/dev/null || echo 'n/a（容器名非 ipes 或无权限）')"
    else
      warn "生效值($cur)≠配置值($LIM)：已保持【不重启】零掉量；要立即生效重跑加 --restart-docker，或等下次 docker/机器重启自动生效"
    fi
  else
    info "dockerd 生效值已一致（$cur），无需重启"
  fi
}

# =============================================================================
# [6] 磁盘队列 + 挂载参数
# =============================================================================
disk_tune(){
  step "6/9" "磁盘队列 + 挂载参数"
  local d b hw want v
  for d in /sys/block/vd* /sys/block/sd* /sys/block/xvd* /sys/block/nvme*; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    echo none >"$d/queue/scheduler"   2>/dev/null   # 虚拟化层已有队列，双层排队只增延迟
    echo 0    >"$d/queue/rotational"  2>/dev/null   # 云盘按 SSD 处理
    echo 0    >"$d/queue/add_random"  2>/dev/null   # 云盘无需贡献熵
    echo 0    >"$d/queue/nomerges"    2>/dev/null   # 允许全部合并：拉缓存是大块顺序写
    echo 2    >"$d/queue/rq_affinity" 2>/dev/null
    echo 256  >"$d/queue/read_ahead_kb" 2>/dev/null # ★实测：并发读随预读增大单调下降，保持 256K
    hw=$(cat "$d/queue/max_hw_sectors_kb" 2>/dev/null); want=1024
    if [ -n "$hw" ] && [ "$hw" -lt "$want" ] 2>/dev/null; then want=$hw; fi
    echo "$want" >"$d/queue/max_sectors_kb" 2>/dev/null
    for v in 8192 4096 1024; do                      # CentOS7+virtio-blk 下常被内核拒绝，容忍失败
      echo "$v" >"$d/queue/nr_requests" 2>/dev/null
      [ "$(cat "$d/queue/nr_requests" 2>/dev/null)" = "$v" ] && break
    done
    info "[$b] sched=$(cat "$d/queue/scheduler" 2>/dev/null|tr -d '\n') ra=$(cat "$d/queue/read_ahead_kb" 2>/dev/null)K nr=$(cat "$d/queue/nr_requests" 2>/dev/null) max_sec=$(cat "$d/queue/max_sectors_kb" 2>/dev/null)K rota=$(cat "$d/queue/rotational" 2>/dev/null)"
  done

  local fstype cur
  fstype=$(findmnt -no FSTYPE / 2>/dev/null)
  if [ "$fstype" = "ext4" ]; then
    cur=$(findmnt -no OPTIONS / 2>/dev/null)
    if echo "$cur" | grep -q 'commit=60'; then
      info "挂载选项已含 commit=60"
    elif mount -o "remount,noatime,nodiratime,commit=60,barrier=0${FSTAB_EXTRA}" / 2>/dev/null; then
      info "在线 remount 成功：$(findmnt -no OPTIONS / 2>/dev/null | cut -c1-80)"
    else
      warn "在线 remount 未生效（非致命，重启后由 fstab 承载）"
    fi
    if grep -q 'commit=60' /etc/fstab 2>/dev/null; then
      info "/etc/fstab 已含 commit=60，跳过改写"
    else
      cp -a /etc/fstab "/etc/fstab.ipes-bak.$(date +%s)" 2>/dev/null
      fix_fstab_root && info "/etc/fstab 根行已更新：$(awk '$2=="/"{print $4; exit}' /etc/fstab)"
    fi
  elif [ "$fstype" = "xfs" ]; then
    mount -o remount,logbsize=256k / 2>/dev/null && info "xfs remount logbsize=256k 完成"
  else
    warn "根分区 fstype=$fstype，跳过挂载参数调整"
  fi
}

# =============================================================================
# [7] 上行优先脏页方案
# =============================================================================
uplink_lock(){
  step "7/9" "上行优先脏页方案(20/10)"
  cat >/etc/sysctl.d/99z-ipes-uplink.conf <<'EOF'
# OWNER: ipes_tune (tune-only) —— 字典序最后(99z)，用于压过 99-pcdn-disk.conf 的 30/50
vm.dirty_background_ratio = 10
vm.dirty_ratio = 20
vm.vfs_cache_pressure = 10
EOF
  sysctl -e -p /etc/sysctl.d/99z-ipes-uplink.conf >/dev/null 2>&1
  info "99z-ipes-uplink.conf 已锁定 20/10（覆盖 99-pcdn-disk.conf 的 30/50）"
}

# =============================================================================
# [8] 自安装：/usr/local/bin/ipes-tune.sh + ipes-tune.service（开机重放）
# =============================================================================
SELF_DEST=/usr/local/bin/ipes-tune.sh
install_self(){
  step "8/9" "开机重放（ipes-tune.service）"
  [ "$NO_SERVICE" -eq 1 ] && { warn "已按 --no-service 跳过"; return 0; }
  command -v systemctl >/dev/null 2>&1 || { warn "无 systemd，跳过"; return 0; }
  # 取同版本副本：优先本机已装文件 → 当前运行文件 → 远端下载（带指纹校验，防 CDN 旧版）
  local src="" u
  if [ -f "$SELF_DEST" ] && grep -q "TUNE_ONLY_REV=\"$TUNE_ONLY_REV\"" "$SELF_DEST" 2>/dev/null; then
    src="$SELF_DEST"
  elif [ -f "${BASH_SOURCE[0]}" ] && grep -q "TUNE_ONLY_REV=\"$TUNE_ONLY_REV\"" "${BASH_SOURCE[0]}" 2>/dev/null; then
    src="${BASH_SOURCE[0]}"
  else
    for u in $SELF_URLS; do
      curl -fsSL -m 30 "$u" -o /tmp/ipes_tune_only_dl.sh 2>/dev/null || continue
      if grep -q "TUNE_ONLY_REV=\"$TUNE_ONLY_REV\"" /tmp/ipes_tune_only_dl.sh 2>/dev/null; then
        src=/tmp/ipes_tune_only_dl.sh; break
      fi
    done
  fi
  if [ -z "$src" ]; then
    warn "未能取得同版本副本（网络/CDN 缓存），跳过开机重放安装：本次调优已生效，仅重启会丢"
    return 0
  fi
  [ "$src" != "$SELF_DEST" ] && install -m 0755 "$src" "$SELF_DEST"
  cat >/etc/systemd/system/ipes-tune.service <<EOF
[Unit]
Description=IPES PCDN tune replay (tune-only v${TUNE_ONLY_VERSION})
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SELF_DEST} --replay
TimeoutStartSec=300
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable ipes-tune.service >/dev/null 2>&1
  info "已安装 ${SELF_DEST} + ipes-tune.service（enabled=$(systemctl is-enabled ipes-tune.service 2>/dev/null)）"
}

# =============================================================================
# [9] 断言自愈 + 验收 + 只读体检
# =============================================================================
KV=(
  "vm.dirty_ratio=20" "vm.dirty_background_ratio=10" "vm.vfs_cache_pressure=10"
  "net.core.netdev_budget=3000" "net.ipv4.udp_rmem_min=32768" "net.core.rmem_default=16777216"
  "net.ipv4.tcp_limit_output_bytes=1048576" "net.ipv4.tcp_max_syn_backlog=65535"
  "net.ipv4.tcp_max_tw_buckets=1048576" "net.ipv4.tcp_autocorking=0"
  "net.core.default_qdisc=fq" "net.ipv4.tcp_fastopen=3"
)

guard(){
  step "9/9" "关键键断言"
  local bad=0 k want got kv
  for kv in "${KV[@]}"; do
    k=${kv%%=*}; want=${kv#*=}; got=$(sysctl -n "$k" 2>/dev/null)
    [ "$got" = "$want" ] || bad=$((bad+1))
  done
  if [ "$bad" -gt 0 ]; then
    warn "有 $bad 项不符：先重跑 sysctl 让位，再重放 99-ipes.conf + 99z-uplink"
    deconflict_sysctl_files >/dev/null 2>&1
    sysctl -e -p "$SYSCTL_CONF" >/dev/null 2>&1
    sysctl -e -p /etc/sysctl.d/99z-ipes-uplink.conf >/dev/null 2>&1
    bad=0
    for kv in "${KV[@]}"; do
      k=${kv%%=*}; want=${kv#*=}; got=$(sysctl -n "$k" 2>/dev/null)
      [ "$got" = "$want" ] || bad=$((bad+1))
    done
    [ "$bad" -eq 0 ] && info "重放后已全部达标" || err "重放后仍有 $bad 项不符（可能有其它脚本在覆盖，见 $LOG）"
  else
    info "全部 ${#KV[@]} 项关键键达标"
  fi
}

report(){
  echo ""
  echo "================= 验收（$(hostname 2>/dev/null) $(date '+%F %T')） ================="
  printf "%-44s %-14s %-14s %s\n" "项目" "实际" "期望" "结果"
  printf "%-44s %-14s %-14s %s\n" "--------------------------------------------" "--------------" "--------------" "----"
  local kv k want got mark sch ra gov govmark thp cur mnt en cstat hh inc LIM nr_open
  nr_open=$(cat /proc/sys/fs/nr_open 2>/dev/null || echo 1048576)
  LIM=$(( nr_open < 1048576 ? nr_open : 1048576 ))
  for kv in "${KV[@]}"; do
    k=${kv%%=*}; want=${kv#*=}; got=$(sysctl -n "$k" 2>/dev/null)
    mark="OK"; [ "$got" = "$want" ] || mark="FAIL"
    printf "%-44s %-14s %-14s %s\n" "$k" "${got:-N/A}" "$want" "$mark"
  done
  sch=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/block/vda/queue/scheduler 2>/dev/null | awk '{print $1}')
  [ -z "$sch" ] && sch=$(cat /sys/block/vda/queue/scheduler 2>/dev/null | tr -d '\n')
  ra=$(cat /sys/block/vda/queue/read_ahead_kb 2>/dev/null)
  if [ -e /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    govmark="$([ "$gov" = performance ] && echo OK || echo FAIL)"
  else
    gov="无 cpufreq"; govmark="n/a"
  fi
  thp=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
  cur=$(get_dockerd_nofile)
  mnt=$(findmnt -no OPTIONS / 2>/dev/null)
  en=$(systemctl is-enabled ipes-tune.service 2>/dev/null || echo n/a)
  printf "%-44s %-14s %-14s %s\n" "vda scheduler（[] 内为当前）" "${sch:-N/A}" "none" "$([ "$sch" = none ] && echo OK || echo FAIL)"
  printf "%-44s %-14s %-14s %s\n" "vda read_ahead_kb" "${ra:-N/A}" "256" "$([ "$ra" = 256 ] && echo OK || echo FAIL)"
  printf "%-44s %-14s %-14s %s\n" "cpu governor" "$gov" "performance" "$govmark"
  printf "%-44s %-14s %-14s %s\n" "transparent_hugepage" "${thp:-n/a}" "never" "$([ "$thp" = never ] && echo OK || echo FAIL)"
  printf "%-44s %-14s %-14s %s\n" "dockerd LimitNOFILE" "${cur:-N/A}" "$LIM" "$([ "$cur" = "$LIM" ] && echo OK || echo '等下次重启')"
  printf "%-44s %-14s %-14s %s\n" "root 挂载选项含 commit=60" "$(echo "$mnt" | grep -q commit=60 && echo yes || echo no)" "yes" "$(echo "$mnt" | grep -q commit=60 && echo OK || echo '等下次重启')"
  printf "%-44s %-14s %-14s %s\n" "ipes-tune.service" "$en" "enabled" "$([ "$en" = enabled ] && echo OK || echo FAIL)"
  echo ""
  echo "---- IPES 只读体检（不改动任何服务）----"
  cstat=$(docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null | grep -i 'ipes' | head -3 | tr '|' ' ')
  if [ -n "$cstat" ]; then echo "容器：$cstat"; else echo "容器：未发现 ipes 容器（本机若非 IPES 节点属正常）"; fi
  hh=$(ps -ef 2>/dev/null | grep -c '[h]app')
  echo "宿主 happy 进程数：${hh}（12 = 满配正常）"
  inc=$(docker exec ipes sh -c "ps -ef | grep -c '[h]app'" 2>/dev/null)
  [ -n "$inc" ] && echo "容器内 happy 进程数：${inc}"
  echo "======================================================================"
}

# ----------------------------- 主流程 -----------------------------
fstab_selfcheck
sys_tune
deconflict_sysctl_files
net_tune
gov_tune
fd_limits
disk_tune
uplink_lock
install_self
guard
if [ "$REPLAY" -eq 0 ]; then
  report
  echo ""
  echo "日志：${LOG}"
  echo "回滚参考："
  echo "  /etc/sysctl.d/99-ipes.conf.ipes-bak   内核调优原文件"
  echo "  /etc/sysctl.conf.ipes-bak             sysctl 让位前原文件"
  echo "  /etc/fstab.ipes-bak.*                 挂载参数原文件"
  echo "  systemctl disable --now ipes-tune.service ipes-gov-tuned.service   关闭开机重放"
else
  info "开机重放完成（--replay）"
fi
exit 0

#!/bin/bash
# =============================================================================
# IPES PCDN 磁盘吞吐 + 上下行 强化调优  v21
# =============================================================================
# 目标（对应用户诉求：磁盘吞吐要快、要大，跑 PCDN 时上下行要高）：
#   1) 拉缓存写盘更快  —— 大块顺序写路径：合并全开 + 更大队列 + 更大单 IO + 更少日志提交
#   2) 上行读缓存更快  —— 顺序读路径：预读按黄金机实测标定【保持 256K】（见下方实证，勿盲目调大）
#   3) 高并发上下行    —— 连接数上限 4096→1048576、UDP 缓冲、队列、RPS、ring、txqueuelen
#   4) 丢包下吞吐      —— BBR 拥塞控制（CentOS7 3.10 有 tcp_bbr 模块，需显式 modprobe）
#
# 特性：
#   - 幂等：可反复执行，重复跑不会写坏配置
#   - 持久化：装成 ipes-tune.service，开机自动重放（重启不回退默认值）
#   - 在线安全：只做 remount / sysctl / 队列写入；★不主动重启 docker★
#     （需要让容器继承新 nofile 时才设 IPES_TUNE_RESTART_DOCKER=1）
#   - ext4 / xfs 自适应挂载参数
#
# 用法：
#   bash ipes_tune.sh                    # 应用 + 装自启
#   IPES_TUNE_RESTART_DOCKER=1 bash ipes_tune.sh   # 顺带重启 docker 让容器继承 nofile
# =============================================================================

set +e
LOG=/var/log/ipes_tune.log
touch "$LOG" 2>/dev/null
# 同时输出到控制台与日志
exec > >(tee -a "$LOG") 2>&1 || exec >>"$LOG" 2>&1

TUNE_VER="v2026-09-14-r21"
NCPU=$(nproc 2>/dev/null || echo 1)
echo ""
echo "=============================================================="
echo " IPES TUNE $TUNE_VER   $(date '+%F %T')   host=$(hostname)  ncpu=$NCPU"
echo "=============================================================="

# -----------------------------------------------------------------------------
# 1) 磁盘 I/O 队列 —— 吞吐优先（PCDN：大块顺序写缓存 + 顺序读缓存）
# -----------------------------------------------------------------------------
echo "--- [1/8] block queue (throughput-first) ---"
for d in /sys/block/vd* /sys/block/sd* /sys/block/xvd* /sys/block/nvme*; do
  [ -d "$d" ] || continue
  b=$(basename "$d")

  # 云盘/SSD：关掉内核 I/O 调度器排队（虚拟化层已有自己的队列，双层排队只增延迟）
  echo none > "$d/queue/scheduler" 2>/dev/null
  # 让内核按 SSD/云盘处理（去掉旋转盘假设）
  echo 0    > "$d/queue/rotational" 2>/dev/null
  # 云盘无需熵贡献
  echo 0    > "$d/queue/add_random" 2>/dev/null

  # 预读保持 256K（内核默认）—— ★实证结论，勿盲目调大★
  #   黄金机 3 轮取中位：ra=256 并发读 237MB/s / 1024→208 / 2048→191 / 4096→158（单调下降）
  #   单流读三档差异在噪声内（247/246/254）
  #   PCDN 是多个 happy 进程并发读缓存 → 属并发场景，故保持小预读
  #   （旧基线把 ra 设 2048/4096，对并发读是负优化，最高 -30%）
  echo 256 > "$d/queue/read_ahead_kb" 2>/dev/null

  # 队列深度：尝试加深；部分内核/virtio-blk 不允许写，读回确认，失败不报错
  #   实测 CentOS7 3.10 + virtio-blk：scheduler=none 时 nr_requests 固定 128，写入被拒
  for _v in 8192 4096 1024; do
    echo "$_v" > "$d/queue/nr_requests" 2>/dev/null
    [ "$(cat "$d/queue/nr_requests" 2>/dev/null)" = "$_v" ] && break
  done

  # ★关键3：nomerges 0 = 允许全部合并。拉缓存是大块顺序写，请求合并能大幅减少 IO 次数
  #          （旧基线设 2 全关合并，对顺序写是负优化）
  echo 0    > "$d/queue/nomerges" 2>/dev/null

  # ★关键4：单次请求上限 512K → 1024K（受 max_hw_sectors_kb 限制，取小值）
  hw=$(cat "$d/queue/max_hw_sectors_kb" 2>/dev/null)
  want=1024
  if [ -n "$hw" ] && [ "$hw" -lt "$want" ] 2>/dev/null; then want=$hw; fi
  echo "$want" > "$d/queue/max_sectors_kb" 2>/dev/null

  # 完成中断回到提交核，减少跨核 cache 反弹
  echo 2 > "$d/queue/rq_affinity" 2>/dev/null

  echo "  [$b] sched=$(tr -d '\n' < "$d/queue/scheduler" 2>/dev/null) ra=$(cat "$d/queue/read_ahead_kb" 2>/dev/null)K nr=$(cat "$d/queue/nr_requests" 2>/dev/null) nomerges=$(cat "$d/queue/nomerges" 2>/dev/null) max_sec=$(cat "$d/queue/max_sectors_kb" 2>/dev/null)K rota=$(cat "$d/queue/rotational" 2>/dev/null)"
done

# -----------------------------------------------------------------------------
# 2) 文件系统挂载参数 —— 减少元数据/日志开销（PCDN 缓存可丢，换吞吐很划算）
#    ext4: commit=60（日志提交 5s→60s）+ barrier=0（云盘块存储已有保护）
#    xfs : logbsize=256k
# -----------------------------------------------------------------------------
echo "--- [2/8] filesystem mount opts ---"
FSTYPE=$(findmnt -no FSTYPE / 2>/dev/null)
CUR_OPTS=$(findmnt -no OPTIONS / 2>/dev/null)
echo "  root fstype=$FSTYPE opts=$CUR_OPTS"

if [ "$FSTYPE" = "ext4" ]; then
  ADD_OPTS="commit=60,barrier=0"
elif [ "$FSTYPE" = "xfs" ]; then
  ADD_OPTS="logbsize=256k"
else
  ADD_OPTS=""
fi

if [ -n "$ADD_OPTS" ]; then
  # 2.1 幂等写入 /etc/fstab（带标记，改一次就够；改前备份）
  if [ -f /etc/fstab ] && ! grep -q "ipes-tuned" /etc/fstab 2>/dev/null; then
    cp -a /etc/fstab "/etc/fstab.ipes.bak.$(date +%s)"
    awk -v add="$ADD_OPTS" 'BEGIN{OFS="\t"} {
      if ($2=="/" && $4 !~ /ipes-tuned/ && index($4,"commit=")==0 && index($4,"logbsize=")==0) {
        $4=$4","add; $0=$0" # ipes-tuned"
      }
      print
    }' /etc/fstab > /etc/fstab.new 2>/dev/null && mv /etc/fstab.new /etc/fstab
    echo "  [fstab] patched: +$ADD_OPTS (backup kept)"
  else
    echo "  [fstab] already patched, skip"
  fi

  # 2.2 立即生效（在线 remount；失败也不影响运行，下次重启由 fstab 承载）
  case "$CUR_OPTS" in
    *commit=*|*logbsize=*)
      echo "  [remount] already active, skip" ;;
    *)
      if mount -o "remount,$ADD_OPTS" / 2>/dev/null; then
        echo "  [remount] OK -> $(findmnt -no OPTIONS / 2>/dev/null)"
      else
        echo "  [remount] FAILED(非致命，重启后由 fstab 生效): $(findmnt -no OPTIONS / 2>/dev/null)"
      fi ;;
  esac
fi

# -----------------------------------------------------------------------------
# 3) 内核 sysctl —— 单权威文件（避免多文件互相覆盖导致重启后值漂移）
# -----------------------------------------------------------------------------
echo "--- [3/8] sysctl (single authoritative file) ---"
cat > /etc/sysctl.d/99-ipes.conf <<'EOF'
# OWNER: ipes_tune (r21) —— 内核调优【唯一权威文件】
#   ★其它脚本（ipes_preheat_and_health.sh / ipes_align_uplink.sh）必须只做补充：
#     先 grep 这一行判断归属，凡本文件已定义的键一律不得再写，避免后跑者把值打回旧值。
# ===== IPES PCDN 调优 v21（唯一权威文件，勿再放 98-*/99-*-perf.conf 以免冲突）=====
# --- TCP/UDP 缓冲：高并发 + 高 BDP 链路，缓冲要够大才跑得满 ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_notsent_lowat = 16384
# UDP（PCDN 上行大量小包）：加大全局与单 socket 下限
net.ipv4.udp_mem = 65536 98304 131072
net.ipv4.udp_rmem_min = 32768
net.ipv4.udp_wmem_min = 32768
net.core.optmem_max = 4194304
# --- 连接队列 / 软中断预算 ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 100000
net.core.netdev_budget = 3000
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
# 高 BDP 链路单流发送上限（默认 256K 会压住长肥管道的上行）
net.ipv4.tcp_limit_output_bytes = 1048576
# 关闭 autocork，上行小包立即发出，降延迟
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_congestion_control = cubic
# --- 端口/路由/邻居表 ---
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.route.max_size = 2097152
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 16384
net.ipv4.neigh.default.gc_thresh3 = 65536
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
# --- conntrack（配合 raw NOTRACK，只兜底）---
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 300
net.netfilter.nf_conntrack_udp_timeout_stream = 600
net.netfilter.nf_conntrack_generic_timeout = 600
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 60
# --- qdisc：fq 配合 BBR（pacing）---
net.core.default_qdisc = fq
# --- 文件/进程句柄 ---
fs.file-max = 4000000
fs.aio-max-nr = 1048576
fs.inotify.max_user_watches = 1048576
kernel.pid_max = 4194304
# --- 内存/脏页：★针对 1G 小内存重调★ ---
# 旧基线 dirty 40/30 → 单次回写洪峰可达 370M，读请求被长时间阻塞（PCDN 上行卡顿）
# 20/10 让回写更平滑，牺牲一点突发写吞吐换稳定的读延迟
vm.swappiness = 0
vm.overcommit_memory = 1
vm.vfs_cache_pressure = 10
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 50
vm.zone_reclaim_mode = 0
vm.min_free_kbytes = 65536
EOF
# ★根治「两套调优打架」★
#   只删【文件名排序 ≥ 99-ipes.conf】且携带旧值的遗留文件 —— 它们在开机 sysctl 扫描时
#   会排在本文件之后，从而把 r21 的新值再打回旧值。
#   · 99-ipes-perf.conf    : r21 早期版本遗留
#   · 99-ipes-fallback.conf: 旧版 align 的兜底文件（dirty 40/30、udp_rmem_min 16384），
#                            新版 align 已改名 50-ipes-fallback.conf 并去掉重叠键
#   98-ipes-nat.conf 保留：修复后它只含 r21 未管理的键，且 98 < 99，开机时会被本文件覆盖。
rm -f /etc/sysctl.d/99-ipes-perf.conf /etc/sysctl.d/99-ipes-fallback.conf 2>/dev/null
modprobe nf_conntrack 2>/dev/null
sysctl -e -p /etc/sysctl.d/99-ipes.conf 2>&1 | grep -vE "^\s*$" | tail -5

# -----------------------------------------------------------------------------
# 4) 拥塞控制 BBR（CentOS7 3.10 有 tcp_bbr 模块，需显式加载并持久化）
# -----------------------------------------------------------------------------
echo "--- [4/8] congestion control ---"
if modprobe tcp_bbr 2>/dev/null && sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
  echo tcp_bbr > /etc/modules-load.d/ipes-bbr.conf 2>/dev/null
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
  echo "  [cc] BBR enabled ($(sysctl -n net.ipv4.tcp_congestion_control))"
else
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
  echo "  [cc] tcp_bbr unavailable -> fallback $(sysctl -n net.ipv4.tcp_congestion_control)"
fi

# -----------------------------------------------------------------------------
# 5) 连接数上限 nofile —— ★高并发上下行的硬门槛（实测默认仅 4096）★
# -----------------------------------------------------------------------------
echo "--- [5/8] nofile limits ---"
NR_OPEN=$(cat /proc/sys/fs/nr_open 2>/dev/null)
[ -z "$NR_OPEN" ] && NR_OPEN=1048576
LIM=1048576
# 不能超过 fs.nr_open，否则 sshd 等新进程会启动失败（经典锁死坑）
if [ "$NR_OPEN" -lt "$LIM" ] 2>/dev/null; then LIM=$NR_OPEN; fi
cat > /etc/security/limits.d/99-ipes.conf <<EOF
# IPES PCDN: 高并发连接
*     soft nofile $LIM
*     hard nofile $LIM
root  soft nofile $LIM
root  hard nofile $LIM
EOF
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/limits.conf <<EOF
# IPES PCDN: 让容器内的 IPES 进程继承大 nofile（否则容器里仍是 4096）
[Service]
LimitNOFILE=$LIM
LimitNPROC=$LIM
EOF
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-ipes-limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=$LIM
EOF
mkdir -p /etc/security/limits.d
echo "  [nofile] soft/hard -> $LIM (fs.nr_open=$NR_OPEN)"
if [ "${IPES_TUNE_RESTART_DOCKER:-0}" = "1" ]; then
  echo "  [nofile] IPES_TUNE_RESTART_DOCKER=1 -> restart docker to apply inside container"
  systemctl daemon-reload 2>/dev/null
  systemctl restart docker 2>/dev/null
  sleep 3
  echo "  [nofile] docker restarted, container nofile now: $(docker exec ipes sh -c 'ulimit -n' 2>/dev/null || echo n/a)"
else
  echo "  [nofile] 未重启 docker（避免打断跑量）。容器内生效需：IPES_TUNE_RESTART_DOCKER=1 bash ipes_tune.sh 或重启机器"
fi

# -----------------------------------------------------------------------------
# 6) 网卡：ring 拉满 + txqueuelen + fq + RPS/RFS（单队列 virtio 必做）
# -----------------------------------------------------------------------------
echo "--- [6/8] nic ---"
MASK=$(printf '%x' $(( (1 << NCPU) - 1 )))
for dev in $(ls /sys/class/net 2>/dev/null); do
  case "$dev" in
    lo|docker*|veth*|br-*|virbr*|cni*|flannel*) continue ;;
  esac
  # ring buffer 拉满：高 PPS 小包不丢
  ethtool -G "$dev" rx 4096 tx 4096 2>/dev/null
  # 发送队列加深：高发送速率不丢包
  ip link set "$dev" txqueuelen 10000 2>/dev/null
  # fq 队列（BBR pacing 需要）
  tc qdisc replace dev "$dev" root fq 2>/dev/null
  # RPS：单队列网卡把收包软中断摊到所有核
  for q in /sys/class/net/$dev/queues/rx-*; do
    [ -d "$q" ] || continue
    echo "$MASK" > "$q/rps_cpus" 2>/dev/null
    echo 4096   > "$q/rps_flow_cnt" 2>/dev/null
  done
  echo "  [$dev] txqueuelen=$(cat /sys/class/net/$dev/tx_queue_len 2>/dev/null) rps=$(cat /sys/class/net/$dev/queues/rx-0/rps_cpus 2>/dev/null) qdisc=$(tc qdisc show dev $dev 2>/dev/null | head -1 | awk '{print $2}')"
done
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null

# -----------------------------------------------------------------------------
# 7) conntrack hashsize + raw NOTRACK（高并发下省 CPU）
# -----------------------------------------------------------------------------
echo "--- [7/8] conntrack ---"
if ! grep -q hashsize /etc/modprobe.d/ipes-conntrack.conf 2>/dev/null; then
  echo 'options nf_conntrack hashsize=32768' > /etc/modprobe.d/ipes-conntrack.conf
  echo "  [conntrack] hashsize=32768 written (下次加载模块生效)"
else
  echo "  [conntrack] hashsize already set"
fi
iptables -t raw -C PREROUTING -j NOTRACK 2>/dev/null || iptables -t raw -A PREROUTING -j NOTRACK 2>/dev/null
iptables -t raw -C OUTPUT     -j NOTRACK 2>/dev/null || iptables -t raw -A OUTPUT     -j NOTRACK 2>/dev/null
echo "  [conntrack] NOTRACK rules: $(iptables -t raw -S 2>/dev/null | grep -c NOTRACK)"

# -----------------------------------------------------------------------------
# 7.5) 空间回收 —— ext4 接近满盘会明显劣化写入（黄金机实测根分区 93% 满）
#      只做安全项：容器日志截断 + 悬挂镜像 + journal 轮转；★绝不删在用镜像/容器★
# -----------------------------------------------------------------------------
echo "--- [7.5/8] space reclaim (safe only) ---"
AVAIL_BEFORE=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
find /var/lib/docker/containers -name "*-json.log" -size +50M -exec truncate -s 0 {} \; 2>/dev/null
docker image prune -f >/dev/null 2>&1
journalctl --vacuum-size=100M >/dev/null 2>&1
AVAIL_AFTER=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
echo "  [/] avail ${AVAIL_BEFORE:-?}MB -> ${AVAIL_AFTER:-?}MB (used $(df -P / 2>/dev/null | awk 'NR==2{print $5}'))"

# -----------------------------------------------------------------------------
# 8) 持久化：装成 systemd 服务，开机重放（重启不回默认）
# -----------------------------------------------------------------------------
echo "--- [8/8] persist (systemd oneshot) ---"
SELF_SRC="$0"
SELF_DST="/usr/local/bin/ipes-tune.sh"
case "$SELF_SRC" in
  /usr/local/bin/ipes-tune.sh) : ;;
  *)
    if [ -f "$SELF_SRC" ] && [ -s "$SELF_SRC" ]; then
      cp -f "$SELF_SRC" "$SELF_DST" 2>/dev/null
    fi ;;
esac
# 兜底：若脚本是管道进来的（无文件），确保目标存在
if [ ! -s "$SELF_DST" ]; then
  echo "  [persist] WARN: 无法自拷贝($SELF_SRC)，开机重放可能缺失"
fi
chmod +x "$SELF_DST" 2>/dev/null
cat > /etc/systemd/system/ipes-tune.service <<'EOF'
[Unit]
Description=IPES PCDN disk/nic/sysctl tuning (replay on boot)
After=network.target local-fs.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=IPES_TUNE_RESTART_DOCKER=0
ExecStart=/usr/local/bin/ipes-tune.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload 2>/dev/null
systemctl enable ipes-tune.service >/dev/null 2>&1 && echo "  [persist] ipes-tune.service enabled"

# -----------------------------------------------------------------------------
# 7) ★护栏★ 关键键断言 + 自愈 —— 根治「其它脚本把新值打回旧值」
# -----------------------------------------------------------------------------
# 背景：ipes_preheat_and_health.sh（旧版）与本脚本曾写同一个 /etc/sysctl.d/99-ipes.conf，
#       谁后跑谁生效，导致 dirty 20/10、netdev_budget 3000、udp_rmem_min 32768、
#       rmem_default 16M、qdisc fq 等 7 项被打回旧值。
# 现在的约定（三处已同步改造）：
#       ① 本脚本写 99-ipes.conf 并打上 "OWNER: ipes_tune" 归属标记；
#       ② preheat 探测到该标记后改为【只补不覆盖】，写 50-ipes-preheat.conf（排序在前，开机必被本文件覆盖）；
#       ③ align 的 NAT/兜底文件剔除被本文件管理的重叠键。
# 本段是最后的「绊线」：任何脚本再把键改回去，这里都会立刻发现并重放自愈。
echo ""
echo "--- [guard] sysctl assert + self-heal ---"
sctl_guard(){
  local conf=/etc/sysctl.d/99-ipes.conf
  [ -f "$conf" ] || { echo "  [guard] 缺少 $conf，跳过"; return 0; }
  # 归属标记做兜底自补（老节点升级上来时可能没有这一行）
  grep -q 'OWNER: ipes_tune' "$conf" 2>/dev/null || \
    sed -i '1i # OWNER: ipes_tune (r21)' "$conf" 2>/dev/null || true
  # 这 10 项是历史上被覆盖过的重灾区
  local pairs="net.core.rmem_default=16777216
net.ipv4.udp_rmem_min=32768
net.core.netdev_budget=3000
net.core.default_qdisc=fq
vm.dirty_ratio=20
vm.dirty_background_ratio=10
net.core.somaxconn=65535
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.tcp_max_tw_buckets=1048576"
  local bad kv k want got
  _sctl_check(){
    bad=""
    while IFS= read -r kv; do
      [ -n "$kv" ] || continue
      k="${kv%%=*}"; want="${kv#*=}"
      got=$(sysctl -n "$k" 2>/dev/null)
      # BBR 不可用时回退 cubic 属正常，不算回退
      if [ "$k" = "net.ipv4.tcp_congestion_control" ] && [ "$got" != "bbr" ]; then
        sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr || continue
      fi
      [ "$got" = "$want" ] || bad="$bad $k(应=$want 实=${got:-N/A})"
    done <<< "$pairs"
  }
  _sctl_check
  if [ -n "$bad" ]; then
    echo "  [guard] ⚠ 关键键被回退:$bad"
    echo "  [guard] 自动自愈：重放 $conf"
    sysctl -e -p "$conf" >/dev/null 2>&1 || true
    _sctl_check
    if [ -n "$bad" ]; then
      echo "  [guard] ✗ 自愈后仍异常:$bad"
      echo "  [guard]   多为第三方脚本（预热/对齐/onekey）持续覆盖，请检查 /etc/sysctl.d/ 下 98-*/99-* 文件"
    else
      echo "  [guard] ✔ 自愈成功，关键键已恢复 r21 值"
    fi
  else
    echo "  [guard] ✔ 关键键全部为 r21 值"
  fi
  # 顺带清掉可能被重跑的旧脚本重建的、会压过本文件的遗留文件
  rm -f /etc/sysctl.d/99-ipes-perf.conf /etc/sysctl.d/99-ipes-fallback.conf 2>/dev/null || true
}
sctl_guard

# -----------------------------------------------------------------------------
# 汇总
# -----------------------------------------------------------------------------
echo ""
echo "----------------- EFFECTIVE NOW -----------------"
echo "  scheduler      : $(tr -d '\n' < /sys/block/vda/queue/scheduler 2>/dev/null)"
echo "  read_ahead_kb  : $(cat /sys/block/vda/queue/read_ahead_kb 2>/dev/null)"
echo "  nr_requests    : $(cat /sys/block/vda/queue/nr_requests 2>/dev/null)"
echo "  nomerges       : $(cat /sys/block/vda/queue/nomerges 2>/dev/null)"
echo "  max_sectors_kb : $(cat /sys/block/vda/queue/max_sectors_kb 2>/dev/null)"
echo "  rotational     : $(cat /sys/block/vda/queue/rotational 2>/dev/null)"
echo "  root mount     : $(findmnt -no OPTIONS / 2>/dev/null)"
echo "  cc / qdisc     : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / $(sysctl -n net.core.default_qdisc 2>/dev/null)"
echo "  tcp rmem_max   : $(sysctl -n net.core.rmem_max 2>/dev/null)"
echo "  udp_mem        : $(sysctl -n net.ipv4.udp_mem 2>/dev/null)"
echo "  dirty 20/10    : $(sysctl -n vm.dirty_ratio)/$(sysctl -n vm.dirty_background_ratio)"
echo "  ulimit -n      : $(ulimit -n)   (新登录 shell)"
echo "  limit conf     : $(grep -h nofile /etc/security/limits.d/99-ipes.conf 2>/dev/null | tail -1)"
echo "  txqueuelen     : $(cat /sys/class/net/$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')/tx_queue_len 2>/dev/null)"
echo "================================================="
echo " IPES TUNE $TUNE_VER DONE  $(date '+%F %T')"
echo "================================================="

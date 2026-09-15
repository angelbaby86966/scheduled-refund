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
# ★版本指纹★：inline_deploy_r21_oss.sh 会强制校验这一行（TUNE_REV_EXPECT 必须与之相等）。
#   原因：ghproxy.net 对上游 raw 有 CDN 缓存，?t= 只能绕过【它自己】那层，
#         部署脚本曾因此静默下发到旧版 tune（实测 28428B 旧版 vs 29404B 新版）。
#   ⇒ 每次改动 tune 必须同步抬高这个值，并让 push 脚本回写 inline 的 TUNE_REV_EXPECT。
TUNE_REV="20260915c"
NCPU=$(nproc 2>/dev/null || echo 1)
echo ""
echo "=============================================================="
echo " IPES TUNE $TUNE_VER   $(date '+%F %T')   host=$(hostname)  ncpu=$NCPU"
echo "=============================================================="

# -----------------------------------------------------------------------------
# ★根治「kernel 调优被别的 sysctl 文件覆盖」★
#   实测（procps-ng 3.3.10，CentOS 7.9）：
#     `sysctl --system` 的顺序是【先扫完 /run|/etc|/usr/lib 下所有 sysctl.d/*.conf，
#      最后才应用 /etc/sysctl.conf】，且 /etc/sysctl.d/99-sysctl.conf 只是 /etc/sysctl.conf
#      的软链 ⇒ 靠“文件名字典序”改名（如 99-zz-*.conf）【压不过它】，已实测证伪。
#   本机该文件里就带着旧值：tcp_max_tw_buckets=5000、tcp_max_syn_backlog=1024。
#   ⇒ 唯一稳妥的做法：让【与 r21 同名但值不同】的键在其它文件里就地让位（注释掉）。
#   原则：值相同的不动（最小侵入）；首次改动前备份 .ipes-bak；幂等，可反复执行。
# -----------------------------------------------------------------------------
deconflict_sysctl_files(){
  local mine=/etc/sysctl.d/99-ipes.conf
  [ -f "$mine" ] || { echo "  [deconf] 缺 ${mine}，跳过"; return 0; }
  # r21 自己声明的「键 <TAB> 值」映射（只取未注释的生效行）
  local kvf=/tmp/ipes_mine_kv.txt
  awk -F= '/^[ \t]*[A-Za-z0-9._-]+[ \t]*=/{
      k=$1; gsub(/^[ \t]+|[ \t]+$/,"",k);
      v=substr($0,index($0,"=")+1); gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/[ \t]+/," ",v);
      print k "\t" v
    }' "$mine" > "$kvf" 2>/dev/null
  local total; total=$(wc -l < "$kvf" 2>/dev/null | tr -d ' ')
  echo "  [deconf] r21 声明 $total 个键，开始比对其它 sysctl 文件…"
  # 候选：/etc/sysctl.conf + /etc/sysctl.d/*.conf
  #   注意用 find -type f 跳过软链（99-sysctl.conf → ../sysctl.conf），避免同一文件被处理两次
  local f files
  files="/etc/sysctl.conf"
  while IFS= read -r f; do files="$files $f"; done < \
    <(find /etc/sysctl.d -maxdepth 1 -name '*.conf' -type f 2>/dev/null | sort)
  local changed_files=0 changed_keys=0
  for f in $files; do
    [ -f "$f" ] || continue
    [ "$f" = "$mine" ] && continue
    awk -v MAP="$kvf" -v TAG="# [ipes-tune r21 接管] " '
      BEGIN{ while((getline l < MAP) > 0){ i=index(l,"\t"); if(i>0){ mine[substr(l,1,i-1)]=substr(l,i+1) } } }
      {
        t=$0; sub(/^[ \t]+/,"",t)
        if (t != "" && t !~ /^#/ && t ~ /^[A-Za-z0-9._-]+[ \t]*=/) {
          k=t; sub(/[ \t]*=.*/,"",k)
          v=t; sub(/^[A-Za-z0-9._-]+[ \t]*=/,"",v)
          gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/[ \t]+/," ",v)
          if ((k in mine) && v != mine[k]) { print TAG $0; next }
        }
        print
      }' "$f" > /tmp/ipes_deconf.out 2>/dev/null
    if ! cmp -s /tmp/ipes_deconf.out "$f" 2>/dev/null; then
      [ -f "$f.ipes-bak" ] || cp -p "$f" "$f.ipes-bak" 2>/dev/null
      # 用 cat 覆盖以保留 inode/权限（对软链目标也安全）
      cat /tmp/ipes_deconf.out > "$f" 2>/dev/null
      local n; n=$(grep -c '^# \[ipes-tune r21 接管\]' "$f" 2>/dev/null || echo 0)
      echo "  [deconf] ✔ 已让位: $f  (累计注释 $n 行，原文件备份为 $f.ipes-bak)"
      changed_files=$((changed_files+1)); changed_keys=$((changed_keys+n))
    fi
  done
  rm -f /tmp/ipes_deconf.out 2>/dev/null
  if [ "$changed_files" -eq 0 ]; then
    echo "  [deconf] ✔ 无冲突键需要让位（其它文件均不与 r21 冲突）"
  else
    echo "  [deconf] ✔ 共处理 $changed_files 个文件；这些键今后不会再被 sysctl --system 打回"
  fi
  # 让被注释掉的键在本次运行末立即回到 r21 值
  sysctl -e -p "$mine" >/dev/null 2>&1 || true
}

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
  ADD_OPTS="noatime,nodiratime,commit=60,barrier=0,data=writeback"
elif [ "$FSTYPE" = "xfs" ]; then
  ADD_OPTS="logbsize=256k"
else
  ADD_OPTS=""
fi

if [ -n "$ADD_OPTS" ]; then
  # 2.1 幂等写入 /etc/fstab（规范化 / 挂载选项；data=writeback 减少日志开销、拉缓存写盘更快）
  #     改前备份；已含 data=writeback 则跳过
  if [ -f /etc/fstab ] && ! grep -q "data=writeback" /etc/fstab 2>/dev/null; then
    cp -a /etc/fstab "/etc/fstab.ipes.bak.$(date +%s)"
    awk 'BEGIN{OFS="\t"} {
      if ($2=="/" && $3=="ext4") { $4="defaults,noatime,nodiratime,commit=60,barrier=0,data=writeback" }
      if ($2=="/" && $3=="xfs")  { $4="defaults,logbsize=256k" }
      print
    }' /etc/fstab > /etc/fstab.new 2>/dev/null && mv /etc/fstab.new /etc/fstab
    echo "  [fstab] patched: +$ADD_OPTS (backup kept)"
  else
    echo "  [fstab] already patched, skip"
  fi

  # 2.2 立即生效（在线 remount；失败也不影响运行，下次重启由 fstab 承载）
  case "$CUR_OPTS" in
    *data=writeback*)
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
net.ipv4.tcp_rmem = 4096 262144 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
# 200M 上行：关掉 notsent_lowat 上限，避免批量上行被节流（缓存回源/上行首窗更快填满管道）
net.ipv4.tcp_notsent_lowat = 0
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
# --- tcp_mem 按物理内存缩放（15% / 30% / 60%，封顶 16G pages）---
#   原先是硬编码 36134 72268 144537 —— 该值恰好等于 941MB 机型的 15/30/60%。
#   换到 2G/4G/8G 规格时它会明显偏小，把 TCP 总内存上限压住，高并发下行（拉缓存）可能提前触顶。
#   改为动态计算：1GB 机型结果与原值【逐字节一致】，更大规格自动放宽。
_mem_kb=$(grep -m1 MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
_mem_mb=$(( ${_mem_kb:-8388608} / 1024 ))
_ram_pages=$(( _mem_mb * 256 ))          # page=4KB ⇒ 每 MB = 256 pages
TP_LOW=$((   _ram_pages * 15 / 100 ))
TP_PRESS=$(( _ram_pages * 30 / 100 ))
TP_MAX=$((   _ram_pages * 60 / 100 ))
[ "$TP_MAX" -gt 4194304 ] && TP_MAX=4194304
sed -i "s|^net.ipv4.tcp_mem = .*|net.ipv4.tcp_mem = $TP_LOW $TP_PRESS $TP_MAX|" /etc/sysctl.d/99-ipes.conf 2>/dev/null
echo "  [tcp_mem] MemTotal=${_mem_mb}MB -> $TP_LOW $TP_PRESS $TP_MAX pages (15/30/60% 缩放)"

# ★根治「两套调优打架」★
#   只删【文件名排序 ≥ 99-ipes.conf】且携带旧值的遗留文件 —— 它们在开机 sysctl 扫描时
#   会排在本文件之后，从而把 r21 的新值再打回旧值。
#   · 99-ipes-perf.conf    : r21 早期版本遗留
#   · 99-ipes-fallback.conf: 旧版 align 的兜底文件（dirty 40/30、udp_rmem_min 16384），
#                            新版 align 已改名 50-ipes-fallback.conf 并去掉重叠键
#   98-ipes-nat.conf 保留：修复后它只含 r21 未管理的键；万一还残留旧值，下一步 deconflict 会兜住。
rm -f /etc/sysctl.d/99-ipes-perf.conf /etc/sysctl.d/99-ipes-fallback.conf 2>/dev/null

# 让 /etc/sysctl.conf（最后应用者）与其它 sysctl.d 文件里【值冲突】的键就地让位
echo "--- [3.5/8] de-conflict competing sysctl files ---"
deconflict_sysctl_files

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
# 6.5) 出口路由 initcwnd/initrwnd —— 加速「部署后拉缓存」与上行爬坡
#   CentOS7 3.10 内核默认 initcwnd=10；拉缓存（从源站下行填充）和上行首窗都受初始窗口限制，
#   调到 20 让新连接起步即多发送 ~2 倍数据：缓存填充更快、上行更快爬到 200M。
#   路由在重启后会重置 → 本脚本（ipes-tune.service 开机重放）带 30s 重试等待默认路由出现。
# -----------------------------------------------------------------------------
echo "--- [6.5/8] egress route initcwnd/initrwnd ---"
tune_egress_route(){
  local tries=30 gw dev
  while [ "$tries" -gt 0 ]; do
    gw=$(ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
    dev=$(ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$gw" ] && [ -n "$dev" ] && break
    sleep 1; tries=$((tries-1))
  done
  if [ -n "$gw" ] && [ -n "$dev" ]; then
    if ip route replace default via "$gw" dev "$dev" initcwnd 20 initrwnd 20 2>/dev/null; then
      echo "  [route] default via $gw dev $dev -> $(ip route show default 2>/dev/null | grep -o 'initcwnd [0-9]* initrwnd [0-9]*')"
    else
      echo "  [route] FAILED set initcwnd (非致命)"
    fi
  else
    echo "  [route] 未发现默认路由，跳过（开机由 ipes-tune.service 重试）"
  fi
}
tune_egress_route

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
# ★20260915 断网事故修复 v2★：CentOS 公共镜像 firewalld 默认 active，其回包放行依赖
# conntrack 状态（ctstate ESTABLISHED,RELATED）。NOTRACK 一上，出站连接的回包全部
# 无状态 → INPUT 丢弃 → 实例出站断（curl 卡死 / 阿里云 agent ClientNetworkBlocked）。
# 三重保险：①NOTRACK 前先关 firewalld；②"死人开关"——150s 内没确认出站正常就无条件回滚
#（脚本被杀/卡死/中途断线一律不例外）；③多径探活（TCP 直连 IP 免 DNS + 域名 HTTPS）。
systemctl stop firewalld 2>/dev/null; systemctl disable firewalld 2>/dev/null
NET_OK_FLAG=/run/ipes_net_ok.flag
rm -f "$NET_OK_FLAG"
if timeout 6 bash -c 'echo > /dev/tcp/223.5.5.5/443' 2>/dev/null; then
  echo "  [conntrack] baseline egress: OK"
else
  echo "  [conntrack] baseline egress: FAIL（加 NOTRACK 前就不通，非本次调优所致）"
fi
setsid bash -c 'for i in $(seq 1 30); do sleep 5; [ -f /run/ipes_net_ok.flag ] && exit 0; done; iptables -t raw -F 2>/dev/null; echo "[DEADMAN] 150s 未确认出站，已自动回滚 NOTRACK" >> /var/log/ipes_net_guard.log 2>/dev/null' >/dev/null 2>&1 &
iptables -t raw -C PREROUTING -j NOTRACK 2>/dev/null || iptables -t raw -A PREROUTING -j NOTRACK 2>/dev/null
iptables -t raw -C OUTPUT     -j NOTRACK 2>/dev/null || iptables -t raw -A OUTPUT     -j NOTRACK 2>/dev/null
sleep 8
egress_ok=0
if timeout 6 bash -c 'echo > /dev/tcp/223.5.5.5/443' 2>/dev/null; then egress_ok=1
elif curl -fsSL -m 8 -o /dev/null https://admin.zhouyi.top 2>/dev/null; then egress_ok=1
elif curl -fsSL -m 8 -o /dev/null https://www.aliyun.com 2>/dev/null; then egress_ok=1
fi
if [ "$egress_ok" = "1" ]; then
  touch "$NET_OK_FLAG"
  echo "  [conntrack] NOTRACK rules: $(iptables -t raw -S 2>/dev/null | grep -c NOTRACK) (egress check passed)"
else
  echo "  [conntrack][ROLLBACK] NOTRACK 后出站探活失败，已回滚 NOTRACK（保留 conntrack）"
  iptables -t raw -F 2>/dev/null
  touch "$NET_OK_FLAG"
  echo "[ROLLBACK] NOTRACK 后出站探活失败，已清空 raw 表" >> /var/log/ipes_net_guard.log 2>/dev/null
fi

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
Wants=network.target network-online.target

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
  [ -f "$conf" ] || { echo "  [guard] 缺少 ${conf}，跳过"; return 0; }
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
    echo "  [guard] 自动自愈：清理冲突文件 + 重放 $conf"
    # 先让"最后应用者"（/etc/sysctl.conf）与其它 sysctl.d 文件里的冲突键让位，
    # 否则单纯重放本文件，下次 sysctl --system 又会被打回
    deconflict_sysctl_files 2>/dev/null | grep -E '已让位|无冲突|共处理' || true
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

  # --- 磁盘队列断言 + 自愈（preheat 的 boot-tune / rc.local 也写这些 /sys 节点）---
  local dq_bad=""
  _dq_check(){
    dq_bad=""
    local d=/sys/block/vda ra ng rq sched
    [ -d "$d/queue" ] || return 0
    ra=$(cat "$d/queue/read_ahead_kb" 2>/dev/null)
    ng=$(cat "$d/queue/nomerges"      2>/dev/null)
    rq=$(cat "$d/queue/rq_affinity"   2>/dev/null)
    sched=$(tr -d '\n' < "$d/queue/scheduler" 2>/dev/null)
    [ "$ra" = "256" ] || dq_bad="$dq_bad read_ahead_kb(应=256 实=${ra:-N/A})"
    { [ -z "$ng" ] || [ "$ng" = "0" ]; } || dq_bad="$dq_bad nomerges(应=0 实=$ng)"
    { [ -z "$rq" ] || [ "$rq" = "2" ]; } || dq_bad="$dq_bad rq_affinity(应=2 实=$rq)"
    # 真实内核回显形如 "[none] mq-deadline kyber"（方括号标出当前生效项）；
    # 少数环境可能只回显 "none"，一并兼容，避免误报
    case "$sched" in
      *"[none]"*|none) : ;;
      *) dq_bad="$dq_bad scheduler(应=[none] 实=${sched:-N/A})" ;;
    esac
  }
  _dq_heal(){
    local d hw want _v
    for d in /sys/block/vd* /sys/block/sd* /sys/block/xvd* /sys/block/nvme*; do
      [ -d "$d/queue" ] || continue
      echo none > "$d/queue/scheduler"     2>/dev/null
      echo 0    > "$d/queue/rotational"    2>/dev/null
      echo 256  > "$d/queue/read_ahead_kb" 2>/dev/null
      for _v in 8192 4096 1024; do
        echo "$_v" > "$d/queue/nr_requests" 2>/dev/null
        [ "$(cat "$d/queue/nr_requests" 2>/dev/null)" = "$_v" ] && break
      done
      echo 0    > "$d/queue/nomerges"      2>/dev/null
      hw=$(cat "$d/queue/max_hw_sectors_kb" 2>/dev/null); want=1024
      [ -n "$hw" ] && [ "$hw" -lt "$want" ] 2>/dev/null && want=$hw
      echo "$want" > "$d/queue/max_sectors_kb" 2>/dev/null
      echo 2    > "$d/queue/rq_affinity"   2>/dev/null
    done
  }
  _dq_check
  if [ -n "$dq_bad" ]; then
    echo "  [guard] ⚠ 磁盘队列被回退:$dq_bad"
    echo "  [guard] 自动自愈：重写块设备队列参数"
    _dq_heal
    _dq_check
    if [ -n "$dq_bad" ]; then
      echo "  [guard] ✗ 磁盘队列自愈后仍异常:$dq_bad"
    else
      echo "  [guard] ✔ 磁盘队列自愈成功"
    fi
  else
    echo "  [guard] ✔ 磁盘队列为 r21 值"
  fi
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
echo "  default route  : $(ip route show default 2>/dev/null | grep -o 'initcwnd [0-9]* initrwnd [0-9]*')"
echo "================================================="
echo " IPES TUNE $TUNE_VER DONE  $(date '+%F %T')"
echo "================================================="

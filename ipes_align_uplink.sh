#!/bin/bash
# =============================================================================
# IPES 一键对齐「跑量好的节点」 —— 全锥 NAT + 上行最大化
# -----------------------------------------------------------------------------
# 【为什么要这个脚本】同批阿里云 SWAS 克隆机跑量差异的实测归因：
#   1) 云防火墙是「实例级」的，不随自定义镜像继承 —— 克隆机默认没放行入向 UDP，
#      NAT 退化为 restricted；restricted 只能下行，fullcone 才能被 peer 主动连入供上行。
#      车队实测：fullcone 均值 8.53 MB/s，restricted 均值 5.72 MB/s（低约 33%）。
#      实证：给节点补一条 TCP+UDP 1/65535 放行后，happ.1 立刻从 restricted 变 fullcone。
#   2) 主机侧 firewalld/iptables 残留 REJECT 规则、conntrack UDP 映射超时过短、
#      rp_filter=1 丢非对称 UDP 回包 —— 都会让「能连进来」变成「连不进来」。
#   3) 缓存容量决定供量上限：/data 可用空间小 → 存不下分片 → 没有内容可上行。
#      好节点系统盘已在线扩容（20G→30G），差节点没扩，缓存少 → 供量天然偏低。
#   4) 出向 tc 硬限速（htb/tbf）会直接卡死上行。
#
# 【本脚本做什么】幂等、可重复执行；全程保留 SN(设备身份)、/data 缓存，且【绝不停止业务原有保活】：
#   - 不 systemctl disable 任何业务看门狗/systemd 服务（仅操作防火墙服务 firewalld/iptables）
#   - 重建容器前先 bash -n 校验 docker_run，且只在原启动命令上最小注入挂载，绝不替换 entrypoint/环境变量
#   - 容器重建沿用原 docker_run 的 --restart=always，被改写的也只是镜像 tag，保活机制原样保留
#   0/6 对齐前快照：入向 UDP 包率、UDP 校验错误、上行速率、NAT 类型、缓存容量
#   1/6 主机防火墙全量放行 TCP+UDP 1-65535（iptables/ip6tables/nft + 关 firewalld，开机持久化）
#   2/6 内核 NAT/conntrack 对齐（rp_filter=0、UDP 映射超时拉长、conntrack 上限拉高）
#   3/6 tc 出向限速探测（默认只报告；FORCE_CLEAR_TC=1 才清 htb/tbf 硬限速）
#   4/6 系统/内核/网络 性能调优（复用 ipes_preheat_and_health.sh，失败则内联兜底）
#   5/6 缓存容量对齐（有未分配空间就在线扩分区+文件系统；报告缓存占用）
#   6/6 IPES 容器/happ 结构对齐（保 SN 保缓存重建，无需重复预热）
#   末   对齐后复测 + 打印报告 + 云端防火墙待办清单
#
# 【用法】
#   # 正式执行（改完自动复测；默认把 happ 补齐到 TARGET_HAPP，再复测）
#   curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_align_uplink.sh | bash
#
#   # 只体检不改动（先看差在哪，再决定改不改）
#   curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_align_uplink.sh | bash -s -- --check
#
#   # 可选环境变量
#   #   TARGET_HAPP=9       happ 实例数对齐目标（默认 9；当前 >= 目标则不动，否则默认补齐到 9）
#   #   TARGET_TAG=1.3.0    IPES 镜像 tag 对齐目标（默认 1.3.0）
#   #   ALIGN_HAPP=0        设为 0 可跳过 happ 结构对齐（默认 1=自动补齐 happ 到 TARGET_HAPP）
#   #   FORCE_CLEAR_TC=1    检测到出向硬限速时真的清掉（默认只报告）
#   #   SKIP_IPES=1         只做系统/网络对齐，不重建 IPES 容器
# =============================================================================
set -uo pipefail
export LC_ALL=C
shopt -s nullglob 2>/dev/null || true

ts(){ date '+%Y-%m-%d %H:%M:%S'; }
LOG="/var/log/align_uplink_$(date +%Y%m%d_%H%M%S).log"
find /var/log -maxdepth 1 -name 'align_uplink_*.log' -mtime +7 -delete 2>/dev/null || true
exec > >(tee -a "$LOG") 2>&1
log(){  echo -e "\033[0;32m[$(ts | cut -d' ' -f2)] INFO\033[0m $*"; }
warn(){ echo -e "\033[1;33m[$(ts | cut -d' ' -f2)] WARN\033[0m $*"; }
err(){  echo -e "\033[0;31m[$(ts | cut -d' ' -f2)] ERROR\033[0m $*"; }
head1(){ echo; echo -e "\033[1;36m===================== $* =====================\033[0m"; }

MODE="run"
case "${1:-}" in
  --check|-c|check) MODE="check" ;;
  --help|-h) [ -f "$0" ] && sed -n '2,45p' "$0"; exit 0 ;;
esac

TARGET_HAPP="${TARGET_HAPP:-9}"
TARGET_TAG="${TARGET_TAG:-1.3.0}"
IMG_BASE="${IMG_BASE:-ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest}"
TARGET_IMG="${IMG_BASE}:${TARGET_TAG}"
FORCE_CLEAR_TC="${FORCE_CLEAR_TC:-0}"
SKIP_IPES="${SKIP_IPES:-0}"
ALIGN_HAPP="${ALIGN_HAPP:-1}"
ALIGN_IMG="${ALIGN_IMG:-1}"

[[ $EUID -eq 0 ]] || { err "请使用 root 执行（云助手默认 root）"; exit 1; }
command -v curl >/dev/null 2>&1 || timeout 60 yum -y -q install curl >/dev/null 2>&1 || true

# =============================================================================
# 工具：读取 /proc/net/snmp 的 UDP 计数
# =============================================================================
snmp_udp(){  # 输出: InDatagrams InErrors InCsumErrors
  awk '/^Udp:/{n++; if(n==2){print $2, $4, $8; exit}}' /proc/net/snmp 2>/dev/null
}
iface_dev(){ ip route show default 2>/dev/null | awk '{print $5; exit}'; }
tx_bytes(){ cat "/sys/class/net/$1/statistics/tx_bytes" 2>/dev/null || echo 0; }
rx_bytes(){ cat "/sys/class/net/$1/statistics/rx_bytes" 2>/dev/null || echo 0; }

# 采样窗口：默认 10 秒，输出 KEY=VALUE 形式
sample_net(){
  local win="${1:-10}" dev u1 u2 t1 t2 r1 r2
  dev=$(iface_dev); [ -n "$dev" ] || dev=$(ls /sys/class/net | grep -v '^lo$' | head -1)
  u1=$(snmp_udp); t1=$(tx_bytes "$dev"); r1=$(rx_bytes "$dev")
  sleep "$win"
  u2=$(snmp_udp); t2=$(tx_bytes "$dev"); r2=$(rx_bytes "$dev")
  local i1=$(echo "$u1" | awk '{print $1}') i2=$(echo "$u2" | awk '{print $1}')
  local c1=$(echo "$u1" | awk '{print $3}') c2=$(echo "$u2" | awk '{print $3}')
  echo "DEV=$dev"
  echo "UDP_IN_PPS=$(awk -v a="$i1" -v b="$i2" -v w="$win" 'BEGIN{printf "%.1f",(b-a)/w}')"
  echo "UDP_CSUM_ERR=$(awk -v a="$c1" -v b="$c2" 'BEGIN{print (b-a)}')"
  echo "UP_MBPS=$(awk -v a="$t1" -v b="$t2" -v w="$win" 'BEGIN{printf "%.2f",(b-a)/w/1048576}')"
  echo "DOWN_MBPS=$(awk -v a="$r1" -v b="$r2" -v w="$win" 'BEGIN{printf "%.2f",(b-a)/w/1048576}')"
}

# IPES health 里抓 happ 数与 NAT 类型（不同版本字段名不一样，做多关键词兜底）
ipes_health_out(){ docker exec ipes ./bin/ipes health 2>&1 || true; }
ipes_happ_count(){  # 取 health 里最大的 happ:N/N 的 N
  ipes_health_out | grep -oE 'happ:[0-9]+/[0-9]+' | sed -E 's#happ:[0-9]+/([0-9]+)#\1#' | sort -n | tail -1
}
ipes_nat_summary(){  # 尽量提取每个 happ 的 NAT 类型
  local out; out=$(ipes_health_out)
  echo "$out" | grep -ioE '(happ[. ]?[0-9]+[^,;)]{0,24})?(fullcone|full_cone|restricted|symmetric|portrestricted)' 2>/dev/null | head -20
}
cache_used_mb(){
  local s
  s=$(timeout 90 du -sm /data/happ/*/hdata/cache 2>/dev/null | awk '{t+=$1} END{print t+0}')
  echo "${s:-0}"
}

# =============================================================================
# 0/6 对齐前快照
# =============================================================================
SNAP_BEFORE=""
take_snapshot(){
  local tag="$1"
  head1 "$tag"
  local inst_id pub_ip priv_ip
  # 公网 IP 取值：元数据不一定提供（轻量服务器无 public-ipv4；ECS 未绑公网/EIP 时返回 404 HTML）
  # → 多源回退 + IPv4 格式校验，避免把 404 HTML 整段打进日志
  _is_ipv4(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
  inst_id=$(curl -s --max-time 3 http://100.100.100.200/latest/meta-data/instance-id 2>/dev/null | tr -d '\r\n')
  priv_ip=$(curl -s --max-time 3 http://100.100.100.200/latest/meta-data/private-ipv4 2>/dev/null | tr -d '\r\n')
  pub_ip=""
  for _u in http://100.100.100.200/latest/meta-data/eipv4 \
            http://100.100.100.200/latest/meta-data/public-ipv4 \
            https://api.ipify.org \
            http://ip.3322.net; do
    _c=$(curl -s --max-time 3 "$_u" 2>/dev/null | tr -d '\r\n')
    if _is_ipv4 "$_c"; then pub_ip="$_c"; break; fi
  done
  [ -n "$inst_id" ] || inst_id="N/A"
  [ -n "$priv_ip" ] || priv_ip="N/A"
  [ -n "$pub_ip" ] || pub_ip="N/A(未绑公网或元数据不可用)"
  log "实例ID=$inst_id  公网IP=$pub_ip  内网IP=$priv_ip"

  local mem cpu root_sz data_avail
  mem=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
  cpu=$(nproc 2>/dev/null)
  root_sz=$(df -h / 2>/dev/null | awk 'NR==2{print $2" ("$5" 已用)"}')
  data_avail=$(df -h /data 2>/dev/null | awk 'NR==2{print $4"/"$2" ("$5" 已用)"}')
  log "内存=${mem}MB  CPU=${cpu}核  根盘=$root_sz  /data=$data_avail"

  local img happ cache
  img=$(docker inspect -f '{{.Config.Image}}' ipes 2>/dev/null || echo "（无 ipes 容器）")
  happ=$(ipes_happ_count); happ=${happ:-0}
  cache=$(cache_used_mb)
  log "IPES镜像=$img  happ=${happ}/${TARGET_HAPP}  缓存占用=${cache}MB"

  local fw_state fw_rule
  fw_state=$(systemctl is-active firewalld 2>/dev/null || true)
  fw_rule=$(iptables -S INPUT 2>/dev/null | head -1 || echo "?")
  log "firewalld=${fw_state:-inactive}  iptables INPUT 默认策略=${fw_rule##*-P INPUT }"

  local rp ctmax ctcnt
  rp=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo "?")
  ctmax=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "?")
  ctcnt=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo "?")
  log "rp_filter=$rp  conntrack=${ctcnt}/${ctmax}"

  local nat
  nat=$(ipes_nat_summary)
  if [ -n "$nat" ]; then log "NAT类型: $(echo "$nat" | tr '\n' ' ')"; else warn "未从 IPES health 解析到 NAT 类型（版本差异，以平台后台为准）"; fi

  log "采样 10 秒（上行/入向UDP）..."
  SNAP_BEFORE=$(sample_net 10)
  echo "$SNAP_BEFORE" | sed 's/^/    /'
}

# =============================================================================
# 1/6 主机防火墙全量放行
# =============================================================================
add_rule(){  # add_rule <iptables-binary> <chain> <rule...>  幂等插入
  local bin="$1"; shift
  [ -x "$bin" ] || return 0
  "$bin" -C "$@" >/dev/null 2>&1 || "$bin" -I "$@" >/dev/null 2>&1 || true
}

fw_open(){
  head1 "1/6 主机防火墙全量放行 TCP+UDP 1-65535"
  # 停掉会自行插入 REJECT 规则的防火墙服务（开机也不再拉起）
  for s in firewalld iptables ip6tables; do
    systemctl disable --now "$s" >/dev/null 2>&1 || true
  done
  # 清掉 nftables（若走 nft 后端，flush 后不再有 drop 规则）
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
  # 立刻核对
  local ok4 ok6
  ok4=$(iptables -S INPUT 2>/dev/null | grep -c -- '--dport 1:65535' || true)
  ok6=$(ip6tables -S INPUT 2>/dev/null | grep -c -- '--dport 1:65535' || true)
  log "已放行：IPv4 规则 $ok4 条 / IPv6 规则 $ok6 条（默认策略 ACCEPT）"

  # 持久化：iptables 规则重启即丢，用 rc.local 开机重新放行
  if ! grep -q 'ipes-fw-open.sh' /etc/rc.d/rc.local 2>/dev/null; then
    echo '/usr/local/bin/ipes-fw-open.sh' >> /etc/rc.d/rc.local 2>/dev/null || true
  fi
  chmod +x /etc/rc.d/rc.local 2>/dev/null || true
  timeout 20 systemctl enable rc-local >/dev/null 2>&1 || true
  log "已写入 /etc/rc.d/rc.local 并 enable rc-local（重启后自动重新放行）"
}

# =============================================================================
# 2/6 内核 NAT / conntrack 对齐
# =============================================================================
tune_nat(){
  head1 "2/6 内核 NAT / conntrack 对齐"
  local mem_kb mem_mb ct_max
  mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
  mem_mb=$(( ${mem_kb:-2097152} / 1024 ))
  ct_max=$(( mem_mb * 512 ))          # 约 每MB内存 512 条，1G≈50万
  [ "$ct_max" -lt 262144 ] && ct_max=262144
  [ "$ct_max" -gt 2097152 ] && ct_max=2097152

  cat > /etc/sysctl.d/98-ipes-nat.conf <<EOF
# PCDN 全锥 NAT / 上行最大化（本文件由 ipes_align_uplink.sh 生成）
# rp_filter=1 会丢掉「非对称路径」回来的 UDP 包 —— P2P 打洞场景必须关
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
# 端口与 conntrack：端口池开满 + UDP 映射超时拉长（映射活得久 = 更像 cone）
net.ipv4.ip_local_port_range = 1024 65535
net.netfilter.nf_conntrack_max = ${ct_max}
net.netfilter.nf_conntrack_udp_timeout = 300
net.netfilter.nf_conntrack_udp_timeout_stream = 600
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_generic_timeout = 600
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 60
# 海量 peer：neigh/路由表容量放大，避免 ARP 表打满丢包
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 16384
net.ipv4.neigh.default.gc_thresh3 = 65536
net.ipv4.route.max_size = 2097152
# UDP 收发缓冲对齐（IPES 为 UDP 密集型）
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.netdev_max_backlog = 100000
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF

  modprobe nf_conntrack 2>/dev/null || true
  local ml=/etc/modules-load.d/ipes-nat.conf
  echo "nf_conntrack" > "$ml" 2>/dev/null || true

  if ! sysctl -p /etc/sysctl.d/98-ipes-nat.conf 2>/tmp/align_nat.err; then
    warn "部分 NAT 键未生效（内核不支持，已忽略）: $(grep -icE 'unknown|invalid|cannot' /tmp/align_nat.err 2>/dev/null || echo 0) 个"
  fi
  rm -f /tmp/align_nat.err
  # 逐网卡把 rp_filter 也关掉（all/default 不覆盖已存在的接口）
  for f in /proc/sys/net/ipv4/conf/*/rp_filter; do
    echo 0 > "$f" 2>/dev/null || true
  done
  # 逐网卡放大 neigh 上限（部分内核只认接口级）
  for f in /proc/sys/net/ipv4/neigh/*/gc_thresh3; do
    echo 65536 > "$f" 2>/dev/null || true
  done

  log "rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)  UDP映射超时=$(sysctl -n net.netfilter.nf_conntrack_udp_timeout 2>/dev/null)s  conntrack上限=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)"
}

# =============================================================================
# 3/6 tc 出向限速探测
# =============================================================================
tc_probe(){
  head1 "3/6 tc 出向限速探测"
  command -v tc >/dev/null 2>&1 || { warn "无 tc 命令，跳过"; return 0; }
  local dev; dev=$(iface_dev); [ -n "$dev" ] || { warn "取不到默认网卡，跳过"; return 0; }
  log "默认出口网卡: $dev"
  tc -s qdisc show dev "$dev" 2>/dev/null | sed 's/^/    /' | head -20
  local filters; filters=$(tc filter show dev "$dev" 2>/dev/null | head -20)
  [ -n "$filters" ] && { log "已有 tc filter（分类器，通常保留）:"; echo "$filters" | sed 's/^/    /'; }

  if tc qdisc show dev "$dev" 2>/dev/null | grep -qE 'htb|tbf|hfsc|cbq'; then
    warn "检测到出向【硬限速】qdisc（htb/tbf/hfsc/cbq）——会直接卡住上行跑量！"
    tc qdisc show dev "$dev" > "/var/log/tc_backup_${dev}_$(date +%s).txt" 2>/dev/null || true
    if [ "$FORCE_CLEAR_TC" = "1" ]; then
      local roots
      roots=$(tc qdisc show dev "$dev" | grep -E 'htb|tbf|hfsc|cbq' | awk '{print $NF}' | head -1)
      log "FORCE_CLEAR_TC=1，清理根 qdisc: ${roots:-root}"
      tc qdisc del dev "$dev" root 2>/dev/null || true
      tc qdisc add dev "$dev" root fq_codel 2>/dev/null || true
      log "已清理硬限速，改用 fq_codel（原规则已备份到 /var/log/tc_backup_*.txt）"
    else
      warn "默认【不清理】：好节点上也存在 tc 规则，类型未知，乱删可能影响平台限速策略。"
      warn "确认要清就重跑： FORCE_CLEAR_TC=1 bash ipes_align_uplink.sh"
    fi
  else
    log "未检出硬限速，出向无 tc 瓶颈"
  fi
}

# =============================================================================
# 4/6 系统/内核/网络 性能调优（复用预热脚本）
# =============================================================================
PREHEAT_URL="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/ipes-scripts/main/ipes_preheat_and_health.sh"
run_preheat(){
  head1 "4/6 系统/内核/网络 性能调优"
  local f=/tmp/ipes_preheat_and_health.sh ok=0 url
  for url in "$PREHEAT_URL" "https://raw.githubusercontent.com/angelbaby86966/ipes-scripts/main/ipes_preheat_and_health.sh"; do
    if curl -fsSL --connect-timeout 15 --max-time 90 "$url" -o "$f" 2>/dev/null \
       && [ -s "$f" ] && head -1 "$f" | grep -q '^#!/bin/bash' && bash -n "$f" 2>/dev/null; then
      ok=1; log "已拉取预热调优脚本并校验通过: $url"; break
    fi
    warn "拉取失败，换下一个源: $url"
  done
  if [ "$ok" = "1" ]; then
    bash "$f" || warn "预热脚本返回非 0（多为个别内核键不支持，可忽略）"
    log "预热调优已完成（详见 /var/log/batch_preheat_*.log）"
  else
    warn "所有源都拉不到预热脚本，改用内联兜底调优"
    cat > /etc/sysctl.d/99-ipes-fallback.conf <<'EOF'
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.netdev_max_backlog = 100000
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 163840 33554432
net.ipv4.tcp_wmem = 4096 163840 33554432
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 4000000
kernel.pid_max = 4194304
vm.swappiness = 0
vm.dirty_ratio = 40
vm.dirty_background_ratio = 30
vm.vfs_cache_pressure = 30
vm.overcommit_memory = 1
EOF
    sysctl -p /etc/sysctl.d/99-ipes-fallback.conf >/dev/null 2>&1 || true
    cat > /etc/security/limits.d/99-ipes.conf <<'EOF'
* soft nofile 1000000
* hard nofile 1000000
* soft nproc 1000000
* hard nproc 1000000
EOF
    log "已应用内联兜底调优（建议网络恢复后重跑本脚本以获得完整预热优化）"
  fi
}

# =============================================================================
# 5/6 缓存容量对齐（在线扩盘 + 缓存占用报告）
# =============================================================================
align_cache(){
  head1 "5/6 缓存容量对齐"
  local root_dev root_disk fs disk_bytes part_bytes
  root_dev=$(findmnt -n -o SOURCE / 2>/dev/null)
  fs=$(findmnt -n -o FSTYPE / 2>/dev/null)
  log "/data 可用: $(df -h /data 2>/dev/null | awk 'NR==2{print $4"/"$2" ("$5" 已用)"}')"
  log "缓存占用: $(cache_used_mb)MB（/data/happ/*/hdata/cache）"

  case "$root_dev" in
    /dev/mapper/*|/dev/dm-*) warn "根盘在 LVM 上，本脚本不做自动扩分区（需手动 lvextend+resize）"; return 0 ;;
    "") warn "取不到根设备，跳过扩盘"; return 0 ;;
  esac
  root_disk=${root_dev%%[0-9]*}
  disk_bytes=$(lsblk -b -d -n -o SIZE "$root_disk" 2>/dev/null || echo 0)
  part_bytes=$(lsblk -b -n -o SIZE "$root_dev" 2>/dev/null || echo 0)
  if [ "${disk_bytes:-0}" -gt "${part_bytes:-0}" ] 2>/dev/null; then
    log "磁盘比分区大 $(( (disk_bytes - part_bytes) / 1024 / 1024 ))MiB，开始在线扩容"
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
        *)              warn "未知文件系统 $fs，未扩容" ;;
      esac
      log "在线扩容后 /data 可用: $(df -h /data 2>/dev/null | awk 'NR==2{print $4"/"$2}')"
    else
      warn "分区扩展失败（未动数据，安全）"
    fi
  else
    log "磁盘无未分配空间（分区已占满磁盘）→ 想加大缓存需先在控制台把系统盘调大，再重跑本脚本"
  fi

  local avail_mb
  avail_mb=$(df -m /data 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 5120 ] 2>/dev/null; then
    warn "缓存可用空间仅 ${avail_mb}MB（<5G）——空间不足会导致分片存不下、供量偏低，建议扩盘"
  fi
}

# =============================================================================
# 6/6 IPES 容器 / happ 结构对齐
# =============================================================================
# 在 custom.yml 的 args 列表后追加缺失的 happ 路径（真值来源：IPES 按 args 数量决定 worker 数）。
# 只在「最后一个 happ 项」之后插入，不重写整个文件，避免破坏 token/server 等其它配置。
add_happ_to_cfg(){
  local cfg="$1" start="$2" end="$3" i line
  line=$(grep -nE '^[[:space:]]*-[[:space:]]*/data/happ/happ\.[0-9]+' "$cfg" 2>/dev/null | tail -1 | cut -d: -f1)
  [ -n "$line" ] || { warn "custom.yml 中未找到 happ 项，无法追加（请确认 $cfg 路径）"; return 1; }
  for i in $(seq "$start" "$end"); do
    grep -qE "(^|[[:space:]]-)[[:space:]]*/data/happ/happ\.$i([[:space:]]|$)" "$cfg" 2>/dev/null && continue
    sed -i -E "${line}a\\  - /data/happ/happ.${i}" "$cfg" 2>/dev/null || true
    line=$((line + 1))
  done
  return 0
}
align_ipes(){
  head1 "6/6 IPES 容器 / happ 结构对齐"
  if [ "$SKIP_IPES" = "1" ]; then warn "SKIP_IPES=1，跳过容器对齐"; return 0; fi
  command -v docker >/dev/null 2>&1 || { warn "无 docker，跳过"; return 0; }
  local C=ipes DR=/opt/ipes/docker_run CFG="" CFG_BAK="" DR_BAK=""
  [ -f "$DR" ] || { warn "$DR 不存在（IPES 未按标准结构部署），跳过容器对齐"; return 0; }
  for p in /opt/ipes/var/db/ipes/happ-conf/custom.yml /opt/ipes/custom.yml /data/ipes/custom.yml; do
    [ -f "$p" ] && { CFG="$p"; break; }
  done
  [ -n "$CFG" ] && log "custom.yml 路径: $CFG" || warn "未找到 custom.yml（happ 数由 custom.yml 的 args 决定，找不到将无法对齐 worker 数）"

  local cur_happ cur_img need=0
  cur_happ=$(ipes_happ_count); cur_happ=${cur_happ:-0}
  cur_img=$(docker inspect -f '{{.Config.Image}}' "$C" 2>/dev/null || true)
  log "当前 happ=${cur_happ}/${TARGET_HAPP}  镜像=${cur_img:-（无容器）}  目标镜像=$TARGET_IMG"

  # (a) happ 结构对齐：默认补齐到 TARGET_HAPP（IPES 按 custom.yml 的 args 数量决定 worker 数）
  if [ "$ALIGN_HAPP" != "1" ]; then
    log "ALIGN_HAPP!=1，跳过 happ 结构对齐"
  elif [ "$cur_happ" -lt "$TARGET_HAPP" ] 2>/dev/null; then
    log "happ 数 $cur_happ < $TARGET_HAPP，开始补齐（建目录 + 改 custom.yml args + 注入 docker_run 挂载，保活安全）"
    local i base xbi
    # 1) 建缺失的 happ 目录 + 身份文件（必须是文件，建成目录会让 IPES 读配置失败）
    for i in $(seq "$cur_happ" $((TARGET_HAPP-1))); do
      base=/data/happ/happ.$i
      mkdir -p "$base/hdata/cache" "$base/hdata/config" 2>/dev/null || true
      xbi="$base/xycould_base_info"
      if [ -d "$xbi" ]; then
        warn "$xbi 是目录（上次失败遗留），会导致 IPES 起不来；已跳过该索引，请人工确认"
      elif [ ! -e "$xbi" ]; then
        # 必须是【文件】；建成目录会让 docker 按目录挂载，导致 IPES 读身份配置失败
        touch "$xbi" 2>/dev/null || warn "创建 $xbi 失败"
      fi
    done
    # 2) 改 custom.yml args（真值来源：IPES 按 args 里的 happ 路径数决定 worker 数）。
    #    先备份，再仅在「最后一个 happ 项」之后追加缺失路径，绝不重写整个文件（避免破坏 token/server 等配置）
    if [ -n "$CFG" ]; then
      cp -a "$CFG" "${CFG}.align.bak" 2>/dev/null || true
      CFG_BAK="${CFG}.align.bak"
      if add_happ_to_cfg "$CFG" "$cur_happ" "$((TARGET_HAPP-1))"; then
        need=1
        log "已向 $CFG 追加缺失的 happ 路径（原文件已备份 ${CFG_BAK}）"
      else
        warn "custom.yml 追加 happ 路径失败（未改动原文件）"
      fi
    else
      warn "未找到 custom.yml，无法改写 args；将仅注入 docker_run 挂载（IPES 可能仍按原 worker 数运行，建议人工确认 $C 的 happ 配置）"
    fi
    # 3) docker_run 最小注入挂载（保留原启动命令 / entrypoint / --restart=always，保活机制不动）
    cp -a "$DR" "${DR}.align.bak" 2>/dev/null || true
    DR_BAK="${DR}.align.bak"
    local newmounts="" j
    for j in $(seq 0 $((TARGET_HAPP-1))); do
      grep -q "/data/happ/happ.$j/hdata/cache" "$DR" 2>/dev/null && continue
      newmounts="$newmounts -v /data/happ/happ.$j/hdata/cache:/data/happ/happ.$j/hdata/cache -v /data/happ/happ.$j/hdata/config:/data/happ/happ.$j/hdata/config -v /data/happ/happ.$j/xycould_base_info:/data/happ/happ.$j/xycould_base_info"
    done
    if [ -n "$newmounts" ]; then
      # 锚点：镜像引用 token；在其前插入挂载，其余一切（含 --restart=always / 启动命令）不动
      if sed -i -E "s#(ccr\.ccs\.tencentyun\.com/zyy_cloud/ipes-linux-amd64-youkai-latest:[A-Za-z0-9._-]+)#$newmounts \1#" "$DR" 2>/dev/null; then
        need=1
        log "已在原始 docker_run 上注入缺失的 happ 挂载（启动命令未改动，原文件已备份 ${DR_BAK}）"
      else
        warn "注入挂载失败，保留原始 docker_run 不动（不重建，避免破坏业务保活）"
      fi
    else
      log "原始 docker_run 已含全部 happ 挂载，无需改动"
    fi
  else
    log "happ 数已达标（$cur_happ >= $TARGET_HAPP），不动结构"
  fi

  # (b) 镜像 tag 不一致 → 只替换 tag（作用域极小，先备份）
  if [ -n "$cur_img" ] && [ "$cur_img" != "$TARGET_IMG" ]; then
    cp -a "$DR" "${DR}.imgbak.$(date +%s)" 2>/dev/null || true
    if sed -i -E "s#${IMG_BASE}:[A-Za-z0-9._-]+#${TARGET_IMG}#g" "$DR" 2>/dev/null; then
      log "已把 docker_run 内镜像 tag 对齐为 $TARGET_TAG（原文件已备份）"
      need=1
    fi
  fi

  if [ "$need" = "0" ]; then
    log "容器结构/镜像均已对齐，无需重建（保 SN、保缓存）"
    return 0
  fi

  if docker image inspect "$TARGET_IMG" >/dev/null 2>&1; then
    log "本地已有目标镜像，跳过拉取"
  elif [ "$ALIGN_IMG" != "1" ]; then
    log "ALIGN_IMG!=1，跳过镜像对齐/拉取（happ 由 custom.yml 决定，不依赖镜像 tag，省时）"
  elif [ -n "$cur_img" ] && docker image inspect "$cur_img" >/dev/null 2>&1 && docker tag "$cur_img" "$TARGET_IMG" 2>/dev/null; then
    log "本地已有等价镜像($cur_img)，tag 为目标镜像，跳过网络拉取（省时）"
  else
    log "拉取 $TARGET_IMG ..."
    if ! timeout 300 docker pull "$TARGET_IMG" >/dev/null 2>&1; then
      warn "目标镜像拉取失败 —— 保留现有容器不动（避免节点宕机），仅结构已更新"
      return 0
    fi
  fi

  # 保活约束：重建前必须先校验 docker_run 语法，避免用写坏的文件把 IPES 弄宕机
  if ! bash -n "$DR" >/dev/null 2>&1; then
    warn "docker_run 语法校验失败，放弃重建（保留现有运行中容器，不破坏业务保活）"
    [ -n "$DR_BAK" ] && [ -f "$DR_BAK" ] && cp -a "$DR_BAK" "$DR" 2>/dev/null && warn "已回滚 docker_run 备份"
    return 0
  fi
  # 备份当前运行态，便于极端情况下复原
  docker inspect "$C" >"/var/log/ipes_container_bak_$(date +%s).json" 2>/dev/null || true
  log "重建容器（保留 /data/happ 缓存与设备身份 SN，业务中断约数秒；原容器快照已备份）..."
  docker rm -f "$C" >/dev/null 2>&1 || true
  if bash "$DR" >/dev/null 2>&1; then
    local k
    for k in $(seq 1 12); do
      docker ps --format '{{.Names}}' | grep -qx "$C" && break
      sleep 5
    done
    if docker ps --format '{{.Names}}' | grep -qx "$C"; then
      log "容器已重建并在运行: $(docker inspect -f '{{.Config.Image}}' "$C")"
    else
      err "容器未起来，请检查 $DR 与日志 $LOG"
      # 回滚 custom.yml + docker_run，避免节点停在错误配置
      [ -n "$DR_BAK" ] && [ -f "$DR_BAK" ] && cp -a "$DR_BAK" "$DR" 2>/dev/null && warn "已回滚 docker_run 备份（请手动 bash $DR 拉起）"
      [ -n "$CFG_BAK" ] && [ -f "$CFG_BAK" ] && cp -a "$CFG_BAK" "$CFG" 2>/dev/null && warn "已回滚 custom.yml 备份"
    fi
  else
    err "按 $DR 重建失败，请手动检查"
    [ -n "$DR_BAK" ] && [ -f "$DR_BAK" ] && cp -a "$DR_BAK" "$DR" 2>/dev/null && warn "已回滚 docker_run 备份"
    [ -n "$CFG_BAK" ] && [ -f "$CFG_BAK" ] && cp -a "$CFG_BAK" "$CFG" 2>/dev/null && warn "已回滚 custom.yml 备份"
  fi
}

# =============================================================================
# 末：对齐后复测 + 报告
# =============================================================================
final_report(){
  head1 "对齐后复测"
  local img happ cache nat
  img=$(docker inspect -f '{{.Config.Image}}' ipes 2>/dev/null || echo "（无容器）")
  happ=$(ipes_happ_count); happ=${happ:-0}
  cache=$(cache_used_mb)
  log "IPES镜像=$img  happ=${happ}/${TARGET_HAPP}  缓存占用=${cache}MB"
  nat=$(ipes_nat_summary)
  [ -n "$nat" ] && log "NAT类型: $(echo "$nat" | tr '\n' ' ')"

  log "采样 5 秒复测..."
  local snap_after; snap_after=$(sample_net 5)
  echo "$snap_after" | sed 's/^/    /'

  local b_up a_up b_in a_in
  b_up=$(echo "$SNAP_BEFORE" | awk -F= '/^UP_MBPS=/{print $2}')
  a_up=$(echo "$snap_after" | awk -F= '/^UP_MBPS=/{print $2}')
  b_in=$(echo "$SNAP_BEFORE" | awk -F= '/^UDP_IN_PPS=/{print $2}')
  a_in=$(echo "$snap_after" | awk -F= '/^UDP_IN_PPS=/{print $2}')

  echo
  echo -e "\033[1;36m==================== 对齐结果对照表 ====================\033[0m"
  echo -e "  上行速率   : ${b_up:-?} MB/s   ->  \033[1;32m${a_up:-?} MB/s\033[0m"
  echo -e "  入向UDP    : ${b_in:-?} 包/秒  ->  \033[1;32m${a_in:-?} 包/秒\033[0m"
  echo -e "  happ       : -              ->  ${happ}/${TARGET_HAPP}"
  if [ "${happ:-0}" -lt "$TARGET_HAPP" ] 2>/dev/null; then
    warn "复测时 happ=${happ} < ${TARGET_HAPP}：容器刚重建，happ worker 仍在初始化（通常需 30s+ 才上报），请稍后在本机执行 ./bin/ipes health 复核是否到 ${TARGET_HAPP}（配置层已对齐，不必重跑本脚本）"
  fi
  echo -e "  缓存占用   : -              ->  ${cache} MB"
  echo -e "\033[1;36m========================================================\033[0m"

  # 判定：入向 UDP 是否为 0 是「能不能被连进来」的直接证据
  local verdict
  verdict=$(awk -v v="${a_in:-0}" 'BEGIN{ if (v+0 < 0.5) print "BLOCKED"; else print "OK" }')
  echo
  if [ "$verdict" = "BLOCKED" ]; then
    echo -e "\033[1;41;37m ⚠ 入向 UDP 包率≈0 —— 外部 peer 连不进来，NAT 仍是 restricted \033[0m"
    echo -e "\033[1;33m 机器内部能做的已经做完了，剩下这一步【必须在云端放行】：\033[0m"
  else
    echo -e "\033[1;42;30m ✔ 已能收到入向 UDP —— NAT 具备 fullcone 条件 \033[0m"
    echo -e "\033[1;33m 若平台后台仍显示 restricted / 跑量没起来，再核对下面这一项：\033[0m"
  fi
  cat <<'TODO'
    ┌──────────────────────────────────────────────────────────────────┐
    │ 【必须人工做的一步】云端放行是「实例级」的，不随自定义镜像继承：  │
    │   放行  TCP 1-65535  和  UDP 1-65535                              │
    │   · 轻量应用服务器(SWAS)：控制台 → 本实例 → 防火墙 → 添加规则      │
    │     或工作台「防火墙模板」→ 批量应用到本实例（一键）               │
    │   · ECS(i-bp1* 开头)：控制台 → 本实例 → 安全组 → 配置规则         │
    │     入方向 添加：协议 TCP+UDP，端口 1/65535，源 0.0.0.0/0          │
    │   未放行时：NAT=restricted，只有下行、几乎没有上行                │
    └──────────────────────────────────────────────────────────────────┘
TODO
  echo
  log "完成。完整日志: $LOG"
  log "如仍有异常，把上面这张对照表 + 本日志发给运维一起看"
  echo "ALIGN_UPLINK_RESULT=OK LOG=$LOG"
}

# =============================================================================
main(){
  SECONDS=0
  echo -e "\033[1;36m########## IPES 对齐「跑量好的节点」开始（模式: $MODE） ##########\033[0m"
  log "目标: happ=${TARGET_HAPP}  镜像=$TARGET_IMG  ALIGN_HAPP=${ALIGN_HAPP}  FORCE_CLEAR_TC=${FORCE_CLEAR_TC}  SKIP_IPES=${SKIP_IPES}"

  take_snapshot "0/6 对齐前快照"

  if [ "$MODE" = "check" ]; then
    echo
    log "=== --check 模式：只体检不改动，以下项目已跳过 ==="
    log "  1/6 主机防火墙放行   2/6 NAT/conntrack 调优   3/6 tc（本就只报告）   4/6 性能调优   5/6 扩盘   6/6 容器对齐"
    log "  要真正对齐，去掉 --check 重跑即可"
    log "耗时: ${SECONDS}s"
    echo "ALIGN_UPLINK_RESULT=CHECK_ONLY LOG=$LOG"
    return 0
  fi

  fw_open
  tune_nat
  tc_probe
  run_preheat
  align_cache
  align_ipes
  final_report
  log "总耗时: ${SECONDS}s"
}
main "$@"

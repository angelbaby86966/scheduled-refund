#!/bin/bash
# ============================================================
# IPES/PCDN 节点系统调优（CentOS 7.9，2C2G 级）
# 来源：ipes-deploy/inline_deploy_r19_inline.sh 的 A 段（已实战验证）
# 特性：幂等（可重复执行）、失败不致命（逐项 -e 容错）、末尾自检并打印结果
# 用法：bash /opt/pcdn_tune.sh
# ============================================================
exec > /var/log/pcdn_tune.log 2>&1
set -x
date

echo "===== [1/5] 写入 sysctl 配置 ====="
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-ipes.conf <<'EOF'
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_wait = 30
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
net.core.default_qdisc = fq
EOF

echo "===== [2/5] 加载内核模块 ====="
modprobe nf_conntrack 2>/dev/null
modprobe tcp_bbr 2>/dev/null

echo "===== [3/5] 应用 sysctl ====="
sysctl -e -p /etc/sysctl.d/99-ipes.conf 2>&1 | tail -5
# 兜底：内核不支持 bbr 时退回 cubic，绝不留在 reno
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || \
  sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null
sysctl -w net.core.default_qdisc=fq 2>/dev/null

echo "===== [4/5] RPS 软中断摊核 + NOTRACK ====="
nic=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [ -n "$nic" ]; then
  ncpu=$(nproc); mask=$(printf '%x' $(( (1<<ncpu)-1 )))
  for q in /sys/class/net/$nic/queues/rx-*; do
    echo "$mask" > "$q/rps_cpus" 2>/dev/null
    echo 4096 > "$q/rps_flow_cnt" 2>/dev/null
  done
  echo "[tune] RPS 已应用到 $nic (mask=$mask, cpus=$ncpu)"
else
  echo "[tune] 未识别网卡，跳过 RPS"
fi
# NOTRACK 幂等：先查后加
if ! iptables -t raw -C PREROUTING -j NOTRACK 2>/dev/null; then
  iptables -t raw -A PREROUTING -j NOTRACK 2>/dev/null
  iptables -t raw -A OUTPUT -j NOTRACK 2>/dev/null
  echo "[tune] NOTRACK 已添加"
else
  echo "[tune] NOTRACK 已存在，跳过"
fi

echo "===== [5/5] 自检 ====="
echo "----------------------------------------"
echo "拥塞控制   : $(cat /proc/sys/net/ipv4/tcp_congestion_control)"
echo "可用算法   : $(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
echo "默认队列   : $(cat /proc/sys/net/core/default_qdisc)"
echo "BBR 模块   : $(lsmod 2>/dev/null | grep -c tcp_bbr)"
echo "somaxconn  : $(cat /proc/sys/net/core/somaxconn)"
echo "backlog    : $(cat /proc/sys/net/core/netdev_max_backlog)"
echo "syn_backlog: $(cat /proc/sys/net/ipv4/tcp_max_syn_backlog)"
echo "conntrack  : $(cat /proc/sys/net/netfilter/nf_conntrack_max)"
echo "rmem_max   : $(cat /proc/sys/net/core/rmem_max)"
echo "wmem_max   : $(cat /proc/sys/net/core/wmem_max)"
echo "fastopen   : $(cat /proc/sys/net/ipv4/tcp_fastopen)"
echo "NOTRACK    : $(iptables -t raw -S 2>/dev/null | grep -c NOTRACK)"
echo "----------------------------------------"
date
echo "===== 调优完成 ====="
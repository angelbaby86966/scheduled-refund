#!/bin/bash
# ============================================================
# 内核升级 + BBR 完整调优（CentOS 7.9）
# 流程：装 kernel-lt（阿里云源）→ grub 默认 → 持久化 BBR/fq → 延迟重启
# 旧内核保留在 grub 里，出问题可回退
# 用法：bash /opt/kernel_bbr.sh
# ============================================================
exec > /var/log/kernel_bbr.log 2>&1
set -x
date

echo "===== [1/5] 切阿里云内网源（更快）====="
sed -i 's|^mirrorlist=|#mirrorlist=|g; s|^#\?baseurl=http://mirror.centos.org|baseurl=https://mirrors.cloud.aliyuncs.com|g' \
  /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
yum clean all >/dev/null 2>&1; rm -rf /var/cache/yum

echo "===== [2/5] 装 kernel-lt（CentOS 官方源，>=4.9 支持 BBR）====="
yum install -y kernel-lt
RC=$?
echo "[kernel] kernel-lt 返回码: $RC"
if ! rpm -q kernel-lt >/dev/null 2>&1; then
  echo "[kernel] kernel-lt 装不上，回退 elrepo kernel-ml"
  rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org || true
  yum --enablerepo=elrepo install -y https://www.elrepo.org/elrepo-release-7.0-4.el7.elrepo.noarch.rpm || true
  yum --enablerepo=elrepo-kernel install -y kernel-ml || true
fi
rpm -q kernel kernel-lt kernel-ml 2>/dev/null

echo "===== [3/5] grub 默认项设为 0（新内核）====="
NEWK=$(rpm -q --last kernel-lt 2>/dev/null | head -1)
[ -z "$NEWK" ] && NEWK=$(rpm -q --last kernel-ml 2>/dev/null | head -1)
echo "[kernel] 目标新内核: ${NEWK:-未装成功}"
if [ -n "$NEWK" ]; then
  grub2-set-default 0
  grub2-editenv list
  echo "[kernel] grub2-editenv saved_entry: $(grub2-editenv list)"
fi

echo "===== [4/5] 持久化 BBR + fq ====="
echo tcp_bbr > /etc/modprobe.d/tcp_bbr.conf
cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_available_congestion_control = bbr cubic reno
net.core.default_qdisc = fq
EOF
sysctl -e -p /etc/sysctl.d/99-bbr.conf 2>&1 | tail -3
echo "[kernel] 重启前 CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control)（重启后才生效）"
echo "[kernel] 当前内核: $(uname -r)"

echo "===== [5/5] 延迟重启 ====="
if [ -n "$NEWK" ]; then
  ( sleep 25; /sbin/reboot ) >/dev/null 2>&1 &
  echo "[kernel] 已安排 25 秒后重启"
else
  echo "[kernel] ⚠️ 未装到新内核，不重启（避免无意义中断）"
fi
date
echo "KERNEL_BBR_DONE"
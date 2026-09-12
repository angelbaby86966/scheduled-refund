#!/bin/bash
# =============================================================================
# IPES 一键融合脚本：预热调优+健康检查  +  对齐拉满（全锥NAT / happ拉满9 / 镜像对齐 / 重建保活）
# -----------------------------------------------------------------------------
# 【融合来源】
#   1) ipes_preheat_and_health.sh  —— OS/IO/网络 激进调优 + 健康检查安装（不动版本/不重建）
#   2) ipes_align_uplink.sh        —— 防火墙/NAT/conntrack/tc/缓存扩容/happ结构/镜像重建
#
# 【与原两条命令等价，但只需一条】
#   curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_onekey.sh | bash
#
# 【参数透传】本脚本把参数原样透传给「对齐脚本」，例如只体检不改动：
#   curl ... | bash -s -- --check
#
# 【可选环境变量（透传给对齐脚本）】
#   TARGET_HAPP=9  TARGET_TAG=1.3.0  ALIGN_HAPP=1  FORCE_CLEAR_TC=0  SKIP_IPES=0  SKIP_PREHEAT=1
#   （SKIP_PREHEAT 本脚本会自动决策：预热成功→1 跳过重复；失败→0 兜底；显式设置则尊重设置）
#
# 说明：先单独跑一次 preheat 是为了让「健康检查安装 / OS 调优」在第一步就落地，
#       即便后续对齐阶段因个别内核键不支持报错，健康拉起机制也已就绪。
#   【2026-09-12】不再重复预热：第 1 步预热成功后，会以 SKIP_PREHEAT=1 调用对齐脚本，
#       跳过它内部的 4/6 预热（原来会跑两遍、日志雷同）；若第 1 步失败，则传 0 让对齐阶段兜底再试。
#
# 变更（2026-09-12）：
#   1) [0.5] 新增「缓存盘余量硬预警」——空间不足是压供量的头号原因，必须一进来就看见；
#   2) 末尾放行提示改为「平台感知」：轻量服务器→云防火墙 / ECS(i-*)→安全组，不再误导。
# =============================================================================
set -uo pipefail
export LC_ALL=C

PREHEAT_URL="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/ipes-scripts/main/ipes_preheat_and_health.sh"
ALIGN_URL="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_align_uplink.sh"

echo
echo -e "\033[1;36m########## IPES 一键融合开始（预热 + 对齐）##########\033[0m"
echo "[0] 前置检查：root / curl"
[[ $EUID -eq 0 ]] || { echo -e "\033[0;31m[ERROR] 请使用 root 执行（云助手默认 root）\033[0m"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo -e "\033[0;31m[ERROR] curl 不可用\033[0m"; exit 1; }

# ---------------------------------------------------------------------------
# [0.5] 缓存盘余量硬预警
#   缓存空间不足 → 分片存不下 → 供量偏低，是跑量上不去的常见原因，
#   而它原来埋在 5/6 步骤里很容易被忽略，这里提到最前面。
# ---------------------------------------------------------------------------
DATA_DIR="${DATA_DIR:-/data}"
if [ -d "$DATA_DIR" ]; then
  _dline=$(df -Pm "$DATA_DIR" 2>/dev/null | awk 'NR==2{print $2, $3, $4, $5}')
  _tot=$(echo "$_dline" | awk '{print $1}')
  _used=$(echo "$_dline" | awk '{print $2}')
  _avail=$(echo "$_dline" | awk '{print $3}')
  _pct=$(echo "$_dline" | awk '{print $4}' | tr -d '%')
  if [ -n "${_tot:-}" ] && [ -n "${_avail:-}" ]; then
    echo "[0.5] 缓存盘检查：$DATA_DIR 总 $(( _tot / 1024 ))G / 已用 $(( _used / 1024 ))G / 可用 $(( _avail / 1024 ))G（${_pct}%）"
    _cachemb=$(du -sm "$DATA_DIR/happ" 2>/dev/null | awk '{print $1}')
    [ -n "${_cachemb:-}" ] && echo "      其中缓存占用约 ${_cachemb}MB（$DATA_DIR/happ）"
    if [ "${_avail:-0}" -lt 5120 ]; then
      echo
      echo -e "\033[1;41;37m ⚠ 缓存盘可用空间仅 ${_avail}MB（<5G）——分片存不下会导致供量偏低 \033[0m"
      echo -e "\033[1;33m   建议先【扩盘】或调低 IPES 缓存上限再跑量。\033[0m"
      echo -e "\033[1;33m   本脚本不会删你的缓存，继续执行是安全的，但跑量大概率上不去。\033[0m"
      echo
    else
      echo -e "      \033[0;32m✔ 空间充足\033[0m"
    fi
  fi
else
  echo "[0.5] 缓存盘检查：无 $DATA_DIR 目录，跳过"
fi

echo
echo -e "\033[1;36m========== [1/2] 预热调优 + 健康检查安装 ==========\033[0m"
PREHEAT_OK=0
if curl -fsSL "$PREHEAT_URL" | bash; then
  PREHEAT_OK=1
  echo "[1/2] 预热脚本执行完成"
else
  echo -e "\033[1;33m[WARN] 预热脚本返回非 0（多为个别内核键不支持，可忽略；健康拉起机制已尽力安装）\033[0m"
fi

echo
echo -e "\033[1;36m========== [2/2] 对齐拉满（防火墙/NAT/tc/缓存/happ/镜像/重建） ==========\033[0m"
# 【2026-09-12】预热去重：
#   本步已在上面跑过预热 → 告知对齐脚本跳过它自己的 4/6 预热，避免重复下载 + 重复日志。
#   但若上面失败了，则传 0，让对齐阶段再兜底跑一次（成功才跳过，失败仍保底）。
#   用户若显式设置了 SKIP_PREHEAT，则尊重用户设置。
if [ -n "${SKIP_PREHEAT:-}" ]; then
  export SKIP_PREHEAT
elif [ "$PREHEAT_OK" = "1" ]; then
  export SKIP_PREHEAT=1
else
  export SKIP_PREHEAT=0
fi
if [ "$SKIP_PREHEAT" = "1" ]; then
  echo "[2/2] 对齐脚本内的预热步骤：跳过（本轮已在上一步完成，避免重复）"
else
  echo "[2/2] 对齐脚本内的预热步骤：将兜底执行一次（上一步未成功）"
fi
# 透传参数给对齐脚本（如 --check）
curl -fsSL "$ALIGN_URL" | bash -s -- "$@"

echo
echo -e "\033[1;42;30m ✔ 融合脚本执行完毕 \033[0m"

# ---------------------------------------------------------------------------
# 平台感知的放行提示：轻量服务器看「云防火墙」，ECS 看「安全组」——两者菜单不同
# ---------------------------------------------------------------------------
_iid=$(curl -s --max-time 3 http://100.100.100.200/latest/meta-data/instance-id 2>/dev/null | tr -d '\r\n')
case "$_iid" in
  i-*) PLATFORM="ECS" ;;
  "")  PLATFORM="未知" ;;
  *)   PLATFORM="轻量应用服务器(SWAS)" ;;
esac
echo "   实例ID=${_iid:-N/A}   平台=$PLATFORM"
echo "   若平台后台仍显示 restricted / 跑量没起来，记得做【实例级放行 TCP 1-65535 + UDP 1-65535】"
echo "   （这一步不随自定义镜像继承，克隆机会丢）："
case "$_iid" in
  i-*) echo "     · ECS：控制台 → 本实例 → 安全组 → 配置规则 → 入方向 添加「TCP+UDP / 1/65535 / 0.0.0.0/0」" ;;
  *)   echo "     · 轻量服务器：控制台 → 本实例 → 防火墙 → 添加规则（或工作台「防火墙模板」批量应用）" ;;
esac
echo "     对齐脚本末尾也有同一份清单，可用 check_all_firewall.py 批量核对。"

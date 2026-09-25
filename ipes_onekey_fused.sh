#!/bin/bash
# =============================================================================
# ipes_onekey_fused.sh  v1.0  (2026-09-26)
# 三段式一键融合：[1/3] 纯调优打底 → [2/3] 预热+健康检查 → [3/3] 对齐拉满
# -----------------------------------------------------------------------------
# 【融合来源】
#   1) ipes_tune_only.sh          —— 存量机纯优化（不动身份/不重建容器/不重启机器）
#   2) ipes_preheat_and_health.sh —— OS/IO/网络调优 + 健康检查安装
#   3) ipes_align_uplink.sh       —— 防火墙/NAT/conntrack/tc/缓存扩容/happ拉满/镜像重建
#
# 【顺序为什么这样排】
#   先跑 tune_only 把 99-ipes.conf 权威值落好，再跑预热（带共存指纹闸门，不会打回调优），
#   最后对齐拉满（它内部兜底会重放权威文件）——三段互不覆盖、层层兜底。
#
# 【可选环境变量】
#   SKIP_TUNE=1        跳过 [1/3] 纯调优（默认执行，幂等安全）
#   SKIP_PREHEAT=1     跳过 [2/3] 预热（默认自动决策：成功跳过/失败兜底）
#   TARGET_HAPP=12     透传给对齐脚本（默认拉满 12 路）
#   FORCE_CLEAR_TC=0   透传给对齐脚本
# 【参数透传】"$@" 原样透传给对齐脚本，例如只体检不动手： bash -s -- --check
# =============================================================================
set -uo pipefail
export LC_ALL=C
FUSED_REV="20260926-fused-v10"

echo
echo -e "\033[1;36m########## IPES 三段式一键融合（调优→预热→对齐） $FUSED_REV ##########\033[0m"

# [0] 前置检查
[[ $EUID -eq 0 ]] || { echo -e "\033[0;31m[ERROR] 请使用 root 执行（云助手默认 root）\033[0m"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo -e "\033[0;31m[ERROR] curl 不可用\033[0m"; exit 1; }

# 三源下载工具：gh-proxy.com 优先（无缓存旧版问题），raw 直连兜底，jsDelivr 最后
fetch3(){ # $1=url后缀格式1(gh-proxy) $2=raw直连 $3=jsDelivr  $4=输出文件 $5=必需指纹(可空)
  local out="$4"; rm -f "$out"
  for u in "$1" "$2" "$3"; do
    if curl -fsSL --connect-timeout 15 --max-time 120 "$u" -o "$out" 2>/dev/null \
       && [ -s "$out" ] && head -1 "$out" | grep -q '^#!/bin/bash' && bash -n "$out" 2>/dev/null; then
      if [ -z "$5" ] || grep -q "$5" "$out"; then
        echo "   ✔ 已就绪: $u"; return 0
      fi
      echo -e "\033[1;33m[WARN] $u 缺指纹【$5】→ 判定旧版，换源\033[0m"
    else
      echo "[WARN] 拉取失败/语法不过，换源: $u"
    fi
    rm -f "$out"
  done
  return 1
}

# [0.5] 缓存盘余量硬预警（沿用 onekey）
DATA_DIR="${DATA_DIR:-/data}"
_dline=$(df -kP "$DATA_DIR" 2>/dev/null | sed -n 2p)
if [ -n "${_dline:-}" ]; then
  _tot=$(echo "$_dline" | awk '{print $2}'); _used=$(echo "$_dline" | awk '{print $3}'); _avail=$(echo "$_dline" | awk '{print $4}')
  _pct=$(echo "$_dline" | awk '{print $5}' | tr -d '%')
  if [ -n "${_tot:-}" ] && [ -n "${_avail:-}" ]; then
    echo "[0.5] 缓存盘检查：$DATA_DIR 总 $(( _tot / 1024 ))G / 已用 $(( _used / 1024 ))G / 可用 $(( _avail / 1024 ))G（${_pct}%）"
    _cachemb=$(du -sm "$DATA_DIR/happ" 2>/dev/null | awk '{print $1}')
    [ -n "${_cachemb:-}" ] && echo "      其中缓存占用约 ${_cachemb}MB（$DATA_DIR/happ）"
    if [ "${_avail:-0}" -lt 5120 ]; then
      echo
      echo -e "\033[1;41;37m ⚠ 缓存盘可用空间仅 ${_avail}MB（<5G）——分片存不下会导致供量偏低 \033[0m"
      echo -e "\033[1;33m   本脚本不会删你的缓存，继续执行是安全的，但跑量大概率上不去。\033[0m"
      echo
    else
      echo -e "      \033[0;32m✔ 空间充足\033[0m"
    fi
  fi
else
  echo "[0.5] 缓存盘检查：无 $DATA_DIR 目录，跳过"
fi

# =============================================================================
echo
echo -e "\033[1;36m========== [1/3] 纯调优打底（ipes_tune_only：不动身份/不重建容器） ==========\033[0m"
if [ "${SKIP_TUNE:-0}" = "1" ]; then
  echo "[1/3] SKIP_TUNE=1 → 跳过"
else
  _tf=/tmp/ipes_tune_only_fused.sh
  if fetch3 \
      "https://gh-proxy.com/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/r20-live/ipes_tune_only.sh" \
      "https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/r20-live/ipes_tune_only.sh" \
      "https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@r20-live/ipes_tune_only.sh" \
      "$_tf" 'TUNE_ONLY_REV='; then
    if bash "$_tf"; then
      echo "[1/3] 纯调优完成 ✔"
    else
      echo -e "\033[1;33m[WARN] 纯调优返回非 0（多为个别内核键不支持），继续后面步骤\033[0m"
    fi
  else
    echo -e "\033[1;33m[WARN] 三源均未取得有效 tune_only → 跳过本步（预热/对齐自带兜底调优）\033[0m"
  fi
fi

# =============================================================================
echo
echo -e "\033[1;36m========== [2/3] 预热调优 + 健康检查安装（带共存指纹闸门） ==========\033[0m"
PREHEAT_OK=0
_pf=/tmp/ipes_preheat_fused.sh
if fetch3 \
    "https://gh-proxy.com/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_preheat_and_health.sh" \
    "https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_preheat_and_health.sh" \
    "https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@main/ipes_preheat_and_health.sh" \
    "$_pf" 'OWNER: ipes_tune'; then
  if bash "$_pf"; then
    PREHEAT_OK=1; echo "[2/3] 预热脚本执行完成"
  else
    echo -e "\033[1;33m[WARN] 预热脚本返回非 0（多为个别内核键不支持，可忽略；健康拉起机制已尽力安装）\033[0m"
  fi
else
  echo -e "\033[1;33m[WARN] 未能取得带共存修复的预热脚本 → 跳过预热（对齐阶段兜底）\033[0m"
fi

# =============================================================================
echo
echo -e "\033[1;36m========== [3/3] 对齐拉满（防火墙/NAT/tc/缓存/happ/镜像/重建） ==========\033[0m"
# 预热去重：上面成功 → SKIP_PREHEAT=1；失败/跳过 → 0 让对齐兜底；显式设置则尊重用户
if [ -n "${SKIP_PREHEAT:-}" ]; then
  export SKIP_PREHEAT
elif [ "$PREHEAT_OK" = "1" ]; then
  export SKIP_PREHEAT=1
else
  export SKIP_PREHEAT=0
fi
if [ "$SKIP_PREHEAT" = "1" ]; then
  echo "[3/3] 对齐脚本内的预热步骤：跳过（本轮已在 [2/3] 完成）"
else
  echo "[3/3] 对齐脚本内的预热步骤：将兜底执行一次"
fi
_af=/tmp/ipes_align_fused.sh
if fetch3 \
    "https://gh-proxy.com/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_align_uplink.sh" \
    "https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_align_uplink.sh" \
    "https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@main/ipes_align_uplink.sh" \
    "$_af" ''; then
  bash "$_af" "$@"
else
  echo -e "\033[0;31m[ERROR] 三源均未取得对齐脚本，[3/3] 中止（前两段调优已生效）\033[0m"
fi

echo
echo -e "\033[1;42;30m ✔ 三段式融合执行完毕（调优→预热→对齐） \033[0m"

# ---------------------------------------------------------------------------
# 平台感知的放行提示：轻量服务器看「云防火墙」，ECS 看「安全组」
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

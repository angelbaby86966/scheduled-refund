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
#   TARGET_HAPP=9  TARGET_TAG=1.3.0  ALIGN_HAPP=1  FORCE_CLEAR_TC=0  SKIP_IPES=0
#
# 说明：对齐脚本第 4 步内部本就会再跑一遍预热（幂等、且带 CLEANED_FLAG 缓存加速），
#       此处先单独跑一次 preheat 是为了让「健康检查安装 / OS 调优」在第一步就落地，
#       即便后续对齐阶段因个别内核键不支持报错，健康拉起机制也已就绪。
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

echo
echo -e "\033[1;36m========== [1/2] 预热调优 + 健康检查安装 ==========\033[0m"
if curl -fsSL "$PREHEAT_URL" | bash; then
  echo "[1/2] 预热脚本执行完成"
else
  echo -e "\033[1;33m[WARN] 预热脚本返回非 0（多为个别内核键不支持，可忽略；健康拉起机制已尽力安装）\033[0m"
fi

echo
echo -e "\033[1;36m========== [2/2] 对齐拉满（防火墙/NAT/tc/缓存/happ/镜像/重建） ==========\033[0m"
# 透传参数给对齐脚本（如 --check）；对齐脚本第4步会再幂等跑一遍预热
curl -fsSL "$ALIGN_URL" | bash -s -- "$@"

echo
echo -e "\033[1;42;30m ✔ 融合脚本执行完毕 \033[0m"
echo "   若平台后台仍显示 restricted / 跑量没起来，记得做【实例级云防火墙 UDP 1-65535 放行】（脚本末尾有清单）"

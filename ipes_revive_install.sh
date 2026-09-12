#!/bin/bash
# =============================================================================
# IPES 节点自愈看护 —— 一键安装/卸载器（安装 ipes_revive.sh 并挂 crontab）
#
# 说明（2026-09-12 RCT 结论已成文）：
#   重启**不能**拉量（随机对照实验未见效果，详见报告第八节）。所以本看护只做：
#     ① 容器不在运行 / happy 进程掉线 → 自动恢复（真故障恢复，有效）
#     ② 低上行 → **只报告不动作**（避免无效重启打断正在跑的流量）
#
# 用法：
#   curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_revive_install.sh | bash
#   curl -fsSL .../ipes_revive_install.sh | bash -s -- --every 30 --th 2            # 自定义间隔/阈值
#   curl -fsSL .../ipes_revive_install.sh | bash -s -- --uninstall                 # 卸载
#   curl -fsSL .../ipes_revive_install.sh | bash -s -- --dry-run                   # 只安装脚本，不挂 crontab
#
# 安装后：
#   - 脚本本体  /usr/local/bin/ipes_revive.sh
#   - 执行日志  /var/log/ipes_revive.log
#   - 冷却状态  /var/lib/ipes_revive.state
#   - crontab   每 --every 分钟跑一次（默认 30），脚本自带冷却（默认 2h）不会反复重启
# =============================================================================
set -uo pipefail

RAW_BASE="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main"
SRC="$RAW_BASE/ipes_revive.sh"
DST="/usr/local/bin/ipes_revive.sh"
CRON_TAG="# ipes_revive (auto-installed)"
EVERY=30        # 分钟
TH=2            # 阈值 Mbps
COOL=7200       # 冷却秒
UNINST=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --every)    EVERY="${2:-30}"; shift 2 ;;
    --th)       TH="${2:-2}"; shift 2 ;;
    --cooldown) COOL="${2:-7200}"; shift 2 ;;
    --uninstall) UNINST=1; shift ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

say(){ echo "[$(date '+%F %T')] $*"; }

# ---------- 卸载 ----------
if [ "$UNINST" = "1" ]; then
  say "卸载 crontab 条目..."
  ( crontab -l 2>/dev/null | grep -v 'ipes_revive' ) | crontab - 2>/dev/null || true
  # 兜底：若系统用 /etc/cron.d
  rm -f /etc/cron.d/ipes_revive 2>/dev/null || true
  say "删除脚本本体（保留日志与状态文件，便于回溯）"
  rm -f "$DST"
  say "已卸载。日志仍保留在 /var/log/ipes_revive.log"
  exit 0
fi

# ---------- 前置 ----------
[ "$(id -u)" = "0" ] || { echo "✗ 需要 root（实例级云助手默认就是 root）"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "✗ 缺少 curl"; exit 1; }

# ---------- 1. 下载脚本本体 ----------
say "下载 ipes_revive.sh ..."
if ! curl -fsSL --max-time 60 "$SRC" -o "$DST"; then
  echo "✗ 下载失败（检查 ghproxy 通道）"; exit 1
fi
chmod 755 "$DST"
if ! bash -n "$DST"; then
  echo "✗ 下载到的脚本语法校验失败，已中断（不安装坏脚本）"; rm -f "$DST"; exit 1
fi
say "已安装: $DST ($(wc -c < "$DST") B)"

# 开机也放一份（供 rc.local / 手工调用）
if [ -d /etc/rc.d ]; then cp -f "$DST" /etc/rc.d/ipes_revive.sh 2>/dev/null || true; fi

# ---------- 2. 挂 crontab ----------
if [ "$DRY" = "1" ]; then
  say "--dry-run：已跳过 crontab 安装"
  say "手工跑一次（只看判定）： DRY_RUN=1 bash $DST $TH 60 $COOL"
  exit 0
fi

# 每 N 分钟：0,30 * * * *（N>=60 时退化为每小时一次）
case "$EVERY" in
  ''|*[!0-9]*) echo "✗ --every 必须是正整数（分钟）"; exit 1 ;;
esac
if [ "$EVERY" -lt 1 ]; then echo "✗ --every 最小 1 分钟"; exit 1; fi
if [ "$EVERY" -ge 60 ]; then
  [ "$EVERY" -ne 60 ] && say "⚠️ --every $EVERY ≥60，已按「每小时一次」处理"
  CRON_SPEC="0 * * * *"
else
  STEPS=""
  for ((m=0; m<60; m+=EVERY)); do STEPS="${STEPS:+$STEPS,}$m"; done
  CRON_SPEC="$STEPS * * * *"
fi
CRON_LINE="$CRON_SPEC /bin/bash $DST $TH 60 $COOL >> /var/log/ipes_revive.log 2>&1 $CRON_TAG"

# 清理旧条目后写入（幂等）
if crontab -l >/dev/null 2>&1; then
  CURRENT="$(crontab -l 2>/dev/null | grep -v 'ipes_revive')"
else
  CURRENT=""
fi
printf '%s\n%s\n' "$CURRENT" "$CRON_LINE" | sed '/^$/d' | crontab -
say "crontab 已写入："
crontab -l 2>/dev/null | grep 'ipes_revive' | sed 's/^/    /'

# ---------- 3. 自检（空跑一次判定，不重启） ----------
say "自检：DRY_RUN 跑一次判定（不会重启）..."
DRY_RUN=1 bash "$DST" "$TH" 20 "$COOL" 2>&1 | sed 's/^/    /'

echo
say "✅ 安装完成"
echo "    脚本   : $DST"
echo "    日志   : tail -f /var/log/ipes_revive.log"
echo "    手动跑 : bash $DST $TH 60 $COOL"
echo "    只看判定: DRY_RUN=1 bash $DST"
echo "    卸载   : bash $DST --uninstall 2>/dev/null || rm -f $DST; crontab -l | grep -v ipes_revive | crontab -"

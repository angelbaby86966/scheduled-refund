#!/bin/bash
# =============================================================================
# IPES 上行"趴着自动唤醒"（低跑量自愈）
#
# 背景（2026-09-12 实测）：
#   杭州 10 台节点 tc 全量清查无任何限速，但同一时刻固定只有约 5 台在跑、其余趴在 1~2 Mbps。
#   对趴着的机器执行「强制重注册」（docker restart ipes，不重建容器 → SN 不变、缓存不丢），
#   两次独立实验均在 2 分钟内把上行从 ~1 Mbps 拉到 15~27 Mbps（pps 同步从 ~25 涨到 ~70~160）。
#   → 本机唯一可控的"拉量"手段就是强制重注册（重启上报/注册链路，让平台重新派量）。
#
# 本脚本：检测长期低上行 → 自动执行一次强制重注册，带冷却与执行记录。
#
# 用法：
#   bash ipes_revive.sh                # 默认：阈值 2 Mbps / 采样 60s / 冷却 2 小时
#   bash ipes_revive.sh 3 60 3600      # 阈值 3Mbps，采样 60s，冷却 1 小时
#   DRY_RUN=1 bash ipes_revive.sh      # 只看判定，不真重启
#
# 建议：配 crontab 每 30 分钟跑一次（脚本自身有冷却，不会反复重启）
#   0,30 * * * * /bin/bash /usr/local/bin/ipes_revive.sh >> /var/log/ipes_revive.log 2>&1
# =============================================================================
set -uo pipefail

TH=${1:-2}            # 判定阈值（Mbps）：低于它视为"趴着"
WIN=${2:-60}          # 采样窗口（秒）
COOLDOWN=${3:-7200}   # 冷却（秒）：距上次唤醒不足此时长则跳过
DRY_RUN=${DRY_RUN:-0}
IFACE=${IFACE:-eth0}
STATE=/var/lib/ipes_revive.state
LOGF=/var/log/ipes_revive.log

ts(){ date '+%F %T'; }
say(){ echo "[$(ts)] $*"; }

[ -d /var/lib ] || mkdir -p /var/lib

# ---------- 1. 采样当前上行 ----------
t1=$(cat /sys/class/net/$IFACE/statistics/tx_bytes 2>/dev/null) || { say "FATAL: 无网卡 $IFACE"; exit 2; }
u1=$(awk -F'[: ]+' '/^Udp:/{print $2}' /proc/net/snmp | tail -1); n1=$(date +%s%N)
sleep "$WIN"
t2=$(cat /sys/class/net/$IFACE/statistics/tx_bytes)
u2=$(awk -F'[: ]+' '/^Udp:/{print $2}' /proc/net/snmp | tail -1); n2=$(date +%s%N)

read UP PPS RATE <<<"$(awk -v t1="$t1" -v t2="$t2" -v u1="$u1" -v u2="$u2" -v n1="$n1" -v n2="$n2" 'BEGIN{
  dt=(n2-n1)/1e9;
  up=(t2-t1)*8/dt/1e6; pps=(u2-u1)/dt;
  printf "%.2f %.1f %.3f", up, pps, (t2-t1)/dt;
}')"

say "当前上行 ${UP} Mbps | 入向UDP ${PPS} pps | ${RATE} B/s | 阈值 ${TH} Mbps"

# ---------- 2. 判定 ----------
if awk -v u="$UP" -v t="$TH" 'BEGIN{exit !(u>=t)}'; then
  say "上行正常（≥ ${TH} Mbps），无需干预"
  exit 0
fi
say "⚠️ 上行低于阈值（${UP} < ${TH} Mbps）—— 判定为趴着"

# ---------- 3. 冷却检查 ----------
now=$(date +%s)
if [ -f "$STATE" ]; then
  last=$(cat "$STATE" 2>/dev/null | head -1)
  case "$last" in
    ''|*[!0-9]*) last=0 ;;
  esac
  elapsed=$(( now - last ))
  if [ "$elapsed" -lt "$COOLDOWN" ]; then
    say "距上次唤醒仅 ${elapsed}s（冷却 ${COOLDOWN}s），本次跳过"
    exit 0
  fi
fi

# ---------- 4. 前置检查 ----------
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ipes; then
  say "IPES 容器不在运行，改走 docker start（保 SN、保缓存）"
  [ "$DRY_RUN" = "1" ] && { say "DRY_RUN：跳过 docker start"; exit 0; }
  docker start ipes >/dev/null 2>&1 && say "已 docker start ipes"
  echo "$now" > "$STATE"; exit 0
fi

# ---------- 5. 强制重注册（不重建容器 → SN 不变、/data 缓存不丢） ----------
if [ "$DRY_RUN" = "1" ]; then
  say "DRY_RUN：本应执行 docker restart ipes（未执行）"
  exit 0
fi

say "执行强制重注册：docker restart ipes（不重建容器 → SN 不变、缓存不丢）"
echo "$now" > "$STATE"
if docker restart ipes >/dev/null 2>&1; then
  say "已重启。等待服务恢复（约 3~5 分钟）..."
  for i in $(seq 1 30); do
    sleep 20
    h=$(docker exec ipes ./bin/ipes health 2>/dev/null | grep -oE 'happ:[0-9]+/[0-9]+' | head -1)
    if [ -n "$h" ]; then say "服务已就绪（$h），第 $((i*20))s"; break; fi
    [ "$i" = "30" ] && say "⚠️ 10 分钟内未探到 happ，请人工检查"
  done
  sleep 30
  t3=$(cat /sys/class/net/$IFACE/statistics/tx_bytes); n3=$(date +%s%N)
  sleep 20
  t4=$(cat /sys/class/net/$IFACE/statistics/tx_bytes); n4=$(date +%s%N)
  a=$(awk -v a="$t3" -v b="$t4" -v c="$n3" -v d="$n4" 'BEGIN{printf "%.2f",(b-a)*8/((d-c)/1e9)/1e6}')
  say "重启后上行复测: ${a} Mbps（重启前 ${UP} Mbps）"
else
  say "❌ docker restart 失败，请人工检查"
  exit 1
fi

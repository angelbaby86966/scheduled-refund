#!/bin/bash
# =============================================================================
# IPES 节点自愈（容器/健康恢复 + 低上行排查）
#
# 🔴 定位更正（2026-09-12 随机对照实验 RCT 结论，务必先读）：
#   本脚本最初假设"低上行 → 强制重注册能拉量"。当晚用 6 台克隆机做随机分组对照
#   （3 台重启 vs 3 台不干预，各采样 基线/T+3/T+7/T+12）后**该假设未被证实，方向甚至相反**：
#     · 干预组 3 时点均值 8.50 Mbps  <  未干预组 18.51 Mbps
#     · 未干预的 gbhm 自行从 5.9 → 55.1 Mbps（说明"起来"根本不需要重启）
#     · 原本健康的 mcnu(24→0.13)、wqpc(29→15) 重启后反而掉
#   → 真正的驱动因素是**平台派量轮换 + 均值回归**。详见
#     aliyun-node-manager/跑量瓶颈排查-20260912.md 第八节。
#
#   所以本脚本现在只做两件有依据的事：
#     ① 【默认】容器/进程异常 → 恢复（docker start / restart）—— 真故障恢复，有价值
#     ② 【默认】低上行 → **只报告不动作**（因为重启无拉量效果，还会打断正在跑的流量）
#        确需对低上行强制执行重启：显式加 REVIVE_ON_LOW=1
#
# 用法：
#   bash ipes_revive.sh                  # 默认：异常恢复 + 低上行只报告
#   bash ipes_revive.sh 2 60 7200        # 阈值 2Mbps / 采样 60s / 冷却 2h
#   DRY_RUN=1 bash ipes_revive.sh        # 只看判定，不真重启
#   REVIVE_ON_LOW=1 bash ipes_revive.sh  # 对低上行也强制重启（已证无拉量效果，谨慎）
#
# 建议：配 crontab 每 30 分钟跑一次（脚本自身有冷却，不会反复重启）
#   0,30 * * * * /bin/bash /usr/local/bin/ipes_revive.sh >> /var/log/ipes_revive.log 2>&1
# =============================================================================
set -uo pipefail

TH=${1:-2}            # 判定阈值（Mbps）：低于它视为"趴着"
WIN=${2:-60}          # 采样窗口（秒）
COOLDOWN=${3:-7200}   # 冷却（秒）：距上次唤醒不足此时长则跳过
DRY_RUN=${DRY_RUN:-0}
REVIVE_ON_LOW=${REVIVE_ON_LOW:-0}   # 1=低上行也重启（RCT 未证实有效，默认关闭）
IFACE=${IFACE:-eth0}
STATE=/var/lib/ipes_revive.state
LOGF=/var/log/ipes_revive.log

ts(){ date '+%F %T'; }
say(){ echo "[$(ts)] $*"; }

[ -d /var/lib ] || mkdir -p /var/lib

# ---------- 0. 先做真故障检查（容器/健康）—— 这类重启才是有效的 ----------
do_restart(){
  local why="$1"
  now=$(date +%s)
  if [ "$DRY_RUN" = "1" ]; then say "DRY_RUN：本应重启（原因：$why），未执行"; return 0; fi
  say "执行恢复重启（原因：$why）—— docker restart ipes，不重建容器 → SN 不变、缓存不丢"
  echo "$now" > "$STATE"
  if docker restart ipes >/dev/null 2>&1; then
    say "已重启，等待服务恢复（约 3~5 分钟）..."
    for i in $(seq 1 30); do
      sleep 20
      h=$(docker exec ipes ./bin/ipes health 2>/dev/null | grep -oE 'happ:[0-9]+/[0-9]+' | head -1)
      if [ -n "$h" ]; then say "服务已就绪（$h），第 $((i*20))s"; break; fi
      [ "$i" = "30" ] && say "⚠️ 10 分钟内未探到 happ，请人工检查"
    done
  else
    say "❌ docker restart 失败，请人工检查"; return 1
  fi
  return 0
}

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ipes; then
  say "⚠️ IPES 容器不在运行 —— 真故障，执行 docker start（保 SN、保缓存）"
  if [ "$DRY_RUN" = "1" ]; then say "DRY_RUN：跳过 docker start"; else docker start ipes >/dev/null 2>&1 && say "已 docker start ipes"; date +%s > "$STATE"; fi
  exit 0
fi

HEALTH_OUT=$(docker exec ipes ./bin/ipes health 2>/dev/null | tr '\n' ' ')
HAPP=$(echo "$HEALTH_OUT" | grep -oE 'happ:[0-9]+/[0-9]+' | head -1)
if [ -n "$HAPP" ]; then
  _cur=${HAPP#happ:}; _cur=${_cur%%/*}; _exp=${HAPP##*/}
  if [ "${_cur:-0}" -lt "${_exp:-0}" ]; then
    say "⚠️ happy 进程不足（$HAPP）—— 真故障，执行恢复重启"
    do_restart "happ ${_cur}/${_exp} 掉线"; exit 0
  fi
fi

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

# ---------- 2. 低上行：默认只报告（RCT 已证重启不能拉量） ----------
if [ "$REVIVE_ON_LOW" != "1" ]; then
  say "结论：低上行 ≠ 本机故障。按 RCT 结论（重启无拉量效果，还会打断在跑的流量），默认【不动作】。"
  say "       真正的驱动因素是平台派量轮换 → 要提升总量需找平台商务（派量策略/带宽档位/业务线）。"
  say "       如仍要强制重启试试：REVIVE_ON_LOW=1 bash $0 $TH $WIN $COOLDOWN"
  exit 0
fi

say "⚠️ REVIVE_ON_LOW=1：对低上行执行强制重启（注意：已证对跑量无效）"

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

# ---------- 4. 执行重启（复用 do_restart） ----------
do_restart "REVIVE_ON_LOW=1 且上行 ${UP} < ${TH} Mbps"
rc=$?
if [ "$rc" = "0" ] && [ "$DRY_RUN" != "1" ]; then
  t3=$(cat /sys/class/net/$IFACE/statistics/tx_bytes); n3=$(date +%s%N)
  sleep 20
  t4=$(cat /sys/class/net/$IFACE/statistics/tx_bytes); n4=$(date +%s%N)
  a=$(awk -v a="$t3" -v b="$t4" -v c="$n3" -v d="$n4" 'BEGIN{printf "%.2f",(b-a)*8/((d-c)/1e9)/1e6}')
  say "重启后上行复测: ${a} Mbps（重启前 ${UP} Mbps）—— 注意：单次涨落受平台轮换影响，不能作为效果依据"
fi
exit $rc

#!/bin/bash
# =============================================================================
# run_limit_v2.sh —— 分时段宽带限速脚本（自包含，单文件）
#
# 设计目标（按需求）：
#   窗口1  14:00 - 16:40   上行限速 4m (4096 Kbps)，下行不限速
#   窗口2  16:40 - 18:30   上行限速 0.01m (10 Kbps)，下行限速 0m（完全阻断）
#   其它时段（18:31 - 次日 14:00）上下行完全不限速
#
# 用法：
#   bash run_limit_v2.sh            # 按当前时间自动套用对应窗口（或解除）
#   bash run_limit_v2.sh clear      # 立即解除所有限速（上下行恢复不限速）
#   bash run_limit_v2.sh status     # 查看当前 tc 规则
#
# 通过 curl 首次运行时，建议先落到文件再执行，以便 cron 持久调度：
#   curl -fsSL <URL> | tr -d '\r' > /tmp/limit_start_v2.sh && bash /tmp/limit_start_v2.sh
# 脚本会自动把自身保存到 /tmp/limit_start_v2.sh 并由 cron 调用，不依赖任何外部文件。
# =============================================================================

SELF_SAVED="/tmp/limit_start_v2.sh"
LOG_FILE="/var/log/set_rate_limit_v2.log"
CONFIG_FILE="/tmp/rate_limit_v2.conf"
PID_FILE="/tmp/.rate_limit_v2.lock"

TC="/sbin/tc"; [ -x /usr/sbin/tc ] && TC="/usr/sbin/tc"
IP="/usr/sbin/ip"

# ===== 限速时段与速率配置（上行单位 Kbps；下行：unlimited=不限速 / block=完全阻断）=====
W1_START="14:00"; W1_END="16:40"; W1_UP=4096; W1_DOWN="unlimited"
W2_START="16:40"; W2_END="18:30"; W2_UP=10;   W2_DOWN="block"
CLEAR_TIME="18:31"   # 18:31 起强制解除限速（窗口2 含 18:30 整点）

# -----------------------------------------------------------------------------
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

exec 200>"$PID_FILE"
flock -n 200 || { log "已有另一个实例在运行"; exit 1; }
trap "flock -u 200; exit" INT TERM EXIT

hm_num() { echo $(( 10#${1%%:*} * 100 + 10#${1#*:} )); }

# 脚本自落盘：若不是从 SELF_SAVED 运行，则复制自身后重新执行（保证 cron 有稳定路径）
if [ "$(readlink -f "$0" 2>/dev/null)" != "$SELF_SAVED" ]; then
  if [ "${_SELF_SAVED_DONE:-false}" = "true" ]; then
    log "已落盘过，防止循环，退出"; exit 1
  fi
  if cp "$0" "$SELF_SAVED" 2>/dev/null; then
    chmod +x "$SELF_SAVED"
    log "脚本已落到 $SELF_SAVED，重新执行"
    export _SELF_SAVED_DONE=true
    exec "$SELF_SAVED" "$@"
  else
    log "无法落盘到 $SELF_SAVED（可能是纯管道执行），继续本次运行（cron 不持久）"
  fi
fi

# -----------------------------------------------------------------------------
# 获取需要限速的网卡（排除 lo/docker/br/veth/tun/ifb 及带 @ / : / . 的虚拟接口）
get_up_interfaces() {
  local static_ppp all intf out=""
  static_ppp=$(/usr/sbin/ip link show 2>/dev/null | awk -F': ' '$2 ~ /(static|ppp)/ {print $2}' | sed 's/^[ \t]*//; s/[ \t]*$//')
  if [ -n "$static_ppp" ] && ! echo "$static_ppp" | grep -q '@'; then
    while IFS= read -r intf; do
      case "$intf" in
        ifb_*|lo|docker*|virbr*|br_*|tun*|veth*) continue;;
        *) out="${out}${intf}"$'\n';;
      esac
    done <<< "$static_ppp"
    if [ -n "$out" ]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  all=$(/usr/sbin/ip link show 2>/dev/null | awk -F': ' '$0 !~ "lo|DOWN" && $0 ~ "state UP" {print $2}')
  while IFS= read -r intf; do
    case "$intf" in
      *@*|*:*|*.*|ifb_*|lo|docker*|virbr*|br_*|tun*|veth*) continue;;
      *) echo "$intf";;
    esac
  done <<< "$all"
}

# -----------------------------------------------------------------------------
clear_iface() {
  local intf="$1"
  $TC qdisc del dev "$intf" root    2>/dev/null
  $TC qdisc del dev "$intf" ingress 2>/dev/null
  $TC qdisc del dev "$intf" clsact  2>/dev/null
}
clear_all() {
  local intf
  for intf in $interfaces; do clear_iface "$intf"; done
  if $TC qdisc show dev ifb0 2>/dev/null | grep -q 'qdisc'; then
    $TC qdisc del dev ifb0 root    2>/dev/null
    $TC qdisc del dev ifb0 ingress 2>/dev/null
    $TC qdisc del dev ifb0 clsact  2>/dev/null
  fi
}

# 设置上行限速（egress HTB，单位 Kbps）—— 精简版 wondershaper uplink
set_egress() {
  local intf="$1" uspeed="$2"
  $TC qdisc add dev "$intf" root handle 1: htb default 20
  $TC class add dev "$intf" parent 1: classid 1:1 htb rate "${uspeed}kbit" prio 5
  local r
  r=$((20*uspeed/100)); [ "$r" -eq 0 ] && r=1
  $TC class add dev "$intf" parent 1:1 classid 1:10 htb rate "${r}kbit" ceil $((95*uspeed/100))kbit prio 1
  r=$((40*uspeed/100)); [ "$r" -eq 0 ] && r=1
  $TC class add dev "$intf" parent 1:1 classid 1:20 htb rate "${r}kbit" ceil $((95*uspeed/100))kbit prio 2
  r=$((20*uspeed/100)); [ "$r" -eq 0 ] && r=1
  $TC class add dev "$intf" parent 1:1 classid 1:30 htb rate "${r}kbit" ceil $((90*uspeed/100))kbit prio 3
  $TC qdisc add dev "$intf" parent 1:10 handle 10: sfq perturb 10 quantum 6000
  $TC qdisc add dev "$intf" parent 1:20 handle 20: sfq perturb 10 quantum 6000
  $TC qdisc add dev "$intf" parent 1:30 handle 30: sfq perturb 10 quantum 6000
  $TC filter add dev "$intf" parent 1: protocol ip prio 10 u32 match ip tos 0x10 0xff flowid 1:10
  $TC filter add dev "$intf" parent 1: protocol ip prio 11 u32 match ip protocol 1 0xff flowid 1:10
  $TC filter add dev "$intf" parent 1: protocol ip prio 18 u32 match ip dst 0.0.0.0/0 flowid 1:20
}

# 下行完全阻断（ingress 丢弃全部入向包）
set_ingress_block() {
  local intf="$1"
  $TC qdisc add dev "$intf" ingress
  $TC filter add dev "$intf" parent ffff: protocol ip u32 match u32 0 0 action drop
}

# -----------------------------------------------------------------------------
apply_profile() {
  local profile="$1"
  clear_all
  for intf in $interfaces; do
    case "$profile" in
      W1)
        log "网卡 $intf：上行 ${W1_UP}Kbps(4m)，下行不限速"
        set_egress "$intf" "$W1_UP"
        ;;
      W2)
        log "网卡 $intf：上行 ${W2_UP}Kbps(0.01m)，下行阻断(0m)"
        set_egress "$intf" "$W2_UP"
        set_ingress_block "$intf"
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
update_crontab() {
  local w1h=$((10#${W1_START%%:*})) w1m=$((10#${W1_START#*:}))
  local w2h=$((10#${W2_START%%:*})) w2m=$((10#${W2_START#*:}))
  local e2h=$((10#${W2_END%%:*}))   e2m=$((10#${W2_END#*:}))
  local ch=$((10#${CLEAR_TIME%%:*})) cm=$((10#${CLEAR_TIME#*:}))

  local cron_reboot="@reboot sleep 180 && $SELF_SAVED"
  local cron_w1="$w1m $w1h * * * $SELF_SAVED"            # 14:00 套用窗口1
  local cron_w2="$w2m $w2h * * * $SELF_SAVED"            # 16:40 套用窗口2
  local cron_end="$cm $ch * * * $SELF_SAVED clear"        # 18:31 强制解除（窗口2 含 18:30）
  local cron_keep="*/10 ${w1h}-${e2h} * * * $SELF_SAVED" # 窗口内每10分自愈重放

  log "更新定时任务：窗口1 $W1_START-$W1_END / 窗口2 $W2_START-$W2_END / 其余不限速"

  local existing
  existing=$(crontab -l 2>/dev/null | grep -vE 'limit_start_v2.sh')
  {
    [ -n "$existing" ] && echo "$existing"
    echo "$cron_reboot"
    echo "$cron_w1"
    echo "$cron_w2"
    echo "$cron_end"
    echo "$cron_keep"
  } > /tmp/new_cron_v2

  if crontab /tmp/new_cron_v2; then
    log "✅ 定时任务已更新"
  else
    log "❌ 更新 cron 失败"
    rm -f /tmp/new_cron_v2
    exit 1
  fi
  rm -f /tmp/new_cron_v2
  echo "START=\"$W1_START\"" >  "$CONFIG_FILE"
  echo "END=\"$W2_END\""     >> "$CONFIG_FILE"
}

# -----------------------------------------------------------------------------
main() {
  interfaces=$(get_up_interfaces)
  if [ -z "$interfaces" ]; then log "未找到可用网卡，退出"; exit 1; fi

  if [ "${1:-}" = "clear" ]; then
    clear_all; log "已强制解除全部限速"; return 0
  fi
  if [ "${1:-}" = "status" ]; then
    for intf in $interfaces; do echo "== $intf =="; $TC -s qdisc show dev "$intf"; done
    return 0
  fi

  update_crontab

  local now w1s w1e w2s w2e
  now=$((10#$(date +%H%M)))
  w1s=$(hm_num "$W1_START"); w1e=$(hm_num "$W1_END")
  w2s=$(hm_num "$W2_START"); w2e=$(hm_num "$W2_END")

  if   [ "$now" -ge "$w1s" ] && [ "$now" -lt "$w1e" ]; then
    log "当前处于窗口1 ($W1_START-$W1_END)"; apply_profile W1
  elif [ "$now" -ge "$w2s" ] && [ "$now" -le "$w2e" ]; then
    log "当前处于窗口2 ($W2_START-$W2_END)"; apply_profile W2
  else
    log "当前不在限速时段，解除全部限速（上下行不限速）"; clear_all
  fi
}

main "$@"
exit 0

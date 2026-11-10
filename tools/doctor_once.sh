#!/usr/bin/env bash
# =============================================================================
# doctor_once.sh —— Q2 业务「docker / ipes」单次暂停脚本（不装 cron、不常驻）
#
# 口径：用户口语里的 "doctor" = docker。本脚本只暂停 Q2 的 ipes 容器，
#       其余一律不动：不删容器、不碰 SN / 9 路 / 缓存 / 镜像 / 限速 / 其它 cron 行。
#
# 用法（部署完 bindfirst 之后执行）：
#   curl -fsSL '<URL>' | bash                     # 暂停（默认动作）
#   curl -fsSL '<URL>' | bash -s -- resume       # 恢复业务（同一个 URL）
#   curl -fsSL '<URL>' | bash -s -- status       # 只读查看当前状态
#
# 为什么还要挂起保活：/usr/local/bin/ipes_health_check.sh 每分钟跑一次，
#   容器不在就 docker start、探测异常就 docker restart ipes。只 docker pause
#   会在一分钟内被它重启掉。所以暂停时给「保活那一行」加 # DOCTOR_HOLD 前缀，
#   恢复时去掉。限速 / @reboot 等其它 cron 行逐字保留。
#
# 特点：执行一次就结束，不留定时任务、不留后台进程、不留守护；
#       pause 与 resume 都幂等，重复执行不会叠加。
#       不需要任何 AK/SK/JWT，不调用任何云 API。
#
# 注意：暂停期间平台侧仍显示「服务中」（不改 stateflow）。
#       恢复后 /var/lib/doctor-once/ 下的备份与状态会自动清理。
# =============================================================================
set -u

ACTION="${1:-pause}"
C="ipes"
HOLD="# DOCTOR_HOLD "
STATE_DIR="/var/lib/doctor-once"
LOG="/var/log/doctor_once.log"

# 非 root 环境可能写不了 /var，回退到 /tmp；路径回退后状态/备份要跟着重算
mkdir -p "$STATE_DIR" 2>/dev/null || { STATE_DIR="/tmp/doctor-once"; mkdir -p "$STATE_DIR" 2>/dev/null || true; }
STATE="$STATE_DIR/state"
BAK="$STATE_DIR/crontab.before"
if ! touch "$LOG" >/dev/null 2>&1; then
  LOG="/tmp/doctor_once.log"
  touch "$LOG" >/dev/null 2>&1 || LOG="/dev/null"
fi

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

cron_get() { crontab -l 2>/dev/null || true; }
cron_set() { crontab - 2>/dev/null; }
held_cnt()  { cron_get | grep -cF "$HOLD" || true; }
live_cnt()  { cron_get | grep -cE '^[^#].*(ipes_health_check|health_check\.sh)' || true; }
limit_cnt() { cron_get | grep -cE 'limit_start|clear_limit' || true; }
window_cnt(){ cron_get | grep -c 'DOCTOR_WINDOW' || true; }

# 先完整读出 crontab 再回写，避免边读边写同一个 spool 被截断
hold_health() {
  local cur; cur="$(cron_get)"
  printf '%s\n' "$cur" | awk -v h="$HOLD" '
    /ipes_health_check|health_check\.sh/ && index($0,h)!=1 { print h $0; next }
    { print }
  ' | cron_set
}
release_health() {
  local cur; cur="$(cron_get)"
  printf '%s\n' "$cur" | sed 's/^# DOCTOR_HOLD //' | cron_set
}

is_paused()  { docker inspect -f '{{.State.Paused}}' "$C" 2>/dev/null | grep -qi true; }
is_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$C"; }
container_exists() { docker inspect "$C" >/dev/null 2>&1; }
deploy_running() {
  pgrep -f 'q2_oneclick_v5_pure_fast|ecache_.*install|docker pull|install_docker' >/dev/null 2>&1
}

# ---------- 部署完成度检查（部署完再暂停，别打断部署） ----------
precheck() {
  if ! command -v docker >/dev/null 2>&1; then
    log "✗ 本机没有 docker，跳过（这不是 Q2 业务机或部署未完成）"; return 1
  fi
  if deploy_running; then
    log "✗ 检测到部署脚本仍在运行，请先等部署跑完（看到「✅ 全部完成」）再执行本脚本"; return 1
  fi
  if ! container_exists; then
    log "✗ 未找到 ipes 容器，部署尚未完成，本次不动作"; return 1
  fi
  if ! is_running; then
    log "✗ ipes 容器存在但未运行，请先排查部署结果，本次不动作"; return 1
  fi
  return 0
}

# ---------- 暂停（默认动作） ----------
do_pause() {
  log "===== 单次暂停 doctor（docker/ipes）开始 ====="
  precheck || { log "===== 未执行暂停 ====="; return 1; }

  # 暂停前读一次，作为「部署完成 + SN 保留」的证据（pause 后 docker exec 不可用）
  local snlen; snlen=$(docker exec "$C" cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n' | wc -c | tr -d ' ')
  local happ; happ=$(docker exec "$C" sh -c 'ps -ef 2>/dev/null | grep -c "[h]app:vod"' 2>/dev/null | tr -d '\r\n')
  log "  暂停前: SN=${snlen} 字节  happ:vod=${happ:-0} 路"
  [ "${snlen:-0}" -lt 60 ] && log "  ⚠️ SN 偏短，部署可能未做完 2.5 回填；如确认无需回填可继续"

  if is_paused; then
    log "  容器已是 paused → 只补齐保活挂起，不重复操作（幂等）"
    if [ "$(live_cnt)" != "0" ]; then hold_health; fi
    show_state; log "===== 已处于暂停状态 ====="; return 0
  fi

  # 备份原 crontab（一次性，供恢复/回滚兜底）
  cron_get > "$BAK" 2>/dev/null || true
  hold_health
  log "  已挂起保活 cron（${HOLD}前缀，共 $(held_cnt) 行）；限速 cron 仍 $(limit_cnt) 行，@reboot 等其它行原样保留"

  if docker pause "$C" >>"$LOG" 2>&1; then
    log "  ✅ docker pause ${C} 完成：容器不重启，SN/9路/缓存/镜像全不动"
  else
    log "  ✗ docker pause 失败，正在回滚保活 cron"; release_health; return 1
  fi
  printf 'PAUSED_AT=%s\nACTION=pause\n' "$(date '+%F %T')" > "$STATE"
  show_state
  log "===== 暂停完成（本脚本到此结束，无 cron、无后台进程）====="
  log "  恢复: 同一条 curl 命令末尾加 ' -s -- resume' 即可；存成文件则 bash 文件名 resume"
  [ "$(window_cnt)" != "0" ] && log "  ⚠️ 检测到定时窗口脚本(DOCTOR_WINDOW cron)，它的 18:20 兜底会把本次暂停恢复，需要长期暂停请先卸载定时版"
  return 0
}

# ---------- 恢复 ----------
do_resume() {
  log "===== 单次恢复 doctor（docker/ipes）开始 ====="
  if ! command -v docker >/dev/null 2>&1; then log "✗ 无 docker，退出"; return 1; fi
  if is_paused; then
    if docker unpause "$C" >>"$LOG" 2>&1; then log "  ✅ docker unpause ${C}（容器不重启，SN/9路/缓存零变化）"
    else log "  ✗ unpause 失败，请手工检查"; return 1; fi
  elif ! is_running; then
    container_exists && docker start "$C" >>"$LOG" 2>&1 && log "  ✅ docker start ${C}"
  else
    log "  容器本就在运行，无需拉起（幂等）"
  fi
  release_health
  log "  ✅ 保活 cron 已恢复在岗（$(live_cnt) 行）；限速 cron 仍 $(limit_cnt) 行"
  rm -f "$STATE" "$BAK"
  show_state
  log "===== 恢复完成，状态与备份已清理 ====="
  return 0
}

# ---------- 只读状态 ----------
show_state() {
  log "  ---- 当前状态 ----"
  log "  容器      : $(docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | grep "^${C} " || echo '不存在')"
  log "  paused    : $(docker inspect -f '{{.State.Paused}}' "$C" 2>/dev/null || echo '?')"
  log "  保活cron  : 在岗 $(live_cnt) 行 / 挂起 $(held_cnt) 行"
  log "  限速cron  : $(limit_cnt) 行   定时窗口cron: $(window_cnt) 行"
  log "  状态文件  : $([ -f "$STATE" ] && tr '\n' ' ' < "$STATE" || echo 无)"
}
do_status() { log "===== doctor 单次脚本 只读状态 ====="; precheck >/dev/null 2>&1 || true; show_state; log "===== 未改动任何东西 ====="; }

case "$ACTION" in
  pause|"")  do_pause ;;
  resume)    do_resume ;;
  status)    do_status ;;
  *) log "未知动作: ${ACTION}（只支持 pause / resume / status）"; exit 1 ;;
esac

#!/usr/bin/env bash
# =============================================================================
# doctor_window.sh —— Q2 业务「docker / ipes」定时暂停窗口
#
# 口径：历史会话里用户把 docker 称作 "doctor"，本脚本只针对 Q2 的 ipes 容器
#       / docker 服务，不碰容器配置、不删容器、不碰 SN、不碰 9 路、不碰镜像、
#       不改限速 cron、不改 crontab 里任何其它行。
#
# 窗口（北京时间，每天）：16:45 暂停 → 18:25 恢复
#   · 16:45  suspend : 挂起保活 cron + 冻结/停掉业务
#   · 18:25  resume  : 恢复保活 cron + 恢复业务 + 清状态（与清限速同一分钟，互不影响）
#   · 每 5 分钟 watchdog：窗口外发现没恢复就兜底恢复；窗口内发现冻结被
#     部署脚本/重启破坏就补冻结（防止「停了就再也没起来」）
#
# 三种模式（--mode=，默认 pause）：
#   pause  = docker pause ipes    只冻结容器进程，daemon/其它容器/配置全不动；
#                                 恢复用 unpause，容器不重启、SN/9路/缓存零变化（推荐）
#   stop   = docker stop ipes     停容器但不删，恢复 docker start；断流 30-60s
#   daemon = systemctl stop docker 彻底停 docker 服务，恢复 systemctl start docker
#                                 （会连带重启容器，仅在确实要停服务时用）
#
# 用法：
#   # 第一次下发（把本文件落到机器后执行一次，装好 cron 即生效）
#   bash doctor_window.sh install                # 默认 pause 模式
#   bash doctor_window.sh install --mode=stop
#   bash doctor_window.sh --probe                # 只读体检，不改任何东西
#   bash doctor_window.sh --dry-run              # 打印将要做的动作
#   bash doctor_window.sh uninstall              # 卸载：恢复业务 + 删自己的 3 条 cron
#
# 手动触发（应急）：doctor_window_ctl.sh suspend / resume / watchdog
# 日志：/var/log/doctor_window.log    状态：/var/lib/doctor-window/state
#
# 依赖：bash / docker / crontab / systemctl（可选）。不需要任何 AK/SK/JWT。
# =============================================================================
set -u

BIN="${DOCTOR_BIN:-/usr/local/bin/doctor_window_ctl.sh}"
STATE_DIR="${DOCTOR_STATE_DIR:-/var/lib/doctor-window}"
STATE="$STATE_DIR/state"
LOG="${DOCTOR_LOG:-/var/log/doctor_window.log}"
MODE="${DOCTOR_MODE:-pause}"
START_BJ="${DOCTOR_START:-16:45}"      # 北京时间，暂停
END_BJ="${DOCTOR_END:-18:25}"          # 北京时间，恢复（与 clear_limit.sh 清限速同分钟）
MARK="DOCTOR_WINDOW"
HOLD="# DOCTOR_HOLD "
C="ipes"

mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR=/tmp/doctor-window
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

# 安装时持久化的配置：cron 调用执行器时不带参数，也要沿用同一 mode / 窗口。
# 优先级：命令行 --mode > 环境变量 DOCTOR_MODE > 已安装配置 > 默认 pause
CFG="$STATE_DIR/config"
if [ -f "$CFG" ]; then
  set +u; . "$CFG"; set -u
  [ -n "${DOCTOR_MODE:-}" ]  && MODE="$DOCTOR_MODE"
  [ -n "${DOCTOR_START:-}" ] && START_BJ="$DOCTOR_START"
  [ -n "${DOCTOR_END:-}" ]   && END_BJ="$DOCTOR_END"
fi

log() {
  # 日志轮转（>2MB 保留末尾 500 行）
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
  fi
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

# ---------- 时间：不依赖 GNU date，纯算术换算，CentOS/macOS 通吃 ----------
tz_off_min() {                       # 本机时区相对 UTC 的分钟数
  local z s hh mm v
  z=$(date +%z 2>/dev/null)
  case "$z" in ''|*[!0-9+-]*) echo 480; return 0;; esac
  s=${z:0:1}; hh=${z:1:2}; mm=${z:3:2}
  case "$hh" in ''|*[!0-9]*) hh=0;; esac
  case "$mm" in ''|*[!0-9]*) mm=0;; esac
  v=$(( 10#$hh * 60 + 10#$mm ))
  [ "$s" = "-" ] && v=$(( -v ))
  echo "$v"
}
hm_min() {                           # "16:45" -> 1005
  local h m; h=${1%%:*}; m=${1##*:}
  echo $(( 10#$h * 60 + 10#$m ))
}
bj_to_local_hm() {                   # 北京时间 "16:45" -> 本机 cron 用的 "16 45"
  local h m off t
  h=${1%%:*}; m=${1##*:}
  off=$(tz_off_min)
  t=$(( (10#$h * 60 + 10#$m) - 480 + off ))
  t=$(( (t % 1440 + 1440) % 1440 ))
  echo "$(( t / 60 )) $(( t % 60 ))"
}
now_bj_min() {                       # 现在的北京时间分钟数
  local h m off t
  read -r h m < <(date +'%H %M')
  off=$(tz_off_min)
  t=$(( (10#$h * 60 + 10#$m) - off + 480 ))
  t=$(( (t % 1440 + 1440) % 1440 ))
  echo "$t"
}
in_window() {
  local n s e; n=$(now_bj_min); s=$(hm_min "$START_BJ"); e=$(hm_min "$END_BJ")
  [ "$n" -ge "$s" ] && [ "$n" -lt "$e" ]
}

# ---------- crontab：只挂起/恢复保活那一行，其它行逐字保留 ----------
cron_get() { crontab -l 2>/dev/null || true; }
cron_set() { crontab - 2>/dev/null; }
health_lines_held() { cron_get | grep -qF "$HOLD"; }
health_lines_live()  { cron_get | grep -qE '^[^#].*(ipes_health_check|health_check\.sh)'; }
# 注意：必须先完整读出 crontab 再回写，不能边读边写同一个 spool（部分系统会截断）
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

# ---------- 容器 / 服务状态 ----------
is_paused()  { docker inspect -f '{{.State.Paused}}' "$C" 2>/dev/null | grep -qi true; }
is_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$C"; }
deploy_running() {                   # 部署中绝不插手，避免打断 docker 安装/拉镜像
  pgrep -f 'q2_oneclick_v5_pure_fast|ecache_.*install|docker pull|install_docker' >/dev/null 2>&1
}

verify_paused() {
  log "  体检: ipes paused=$(docker inspect -f '{{.State.Paused}}' "$C" 2>/dev/null || echo '?') 保活cron=$(cron_get | grep -cF "$HOLD") 条已挂起"
}
verify_running() {
  log "  体检: ipes=$(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep "^$C " || echo '未运行') happ=$(docker exec "$C" sh -c 'ps -ef 2>/dev/null | grep -c "[h]app:vod"' 2>/dev/null | tr -d '\r\n') 保活cron=$(cron_get | grep -cE '^[^#].*(ipes_health_check|health_check\.sh)') 条在岗"
}

# ---------- 状态文件 ----------
state_write() {
  local had_sock="${PRE_SOCKET_ACTIVE:-}"
  if [ -z "$had_sock" ]; then
    had_sock=0
    systemctl is-active docker.socket >/dev/null 2>&1 && had_sock=1
  fi
  cat > "$STATE" <<EOF
MODE=$MODE
HAD_SOCKET=$had_sock
SUSPEND_AT=$(date '+%F %T')
START_BJ=$START_BJ
END_BJ=$END_BJ
EOF
}
state_load() { [ -f "$STATE" ] && { set +u; . "$STATE"; set -u; }; return 0; }

# ---------- 暂停 ----------
do_suspend() {
  if deploy_running; then log "检测到部署进程在跑，跳过本次暂停（不打断部署）"; return 0; fi
  if [ -f "$STATE" ]; then log "已处于暂停状态，跳过（幂等）"; return 0; fi
  cron_get > "$STATE_DIR/crontab.before" 2>/dev/null || true
  log "=== ${START_BJ} 暂停开始 mode=${MODE} ==="
  hold_health
  log "  已临时挂起保活 cron（其余 cron 行原样保留）"
  case "$MODE" in
    pause)
      if is_paused; then log "  容器已是 paused，跳过"
      elif docker pause "$C" >>"$LOG" 2>&1; then log "  已 docker pause ${C}（daemon/其它容器/SN/9路/缓存全不动）"
      else log "  ✗ docker pause 失败（容器不存在？）— 见日志"; fi ;;
    stop)
      if is_running; then docker stop "$C" >>"$LOG" 2>&1 && log "  已 docker stop ${C}（容器保留，SN 不变）"; else log "  容器未运行，跳过"; fi ;;
    daemon)
      # 先记下 socket 原状态，恢复时才能还原（停完再读就永远是 inactive）
      PRE_SOCKET_ACTIVE=0
      systemctl is-active docker.socket >/dev/null 2>&1 && PRE_SOCKET_ACTIVE=1
      systemctl stop docker.socket  >/dev/null 2>&1 || true   # 先停 socket，防 CLI 触发 socket 激活把 daemon 拉回来
      systemctl stop docker.service >/dev/null 2>&1 || true
      log "  已停 docker.service + docker.socket（恢复时按原状态还原 socket=${PRE_SOCKET_ACTIVE}）" ;;
    *) log "  ✗ 未知 mode=$MODE"; return 1 ;;
  esac
  state_write
  verify_paused
  log "=== 暂停完成，${END_BJ} 自动恢复 ==="
}

# ---------- 恢复 ----------
do_resume() {
  local m="$MODE" had_sock=0
  if [ -f "$STATE" ]; then state_load; m="${MODE:-$MODE}"; had_sock="${HAD_SOCKET:-0}"; fi
  log "=== ${END_BJ} 恢复开始 mode=${m} ==="
  case "$m" in
    pause)
      if is_paused; then docker unpause "$C" >>"$LOG" 2>&1 && log "  已 docker unpause ${C}（容器不重启，SN/9路/缓存零变化）"; fi
      is_running || docker start "$C" >>"$LOG" 2>&1 ;;
    stop)
      is_running || docker start "$C" >>"$LOG" 2>&1; log "  已 docker start $C" ;;
    daemon)
      systemctl start docker.service >/dev/null 2>&1 || true
      [ "$had_sock" = "1" ] && systemctl start docker.socket >/dev/null 2>&1 || true
      is_running || docker start "$C" >>"$LOG" 2>&1
      log "  已启动 docker.service（--restart=always 容器自动回归）" ;;
  esac
  release_health
  log "  已恢复保活 cron"
  rm -f "$STATE"
  verify_running
  log "=== 恢复完成 ==="
}

# ---------- 看门狗：兜底，保证「停了一定会起来」 ----------
do_watchdog() {
  if in_window; then
    [ -f "$STATE" ] || return 0
    state_load
    local m="${MODE:-pause}"
    if [ "$m" = "pause" ] && ! is_paused && ! deploy_running; then
      log "[watchdog] 窗口内容器未冻结，补做 docker pause"
      docker pause "$C" >>"$LOG" 2>&1 || true
    fi
    if [ "$m" = "stop" ] && is_running && ! deploy_running; then
      log "[watchdog] 窗口内容器被拉起，补做 docker stop"
      docker stop "$C" >>"$LOG" 2>&1 || true
    fi
    if health_lines_live; then
      log "[watchdog] 保活 cron 被重建，重新挂起"
      hold_health
    fi
    return 0
  fi
  if [ -f "$STATE" ]; then
    log "[watchdog] 已过 ${END_BJ} 但仍处于暂停，兜底恢复"
    do_resume
    return 0
  fi
  if health_lines_held; then
    log "[watchdog] 清理残留的保活挂起注释"
    release_health
  fi
  return 0
}

# ---------- 只读体检 ----------
do_probe() {
  echo "===== doctor-window 只读体检 $(date '+%F %T %z') ====="
  echo "时区偏移(分钟) : $(tz_off_min)   北京时间窗口: $START_BJ → $END_BJ"
  echo "本机 cron 时间 : 暂停 $(bj_to_local_hm "$START_BJ")  恢复 $(bj_to_local_hm "$END_BJ")  (H M)"
  echo "当前窗口内?    : $(in_window && echo 是 || echo 否)"
  echo "docker         : $(docker --version 2>/dev/null || echo '未安装/不可用')"
  echo "ipes 容器      : $(docker inspect -f 'status={{.State.Status}} paused={{.State.Paused}} restart={{.HostConfig.RestartPolicy.Name}}' "$C" 2>/dev/null || echo '不存在')"
  echo "happ:vod 进程  : $(docker exec "$C" sh -c 'ps -ef 2>/dev/null | grep -c "[h]app:vod"' 2>/dev/null | tr -d '\r\n')  (期望 9)"
  echo "保活 cron      : $(cron_get | grep -cE 'ipes_health_check|health_check\.sh') 条"
  echo "限速 cron      : $(cron_get | grep -cE 'limit_start|clear_limit') 条"
  echo "docker.socket  : $(systemctl is-active docker.socket 2>/dev/null || echo 'n/a')"
  echo "本工具 cron    : $(cron_get | grep -c "$MARK") 条   状态文件: $([ -f "$STATE" ] && cat "$STATE" | tr '\n' ' ' || echo 无)"
  echo "名字含 doctor 的进程: $(pgrep -af doctor 2>/dev/null | grep -v 'doctor_window\|pgrep' | head -5 || echo '无')"
  echo "名字含 doctor 的单元: $(systemctl list-units --all 2>/dev/null | grep -i doctor | head -5 || echo '无')"
  echo "===== 体检结束（未改动任何东西）====="
}

# ---------- 安装（幂等，重复下发不会叠加 cron 行） ----------
do_install() {
  log "===== 安装 doctor-window  mode=$MODE  窗口(北京) $START_BJ → $END_BJ ====="
  if [ "${DRY:-0}" = "1" ]; then
    log "[DRY-RUN] 将写入 3 条 cron："; do_probe; return 0
  fi
  # 0) 与「单次版」兼容：若容器已被单次脚本 pause，先安全 unpause。
  #    否则下面 release_health 恢复保活后，health_check 会判定异常并 docker restart，
  #    那就变成「重启容器」而不是「零变化恢复」了。
  if is_paused; then
    docker unpause "$C" >>"$LOG" 2>&1 || true
    log "  检测到容器已被单次版暂停 → 先 docker unpause 复原（SN/9路/缓存不变）"
  fi
  for s in /var/lib/doctor-once/state /tmp/doctor-once/state; do
    [ -f "$s" ] && log "  ⚠️ 单次版状态残留 ${s}（业务已复原），可手工删除以免状态显示混淆"
  done
  # 1) 先清掉上一轮可能残留的状态（保证下发即干净）
  if [ -f "$STATE" ]; then do_resume; else release_health; fi
  # 2) 把自己落地成常驻执行器（curl|bash 直跑时 $0 是 bash，需先落文件）
  local src; src="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  if [ "$src" != "$BIN" ]; then
    if [ -f "$src" ]; then cp -f "$src" "$BIN" && chmod +x "$BIN" && log "  执行器已落地 $BIN"
    else log "  ✗ 找不到脚本源文件 ${src}，请先把本脚本保存成文件再执行"; return 1; fi
  else
    chmod +x "$BIN" 2>/dev/null || true; log "  执行器已就位 $BIN"
  fi
  cat > "$CFG" <<EOF
MODE=$MODE
START_BJ=$START_BJ
END_BJ=$END_BJ
EOF
  log "  配置已固化 mode=$MODE 窗口=${START_BJ}-${END_BJ}（cron 调用执行器自动沿用）"
  # 3) 保证 crond 在跑（现网已有保活/限速 cron，正常无需这步）
  systemctl enable crond >/dev/null 2>&1 || true
  systemctl start  crond >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
  # 4) 只替换自己带 MARK 的 3 行，其它 cron 行一个字不动
  local sh sm rh rm_
  read -r sh sm < <(bj_to_local_hm "$START_BJ")
  read -r rh rm_ < <(bj_to_local_hm "$END_BJ")
  local cur; cur="$(cron_get)"
  { printf '%s\n' "$cur" | grep -v "$MARK"
    echo "$sm $sh * * * $BIN suspend  >/dev/null 2>&1 # $MARK suspend"
    echo "$rm_ $rh * * * $BIN resume   >/dev/null 2>&1 # $MARK resume"
    echo "*/5 * * * * $BIN watchdog >/dev/null 2>&1 # $MARK watchdog"
  } | cron_set
  log "  cron 已写入：本机 ${sh}:${sm} 暂停 / ${rh}:${rm_} 恢复 / 每5分钟兜底（对应北京 ${START_BJ} / ${END_BJ}）"
  log "  当前 crontab 共 $(cron_get | wc -l | tr -d ' ') 行，其中本工具 $(cron_get | grep -c "$MARK") 行"
  # 5) 补做：如果下发时正好在窗口内，立刻暂停，不用等明天
  if in_window; then
    log "  当前已在窗口内 → 立即补做暂停"
    do_suspend
  else
    log "  当前不在窗口内 → 保持业务运行，等 $START_BJ 自动暂停"
  fi
  log "===== 安装完成 ====="
}

do_uninstall() {
  log "===== 卸载 doctor-window ====="
  do_resume
  local cur; cur="$(cron_get)"
  printf '%s\n' "$cur" | grep -v "$MARK" | cron_set
  rm -f "$STATE" "$STATE_DIR/crontab.before" "$CFG" "$BIN"
  log "  已删除本工具的 3 条 cron 与执行器；限速/保活/其它 cron 全部保留"
  log "===== 卸载完成 ====="
}

# ---------- 参数 ----------
ACTION="${1:-install}"; shift 2>/dev/null || true
DRY=0
for a in "$@"; do
  case "$a" in
    --mode=*)     MODE="${a#*=}" ;;
    --start=*)    START_BJ="${a#*=}" ;;
    --end=*)      END_BJ="${a#*=}" ;;
    --probe)      ACTION=probe ;;
    --dry-run)    DRY=1 ;;
    --no-catchup) NO_CATCHUP=1 ;;
    --uninstall)  ACTION=uninstall ;;
    suspend|resume|watchdog|install|uninstall|probe) ACTION="$a" ;;
    *) log "未知参数: ${a}（忽略）" ;;
  esac
done

case "$ACTION" in
  install)   do_install ;;
  suspend)   do_suspend ;;
  resume)    do_resume ;;
  watchdog)  do_watchdog ;;
  probe)     do_probe ;;
  uninstall) do_uninstall ;;
  *) echo "用法: $0 install|suspend|resume|watchdog|probe|uninstall [--mode=pause|stop|daemon] [--probe] [--dry-run] [--uninstall]"; exit 1 ;;
esac

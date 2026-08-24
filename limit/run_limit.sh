#!/bin/bash
#
# 两档上行限速调度脚本（基于 Wonder Shaper）
#   - 严格档：START_TIME ~ END_TIME（跨天）  物理卡 4096Kbps / 拨号卡 1024Kbps
#   - 宽松档：END_TIME ~ 23:58              物理卡 40960Kbps / 拨号卡 10240Kbps
# 下行（下载）始终不限制。
#
# 用法：bash run_limit.sh <START> <END> [严格物理Kbps] [严格拨号Kbps] [宽松物理Kbps] [宽松拨号Kbps]
#   例：bash run_limit.sh "23:59" "19:45"            # 使用默认档位
#   例：bash run_limit.sh "23:59" "19:45" 4096 1024 40960 10240

_AUTO_UPDATED="${_AUTO_UPDATED:-false}"
SELF_SAVED="/tmp/limit_start.sh"
LOG_FILE="/var/log/set_rate_limit.log"
CONFIG_FILE="/tmp/rate_limit.conf"
PID_FILE="/tmp/.rate_limit.lock"
SPEED_LIMIT_SCRIPT="/tmp/speed_limit.sh"
CLEAR_SCRIPT="/tmp/clear_limit.sh"

# 默认档位（Kbps）
DEF_STRICT_PHYS_KBPS=4096
DEF_STRICT_DIAL_KBPS=1024
DEF_LOOSE_PHYS_KBPS=40960
DEF_LOOSE_DIAL_KBPS=10240

# 预期的 MD5 值（远程 speed_limit.sh / clear.sh 未变，沿用原值）
EXPECTED_SPEED_LIMIT_MD5="cfa4ea1ed8dbced0343a3826308881ad"
EXPECTED_CLEAR_LIMIT_MD5="17f54e30bb4ee7f24408aa806f56b088"

# 日志函数
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# 检查自身是否有执行权限
if [ -d "$SELF_SAVED" ]; then
  log "警告：$SELF_SAVED 正在添加权限..."
  chmod +x "$SELF_SAVED"
fi

# 加锁机制
exec 200>"$PID_FILE"

# 加锁，如果失败则退出
flock -n 200 || {
  log "已经有另一个实例在运行"
  exit 1
}

trap "flock -u 200; exit" INT TERM EXIT

# MD5 校验函数
check_md5() {
  local file="$1"
  local expected_md5="$2"
  local script_name="$3"

  if [ ! -f "$file" ]; then
    log "文件不存在: $file"
    return 1
  fi

  local actual_md5
  if command -v md5sum >/dev/null 2>&1; then
    actual_md5=$(md5sum "$file" | cut -d' ' -f1)
  elif command -v md5 >/dev/null 2>&1; then
    actual_md5=$(md5 -q "$file")
  else
    log "错误：系统中未找到 md5sum 或 md5 命令"
    return 1
  fi

  if [ "$actual_md5" = "$expected_md5" ]; then
    log "✅ $script_name MD5 校验通过"
    return 0
  else
    log "❌ $script_name MD5 校验失败"
    log "   预期: $expected_md5"
    log "   实际: $actual_md5"
    return 1
  fi
}

# 脚本自更新逻辑
if [ "$(readlink -f "$0")" != "$SELF_SAVED" ]; then
  if [ "$_AUTO_UPDATED" = "true" ]; then
    log "检测到脚本已自动更新过，防止无限循环，退出"
    exit 1
  fi

  log "脚本不在目标路径，正在复制到 $SELF_SAVED"

  curl -s "https://zyy-go.oss-cn-beijing.aliyuncs.com/script/limit/run_limit.sh" | tr -d '\r' > "$SELF_SAVED"
  if [ $? -ne 0 ]; then
    log "下载脚本失败，请检查网络或 URL 是否正确"
    exit 1
  fi

  chmod +x "$SELF_SAVED"
  log "脚本已更新，准备重新执行..."
  export _AUTO_UPDATED=true
  exec "$SELF_SAVED" "$@"
fi

# 校验时间格式是否为 HH:mm
is_valid_time() {
  local time="$1"
  [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

# 更新定时任务（两档）
update_crontab() {
  local start_time="$1"
  local end_time="$2"
  local sp="$3"
  local sd="$4"
  local lp="$5"
  local ld="$6"

  local start_hour=$((10#${start_time%%:*}))
  local start_minute=$((10#${start_time#*:}))
  local end_hour=$((10#${end_time%%:*}))
  local end_minute=$((10#${end_time#*:}))
  local end_hour1=$((end_hour - 1))

  local cron_reboot="@reboot sleep 180 && $SELF_SAVED"
  # 边界精确触发
  local cron_strict="$start_minute $start_hour * * * $SELF_SAVED"
  local cron_loose="$end_minute $end_hour * * * $SELF_SAVED"
  # 每 10 分钟重套一次（main 会按当前时间自动选档）
  local cron_strict_reapply="*/10 0-$end_hour1 * * * $SELF_SAVED"
  local cron_loose_reapply="*/10 $end_hour-23 * * * $SELF_SAVED"

  log "更新定时任务：严格档 $start_time-$end_time，宽松档 $end_time-23:58"

  existing_cron=$(crontab -l 2>/dev/null | grep -vE 'limit_start.sh|clear_limit.sh')

  echo "$existing_cron" > /tmp/new_cron
  echo "$cron_strict" >> /tmp/new_cron
  echo "$cron_loose" >> /tmp/new_cron
  echo "$cron_reboot" >> /tmp/new_cron
  echo "$cron_strict_reapply" >> /tmp/new_cron
  echo "$cron_loose_reapply" >> /tmp/new_cron

  if crontab /tmp/new_cron; then
    log "✅ 定时任务已成功更新"
  else
    log "❌ 更新 cron 失败，请检查权限/cron 服务/new_cron 格式"
    exit 1
  fi

  rm -f /tmp/new_cron
  save_config "$start_time" "$end_time" "$sp" "$sd" "$lp" "$ld"
}

# 获取网卡接口
get_up_interfaces() {
  local static_ppp_interfaces all_interfaces valid_static_ppp=0

  static_ppp_interfaces=$(/usr/sbin/ip link show | awk -F': ' '$2 ~ /(static|ppp)/ {print $2}' | sed 's/^[ \t]*//; s/[ \t]*$//')

  if [ -n "$static_ppp_interfaces" ]; then
    echo "$static_ppp_interfaces" | grep -q '@'
    if [ $? -ne 0 ]; then
      echo "$static_ppp_interfaces" | while IFS= read -r intf; do
        case "$intf" in
          ifb_*|lo|docker*|virbr*|br_*|tun*|veth*)
            continue;;
          *)
            echo "$intf"
            valid_static_ppp=1;;
        esac
      done
      [ $valid_static_ppp -eq 1 ] && return 0
    else
      log "发现带@的接口，改用物理网卡"
    fi
  fi

  all_interfaces=$(/usr/sbin/ip link show | awk -F': ' '$0 !~ "lo|DOWN" && $0 ~ "state UP" {print $2}')

  while IFS= read -r intf; do
    case "$intf" in
      *@*|*:*|*.*|ifb_*|lo|docker*|virbr*|br_*|tun*|veth*)
        continue;;
      *)
        echo "$intf";;
    esac
  done <<< "$all_interfaces"
}

save_config() {
  echo "START_TIME=\"$1\"" > "$CONFIG_FILE"
  echo "END_TIME=\"$2\"" >> "$CONFIG_FILE"
  echo "STRICT_PHYS_KBPS=\"$3\"" >> "$CONFIG_FILE"
  echo "STRICT_DIAL_KBPS=\"$4\"" >> "$CONFIG_FILE"
  echo "LOOSE_PHYS_KBPS=\"$5\"" >> "$CONFIG_FILE"
  echo "LOOSE_DIAL_KBPS=\"$6\"" >> "$CONFIG_FILE"
}

# 下载远程脚本（speed_limit.sh / clear.sh）
download_scripts() {
  SPEED_LIMIT_URL="https://zyy-go.oss-cn-beijing.aliyuncs.com/script/limit/speed_limit.sh"
  CLEAR_SCRIPT_URL="https://zyy-go.oss-cn-beijing.aliyuncs.com/script/limit/clear.sh"

  log "检查 speed_limit.sh..."
  if [ -f "$SPEED_LIMIT_SCRIPT" ]; then
    if check_md5 "$SPEED_LIMIT_SCRIPT" "$EXPECTED_SPEED_LIMIT_MD5" "speed_limit.sh"; then
      log "speed_limit.sh 已存在且 MD5 校验通过，跳过下载"
    else
      log "speed_limit.sh MD5 校验失败，重新下载..."
      curl -fsSL "$SPEED_LIMIT_URL" | sed 's/\r//g' > "$SPEED_LIMIT_SCRIPT"
      [ $? -ne 0 ] && { log "下载 speed_limit.sh 失败"; exit 1; }
      chmod +x "$SPEED_LIMIT_SCRIPT"
      check_md5 "$SPEED_LIMIT_SCRIPT" "$EXPECTED_SPEED_LIMIT_MD5" "speed_limit.sh" || { log "❌ 下载后 MD5 仍不匹配"; exit 1; }
    fi
  else
    log "下载 speed_limit.sh..."
    curl -fsSL "$SPEED_LIMIT_URL" | sed 's/\r//g' > "$SPEED_LIMIT_SCRIPT"
    [ $? -ne 0 ] && { log "下载 speed_limit.sh 失败"; exit 1; }
    chmod +x "$SPEED_LIMIT_SCRIPT"
    check_md5 "$SPEED_LIMIT_SCRIPT" "$EXPECTED_SPEED_LIMIT_MD5" "speed_limit.sh" || { log "❌ 下载的 MD5 不匹配"; exit 1; }
  fi

  log "检查 clear_limit.sh..."
  if [ -f "$CLEAR_SCRIPT" ]; then
    if check_md5 "$CLEAR_SCRIPT" "$EXPECTED_CLEAR_LIMIT_MD5" "clear_limit.sh"; then
      log "clear_limit.sh 已存在且 MD5 校验通过，跳过下载"
    else
      log "clear_limit.sh MD5 校验失败，重新下载..."
      curl -fsSL "$CLEAR_SCRIPT_URL" | sed 's/\r//g' > "$CLEAR_SCRIPT"
      [ $? -ne 0 ] && { log "下载 clear_limit.sh 失败"; exit 1; }
      chmod +x "$CLEAR_SCRIPT"
      check_md5 "$CLEAR_SCRIPT" "$EXPECTED_CLEAR_LIMIT_MD5" "clear_limit.sh" || { log "❌ 下载后 MD5 仍不匹配"; exit 1; }
    fi
  else
    log "下载 clear_limit.sh..."
    curl -fsSL "$CLEAR_SCRIPT_URL" | sed 's/\r//g' > "$CLEAR_SCRIPT"
    [ $? -ne 0 ] && { log "下载 clear_limit.sh 失败"; exit 1; }
    chmod +x "$CLEAR_SCRIPT"
    check_md5 "$CLEAR_SCRIPT" "$EXPECTED_CLEAR_LIMIT_MD5" "clear_limit.sh" || { log "❌ 下载的 MD5 不匹配"; exit 1; }
  fi
}

# 设置上行限速（按网卡类型套不同档位）
set_rate_limit() {
  local phys_kbps="$1"
  local dial_kbps="$2"
  local interfaces="$3"
  for intf in $interfaces; do
    if [[ "$intf" =~ ^(static|ppp) ]]; then
      log "虚拟网卡：$intf，上行限速 ${dial_kbps}Kbps"
      "$SPEED_LIMIT_SCRIPT" -a "$intf" -u "$dial_kbps"
    else
      log "物理网卡：$intf，上行限速 ${phys_kbps}Kbps"
      "$SPEED_LIMIT_SCRIPT" -a "$intf" -u "$phys_kbps"
    fi
  done
}

# 当前是否在严格限速时段（跨天逻辑）
is_strict_time() {
  local current_time start_num end_num
  current_time=$(date +"%H%M")
  start_num=$(echo "$START_TIME" | sed 's/://')
  end_num=$(echo "$END_TIME" | sed 's/://')
  if [ "$start_num" -gt "$end_num" ]; then
    if [ "$current_time" -ge "$start_num" ] || [ "$current_time" -lt "$end_num" ]; then
      return 0
    else
      return 1
    fi
  else
    if [ "$current_time" -ge "$start_num" ] && [ "$current_time" -lt "$end_num" ]; then
      return 0
    else
      return 1
    fi
  fi
}

main() {
  if [ $# -ge 2 ]; then
    START_TIME="$1"
    END_TIME="$2"
    STRICT_PHYS_KBPS="${3:-$DEF_STRICT_PHYS_KBPS}"
    STRICT_DIAL_KBPS="${4:-$DEF_STRICT_DIAL_KBPS}"
    LOOSE_PHYS_KBPS="${5:-$DEF_LOOSE_PHYS_KBPS}"
    LOOSE_DIAL_KBPS="${6:-$DEF_LOOSE_DIAL_KBPS}"

    if ! is_valid_time "$START_TIME" || ! is_valid_time "$END_TIME"; then
      log "错误：时间格式不合法，必须是 HH:mm 格式（例如 09:30）"
      exit 1
    fi

    update_crontab "$START_TIME" "$END_TIME" "$STRICT_PHYS_KBPS" "$STRICT_DIAL_KBPS" "$LOOSE_PHYS_KBPS" "$LOOSE_DIAL_KBPS"
  else
    if [ -f "$CONFIG_FILE" ]; then
      source "$CONFIG_FILE"
      STRICT_PHYS_KBPS="${STRICT_PHYS_KBPS:-$DEF_STRICT_PHYS_KBPS}"
      STRICT_DIAL_KBPS="${STRICT_DIAL_KBPS:-$DEF_STRICT_DIAL_KBPS}"
      LOOSE_PHYS_KBPS="${LOOSE_PHYS_KBPS:-$DEF_LOOSE_PHYS_KBPS}"
      LOOSE_DIAL_KBPS="${LOOSE_DIAL_KBPS:-$DEF_LOOSE_DIAL_KBPS}"
    else
      log "未找到配置文件，也未传入参数，退出"
      exit 1
    fi
  fi

  download_scripts

  interfaces=$(get_up_interfaces)
  if [ -z "$interfaces" ]; then
    log "未找到可用网卡，退出"
    exit 1
  fi

  # 先全局清除旧规则，再按当前时段套对应档位（下行始终不限）
  bash $CLEAR_SCRIPT

  if is_strict_time; then
    log "当前在严格限速时段 ($START_TIME - $END_TIME)，上行压到 ${STRICT_PHYS_KBPS}Kbps(物理)/${STRICT_DIAL_KBPS}Kbps(拨号)"
    set_rate_limit "$STRICT_PHYS_KBPS" "$STRICT_DIAL_KBPS" "$interfaces"
  else
    log "当前在宽松限速时段，上行压到 ${LOOSE_PHYS_KBPS}Kbps(物理)/${LOOSE_DIAL_KBPS}Kbps(拨号)"
    set_rate_limit "$LOOSE_PHYS_KBPS" "$LOOSE_DIAL_KBPS" "$interfaces"
  fi
}

main "$@"
exit 0

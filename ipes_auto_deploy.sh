#!/usr/bin/env bash
#
# IPES 边缘缓存 一键部署脚本（空白 CentOS 7.9 云主机）
# ------------------------------------------------------------
# 完整流程（6 步）：
#   1) 安装 Docker
#   2) 部署 IPES 边缘缓存（JWT token 方式）
#   3) 预热调优 + 健康检查
#   4) 安装 ZyCloud Agent（生成 /etc/.mac 设备ID）   ← 来自 test.sh
#   5) 注册设备到平台 api.zhouyi.top                ← 来自 test.sh
#   6) 绑定业务ID（提交带宽业务到 admin.zhouyi.top）  ← 来自 test.sh
#
# 所有凭据参数化传入，不写死，避免泄露：
#   --token <JWT>             IPES 部署 token（必需）
#   --ak <appKey>             注册 API appKey
#   --sk <secretKey>          注册 API secretKey
#   --isp <运营商>            运营商，如 电信/联通/移动
#   --num-dirs <数量>         目录数量（默认 12，预留/扩展用）
#   --appid <appid>           绑定业务 API appid
#   --appak <ak>              绑定业务 API ak
#   --appsk <sk>              绑定业务 API sk
#
# 用法：
#   curl -fsSL https://angelbaby86966.github.io/scheduled-refund/ipes_auto_deploy.sh | bash -s -- \
#     --token "<JWT>" \
#     --ak "<appKey>" --sk "<secretKey>" --isp 电信 --num-dirs 12 \
#     --appid "<appid>" --appak "<ak>" --appsk "<sk>"
#
# 注意：
#   - Token 是 JWT，自带过期时间，过期后需重新生成再跑。
#   - 仅传 --token 时，只执行 1~3 步（向后兼容）；注册/绑定在提供对应凭据后执行。
# ------------------------------------------------------------
set -uo pipefail

# ===== 日志 =====
LOG_FILE="/var/log/ipes_deploy.log"
log() { local ts="$(date '+%F %T')"; echo "[$ts] $*"; echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null || true; }
warn() { log "⚠️ $*"; }
ok()   { log "✔ $*"; }

# ===== 可配置项（公开，非机密） =====
DOCKER_INSTALL_URL="https://zyy-go.oss-cn-beijing.aliyuncs.com/script/install_docker/install_docker-ce.sh"
IPES_INSTALL_URL="https://zyy-go.oss-cn-beijing.aliyuncs.com/script/Q2_test/ecache_auto_disk_install.sh"
PREHEAT_URL="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/ipes-scripts/main/ipes_preheat_and_health.sh"
IPES_INSTALL_FLAG_I="${IPES_INSTALL_FLAG_I:-1}"
IPES_INSTALL_FLAG_T="${IPES_INSTALL_FLAG_T:-2}"

# Agent 安装包（OSS 主 / CDN 备）
declare -A CDN_URLS=(
  ["zyy_install_notele.tgz"]="http://file.zhouyi.top/script/zyy_init_qudao/zyy_install_notele.tgz"
  ["zyy_install.tgz"]="http://file.zhouyi.top/script/zyy_init_qudao/zyy_install.tgz"
)
declare -A SOURCE_URLS=(
  ["zyy_install_notele.tgz"]="http://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init_qudao/zyy_install_notele.tgz"
  ["zyy_install.tgz"]="http://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init_qudao/zyy_install.tgz"
)
declare -A FILE_MD5=(
  ["zyy_install_notele.tgz"]="6b6c7f1cb2fa1152ef092559d1c30850"
  ["zyy_install.tgz"]="f8272b926b3050223c5f3927a3c55508"
)
REGISTER_API_URL="http://api.zhouyi.top/qudao/device/v1/batch/create2"
BIND_API_URL="https://admin.zhouyi.top/api/edgeNode/updateEdgeNominalInfo"

FRPC_CONFIG="/usr/local/frpc_zycloud/frpc.json"
INSTALLER_DIR="/opt/zyy_install"

# ===== 参数解析 =====
TOKEN=""; APP_KEY=""; SECRET_KEY=""; ISP=""; NUM_DIRS="12"
APPID=""; APPAK=""; APPSK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)    TOKEN="$2"; shift 2;;
    --ak)       APP_KEY="$2"; shift 2;;
    --sk)       SECRET_KEY="$2"; shift 2;;
    --isp)      ISP="$2"; shift 2;;
    --num-dirs) NUM_DIRS="$2"; shift 2;;
    --appid)    APPID="$2"; shift 2;;
    --appak)    APPAK="$2"; shift 2;;
    --appsk)    APPSK="$2"; shift 2;;
    -h|--help)
      echo "用法: bash ipes_auto_deploy.sh --token <JWT> [--ak <ak> --sk <sk> --isp 电信 --num-dirs 12 --appid <appid> --appak <ak> --appsk <sk>]"
      exit 0;;
    *) echo "❌ 未知参数: $1"; exit 1;;
  esac
done

# 校验 token（必需）
if [ -z "$TOKEN" ]; then
  echo "❌ 缺少 --token（IPES 部署必需）。" >&2
  exit 1
fi

DO_REGISTER=0; DO_BIND=0
if [ -n "$APP_KEY" ] && [ -n "$SECRET_KEY" ] && [ -n "$ISP" ]; then
  DO_REGISTER=1
else
  warn "缺少注册凭据(--ak/--sk/--isp)，将跳过『注册设备』步骤"
fi
if [ -n "$APPID" ] && [ -n "$APPAK" ] && [ -n "$APPSK" ]; then
  DO_BIND=1
else
  warn "缺少绑定业务凭据(--appid/--appak/--appsk)，将跳过『绑定业务ID』步骤"
fi

# ============ 步骤 1/6：安装 Docker ============
log "===== 步骤 1/6：安装 Docker ====="
curl -fsSL "$DOCKER_INSTALL_URL" | bash || warn "Docker 安装返回非0，后续步骤可能异常"

# ============ 步骤 2/6：部署 IPES 边缘缓存 ============
log "===== 步骤 2/6：部署 IPES 边缘缓存 ====="
curl -fsSL "$IPES_INSTALL_URL" | bash -s -- -i "$IPES_INSTALL_FLAG_I" -t "$IPES_INSTALL_FLAG_T" token "$TOKEN" \
  || warn "IPES 部署命令返回非0，请检查节点状态"

# ============ 步骤 3/6：预热调优 + 健康检查 ============
log "===== 步骤 3/6：预热调优 + 健康检查 ====="
if curl -fsSL "$PREHEAT_URL" -o /tmp/ipes_preheat.sh; then
  bash /tmp/ipes_preheat.sh || warn "调优脚本返回非0，可稍后手动执行预热"
else
  warn "调优脚本下载失败，跳过"
fi

# ============ 步骤 4/6：安装 ZyCloud Agent（生成 /etc/.mac 设备ID） ============
log "===== 步骤 4/6：安装 ZyCloud Agent（生成 /etc/.mac 设备ID） ====="

check_md5() {
  local fp="$1" fn="$2" expect="${FILE_MD5[$fn]}"
  [ -f "$fp" ] || return 1
  local actual; actual=$(md5sum "$fp" | awk '{print $1}')
  [ "$actual" = "$expect" ]
}

download_file() {
  local url="$1" out="$2"
  curl -L -C - --connect-timeout 30 --max-time 600 --retry 1 --retry-delay 5 -o "$out" "$url" 2>/dev/null
}

download_with_fallback() {
  local fn="$1" local_path="/opt/$fn" temp="${local_path}.part"
  if [ -f "$local_path" ] && check_md5 "$local_path" "$fn"; then
    log "使用现有有效文件，无需下载: $fn"; return 0
  fi
  [ -f "$temp" ] && rm -f "$temp"
  if download_file "${SOURCE_URLS[$fn]}" "$temp" && [ -s "$temp" ] && check_md5 "$temp" "$fn"; then
    mv "$temp" "$local_path"; ok "OSS 下载并校验通过: $fn"; return 0
  fi
  rm -f "$local_path" 2>/dev/null
  if download_file "${CDN_URLS[$fn]}" "$temp" && [ -s "$temp" ] && check_md5 "$temp" "$fn"; then
    mv "$temp" "$local_path"; ok "CDN 下载并校验通过: $fn"; return 0
  fi
  return 1
}

detect_cloud_environment() {
  if dmesg 2>/dev/null | grep -qi alibaba; then echo aliyun; return 0; fi
  if dmesg 2>/dev/null | grep -qi tencent; then echo tencent; return 0; fi
  echo non_cloud; return 1
}

cloud_server_edge() {
  local fn="zyy_install_notele.tgz"
  download_with_fallback "$fn" || { warn "下载 $fn 失败"; return 1; }
  tar xf "/opt/$fn" -C /opt || { warn "解压失败"; return 1; }
  chmod -R +x /opt/zyy_install/* 2>/dev/null || true
  ( cd /opt/zyy_install/ && ./agent_installer install zycloud ) || { warn "agent_installer 执行失败"; return 1; }
  ok "ZyCloud Agent 安装完成"
}

iso_server_edge() {
  local fn="zyy_install.tgz"
  download_with_fallback "$fn" || { warn "下载 $fn 失败"; return 1; }
  tar xf "/opt/$fn" -C /opt || { warn "解压失败"; return 1; }
  chmod -R +x /opt/zyy_install/* 2>/dev/null || true
  ( cd /opt/zyy_install/ && ./agent_installer install zycloud --enable-telegraf ) || { warn "agent_installer 执行失败"; return 1; }
  ok "ZyCloud Agent 安装完成(含 telegraf)"
}

set_frp_port() {
  local ssh_port
  ssh_port=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
  [ -z "$ssh_port" ] && ssh_port=22
  if [ -f "$FRPC_CONFIG" ]; then
    cp "$FRPC_CONFIG" "${FRPC_CONFIG}.backup" 2>/dev/null || true
    sed -i "s/\"LocalPort\": [0-9]*/\"LocalPort\": $ssh_port/g" "$FRPC_CONFIG" 2>/dev/null || true
    systemctl restart frpc_zycloud 2>/dev/null || warn "frpc_zycloud 重启失败(可忽略)"
    ok "frpc LocalPort 已设为 $ssh_port"
  else
    warn "未找到 frpc 配置($FRPC_CONFIG)，跳过"
  fi
}

mkdir -p /opt
env_type=$(detect_cloud_environment)
if [ "$env_type" = "non_cloud" ]; then
  log "检测到非云环境，使用完整版(含 telegraf)"
  iso_server_edge && set_frp_port
else
  log "检测到云环境($env_type)，使用无 telegraf 版"
  cloud_server_edge && set_frp_port
fi

# ============ 步骤 5/6：注册设备 ============
DEVICE_ID=""
if [ $DO_REGISTER -eq 1 ]; then
  log "===== 步骤 5/6：注册设备到平台 ====="

  display_device_id() {
    local f="/etc/.mac"
    if [ -f "$f" ]; then
      DEVICE_ID=$(cat "$f")
      mkdir -p /usr/local/edge
      cat "$f" > /usr/local/edge/device_code
      ok "设备ID: $DEVICE_ID"
      return 0
    else
      warn "未找到设备ID文件($f)，跳过注册（可能 Agent 未正确安装）"
      return 1
    fi
  }

  get_location_info() {
    local ip_info
    ip_info=$(curl -s --retry 3 --retry-delay 2 --connect-timeout 5 --max-time 10 myip.ipip.net 2>/dev/null)
    province=$(echo "$ip_info" | awk '{print $4}' | tr -d ',')
    city=$(echo "$ip_info" | awk '{print $5}' | tr -d ',')
    [ -z "$province" ] && province="北京"
    [ -z "$city" ] && city="北京"
    ok "地理位置: $province / $city"
  }

  generate_sign() {
    local ts="$1" ak="$2" sk="$3"
    echo -n "${ak}${ts}${sk}" | md5sum | cut -d' ' -f1 | sed 's/^/ZYY/'
  }

  register_device() {
    local device_id="$1" prov="$2" cty="$3" isp="$4" remark="${5:-}"
    local max_retries=3 retry=0
    while [ $retry -lt $max_retries ]; do
      local ts; ts=$(date +%s)
      local sign; sign=$(generate_sign "$ts" "$APP_KEY" "$SECRET_KEY")
      local dev_remark="${remark:-${isp}-${device_id:0:8}}"
      local data="{\"devices\":[{\"device_id\":\"$device_id\",\"remark\":\"$dev_remark\"}],\"province\":\"$prov\",\"city\":\"$cty\",\"isp\":\"$isp\"}"
      log "注册设备(尝试 $((retry+1))/$max_retries)..."
      local resp
      resp=$(curl -s -w "\n%{http_code}" --location --request POST "$REGISTER_API_URL" \
        --header "sign: $sign" --header "verison: V1.0.0" --header "appKey: $APP_KEY" \
        --header "timestamp: $ts" --header "Content-Type: application/json" \
        --data "$data" --connect-timeout 10 --max-time 30 2>&1)
      local http_code; http_code=$(echo "$resp" | tail -n1)
      local body; body=$(echo "$resp" | sed '$d')
      if [ "$http_code" = "200" ]; then
        local message; message=$(echo "$body" | sed 's/.*"message":"\([^"]*\)".*/\1/')
        if echo "$message" | grep -q "全部绑定成功,成功:1台"; then
          ok "设备注册成功：$body"
          {
            echo "注册时间: $(date '+%F %T')"
            echo "设备ID: $device_id"
            echo "运营商: $isp"
            echo "注册状态: 成功"
            echo "API响应: $body"
          } > /usr/local/edge/registration_info
          return 0
        elif echo "$message" | grep -q "全部已存在"; then
          log "设备已存在，跳过"; return 0
        else
          warn "注册失败: $body"
        fi
      else
        warn "HTTP $http_code"
      fi
      retry=$((retry+1)); [ $retry -lt $max_retries ] && sleep 2
    done
    warn "设备注册达到最大重试次数，跳过"
    return 1
  }

  if display_device_id; then
    get_location_info
    register_device "$DEVICE_ID" "$province" "$city" "$ISP" ""
  fi
else
  log "===== 步骤 5/6：注册设备（已跳过，未提供注册凭据） ====="
fi

# ============ 步骤 6/6：绑定业务ID（提交带宽业务） ============
if [ $DO_BIND -eq 1 ]; then
  log "===== 步骤 6/6：绑定业务ID（提交带宽业务） ====="
  node=$(cat /etc/.mac 2>/dev/null || echo "")
  if [ -z "$node" ]; then
    warn "无法获取 nodeId(/etc/.mac)，跳过绑定业务"
  else
    VENDOR_SUGGEST_CUSTOMERS="${VENDOR_SUGGEST_CUSTOMERS:-41}"
    USBW="${USBW:-200}"
    BWNUM="${BWNUM:-1}"
    TRANS_MODE="${TRANS_MODE:-1}"
    bind_ts=$(date +%s)
    sign_str="${APPAK}:${bind_ts}"
    bind_sign=$(echo -n "$sign_str" | openssl dgst -sha256 -hmac "$APPSK" | cut -d' ' -f2)
    bind_body="{\"nodeId\":\"$node\",\"vendorSuggestCustomers\":$VENDOR_SUGGEST_CUSTOMERS,\"transMode\":$TRANS_MODE,\"isCrossNetwork\":false,\"crossNetworkIsp\":null,\"isTransProv\":false,\"usbw\":$USBW,\"bwNum\":$BWNUM}"
    log "提交带宽业务信息..."
    bw_resp=$(curl -k -s --location --request POST "$BIND_API_URL" \
      --header "appId: $APPID" --header "timestamp: $bind_ts" --header "sign: $bind_sign" \
      --header "Content-Type: application/json" --data "$bind_body")
    if echo "$bw_resp" | grep -q '"code":0'; then
      ok "带宽业务提交成功：$bw_resp"
    else
      warn "带宽业务提交失败：$bw_resp"
    fi
  fi
else
  log "===== 步骤 6/6：绑定业务ID（已跳过，未提供绑定凭据） ====="
fi

log "✅ 全部完成。请到控制台确认节点已上线、已注册并绑定业务。"

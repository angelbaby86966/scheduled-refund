#!/usr/bin/env bash
#
# 半黄金镜像 · 新机首次启动脚本（由 systemd edge-firstboot.service 自动调用）
# ------------------------------------------------------------
# 在克隆出的「每台新机」首次启动时运行：
#   1) 读取 /etc/edge_firstboot.conf 里的注册/绑定凭据
#   2) 安装 ZyCloud Agent → 生成【全新】/etc/.mac（每台机器独立设备ID）
#   3) 注册设备到 api.zhouyi.top
#   4) 绑定业务ID 到 admin.zhouyi.top
#   5) 确保 IPES 容器在运行
#   6) 写 /etc/edge_firstboot_done 标记（只跑一次，重启不再执行）
#
# 因为 Agent 是每台新机【现装】的，/etc/.mac 每台不同，
# 所以注册/绑定是每台独立的，不会像"整镜像克隆"那样多台共用设备ID冲突。
#
# 也可手动运行（用于调试）：
#   bash /opt/edge_firstboot.sh [--ak x --sk y --isp 电信 --num-dirs 10 --appid a --appak b --appsk c]
# ------------------------------------------------------------
set -uo pipefail

LOG_FILE="/var/log/edge_firstboot.log"
log() { local ts="$(date '+%F %T')"; echo "[$ts] $*"; echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null || true; }
warn() { log "⚠️ $*"; }
ok()   { log "✔ $*"; }

# 幂等守卫：跑过就退出
if [ -f /etc/edge_firstboot_done ]; then
  log "已执行过首次启动注册，跳过。"
  exit 0
fi

# ===== 凭据：优先命令行参数，否则读 conf =====
APP_KEY=""; SECRET_KEY=""; ISP=""; NUM_DIRS="12"
APPID=""; APPAK=""; APPSK=""
if [ -f /etc/edge_firstboot.conf ]; then
  # shellcheck disable=SC1091
  source /etc/edge_firstboot.conf
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ak)    APP_KEY="$2"; shift 2;;
    --sk)    SECRET_KEY="$2"; shift 2;;
    --isp)   ISP="$2"; shift 2;;
    --num-dirs) NUM_DIRS="$2"; shift 2;;
    --appid) APPID="$2"; shift 2;;
    --appak) APPAK="$2"; shift 2;;
    --appsk) APPSK="$2"; shift 2;;
    *) shift;;
  esac
done

# ===== Agent 安装包（OSS 主 / CDN 备） =====
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
  ok "ZyCloud Agent 安装完成（新设备ID）"
}
iso_server_edge() {
  local fn="zyy_install.tgz"
  download_with_fallback "$fn" || { warn "下载 $fn 失败"; return 1; }
  tar xf "/opt/$fn" -C /opt || { warn "解压失败"; return 1; }
  chmod -R +x /opt/zyy_install/* 2>/dev/null || true
  ( cd /opt/zyy_install/ && ./agent_installer install zycloud --enable-telegraf ) || { warn "agent_installer 执行失败"; return 1; }
  ok "ZyCloud Agent 安装完成(含 telegraf，新设备ID)"
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

log "===== 首次启动注册绑定开始 ====="

# ============ 步骤 1：安装 Agent（生成新设备ID） ============
mkdir -p /opt
env_type=$(detect_cloud_environment)
if [ "$env_type" = "non_cloud" ]; then
  log "检测到非云环境，使用完整版(含 telegraf)"
  iso_server_edge && set_frp_port
else
  log "检测到云环境($env_type)，使用无 telegraf 版"
  cloud_server_edge && set_frp_port
fi

# ============ 步骤 2：注册设备 ============
if [ -z "$APP_KEY" ] || [ -z "$SECRET_KEY" ] || [ -z "$ISP" ]; then
  warn "缺少注册凭据，跳过注册"
else
  DEVICE_ID=""
  if [ -f /etc/.mac ]; then
    DEVICE_ID=$(cat /etc/.mac)
  fi
  if [ -z "$DEVICE_ID" ]; then
    warn "未找到 /etc/.mac（Agent 未生成设备ID），跳过注册"
  else
    ok "设备ID: $DEVICE_ID"
    # 地理位置
    province=""; city=""
    ip_info=$(curl -s --retry 3 --retry-delay 2 --connect-timeout 5 --max-time 10 myip.ipip.net 2>/dev/null)
    province=$(echo "$ip_info" | awk '{print $4}' | tr -d ',')
    city=$(echo "$ip_info" | awk '{print $5}' | tr -d ',')
    [ -z "$province" ] && province="北京"
    [ -z "$city" ] && city="北京"

    generate_sign() {
      local ts="$1" ak="$2" sk="$3"
      echo -n "${ak}${ts}${sk}" | md5sum | cut -d' ' -f1 | sed 's/^/ZYY/'
    }
    ts=$(date +%s)
    sign=$(generate_sign "$ts" "$APP_KEY" "$SECRET_KEY")
    dev_remark="${ISP}-${DEVICE_ID:0:8}"
    data="{\"devices\":[{\"device_id\":\"$DEVICE_ID\",\"remark\":\"$dev_remark\"}],\"province\":\"$province\",\"city\":\"$city\",\"isp\":\"$ISP\"}"
    log "注册设备..."
    resp=$(curl -s -w "\n%{http_code}" --location --request POST "$REGISTER_API_URL" \
      --header "sign: $sign" --header "verison: V1.0.0" --header "appKey: $APP_KEY" \
      --header "timestamp: $ts" --header "Content-Type: application/json" \
      --data "$data" --connect-timeout 10 --max-time 30 2>&1)
    http_code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')
    if [ "$http_code" = "200" ]; then
      message=$(echo "$body" | sed 's/.*"message":"\([^"]*\)".*/\1/')
      if echo "$message" | grep -q "全部绑定成功,成功:1台"; then
        ok "设备注册成功：$body"
        { echo "注册时间: $(date '+%F %T')"; echo "设备ID: $DEVICE_ID"; echo "运营商: $ISP"; echo "注册状态: 成功"; } > /usr/local/edge/registration_info 2>/dev/null || true
      elif echo "$message" | grep -q "全部已存在"; then
        log "设备已存在，跳过"
      else
        warn "注册失败: $body"
      fi
    else
      warn "注册 HTTP $http_code"
    fi
  fi
fi

# ============ 步骤 3：绑定业务ID ============
if [ -z "$APPID" ] || [ -z "$APPAK" ] || [ -z "$APPSK" ]; then
  warn "缺少绑定业务凭据，跳过绑定"
else
  node=$(cat /etc/.mac 2>/dev/null || echo "")
  if [ -z "$node" ]; then
    warn "无法获取 nodeId(/etc/.mac)，跳过绑定"
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
fi

# ============ 步骤 4：确保 IPES 容器在运行 ============
if command -v docker >/dev/null 2>&1; then
  stopped=$(docker ps -aq --filter "status=exited" 2>/dev/null)
  if [ -n "$stopped" ]; then
    for cid in $stopped; do
      docker start "$cid" >/dev/null 2>&1 && ok "已启动容器 $cid" || warn "启动容器 $cid 失败"
    done
  else
    ok "IPES 容器已在运行（或无需启动）"
  fi
fi

# ============ 完成标记 ============
touch /etc/edge_firstboot_done
log "✅ 首次启动注册绑定完成。本机已独立注册并绑定业务。"

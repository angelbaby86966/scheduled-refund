#!/bin/bash
#
# IPES 节点 待配置 → 服务中 自动状态流转脚本
# ------------------------------------------------------------
# 运行位置：已部署 IPES 的机器本机（确保一对一）
# 逻辑：
#   1) 读 /etc/.mac 拿到本机舟翼云设备ID
#   2) 读 docker exec ipes cat bin/ipes_sn 拿到本机 IPES SN（业务ID）
#   3) 调用 admin.zhouyi.top 状态流转接口，把本机节点流转到 服务中
#
# 用法：
#   # 方式1：环境变量
#   STATUS_API_URL="https://admin.zhouyi.top/api/edgeNode/xxx" \
#   APPID="xxx" APPAK="xxx" APPSK="xxx" \
#     bash transition_to_service.sh
#
#   # 方式2：命令行参数
#   bash transition_to_service.sh \
#     --status-api-url "https://admin.zhouyi.top/api/edgeNode/xxx" \
#     --appid "xxx" --appak "xxx" --appsk "xxx"
#
# 注意：IPES 容器首次启动后约需 3 分钟才会生成 SN，脚本会自动轮询等待。
# ------------------------------------------------------------
set -uo pipefail

# ===== 默认配置（可被命令行/环境变量覆盖） =====
STATUS_API_URL="${STATUS_API_URL:-}"
APPID="${APPID:-}"
APPAK="${APPAK:-}"
APPSK="${APPSK:-}"
STATUS_BODY_TPL='{"nodeId":"{nodeId}","businessId":"{businessId}","status":"服务中"}'

# ===== 日志 =====
LOG_FILE="/var/log/transition_to_service.log"
log() { local ts="$(date '+%F %T')"; echo "[$ts] $*"; echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null || true; }
warn() { log "⚠️ $*"; }
ok()   { log "✔ $*"; }

# ===== 参数解析 =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status-api-url) STATUS_API_URL="$2"; shift 2;;
    --appid)  APPID="$2"; shift 2;;
    --appak)  APPAK="$2"; shift 2;;
    --appsk)  APPSK="$2"; shift 2;;
    -h|--help)
      echo "用法: bash $0 [--status-api-url <url>] [--appid <id>] [--appak <ak>] [--appsk <sk>]"
      exit 0;;
    *) echo "❌ 未知参数: $1"; exit 1;;
  esac
done

# ===== 1) 读取本机舟翼云设备ID =====
node=$(cat /etc/.mac 2>/dev/null || echo "")
if [ -z "$node" ]; then
  warn "无法读取 /etc/.mac，本机尚未安装 ZyCloud Agent 或未生成设备ID"
  exit 1
fi
ok "本机设备ID(nodeId): $node"

# ===== 2) 读取本机 IPES SN（业务ID） =====
get_ipes_sn() {
  docker exec ipes cat bin/ipes_sn 2>/dev/null
}

sn=$(get_ipes_sn)
if [ -z "$sn" ]; then
  log "IPES SN 尚未生成，首次启动约需 3 分钟，正在轮询..."
  for i in $(seq 1 40); do
    sleep 5
    sn=$(get_ipes_sn)
    if [ -n "$sn" ]; then
      ok "轮询 ${i} 次后获取到 IPES SN"
      break
    fi
  done
fi
if [ -z "$sn" ]; then
  warn "等待超过 3 分钟仍未获取到 IPES SN，请检查：docker exec ipes cat bin/ipes_sn"
  log "请手动在后台填写：设备ID=$node，业务ID=<IPES SN>，流转状态=服务中"
  exit 1
fi
ok "本机 IPES SN(业务ID): $sn"

# ===== 3) 调用状态流转接口 =====
if [ -z "$STATUS_API_URL" ] || [ -z "$APPID" ] || [ -z "$APPAK" ] || [ -z "$APPSK" ]; then
  warn "缺少 STATUS_API_URL / APPID / APPAK / APPSK，无法自动调用接口。"
  log "手工操作：登录 admin.zhouyi.top → 状态流转 → 设备ID=$node，业务ID=$sn，流转状态=服务中"
  exit 0
fi

ts=$(date +%s)
sign=$(echo -n "${APPAK}:${ts}" | openssl dgst -sha256 -hmac "$APPSK" | cut -d' ' -f2)
body=$(echo "$STATUS_BODY_TPL" | sed "s/{nodeId}/$node/g; s/{businessId}/$sn/g")

log "调用状态流转接口: $STATUS_API_URL"
log "请求体: $body"
resp=$(curl -k -s --location --request POST "$STATUS_API_URL" \
  --header "appId: $APPID" \
  --header "timestamp: $ts" \
  --header "sign: $sign" \
  --header "Content-Type: application/json" \
  --data "$body")

if echo "$resp" | grep -q '"code":0'; then
  ok "状态流转成功（待配置 → 服务中）: $resp"
else
  warn "状态流转失败: $resp"
  log "请手工核对：设备ID=$node，业务ID=$sn"
fi

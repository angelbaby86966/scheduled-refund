#!/bin/bash
# ==============================================================================
# ipes_bind_auto.sh v20260915a — IPES 部署后自动绑定收尾
# 流程：等本机部署就绪 → create2 挂渠道(免JWT) → HMAC 提交属性(免JWT) → stateflow 服务中(需JWT)
# 说明：stateflow 不支持 HMAC 鉴权(实测"未登录或非法访问")，JWT 复用部署命令里现成的那个
# 用法：ipes_bind_auto.sh --ak <渠道AK> --sk <渠道SK> --jwt <JWT> --province 上海 --city 上海 [--isp 电信] [--remark 云主机]
# 日志：/var/log/ipes_bind_auto.log
# ==============================================================================
CH_AK=""; CH_SK=""; JWT=""; ISP="电信"; PROVINCE=""; CITY=""; REMARK="云主机"
ADMIN_APPID="fg5c21pbzfgu6y2s2yqvanvr6uv99drq"
ADMIN_AK="ja3io44nq2m7hx63fjkpio7s422aksel"
ADMIN_SK="ydDGuguZ8COcJN4Ztl3Lsic3Z00zGEani8fYOPiYk2XXCuXQ1AHyy7E1sgV4dyDT"
ADMIN_BASE="https://admin.zhouyi.top"
CH_API="http://api.zhouyiy.com/qudao/device/v1/batch/create2"
LOG="/var/log/ipes_bind_auto.log"

log(){ echo "[$(date '+%F %T')] $1" >> "${LOG}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ak) CH_AK="$2"; shift 2;;
    --sk) CH_SK="$2"; shift 2;;
    --jwt) JWT="$2"; shift 2;;
    --isp) ISP="$2"; shift 2;;
    --province) PROVINCE="$2"; shift 2;;
    --city) CITY="$2"; shift 2;;
    --remark) REMARK="$2"; shift 2;;
    *) shift;;
  esac
done
if [[ -z "${CH_AK}" || -z "${CH_SK}" || -z "${PROVINCE}" || -z "${CITY}" ]]; then
  log "[FATAL] 缺少必填参数 --ak/--sk/--province/--city"
  exit 1
fi
log "=== bind_auto v20260915a 开始 (province=${PROVINCE} city=${CITY} isp=${ISP}) ==="

# ---------- 1) 等本机就绪：/etc/.mac + ipes 容器 Up（最多 40 分钟） ----------
DID=""
for i in $(seq 1 240); do
  DID=$(cat /etc/.mac 2>/dev/null)
  if [[ -n "${DID}" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'ipes'; then
    log "本机就绪: device=${DID} (等待 $((i*10))s)"
    break
  fi
  sleep 10
done
if [[ -z "${DID}" ]]; then
  log "[FATAL] 40 分钟内 /etc/.mac 或 ipes 容器未就绪，放弃绑定"
  exit 1
fi

# ---------- 2) 等部署自身流程走到 inService（有 JWT 就轮询；否则固定等 8 分钟） ----------
if [[ -n "${JWT}" ]]; then
  for i in $(seq 1 90); do
    ST=$(curl -sk -m 10 -H "x-token: ${JWT}" "${ADMIN_BASE}/api/edgeNode/findEdgeNode?nodeId=${DID}" 2>/dev/null | grep -o '"stage":"inService"' | head -1)
    if [[ -n "${ST}" ]]; then
      log "部署自身流程已到 inService (轮询 $((i*10))s)"
      break
    fi
    sleep 10
  done
else
  log "未提供 JWT，固定等待 480s 让部署自身流程先行"
  sleep 480
fi

# ---------- 3) create2 渠道挂靠（免JWT，重试3次；成功判定：绑定成功/已存在） ----------
BOUND=0
for t in 1 2 3; do
  TS=$(date +%s)
  SIGN="ZYY$(printf '%s' "${CH_AK}${TS}${CH_SK}" | md5sum | cut -d ' ' -f1)"
  RESP=$(curl -s -m 20 -X POST "${CH_API}" \
    -H "sign: ${SIGN}" -H "verison: V1.0.0" -H "appKey: ${CH_AK}" -H "timestamp: ${TS}" \
    -H "Content-Type: application/json" \
    -d "{\"devices\":[{\"device_id\":\"${DID}\",\"remark\":\"${REMARK}\"}],\"province\":\"${PROVINCE}\",\"city\":\"${CITY}\",\"isp\":\"${ISP}\"}")
  log "create2#${t}: ${RESP}"
  if echo "${RESP}" | grep -q '绑定成功\|已存在'; then
    BOUND=1
    break
  fi
  sleep 5
done
if [[ ${BOUND} -eq 0 ]]; then
  log "[WARN] create2 三次未确认成功，继续后续步骤（可能未挂上渠道属主）"
fi
sleep 8

# ---------- 4) HMAC 提交属性（免JWT；create2 会把节点重置回 configured，此时可改） ----------
TS=$(date +%s)
ASIGN=$(printf '%s' "${ADMIN_AK}:${TS}" | openssl dgst -sha256 -hmac "${ADMIN_SK}" | sed 's/^.*= //')
NOMINAL="{\"nodeId\":\"${DID}\",\"province\":\"${PROVINCE}\",\"city\":\"${CITY}\",\"isp\":\"${ISP}\",\"natType\":\"public\",\"resourceType\":\"2\",\"dialType\":\"staticNetSingle\",\"singleIpRadio\":true,\"usbw\":200,\"bwNum\":1,\"transMode\":0,\"transModeStr\":\"cm:0,ct:0,cu:0\",\"transProvRate\":0,\"isTransProv\":true,\"isIPv6Schedule\":false,\"isCrossNetwork\":false,\"crossNetworkIsp\":null,\"vendorSuggestCustomers\":41}"
RESP=$(curl -sk -m 20 -X POST "${ADMIN_BASE}/api/edgeNode/updateEdgeNominalInfo" \
  -H "appId: ${ADMIN_APPID}" -H "timestamp: ${TS}" -H "sign: ${ASIGN}" \
  -H "Content-Type: application/json" -d "${NOMINAL}")
log "nominal(HMAC): ${RESP}"

# ---------- 5) stateflow -> inService（需 JWT；hostname=容器 ipes_sn，缺失则不流转防写占位符） ----------
SN=""
for i in $(seq 1 12); do
  SN=$(docker exec ipes cat /bin/ipes_sn 2>/dev/null || docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null)
  [[ -n "${SN}" ]] && break
  sleep 10
done
if [[ -z "${SN}" ]]; then
  log "[WARN] 取容器 ipes_sn 失败——为防写入占位符 ZHOUYI_XIAODU，跳过 stateflow，节点停在 configured，需人工补流转"
fi
if [[ -n "${JWT}" && -n "${SN}" ]]; then
  sleep 5
  RESP=$(curl -sk -m 20 -X POST "${ADMIN_BASE}/api/edgeNode/stateflow" \
    -H "x-token: ${JWT}" -H "Content-Type: application/json" \
    -d "{\"nodes\":[\"${DID}\"],\"hostname\":\"${SN}\",\"stage\":\"inService\"}")
  log "stateflow->inService: ${RESP}"
fi

# ---------- 6) 终验（需 JWT） ----------
if [[ -n "${JWT}" ]]; then
  sleep 10
  FINAL=$(curl -sk -m 15 -H "x-token: ${JWT}" "${ADMIN_BASE}/api/edgeNode/findEdgeNode?nodeId=${DID}" 2>/dev/null)
  log "终验快照: $(echo "${FINAL}" | head -c 600)"
fi
log "=== bind_auto 结束 ==="

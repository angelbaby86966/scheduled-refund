#!/bin/bash
# =============================================================================
# 批量内核升级：CentOS 7 (3.10) -> elrepo kernel-ml (>=4.9)，启用 BBR
# -----------------------------------------------------------------------------
# 背景：IPES 调优脚本 ipes_quick_deploy.sh 的 BBR 拥塞控制需内核 >=4.9；
#       CentOS 7 默认 3.10 无 tcp_bbr 模块，自动回退 cubic。
#       升级后新内核支持 BBR，配合 99-ipes-bbr.conf 开机自动生效。
#
# 走阿里云云助手批量下发（ECS RunCommand / SWAS CreateCommand+InvokeCommand）。
#
# ⚠️ 重启类操作：每台实例会重启一次（IPES 容器 --restart=always 自动恢复）。
#   脚本默认每批 10 台、批间隔 30s，避免所有节点同时离线掉量。
#   ★ 首次使用务必先 --instance-ids 指定 1 台试点，确认重启后 IPES 正常 + BBR 生效，再全量。
#
# 用法：
#   bash fleet_kernel_upgrade.sh \
#     --product ecs \            # ecs 或 swas
#     --region cn-hangzhou \
#     --ak <AccessKeyId> --sk <AccessKeySecret> \
#     --instance-ids "i-xxx,i-yyy" \   # 或 --instance-file /path/list.txt
#     --batch 10 --interval 30
# =============================================================================
set -uo pipefail

PRODUCT="ecs"; REGION=""; AK=""; SK=""; INSTANCES=""; INST_FILE=""
BATCH=10; INTERVAL=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product) PRODUCT="$2"; shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    --ak)      AK="$2"; shift 2 ;;
    --sk)      SK="$2"; shift 2 ;;
    --instance-ids) INSTANCES="$2"; shift 2 ;;
    --instance-file) INST_FILE="$2"; shift 2 ;;
    --batch)   BATCH="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

[ -z "$REGION" ] && { echo "缺少 --region"; exit 1; }
[ -z "$AK" ] && { echo "缺少 --ak"; exit 1; }
[ -z "$SK" ] && { echo "缺少 --sk"; exit 1; }
if [ -n "$INST_FILE" ]; then INSTANCES=$(tr '\n' ',' < "$INST_FILE" | sed 's/,$//'); fi
[ -z "$INSTANCES" ] && { echo "缺少 --instance-ids 或 --instance-file"; exit 1; }

# ---- 产品相关配置 ----
if [ "$PRODUCT" = "ecs" ]; then
  ENDPOINT="ecs.${REGION}.aliyuncs.com"; VERSION="2014-05-26"
elif [ "$PRODUCT" = "swas" ]; then
  ENDPOINT="swas.${REGION}.aliyuncs.com"; VERSION="2020-06-01"
else
  echo "未知 --product: $PRODUCT (仅 ecs/swas)"; exit 1
fi

# ---- 升级命令（装 kernel-ml + 设默认 + 持久化 BBR + 延迟重启） ----
read -r -d '' CMD <<'SCRIPT'
set -e
rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
rpm -Uvh http://www.elrepo.org/elrepo-release-7.0-4.el7.elrepo.noarch.rpm || true
yum --enablerepo=elrepo-kernel install kernel-ml -y
grub2-set-default 0
echo tcp_bbr > /etc/modprobe.d/tcp_bbr.conf
echo 'net.ipv4.tcp_congestion_control = bbr' > /etc/sysctl.d/99-ipes-bbr.conf
# 延迟重启：先让云助手命令返回成功，再重启（避免进程被杀被误报失败）
( sleep 20; /sbin/reboot ) >/dev/null 2>&1 &
echo "KERNEL_UPGRADE_DONE_REBOOTING"
SCRIPT
CMD_B64=$(printf '%s' "$CMD" | base64 | tr -d '\n')

# ---- 阿里云 RPC HMAC-SHA1 签名 ----
percent_encode() {
  local s="$1" out="" i c
  for ((i=0;i<${#s};i++)); do
    c="${s:$i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out+="$c" ;;
      ' ') out+="%20" ;;
      *) printf -v h '%%%02X' "'$c"; out+="$h" ;;
    esac
  done
  printf '%s' "$out"
}
rpc_call() {
  # $1 = Action; 其余以 "Key=Value" 传入的业务参数
  local action="$1"; shift
  declare -A P
  P[Action]="$action"; P[AccessKeyId]="$AK"; P[Format]="JSON"
  P[Version]="$VERSION"; P[RegionId]="$REGION"; P[SignatureMethod]="HMAC-SHA1"
  P[SignatureVersion]="1.0"; P[SignatureNonce]="$(cat /proc/sys/kernel/random/uuid)"
  P[Timestamp]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local k v
  for kv in "$@"; do k="${kv%%=*}"; v="${kv#*=}"; P[$k]="$v"; done
  local query=""
  for k in $(echo "${!P[@]}" | tr ' ' '\n' | sort); do
    v="${P[$k]}"
    [ -n "$query" ] && query+="&"
    query+="${k}=$(percent_encode "$v")"
  done
  local sts="GET&$(percent_encode '/')&$(percent_encode "$query")"
  local sig=$(printf '%s' "$sts" | openssl dgst -sha1 -hmac "${SK}&" -binary | openssl base64)
  local url="https://${ENDPOINT}/?${query}&Signature=$(percent_encode "$sig")"
  curl -s --connect-timeout 15 --max-time 120 "$url"
}

# ---- ECS: 一步 RunCommand ----
invoke_ecs() {
  local ids_json="$1"
  rpc_call RunCommand \
    "Type=RunShellScript" "CommandContent=$CMD_B64" "InstanceIds=$ids_json" \
    "Timeout=600" "WorkingDir=/root" "Name=ipes-kernel-upgrade"
}

# ---- SWAS: CreateCommand + InvokeCommand ----
invoke_swas() {
  local ids_json="$1"
  local create_resp=$(rpc_call CreateCommand \
    "Type=RunShellScript" "CommandContent=$CMD_B64" "Timeout=600" \
    "WorkingDir=/root" "Name=ipes-kernel-upgrade" "Description=BBR-kernel-upgrade")
  local cmd_id=$(printf '%s' "$create_resp" | grep -o '"CommandId":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//')
  if [ -z "$cmd_id" ]; then echo "  [SWAS] CreateCommand 失败: $create_resp"; return 1; fi
  rpc_call InvokeCommand "CommandId=$cmd_id" "InstanceIds=$ids_json"
}

# ---- 分批下发 ----
IFS=',' read -ra ARR <<< "$INSTANCES"
TOTAL=${#ARR[@]}
echo "共 $TOTAL 台，每批 $BATCH 台，批间隔 ${INTERVAL}s"
n=0
while [ $n -lt $TOTAL ]; do
  batch=("${ARR[@]:$n:$BATCH}")
  ids_json=$(printf '["%s"]' "$(IFS=','; echo "${batch[*]}")")
  echo ">>> 批次 $((n/BATCH+1)): ${batch[*]}"
  if [ "$PRODUCT" = "ecs" ]; then
    invoke_ecs "$ids_json"
  else
    invoke_swas "$ids_json"
  fi
  echo ""
  n=$((n+BATCH))
  [ $n -lt $TOTAL ] && { echo "    等待 ${INTERVAL}s 下一批..."; sleep "$INTERVAL"; }
done
echo "=== 下发完成。实例将在 ~20s 后陆续重启，请观察 IPES 自动恢复 + BBR 生效 ==="
echo "=== 复核: sysctl net.ipv4.tcp_congestion_control  (应为 bbr) ==="

#!/bin/bash
# =============================================================================
# 单节点补完：待配置 -> 提交业务41 -> 服务中（携带业务ID）
# -----------------------------------------------------------------------------
# 适用场景：ipes_deploy_full.sh 因内置 HMAC 凭据已失效，导致 updateEdgeNominalInfo
#           （业务属性）写不进、节点卡在「待配置」、业务ID为空。
#           本脚本用 NODE_ACTIVATE_TOKEN（后台 x-token JWT，可与 stateflow 通用）
#           直接补完最后两步。
#
# 用法（在目标机上，root 执行）：
#   export NODE_ACTIVATE_TOKEN="<后台 x-token JWT，有效期约3天>"
#   bash complete_node.sh
# =============================================================================
#
# ── 已知事项：BBR 拥塞控制 与 内核版本 ────────────────────────────────────────
# 本脚本只做「业务绑定+流转」，不碰内核。若你同时跑了 ipes_quick_deploy.sh 的调优：
#   * BBR 需内核 >= 4.9；CentOS 7 默认 3.10 内核无 tcp_bbr 模块，脚本会自动回退 cubic。
#   * 其余调优（conntrack 表/RPS/NOTRACK/socket 缓冲等）在 3.10 上全部生效。
#   * 想真正启用 BBR：把内核升到 elrepo kernel-ml(>=4.9)，见仓库 fleet_kernel_upgrade.sh
#     （走阿里云云助手批量下发，重启后 99-ipes-bbr.conf 自动生效）。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

TOKEN="${NODE_ACTIVATE_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    echo -e "\033[0;31m[错误]\033[0m 请先 export NODE_ACTIVATE_TOKEN=<后台 x-token JWT>\033[0m"
    exit 1
fi

node=$(cat /etc/.mac 2>/dev/null | tr -d '[:space:]')
if [ -z "$node" ]; then
    echo -e "\033[0;31m[错误]\033[0m 取不到 nodeId（/etc/.mac 不存在）"; exit 1
fi

# IPES 容器序列号 = 后台「业务ID」（business_tags.hostName）
biz=$(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n')
[ -z "$biz" ] && biz=$(docker exec ipes cat /bin/ipses_sn 2>/dev/null | tr -d '\r\n')
[ -z "$biz" ] && biz=$(docker exec ipes cat /opt/soft/disk/IPES_SN 2>/dev/null | tr -d '\r\n')
if [ -z "$biz" ]; then
    echo -e "\033[1;33m[警告]\033[0m 取不到 IPES 序列号（docker 未起？），流转将不带业务ID（后台写占位符）"
else
    echo "nodeId=$node  bizSn=${biz:0:16}..."
fi

# 省份/城市：优先取部署脚本写回的 registration_info，否则自动探测
if [ -f /usr/local/edge/registration_info ]; then
    province=$(awk -F': ' '/^省份:/{print $2}' /usr/local/edge/registration_info)
    city=$(awk -F': ' '/^城市:/{print $2}' /usr/local/edge/registration_info)
    isp=$(awk -F': ' '/^运营商:/{print $2}' /usr/local/edge/registration_info)
fi
if [ -z "${province:-}" ]; then
    read -r _ _ _ province city _ < <(curl -s --max-time 10 myip.ipip.net)
    province=${province%,}; city=${city%,}
fi
isp="${isp:-电信}"
echo "位置: ${province:-未知} / ${city:-未知}  运营商: $isp"

HOST="https://admin.zhouyi.top"

echo "== 1) 提交业务41（待配置下才允许改设备信息）=="
resp=$(curl -k -s -w "\n%{http_code}" -X POST "$HOST/api/edgeNode/updateEdgeNominalInfo" \
  -H "X-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"nodeId\":\"$node\",\"province\":\"$province\",\"city\":\"$city\",\"isp\":\"$isp\",\"natType\":\"public\",\"resourceType\":\"2\",\"dialType\":\"staticNetSingle\",\"singleIpRadio\":0,\"usbw\":200,\"bwNum\":1,\"transMode\":0,\"transProvRate\":0,\"isTransProv\":true,\"isIPv6Schedule\":false,\"isCrossNetwork\":false,\"crossNetworkIsp\":null,\"vendorSuggestCustomers\":41}")
echo "  HTTP=$(echo "$resp"|tail -n1)  BODY=$(echo "$resp"|sed '$d')"

echo "== 2) 流转 待配置 -> 服务中（携带业务ID）=="
if [ -n "$biz" ]; then
    body="{\"nodes\":[\"$node\"],\"stage\":\"inService\",\"hostname\":\"$biz\"}"
else
    body="{\"nodes\":[\"$node\"],\"stage\":\"inService\"}"
fi
resp=$(curl -k -s -w "\n%{http_code}" -X POST "$HOST/api/edgeNode/stateflow" \
  -H "X-Token: $TOKEN" -H 'Content-Type: application/json' -d "$body")
echo "  HTTP=$(echo "$resp"|tail -n1)  BODY=$(echo "$resp"|sed '$d')"

echo "== 3) 复核 =="
curl -k -s "$HOST/api/edgeNode/findEdgeNode?nodeId=$node" -H "X-Token: $TOKEN" | head -c 800
echo
echo "提示：若 findEdgeNode 返回 stage=inService 且 hostName 为真实 76 位序列号，即成功。"

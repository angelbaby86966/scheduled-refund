#!/bin/bash
# =============================================================================
# set_node_biz_id.sh —— 回填后台「业务ID」（business_tags.hostName）
#
# 背景（2026-09-13 实测确认）：
#   后台列表/悬浮卡显示的「业务ID」= business_tags.hostName，
#   其真实值 = IPES 容器生成的序列号（76 位 hex）：
#       docker exec ipes cat /app/ipes/bin/ipes_sn
#   平台在「状态流转到服务中」时创建该标签记录；
#   如果流转请求里 **没有带 hostname**，平台就写死占位符 "ZHOUYI_XIAODU占位符"。
#
#   正确接口（唯一可行通道，其它都不行）：
#       POST https://admin.zhouyi.top/api/edgeNode/stateflow
#       Header: X-Token: <JWT>
#       Body:   {"nodes":["<节点ID>"],"stage":"inService","hostname":"<业务ID>"}
#   注意：平台在「服务中」状态不允许修改信息 → 必须「先降到 configured，再升回 inService」，
#         第二次请求携带 hostname 才会写库。
#
#   踩坑记录：
#     - PUT /api/businessTag/updateBusinessTag → 普通账号「权限不足」(code:7)
#     - POST /api/businessTag/createBusinessTag / nodeBusinessChange → 同样无权限
#     - appId+HMAC 签名通道对该类接口 401（只对 updateEdgeNominalInfo 有效）
#     - business_tags.mac 是 32 位 base32 随机值，本地不可推导 → 不要伪造，留空即可
#
# 用法：
#   NODE_ACTIVATE_TOKEN='<JWT>' bash set_node_biz_id.sh [节点ID]
#   节点ID 省略时读 /etc/.mac
# =============================================================================
set -u

API_HOST="${ADMIN_API_HOST:-https://admin.zhouyi.top}"
API_STATEFLOW="${ADMIN_STATUS_API:-/api/edgeNode/stateflow}"
API_TAGLIST="${ADMIN_BUSINESS_TAG_LIST_API:-/api/businessTag/getBusinessTagList}"
TOKEN="${NODE_ACTIVATE_TOKEN:-${ADMIN_TOKEN:-}}"
ISP="${ISP:-电信}"
SLEEP="${SLEEP_BETWEEN:-5}"

NODE_ID="${1:-}"
[ -z "$NODE_ID" ] && NODE_ID=$(cat /etc/.mac 2>/dev/null | tr -d ' \r\n')

if [ -z "$NODE_ID" ]; then
    echo "[失败] 未指定节点ID，且 /etc/.mac 不可读"
    exit 1
fi
if [ -z "$TOKEN" ]; then
    echo "[失败] 需要 JWT：NODE_ACTIVATE_TOKEN='<token>' bash $0 $NODE_ID"
    exit 1
fi

# ---- 1) 读 IPES 业务ID ----
BIZ_SN=""
if command -v docker >/dev/null 2>&1; then
    BIZ_SN=$(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d ' \r\n')
    [ -z "$BIZ_SN" ] && BIZ_SN=$(docker exec ipes cat /opt/soft/disk/IPES_SN 2>/dev/null | tr -d ' \r\n')
fi
if [ -z "$BIZ_SN" ]; then
    echo "[失败] 取不到 IPES 序列号（容器未就绪？）"
    echo "       请确认：docker ps | grep ipes"
    exit 2
fi

echo "[信息] 节点ID : $NODE_ID"
echo "[信息] 业务ID : $BIZ_SN"

# ---- 2) 回读当前值（若已正确则直接退出）----
cur=$(curl -k -s -m 30 -H "X-Token: $TOKEN" \
    "$API_HOST$API_TAGLIST?page=1&pageSize=5&nodeId=$NODE_ID" 2>/dev/null \
    | sed -n 's/.*"hostName":"\([^"]*\)".*/\1/p' | head -1)
echo "[信息] 当前后台值: ${cur:-（无记录）}"
if [ -n "$cur" ] && [ "$cur" = "$BIZ_SN" ]; then
    echo "[成功] 后台业务ID 已经是正确值，无需修改"
    exit 0
fi

# ---- 3) 先降到「待配置」----
resp=$(curl -k -s -m 30 -X POST -H "X-Token: $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"nodes\":[\"$NODE_ID\"],\"stage\":\"configured\"}" "$API_HOST$API_STATEFLOW" 2>&1)
echo "[信息] 第1步(->待配置): $(echo "$resp" | head -c 200)"
case "$resp" in
    *'"code":0'*) : ;;
    *) echo "[警告] 第1步未返回成功，继续尝试第2步..." ;;
esac
sleep "$SLEEP"

# ---- 4) 带 hostname 升回「服务中」----
resp=$(curl -k -s -m 30 -X POST -H "X-Token: $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"nodes\":[\"$NODE_ID\"],\"stage\":\"inService\",\"hostname\":\"$BIZ_SN\"}" \
    "$API_HOST$API_STATEFLOW" 2>&1)
echo "[信息] 第2步(->服务中): $(echo "$resp" | head -c 200)"

# ---- 5) 回读校验 ----
sleep 3
final=$(curl -k -s -m 30 -H "X-Token: $TOKEN" \
    "$API_HOST$API_TAGLIST?page=1&pageSize=5&nodeId=$NODE_ID" 2>/dev/null)
val=$(echo "$final" | sed -n 's/.*"hostName":"\([^"]*\)".*/\1/p' | head -1)

if [ "$val" = "$BIZ_SN" ]; then
    echo "[成功] 业务ID 已写入后台：$val"
    exit 0
fi

echo "[失败] 写入未生效，回读值: ${val:-（空）}"
echo "       期望值: $BIZ_SN"
echo "       排查：1) JWT 是否有效/有权限  2) 节点是否处于可流转状态"
exit 5

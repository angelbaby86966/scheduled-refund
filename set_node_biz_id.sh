#!/bin/bash
# =============================================================================
# set_node_biz_id.sh —— 回填后台「业务标签」里的 **业务ID**
# -----------------------------------------------------------------------------
# 背景：admin.zhouyi.top 节点列表 hover 提示里的「业务ID」= business_tags[].hostName，
#       真实来源是 **IPES 容器本地生成的序列号**：
#           /app/ipes/bin/ipes_sn      -> 76 位 hex（64+12；业务41后缀固定 69bccfe3bf24）
#           /app/ipes/bin/ipes_phy_sn  -> 物理SN（32 位 hex）
#       平台在节点流转「服务中」时会自动建 business_tags 记录，但节点没上报成功时
#       只写占位符 "ZHOUYI_XIAODU占位符"，需要本脚本回填。
#
# ⚠️ mac 字段**不要**用 ipes_phy_sn 顶替：
#    实测正常节点（64e 工作机 / 同批 110 台）的 mac 是 **32 位 base32** 的 20 字节随机值
#    （例：tip33hc3m5gterglsxm4s7ih74ntcp5x），由节点/平台侧生成，无法本地推导。
#    本脚本策略：**保留记录里已有的 mac，取不到就留空**，绝不臆造。
#
# 用法（在节点上执行）：
#   ADMIN_TOKEN=<JWT> bash set_node_biz_id.sh [nodeId] [运营商]
#   NODE_ACTIVATE_TOKEN=<JWT> bash set_node_biz_id.sh [nodeId] [运营商]
#
# 示例：
#   ADMIN_TOKEN=eyJhbG... bash set_node_biz_id.sh 3509392d18f030d85104e2f2d6eb2a55 电信
#
# 说明：
#   - nodeId 省略时自动取 /etc/.mac -> /usr/local/edge_zycloud/device_code -> hostname
#   - 运营商省略时读 /opt/ipes/var/db/ipes/happ-conf/custom.yml 的 reg_isp(1=电信 2=联通 3=移动)
#   - 写接口需要账号具备「业务标签」写权限；无权限会返回 {"code":7,"msg":"权限不足"}，
#     此时请改用有权限的账号 token，或到后台「业务标签」页面手工填（脚本会打印要填的值）
# =============================================================================
set -u

API_HOST="${ADMIN_API_HOST:-https://admin.zhouyi.top}"
API_LIST="${ADMIN_BUSINESS_TAG_LIST_API:-/api/businessTag/getBusinessTagList}"
API_UPDATE="${ADMIN_BUSINESS_TAG_UPDATE_API:-/api/businessTag/updateBusinessTag}"
API_CREATE="${ADMIN_BUSINESS_TAG_CREATE_API:-/api/businessTag/createBusinessTag}"
BIZ_TYPE="${NODE_BIZ_TYPE:-Q-Q2}"
BUSINESS_ID="${BUSINESS_ID:-41}"

TOKEN="${ADMIN_TOKEN:-${NODE_ACTIVATE_TOKEN:-${X_TOKEN:-}}}"
if [ -z "$TOKEN" ]; then
    echo "[错误] 缺少 token：请用 ADMIN_TOKEN=<JWT> bash $0 ..."
    exit 2
fi

# ---- 1) 设备ID(nodeId) ----
NODE_ID="${1:-}"
if [ -z "$NODE_ID" ]; then
    for f in /etc/.mac /usr/local/edge_zycloud/device_code /usr/local/edge/device_code; do
        [ -s "$f" ] && NODE_ID=$(tr -d ' \r\n' < "$f") && [ -n "$NODE_ID" ] && break
    done
fi
[ -z "$NODE_ID" ] && NODE_ID=$(hostname)
echo "[信息] 设备ID(nodeId): $NODE_ID"

# ---- 2) 运营商 ----
ISP="${2:-}"
if [ -z "$ISP" ]; then
    reg=$(grep -E '^reg_isp:' /opt/ipes/var/db/ipes/happ-conf/custom.yml 2>/dev/null | head -1 | awk '{print $2}')
    case "$reg" in
        1) ISP="电信" ;;
        2) ISP="联通" ;;
        3) ISP="移动" ;;
        *) ISP="电信" ;;
    esac
fi
echo "[信息] 运营商: $ISP"

# ---- 3) 从 IPES 容器读真实业务ID ----
BIZ_SN=""
PHY_SN=""
if command -v docker >/dev/null 2>&1; then
    BIZ_SN=$(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d ' \r\n')
    PHY_SN=$(docker exec ipes cat /app/ipes/bin/ipes_phy_sn 2>/dev/null | tr -d ' \r\n')
fi
if [ -z "$BIZ_SN" ]; then
    echo "[错误] 取不到 IPES 序列号（容器 ipes 未运行？），无法回填"
    exit 3
fi
echo "[信息] 业务ID(IPES sn): $BIZ_SN"
echo "[信息] 物理SN(参考)   : $PHY_SN"

# ---- 4) 查已有标签记录 ----
resp=$(curl -k -s -m 30 -H "X-Token: $TOKEN" \
    "$API_HOST$API_LIST?page=1&pageSize=5&nodeId=$NODE_ID" 2>&1)
echo "[信息] 当前标签: $(echo "$resp" | head -c 400)"
TAG_ID=$(echo "$resp" | sed -n 's/.*"ID":\([0-9]\{1,\}\).*/\1/p' | head -1)
# 保留已有 mac（平台/节点侧生成的 20 字节 base32），取不到就留空
EXIST_MAC=$(echo "$resp" | sed -n 's/.*"mac":"\([^"]*\)".*/\1/p' | head -1)
EXIST_TELEGRAF=$(echo "$resp" | sed -n 's/.*"telegraf":"\([^"]*\)".*/\1/p' | head -1)
echo "[信息] 已有 mac: ${EXIST_MAC:-<空>}"

# ---- 5) 覆盖 / 新建 ----
if [ -n "$TAG_ID" ]; then
    echo "[信息] 命中已有记录 ID=$TAG_ID，执行更新"
    payload="{\"ID\":${TAG_ID},\"nodeId\":\"${NODE_ID}\",\"hostName\":\"${BIZ_SN}\",\"isp\":\"${ISP}\",\"deviceArch\":\"\",\"mac\":\"${EXIST_MAC:-}\",\"telegraf\":\"${EXIST_TELEGRAF:-}\",\"bizType\":\"${BIZ_TYPE}\",\"businessID\":${BUSINESS_ID}}"
    out=$(curl -k -s -m 30 -X PUT -H "X-Token: $TOKEN" -H 'Content-Type: application/json' \
        -d "$payload" "$API_HOST$API_UPDATE" 2>&1)
else
    echo "[信息] 未找到记录，执行新建"
    payload="{\"nodeId\":\"${NODE_ID}\",\"hostName\":\"${BIZ_SN}\",\"isp\":\"${ISP}\",\"deviceArch\":\"\",\"mac\":\"\",\"telegraf\":\"\"}"
    out=$(curl -k -s -m 30 -X POST -H "X-Token: $TOKEN" -H 'Content-Type: application/json' \
        -d "$payload" "$API_HOST$API_CREATE" 2>&1)
fi
echo "[信息] 写入响应: $(echo "$out" | head -c 400)"

case "$out" in
    *'"code":0'*)
        echo "[成功] 业务ID 已写入后台"
        echo "       节点ID=$NODE_ID"
        echo "       业务ID=$BIZ_SN"
        echo "       运营商=$ISP"
        exit 0
        ;;
    *权限不足*)
        echo "[警告] 当前账号没有「业务标签」写权限，请改用有权限的账号 token，"
        echo "       或到后台 →「业务标签」页面找 nodeId=$NODE_ID 那行点「编辑」，手工填入："
        echo "        主机名(业务ID) = $BIZ_SN"
        echo "        运营商         = $ISP"
        exit 4
        ;;
    *)
        echo "[失败] 写入未成功，请检查接口路径 / token 是否过期"
        exit 5
        ;;
esac

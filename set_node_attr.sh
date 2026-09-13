#!/usr/bin/env bash
# =============================================================================
# zhouyi 节点「业务线运营商 / 资源-上网方式」修复器
# -----------------------------------------------------------------------------
# 背景：admin.zhouyi.top 节点列表里的两列
#         业务线运营商  <- nodeInfo.isp
#         资源/上网方式 <- nodeInfo.resourceType(1=汇聚 2=专线) + nodeInfo.dialType
#       官方 zyy_init_max.sh 只在【渠道注册】时写了顶层 isp（channels 侧），
#       并不会写 nodeInfo，所以新节点在后台这两列是空的 / 显示「其他」。
#
# 本脚本用后台真实接口把这两列补上（与 admin 前端「编辑节点」等价）：
#         GET  /api/edgeNode/findEdgeNode?nodeId=<SN>   取节点完整对象
#         PUT  /api/edgeNode/updateEdgeNode             整对象回写（只改 nodeInfo 几个字段）
#       鉴权：Header  X-Token: <JWT>（后台登录 token）
#
# 用法：
#   NODE_ACTIVATE_TOKEN='<JWT>' ./set_node_attr.sh <SN> [isp] [resourceType] [dialType]
#   NODE_ACTIVATE_TOKEN='<JWT>' ./set_node_attr.sh 3509392d18f030d85104e2f2d6eb2a55 电信 2 staticNetSingle
#
# 参数默认值：isp=电信  resourceType=2(专线)  dialType=staticNetSingle(固定公网单 IP)
#   resourceType: 1=汇聚  2=专线
#   dialType: staticNetSingle=固定公网单 IP | staticNetCouple=固定公网多 IP | serverDial=服务器拨号
#             dhcpNetSingle=DHCP单 IP      | dhcpNetCouple=DHCP多 IP     | virtualRoute=软路由
#
# 注意：token 只从环境变量读，不要写进本文件、不要进命令行历史。
# =============================================================================
set -uo pipefail

SN="${1:-}"
ISP="${2:-电信}"
RES_TYPE="${3:-2}"
DIAL_TYPE="${4:-staticNetSingle}"

TOKEN="${NODE_ACTIVATE_TOKEN:-${ADMIN_TOKEN:-}}"
API_HOST="${ADMIN_API_HOST:-https://admin.zhouyi.top}"
API="${API_HOST}/api/edgeNode"

if [ -z "$SN" ]; then
    echo "用法: NODE_ACTIVATE_TOKEN='<JWT>' $0 <SN> [isp] [resourceType] [dialType]"
    exit 2
fi
if [ -z "$TOKEN" ]; then
    echo "[错误] 缺少 token：请设置环境变量 NODE_ACTIVATE_TOKEN（后台 JWT）"
    exit 2
fi

# 选一个可用的 python（json 处理；网络仍走 curl，避免老 python 的 TLS 问题）
PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
    echo "[错误] 未找到 python/python3，无法安全改写 JSON"
    exit 3
fi

TMP_BEFORE=/tmp/zyy_node_before.json
TMP_AFTER=/tmp/zyy_node_after.json

echo ">> [1/4] 读取节点: $SN"
HTTP=$(curl -k -s -o "$TMP_BEFORE" -w '%{http_code}' -m 30 \
    -H "X-Token: $TOKEN" "$API/findEdgeNode?nodeId=$SN")
echo "   HTTP=$HTTP"
[ "$HTTP" = "200" ] || { echo "[错误] 读取失败：$(head -c 300 "$TMP_BEFORE")"; exit 4; }

echo ">> [2/4] 改写 nodeInfo: isp=$ISP resourceType=$RES_TYPE dialType=$DIAL_TYPE"
"$PY" - "$TMP_BEFORE" "$TMP_AFTER" "$ISP" "$RES_TYPE" "$DIAL_TYPE" <<'PYEOF'
# -*- coding: utf-8 -*-
import json, sys
src, dst, isp, rtype, dtype = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
d = json.load(open(src, encoding='utf-8') if sys.version_info[0] >= 3 else open(src))
data = d.get('data') or {}
ni = data.get('nodeInfo') or {}
keys = ['isp', 'resourceType', 'dialType', 'natType', 'province', 'city']
print('   BEFORE: ' + json.dumps(dict((k, ni.get(k)) for k in keys), ensure_ascii=False))
ni['isp'] = isp
ni['resourceType'] = rtype
ni['dialType'] = dtype
if not ni.get('natType'):
    ni['natType'] = 'public'
if not ni.get('province'):
    ni['province'] = data.get('province') or ''
if not ni.get('city'):
    ni['city'] = data.get('city') or ''
if not ni.get('stage'):
    ni['stage'] = data.get('stage') or 'inService'
data['nodeInfo'] = ni
print('   AFTER : ' + json.dumps(dict((k, ni.get(k)) for k in keys), ensure_ascii=False))
with open(dst, 'w', encoding='utf-8') if sys.version_info[0] >= 3 else open(dst, 'w') as f:
    f.write(json.dumps(data, ensure_ascii=False))
PYEOF
[ $? -eq 0 ] || { echo "[错误] JSON 改写失败"; exit 5; }

echo ">> [3/4] PUT /api/edgeNode/updateEdgeNode"
RESP=$(curl -k -s -w '\n%{http_code}' -m 40 -X PUT \
    -H "X-Token: $TOKEN" -H 'Content-Type: application/json' \
    --data @"$TMP_AFTER" "$API/updateEdgeNode")
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
echo "   HTTP=$CODE  $BODY"
case "$BODY" in
    *'"code":0'*) echo "   [成功] 已提交" ;;
    *) echo "   [警告] 返回非成功，请检查是否正确/权限" ;;
esac

echo ">> [4/4] 回读校验"
curl -k -s -m 30 -H "X-Token: $TOKEN" "$API/findEdgeNode?nodeId=$SN" -o "$TMP_AFTER"
"$PY" - "$TMP_AFTER" <<'PYEOF'
# -*- coding: utf-8 -*-
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8') if sys.version_info[0] >= 3 else open(sys.argv[1]))
ni = (d.get('data') or {}).get('nodeInfo') or {}
rt = {1: '汇聚', 2: '专线', '1': '汇聚', '2': '专线'}.get(ni.get('resourceType'), '')
dt = {'staticNetSingle': '固定公网单 IP', 'staticNetCouple': '固定公网多 IP',
      'serverDial': '服务器拨号', 'dhcpNetSingle': 'DHCP单 IP',
      'dhcpNetCouple': 'DHCP多 IP', 'virtualRoute': '软路由'}.get(ni.get('dialType'), '其他')
print('   业务线运营商 = %s' % (ni.get('isp') or '(空)'))
print('   资源/上网方式 = %s %s' % (rt, dt))
PYEOF
echo ">> 完成。回到 admin.zhouyi.top 节点列表刷新即可看到这两列。"

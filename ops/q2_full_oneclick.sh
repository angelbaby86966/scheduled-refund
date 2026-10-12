#!/bin/bash
# ==============================================================================
# 舟翼云 q2（业务41）一键部署 · 完整版（全新机器从零开始）
#
#   ⓪ 渠道绑定(zyy_init_max)      —— 生成 device_code / 装 agent / 设备注册
#   ① 占位符流转「服务中」          —— 先让节点可被调度
#   ② 部署 docker + Q2 业务(9 路)   —— Q2 官方链路，纯净版无系统调优
#   ③ 保活(每分钟健康检查 + 开机自启)
#   ④ 真 76hex SN 回填 + 再流转      —— 降级→提交属性→升回服务中
#   ⑤ 限速(23:59 挂 / 18:25 解)
#
# 纯净版：不含 BBR/fq/RPS/conntrack 等任何系统调优；happy 固定 9 路。
# 用法：改好下面 4 个参数 → 整段贴进云助手「命令助手」执行（超时 ≥1800 秒）
# ==============================================================================
JWT="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJVVUlEIjoiMzhjZTQ2YTctZDNkMi00YzVlLWJkNTYtM2I3YTEwM2Q2ZjIiLCJJRCI6NDAsIlVzZXJuYW1lIjoiMTc2OTU5Mzc3NTYiLCJOaWNrTmFtZSI6IuS4queivOiJ9.-lpWIqfGtjcaGLcvVIF5xQ6WeVf0siv9lB4k3aMglfg"
CHAN_AK="06d78b19bd0d9fc0aa300c6d"
CHAN_SK="16d6c46443308e62bb51f22c074a90ed"
ISP="联通"

# 下面两个一般不用改
PLACEHOLDER="ZHOUYI_XIAODU"
ADMIN_API="https://admin.zhouyi.top"
OSS="https://zyy-go.oss-cn-beijing.aliyuncs.com/script"
# 后台凭证（属性提交用：appId + HMAC-SHA256 签名）
ADMIN_APPID="fg5c21pbzfgu6y2s2yqvanvr6uv99drq"
ADMIN_AK="ja3io44nq2m7hx63fjkpio7s422aksel"
ADMIN_SK="ydDGuguZ8COcJN4Ztl3Lsic3Z00zGEani8fYOPiYk2XXCuXQ1AHyy7E1sgV4dyDT"

LOG=/var/log/q2_full.log
mkdir -p /var/log
exec > >(tee -a "$LOG") 2>&1
echo "============ q2 完整版开始 $(date '+%F %T') ============"

# ---------------- JWT 有效期预检（避免白跑一轮） ----------------
JWT_TS=$(python3 -c "
import base64,json
try:
    p='$JWT'.split('.')[1]; p+='='*(-len(p)%4)
    print(int(json.loads(base64.urlsafe_b64decode(p).decode('utf-8','replace')).get('exp',0)))
except Exception:
    print(0)
" 2>/dev/null)
if [ -n "$JWT_TS" ] && [ "$JWT_TS" -gt 0 ] 2>/dev/null; then
  NOW=$(date +%s)
  if [ "$JWT_TS" -lt "$NOW" ]; then
    echo "!!!!!! 严重警告：JWT 已过期（过期时间 $(date -d @"$JWT_TS" '+%F %T')，当前 $(date '+%F %T')）!!!!!!"
    echo "!!!!!! ① 占位符流转 与 ④ 真SN回填 会返回 401，节点将卡在「待配置」 !!!!!!"
    echo "!!!!!! 请把脚本顶部 JWT= 那一行换成新的 token 再跑                    !!!!!!"
    echo
  fi
fi

# ---------------- 工具函数 ----------------
node_id() { cat /usr/local/edge_zycloud/device_code 2>/dev/null || cat /etc/.mac 2>/dev/null; }
# 流转：$1=nodeID $2=hostname $3=stage
flow() {
  curl -fsS -m 30 -X POST "$ADMIN_API/api/edgeNode/stateflow" \
    -H "Content-Type: application/json" -H "X-Token: $JWT" \
    -d "{\"nodes\":[\"$1\"],\"hostname\":\"$2\",\"stage\":\"$3\"}" 2>&1
}
# 提交属性（业务41 / 200M / 上网方式），appId 签名
submit_nominal() {
  local nid="$1" prov="$2" city="$3" ts sign
  ts=$(date +%s)
  sign=$(printf '%s' "${ADMIN_AK}:${ts}" | openssl dgst -sha256 -hmac "$ADMIN_SK" | cut -d' ' -f2)
  curl -fsS -k -m 30 -X POST "$ADMIN_API/api/edgeNode/updateEdgeNominalInfo" \
    -H "Content-Type: application/json" -H "appId: $ADMIN_APPID" \
    -H "timestamp: $ts" -H "sign: $sign" \
    -d "{\"nodeId\":\"$nid\",\"province\":\"$prov\",\"city\":\"$city\",\"isp\":\"$ISP\",\"natType\":\"public\",\"resourceType\":\"2\",\"dialType\":\"staticNetSingle\",\"vendorSuggestCustomers\":41,\"usbw\":200,\"bwNum\":1,\"isCrossNetwork\":false,\"crossNetworkIsp\":null,\"isTransProv\":false,\"transMode\":1}" 2>&1
}
detect_loc() {
  local info p c
  info=$(curl -s --retry 2 --max-time 10 myip.ipip.net)
  p=$(echo "$info" | awk -F' ' '{print $4}' | tr -d ',')
  c=$(echo "$info" | awk -F' ' '{print $5}' | tr -d ',')
  [ -z "$p" ] && p="浙江"; [ -z "$c" ] && c="杭州"
  echo "${p}|${c}"
}

# ==============================================================================
# ⓪ 渠道绑定（已有 device_code 会自动跳过重装）
# ==============================================================================
echo; echo "===== [0/5] 渠道绑定 zyy_init_max ====="
if [ -f /usr/local/edge/registration_info ] && grep -q "注册状态: 成功" /usr/local/edge/registration_info 2>/dev/null && [ -n "$(node_id)" ]; then
  echo "[跳过] 本机已绑定过（device_code=$(node_id)）"
else
  curl -fsSL -m 900 "$OSS/zyy_init/zyy_init_max.sh" | bash -s -- --ak "$CHAN_AK" --sk "$CHAN_SK" --isp "$ISP" --num-dirs 12
  echo "[绑定] 返回码=$?"
  sleep 5
fi
NID=$(node_id)
echo "nodeID = ${NID:-未生成}"
[ -z "$NID" ] && { echo "[致命] 绑定失败，没有 device_code，后续步骤无法进行"; exit 1; }

# ==============================================================================
# ① 占位符流转「服务中」
# ==============================================================================
echo; echo "===== [1/5] 占位符流转「服务中」 ====="
R1=$(flow "$NID" "$PLACEHOLDER" "inService")
echo "流转: $R1"
case "$R1" in
  *'"code":0'*) echo "[OK] 已进入服务中（业务ID 为占位符，第4步回填真SN）" ;;
  *) echo "[提示] 未成功（已在服务中 / 节点刚创建未同步），不阻断后续" ;;
esac

# ==============================================================================
# ② 部署：docker + Q2 业务（9 路）
# ==============================================================================
echo; echo "===== [2/5] 部署：docker + Q2 业务(9路) ====="
curl -fsSL -m 300 "$OSS/install_docker/install_docker-ce_v2.sh" | bash
echo "[docker] 返回码=$?"
curl -fsSL -m 1800 "$OSS/Q2_test/ecache_auto_disk_install.sh" | bash -s -- -i 2 -t 2
echo "[Q2部署] 返回码=$?"

# ==============================================================================
# ③ 保活
# ==============================================================================
echo; echo "===== [3/5] 安装保活（每分钟 + 开机自启） ====="
curl -fsSL -m 120 "$OSS/Q2_test/install_ipes_health_check.sh" | bash
echo "[保活] 返回码=$?"

# ==============================================================================
# ④ 真 76hex SN 回填 + 再流转
# ==============================================================================
echo; echo "===== [4/5] 真SN回填 + 再流转 ====="
SN=""
for i in 1 2 3 4 5 6; do           # 容器刚起时 SN 可能还没写好，最多等 3 分钟
  SN=$(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n')
  [ ${#SN} -ge 60 ] && break
  sleep 30
done
echo "真SN = ${SN:-未取到}"
if [ ${#SN} -ge 60 ]; then
  LOC=$(detect_loc); PROV=${LOC%%|*}; CITY=${LOC##*|}
  echo "-- 4.1 降级 inService -> configured"; echo "   $(flow "$NID" "$SN" configured)"
  echo "-- 4.2 提交属性（业务41/200M/${ISP}，${PROV}${CITY}）"; echo "   $(submit_nominal "$NID" "$PROV" "$CITY")"
  sleep 2
  echo "-- 4.3 升回 configured -> inService（带真SN）"; echo "   $(flow "$NID" "$SN" inService)"
else
  echo "[跳过] 未取到真SN；部署可能仍在进行。稍后重跑本脚本会自动只补这一步"
fi

# ==============================================================================
# ⑤ 限速 23:59 挂 / 18:25 解
# ==============================================================================
echo; echo "===== [5/5] 挂限速（23:59 → 18:25） ====="
curl -fsSL -m 180 "$OSS/limit/run_limit.sh" | tr -d '\r' | bash -s -- "23:59" "18:25"
echo "[限速] 返回码=$?"

# ==============================================================================
# 验收
# ==============================================================================
echo; echo "==================== 验收 ===================="
echo "容器     : $(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | tr '\n' ' ')"
echo "happ 路数: $(docker exec ipes ls /data/happ 2>/dev/null | grep -c happ)  (期望 9)"
echo "真SN     : $(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | head -c 76)"
echo "SN 长度  : $(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n' | wc -c)  (期望 76)"
echo "保活cron : $(crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check') 条"
echo "限速规则 : $(tc qdisc show dev eth0 2>/dev/null | grep -c htb) 条 (1=已挂)"
echo "限速cron : $(crontab -l 2>/dev/null | grep -cE 'limit_start|clear_limit') 条"
echo "拥塞控制 : $(cat /proc/sys/net/ipv4/tcp_congestion_control)  (纯净版=cubic)"
echo "默认队列 : $(cat /proc/sys/net/core/default_qdisc)  (纯净版=pfifo_fast)"
echo "nodeID   : $(node_id)"
echo "============ 完成 $(date '+%F %T') ============"
echo "日志: $LOG"
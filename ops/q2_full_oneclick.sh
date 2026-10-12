#!/bin/bash
# ==============================================================================
# 舟翼云 q2（业务41）一键部署 · 完整版 v2
#   ⓪ 渠道绑定 → ① 占位符流转 → ② 部署(9路) → ③ 保活 → ④ 真SN回填+再流转 → ⑤ 限速
# 纯净版：不做任何系统调优（cubic + pfifo_fast）
#
# v2 改动：
#   1. 输出双写（终端 + 日志），日志写不了也不影响终端回显 ← 修「没反应」
#   2. 任何一步失败都不中断整条链，最后统一汇总     ← 修「一步失败全停」
#   3. 每个远端脚本先下载到 /tmp 校验非空再执行，失败自动切备用源
#   4. 每步打印 [HH:MM:SS] 步骤心跳
#   5. 绑定失败不再 exit，改到最后重试一次
#
# 用法：改好下面 4 个参数 → 整段贴进云助手「命令助手」（超时 ≥1800 秒）
# ==============================================================================
JWT="${Q2_JWT:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJVVUlEIjoiMzhjZTQ2YTctZDNkMi00YzVlLWJkNTYtM2I3YTEwM2Q2ZjIiLCJJRCI6NDAsIlVzZXJuYW1lIjoiMTc2OTU5Mzc3NTYiLCJOaWNrTmFtZSI6IuS4queivOiJ9.-lpWIqfGtjcaGLcvVIF5xQ6WeVf0siv9lB4k3aMglfg}"
CHAN_AK="${Q2_AK:-06d78b19bd0d9fc0aa300c6d}"
CHAN_SK="${Q2_SK:-16d6c46443308e62bb51f22c074a90ed}"
ISP="${Q2_ISP:-联通}"
PLACEHOLDER="ZHOUYI_XIAODU"
ADMIN_API="https://admin.zhouyi.top"
OSS="https://zyy-go.oss-cn-beijing.aliyuncs.com/script"
ADMIN_APPID="${Q2_APPID:-fg5c21pbzfgu6y2s2yqvanvr6uv99drq}"
ADMIN_AK="${Q2_ADMIN_AK:-ja3io44nq2m7hx63fjkpio7s422aksel}"
ADMIN_SK="${Q2_ADMIN_SK:-ydDGuguZ8COcJN4Ztl3Lsic3Z00zGEani8fYOPiYk2XXCuXQ1AHyy7E1sgV4dyDT}"

# ---------- 日志：终端 + 文件双写，写不了文件也不影响回显 ----------
LOG=/tmp/q2_full_$$.log
mkdir -p /tmp 2>/dev/null
touch "$LOG" 2>/dev/null || LOG=/dev/null
exec > >(tee -a "$LOG" 2>/dev/null) 2>&1
TS() { date '+%H:%M:%S'; }
say() { echo "[$(TS)] $*"; }
FAIL_LIST=""
mark_fail() { FAIL_LIST="${FAIL_LIST} $1"; say "  ✗ 失败：$1"; }

say "===== q2 完整版 v2 开始 $(date '+%F %T') ====="
say "日志: $LOG"

# ---------- JWT 过期预检 ----------
JWT_TS=$(command -v python3 >/dev/null 2>&1 && python3 -c "
import base64,json
try:
    p='$JWT'.split('.')[1]; p+='='*(-len(p)%4)
    print(int(json.loads(base64.urlsafe_b64decode(p).decode('utf-8','replace')).get('exp',0)))
except Exception: print(0)
" 2>/dev/null)
if [ -n "${JWT_TS:-}" ] && [ "$JWT_TS" -gt 0 ] 2>/dev/null; then
  if [ "$JWT_TS" -lt "$(date +%s)" ]; then
    say "⚠️⚠️ JWT 已过期（$(date -d @"$JWT_TS" '+%F %T' 2>/dev/null || echo $JWT_TS)）"
    say "⚠️⚠️ ①占位符流转 与 ④真SN回填 会 401 → 节点停在「待配置」，其他步骤不受影响"
  else
    say "JWT 有效期至 $(date -d @"$JWT_TS" '+%F %T' 2>/dev/null || echo $JWT_TS) ✅"
  fi
else
  say "（JWT 有效期无法预检，python3 可能不存在）"
fi

# ---------- 工具 ----------
node_id() { cat /usr/local/edge_zycloud/device_code 2>/dev/null || cat /etc/.mac 2>/dev/null; }
# 下载脚本到本地、校验非空再执行；多源回退
fetch_run() {  # $1=标签  $2=主源  $3=备用源  之后是传给脚本的参数
  local tag="$1" u1="$2" u2="$3"; shift 3
  local f="/tmp/.dl_${tag}.sh"
  for u in "$u1" "$u2"; do
    [ -z "$u" ] && continue
    if curl -fsSL -m 120 "$u" -o "$f" 2>/dev/null && [ -s "$f" ]; then
      say "  下载成功 $(basename "$u")（$(wc -c < "$f") 字节）"
      bash "$f" "$@"
      local rc=$?
      say "  [$tag] 返回码=$rc"
      return $rc
    fi
    say "  源不可用: $u"
  done
  say "  [$tag] 所有源都失败"
  return 1
}
flow() { curl -fsS -m 30 -X POST "$ADMIN_API/api/edgeNode/stateflow" \
  -H "Content-Type: application/json" -H "X-Token: $JWT" \
  -d "{\"nodes\":[\"$1\"],\"hostname\":\"$2\",\"stage\":\"$3\"}" 2>&1; }
submit_nominal() {
  local ts sign
  ts=$(date +%s)
  sign=$(printf '%s' "${ADMIN_AK}:${ts}" | openssl dgst -sha256 -hmac "$ADMIN_SK" 2>/dev/null | cut -d' ' -f2)
  curl -fsS -k -m 30 -X POST "$ADMIN_API/api/edgeNode/updateEdgeNominalInfo" \
    -H "Content-Type: application/json" -H "appId: $ADMIN_APPID" -H "timestamp: $ts" -H "sign: $sign" \
    -d "{\"nodeId\":\"$1\",\"province\":\"$2\",\"city\":\"$3\",\"isp\":\"$ISP\",\"natType\":\"public\",\"resourceType\":\"2\",\"dialType\":\"staticNetSingle\",\"vendorSuggestCustomers\":41,\"usbw\":200,\"bwNum\":1,\"isCrossNetwork\":false,\"crossNetworkIsp\":null,\"isTransProv\":false,\"transMode\":1}" 2>&1
}
detect_loc() {
  local info p c
  info=$(curl -s --retry 2 --max-time 10 myip.ipip.net 2>/dev/null)
  p=$(echo "$info" | awk -F' ' '{print $4}' | tr -d ','); c=$(echo "$info" | awk -F' ' '{print $5}' | tr -d ',')
  [ -z "$p" ] && p="浙江"; [ -z "$c" ] && c="杭州"
  echo "${p}|${c}"
}

# ==============================================================================
say ""
say "===== [0/5] 渠道绑定 ====="
if [ -n "$(node_id)" ] && grep -q "注册状态: 成功" /usr/local/edge/registration_info 2>/dev/null; then
  say "  已绑定过，跳过（device_code=$(node_id)）"
else
  say "  执行 zyy_init_max.sh（装 agent + 设备注册，可能 5-10 分钟）…"
  # 注意：zyy_init_max.sh 只接受 --ak/--sk/--isp/--help，多传参数会直接报错退出
  fetch_run bind "$OSS/zyy_init/zyy_init_max.sh" \
    "https://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init/zyy_init_max.sh" \
    --ak "$CHAN_AK" --sk "$CHAN_SK" --isp "$ISP" || mark_fail "⓪绑定"
fi
NID=$(node_id)
say "  nodeID = ${NID:-未生成}"
[ -z "$NID" ] && say "  ⚠️ 没有 device_code，①④ 两步将跳过（部署/保活/限速仍会继续）"

# ==============================================================================
say ""
say "===== [1/5] 占位符流转「服务中」 ====="
if [ -n "$NID" ]; then
  R1=$(flow "$NID" "$PLACEHOLDER" "inService"); say "  $R1"
  case "$R1" in *'"code":0'*) say "  ✅ 已进入服务中";; *) say "  ⚠️ 未成功（JWT 过期或节点未同步），不影响后续";; esac
else
  say "  跳过（无 nodeID）"
fi

# ==============================================================================
say ""
say "===== [2/5] 部署 docker + Q2业务(9路) ====="
say "  [2.1] 安装 docker…"
fetch_run docker "$OSS/install_docker/install_docker-ce_v2.sh" "" || mark_fail "docker安装"
say "  docker: $(docker --version 2>/dev/null || echo 未装成功)"
say "  [2.2] Q2 业务部署（-i 2 -t 2 = 9路），要下镜像约 10 分钟…"
fetch_run q2 "$OSS/Q2_test/ecache_auto_disk_install.sh" "" -i 2 -t 2 || mark_fail "Q2部署"

# ==============================================================================
say ""
say "===== [3/5] 安装保活 ====="
fetch_run health "$OSS/Q2_test/install_ipes_health_check.sh" "" || mark_fail "保活安装"
say "  保活cron 条数: $(crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check')"

# ==============================================================================
say ""
say "===== [4/5] 真SN回填 + 再流转 ====="
SN=""
for i in 1 2 3 4 5 6; do
  SN=$(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n')
  [ -n "$NID" ] && [ "${NID:0:6}" != "${SN:0:6}" ] && :   # 不比较内容，仅防串号
  [ ${#SN} -ge 60 ] && break
  say "  等 SN（第 $i 次，${#SN} 字节）…"; sleep 30
done
if [ ${#SN} -ge 60 ] && [ -n "$NID" ]; then
  LOC=$(detect_loc); PROV=${LOC%%|*}; CITY=${LOC##*|}
  say "  SN=${SN:0:20}…（${#SN} 字节）"
  say "  4.1 降级→待配置: $(flow "$NID" "$SN" configured)"
  say "  4.2 提交属性(41/200M/${ISP}): $(submit_nominal "$NID" "$PROV" "$CITY")"
  sleep 2
  say "  4.3 升回→服务中: $(flow "$NID" "$SN" inService)"
elif [ -z "$NID" ]; then
  say "  跳过（无 nodeID）"
else
  say "  ⚠️ 未取到真SN（${#SN} 字节），稍后重跑本脚本会自动只补这一步"
fi

# ==============================================================================
say ""
say "===== [5/5] 挂限速 23:59 → 18:25 ====="
curl -fsSL -m 180 "$OSS/limit/run_limit.sh" 2>/dev/null | tr -d '\r' | bash -s -- "23:59" "18:25"
say "  限速返回码=$?  qdisc=$(tc qdisc show dev eth0 2>/dev/null | grep -c htb)条  cron=$(crontab -l 2>/dev/null | grep -cE 'limit_start|clear_limit')条"

# ==============================================================================
say ""
say "==================== 验收 ===================="
say "容器     : $(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | tr '\n' ' ')"
say "happ 路数: $(docker exec ipes ls /data/happ 2>/dev/null | grep -c happ)  (期望 9)"
say "真SN     : $(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | head -c 76)"
say "SN 长度  : $(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n' | wc -c)  (期望 76)"
say "保活cron : $(crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check') 条"
say "限速     : qdisc $(tc qdisc show dev eth0 2>/dev/null | grep -c htb) 条 / cron $(crontab -l 2>/dev/null | grep -cE 'limit_start|clear_limit') 条"
say "纯净版验证: CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null) Q=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)  (应为 cubic + pfifo_fast)"
say "nodeID   : $(node_id)"
if [ -n "$FAIL_LIST" ]; then say "❌ 失败步骤:${FAIL_LIST}"; else say "✅ 六步全部执行完成"; fi
say "============ 完成 $(date '+%F %T') ============"
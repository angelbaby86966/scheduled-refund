#!/bin/bash
# ==============================================================================
# 舟翼云 q2（业务41）一键部署 · v4
#   ① 占位符流转「服务中」  ← 先流转，节点立刻可被调度
#   ② 一次性部署：绑定+注册 → docker → Q2业务 → 【9路一次做对】 → 【真SN回填+再流转】
#   ③ 保活   ④ 限速
#
# v4 关键：9 路不是"后面对齐"，而是在部署流程内一次做完
#   （官方脚本对无数据盘机器只建 1 个目录 → 部署后立刻在同一流程内补齐 9 路并重启容器，
#     紧接着读真 SN 回填流转；全程一个步骤内闭环，不留独立"后面对齐"阶段）
#   纯净版：不做系统调优（cubic + pfifo_fast），happ 固定 9 路
#
# 用法：贴进云助手「命令助手」，超时 ≥1800 秒
# ==============================================================================
JWT="${Q2_JWT:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJVVUlEIjoiMzhjZTQ2YTctZDNkMi00YzVlLWJkNTYtM2I3YzFlMDNkNmYyIiwiSUQiOjQwLCJVc2VybmFtZSI6IjE3Njk1OTM3NzU2IiwiTmlja05hbWUiOiLlvKDnnb8iLCJBdXRob3JpdHlJZCI6MjEsIlVzZXJUeXBlIjoxLCJSZWxhdGVkUGFydHlJRCI6MCwiWnlVaWRzIjoiIiwiQnVmZmVyVGltZSI6ODY0MDAsImlzcyI6Inp5eSIsImF1ZCI6WyJHVkEiXSwiZXhwIjoxNzkyMDI4ODI2LCJuYmYiOjE3OTE0MjQwMjZ9.USrQ-EgFhWBKJKpOzFgj5FlnJZnBJ_QTm7WdfCh8iJ0}"
CHAN_AK="${Q2_AK:-06d78b19bd0d9fc0aa300c6d}"
CHAN_SK="${Q2_SK:-16d6c46443308e62bb51f22c074a90ed}"
ISP="${Q2_ISP:-联通}"
PLACEHOLDER="ZHOUYI_XIAODU"
ADMIN_API="https://admin.zhouyi.top"
OSS="https://zyy-go.oss-cn-beijing.aliyuncs.com/script"
WRAP="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@main/inline_deploy_r20_oss_nt.sh"
ADMIN_APPID="${Q2_APPID:-fg5c21pbzfgu6y2s2yqvanvr6uv99drq}"
ADMIN_AK="${Q2_ADMIN_AK:-ja3io44nq2m7hx63fjkpio7s422aksel}"
ADMIN_SK="${Q2_ADMIN_SK:-ydDGuguZ8COcJN4Ztl3Lsic3Z00zGEani8fYOPiYk2XXCuXQ1AHyy7E1sgV4dyDT}"
LIMIT_START="23:59"; LIMIT_END="18:25"; HAPP_N=9

LOG=/tmp/q2_v4_$$.log
touch "$LOG" 2>/dev/null || LOG=/dev/null
exec > >(tee -a "$LOG" 2>/dev/null) 2>&1
say() { echo "[$(date '+%H:%M:%S')] $*"; }
FAIL=""; mark_fail() { FAIL="${FAIL} $1"; say "  ✗ 失败：$1"; }

say "===== q2 一键部署 v4 开始 $(date '+%F %T') ====="
say "日志: $LOG"

LOCK=/var/run/ipes_deploy.lock
exec 9>"$LOCK" 2>/dev/null
if flock -n 9 2>/dev/null; then say "✅ 部署锁已获取（防并发互踩）"
else say "❌ 本机已有部署在运行，本次退出"; say "   确认前一份卡死： rm -f $LOCK"; exit 1; fi

node_id() { cat /usr/local/edge_zycloud/device_code 2>/dev/null || cat /usr/local/edge/device_code 2>/dev/null || cat /etc/.mac 2>/dev/null; }
flow() { curl -fsS -m 30 -X POST "$ADMIN_API/api/edgeNode/stateflow" -H "Content-Type: application/json" \
  -H "X-Token: $JWT" -d "{\"nodes\":[\"$1\"],\"hostname\":\"$2\",\"stage\":\"$3\"}" 2>&1; }
submit_nominal() {
  local ts sign; ts=$(date +%s)
  sign=$(printf '%s' "${ADMIN_AK}:${ts}" | openssl dgst -sha256 -hmac "$ADMIN_SK" 2>/dev/null | cut -d' ' -f2)
  curl -fsS -k -m 30 -X POST "$ADMIN_API/api/edgeNode/updateEdgeNominalInfo" -H "Content-Type: application/json" \
    -H "appId: $ADMIN_APPID" -H "timestamp: $ts" -H "sign: $sign" \
    -d "{\"nodeId\":\"$1\",\"province\":\"$2\",\"city\":\"$3\",\"isp\":\"$ISP\",\"natType\":\"public\",\"resourceType\":\"2\",\"dialType\":\"staticNetSingle\",\"vendorSuggestCustomers\":41,\"usbw\":200,\"bwNum\":1,\"isCrossNetwork\":false,\"crossNetworkIsp\":null,\"isTransProv\":false,\"transMode\":1}" 2>&1
}
detect_loc() {
  local i p c; i=$(curl -s --retry 2 --max-time 10 myip.ipip.net 2>/dev/null)
  p=$(echo "$i"|awk -F' ' '{print $4}'|tr -d ','); c=$(echo "$i"|awk -F' ' '{print $5}'|tr -d ',')
  [ -z "$p" ] && p="浙江"; [ -z "$c" ] && c="杭州"; echo "${p}|${c}"
}

# ==============================================================================
# ① 先流转「服务中」—— 早于部署，节点立刻可被调度
# ==============================================================================
say ""; say "===== [1/4] 占位符流转「服务中」（先流转，再部署）====="
NID=$(node_id)
if [ -z "$NID" ]; then
  say "  本机无 device_code（新机器）→ ② 部署会完成绑定+注册，之后重跑本脚本即会补流转"
else
  say "  nodeID=$NID"
  R=$(flow "$NID" "$PLACEHOLDER" "inService")
  case "$R" in
    *'"code":0'*) say "  ✅ 已在服务中（业务ID暂为占位符，②部署完成后自动回填真SN）" ;;
    *) say "  ⚠️ 未成功：$(echo "$R" | head -c 80)"
       say "     （JWT 401 最常见；②里会再回填一次，不影响部署）" ;;
  esac
fi

# ==============================================================================
# ② 部署 + 9 路一次做对 + 真SN回填（同一流程内闭环）
# ==============================================================================
say ""; say "===== [2/4] 部署：绑定 → docker → Q2业务 → 9路 → 真SN回填 ====="

# 2.1 绑定 + 设备注册（无设备码时才做，已绑则跳过）
if [ -z "$NID" ] || ! grep -q "注册状态: 成功" /usr/local/edge/registration_info 2>/dev/null; then
  say "  [2.1] 渠道绑定 + 设备注册（zyy_init_max，5-10 分钟）…"
  curl -fsSL -m 900 "$OSS/zyy_init/zyy_init_max.sh" -o /tmp/_bind.sh 2>/dev/null \
    && bash /tmp/_bind.sh --ak "$CHAN_AK" --sk "$CHAN_SK" --isp "$ISP" || mark_fail "绑定"
  NID=$(node_id); say "  nodeID=${NID:-未生成}"
else
  say "  [2.1] 已绑定，跳过"
fi

# 2.2 docker + Q2 业务（官方链路）
say "  [2.2] 安装 docker…"
curl -fsSL -m 300 "$OSS/install_docker/install_docker-ce_v2.sh" -o /tmp/_dk.sh 2>/dev/null \
  && bash /tmp/_dk.sh || mark_fail "docker安装"
say "  docker: $(docker --version 2>/dev/null || echo 失败)"
say "  [2.3] Q2 业务部署（-i 2 -t 2）…"
curl -fsSL -m 1800 "$OSS/Q2_test/ecache_auto_disk_install.sh" -o /tmp/_q2.sh 2>/dev/null \
  && bash /tmp/_q2.sh -i 2 -t 2 || mark_fail "Q2部署"

# 2.4 ★ 9 路在部署流程内一次做对（不是后面对齐）
#     官方脚本对无数据盘机器只建 1 个目录，这里立刻补齐 9 路并重启容器
say "  [2.4] happ 路数一次做对（目标 ${HAPP_N} 路）…"
for _w in 1 2 3 4 5 6 7 8 9 10; do
  docker inspect ipes >/dev/null 2>&1 && [ -d /data/happ/happ.0 ] && break
  say "     等容器初始化（$ _w/10）…"; sleep 30
done
ROOT=/data/happ; CFG=/opt/ipes/var/db/ipes/happ-conf/custom.yml
CUR=$(docker exec ipes ls /data/happ 2>/dev/null | grep -c happ)
say "     当前 ${CUR:-0} 路"
if [ "$CUR" = "$HAPP_N" ]; then
  say "     ✅ 已是 ${HAPP_N} 路，无需处理"
elif docker inspect ipes >/dev/null 2>&1 && [ -f "$CFG" ] && [ -d "$ROOT/happ.0" ]; then
  REF="$ROOT/happ.0/xycould_base_info"; n
  for n in $(seq 0 $((HAPP_N-1))); do
    [ -d "$ROOT/happ.$n" ] || mkdir -p "$ROOT/happ.$n"
    [ -s "$REF" ] && [ ! -s "$ROOT/happ.$n/xycould_base_info" ] && cp -p "$REF" "$ROOT/happ.$n/xycould_base_info" 2>/dev/null
  done
  TMP=$(mktemp)
  { echo "# q2 happy${HAPP_N} $(date '+%F %T')"; echo "args:"
    for n in $(seq 0 $((HAPP_N-1))); do echo "  - $ROOT/happ.$n"; done
    grep -E '^reg_isp:' "$CFG" 2>/dev/null; } > "$TMP"
  CNT=$(grep -cE "^  - ${ROOT}/happ\.[0-9]+$" "$TMP")
  if [ "$CNT" = "$HAPP_N" ]; then
    cp -p "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    cp -p "$TMP" "$CFG"
    say "     custom.yml 已设为 ${HAPP_N} 路，重启容器生效（30-60秒断流）…"
    docker restart ipes >/dev/null 2>&1; sleep 30
    say "     ✅ ${HAPP_N} 路已生效，happ 进程数=$(docker exec ipes sh -c 'ps -ef | grep -c "[h]app:vod"' 2>/dev/null | tr -d '\r')"
  else
    rm -f "$TMP"; say "     ✗ 生成条数异常($CNT != $HAPP_N)，保留现场"; mark_fail "9路配置"
  fi
else
  say "     ⚠️ 容器或 custom.yml 尚未就绪；部署完成后重跑本脚本会自动补这一步"
fi

# 2.5 真 SN 回填 + 再流转（紧接部署，不分离）
say "  [2.5] 读真SN → 回填 → 再流转…"
SN=""
for i in 1 2 3 4 5 6; do
  SN=$(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n')
  [ ${#SN} -ge 60 ] && break
  say "     等 SN（$i/6，${#SN}字节）…"; sleep 30
done
if [ ${#SN} -ge 60 ] && [ -n "$NID" ]; then
  LOC=$(detect_loc)
  say "     SN=${SN:0:16}…（${#SN}字节）"
  say "     降级→待配置: $(flow "$NID" "$SN" configured)"
  say "     提交属性(41/200M/${ISP}): $(submit_nominal "$NID" "${LOC%%|*}" "${LOC##*|}")"
  sleep 2
  say "     升回→服务中: $(flow "$NID" "$SN" inService)"
else
  say "     ⚠️ 未取到真SN（${#SN}字节），重跑本脚本会自动只补这一步"
fi

# ==============================================================================
say ""; say "===== [3/4] 安装保活 ====="
curl -fsSL -m 120 "$OSS/Q2_test/install_ipes_health_check.sh" -o /tmp/_hc.sh 2>/dev/null \
  && bash /tmp/_hc.sh || mark_fail "保活"
say "  保活cron: $(crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check') 条"

# ==============================================================================
say ""; say "===== [4/4] 挂限速 ${LIMIT_START} → ${LIMIT_END} ====="
curl -fsSL -m 180 "$OSS/limit/run_limit.sh" 2>/dev/null | tr -d '\r' | bash -s -- "$LIMIT_START" "$LIMIT_END"
say "  qdisc=$(tc qdisc show dev eth0 2>/dev/null | grep -c htb) 条  cron=$(crontab -l 2>/dev/null | grep -cE 'limit_start|clear_limit') 条"

flock -u 9 2>/dev/null; exec 9>&-
# ==============================================================================
say ""; say "==================== 验收 ===================="
say "容器     : $(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | tr '\n' ' ')"
say "happ 路数: $(docker exec ipes ls /data/happ 2>/dev/null | grep -c happ)  (期望 9)"
say "happ进程 : $(docker exec ipes sh -c 'ps -ef | grep -c "[h]app:vod"' 2>/dev/null | tr -d '\r')  (期望 9)"
say "真SN     : $(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | head -c 76)"
say "SN 长度  : $(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n' | wc -c)  (期望 76)"
say "保活cron : $(crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check') 条"
say "限速     : qdisc $(tc qdisc show dev eth0 2>/dev/null | grep -c htb) / cron $(crontab -l 2>/dev/null | grep -cE 'limit_start|clear_limit') 条"
say "纯净版   : CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null) Q=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)  (应 cubic + pfifo_fast)"
say "nodeID   : $(node_id)"
[ -n "$FAIL" ] && say "❌ 失败步骤:${FAIL}" || say "✅ 全部完成"
say "============ 完成 $(date '+%F %T') ============"
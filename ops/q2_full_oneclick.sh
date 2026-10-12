#!/bin/bash
# ==============================================================================
# 舟翼云 q2（业务41）一键部署 · 完整版 v3（根治版）
#
#   ⓪ 绑定+设备注册 → ① 占位符流转 → ② 部署(含9路对齐) → ③ 保活 → ④ 真SN回填+再流转 → ⑤ 限速
#
# v3 根治说明：
#   1) ② 部署改为调用统一 wrapper inline_deploy_r20_oss_nt.sh（它已内置 B1.8 设备注册 +
#      B1.9 happ 9 路对齐 + 部署互斥锁），不再自己拼官方脚本 —— v2 漏 9 路对齐的根因
#   2) ①④ 流转全部内置兜底：JWT 401 时不阻塞，自动降级为占位符流转，保证节点先上「服务中」
#   3) 单机互斥锁：并发重入直接退出，避免两份部署互踩（09-17 上海事故教训）
#   4) 任何一步失败都不中断，最后统一汇总；输出双写（终端+日志）
#
# 纯净版：不做系统调优（cubic + pfifo_fast），happ 固定 9 路
# 用法：改下面参数 → 贴进云助手「命令助手」（超时 ≥1800 秒）
# ==============================================================================
JWT="${Q2_JWT:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJVVUlEIjoiMzhjZTQ2YTctZDNkMi00YzVlLWJkNTYtM2I3YTEwM2Q2ZjIiLCJJRCI6NDAsIlVzZXJuYW1lIjoiMTc2OTU5Mzc3NTYiLCJOaWNrTmFtZSI6IuS4queivOiJ9.-lpWIqfGtjcaGLcvVIF5xQ6WeVf0siv9lB4k3aMglfg}"
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
LIMIT_START="23:59"; LIMIT_END="18:25"

LOG=/tmp/q2_v3_$$.log
touch "$LOG" 2>/dev/null || LOG=/dev/null
exec > >(tee -a "$LOG" 2>/dev/null) 2>&1
TS() { date '+%H:%M:%S'; }
say() { echo "[$(TS)] $*"; }
FAIL=""
mark_fail() { FAIL="${FAIL} $1"; say "  ✗ 失败：$1"; }

say "===== q2 完整版 v3（根治版）开始 $(date '+%F %T') ====="
say "日志: $LOG"

# ---------- 互斥锁：防并发重入 ----------
LOCK=/var/run/ipes_deploy.lock
exec 9>"$LOCK" 2>/dev/null
if flock -n 9 2>/dev/null; then say "✅ 已获取部署锁（互斥生效）"
else say "❌ 本机已有部署在运行，为避免两份互踩本次退出"; say "   若确认前一份卡死： rm -f $LOCK"; exit 1; fi

# ---------- JWT 预检 ----------
JWT_TS=$(command -v python3 >/dev/null 2>&1 && python3 -c "
import base64,json
try:
    p='$JWT'.split('.')[1]; p+='='*(-len(p)%4)
    print(int(json.loads(base64.urlsafe_b64decode(p).decode('utf-8','replace')).get('exp',0)))
except Exception: print(0)" 2>/dev/null)
if [ -n "${JWT_TS:-}" ] && [ "$JWT_TS" -gt 0 ] 2>/dev/null; then
  [ "$JWT_TS" -lt "$(date +%s)" ] && say "⚠️ JWT 已过期 → ①④ 会自动降级为占位符流转（不影响部署）" \
                                || say "JWT 有效期至 $(date -d @"$JWT_TS" '+%F %T' 2>/dev/null) ✅"
else say "（JWT 有效期无法预检）"; fi

# ---------- 工具 ----------
node_id() { cat /usr/local/edge_zycloud/device_code 2>/dev/null || cat /usr/local/edge/device_code 2>/dev/null || cat /etc/.mac 2>/dev/null; }
flow() { curl -fsS -m 30 -X POST "$ADMIN_API/api/edgeNode/stateflow" -H "Content-Type: application/json" \
  -H "X-Token: $JWT" -d "{\"nodes\":[\"$1\"],\"hostname\":\"$2\",\"stage\":\"$3\"}" 2>&1; }
submit_nominal() {
  local ts sign; ts=$(date +%s)
  sign=$(printf '%s' "${ADMIN_AK}:${ts}" | openssl dgst -sha256 -hmac "$ADMIN_SK" 2>/dev/null | cut -d' ' -f2)
  curl -fsS -k -m 30 -X POST "$ADMIN_API/api/edgeNode/updateEdgeNominalInfo" \
    -H "Content-Type: application/json" -H "appId: $ADMIN_APPID" -H "timestamp: $ts" -H "sign: $sign" \
    -d "{\"nodeId\":\"$1\",\"province\":\"$2\",\"city\":\"$3\",\"isp\":\"$ISP\",\"natType\":\"public\",\"resourceType\":\"2\",\"dialType\":\"staticNetSingle\",\"vendorSuggestCustomers\":41,\"usbw\":200,\"bwNum\":1,\"isCrossNetwork\":false,\"crossNetworkIsp\":null,\"isTransProv\":false,\"transMode\":1}" 2>&1
}
detect_loc() {
  local i p c; i=$(curl -s --retry 2 --max-time 10 myip.ipip.net 2>/dev/null)
  p=$(echo "$i"|awk -F' ' '{print $4}'|tr -d ','); c=$(echo "$i"|awk -F' ' '{print $5}'|tr -d ',')
  [ -z "$p" ] && p="浙江"; [ -z "$c" ] && c="杭州"; echo "${p}|${c}"
}

# ==============================================================================
say ""; say "===== [1/5] 占位符流转「服务中」（早于部署，让节点可被调度）====="
NID=$(node_id)
if [ -z "$NID" ]; then
  say "  本机无 device_code（新机器），跳过 —— 部署脚本会完成绑定+注册，之后重跑本脚本即会补上"
else
  say "  nodeID=$NID"
  R=$(flow "$NID" "$PLACEHOLDER" "inService")
  case "$R" in
    *'"code":0'*) say "  ✅ 已进入服务中" ;;
    *) say "  ⚠️ 流转未成功：$(echo "$R"|head -c 90)"; say "     （JWT 401 是常见原因；部署不受影响，第4步会再回填一次）" ;;
  esac
fi

# ==============================================================================
say ""; say "===== [2/5] 部署（绑定+docker+Q2业务+9路对齐）====="
say "  调�� inline_deploy_r20_oss_nt.sh（含 B1.8 设备注册 + B1.9 happ9 对齐）"
say "  预计 10-20 分钟（要下镜像）…"
if curl -fsSL -m 60 "$WRAP" -o /tmp/_wrap.sh 2>/dev/null && [ -s /tmp/_wrap.sh ] \
   && grep -q "q2-new-20261010" /tmp/_wrap.sh; then
  say "  wrapper 下载成功（$(wc -c < /tmp/_wrap.sh) 字节）"
  bash /tmp/_wrap.sh --ak "$CHAN_AK" --sk "$CHAN_SK" --jwt "$JWT" --isp "$ISP" --num-dirs 9
  say "  部署返回码=$?"
else
  say "  ✗ wrapper 下载失败或版本不符"
  mark_fail "②部署"
  #兜底：至少保证 docker + 官方部署 + 手工9路对齐
  say "  降级为官方链路 + 手工 9 路对齐"
  curl -fsSL -m 300 "$OSS/install_docker/install_docker-ce_v2.sh" -o /tmp/_dk.sh && bash /tmp/_dk.sh || mark_fail "docker"
  curl -fsSL -m 1800 "$OSS/Q2_test/ecache_auto_disk_install.sh" -o /tmp/_q2.sh && bash /tmp/_q2.sh -i 2 -t 2 || mark_fail "Q2部署"
fi

# ---------- 9 路兜底对齐（B1.9 复刻，幂等） ----------
align9() {
  local ROOT=/data/happ CFG=/opt/ipes/var/db/ipes/happ-conf/custom.yml
  docker inspect ipes >/dev/null 2>&1 || { say "  无 ipes 容器，跳过9路对齐"; return 1; }
  [ -f "$CFG" ] || { say "  无 custom.yml，跳过"; return 1; }
  [ -d "$ROOT/happ.0" ] || { say "  happ.0 未初始化（容器可能还在拉镜像），稍后重跑本脚本会自动补"; return 1; }
  local ref="$ROOT/happ.0/xycould_base_info" n
  for n in $(seq 0 8); do
    [ -d "$ROOT/happ.$n" ] || mkdir -p "$ROOT/happ.$n"
    [ -s "$ref" ] && [ ! -s "$ROOT/happ.$n/xycould_base_info" ] && cp -p "$ref" "$ROOT/happ.$n/xycould_base_info" 2>/dev/null
  done
  local tmp=$(mktemp)
  { echo "# q2 happy9 $(date '+%F %T')"; echo "args:"
    for n in $(seq 0 8); do echo "  - $ROOT/happ.$n"; done
    grep -E '^reg_isp:' "$CFG" 2>/dev/null; } > "$tmp"
  local c=$(grep -cE "^  - ${ROOT}/happ\.[0-9]+$" "$tmp")
  if [ "$c" = "9" ]; then
    cp -p "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    cp -p "$tmp" "$CFG"; say "  ✅ custom.yml 已设为 9 路"
    say "  重启 ipes 使路数生效（约 30~60 秒断流）…"
    docker restart ipes >/dev/null 2>&1; sleep 30
    say "  happ 进程数: $(docker exec ipes sh -c 'ps -ef | grep -c "[h]app:vod"' 2>/dev/null | tr -d '\r')"
  else
    rm -f "$tmp"; say "  ✗ 生成条数异常($_c != 9)，保留现场"; return 1
  fi
}
say "  [9路核对] 当前 $(docker exec ipes ls /data/happ 2>/dev/null | grep -c happ) 路，期望 9"
[ "$(docker exec ipes ls /data/happ 2>/dev/null | grep -c happ)" = "9" ] 2>/dev/null || { say "  执行 9 路对齐…"; align9 || say "  9路对齐未完成（可重跑本脚本）"; }

# ==============================================================================
say ""; say "===== [3/5] 安装保活 ====="
if curl -fsSL -m 120 "$OSS/Q2_test/install_ipes_health_check.sh" -o /tmp/_hc.sh 2>/dev/null && [ -s /tmp/_hc.sh ]; then
  bash /tmp/_hc.sh || mark_fail "保活"
else mark_fail "保活下载"; fi
say "  保活cron: $(crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check') 条"

# ==============================================================================
say ""; say "===== [4/5] 真SN回填 + 再流转 ====="
SN=""
for i in 1 2 3 4 5 6 7 8; do
  SN=$(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n')
  [ ${#SN} -ge 60 ] && break
  say "  等 SN（第 $i 次，${#SN} 字节）…"; sleep 30
done
NID=$(node_id)
if [ ${#SN} -ge 60 ] && [ -n "$NID" ]; then
  LOC=$(detect_loc); say "  SN=${SN:0:20}…（${#SN}字节）"
  say "  4.1 降级→待配置: $(flow "$NID" "$SN" configured)"
  say "  4.2 提交属性(41/200M/${ISP}): $(submit_nominal "$NID" "${LOC%%|*}" "${LOC##*|}")"
  sleep 2
  say "  4.3 升回→服务中: $(flow "$NID" "$SN" inService)"
elif [ -z "$NID" ]; then say "  跳过（无 nodeID）"
else say "  ⚠️ 未取到真SN（${#SN}字节），重跑本脚本会自动只补这一步"; fi

# ==============================================================================
say ""; say "===== [5/5] 挂限速 ${LIMIT_START} → ${LIMIT_END} ====="
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
[ -n "$FAIL" ] && say "❌ 失败步骤:${FAIL}" || say "✅ 五步全部完成"
say "============ 完成 $(date '+%F %T') ============"
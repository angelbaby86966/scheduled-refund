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
# 用法：先备好 token（export Q2_JWT=xxx，或 echo <token> > /etc/q2/jwt），再贴进云助手「命令助手」，超时 ≥1800 秒
# ==============================================================================
# ── token 外置：脚本不再内置 JWT（公开 CDN 不再泄露密钥）──
#   读取优先级：export Q2_JWT=xxx  >  文件 ${Q2_JWT_FILE:-/etc/q2/jwt}  >  报错退出
#   换 token 只需改环境变量或重写该文件，无需改脚本；JWT 过期也能即时更替
Q2_JWT_FILE="${Q2_JWT_FILE:-/etc/q2/jwt}"
if [ -z "${Q2_JWT:-}" ] && [ -f "$Q2_JWT_FILE" ]; then
  Q2_JWT="$(cat "$Q2_JWT_FILE" 2>/dev/null | tr -d '[:space:]')"
fi
: "${Q2_JWT:?未找到 JWT：请 export Q2_JWT=xxx，或 echo <新token> > $Q2_JWT_FILE（脚本已不再内置密钥）}"
JWT="$Q2_JWT"
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
#     官方脚本对无数据盘机器只建 1 个目录。这里补齐 9 路分片，并用【9 个 -v 重建容器】生效。
#     ⚠️ 关键：docker run 的 -v 挂载参数在创建时固化，docker restart 不会新增挂载 ——
#        只改 custom.yml + restart 会造成「配置 9 路 / 容器内只见 happ.0 / happ 进程=1」的假成功。
say "  [2.4] happ 路数一次做对（目标 ${HAPP_N} 路）…"
for _w in $(seq 1 20); do
  docker inspect ipes >/dev/null 2>&1 && [ -d /data/happ/happ.0 ] && break
  say "     等容器初始化（$_w/20）…"; sleep 30
done
ROOT=/data/happ; CFG=/opt/ipes/var/db/ipes/happ-conf/custom.yml
IMG="ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:latest"
# 容器内实际可见分片数（这才是真实路数，不能看配置文件）
CUR=$(docker exec ipes ls -d /data/happ/happ.* 2>/dev/null | wc -l | tr -d ' ')
say "     容器内实际可见 ${CUR:-0} 个分片（期望 $HAPP_N）"
if [ "$CUR" = "$HAPP_N" ]; then
  say "     ✅ 已是 ${HAPP_N} 路，跳过"
elif docker inspect ipes >/dev/null 2>&1 && [ -f "$CFG" ] && [ -d "$ROOT/happ.0" ]; then
  # 2.4.1 补齐 9 个分片目录 + 每片的 xycould_base_info（缺它 happ.N 起不来）
  REF="$ROOT/happ.0/xycould_base_info"; n
  for n in $(seq 0 $((HAPP_N-1))); do
    mkdir -p "$ROOT/happ.$n/hdata/cache" "$ROOT/happ.$n/hdata/config"
    [ -s "$REF" ] && [ ! -s "$ROOT/happ.$n/xycould_base_info" ] && cp -p "$REF" "$ROOT/happ.$n/xycould_base_info" 2>/dev/null
  done
  say "     分片目录就绪：$(ls -d $ROOT/happ.* 2>/dev/null | wc -l) 个"
  # 2.4.2 custom.yml 写 9 路（先备份，条数校验不符则放弃，不破坏现场）
  TMP=$(mktemp)
  { echo "# q2 happy${HAPP_N} $(date '+%F %T')"; echo "args:"
    for n in $(seq 0 $((HAPP_N-1))); do echo "  - $ROOT/happ.$n"; done
    grep -E '^reg_isp:' "$CFG" 2>/dev/null; } > "$TMP"
  CNT=$(grep -cE "^  - ${ROOT}/happ\.[0-9]+$" "$TMP")
  if [ "$CNT" != "$HAPP_N" ]; then
    rm -f "$TMP"; say "     ✗ 配置条数异常($CNT != $HAPP_N)，保留现场"; mark_fail "9路配置"
  else
    cp -p "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    cp -p "$TMP" "$CFG"; rm -f "$TMP"
    say "     custom.yml 已设为 ${HAPP_N} 路"
    # 2.4.3 ★ 用 9 个 -v 重建容器（挂载固化，必须重建才能生效）
    say "     重建容器挂载 ${HAPP_N} 路（断流 30-60 秒）…"
    docker stop ipes >/dev/null 2>&1
    docker rm -f ipes   >/dev/null 2>&1
    MARGS=""
    for n in $(seq 0 $((HAPP_N-1))); do
      MARGS="$MARGS -v $ROOT/happ.$n/hdata/cache:$ROOT/happ.$n/hdata/cache"
      MARGS="$MARGS -v $ROOT/happ.$n/hdata/config:$ROOT/happ.$n/hdata/config"
      MARGS="$MARGS -v $ROOT/happ.$n/xycould_base_info:$ROOT/happ.$n/xycould_base_info"
    done
    # shellcheck disable=SC2086
    docker run -d --restart=always --name=ipes --network=host $MARGS \
      -v "$CFG:/app/ipes/var/db/ipes/happ-conf/custom.yml" \
      "$IMG" sh -c '/app/ipes/bin/ipes start && tail -f /dev/null' >/dev/null 2>&1
    RCD=$?
    say "     docker run 返回码=$RCD"
    sleep 40
    NEW=$(docker exec ipes ls -d /data/happ/happ.* 2>/dev/null | wc -l | tr -d ' ')
    HP=$(docker exec ipes sh -c 'ps -ef | grep "[h]app" | wc -l' 2>/dev/null | tr -d '\r')
    if [ "$NEW" = "$HAPP_N" ]; then
      say "     ✅ ${HAPP_N} 路已真正生效：容器内分片=$NEW happ进程=$HP"
    else
      say "     ⚠️ 重建后容器内分片=$NEW（期望$HAPP_N）；happ进程=$HP"
      say "     若仍不符，请查 /tmp/happy9_fix.log；重跑本脚本会再修一次（幂等）"
    fi
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
#!/bin/bash
# ==============================================================================
# 舟翼云 q2（业务41）一键部署 · v6（提速版）
#   ① 先绑定+注册 → 占位符流转「服务中」（节点立刻可被调度）
#   ② 部署（docker + Q2业务 + 9路一次做对 + 真SN回填 + 保活 + 限速）
#      以 setsid 后台运行，云助手命令秒回，真进度写 /var/log/ipes_nohup.log
#   纯净版：不做系统调优（cubic + pfifo_fast），happ 固定 9 路
#
# 与 v5 的差异（仅编排层，部署内部逻辑逐字保留）：
#   1) [1/4] 占位符流转从「脚本开头（新机NID空→死代码）」移到「绑定之后」，
#      新机也能真正先流转服务中；
#   2) 部署段（[2.2]~[4/4]）整体交给后台子进程（setsid nohup），云助手命令立即返回；
#   3) 轮询粒度 30s→10s，[2.4] 重建后的固定 sleep 40 改为「等 happ 进程达 9 路」健康轮询；
#   4) 互斥锁由后台子进程持有（避免 dispatcher 退出即释放造成的竞态）。
#
# 用法：先备好 token（export Q2_JWT=xxx，或 echo <token> > /etc/q2/jwt），
#      云助手「命令助手」超时 ≥1200 秒（仅绑定时长）。
#      普通重跑：bash q2_oneclick_v6.sh
#      后台部署子进程（勿手工调用）：bash q2_oneclick_v6.sh --internal-deploy
# ==============================================================================
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

LOG=/tmp/q2_v6_$$.log
touch "$LOG" 2>/dev/null || LOG=/dev/null
exec > >(tee -a "$LOG" 2>/dev/null) 2>&1
say() { echo "[$(date '+%H:%M:%S')] $*"; }
FAIL=""; mark_fail() { FAIL="${FAIL} $1"; say "  ✗ 失败：$1"; }

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

LOCK=/var/run/ipes_deploy.lock
NOHUP_LOG=/var/log/ipes_nohup.log

# ==============================================================================
# 后台部署子进程：持有互斥锁，单台不互踩。云助手命令不在此阻塞。
# ==============================================================================
internal_deploy() {
  exec 9>"$LOCK" 2>/dev/null
  if ! flock -n 9 2>/dev/null; then
    say "❌ 本机已有部署在运行（锁被占用），本次后台子进程退出"
    return 1
  fi
  say ""; say "===== [后台] 部署：docker → Q2业务 → 9路 → 真SN回填 → 保活 → 限速 ====="

  # 2.2 docker + Q2 业务（官方链路）
  say "  [2.2] 安装 docker…"
  curl -fsSL -m 300 "$OSS/install_docker/install_docker-ce_v2.sh" -o /tmp/_dk.sh 2>/dev/null \
    && bash /tmp/_dk.sh || mark_fail "docker安装"
  say "  docker: $(docker --version 2>/dev/null || echo 失败)"
  say "  [2.3] Q2 业务部署（-i 2 -t 2）…"
  curl -fsSL -m 1800 "$OSS/Q2_test/ecache_auto_disk_install.sh" -o /tmp/_q2.sh 2>/dev/null \
    && bash /tmp/_q2.sh -i 2 -t 2 || mark_fail "Q2部署"

  # 2.4 ★ 9 路在部署流程内一次做对（不是后面对齐）
  say "  [2.4] happ 路数一次做对（目标 ${HAPP_N} 路）…"
  for _w in $(seq 1 60); do
    docker inspect ipes >/dev/null 2>&1 && [ -d /data/happ/happ.0 ] && break
    say "     等容器初始化（$_w/60）…"; sleep 10
  done
  ROOT=/data/happ; CFG=/opt/ipes/var/db/ipses/happ-conf/custom.yml
  IMG="ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:latest"
  CUR=$(docker exec ipes ls -d /data/happ/happ.* 2>/dev/null | wc -l | tr -d ' ')
  say "     容器内实际可见 ${CUR:-0} 个分片（期望 $HAPP_N）"
  if [ "$CUR" = "$HAPP_N" ]; then
    say "     ✅ 已是 ${HAPP_N} 路，跳过"
  elif docker inspect ipes >/dev/null 2>&1 && [ -f "$CFG" ] && [ -d "$ROOT/happ.0" ]; then
    REF="$ROOT/happ.0/xycould_base_info"
    for n in $(seq 0 $((HAPP_N-1))); do
      mkdir -p "$ROOT/happ.$n/hdata/cache" "$ROOT/happ.$n/hdata/config"
      [ -s "$REF" ] && [ ! -s "$ROOT/happ.$n/xycould_base_info" ] && cp -p "$REF" "$ROOT/happ.$n/xycould_base_info" 2>/dev/null
    done
    say "     分片目录就绪：$(ls -d $ROOT/happ.* 2>/dev/null | wc -l) 个"
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
        -v "$CFG:/app/ipses/var/db/ipes/happ-conf/custom.yml" \
        "$IMG" sh -c '/app/ipses/bin/ipes start && tail -f /dev/null' >/dev/null 2>&1
      RCD=$?
      say "     docker run 返回码=$RCD"
      # 健康轮询：等 happ 进程达到 9 路（最多 60s），替代固定 sleep 40
      for _h in $(seq 1 12); do
        HP=$(docker exec ipes sh -c 'ps -ef | grep -c "[h]app"' 2>/dev/null | tr -d '\r')
        [ "${HP:-0}" = "$HAPP_N" ] && break
        sleep 5
      done
      NEW=$(docker exec ipes ls -d /data/happ/happ.* 2>/dev/null | wc -l | tr -d ' ')
      HP=$(docker exec ipes sh -c 'ps -ef | grep -c "[h]app"' 2>/dev/null | tr -d '\r')
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
  NID=$(node_id)
  say "  [2.5] 读真SN → 回填 → 再流转…"
  SN=""
  for i in $(seq 1 18); do
    SN=$(docker exec ipes cat /app/ipses/bin/ipes_sn 2>/dev/null | tr -d '\r\n')
    [ ${#SN} -ge 60 ] && break
    say "     等 SN（$i/18，${#SN}字节）…"; sleep 10
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
  curl -fsSL -m 120 "$OSS/Q2_test/install_ipses_health_check.sh" -o /tmp/_hc.sh 2>/dev/null \
    && bash /tmp/_hc.sh || mark_fail "保活"
  say "  保活cron: $(crontab -l 2>/dev/null | grep -cE 'ipses_health|health_check') 条"

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
  say "真SN     : $(docker exec ipes cat /app/ipses/bin/ipes_sn 2>/dev/null | head -c 76)"
  say "SN 长度  : $(docker exec ipes cat /app/ipses/bin/ipes_sn 2>/dev/null | tr -d '\r\n' | wc -c)  (期望 76)"
  say "保活cron : $(crontab -l 2>/dev/null | grep -cE 'ipses_health|health_check') 条"
  say "限速     : qdisc $(tc qdisc show dev eth0 2>/dev/null | grep -c htb) / cron $(crontab -l 2>/dev/null | grep -cE 'limit_start|clear_limit') 条"
  say "纯净版   : CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null) Q=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)  (应 cubic + pfifo_fast)"
  say "nodeID   : $(node_id)"
  [ -n "$FAIL" ] && say "❌ 失败步骤:${FAIL}" || say "✅ 全部完成"
  say "============ 后台部署完成 $(date '+%F %T') ============"
}

# ==============================================================================
# 主流程（云助手执行这段，秒回）：绑定 → 占位符流转 → 启动后台部署
# ==============================================================================
main_deploy() {
  say "===== q2 一键部署 v6（提速版）开始 $(date '+%F %T') ====="
  say "日志: $LOG"

  # 2.1 绑定 + 设备注册（无设备码时才做，已绑则跳过）
  NID=$(node_id)
  if [ -z "$NID" ] || ! grep -q "注册状态: 成功" /usr/local/edge/registration_info 2>/dev/null; then
    say "  [2.1] 渠道绑定 + 设备注册（zyy_init_max，5-10 分钟）…"
    curl -fsSL -m 900 "$OSS/zyy_init/zyy_init_max.sh" -o /tmp/_bind.sh 2>/dev/null \
      && bash /tmp/_bind.sh --ak "$CHAN_AK" --sk "$CHAN_SK" --isp "$ISP" || mark_fail "绑定"
    NID=$(node_id); say "  nodeID=${NID:-未生成}"
  else
    say "  [2.1] 已绑定，跳过"
  fi

  # ① 先提交业务属性(41/200M) + 占位符流转「服务中」—— 放在绑定之后，新机也立即拿到业务
  say ""; say "===== [1/4] 提交业务(41/200M) + 占位符流转「服务中」====="
  NID=$(node_id)
  if [ -n "$NID" ]; then
    LOC=$(detect_loc)
    # 容器若已起来则带真 SN，否则用占位符（避免重跑时用占位符覆盖真 SN）
    SN_NOW=$(docker exec ipes cat /app/ipses/bin/ipes_sn 2>/dev/null | tr -d '\r\n')
    HOST="$PLACEHOLDER"; [ ${#SN_NOW} -ge 60 ] && HOST="$SN_NOW"
    # submit_nominal 要求节点在 configured 阶段（inService 下提交返回 code:7），先降配
    flow "$NID" "$HOST" "configured" >/dev/null 2>&1
    R2=$(submit_nominal "$NID" "${LOC%%|*}" "${LOC##*|}")
    case "$R2" in
      *'"code":0'*) say "  ✅ 已提交业务属性(41/200M/${ISP})" ;;
      *) say "  ⚠️ 属性提交未成功：$(echo "$R2" | head -c 80)" ;;
    esac
    R=$(flow "$NID" "$HOST" "inService")
    case "$R" in
      *'"code":0'*) say "  ✅ 已流转服务中（业务41/200M已挂 ${HOST:0:16}…，后台部署完成回填真SN）" ;;
      *) say "  ⚠️ 流转未成功：$(echo "$R" | head -c 80)" ;;
    esac
  else
    say "  ⚠️ 仍未取到 nodeID，流转跳过（后台部署完成后重跑本脚本可补）"
  fi

  # ② 启动后台部署（命令立即返回，真进度落 /var/log/ipes_nohup.log）
  say ""; say "===== 启动后台部署（setsid 脱离会话）====="
  # ⚠️ 关键（真实踩坑）：管道执行(`curl … | bash`)时 $0=="bash" 且 BASH_SOURCE 为空，
  #    `setsid "$0" --internal-deploy` 会变成 `bash --internal-deploy`
  #    → bash 报 "--internal-deploy: invalid option" 退出，后台部署【静默不启动】，
  #    日志里只剩一屏 bash 用法，且 deploy.status 永远不写 → 表现为"部署没成功"。
  #    对策：把脚本实体落到磁盘，再用 /bin/bash <文件> --internal-deploy 启动。
  #    落盘顺序：① BASH_SOURCE(文件执行场景) ② Q2_SELF_URL 自下载(管道场景) ③ 前台回落
  SELF="/etc/q2/q2_oneclick_v6.self.sh"
  mkdir -p /etc/q2 2>/dev/null
  # ① 文件执行场景：直接复制自身
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -s "${BASH_SOURCE[0]:-}" ]; then
    cp -f "${BASH_SOURCE[0]}" "$SELF" 2>/dev/null
    say "  · 自身落盘(复制 BASH_SOURCE) → $SELF"
  fi
  # ② 管道场景：BASH_SOURCE 为空，改用自下载
  if [ ! -s "$SELF" ]; then
    SELF_URL="${Q2_SELF_URL:-https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@1f890c0c4bb102d3fc2290deb995336c9a1838ca/ops/q2_oneclick_v6.sh}"
    say "  · 管道执行无本地路径，自下载脚本 → $SELF_URL"
    curl -fsSL --max-time 60 "$SELF_URL" -o "$SELF" 2>/dev/null
  fi
  if [ ! -s "$SELF" ]; then
    say "  ⚠️ 仍无法落盘，回落【前台】执行（会阻塞到部署完成，请把云助手超时调到 2400s）"
    internal_deploy
    return $?
  fi
  chmod +x "$SELF" 2>/dev/null
  setsid nohup /bin/bash "$SELF" --internal-deploy </dev/null >>"$NOHUP_LOG" 2>&1 &
  local pid=$!
  sleep 3
  if kill -0 "$pid" 2>/dev/null; then
    say "  ✅ 后台部署已启动（PID=$pid），云助手命令立即返回。"
  else
    say "  ⚠️ 后台进程未存活，回落【前台】执行（会阻塞，请把云助手超时调到 2400s）"
    internal_deploy
    return $?
  fi
  say "     真进度日志: tail -f $NOHUP_LOG"
  say "     验收命令  : docker ps --format '{{.Names}} {{.Status}}'"
  say "                docker exec ipes ls /data/happ | grep -c happ   （应 = 9）"
  say "                docker exec ipes sh -c 'ps -ef | grep -c \"[h]app\"'  （应 = 9）"
  say "============ 主流程结束，部署转入后台 $(date '+%F %T') ============"
}

if [ "${1:-}" = "--internal-deploy" ]; then
  exec >>"$NOHUP_LOG" 2>&1
  internal_deploy
  exit $?
fi

main_deploy

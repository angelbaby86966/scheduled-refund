#!/bin/bash
# ==============================================================================
# 舟翼云 q2（业务41）一键部署 · v6.1（加固版）
#   ① 先绑定+注册 → 占位符流转「服务中」（节点立刻可被调度）
#   ② 部署（docker + Q2业务 + 9路一次做对 + 真SN回填 + 保活 + 限速）
#      以 setsid 后台运行，云助手命令秒回，真进度写 /var/log/ipes_nohup.log
#   纯净版：不做系统调优（cubic + pfifo_fast），happ 固定 9 路
#
# ------------------------------------------------------------------
# ★★ 部署命令（务必用这个，禁止 `curl … | bash`）★★
#    `curl … | bash` 在下载失败（TCP reset / 404 / 超时）时，bash 收到空输入
#    仍会 exit 0，云助手因此显示「执行成功」，但机器上一个字节都没部署。
#    这是 v6 最致命的静默失败。v6.1 起改为：多源 → 落盘 → 校验 → 执行。
#
#   export Q2_JWT=<你的token>
#   /bin/bash /root/q2_oneclick_v6.sh --bootstrap
#
#   等价的自举命令（不依赖本文件的 --bootstrap，可直接复制粘贴）：
#
#   export Q2_JWT=<你的token>
#   D=/root/q2_oneclick_v6.sh; R=angelbaby86966/scheduled-refund@main/ops/q2_oneclick_v6.sh
#   for U in "https://gh-proxy.com/https://raw.githubusercontent.com/$R" \
#            "https://raw.githubusercontent.com/$R" \
#            "https://cdn.jsdelivr.net/gh/$R"; do
#     curl -fsSL -m 90 "$U" -o "$D" 2>/dev/null && \
#     [ "$(wc -c <"$D")" -gt 3000 ] && bash -n "$D" 2>/dev/null && break
#     rm -f "$D"
#   done
#   [ -s "$D" ] || { echo "[FATAL] 下载失败"; exit 1; }
#   chmod +x "$D"; /bin/bash "$D"
#
# ------------------------------------------------------------------
# 用法：先备好 token（export Q2_JWT=xxx，或 echo <token> > /etc/q2/jwt）
#      云助手「命令助手」超时 ≥1200 秒（仅绑定时长）。
#      普通重跑：/bin/bash q2_oneclick_v6.sh
#      自举下载：/bin/bash q2_oneclick_v6.sh --bootstrap
#      后台部署子进程（勿手工调用）：/bin/bash q2_oneclick_v6.sh --internal-deploy
# ==============================================================================

# ==============================================================================
# 基础设施（bootstrap / 主流程 / 子进程共用，必须最先定义）
# ==============================================================================
LOG=/tmp/q2_v6_$$.log
touch "$LOG" 2>/dev/null || LOG=/dev/null
exec > >(tee -a "$LOG" 2>/dev/null) 2>&1
say() { echo "[$(date '+%H:%M:%S')] $*"; }
FAIL=""; mark_fail() { FAIL="${FAIL} $1"; say "  ✗ 失败：$1"; }
# 失败步骤汇总（去首尾空格 + 空格转逗号），供验收行与调用方 grep
fail_list() { printf '%s' "$FAIL" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/,/g'; }

# ==============================================================================
# ★ 通用下载器：多源依次尝试 → 落盘 → 校验（大小 + bash -n）→ 换下一个源
#   用法: fetch_script <输出文件> <最小字节> <超时秒> <尝试轮数> <URL...>
#   返回: 0=全部校验通过；1=所有源都失败
#   说明: 任何一次失败都不会让上层"看起来成功"，上层必须显式判断返回值。
# ==============================================================================
fetch_script() {
  local out="$1" min="$2" to="$3" rounds="$4"; shift 4
  local u tmp sz r
  mkdir -p "$(dirname "$out")" 2>/dev/null
  rm -f "$out" 2>/dev/null
  for r in $(seq 1 "$rounds"); do
    [ "$r" -gt 1 ] && say "     ↻ 第 $r/$rounds 轮重试…"
    for u in "$@"; do
      tmp="${out}.part.$$"
      rm -f "$tmp" 2>/dev/null
      say "     ↘ 源: $u"
      if ! curl -fsSL -m "$to" "$u" -o "$tmp" 2>/dev/null; then
        say "        ✗ 下载失败（网络错误/404/超时）"; rm -f "$tmp" 2>/dev/null; continue
      fi
      sz=$(wc -c <"$tmp" 2>/dev/null | tr -d ' ')
      case "${sz:-x}" in (''|*[!0-9]*) sz=0 ;; esac
      if [ "$sz" -lt "$min" ]; then
        say "        ✗ 内容过小（${sz}B < ${min}B，疑似被截断/网关拦截页）"
        rm -f "$tmp" 2>/dev/null; continue
      fi
      if ! bash -n "$tmp" 2>/dev/null; then
        say "        ✗ bash -n 语法校验失败（内容不是可执行脚本）"
        rm -f "$tmp" 2>/dev/null; continue
      fi
      if mv -f "$tmp" "$out" 2>/dev/null; then
        say "        ✅ 校验通过（${sz}B，bash -n OK）→ $out"
        return 0
      fi
      say "        ✗ 落盘失败：$out"
      rm -f "$tmp" 2>/dev/null
    done
  done
  rm -f "$out" 2>/dev/null
  return 1
}

# ==============================================================================
# ★ 自举段：安全地把自己下载到磁盘并执行（对应 v6 的缺陷①）
#   多源 gh-proxy.com → raw.githubusercontent.com → cdn.jsdelivr.net
#   全失败必须非 0 退出并打印 [FATAL]，绝不允许"静默成功"。
# ==============================================================================
Q2_REF="${Q2_REF:-92e5cff4bb102d3fc2290deb995336c9a1838ca}"
Q2_RAW="https://raw.githubusercontent.com/angelbaby86966/scheduled-refund@${Q2_REF}/ops/q2_oneclick_v6.sh"
Q2_CDN="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@${Q2_REF}/ops/q2_oneclick_v6.sh"
Q2_BOOT_DST="${Q2_BOOT_DST:-/root/q2_oneclick_v6.sh}"

q2_bootstrap() {
  say "===== q2 v6.1 自举下载（多源 + 落盘 + 校验，禁止 curl|bash）====="
  say "  目标: $Q2_BOOT_DST"
  if fetch_script "$Q2_BOOT_DST" 3000 90 2 \
      "https://gh-proxy.com/${Q2_RAW}" \
      "${Q2_RAW}" \
      "${Q2_CDN}"; then
    chmod +x "$Q2_BOOT_DST" 2>/dev/null
    say "  ✅ 主脚本已落盘并通过校验，开始执行：/bin/bash $Q2_BOOT_DST $*"
    exec /bin/bash "$Q2_BOOT_DST" "$@"
  fi
  # ↓↓↓ 绝不静默：所有源都失败 → 明确报错 + 非 0 退出 ↓↓↓
  echo "[FATAL] 下载失败：q2_oneclick_v6.sh 全部候选源均不可用或校验未通过（gh-proxy.com / raw.githubusercontent.com / cdn.jsdelivr.net）" >&2
  say "  ❌ [FATAL] 下载失败，未执行任何部署动作；请检查出网/代理后重试"
  exit 1
}

if [ "${1:-}" = "--bootstrap" ]; then
  shift
  q2_bootstrap "$@"
fi

# ==============================================================================
# 部署参数
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
ADMIN_APPID="${Q2_APPID:-fg5c21pbzfgu6y2s2yqvanvr6uv99drq}"
ADMIN_AK="${Q2_ADMIN_AK:-ja3io44nq2m7hx63fjkpio7s422aksel}"
ADMIN_SK="${Q2_ADMIN_SK:-ydDGuguZ8COcJN4Ztl3Lsic3Z00zGEani8fYOPiYk2XXCuXQ1AHyy7E1sgV4dyDT}"
LIMIT_START="23:59"; LIMIT_END="18:25"; HAPP_N=9
# ★ 9 路就绪门限（对应 v6 的缺陷②）：有限重试，不再"提示一句就跳过"
READY_TRY="${Q2_READY_TRY:-6}"
READY_WAIT="${Q2_READY_WAIT:-15}"
READY_MISSING=""; NINE_OK=1

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
# ★ 真 SN 读取：双路径 + 容器内/宿主机都试，取第一个"非空且长度 ≥ 60"的结果。
#   ⚠️ 路径必须是【单数 ipes】！机器实测铁证：
#      /app/ipes/bin/ipes_sn 存在（76字节），复数 /app/ipses/... 永失败。
#      v6/v6.1 早期版写成复数 → 真 SN 永远读空（18 轮全 0 字节）。
#      同理 Q2 官方 docker run 用 /app/ipes/bin/ipes start。
# ==============================================================================
SN_IN_PATHS="/app/ipes/bin/ipes_sn /usr/local/edge/ipes_sn"
SN_HOST_PATHS="/usr/local/edge_zycloud/ipes_sn /usr/local/edge/ipes_sn"
read_sn() {
  local p v
  SN=""
  for p in $SN_IN_PATHS; do
    v=$(docker exec ipes cat "$p" 2>/dev/null | tr -d '\r\n')
    if [ "${#v}" -ge 60 ]; then SN="$v"; SN_SRC="container:$p"; return 0; fi
    [ -n "$v" ] && say "     · 容器内 $p 有内容但仅 ${#v} 字节(<60)，继续换路径"
  done
  for p in $SN_HOST_PATHS; do
    [ -f "$p" ] || continue
    v=$(tr -d '\r\n' <"$p" 2>/dev/null)
    if [ "${#v}" -ge 60 ]; then SN="$v"; SN_SRC="host:$p"; return 0; fi
  done
  return 1
}
# 当前已存在的 SN（无则空），用于"避免用占位符覆盖真 SN"
sn_current() { read_sn >/dev/null 2>&1; printf '%s' "$SN"; }

# ==============================================================================
# ★ 就绪探测（对应 v6 的缺陷②）
#   返回 0 = 容器 + custom.yml + happ.0 全部就绪；否则把缺失项写进 READY_MISSING
#   ⚠️ CFG 路径必须是【单数 ipes】！机器实测：/opt/ipes/var/db/ipes/happ-conf/custom.yml。
#      写成复数 → [ -f "$CFG" ] 永假 → 9 路分支永远走 else → happ 永远 1 路。
# ==============================================================================
ROOT=/data/happ; CFG=/opt/ipes/var/db/ipes/happ-conf/custom.yml
IMG="ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:latest"
ready_probe() {
  READY_MISSING=""
  docker inspect ipes >/dev/null 2>&1 || READY_MISSING="$READY_MISSING 容器ipes"
  [ -f "$CFG" ] || READY_MISSING="$READY_MISSING custom.yml"
  [ -d "$ROOT/happ.0" ] || READY_MISSING="$READY_MISSING happ.0"
  [ -z "$READY_MISSING" ]
}
wait_ready() {
  local i=1
  while [ "$i" -le "$READY_TRY" ]; do
    if ready_probe; then say "     ✅ 就绪探测通过（第 $i/$READY_TRY 次）"; return 0; fi
    say "     ⏳ 未就绪（$i/$READY_TRY）缺少：$READY_MISSING → ${READY_WAIT}s 后重试"
    i=$((i+1))
    [ "$i" -le "$READY_TRY" ] && sleep "$READY_WAIT"
  done
  say "     ✗ 等待 $READY_TRY 次（$((READY_TRY * READY_WAIT))s）仍不就绪，缺少：$READY_MISSING"
  return 1
}

LOCK=/var/run/ipes_deploy.lock
NOHUP_LOG=/var/log/ipes_nohup.log
STATUS_FILE=/var/log/ipes_deploy.status

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
  CUR=$(docker exec ipes ls -d /data/happ/happ.* 2>/dev/null | wc -l | tr -d ' ')
  say "     容器内实际可见 ${CUR:-0} 个分片（期望 $HAPP_N）"
  if [ "${CUR:-0}" = "$HAPP_N" ]; then
    say "     ✅ 已是 ${HAPP_N} 路，跳过"
  elif wait_ready; then
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
      rm -f "$TMP"; say "     ✗ 配置条数异常($CNT != $HAPP_N)，保留现场"
      NINE_OK=0; mark_fail "9路部署(配置条数异常:$CNT!=$HAPP_N)"
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
      # ⚠️ 挂载目标与启动命令必须是【单数 ipes】！与 Q2 官方 docker run 完全一致：
      #    -v /opt/ipes/.../custom.yml:/app/ipes/.../custom.yml + /app/ipes/bin/ipes start
      docker run -d --restart=always --name=ipes --network=host $MARGS \
        -v "$CFG:/app/ipes/var/db/ipes/happ-conf/custom.yml" \
        "$IMG" sh -c '/app/ipes/bin/ipes start && tail -f /dev/null' >/dev/null 2>&1
      RCD=$?
      say "     docker run 返回码=$RCD"
      [ "$RCD" != "0" ] && { NINE_OK=0; mark_fail "9路部署(docker run 返回码=$RCD)"; }
      # 健康轮询：等 happ 进程达到 9 路（最多 60s），替代固定 sleep 40
      for _h in $(seq 1 12); do
        HP=$(docker exec ipes sh -c 'ps -ef | grep -c "[h]app"' 2>/dev/null | tr -d '\r')
        [ "${HP:-0}" = "$HAPP_N" ] && break
        sleep 5
      done
      NEW=$(docker exec ipes ls -d /data/happ/happ.* 2>/dev/null | wc -l | tr -d ' ')
      HP=$(docker exec ipes sh -c 'ps -ef | grep -c "[h]app"' 2>/dev/null | tr -d '\r')
      if [ "${NEW:-0}" = "$HAPP_N" ]; then
        say "     ✅ ${HAPP_N} 路已真正生效：容器内分片=$NEW happ进程=$HP"
      else
        say "     ❌ 重建后容器内分片=$NEW（期望$HAPP_N）；happ进程=$HP"
        say "        现场保留：$CFG.bak.* 可回滚；重跑本脚本会再修一次（幂等）"
        NINE_OK=0; mark_fail "9路部署(重建后分片=$NEW!=$HAPP_N)"
      fi
    fi
  else
    # ★ v6 这里只 say 一句就跳过 → 静默失败。v6.1 明确标红并计入失败。
    say "     ❌ 容器或 custom.yml 未就绪，已放弃本轮 9 路部署（重跑本脚本会再修一次）"
    NINE_OK=0; mark_fail "9路部署(未就绪:$READY_MISSING)"
  fi

  # 2.5 真 SN 回填 + 再流转（紧接部署，不分离）
  NID=$(node_id)
  say "  [2.5] 读真SN → 回填 → 再流转…"
  SN=""; SN_SRC=""
  for i in $(seq 1 18); do
    if read_sn; then
      say "     ✅ 取到真SN（${#SN}字节，来源 $SN_SRC）"; break
    fi
    say "     等 SN（$i/18，尝试 /app/ipes/bin/ipes_sn → /usr/local/edge/ipses_sn）…"; sleep 10
  done
  if [ ${#SN} -ge 60 ] && [ -n "$NID" ]; then
    LOC=$(detect_loc)
    say "     SN=${SN:0:16}…（${#SN}字节）"
    say "     降级→待配置: $(flow "$NID" "$SN" configured)"
    say "     提交属性(41/200M/${ISP}): $(submit_nominal "$NID" "${LOC%%|*}" "${LOC##*|}")"
    sleep 2
    say "     升回→服务中: $(flow "$NID" "$SN" inService)"
  else
    say "     ⚠️ 未取到真SN（${#SN}字节，来源 ${SN_SRC:-无}），重跑本脚本会自动只补这一步"
  fi

  # ==============================================================================
  say ""; say "===== [3/4] 安装保活 ====="
  # ★ 修 v6 的缺陷③（下载失败无重试无校验）+ 实测发现：OSS 上
  #   install_ipses_health_check.sh 返回 404，而 Q2 官方部署脚本
  #   （ecache_auto_disk_install.sh）自己会装 /usr/local/bin/ipes_health_check.sh
  #   + cron(* * * * *)，所以 v6 的保活段本来就是"误报失败"。
  #   新逻辑：① 已就绪(脚本+cron 都在) → ✅ 跳过，不算失败；
  #           ② 未就绪 → 多源 + 3 轮重试 + 落盘校验安装，装不上才 mark_fail。
  HC_SCRIPT=/tmp/_hc.sh
  HC_BIN=/usr/local/bin/ipes_health_check.sh
  HC_URL="${Q2_HC_URL:-$OSS/Q2_test/install_ipses_health_check.sh}"
  hc_cron_cnt() { crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check'; }
  if [ -x "$HC_BIN" ] && [ "$(hc_cron_cnt)" -ge 1 ] 2>/dev/null; then
    say "  ✅ 保活已就绪：$HC_BIN 存在，cron $(hc_cron_cnt) 条，跳过安装"
  else
    say "  保活未就绪（HC_BIN=$([ -x "$HC_BIN" ] && echo 有 || echo 无)，cron $(hc_cron_cnt) 条），开始安装…"
    if fetch_script "$HC_SCRIPT" 200 120 3 "$HC_URL"; then
      say "  执行保活安装脚本…"
      if bash "$HC_SCRIPT"; then
        say "  ✅ 保活安装脚本执行完成"
      else
        mark_fail "保活(脚本执行返回码=$?)"
      fi
    else
      say "  ❌ 保活脚本下载失败（已尝试 $HC_URL，3 轮）"
      mark_fail "保活(下载失败:$HC_URL)"
    fi
  fi
  say "  保活cron: $(hc_cron_cnt) 条"

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
  ACC_SN=""; ACC_SN_SRC=""
  SN=""; SN_SRC=""
  if read_sn >/dev/null 2>&1; then ACC_SN="$SN"; ACC_SN_SRC="$SN_SRC"; fi
  say "真SN     : ${ACC_SN:-未取到}  (来源 ${ACC_SN_SRC:-无})"
  say "SN 长度  : ${#ACC_SN}  (期望 76)"
  say "保活cron : $(hc_cron_cnt) 条（脚本 $([ -x "$HC_BIN" ] && echo 存在 || echo 缺失)）"
  say "限速     : qdisc $(tc qdisc show dev eth0 2>/dev/null | grep -c htb) / cron $(crontab -l 2>/dev/null | grep -cE 'limit_start|clear_limit') 条"
  say "纯净版   : CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null) Q=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)  (应 cubic + pfifo_fast)"
  say "nodeID   : $(node_id)"
  if [ "$NINE_OK" = "1" ]; then
    say "9路部署  : ✅ 完成"
  else
    say "9路部署  : ❌ 未完成（详见上文 9 路段落）"
  fi
  # ★ 汇总判定：调用方 grep 这一行即可，不必逐条读指标
  if [ -n "$FAIL" ]; then
    say "==== 总体结果:失败（失败步骤:$(fail_list)）===="
  else
    say "==== 总体结果:成功 ===="
  fi
  say "============ 后台部署完成 $(date '+%F %T') ============"
  # 机器可读状态文件（供云助手/巡检判断，避免再次"看起来成功"）
  {
    printf 'time=%s\n' "$(date '+%F %T')"
    printf 'node_id=%s\n' "$(node_id)"
    printf 'happ_shards=%s\n' "$(docker exec ipes ls /data/happ 2>/dev/null | grep -c happ)"
    printf 'nine_deploy=%s\n' "$([ "$NINE_OK" = "1" ] && echo OK || echo FAIL)"
    if [ -n "$FAIL" ]; then
      printf 'result=FAIL\nfailed_steps=%s\n' "$(fail_list)"
    else
      printf 'result=OK\nfailed_steps=\n'
    fi
  } > "$STATUS_FILE" 2>/dev/null
  say "  状态文件: $STATUS_FILE"
  [ -n "$FAIL" ] && return 1
  return 0
}

# ==============================================================================
# 主流程（云助手执行这段，秒回）：绑定 → 占位符流转 → 启动后台部署
# ==============================================================================
main_deploy() {
  say "===== q2 一键部署 v6.1（加固版）开始 $(date '+%F %T') ====="
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
    SN_NOW=$(sn_current)
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
  #    ★ v6.1：落盘也走「多源 + 校验」，下载失败不再静默回落。
  #    落盘顺序：① BASH_SOURCE(文件执行场景) ② Q2_SELF_URL 多源自下载(管道场景)
  SELF="/etc/q2/q2_oneclick_v6.self.sh"
  mkdir -p /etc/q2 2>/dev/null
  # ① 文件执行场景：直接复制自身
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -s "${BASH_SOURCE[0]:-}" ]; then
    cp -f "${BASH_SOURCE[0]}" "$SELF" 2>/dev/null
    say "  · 自身落盘(复制 BASH_SOURCE) → $SELF"
  fi
  # ② 管道场景：BASH_SOURCE 为空，改用多源 + 校验自下载
  if [ ! -s "$SELF" ]; then
    say "  · 管道执行无本地路径，多源 + 校验自下载脚本 → $SELF"
    if fetch_script "$SELF" 3000 90 2 \
        "https://gh-proxy.com/${Q2_RAW}" \
        "${Q2_RAW}" \
        "${Q2_CDN}"; then
      say "  · 自下载校验通过"
    else
      say "  ❌ 自下载失败（全部源不可用/校验未通过）"
    fi
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
  say "     验收命令  : grep '==== 总体结果' $STATUS_FILE"
  say "                docker ps --format '{{.Names}} {{.Status}}'"
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
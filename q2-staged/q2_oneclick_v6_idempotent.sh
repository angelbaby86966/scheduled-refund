#!/bin/bash
# ==============================================================================
# 舟翼云 q2（业务41）一键部署 · v6-cache-safe（保继承缓存）
#   基线：q2-staged/q2_oneclick_v5_pure.sh @340771c（v5 纯净版：cubic+pfifo_fast，happ 9 路）
#   定位：只优化「等待与编排」，业务语义/保活/限速/验收逻辑与原版完全一致
#
#   优化点（新机实测 ~30min → 预期 ~12-18min，收益取决于绑定与拉镜像的重叠度）：
#     O1 并行编排：渠道绑定 ∥（docker 安装 → 镜像预拉取 → Q2 组件预下载+patch）
#        · 绑定(zyy_init_max) 与 docker(yum) 无共享资源，可安全并行
#        · 预拉取与官方 docker run 同一 repo:tag（ccr.ccs.tencentyun.com/zyy_cloud/
#          ipes-linux-amd64-youkai-latest:latest），官方 clean_existing_containers 不清镜像
#     O2 官方 ecache_docker_install_ali_ten.sh 固定 `sleep 90s`（其 521 行）
#        → 轮询 ipes_sn 可读即走（上限仍 90s，通常 3-6s）
#     O3 9 路重建容器后固定 `sleep 40` → 轮询 happ 进程数=9（上限 60s，通常 10-20s）
#     O4 容器初始化等待 30s/轮 → 5s/轮；SN 等待 30s/轮 → 5s/轮（24 轮=120s 上限）
#     O5 全流程阶段耗时打点，验收段输出各阶段秒数（下次部署可直接看时间花在哪）
#
#   回退开关：
#     Q2_NO_PARALLEL=1  退回「绑定 → docker → Q2」串行（其余优化保留）
#     Q2_SKIP_PATCH=1   不 patch 官方脚本（sleep 90s 原样保留）
#
#   用法：export Q2_JWT=xxx Q2_AK=xxx Q2_SK=xxx 后
#         nohup bash q2_oneclick_v6_cache_safe.sh > /tmp/q2_v5.log 2>&1 &
# ==============================================================================
Q2_JWT_FILE="${Q2_JWT_FILE:-/etc/q2/jwt}"
if [ -z "${Q2_JWT:-}" ] && [ -f "$Q2_JWT_FILE" ]; then
  Q2_JWT="$(cat "$Q2_JWT_FILE" 2>/dev/null | tr -d '[:space:]')"
fi
: "${Q2_JWT:?未找到 JWT：请 export Q2_JWT=xxx，或 echo <新token> > $Q2_JWT_FILE（脚本已不再内置密钥）}"
JWT="$Q2_JWT"
# ── 渠道/管理员凭证全部外置：脚本不再内置任何密钥，缺失即报错退出 ──
: "${Q2_AK:?未找到渠道 AK：请 export Q2_AK=xxx（脚本已去除内置凭证，以外置为准）}"
: "${Q2_SK:?未找到渠道 SK：请 export Q2_SK=xxx（脚本已去除内置凭证，以外置为准）}"
CHAN_AK="$Q2_AK"
CHAN_SK="$Q2_SK"
ISP="${Q2_ISP:-联通}"
PLACEHOLDER="ZHOUYI_XIAODU"
ADMIN_API="https://admin.zhouyi.top"
OSS="https://zyy-go.oss-cn-beijing.aliyuncs.com/script"
# ── admin API 凭证：内置默认（2026-10-22 确认可内置），env 可覆盖 ──
ADMIN_APPID="${Q2_APPID:-fg5c21pbzfgu6y2s2yqvanvr6uv99drq}"
ADMIN_AK="${Q2_ADMIN_AK:-ja3io44nq2m7hx63fjkpio7s422aksel}"
ADMIN_SK="${Q2_ADMIN_SK:-ydDGuguZ8COcJN4Ztl3Lsic3Z00zGEani8fYOPiYk2XXCuXQ1AHyy7E1sgV4dyDT}"
LIMIT_START="23:59"; LIMIT_END="18:25"; HAPP_N=9
# ★ O1：与官方 `-t 2`（省外 youkai-latest）完全一致的 repo:tag，预拉取才能被官方 docker run 复用
# ★ 镜像源：默认用已验证可拉的腾讯源（新机 v5_pure_fast 同款，实测可达）；
#   要用「省外阿里云镜像源」只需在命令前加 Q2_IMG=registry.cn-<省>.aliyuncs.com/<ns>/ipes-linux-amd64-youkai-latest:latest
IMG="${Q2_IMG:-ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:latest}"

LOG=/tmp/q2_v4_$$.log
touch "$LOG" 2>/dev/null || LOG=/dev/null
exec > >(tee -a "$LOG" 2>/dev/null) 2>&1
say() { echo "[$(date '+%H:%M:%S')] $*"; }
FAIL=""; mark_fail() { FAIL="${FAIL} $1"; say "  ✗ 失败：$1"; }

# ---- O5：阶段耗时打点 ----
T0=$(date +%s); T_PAR=0; T_Q2=0; T_NINE=0; T_SN=0
dur() { echo "$(( $2 - $1 ))s"; }

say "===== q2 一键部署 v5-pure-fast 开始 $(date '+%F %T') ====="
say "日志: $LOG"

LOCK=/var/run/ipes_deploy.lock
exec 9>"$LOCK" 2>/dev/null
if flock -n 9 2>/dev/null; then say "✅ 部署锁已获取（防并发互踩）"
else say "❌ 本机已有部署在运行，本次退出"; say "   确认前一份卡死： rm -f $LOCK"; exit 1; fi

node_id() { cat /usr/local/edge_zycloud/device_code 2>/dev/null || cat /usr/local/edge/device_code 2>/dev/null || cat /etc/.mac 2>/dev/null; }
# ★ doctor 幂等守卫：保活脚本存在 + crontab 有健康检查条目 → 视为已装
doctor_ok() {
  [ -f /usr/local/bin/ipes_health_check.sh ] || return 1
  crontab -l 2>/dev/null | grep -qE 'ipes_health_check\.sh' || return 1
  return 0
}
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
# ★ 真 SN 回填 + 再流转（抽成函数，正常部署与「快捷路径」共用）
sn_flow() {
  say "  [SN] 读真SN → 回填 → 再流转服务中…"
  if [ "${Q2_NEW_SN:-0}" = "1" ]; then
    say "     [新SN] 删除旧SN并重启 ipes 以重新生成…"
    docker exec ipes rm -f /app/ipes/bin/ipes_sn 2>/dev/null
    docker restart ipes >/dev/null 2>&1 || true
    sleep 5
  fi
  local SN=""
  for i in $(seq 1 24); do
    SN=$(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n')
    [ ${#SN} -ge 60 ] && break
    say "     等 SN（$i/24，${#SN}字节）…"; sleep 5
  done
  if [ ${#SN} -ge 60 ] && [ -n "$NID" ]; then
    local LOC; LOC=$(detect_loc)
    say "     SN=${SN:0:16}…（${#SN}字节）"
    say "     降级→待配置: $(flow "$NID" "$SN" configured)"
    say "     提交属性(41/200M/${ISP}): $(submit_nominal "$NID" "${LOC%%|*}" "${LOC##*|})")"
    sleep 2
    say "     升回→服务中: $(flow "$NID" "$SN" inService)"
  else
    say "     ⚠️ 未取到真SN（${#SN}字节），重跑本脚本会自动只补这一步"
  fi
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
# ★ 幂等快路径判定：克隆机若已装 doctor + 已拉 q2 镜像 + 继承缓存已挂载 + 有 nodeID
#   → 跳过一切重装，仅做 SN 回填+流转（保留缓存，不碰磁盘/镜像/doctor）
#   否则走完整 [2/4]+[3/4] 部署（部署内各步仍各自幂等：docker/镜像/doctor 有了就不动）
# =============================================================================
FAST=0
if doctor_ok && docker image inspect "$IMG" >/dev/null 2>&1 \
   && [ -d /data/happ ] && [ -n "$(ls -A /data/happ 2>/dev/null)" ] && [ -n "$NID" ]; then
  FAST=1
  say "  [幂等] doctor✔ 镜像✔ 缓存✔ nodeID✔ → 跳过重装，直接进入 SN 回填+流转（保留缓存）"
fi
if [ "$FAST" = "1" ]; then
  CACHE_PROTECT=1
  T_PAR=$T0; T_NINE=$T0   # O5：快路径无重装阶段，打点对齐，避免负数耗时
  docker start ipes >/dev/null 2>&1 || true
  for _c in $(seq 1 12); do docker ps --format '{{.Names}}' | grep -qx ipes && break; sleep 5; done
  sn_flow
  T_SN=$(date +%s)
  say ""; say "===== [3/4] doctor 已存在，跳过安装 ====="
  say "  保活cron: $(crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check') 条"
else

# ==============================================================================
# ② 部署 + 9 路一次做对 + 真SN回填（同一流程内闭环）
#    O1：绑定 ∥（docker → 预拉镜像 → Q2 组件预下载+patch）
# ==============================================================================
say ""; say "===== [2/4] 部署：绑定 ∥ docker+预拉 → Q2业务 → 9路 → 真SN回填 ====="

# ---- O1-a：docker 安装（已就绪则跳过）+ 镜像预拉取 ----
install_docker_and_prepull() {
  local rc=0
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    say "  [2.2] docker 已就绪（$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')），跳过安装"
  else
    say "  [2.2] 安装 docker…"
    if ! { curl -fsSL -m 300 "$OSS/install_docker/install_docker-ce_v2.sh" -o /tmp/_dk.sh 2>/dev/null \
        && bash /tmp/_dk.sh; }; then
      say "  ✗ docker 安装失败"; rc=1
    fi
  fi
  say "  docker: $(docker --version 2>/dev/null || echo 失败)"
  if [ "$rc" = "0" ]; then
    if docker image inspect "$IMG" >/dev/null 2>&1; then
      say "  [2.2b] 镜像已存在，跳过预拉取"
    else
      say "  [2.2b] 预拉取镜像 $IMG（最多 3 次，失败不阻塞）…"
      local _ok=0 _p
      for _p in 1 2 3; do
        docker pull "$IMG" >/dev/null 2>&1 && { _ok=1; break; }
        say "     第 $_p 次失败，10s 后重试…"; sleep 10
      done
      if [ "$_ok" = "1" ]; then say "  [2.2b] ✅ 预拉取完成，官方 docker run 将秒起"
      else say "  [2.2b] ⚠️ 预拉取失败（不阻塞，官方 docker run 时会自行拉取）"; fi
    fi
  fi
  return $rc
}

# ---- O1-b/O2：Q2 组件预下载 + 去掉官方固定 sleep 90s ----
prep_q2_components() {
  curl -fsSL -m 300 "$OSS/Q2_test/ecache_auto_disk_install.sh" -o /tmp/_q2.sh 2>/dev/null || return 1
  [ "${Q2_SKIP_PATCH:-0}" = "1" ] && return 0
  curl -fsSL -m 600 "$OSS/Q2_test/ecache_docker_install_ali_ten.sh" -o /tmp/_q2_ali.sh 2>/dev/null || return 0
  if grep -qE '^sleep 90s[[:space:]]*$' /tmp/_q2_ali.sh; then
    # 固定 sleep 90s → 轮询 ipes_sn 可读即走（上限仍 30×3s=90s，与官方最坏情况一致）
    sed 's#^sleep 90s[[:space:]]*$#for _s in $(seq 1 30); do docker exec ipes cat bin/ipes_sn 2>/dev/null | grep -q . \&\& break; sleep 3; done#' \
      /tmp/_q2_ali.sh > /tmp/_q2_ali.sh.new && mv /tmp/_q2_ali.sh.new /tmp/_q2_ali.sh
    # 分发器内的 curl|bash 管道 → 改调本地 patch 版（保留 -t/-i 参数）
    sed -E 's#curl +https?://zyy-go\.oss-cn-beijing\.aliyuncs\.com/script/Q2_test/ecache_docker_install_ali_ten\.sh +\| +bash -s --#bash /tmp/_q2_ali.sh#' \
      /tmp/_q2.sh > /tmp/_q2.sh.new && mv /tmp/_q2.sh.new /tmp/_q2.sh
    say "  [2.2c] 已 patch 官方组件：sleep 90s → SN就绪轮询（上限90s）"
  else
    rm -f /tmp/_q2_ali.sh
    say "  [2.2c] 官方组件未见 sleep 90s（版本可能已变），未 patch，按原样执行"
  fi
  return 0
}

NEED_BIND=0
if [ -z "$NID" ] || ! grep -q "注册状态: 成功" /usr/local/edge/registration_info 2>/dev/null; then NEED_BIND=1; fi

if [ "$NEED_BIND" = "1" ] && [ "${Q2_NO_PARALLEL:-0}" != "1" ]; then
  # ---- O1：并行路径（绑定 ∥ docker+预拉+组件patch）----
  say "  [并行] 渠道绑定 ∥ docker安装+镜像预拉取（Q2_NO_PARALLEL=1 可退回串行）"
  BLOG=/tmp/q2_bind_$$.log; DLOG=/tmp/q2_dk_$$.log
  BRC=/tmp/q2_bind_$$.rc;   DRC=/tmp/q2_dk_$$.rc
  (
    say "  [2.1] 渠道绑定 + 设备注册（zyy_init_max OSS 原版，5-10 分钟）…"
    curl -fsSL -m 900 "$OSS/zyy_init/zyy_init_max.sh" -o /tmp/_bind.sh 2>/dev/null \
      && bash /tmp/_bind.sh --ak "$CHAN_AK" --sk "$CHAN_SK" --isp "$ISP"
    echo $? > "$BRC"
  ) > "$BLOG" 2>&1 &
  (
    install_docker_and_prepull; _dk_rc=$?
    prep_q2_components
    echo "$_dk_rc" > "$DRC"
  ) > "$DLOG" 2>&1 &
  wait
  say "  ── 绑定日志（尾 8 行）──"
  grep -vE '^\s*$' "$BLOG" 2>/dev/null | tail -n 8 | sed 's/^/    /'
  say "  ── docker/镜像/组件日志（尾 12 行）──"
  grep -vE '^\s*$' "$DLOG" 2>/dev/null | tail -n 12 | sed 's/^/    /'
  [ -s "$BRC" ] && [ "$(cat "$BRC")" != "0" ] && mark_fail "绑定"
  [ -s "$DRC" ] && [ "$(cat "$DRC")" != "0" ] && mark_fail "docker安装"
  rm -f "$BRC" "$DRC"
  # 双保险：即便 exit 0，注册未确认成功也判失败（吞错 bug 兜底，与原版一致）
  if ! grep -q "注册状态: 成功" /usr/local/edge/registration_info 2>/dev/null; then
    mark_fail "绑定"
    say "     ── 绑定/注册未确认成功，最后 20 行安装日志（真因在这里）──"
    tail -n 20 /var/log/zycloud_agent_setup.log 2>/dev/null | sed 's/^/       /'
  fi
  NID=$(node_id); say "  nodeID=${NID:-未生成}"
else
  # ---- 串行路径（与原版行为一致，仅保留 O2-O4 优化）----
  if [ "$NEED_BIND" = "1" ]; then
    say "  [2.1] 渠道绑定 + 设备注册（zyy_init_max OSS 原版，5-10 分钟）…"
    BIND_OK=0
    curl -fsSL -m 900 "$OSS/zyy_init/zyy_init_max.sh" -o /tmp/_bind.sh 2>/dev/null \
      && bash /tmp/_bind.sh --ak "$CHAN_AK" --sk "$CHAN_SK" --isp "$ISP" \
      && BIND_OK=1
    if [ "$BIND_OK" != "1" ] || ! grep -q "注册状态: 成功" /usr/local/edge/registration_info 2>/dev/null; then
      mark_fail "绑定"
      say "     ── 绑定/注册失败，最后 20 行安装日志（真因在这里）──"
      tail -n 20 /var/log/zycloud_agent_setup.log 2>/dev/null | sed 's/^/       /'
    fi
    NID=$(node_id); say "  nodeID=${NID:-未生成}"
  else
    say "  [2.1] 已绑定，跳过"
  fi
  install_docker_and_prepull || mark_fail "docker安装"
  prep_q2_components
fi
T_PAR=$(date +%s); say "  ⏱ 绑定+docker+预拉阶段耗时 $(dur $T0 $T_PAR)"

# ============================================================
# ★ 缓存保护（v6-cache-safe 核心）：克隆机若已挂载且有继承缓存(/data/happ 非空)，
#   把上游 ecache_auto_disk_install.sh 内会清缓存的步骤（uninstall_ecache / umount_disk /
#   auto_mount_disk 内含 mkfs）全部置为 no-op，仅保留容器安装；空白机走原版完整流程。
# ============================================================
if [ -d /data/happ ] && [ -n "$(ls -A /data/happ 2>/dev/null)" ]; then
  sed -i -E 's#curl[[:space:]]+(https?:)?//[^ ]*(uninstall_ecache|umount_disk|auto_mount_disk)\.sh[[:space:]]*\|[[:space:]]*bash#true#g' /tmp/_q2.sh
  docker rm -f ipes >/dev/null 2>&1 || true   # 仅清容器避免 docker run 冲突，不碰磁盘缓存
  CACHE_PROTECT=1
  say "  [缓存保护] 检测到继承缓存(/data/happ)，已禁用上游清缓存/mkfs，仅重装容器"
else
  CACHE_PROTECT=0
  say "  [缓存保护] 未检测到继承缓存，走原版完整流程(含磁盘挂载/格式化)"
fi

say "  [2.3] Q2 业务部署（-i 2 -t 2）…"
if [ -s /tmp/_q2.sh ]; then
  bash /tmp/_q2.sh -i 2 -t 2 || mark_fail "Q2部署"
else
  curl -fsSL -m 1800 "$OSS/Q2_test/ecache_auto_disk_install.sh" -o /tmp/_q2.sh 2>/dev/null \
    && bash /tmp/_q2.sh -i 2 -t 2 || mark_fail "Q2部署"
fi

# 2.4 ★ 9 路在部署流程内一次做对（不是后面对齐）
say "  [2.4] happ 路数一次做对（目标 ${HAPP_N} 路）…"
for _w in $(seq 1 20); do
  docker inspect ipes >/dev/null 2>&1 && [ -d /data/happ/happ.0 ] && break
  say "     等容器初始化（$_w/20）…"; sleep 5
done
ROOT=/data/happ; CFG=/opt/ipes/var/db/ipes/happ-conf/custom.yml
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
      -v "$CFG:/app/ipes/var/db/ipes/happ-conf/custom.yml" \
      "$IMG" sh -c '/app/ipes/bin/ipes start && tail -f /dev/null' >/dev/null 2>&1
    RCD=$?
    say "     docker run 返回码=$RCD"
    # ★ O3：固定 sleep 40 → 轮询 happ 进程=9（上限 12×5s=60s，通常 10-20s 即退）
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
T_NINE=$(date +%s); say "  ⏱ Q2+9路阶段耗时 $(dur $T_PAR $T_NINE)"

# 2.5 真 SN 回填 + 再流转（sn_flow 兼顾正常部署与幂等快路径；快路径已在前面调用过，此处仅正常路径执行）
if [ "$FAST" != "1" ]; then
  say "  [2.5] 读真SN → 回填 → 再流转…"
SN=""
for i in $(seq 1 24); do
  SN=$(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n')
  [ ${#SN} -ge 60 ] && break
  say "     等 SN（$i/24，${#SN}字节）…"; sleep 5
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
fi
T_SN=$(date +%s); say "  ⏱ SN回填阶段耗时 $(dur $T_NINE $T_SN)"

# ==============================================================================
say ""; say "===== [3/4] 安装真保活（融合版 + r20-fix11 硬自愈，内嵌自包含，不依赖外网 OSS）====="
install_health_check() {
  say "  [3.1] 写入 /usr/local/bin/ipes_health_check.sh（容器兜底启动 + ./bin/ipes health 探测 + fix11 挂载自愈）"
  cat > /usr/local/bin/ipes_health_check.sh <<'HEALTH'
#!/usr/bin/env bash
# IPES 健康检查（融合版 + r20-fix11 硬自愈）：容器级 docker start 兜底 + 应用层 ./bin/ipes health 探测，
# 真正异常时才 docker restart 恢复；非交互、并对「探测命令不存在」做了跳过处理避免每分钟重启抖动。
# 容器 docker start 失败时，先执行 fix11_heal（xycould_base_info 目录/缺失 → 43B 文件）再重试启动。
# ★ 这正是「doctor 没了 / 容器没了，都会自动拉起」的实现：cron 每分钟跑一次，
#   容器不在就 docker start（保 SN 不变）；容器在但服务异常就 docker restart（冷却 10 分钟避免抖动）；
#   挂载类型异常（目录取代 43B 文件导致 Exited(127)）先 fix11 修复再起。
LOG=/var/log/ipes_health.log
C=ipes
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
fi
echo "[$(ts)] 检查开始" >> "$LOG"
fix11_heal(){
  local ref=/data/happ/happ.0/xycould_base_info d p fixed=0
  [ -s "$ref" ] || return 1
  for d in /data/happ/happ.*; do
    [ -d "$d" ] || continue
    p="$d/xycould_base_info"
    if [ -d "$p" ]; then
      rmdir "$p" 2>/dev/null || rm -rf "$p" 2>/dev/null
    fi
    if [ ! -e "$p" ]; then
      cp -f "$ref" "$p" 2>/dev/null && fixed=$((fixed+1))
    fi
  done
  if [ "$fixed" -gt 0 ]; then
    echo "[$(ts)] [fix11] 已修复 $fixed 个 xycould_base_info（目录/缺失 → 文件），准备重试启动" >> "$LOG"
    return 0
  fi
  return 1
}
if ! docker ps --format '{{.Names}}' | grep -qx "$C"; then
  echo "[$(ts)] 容器未运行，尝试 docker start（SN 不变）" >> "$LOG"
  if docker start "$C" >> "$LOG" 2>&1; then
    echo "[$(ts)] 已启动" >> "$LOG"
  else
    if fix11_heal; then
      if docker start "$C" >> "$LOG" 2>&1; then
        echo "[$(ts)] [fix11] 修复挂载后已启动" >> "$LOG"
      else
        echo "[$(ts)] [fix11] 修复后仍启动失败：$(docker inspect -f '{{.State.Error}}' "$C" 2>/dev/null | head -c 200)" >> "$LOG"
      fi
    else
      echo "[$(ts)] 启动失败且未发现 fix11 挂载异常，请检查" >> "$LOG"
    fi
  fi
  exit 0
fi
OUT=$(docker exec "$C" ./bin/ipes health 2>&1); RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qiE 'OCI runtime|exec: "|No such file|command not found'; then
  echo "[$(ts)] 健康探测命令不可用，跳过重启($OUT)" >> "$LOG"
  exit 0
fi
if [ "$RC" -ne 0 ] || echo "$OUT" | grep -qiE 'connection refused|get services failed|unhealthy|not healthy|panic|refused to connect'; then
  LR=/var/lib/ipes-preheat/.last_health_restart
  now_ts=$(date +%s)
  last_ts=$(cat "$LR" 2>/dev/null || echo 0)
  if [ $((now_ts - last_ts)) -lt 600 ]; then
    echo "[$(ts)] 检测到异常但处于重启冷却期(10分钟)，本次跳过 ($OUT)" >> "$LOG"
    exit 0
  fi
  mkdir -p /var/lib/ipes-preheat 2>/dev/null
  echo "$now_ts" > "$LR" 2>/dev/null || true
  echo "[$(ts)] 检测到服务异常，准备 docker restart ($OUT)" >> "$LOG"
  docker restart "$C" >> "$LOG" 2>&1 && echo "[$(ts)] 已重启恢复" >> "$LOG" || echo "[$(ts)] 重启失败，请检查" >> "$LOG"
  exit 0
fi
# happ 9 路守恒：v5 固定 9 路，容器内 happ:vod 进程数必须恒为 9；
# 容器活着但某路 happ 进程掉了（health 探针未必能查到分片数下降），这里兜底重启拉回 9 路。
HC=$(docker exec "$C" sh -c 'ps -ef 2>/dev/null | grep -c "[h]app:vod"' 2>/dev/null | tr -d '\r\n')
if [ "${HC:-0}" != "9" ]; then
  LR2=/var/lib/ipes-preheat/.last_happ_restart
  now_ts=$(date +%s)
  last_ts=$(cat "$LR2" 2>/dev/null || echo 0)
  if [ $((now_ts - last_ts)) -lt 600 ]; then
    echo "[$(ts)] happ 进程数=$HC(期望9) 但处于重启冷却期(10分钟)，本次跳过" >> "$LOG"
  else
    mkdir -p /var/lib/ipes-preheat 2>/dev/null
    echo "$now_ts" > "$LR2" 2>/dev/null || true
    echo "[$(ts)] happ 进程数=$HC(期望9)，准备 docker restart 拉回 9 路" >> "$LOG"
    docker restart "$C" >> "$LOG" 2>&1 && echo "[$(ts)] 已重启恢复 9 路" >> "$LOG" || echo "[$(ts)] 重启失败，请检查" >> "$LOG"
  fi
  exit 0
fi
echo "[$(ts)] 服务正常（happ=$HC）" >> "$LOG"
HEALTH
  chmod +x /usr/local/bin/ipes_health_check.sh
  touch /var/log/ipes_health.log 2>/dev/null
  # 精准重建 cron：只替换自己那一行；同时清掉渠道脚本历史写入的 @reboot `bin/ipes stop`（重启后停业务）
  ( crontab -l 2>/dev/null | grep -vE 'ipes_health_check|bin/ipes[[:space:]]+stop' ; \
    echo "* * * * * /usr/local/bin/ipes_health_check.sh >/dev/null 2>&1" ) | crontab -
  systemctl enable crond >/dev/null 2>&1 || true
  systemctl start crond >/dev/null 2>&1 || true
  say "  [3.2] cron 已写入（每分钟兜底启动容器 + health 探测，异常重启冷却10分钟）"
}
  if doctor_ok; then
    say "  [3.0] doctor 已存在（脚本 + crontab 条目），按「有了就不动」跳过安装"
  else
    install_health_check || mark_fail "保活"
  fi
say "  保活cron: $(crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check') 条"
fi

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
say "继承缓存 : /data/happ 大小 $(du -sh /data/happ 2>/dev/null | cut -f1)（缓存保护模式=$CACHE_PROTECT）"

say "⏱ 耗时   : 绑定+docker+预拉=$(dur $T0 $T_PAR)  Q2+9路=$(dur $T_PAR $T_NINE)  SN回填=$(dur $T_NINE $T_SN)  总计=$(dur $T0 $T_SN)"
[ -n "$FAIL" ] && say "❌ 失败步骤:${FAIL}" || say "✅ 全部完成"
say "============ 完成 $(date '+%F %T') ============"

#!/usr/bin/env bash
#
# IPES SN 换新 + 状态流转 一条龙
# ------------------------------------------------------------
# 运行位置：克隆机 / 镜像复制出来的边缘节点本机
#
# 要解决的问题：
#   克隆机复用源实例的 IPES SN（爱奇艺业务ID），导致
#     - 多台机器在爱奇艺侧是同一个业务ID
#     - admin.zhouyi.top 绑定冲突 / 状态流转串号
#
# 完整流程（严格按此顺序，缺一不可）：
#   1) 找 IPES 容器（按名字精确匹配；找不到就用 --token 现场装）
#   2) 记录【旧 SN】
#   3) 删旧 SN：容器内 bin/ipes_sn + 容器挂载卷 + 宿主机 IPES 数据目录
#   4) 停容器 → 启容器 → IPES 重新向爱奇艺注册，生成【新 SN】
#   5) 轮询等待新 SN（首次约 3 分钟，最多等 6 分钟）
#   6) 校验 SN 确实变了（没变 = 清理没生效，报错退出）
#   7) 读 /etc/.mac 拿舟翼云设备ID (nodeId)
#   8) 用【新 SN】作为 businessId 调状态流转接口（待配置 → 服务中）
#
# 用法：
#   # 完整一条龙（换 SN + 流转）
#   bash ipes_sn_renew.sh \
#     --token "<IPES JWT>" \
#     --status-api-url "https://admin.zhouyi.top/api/edgeNode/xxx" \
#     --appid "xxx" --appak "xxx" --appsk "xxx"
#
#   # 只换 SN，不调接口
#   bash ipes_sn_renew.sh --token "<JWT>" --no-transition
#
#   # 容器已存在，只想强制换新 SN（不传 token 也行）
#   bash ipes_sn_renew.sh --appid "xxx" --appak "xxx" --appsk "xxx" \
#     --status-api-url "https://admin.zhouyi.top/api/edgeNode/xxx"
# ------------------------------------------------------------
set -uo pipefail

# ===== 默认配置 =====
IPES_INSTALL_URL="${IPES_INSTALL_URL:-https://zyy-go.oss-cn-beijing.aliyuncs.com/script/Q2_test/ecache_auto_disk_install.sh}"
STATUS_API_URL="${STATUS_API_URL:-}"
APPID="${APPID:-}"
APPAK="${APPAK:-}"
APPSK="${APPSK:-}"
STATUS_BODY_TPL='{"nodeId":"{nodeId}","businessId":"{businessId}","status":"服务中"}'
TOKEN=""
DO_TRANSITION="1"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-360}"   # 等新 SN 最长时间，默认 6 分钟

# ===== 日志 =====
LOG_FILE="/var/log/ipes_sn_renew.log"
log() { local ts="$(date '+%F %T')"; echo "[$ts] $*"; echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null || true; }
warn() { log "⚠️ $*"; }
ok()   { log "✔ $*"; }
die()  { echo "" >&2; echo "❌ $*" >&2; log "❌ $*"; exit 1; }

# ===== 参数解析 =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)           TOKEN="$2"; shift 2;;
    --status-api-url)  STATUS_API_URL="$2"; shift 2;;
    --appid)           APPID="$2"; shift 2;;
    --appak)           APPAK="$2"; shift 2;;
    --appsk)           APPSK="$2"; shift 2;;
    --no-transition)   DO_TRANSITION="0"; shift;;
    --max-wait)        MAX_WAIT_SEC="$2"; shift 2;;
    -h|--help)         sed -n '3,40p' "$0"; exit 0;;
    *) echo "❌ 未知参数: $1"; exit 1;;
  esac
done

# ===== 公共函数：按名字精确匹配找 IPES 容器 =====
# 绝不把空串传给 docker restart/exec（旧版 bug：docker ps -aq --filter name=ipes | head -1）
find_ipes_cid() {
  local _cid=""
  while IFS='|' read -r cid name; do
    [ -z "$cid" ] && continue
    case "$name" in
      ipes|ipes-*|ipes_*) _cid="$cid"; break;;
    esac
  done < <(docker ps -a --format '{{.ID}}|{{.Names}}' 2>/dev/null)
  if [ -z "$_cid" ]; then
    while IFS='|' read -r cid name; do
      [ -z "$cid" ] && continue
      case "$name" in
        *ipes*|*IPES*|*ecache*) _cid="$cid"; break;;
      esac
    done < <(docker ps -a --format '{{.ID}}|{{.Names}}' 2>/dev/null)
  fi
  printf '%s' "$_cid"
}

IPES_CID=""

# ===== 步骤 1：定位 IPES 容器（没有就装） =====
log "===== 步骤 1/6：定位 IPES 容器 ====="
if ! command -v docker >/dev/null 2>&1; then
  die "docker 命令不可用，请先安装 Docker"
fi

IPES_CID="$(find_ipes_cid)"
if [ -z "$IPES_CID" ]; then
  [ -z "$TOKEN" ] && die "未发现 IPES 容器，且未提供 --token，无法安装 IPES。
   请先装 IPES：curl -fsSL $IPES_INSTALL_URL | bash -s -- -i 1 -t 2 token <JWT>
   或带 --token 重跑本脚本，由脚本自动安装。"
  log "未发现 IPES 容器，使用 --token 现场安装..."
  curl -fsSL "$IPES_INSTALL_URL" | bash -s -- -i 1 -t 2 token "$TOKEN" \
    || warn "IPES 安装命令返回非0，30 秒后校验容器是否真的起来了"
  sleep 30
  IPES_CID="$(find_ipes_cid)"
  [ -z "$IPES_CID" ] && die "IPES 安装后仍未发现容器，请检查 token 是否有效：tail -50 /var/log/ipes_deploy.log"
  ok "IPES 已安装，容器: $IPES_CID"
else
  ok "找到 IPES 容器: $IPES_CID ($(docker inspect --format '{{.Name}}' "$IPES_CID" 2>/dev/null | sed 's#^/##'))"
fi

# 读 SN（容器必须在）
get_ipes_sn() {
  [ -z "$IPES_CID" ] && return 1
  docker exec "$IPES_CID" cat bin/ipes_sn 2>/dev/null | tr -d '[:space:]'
}

# ===== 步骤 2：记录旧 SN =====
log "===== 步骤 2/6：记录旧 SN ====="
OLD_SN="$(get_ipes_sn)"
if [ -n "$OLD_SN" ]; then
  ok "旧 SN（即将删除）: $OLD_SN"
else
  warn "当前未获取到 SN（容器可能刚起或首次启动），继续清理"
fi

# ===== 步骤 3：删除旧 SN（容器内 + 挂载卷 + 数据目录） =====
log "===== 步骤 3/6：删除旧 SN ====="

# 3.1 容器内删（容器还在跑，exec 可用）
log "清理容器内身份文件..."
docker exec "$IPES_CID" sh -c 'rm -f bin/ipes_sn 2>/dev/null; rm -rf /var/lib/ipescache/* 2>/dev/null; exit 0' >/dev/null 2>&1 \
  && ok "  已清容器内 bin/ipes_sn" || warn "  容器内清理失败（可能因权限，后续靠挂载卷兜底）"

# 3.2 停容器
log "停止容器..."
docker stop "$IPES_CID" >/dev/null 2>&1 && ok "  容器已停止" || warn "  停止容器失败（可能已停止）"

# 3.3 清宿主机挂载卷（关键：SN 可能持久化在挂载卷里，只删容器内文件重启后会复活）
log "清理宿主机挂载卷..."
MOUNTS="$(docker inspect "$IPES_CID" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)"
if [ -n "$MOUNTS" ]; then
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    [ -d "$m" ] || continue
    case "$m" in
      /|/etc|/usr|/var/lib/docker|/bin|/sbin|/lib*) warn "  跳过危险挂载点: $m"; continue;;
    esac
    rm -rf "$m"/* 2>/dev/null && ok "  已清挂载卷: $m" || warn "  清挂载卷失败: $m"
  done <<< "$MOUNTS"
else
  warn "  未发现挂载卷"
fi

# 3.4 兜底：常见 IPES 数据目录
for d in /var/lib/ipescache /var/lib/ipes /opt/ipes/data; do
  if [ -d "$d" ]; then
    rm -rf "$d"/* 2>/dev/null && ok "  已清数据目录: $d" || warn "  清数据目录失败: $d"
  fi
done

# ===== 步骤 4：启动容器，触发 IPES 重新生成 SN =====
log "===== 步骤 4/6：重启容器 → 触发新 SN 生成 ====="
docker start "$IPES_CID" >/dev/null 2>&1 || die "启动容器失败: $IPES_CID"
ok "容器已启动: $IPES_CID"
log "IPES 将重新向爱奇艺注册并生成全新 SN（业务ID）"

# ===== 步骤 5：轮询等待新 SN，并校验确实变了 =====
log "===== 步骤 5/6：等待新 SN（最多 ${MAX_WAIT_SEC}s）====="
NEW_SN=""
elapsed=0
interval=10
while [ "$elapsed" -lt "$MAX_WAIT_SEC" ]; do
  sleep "$interval"
  elapsed=$((elapsed + interval))
  cur="$(get_ipes_sn)"
  if [ -n "$cur" ]; then
    if [ -n "$OLD_SN" ] && [ "$cur" = "$OLD_SN" ]; then
      log "  [${elapsed}s] SN 仍为旧值，继续等待重新生成..."
      continue
    fi
    NEW_SN="$cur"
    ok "  [${elapsed}s] 获得新 SN"
    break
  fi
  log "  [${elapsed}s] 等待 SN 生成中..."
done

if [ -z "$NEW_SN" ]; then
  die "等待 ${MAX_WAIT_SEC}s 后仍未拿到【新】SN。
   排查：
     1) docker ps -a 看容器是否 Up
     2) docker logs $IPES_CID | tail -50
     3) docker exec $IPES_CID cat bin/ipes_sn
   若 SN 与旧值相同，说明清理未生效：检查是否有其他持久化路径保存了 SN。"
fi

if [ -n "$OLD_SN" ]; then
  ok "SN 已换新: $OLD_SN  →  $NEW_SN"
  [ "$NEW_SN" = "$OLD_SN" ] && die "SN 未发生变化，清理未生效，终止（避免用旧 ID 流转）"
else
  ok "新 SN: $NEW_SN"
fi

# ===== 步骤 6：读设备ID + 调状态流转接口 =====
log "===== 步骤 6/6：状态流转（待配置 → 服务中）====="
node="$(cat /etc/.mac 2>/dev/null | tr -d '[:space:]')"
if [ -z "$node" ]; then
  warn "无法读取 /etc/.mac（未安装 ZyCloud Agent 或未生成设备ID）"
  warn "新 SN 已生成: $NEW_SN —— 请先装 Agent 生成设备ID，再手工在 admin.zhouyi.top 流转"
  exit 0
fi
ok "设备ID(nodeId): $node"
ok "业务ID(businessId，新 SN): $NEW_SN"

if [ "$DO_TRANSITION" != "1" ]; then
  log "已指定 --no-transition，跳过接口调用。"
  log "手工流转：设备ID=$node，业务ID=$NEW_SN，状态=服务中"
  exit 0
fi

if [ -z "$STATUS_API_URL" ] || [ -z "$APPID" ] || [ -z "$APPAK" ] || [ -z "$APPSK" ]; then
  warn "缺少 --status-api-url / --appid / --appak / --appsk，无法自动调接口。"
  log "手工流转：登录 admin.zhouyi.top → 状态流转 → 设备ID=$node，业务ID=$NEW_SN，流转状态=服务中"
  exit 0
fi

ts=$(date +%s)
sign=$(printf '%s' "${APPAK}:${ts}" | openssl dgst -sha256 -hmac "$APPSK" | awk '{print $NF}')
body=$(printf '%s' "$STATUS_BODY_TPL" | sed "s/{nodeId}/$node/g; s/{businessId}/$NEW_SN/g")

log "调用状态流转接口: $STATUS_API_URL"
log "请求体: $body"
resp=$(curl -k -s --location --max-time 60 --request POST "$STATUS_API_URL" \
  --header "appId: $APPID" \
  --header "timestamp: $ts" \
  --header "sign: $sign" \
  --header "Content-Type: application/json" \
  --data "$body")

if printf '%s' "$resp" | grep -q '"code":0'; then
  ok "✅ 状态流转成功（待配置 → 服务中）"
  log "响应: $resp"
  log "设备ID=$node  业务ID=$NEW_SN"
else
  warn "状态流转失败，响应: $resp"
  log "请手工核对：设备ID=$node，业务ID=$NEW_SN"
  exit 1
fi

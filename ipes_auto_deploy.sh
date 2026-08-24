#!/usr/bin/env bash
#
# IPES 边缘缓存 一键部署脚本（空白 CentOS 7.9 云主机）
# ------------------------------------------------------------
# 适用：一台全新的、仅装了 CentOS 7.9 的云主机（阿里云轻量/ESC 均可）
# 作用：自动装 Docker → 部署 IPES 边缘缓存 → 预热调优 + 健康检查
# 全程日志带时间戳，方便排查。
#
# 用法（Token 通过参数传入，不写死在脚本里，避免泄露）：
#   curl -fsSL https://angelbaby86966.github.io/scheduled-refund/ipes_auto_deploy.sh \
#     | bash -s -- "<你的 IPES TOKEN>"
#
# 或（环境变量方式）：
#   IPES_TOKEN="<TOKEN>" bash -c "$(curl -fsSL https://angelbaby86966.github.io/scheduled-refund/ipes_auto_deploy.sh)"
#
# 注意：Token 是 JWT，自带过期时间（exp），过期后需重新生成再跑。
# ------------------------------------------------------------
set -euo pipefail

# ===== 可配置项（公开，非机密） =====
DOCKER_INSTALL_URL="https://zyy-go.oss-cn-beijing.aliyuncs.com/script/install_docker/install_docker-ce.sh"
IPES_INSTALL_URL="https://zyy-go.oss-cn-beijing.aliyuncs.com/script/Q2_test/ecache_auto_disk_install.sh"
# 预热调优脚本（你自己的仓库，真实版本）
PREHEAT_URL="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/ipes-scripts/main/ipes_preheat_and_health.sh"

# ecache_auto_disk_install.sh 的部署参数（-i / -t），可按需改
IPES_INSTALL_FLAG_I="${IPES_INSTALL_FLAG_I:-1}"
IPES_INSTALL_FLAG_T="${IPES_INSTALL_FLAG_T:-2}"

# ===== Token：优先命令行参数，其次环境变量 =====
IPES_TOKEN="${1:-${IPES_TOKEN:-}}"
if [ -z "$IPES_TOKEN" ]; then
  echo "❌ 缺少 IPES Token。用法：bash ipes_auto_deploy.sh <TOKEN>" >&2
  echo "   或：IPES_TOKEN=<TOKEN> bash -c \"\$(curl -fsSL https://angelbaby86966.github.io/scheduled-refund/ipes_auto_deploy.sh)\"" >&2
  exit 1
fi

log() { echo "[$(date '+%F %T')] $*"; }

log "===== 步骤 1/3：安装 Docker ====="
curl -fsSL "$DOCKER_INSTALL_URL" | bash
log "✔ Docker 安装完成"

log "===== 步骤 2/3：部署 IPES 边缘缓存 ====="
curl -fsSL "$IPES_INSTALL_URL" | bash -s -- -i "$IPES_INSTALL_FLAG_I" -t "$IPES_INSTALL_FLAG_T" token "$IPES_TOKEN"
log "✔ IPES 部署命令已执行"

log "===== 步骤 3/3：预热调优 + 健康检查 ====="
if curl -fsSL "$PREHEAT_URL" -o /tmp/ipes_preheat.sh; then
  bash /tmp/ipes_preheat.sh || log "⚠️ 调优脚本返回非0，请手动检查节点状态"
else
  log "⚠️ 调优脚本下载失败，跳过（不影响主部署，可稍后手动执行预热）"
fi

log "✅ 全部完成。请在控制台确认节点已上线并注册到平台。"

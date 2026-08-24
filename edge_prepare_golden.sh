#!/usr/bin/env bash
#
# 半黄金镜像 · 预装脚本（在「源实例」上跑一次，然后打镜像）
# ------------------------------------------------------------
# 目的：把环境装好并固化进镜像，但【不装 Agent / 不注册 / 不绑定】。
#       这样克隆出的新机各自首次启动时才独立装 Agent（生成全新设备ID）+ 注册 + 绑定，
#       避免多台机器共用同一个 /etc/.mac（设备ID）导致注册/绑定冲突。
#
# 流程：
#   1) 安装 Docker
#   2) 部署 IPES 边缘缓存（JWT token）
#   3) 预热调优 + 健康检查
#   4) 把 IPES 容器设为开机自启（restart=always）
#   5) 下载"首次启动脚本"到 /opt/edge_firstboot.sh
#   6) 把注册/绑定凭据写入 /etc/edge_firstboot.conf（私有镜像内，安全）
#   7) 安装 systemd 首次启动服务（开机自动跑注册/绑定）
#   —— 完成，提示去打镜像（CreateCustomImage）
#
# 参数（与 ipes_auto_deploy.sh 兼容）：
#   --token <JWT>             IPES 部署 token（必需，仅打镜像前用，过期无关紧要）
#   --ak/--sk/--isp/--num-dirs    注册设备凭据（写入 conf，供新机首次启动用）
#   --appid/--appak/--appsk       绑定业务凭据（写入 conf，供新机首次启动用）
#
# 用法：
#   curl -fsSL https://angelbaby86966.github.io/scheduled-refund/edge_prepare_golden.sh | bash -s -- \
#     --token "<JWT>" \
#     --ak "<appKey>" --sk "<secretKey>" --isp 电信 --num-dirs 10 \
#     --appid "<appid>" --appak "<ak>" --appsk "<sk>"
# ------------------------------------------------------------
set -uo pipefail

LOG_FILE="/var/log/edge_prepare.log"
log() { local ts="$(date '+%F %T')"; echo "[$ts] $*"; echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null || true; }
warn() { log "⚠️ $*"; }
ok()   { log "✔ $*"; }

# ===== 公开可配置项 =====
DOCKER_INSTALL_URL="https://zyy-go.oss-cn-beijing.aliyuncs.com/script/install_docker/install_docker-ce.sh"
IPES_INSTALL_URL="https://zyy-go.oss-cn-beijing.aliyuncs.com/script/Q2_test/ecache_auto_disk_install.sh"
PREHEAT_URL="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/ipes-scripts/main/ipes_preheat_and_health.sh"
FIRSTBOOT_URL="https://angelbaby86966.github.io/scheduled-refund/edge_firstboot_register.sh"
IPES_INSTALL_FLAG_I="${IPES_INSTALL_FLAG_I:-1}"
IPES_INSTALL_FLAG_T="${IPES_INSTALL_FLAG_T:-2}"

# ===== 参数解析 =====
TOKEN=""; APP_KEY=""; SECRET_KEY=""; ISP=""; NUM_DIRS="12"
APPID=""; APPAK=""; APPSK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)    TOKEN="$2"; shift 2;;
    --ak)       APP_KEY="$2"; shift 2;;
    --sk)       SECRET_KEY="$2"; shift 2;;
    --isp)      ISP="$2"; shift 2;;
    --num-dirs) NUM_DIRS="$2"; shift 2;;
    --appid)    APPID="$2"; shift 2;;
    --appak)    APPAK="$2"; shift 2;;
    --appsk)    APPSK="$2"; shift 2;;
    -h|--help)
      echo "用法: bash edge_prepare_golden.sh --token <JWT> [--ak/--sk/--isp/--num-dirs/--appid/--appak/--appsk]"
      exit 0;;
    *) echo "❌ 未知参数: $1"; exit 1;;
  esac
done

if [ -z "$TOKEN" ]; then
  echo "❌ 缺少 --token（IPES 部署必需）。" >&2
  exit 1
fi

log "===== 半黄金镜像预装开始 ====="

# ============ 步骤 1：安装 Docker ============
log "===== 步骤 1/7：安装 Docker ====="
curl -fsSL "$DOCKER_INSTALL_URL" | bash || warn "Docker 安装返回非0，后续步骤可能异常"

# ============ 步骤 2：部署 IPES 边缘缓存 ============
log "===== 步骤 2/7：部署 IPES 边缘缓存 ====="
curl -fsSL "$IPES_INSTALL_URL" | bash -s -- -i "$IPES_INSTALL_FLAG_I" -t "$IPES_INSTALL_FLAG_T" token "$TOKEN" \
  || warn "IPES 部署命令返回非0，请检查节点状态"

# ============ 步骤 3：预热调优 + 健康检查 ============
log "===== 步骤 3/7：预热调优 + 健康检查 ====="
if curl -fsSL "$PREHEAT_URL" -o /tmp/ipes_preheat.sh; then
  bash /tmp/ipes_preheat.sh || warn "调优脚本返回非0，可稍后手动执行预热"
else
  warn "调优脚本下载失败，跳过"
fi

# ============ 步骤 4：IPES 容器开机自启 ============
log "===== 步骤 4/7：设置 IPES 容器开机自启 ====="
if command -v docker >/dev/null 2>&1; then
  cids=$(docker ps -aq 2>/dev/null)
  if [ -n "$cids" ]; then
    for cid in $cids; do
      docker update --restart=always "$cid" >/dev/null 2>&1 && ok "容器 $cid 设为开机自启" || warn "容器 $cid 设置自启失败"
    done
  else
    warn "未发现任何容器，跳过自启设置（IPES 可能未正常启动）"
  fi
else
  warn "docker 命令不可用，跳过自启设置"
fi

# ============ 步骤 5：下载首次启动脚本 ============
log "===== 步骤 5/7：下载首次启动脚本 ====="
curl -fsSL "$FIRSTBOOT_URL" -o /opt/edge_firstboot.sh || { echo "❌ 首次启动脚本下载失败"; exit 1; }
chmod +x /opt/edge_firstboot.sh
ok "首次启动脚本已就位: /opt/edge_firstboot.sh"

# ============ 步骤 6：写入凭据到私有 conf ============
log "===== 步骤 6/7：写入注册/绑定凭据 ====="
cat > /etc/edge_firstboot.conf <<EOF
# 半黄金镜像 · 首次启动凭据（私有镜像内，非公开）
APP_KEY='${APP_KEY}'
SECRET_KEY='${SECRET_KEY}'
ISP='${ISP}'
NUM_DIRS='${NUM_DIRS}'
APPID='${APPID}'
APPAK='${APPAK}'
APPSK='${APPSK}'
EOF
chmod 600 /etc/edge_firstboot.conf
ok "凭据已写入 /etc/edge_firstboot.conf (chmod 600)"

# ============ 步骤 7：安装 systemd 首次启动服务 ============
log "===== 步骤 7/7：安装 systemd 首次启动服务 ====="
cat > /etc/systemd/system/edge-firstboot.service <<'UNIT'
[Unit]
Description=Edge Node First Boot Registration
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/edge_firstboot.sh
RemainAfterExit=yes
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload 2>/dev/null || true
systemctl enable edge-firstboot.service 2>/dev/null && ok "已启用 edge-firstboot 服务（新机首次启动自动注册/绑定）" \
  || warn "systemctl enable 失败（非 systemd 环境？），可改用 rc.local 触发"

log "✅ 半黄金镜像预装完成！"
log "下一步：在阿里云控制台用本实例创建自定义镜像（CreateCustomImage）。"
log "克隆出的新机首次启动会自动：装 Agent → 注册设备 → 绑定业务ID（每台独立设备ID）。"

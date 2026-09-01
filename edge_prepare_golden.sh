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
PARAM_CLEANUP="1"
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
    --no-cleanup) PARAM_CLEANUP="0"; shift;;
    -h|--help)
      echo "用法: bash edge_prepare_golden.sh --token <JWT> [--ak/--sk/--isp/--num-dirs/--appid/--appak/--appsk] [--no-cleanup]"
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

log "===== 半黄金镜像预装完成 ====="

# ============ 步骤 8：黄金镜像去个性化（必跑，否则克隆机复用源实例 ID） ============
if [ "$PARAM_CLEANUP" = "1" ]; then
  log "===== 步骤 8/8：黄金镜像去个性化 ====="
  log "⚠️  本步骤会清掉本机 /etc/.mac、SSH host key、machine-id、IPES 数据目录。"
  log "   跑完本机身份失效，请确认：1) 已在 admin.zhouyi.top 完成绑定业务 ID；2) 立刻去阿里云控制台 CreateCustomImage 打镜像。"

  # 舟翼云设备 ID
  if [ -f /etc/.mac ]; then
    rm -f /etc/.mac && ok "已清 /etc/.mac"
  else
    ok "/etc/.mac 不存在，跳过"
  fi

  # 边缘节点首启标记（防止镜像里这个文件已存在，导致新机跳过首启注册）
  rm -f /etc/edge_firstboot_done 2>/dev/null && ok "已清 /etc/edge_firstboot_done" || true

  # SSH host key
  if ls /etc/ssh/ssh_host_* >/dev/null 2>&1; then
    rm -f /etc/ssh/ssh_host_*
    ssh-keygen -A >/dev/null 2>&1 && ok "已重生成 SSH host key" || warn "SSH host key 重生失败"
  fi

  # machine-id
  if [ -f /etc/machine-id ]; then
    rm -f /etc/machine-id && systemd-machine-id-setup >/dev/null 2>&1 && ok "已重置 machine-id" || warn "machine-id 重置失败"
  fi

  # IPES 容器数据目录（让克隆机首启后容器启动时重新生成 SN）
  if command -v docker >/dev/null 2>&1; then
    for ipes_data in /var/lib/ipescache /var/lib/ipes /opt/ipes/data; do
      if [ -d "$ipes_data" ]; then
        rm -rf "$ipes_data"/* 2>/dev/null && ok "已清 IPES 数据目录: $ipes_data" || warn "清 IPES 数据目录失败: $ipes_data"
      fi
    done
    # 重启 IPES 容器以彻底刷新状态（如果用户改主意没去打镜像，本机还能继续用）
    ipes_cid=$(docker ps -aq --filter "name=ipes" 2>/dev/null | head -1)
    if [ -n "$ipes_cid" ]; then
      docker restart "$ipes_cid" >/dev/null 2>&1 && ok "已重启 IPES 容器: $ipes_cid" || warn "重启 IPES 容器失败"
    fi
  fi

  # 清理 IPES 日志
  rm -rf /var/log/ipescache/*.log 2>/dev/null || true
  : > /etc/hostname 2>/dev/null || true

  # 清理边缘节点凭据缓存
  rm -f /usr/local/edge/registration_info 2>/dev/null || true

  ok "✅ 黄金镜像去个性化完成！"
  log "👉 下一步：在阿里云控制台用本实例 CreateCustomImage 打镜像，然后立刻关掉/释放本机。"
  log "   克隆出的新机首次启动会自动：清身份 → 装 Agent → 拿新设备ID → 注册 → 绑定 → 读新 SN → 流转服务中。"
else
  log "===== 步骤 8/8：黄金镜像去个性化（已用 --no-cleanup 跳过）====="
  warn "⚠️  你选择了不去个性化。克隆机首启时会复用本机的 /etc/.mac 和 IPES SN，"
  warn "    必须确保 edge_firstboot_register.sh 的步骤 0（强制重置身份）存在，否则多台机器会冲突。"
fi

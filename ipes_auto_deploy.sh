#!/bin/bash
# =============================================================================
# IPES PCDN 边缘缓存节点 —— 一键部署脚本（CentOS 7.x / 空白机器）
# -----------------------------------------------------------------------------
# 用途：在空白 CentOS 7.9 云主机上自动完成：
#       1) 安装 Docker
#       2) 下载并部署 IPES 缓存节点（需你提供安装链接 + Token）
#       3) 执行系统级预热调优 + 健康检查
# 用法：
#   curl -fsSL https://angelbaby86966.github.io/scheduled-refund/ipes_auto_deploy.sh | bash
#   # 或经 ghproxy 代理：
#   curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/gh-pages/ipes_auto_deploy.sh | bash
# 注意：
#   - 必须 root 执行
#   - 请先修改下方【配置区】的 IPES_INSTALL_URL 和 IPES_TOKEN
#   - 如果 IPES 官方提供的是 docker run 命令而非安装脚本，请把【3/4 部署 IPES】
#     那段改成你的 docker run 命令，并删掉 install.sh 相关逻辑
# =============================================================================
set -uo pipefail
export LC_ALL=C
shopt -s nullglob 2>/dev/null || true

# ===================== 配置区（使用前必须修改） =====================
# IPES 安装包/安装脚本下载链接。示例：
#   IPES_INSTALL_URL="https://your-domain.com/ipes/install.sh"
#   IPES_INSTALL_URL="https://ghproxy.net/https://raw.githubusercontent.com/xxx/ipes-install/main/install.sh"
IPES_INSTALL_URL="【请填写 IPES 安装脚本下载链接】"

# IPES 激活/注册令牌（Token/SN/激活码），具体名称以你的 IPES 版本为准
IPES_TOKEN="【请填写 IPES 激活/注册 Token】"

# IPES 数据目录（缓存盘，建议挂载独立数据盘到 /data）
IPES_DATA_DIR="/data/ipes"

# IPES 容器名（按实际调整，常见为 ipes / ipes-agent / pcdn）
IPES_CONTAINER_NAME="ipes"
# =================================================================

LOG_DIR="/var/log"
LOG="$LOG_DIR/ipes_auto_deploy_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
exec > >(tee -a "$LOG") 2>&1

log(){ echo -e "\033[0;32m[$(date +%T)] INFO\033[0m $*"; }
warn(){ echo -e "\033[0;33m[$(date +%T)] WARN\033[0m $*"; }
err(){ echo -e "\033[0;31m[$(date +%T)] ERROR\033[0m $*"; exit 1; }

[[ $EUID -eq 0 ]] || err "请使用 root 执行（云助手默认 root）"
command -v curl >/dev/null 2>&1 || timeout 60 yum -y -q --setopt=timeout=10 --setopt=retries=2 install curl >/dev/null 2>&1 || err "curl 不可用"

# ===================== 1/4 基础环境与 Docker =====================
install_docker(){
  log "===== 1/4 安装基础工具与 Docker ====="
  timeout 120 yum -y -q --setopt=timeout=10 --setopt=retries=2 install \
    curl wget yum-utils device-mapper-persistent-data lvm2 >/dev/null 2>&1 || true

  if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
    log "Docker 已存在且可用，跳过安装"
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    return 0
  fi

  # 优先用阿里云镜像仓库加速 Docker 安装
  if ! [ -f /etc/yum.repos.d/docker-ce.repo ]; then
    yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo >/dev/null 2>&1 || \
      curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo >/dev/null 2>&1 || true
  fi

  # 若仓库添加失败，fallback 到官方 get.docker.com
  if ! [ -f /etc/yum.repos.d/docker-ce.repo ]; then
    warn "阿里云 Docker 仓库不可用，尝试官方一键安装..."
    curl -fsSL https://get.docker.com | bash || err "Docker 安装失败"
  else
    timeout 300 yum -y -q --setopt=timeout=10 --setopt=retries=2 install docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || \
      err "yum 安装 Docker 失败"
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || err "Docker 启动失败"
  docker version >/dev/null 2>&1 || err "Docker 安装后不可用"
  log "Docker 安装/启动完成"
}

# ===================== 2/4 数据盘准备（可选） =====================
prepare_data_disk(){
  log "===== 2/4 准备数据盘（如已挂载 /data 则跳过） ====="
  if mountpoint -q /data 2>/dev/null || df -h /data >/dev/null 2>&1; then
    log "/data 已可用，无需处理"
  else
    warn "/data 未单独挂载，IPES 缓存将使用根盘。如需缓存盘，请先挂载数据盘到 /data"
  fi
  mkdir -p "$IPES_DATA_DIR" /opt/ipes 2>/dev/null || true
}

# ===================== 3/4 部署 IPES（需按你的安装方式修改） =====================
deploy_ipes(){
  log "===== 3/4 部署 IPES 缓存节点 ====="
  if [[ "$IPES_INSTALL_URL" == *"【请填写"* ]] || [ -z "$IPES_INSTALL_URL" ]; then
    err "IPES_INSTALL_URL 未配置。请先编辑本脚本，填写 IPES 安装脚本下载链接后再执行"
  fi
  if [[ "$IPES_TOKEN" == *"【请填写"* ]] || [ -z "$IPES_TOKEN" ]; then
    err "IPES_TOKEN 未配置。请先编辑本脚本，填写 IPES 激活/注册 Token 后再执行"
  fi

  cd /opt/ipes || err "无法进入 /opt/ipes"

  # 方案 A：IPES 提供的是 bash 安装脚本（最常见）
  # 如果你的 IPES 是 docker run / docker-compose / 二进制包，请改用方案 B/C
  log "下载 IPES 安装脚本: $IPES_INSTALL_URL"
  curl -fsSL "$IPES_INSTALL_URL" -o /opt/ipes/install.sh || err "下载 IPES 安装脚本失败"
  chmod +x /opt/ipes/install.sh

  # 执行安装脚本（参数名需按你的官方安装脚本调整，常见为 --token / -t / --sn）
  # 如果你的脚本不需要 token 参数而是读取环境变量，请自行调整
  log "执行 IPES 安装脚本（Token 已隐藏）..."
  bash /opt/ipes/install.sh --token "$IPES_TOKEN" --data-dir "$IPES_DATA_DIR" --container-name "$IPES_CONTAINER_NAME" || \
    err "IPES 安装脚本执行失败"

  # 兜底检查：确保容器在跑
  if docker ps --format '{{.Names}}' | grep -qx "$IPES_CONTAINER_NAME"; then
    log "IPES 容器 $IPES_CONTAINER_NAME 已运行"
  else
    warn "IPES 安装脚本执行后容器未运行，尝试 docker start..."
    docker start "$IPES_CONTAINER_NAME" >/dev/null 2>&1 || warn "docker start $IPES_CONTAINER_NAME 失败，请检查日志"
  fi
}

# ===================== 4/4 调优 + 健康检查 =====================
tune_and_health(){
  log "===== 4/4 系统调优 + 健康检查 ====="
  # 优先从本站点拉（可能更快），失败则 fallback 到 ipes-scripts 主仓库
  local urls=(
    "https://angelbaby86966.github.io/scheduled-refund/ipes_preheat_and_health.sh"
    "https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/ipes-scripts/main/ipes_preheat_and_health.sh"
  )
  local downloaded=0
  for url in "${urls[@]}"; do
    if curl -fsSL "$url" -o /tmp/ipes_preheat_and_health.sh 2>/dev/null; then
      log "已下载预热调优脚本: $url"
      downloaded=1
      break
    else
      warn "下载失败: $url，尝试下一个源..."
    fi
  done
  if [ "$downloaded" -eq 0 ]; then
    err "所有源均无法下载 ipes_preheat_and_health.sh，请检查网络"
  fi

  bash /tmp/ipes_preheat_and_health.sh || warn "预热调优脚本部分步骤失败（通常不影响 IPES 运行，可后续单独重跑）"
}

main(){
  log "########## IPES PCDN 一键部署开始 ##########"
  log "数据目录: $IPES_DATA_DIR"
  log "容器名: $IPES_CONTAINER_NAME"
  install_docker
  prepare_data_disk
  deploy_ipes
  tune_and_health
  log "########## 部署完成 ##########"
  log "详细日志: $LOG"
  log "健康检查日志: /var/log/ipes_health.log"
  log "调优日志: /var/log/batch_preheat_*.log"
  if docker ps --format '{{.Names}}' | grep -qx "$IPES_CONTAINER_NAME"; then
    log "当前运行容器: $(docker inspect -f '{{.Config.Image}}' "$IPES_CONTAINER_NAME" 2>/dev/null)"
  else
    warn "部署完成但 $IPES_CONTAINER_NAME 容器未在运行，请检查 /var/log 日志"
  fi
  echo "IPES_DEPLOY_RESULT=OK LOG=$LOG"
}
main "$@"

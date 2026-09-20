#!/bin/bash

# 增强版 Docker CE 安装脚本
# 支持 CentOS 7/8 和 Debian (buster/bullseye/bookworm)
# 镜像加速器: https://stxam7vz.mirror.aliyuncs.com
# 安装最新版本 Docker CE
# 特性: 优先使用阿里源，失败时自动切换到腾讯源
# 版本阈值: Docker < 23.0.0 时重新安装
# 源配置: CentOS 7 清空 /etc/yum.repos.d/ 下所有 .repo 文件（保留目录）

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# 验证源是否真正可用（只认为 403 为不可用，其他状态码视为可用）
verify_repo_available() {
    local repo_url=$1
    local test_path=$2
    local full_url="$repo_url/$test_path"
    
    log_debug "验证源可用性: $full_url"
    
    # 使用 curl 获取 HTTP 状态码
    local http_code=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" "$full_url" 2>/dev/null)
    
    # 只有返回 403 才认为不可用，其他状态码（包括 200, 404, 500 等）都视为可用
    if [[ "$http_code" == "403" ]]; then
        log_debug "源不可用 (HTTP $http_code - Forbidden)"
        return 1
    else
        log_debug "源可用 (HTTP $http_code - 非403状态码)"
        return 0
    fi
}

# 检测操作系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    elif [ -f /etc/centos-release ]; then
        OS="centos"
        VER=$(grep -oE '[0-9]+' /etc/centos-release | head -1)
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        VER=$(cat /etc/debian_version)
    else
        OS="unknown"
    fi
    echo "$OS"
}

# 获取系统版本
get_system_version() {
    if [ "$OS" = "centos" ]; then
        if [ -f /etc/centos-release ]; then
            local version=$(grep -oE '[0-9]+\.[0-9]+' /etc/centos-release | head -1 | cut -d. -f1)
            echo "$version"
        else
            echo "7"
        fi
    elif [ "$OS" = "debian" ]; then
        # 获取 Debian 版本代号
        if command -v lsb_release &> /dev/null; then
            lsb_release -cs
        elif [ -f /etc/debian_version ]; then
            local deb_version=$(cat /etc/debian_version)
            if [[ $deb_version == "11"* ]]; then
                echo "bullseye"
            elif [[ $deb_version == "12"* ]]; then
                echo "bookworm"
            elif [[ $deb_version == "10"* ]]; then
                echo "buster"
            else
                echo "unknown"
            fi
        else
            echo "unknown"
        fi
    fi
}

# 版本比较函数
version_compare() {
    if [[ $1 == $2 ]]; then
        echo 0
    else
        local IFS=.
        local i ver1=($1) ver2=($2)
        for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
            ver1[i]=0
        done
        for ((i=0; i<${#ver1[@]}; i++)); do
            if [[ -z ${ver2[i]} ]]; then
                ver2[i]=0
            fi
            if ((10#${ver1[i]} > 10#${ver2[i]})); then
                echo 1
                return
            fi
            if ((10#${ver1[i]} < 10#${ver2[i]})); then
                echo -1
                return
            fi
        done
        echo 0
    fi
}

# ==================== CentOS 相关函数 ====================

# 清空 CentOS 7 的 yum 源文件（只删除 .repo 文件，保留目录）
clean_centos7_repos() {
    log_info "清空 /etc/yum.repos.d/ 目录下的所有 yum 源文件（保留目录）..."
    
    # 只删除 .repo 文件，不删除目录
    find /etc/yum.repos.d/ -type f -name "*.repo" -delete 2>/dev/null
    
    log_info "✅ 已清空所有 .repo 文件，目录结构保留"
}

# CentOS 8 特殊预处理
prepare_centos8() {
    log_info "CentOS 8 环境预处理..."
    
    dnf module enable -y container-tools 2>/dev/null || true
    dnf module reset -y container-tools 2>/dev/null || true
    timeout 300 dnf install -y container-selinux --disableexcludes=all 2>/dev/null || true
    sed -i 's/module_hotfixes=0/module_hotfixes=1/g' /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    
    log_info "✅ CentOS 8 预处理完成"
}

# 配置 CentOS 基础源（优先阿里，失败切腾讯，CentOS 7 清空原源文件）
configure_centos_base_repo() {
    local centos_version=$1
    log_info "配置 CentOS $centos_version 基础 YUM 源..."
    
    # CentOS 7 清空所有原有 .repo 文件
    if [[ $centos_version -eq 7 ]]; then
        clean_centos7_repos
    fi
    
    ALI_BASE_URL="http://mirrors.aliyun.com/centos"
    TENCENT_BASE_URL="http://mirrors.cloud.tencent.com/centos"
    
    # 测试路径
    ALI_TEST_PATH="$centos_version/os/x86_64/repodata/repomd.xml"
    TENCENT_TEST_PATH="$centos_version/os/x86_64/repodata/repomd.xml"
    
    BASE_URL=""
    PRIMARY_REPO=""
    
    # 优先尝试阿里源（只有 403 才认为不可用）
    log_info "正在测试阿里云镜像源可用性..."
    if verify_repo_available "$ALI_BASE_URL" "$ALI_TEST_PATH"; then
        BASE_URL=$ALI_BASE_URL
        PRIMARY_REPO="aliyun"
        log_info "✅ 阿里云镜像源可用，使用阿里云源"
    else
        log_warn "⚠️ 阿里云镜像源返回 403 Forbidden，切换到腾讯云源..."
        log_info "正在切换到腾讯云镜像源..."
        
        if verify_repo_available "$TENCENT_BASE_URL" "$TENCENT_TEST_PATH"; then
            BASE_URL=$TENCENT_BASE_URL
            PRIMARY_REPO="tencent"
            log_info "✅ 腾讯云镜像源可用，使用腾讯云源"
        else
            # 如果腾讯云也返回 403，则使用阿里源（因为其他非403错误仍然可用）
            log_warn "⚠️ 腾讯云镜像源也返回 403，将使用阿里云源"
            BASE_URL=$ALI_BASE_URL
            PRIMARY_REPO="aliyun"
        fi
    fi
    
    # 直接替换源文件
    if [[ $centos_version -eq 8 ]]; then
        cat > /etc/yum.repos.d/CentOS-Base.repo << EOF
[base]
name=CentOS-\$releasever - Base - $PRIMARY_REPO
baseurl=$BASE_URL/\$releasever/BaseOS/\$basearch/os/
gpgcheck=1
gpgkey=$BASE_URL/\$releasever/BaseOS/\$basearch/os/RPM-GPG-KEY-CentOS-8
enabled=1
module_hotfixes=1

[appstream]
name=CentOS-\$releasever - AppStream - $PRIMARY_REPO
baseurl=$BASE_URL/\$releasever/AppStream/\$basearch/os/
gpgcheck=1
gpgkey=$BASE_URL/\$releasever/BaseOS/\$basearch/os/RPM-GPG-KEY-CentOS-8
enabled=1
module_hotfixes=1
EOF
    else
        cat > /etc/yum.repos.d/CentOS-Base.repo << EOF
[base]
name=CentOS-\$releasever - Base - $PRIMARY_REPO
baseurl=$BASE_URL/\$releasever/os/\$basearch/
gpgcheck=1
gpgkey=$BASE_URL/\$releasever/os/\$basearch/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-\$releasever - Updates - $PRIMARY_REPO
baseurl=$BASE_URL/\$releasever/updates/\$basearch/
gpgcheck=1
gpgkey=$BASE_URL/\$releasever/os/\$basearch/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-\$releasever - Extras - $PRIMARY_REPO
baseurl=$BASE_URL/\$releasever/extras/\$basearch/
gpgcheck=1
gpgkey=$BASE_URL/\$releasever/os/\$basearch/RPM-GPG-KEY-CentOS-7
enabled=1
EOF
    fi
    
    log_info "✅ CentOS 基础源配置完成（使用 $PRIMARY_REPO 源）"
}

# 配置 CentOS Docker 源（优先阿里，失败切腾讯）
configure_centos_docker_repo() {
    local centos_version=$1
    log_info "配置 Docker CE YUM 源..."
    
    DOCKER_ALI_URL="https://mirrors.aliyun.com/docker-ce/linux/centos"
    DOCKER_TENCENT_URL="https://mirrors.cloud.tencent.com/docker-ce/linux/centos"
    
    # 测试路径
    DOCKER_TEST_PATH="$centos_version/x86_64/stable/repodata/repomd.xml"
    
    DOCKER_REPO_URL=""
    DOCKER_REPO_NAME=""
    
    # 优先尝试阿里 Docker 源（只有 403 才认为不可用）
    log_info "正在测试阿里云 Docker 源可用性..."
    if verify_repo_available "$DOCKER_ALI_URL" "$DOCKER_TEST_PATH"; then
        DOCKER_REPO_URL=$DOCKER_ALI_URL
        DOCKER_REPO_NAME="aliyun"
        log_info "✅ 阿里云 Docker 源可用，使用阿里云源"
    else
        log_warn "⚠️ 阿里云 Docker 源返回 403 Forbidden"
        log_info "正在切换到腾讯云 Docker 源..."
        
        if verify_repo_available "$DOCKER_TENCENT_URL" "$DOCKER_TEST_PATH"; then
            DOCKER_REPO_URL=$DOCKER_TENCENT_URL
            DOCKER_REPO_NAME="tencent"
            log_info "✅ 腾讯云 Docker 源可用，使用腾讯云源"
        else
            # 如果腾讯云也返回 403，则使用阿里源
            log_warn "⚠️ 腾讯云 Docker 源也返回 403，将使用阿里云源"
            DOCKER_REPO_URL=$DOCKER_ALI_URL
            DOCKER_REPO_NAME="aliyun"
        fi
    fi
    
    # 直接替换 Docker 源文件
    cat > /etc/yum.repos.d/docker-ce.repo << EOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch - $DOCKER_REPO_NAME
baseurl=$DOCKER_REPO_URL/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=$DOCKER_REPO_URL/gpg
module_hotfixes=1
EOF
    
    log_info "✅ Docker CE 源配置完成（使用 $DOCKER_REPO_NAME 源）"
}

# 安装 Docker on CentOS
# 【r20-fix18】yum/dnf 全局加固：避免 aliyun/tencent 镜像 CLOSE-WAIT 挂死时无超时永久卡住
harden_yum_conf() {
    local f=/etc/yum.conf
    [ -f "$f" ] || return 0
    grep -qE '^timeout=' "$f" || echo 'timeout=30' >> "$f"
    grep -qE '^retries=' "$f" || echo 'retries=3' >> "$f"
    grep -qE '^metadata_expire=' "$f" || echo 'metadata_expire=300' >> "$f"
}

# 带超时+可见输出的 docker 包安装（CentOS 7 用 yum，8 用 dnf）
docker_pkg_install() {
    log_info "安装 Docker CE（timeout 600 + timeout/retries=3，输出可见）..."
    if [[ $1 -eq 8 ]]; then
        timeout 600 dnf install -y --setopt=timeout=30 --setopt=retries=3 \
            docker-ce docker-ce-cli containerd.io docker-compose-plugin --nobest --allowerasing 2>&1 | tail -n 20
    else
        timeout 600 yum install -y --setopt=timeout=30 --setopt=retries=3 \
            docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>&1 | tail -n 20
    fi
}

install_docker_centos() {
    local centos_version=$1
    
    if [[ $centos_version -eq 8 ]]; then
        prepare_centos8
    fi
    
    configure_centos_base_repo $centos_version || return 1
    configure_centos_docker_repo $centos_version || return 1
    
    # 【r20-fix18】yum/dnf 全局加超时/重试，避免镜像偶发 CLOSE-WAIT 挂死永久卡住
    harden_yum_conf
    
    log_info "安装依赖包..."
    if [[ $centos_version -eq 8 ]]; then
        timeout 300 dnf install -y --setopt=timeout=30 --setopt=retries=3 \
            yum-utils device-mapper-persistent-data lvm2 curl iproute-tc 2>&1 | tail -n 15
    else
        timeout 300 yum install -y --setopt=timeout=30 --setopt=retries=3 \
            yum-utils device-mapper-persistent-data lvm2 curl 2>&1 | tail -n 15
    fi
    
    log_info "安装 Docker CE..."
    local try
    for try in 1 2 3; do
        docker_pkg_install $centos_version && return 0
        log_warn "Docker CE 安装第 ${try}/3 次失败，10s 后重试"
        sleep 10
    done
    log_error "Docker CE 安装 3 次均失败"
    return 1
}

# ==================== Debian 相关函数 ====================

# 配置 Debian APT 源（阿里云，不备份）
configure_debian_apt_repo() {
    local deb_version=$1
    log_info "配置 Debian $deb_version APT 源（阿里云镜像）..."
    
    # 直接替换源文件，不备份
    case $deb_version in
        bookworm)
            tee /etc/apt/sources.list <<EOF
deb https://mirrors.aliyun.com/debian/ bookworm main non-free non-free-firmware contrib
deb-src https://mirrors.aliyun.com/debian/ bookworm main non-free non-free-firmware contrib
deb https://mirrors.aliyun.com/debian-security/ bookworm-security main
deb-src https://mirrors.aliyun.com/debian-security/ bookworm-security main
deb https://mirrors.aliyun.com/debian/ bookworm-updates main non-free non-free-firmware contrib
deb-src https://mirrors.aliyun.com/debian/ bookworm-updates main non-free non-free-firmware contrib
deb https://mirrors.aliyun.com/debian/ bookworm-backports main non-free non-free-firmware contrib
deb-src https://mirrors.aliyun.com/debian/ bookworm-backports main non-free non-free-firmware contrib
EOF
            ;;
        bullseye)
            tee /etc/apt/sources.list <<EOF
deb https://mirrors.aliyun.com/debian/ bullseye main non-free contrib
deb-src https://mirrors.aliyun.com/debian/ bullseye main non-free contrib
deb https://mirrors.aliyun.com/debian-security/ bullseye-security main
deb-src https://mirrors.aliyun.com/debian-security/ bullseye-security main
deb https://mirrors.aliyun.com/debian/ bullseye-updates main non-free contrib
deb-src https://mirrors.aliyun.com/debian/ bullseye-updates main non-free contrib
deb https://mirrors.aliyun.com/debian/ bullseye-backports main non-free contrib
deb-src https://mirrors.aliyun.com/debian/ bullseye-backports main non-free contrib
EOF
            ;;
        buster)
            tee /etc/apt/sources.list <<EOF
deb https://mirrors.aliyun.com/debian/ buster main non-free contrib
deb-src https://mirrors.aliyun.com/debian/ buster main non-free contrib
deb https://mirrors.aliyun.com/debian-security/ buster/updates main
deb-src https://mirrors.aliyun.com/debian-security/ buster/updates main
deb https://mirrors.aliyun.com/debian/ buster-updates main non-free contrib
deb-src https://mirrors.aliyun.com/debian/ buster-updates main non-free contrib
deb https://mirrors.aliyun.com/debian/ buster-backports main non-free contrib
deb-src https://mirrors.aliyun.com/debian/ buster-backports main non-free contrib
EOF
            ;;
        *)
            log_error "不支持的 Debian 版本: $deb_version"
            return 1
            ;;
    esac
    
    log_info "更新 APT 源..."
    apt-get update
    
    log_info "✅ Debian APT 源配置完成"
}

# 安装 Docker on Debian
install_docker_debian() {
    local deb_version=$1
    
    # 配置 APT 源
    configure_debian_apt_repo $deb_version
    
    # 安装依赖
    log_info "安装依赖包..."
    timeout 600 apt-get install -y apt-transport-https ca-certificates curl software-properties-common iproute2 2>&1 | tail -n 15
    
    # 添加 Docker GPG 密钥
    log_info "添加 Docker GPG 密钥..."
    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # 添加 Docker APT 源
    log_info "添加 Docker APT 源..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # 更新源
    apt-get update
    
    # 安装 Docker
    log_info "安装 Docker CE..."
    timeout 600 apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>&1 | tail -n 20
}

# ==================== 通用函数 ====================

# 配置 Docker 镜像加速器
configure_docker_mirror() {
    log_info "配置镜像加速器..."
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": ["https://stxam7vz.mirror.aliyuncs.com"]
}
EOF
}

# 启动 Docker 服务
start_docker_service() {
    log_info "启动 Docker 服务..."
    systemctl start docker
    systemctl enable docker
}

# 验证 Docker 安装
verify_docker_installation() {
    log_info "验证 Docker 安装..."
    
    if command -v docker &> /dev/null; then
        INSTALLED_VERSION=$(docker --version | grep -oP '\d+\.\d+\.\d+' || docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        log_info "✅ Docker 版本: $INSTALLED_VERSION"
    else
        log_error "Docker 安装失败"
        return 1
    fi
    
    if docker compose version &> /dev/null; then
        log_info "✅ docker-compose-plugin 已安装"
        docker compose version
    elif docker-compose --version &> /dev/null; then
        log_info "✅ docker-compose 已安装"
        docker-compose --version
    else
        log_warn "docker-compose-plugin 未安装"
    fi
    
    return 0
}

# 检查并处理已安装的 Docker（版本阈值 23.0.0）
check_existing_docker() {
    if command -v docker &> /dev/null; then
        current_version=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_info "检测到已安装 Docker 版本: $current_version"
        
        # 版本阈值为 23.0.0
        compare_result=$(version_compare "$current_version" "23.0.0")
        
        if [[ $compare_result -lt 0 ]]; then
            log_warn "当前版本 $current_version 小于 23.0.0，需要升级..."
            log_info "卸载旧版本 Docker..."
            
            if [ "$OS" = "centos" ]; then
                local centos_version=$(get_system_version)
                if [[ $centos_version -eq 8 ]]; then
                    dnf remove -y docker* containerd.io docker-compose* 2>/dev/null || true
                else
                    yum remove -y docker* containerd.io docker-compose* 2>/dev/null || true
                fi
            elif [ "$OS" = "debian" ]; then
                apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
                apt-get remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
            fi
            
            return 1  # 需要安装
        else
            log_info "当前版本 $current_version >= 23.0.0，无需升级"
            
            # 检查并配置镜像加速器
            if [[ ! -f /etc/docker/daemon.json ]] || ! grep -q "stxam7vz" /etc/docker/daemon.json 2>/dev/null; then
                configure_docker_mirror
                systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || true
            fi
            
            verify_docker_installation
            return 0  # 无需操作
        fi
    else
        log_info "未检测到 Docker，将安装最新版本..."
        return 1  # 需要安装
    fi
}

# ==================== 主程序 ====================

main() {
    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        log_info "请使用: sudo $0"
        exit 1
    fi
    
    # 检测操作系统
    OS=$(detect_os)
    log_info "检测到操作系统: $OS"
    
    # 移除不可变标志（仅 CentOS）
    if [ "$OS" = "centos" ]; then
        chattr -i /usr/bin 2>/dev/null || true
        lsattr -d /usr/bin 2>/dev/null || true
    fi
    
    # 检查现有 Docker 安装
    if check_existing_docker; then
        log_info "Docker 已满足要求，无需操作"
        exit 0
    fi
    
    # 根据系统类型安装 Docker
    if [ "$OS" = "centos" ]; then
        CENTOS_VERSION=$(get_system_version)
        log_info "CentOS 版本: $CENTOS_VERSION"
        
        if ! install_docker_centos $CENTOS_VERSION; then
            log_error "Docker 安装失败"
            exit 1
        fi
        
    elif [ "$OS" = "debian" ]; then
        DEBIAN_VERSION=$(get_system_version)
        log_info "Debian 版本: $DEBIAN_VERSION"
        
        if [ "$DEBIAN_VERSION" = "unknown" ]; then
            log_error "无法识别的 Debian 版本"
            exit 1
        fi
        
        install_docker_debian $DEBIAN_VERSION
        
    else
        log_error "不支持的操作系统: $OS"
        log_info "本脚本仅支持 CentOS 7/8 和 Debian (buster/bullseye/bookworm)"
        exit 1
    fi
    
    # 配置镜像加速器
    configure_docker_mirror
    
    # 启动 Docker
    start_docker_service
    
    # 验证安装
    verify_docker_installation
    
    # 输出安装信息
    echo ""
    log_info "========================================="
    log_info "✅ Docker CE 安装完成！"
    log_info "系统: $OS"
    log_info "镜像加速器: https://stxam7vz.mirror.aliyuncs.com"
    log_info "========================================="
    echo ""
    log_info "常用命令:"
    log_info "  docker --version          # 查看 Docker 版本"
    log_info "  docker compose version    # 查看 Compose 版本"
    log_info "  systemctl status docker   # 查看 Docker 状态"
    log_info "  docker run hello-world    # 测试运行"
}

# 执行主程序
main
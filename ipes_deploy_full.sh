#!/bin/bash
# =============================================================================
# IPES 业务 41（q2）整体部署脚本 —— 绑定 + 部署 + happy 9/9 + 状态流转
# =============================================================================
# 融合来源：
#   1) zyy_init_max.sh       —— 官方 zycloud agent 安装、SSH/用户安全配置、设备注册
#   2) ipes_onekey.sh        —— IPES 预热/对齐/拉满（happy 9/9）
#   3) ecache 部署脚本       —— Docker + IPES 容器初始化
#
# 用途：
#   在云主机上一站式完成：
#     系统初始化 → zycloud agent → SSH/用户安全 → 设备注册
#     → Docker 安装 → IPES 部署 → 预热对齐拉满 happy 9/9
#     → 提交业务 41 → admin token 注入 → 从「待配置」流转到「服务中」。
#
# 用法：
#   curl -fsSL <脚本URL> | bash -s -- \
#     --ak <渠道AK> --sk <渠道SK> --isp 电信 --num-dirs 12
#
# 必需参数：
#   --ak <appKey>          渠道注册 appKey
#   --sk <secretKey>       渠道注册 secretKey
#   --isp <运营商>          电信 / 联通 / 移动
#   --num-dirs <数量>       IPES 缓存目录数量（云环境常见 12）
#
# 可选参数：
#   --remark <备注>         设备注册备注，默认 "<isp>-<设备SN前8位>"
#   --business <业务ID>     提交给平台的业务编号，默认 41（q2）
#   --target-happ <N>       happy 进程数，默认 9
#   --skip-onekey           跳过 ipes_onekey 预热对齐
#   --skip-olmt             跳过 olmt.sh 限速（节点跑满不封顶时加）
#   --help                  显示帮助
#
# 后台认证（两种，Bearer 优先；均已在脚本内配置 test.sh 的真实凭证，可用环境变量覆盖）：
#   1) ADMIN_TOKEN          admin.zhouyi.top 的 Bearer Token（设了就优先用）
#   2) ADMIN_APPID/AK/SK     管理后台 appId + AK + SK（默认取自 test.sh，用 HMAC-SHA256 签名）
#
# 可配置环境变量：
#   ADMIN_API_HOST          管理后台域名，默认 https://admin.zhouyi.top
#   ADMIN_NOMINAL_API       业务/带宽提交接口，默认 /api/edgeNode/updateEdgeNominalInfo
#   ADMIN_STATUS_API        状态流转接口，默认 /api/edgeNode/stateflow
#   ADMIN_STATUS_BODY       自定义状态流转请求体（覆盖默认 nodes+stage）
#   NODE_ACTIVATE_TOKEN     节点激活 JWT（stateflow 以 X-Token 头鉴权，必需）
#   IPES_IMAGE_MIRROR       IPES 镜像（默认腾讯云公开镜像，匿名可拉）
#
# 安全提示：
#   脚本内已内置 test.sh 里的后台凭证以便开箱即用；正式分发前建议改为环境变量传入，
#   并到 admin.zhouyi.top 轮换 AK/SK。
# =============================================================================

set -uo pipefail
export LC_ALL=C

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/var/log/ipes_full_deploy.log"
FRPC_CONFIG="/usr/local/frpc_zycloud/frpc.json"
INSTALLER_DIR="/opt/zyy_install"
SCRIPT_VERSION="v2026-09-13-r4"

# CDN/OSS 下载配置
CDN_DOMAIN="file.zhouyi.top"
ORIGIN_DOMAIN="zyy-go.oss-cn-beijing.aliyuncs.com"

# 渠道注册 API
API_URL="http://api.zhouyiy.com/qudao/device/v1/batch/create2"

# 管理后台配置（admin.zhouyi.top）
# 后台认证真实方案（来自 test.sh）：appId + 时间戳 + HMAC-SHA256 签名
#   sign = HMAC-SHA256("<ak>:<timestamp>", key="<sk>")
# 默认 appId/ak/sk 取自 test.sh（你自己的后台凭证）；如需覆盖用环境变量：
#   ADMIN_APPID=xxx ADMIN_AK=xxx ADMIN_SK=xxx
# 也可改用 Bearer token：设置 ADMIN_TOKEN=xxx 后将优先使用
ADMIN_API_HOST="${ADMIN_API_HOST:-https://admin.zhouyi.top}"
ADMIN_NOMINAL_API="${ADMIN_NOMINAL_API:-/api/edgeNode/updateEdgeNominalInfo}"
ADMIN_STATUS_API="${ADMIN_STATUS_API:-/api/edgeNode/stateflow}"

# ↓↓↓ 加 token 的地方 ↓↓↓
# 1) 后台登录 Bearer token（可选）：从 admin.zhouyi.top 拿到后粘贴，或运行时 ADMIN_TOKEN=xxx 传入
ADMIN_TOKEN="${ADMIN_TOKEN:-}"
# 2) 节点激活 token（可选）：部分后台「待配置→服务中」需单独传入的 token，留空则不带
NODE_ACTIVATE_TOKEN="${NODE_ACTIVATE_TOKEN:-}"
# IPES 镜像：官方 ecache 脚本内置的阿里云 ACR 已失效（401），改用腾讯云公开镜像（匿名可拉）
IPES_IMAGE_MIRROR="${IPES_IMAGE_MIRROR:-ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:1.3.0}"
# 官方 ecache 脚本里写死的阿里云 ACR 镜像（用于 sed 替换，勿改）
ACR_IMAGE_DEAD="crpi-0myzmqp9v99mnimv.cn-beijing.personal.cr.aliyuncs.com/qy_q2/ipes-linux-amd64-youkai-latest:latest"
# ↑↑↑ 加 token 的地方 ↑↑↑

# 默认后台凭证（来自 test.sh；建议通过环境变量覆盖，避免明文落在脚本里）
ADMIN_APPID="${ADMIN_APPID:-fg5c21pbzfgu6y2s2yqvanvr6uv99drq}"
ADMIN_AK="${ADMIN_AK:-ja3io44nq2m7hx63fjkpio7s422aksel}"
ADMIN_SK="${ADMIN_SK:-ydDGuguZ8COcJN4Ztl3Lsic3Z00zGEani8fYOPiYk2XXCuXQ1AHyy7E1sgV4dyDT}"

# zyy_install 包配置
declare -A CDN_URLS
declare -A SOURCE_URLS
declare -A FILE_MD5

CDN_URLS["zyy_install_notele.tgz"]="http://file.zhouyi.top/script/zyy_init_qudao/zyy_install_notele.tgz"
CDN_URLS["zyy_install.tgz"]="http://file.zhouyi.top/script/zyy_init_qudao/zyy_install.tgz"

SOURCE_URLS["zyy_install_notele.tgz"]="http://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init_qudao/zyy_install_notele.tgz"
SOURCE_URLS["zyy_install.tgz"]="http://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init_qudao/zyy_install.tgz"

FILE_MD5["zyy_install_notele.tgz"]="e05af065a219983a9fd2d0c2432f0747"
FILE_MD5["zyy_install.tgz"]="9a2f340ec53f394eb3f68219037c99b3"

CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIMEOUT=30

# 用户传入参数
APP_KEY=""
SECRET_KEY=""
ISP=""
NUM_DIRS=""
REMARK=""
BUSINESS_ID="41"
TARGET_HAPP="9"
SKIP_ONEKEY=0
SKIP_OLMT=0

province=""
city=""
DEVICE_ID=""

# =============================================================================
# 帮助信息
# =============================================================================
show_help() {
    cat <<EOF
用法: $0 [选项]

选项:
  --ak <appKey>          设置应用Key (必需)
  --sk <secretKey>       设置密钥 (必需)
  --isp <运营商>          设置运营商 (必需，如: 电信、联通、移动)
  --num-dirs <数量>       云环境固定目录数量 (必需，如: 12)
  --remark <备注>         设备注册备注 (可选)
  --business <业务ID>     提交的业务编号 (默认: 41)
  --target-happ <N>       happy 进程数 (默认: 9)
  --skip-onekey           跳过 ipes_onekey 预热对齐
  --skip-olmt             跳过 olmt.sh 限速（希望节点跑满不封顶时加）
  --node-token <token>    节点激活 token（待配置→服务中）
  --help                  显示此帮助信息

环境变量 (后台认证，脚本已内置 test.sh 凭证，可用以下覆盖/补充):
  优先: ADMIN_TOKEN=<Bearer token>            设了就走 Bearer
  默认: ADMIN_APPID/AK/SK=<id>/<ak>/<sk>      HMAC-SHA256 签名（已内置，可覆盖）
  加token: NODE_ACTIVATE_TOKEN=<节点激活JWT>  状态流转接口 stateflow 用 X-Token 头鉴权，必需

可配置:
  ADMIN_API_HOST=<host>        默认 https://admin.zhouyi.top
  ADMIN_STATUS_API=<path>      默认 /api/edgeNode/stateflow
  ADMIN_NOMINAL_API=<path>     默认 /api/edgeNode/updateEdgeNominalInfo
  ADMIN_STATUS_BODY=<json>     自定义状态流转请求体（覆盖默认 nodes+stage）
  IPES_IMAGE_MIRROR=<image>    IPES 镜像，默认 ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:1.3.0

状态流转 stage 取值（后台只允许 configured / inService 之间流转）:
  bound(待提交) / configured(待配置) / waitAudit(交付中) / inService(服务中) / gotOff(已下机)

示例:
  在线执行 (推荐):
    curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_deploy_full.sh \
      | bash -s -- --ak <你的渠道ak> --sk <你的渠道sk> --isp 电信 --num-dirs 12 --node-token <你的激活token>

  本地执行:
    ADMIN_TOKEN=eyJhbG... \\
      $0 --ak 06d78b... --sk 16d6c4... --isp 电信 --num-dirs 12
EOF
    exit 0
}

# =============================================================================
# 参数解析
# =============================================================================
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ak)          APP_KEY="$2"; shift 2 ;;
            --sk)          SECRET_KEY="$2"; shift 2 ;;
            --isp)         ISP="$2"; shift 2 ;;
            --num-dirs)    NUM_DIRS="$2"; shift 2 ;;
            --remark)      REMARK="$2"; shift 2 ;;
            --business)    BUSINESS_ID="$2"; shift 2 ;;
            --target-happ) TARGET_HAPP="$2"; shift 2 ;;
            --skip-onekey) SKIP_ONEKEY=1; shift ;;
            --skip-olmt)   SKIP_OLMT=1; shift ;;
            --node-token)  NODE_ACTIVATE_TOKEN="$2"; shift 2 ;;
            --help)        show_help ;;
            *)
                echo -e "${RED}[错误]${NC} 未知参数: $1"
                show_help
                ;;
        esac
    done

    local missing=0
    if [ -z "$APP_KEY" ]; then
        echo -e "${RED}[错误]${NC} 缺少参数: --ak"; missing=1
    fi
    if [ -z "$SECRET_KEY" ]; then
        echo -e "${RED}[错误]${NC} 缺少参数: --sk"; missing=1
    fi
    if [ -z "$ISP" ]; then
        echo -e "${RED}[错误]${NC} 缺少参数: --isp"; missing=1
    fi
    if [ -z "$NUM_DIRS" ]; then
        echo -e "${RED}[错误]${NC} 缺少参数: --num-dirs"; missing=1
    fi
    if ! [[ "$NUM_DIRS" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[错误]${NC} --num-dirs 必须是数字"; missing=1
    fi

    if [ "$missing" -eq 1 ]; then
        echo
        show_help
        exit 1
    fi
}

# =============================================================================
# 日志
# =============================================================================
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local clean_message=$(echo -e "$message" | sed -E 's/\x1B\[[0-9;]*[mGK]//g')
    echo "[$timestamp] $clean_message" >> "$LOG_FILE"
    echo -e "$message"
}

log_stderr() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local clean_message=$(echo -e "$message" | sed -E 's/\x1B\[[0-9;]*[mGK]//g')
    echo "[$timestamp] $clean_message" >> "$LOG_FILE"
    echo -e "$message" >&2
}

print_step() {
    local step_title="$1"
    log_message "\n======================================================"
    log_message ">> 步骤：$step_title"
    log_message "======================================================"
}

init_log() {
    local log_dir=$(dirname "$LOG_FILE")
    mkdir -p "$log_dir"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    log_message "=== IPES 业务 ${BUSINESS_ID} 整体部署脚本开始执行 ==="
    log_message "脚本版本: $SCRIPT_VERSION"
    log_message "日志文件: $LOG_FILE"
    log_message "目标 happy 进程数: $TARGET_HAPP"
    log_message "运营商: $ISP / 缓存目录数: $NUM_DIRS"
}

# =============================================================================
# 下载与校验
# =============================================================================
check_md5() {
    local file_path=$1
    local file_name=$2
    local expected_md5=${FILE_MD5[$file_name]}

    [ -f "$file_path" ] || { log_stderr "文件不存在: $file_path"; return 1; }
    local actual_md5=$(md5sum "$file_path" | awk '{print $1}')
    if [ "$actual_md5" = "$expected_md5" ]; then
        log_message "MD5校验通过: $file_name"
        return 0
    else
        log_stderr "MD5校验失败: $file_name (期望 $expected_md5 / 实际 $actual_md5)"
        return 1
    fi
}

check_and_clean_existing_file() {
    local file_name=$1
    local file_path="/opt/${file_name}"
    if [ -f "$file_path" ]; then
        if check_md5 "$file_path" "$file_name"; then
            return 0
        else
            rm -f "$file_path"
            return 1
        fi
    fi
    return 1
}

download_file() {
    local url=$1
    local output_path=$2
    local max_retries=3
    local retry_delay=2

    for ((i=1; i<=max_retries; i++)); do
        log_stderr "下载尝试 $i/$max_retries: $url"
        if curl -L -C - --connect-timeout 30 --max-time 600 --retry 1 --retry-delay 5 \
            -o "$output_path" "$url" 2>&1; then
            if [ -f "$output_path" ] && [ "$(stat -c%s "$output_path")" -gt 0 ]; then
                log_stderr "下载成功: $url"
                return 0
            fi
        fi
        [ $i -lt $max_retries ] && { log_stderr "等待 ${retry_delay} 秒后重试..."; sleep $retry_delay; }
    done
    return 1
}

download_with_fallback() {
    local file_name=$1
    local local_path="/opt/${file_name}"
    local temp_path="${local_path}.part"

    if check_and_clean_existing_file "$file_name"; then
        return 0
    fi

    rm -f "$temp_path"
    local cdn_url="${CDN_URLS[$file_name]}"
    log_stderr "开始从 CDN 下载 $file_name"
    if download_file "$cdn_url" "$temp_path"; then
        mv "$temp_path" "$local_path"
        if check_md5 "$local_path" "$file_name"; then
            return 0
        fi
        rm -f "$local_path"
    fi

    rm -f "$temp_path"
    local source_url="${SOURCE_URLS[$file_name]}"
    log_stderr "切换到 OSS 回源下载 $file_name"
    if download_file "$source_url" "$temp_path"; then
        mv "$temp_path" "$local_path"
        if check_md5 "$local_path" "$file_name"; then
            return 0
        fi
        rm -f "$local_path"
    fi

    return 1
}

# =============================================================================
# 云环境检测 / agent 安装 / frp / ssh / 用户
# =============================================================================
detect_cloud_environment() {
    if dmesg | grep -qi alibaba 2>/dev/null; then
        echo "aliyun"; return 0
    fi
    if dmesg | grep -qi tencent 2>/dev/null; then
        echo "tencent"; return 0
    fi
    echo "non_cloud"; return 1
}

cloud_server_edge() {
    local file_name="zyy_install_notele.tgz"
    if ! download_with_fallback "$file_name"; then
        log_message "${RED}[错误]${NC} 下载 $file_name 失败"; return 1
    fi
    log_message "解压文件..."
    tar xf "/opt/${file_name}" -C /opt
    chmod -R +x /opt/zyy_install/*
    cd /opt/zyy_install/ && ./agent_installer install zycloud
}

iso_server_edge() {
    local file_name="zyy_install.tgz"
    if ! download_with_fallback "$file_name"; then
        log_message "${RED}[错误]${NC} 下载 $file_name 失败"; return 1
    fi
    log_message "解压文件..."
    tar xf "/opt/${file_name}" -C /opt
    chmod -R +x /opt/zyy_install/*
    mkdir -p /var/log/telegraf
    id telegraf &>/dev/null || useradd -r -s /bin/false -d /etc/telegraf telegraf
    chown -R telegraf:telegraf /var/log/telegraf
    cd /opt/zyy_install/ && ./agent_installer install zycloud --enable-telegraf
}

get_ssh_port() {
    local ssh_port
    ssh_port=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
    if [ -z "$ssh_port" ] && [ -f "/etc/ssh/sshd_config" ]; then
        ssh_port=$(grep -E "^Port[[:space:]]+[0-9]+" /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    fi
    [ -z "$ssh_port" ] && ssh_port=22
    echo "$ssh_port"
}

enable_ssh_pubkey_auth() {
    local sshd_config="/etc/ssh/sshd_config"
    [ -f "$sshd_config" ] || { log_message "${YELLOW}[警告]${NC} SSH配置文件不存在"; return 1; }

    local backup_file="${sshd_config}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$sshd_config" "$backup_file"
    log_message "${GREEN}[成功]${NC} SSH配置文件已备份到: $backup_file"

    if grep -q "^PubkeyAuthentication\\s*yes" "$sshd_config"; then
        log_message "${YELLOW}[信息]${NC} 公钥认证已启用"
        return 0
    fi

    if grep -q "^#PubkeyAuthentication" "$sshd_config"; then
        sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/g' "$sshd_config"
    elif grep -q "^PubkeyAuthentication" "$sshd_config"; then
        sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/g' "$sshd_config"
    else
        echo -e "\n# Enable public key authentication" >> "$sshd_config"
        echo "PubkeyAuthentication yes" >> "$sshd_config"
    fi

    if grep -q "^PubkeyAuthentication\\s*yes" "$sshd_config"; then
        log_message "${GREEN}[成功]${NC} SSH公钥认证已启用"
        systemctl restart sshd && log_message "${GREEN}[成功]${NC} SSH服务重启成功" \
            || log_message "${YELLOW}[警告]${NC} SSH服务重启失败"
        return 0
    fi
    log_message "${RED}[错误]${NC} SSH公钥认证配置失败"
    return 1
}

disable_root_ssh_login() {
    local sshd_config="/etc/ssh/sshd_config"
    local backup_file="${sshd_config}.backup.$(date +%Y%m%d_%H%M%S)"

    print_step "禁用 SSH root 登录"

    [ -f "$sshd_config" ] || { log_message "${YELLOW}[警告]${NC} SSH配置文件不存在"; return 1; }

    cp "$sshd_config" "$backup_file"
    log_message "${GREEN}[成功]${NC} SSH配置文件已备份到: $backup_file"

    if grep -Eq "^PermitRootLogin[[:space:]]+no" "$sshd_config"; then
        log_message "${YELLOW}[信息]${NC} SSH root 登录已被禁用"
    elif grep -q "^#PermitRootLogin" "$sshd_config"; then
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/g' "$sshd_config"
    elif grep -q "^PermitRootLogin" "$sshd_config"; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin no/g' "$sshd_config"
    else
        echo -e "\n# Disable root SSH login" >> "$sshd_config"
        echo "PermitRootLogin no" >> "$sshd_config"
    fi

    if grep -Eq "^AllowUsers[[:space:]]+admin" "$sshd_config"; then
        log_message "${YELLOW}[信息]${NC} 仅允许 admin 登录配置已存在"
    elif grep -q "^AllowUsers" "$sshd_config"; then
        sed -i 's/^AllowUsers.*/AllowUsers admin/g' "$sshd_config"
    else
        echo "AllowUsers admin" >> "$sshd_config"
    fi

    if grep -Eq "^PermitRootLogin[[:space:]]+no" "$sshd_config" && \
       grep -Eq "^AllowUsers[[:space:]]+admin" "$sshd_config"; then
        log_message "${GREEN}[成功]${NC} SSH root 登录已禁用，且仅允许 admin 登录"
        systemctl restart sshd && log_message "${GREEN}[成功]${NC} SSH服务重启成功" \
            || log_message "${YELLOW}[警告]${NC} SSH服务重启失败"
        return 0
    else
        log_message "${RED}[错误]${NC} SSH root 登录配置失败"
        return 1
    fi
}

clear_root_ssh_dir() {
    local root_ssh_dir="/root/.ssh"
    print_step "清空 root 用户 .ssh 目录"
    mkdir -p "$root_ssh_dir"
    if [ -d "$root_ssh_dir" ]; then
        find "$root_ssh_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
        chmod 700 "$root_ssh_dir"
        chown root:root "$root_ssh_dir"
        log_message "${GREEN}[成功]${NC} root 用户 .ssh 目录内容已清空"
        return 0
    fi
    log_message "${RED}[错误]${NC} 无法访问 root 用户 .ssh 目录"
    return 1
}

set_root_password() {
    local root_password_hash='$6sQhmo2hOEsM'
    print_step "修改 root 密码"
    if usermod --password "$root_password_hash" root; then
        log_message "${GREEN}[成功]${NC} root 密码已使用加密哈希更新"
        return 0
    fi
    log_message "${RED}[错误]${NC} 更新 root 密码失败"
    return 1
}

set_frp_port() {
    print_step "修改frpc配置（动态获取SSH端口）"
    local SSH_PORT=$(get_ssh_port)
    log_message "检测到的SSH端口: ${GREEN}$SSH_PORT${NC}"

    if [ -f "$FRPC_CONFIG" ]; then
        cp "$FRPC_CONFIG" "${FRPC_CONFIG}.backup"
        sed -i "s/\"LocalPort\": [0-9]*/\"LocalPort\": $SSH_PORT/g" "$FRPC_CONFIG"
        if grep -q "\"LocalPort\": $SSH_PORT" "$FRPC_CONFIG"; then
            log_message "${GREEN}[成功]${NC} frpc.json 已更新为 $SSH_PORT"
        fi
        systemctl restart frpc_zycloud && log_message "${GREEN}[成功]${NC} frpc_zycloud 已重启" \
            || log_message "${YELLOW}[警告]${NC} frpc_zycloud 重启失败"
    else
        log_message "${YELLOW}[警告]${NC} 未找到 $FRPC_CONFIG"
    fi
}

check_services_status() {
    print_step "检查zyycloud相关服务状态"
    local SERVICES=("frpc_zycloud" "edge_client_zycloud" "telegraf_zycloud")
    for service in "${SERVICES[@]}"; do
        if systemctl list-units --full -all | grep -q "$service.service"; then
            local STATUS=$(systemctl is-active "$service" 2>/dev/null)
            if [ "$STATUS" == "active" ]; then
                log_message "  - $service: ${GREEN}运行中${NC}"
            else
                log_message "  - $service: ${RED}异常 ($STATUS)${NC}"
            fi
        else
            log_message "  - $service: ${YELLOW}未安装${NC}"
        fi
    done
}

add_admin_user() {
    print_step "添加 admin 用户"
    if id "admin" &>/dev/null; then
        log_message "${YELLOW}[警告]${NC} 用户 'admin' 已存在，跳过"
    else
        /usr/sbin/useradd admin && log_message "${GREEN}[成功]${NC} 用户 'admin' 创建完毕" \
            || log_message "${RED}[错误]${NC} 创建用户 'admin' 失败"
    fi
}

add_zhouyi_user() {
    print_step "添加 zhouyi 用户并配置免密切换"
    if id "zhouyi" &>/dev/null; then
        log_message "${YELLOW}[警告]${NC} 用户 'zhouyi' 已存在，跳过"
    else
        /usr/sbin/useradd zhouyi && log_message "${GREEN}[成功]${NC} 用户 'zhouyi' 创建完毕" \
            || { log_message "${RED}[错误]${NC} 创建用户 'zhouyi' 失败"; return 1; }
    fi

    local sudoers_file="/etc/sudoers.d/zhouyi"
    cat > "$sudoers_file" <<-'EOF'
# admin 可免密切换到 zhouyi
admin ALL=(zhouyi) NOPASSWD: ALL
# zhouyi 可免密切换到 root
zhouyi ALL=(root) NOPASSWD: ALL
EOF
    chmod 440 "$sudoers_file"
    if visudo -cf "$sudoers_file" >/dev/null 2>&1; then
        log_message "${GREEN}[成功]${NC} 免密切换配置完成: admin->zhouyi->root"
    else
        log_message "${RED}[错误]${NC} sudoers 语法校验失败"
        rm -f "$sudoers_file"
        return 1
    fi
}

add_ssh_key() {
    print_step "添加 SSH 公钥到 authorized_keys"
    local SSH_DIR="/home/admin/.ssh"
    local AUTH_KEYS_FILE="$SSH_DIR/authorized_keys"
    local SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+qsk4/j2FQeDZKWkC8xI9RnSDFAkXmVO2SbToaoDF+eIsnJVIagtFvUkLA2r5pszEKFGWvoNkm0FrU8cqzfno1jkS3Y0j77rW++96qvf1fAA36PHHSYMtQ/aQCexptfBdVczARXM6/bzzBjtPHZ/SN4fS2bQ4RCwNouLYgwx1gsyi70XaoKbLdm5neqqX3IQK1OHACV2SkrX/libVze7cRNJlpYb6RpBpSq6TGLvqzXEHzNgVhM0HC5i8LWMdvNT8+txhYI+tWffYE8rn/KEeLmMwkyxLv45og9nQKrNaGh3agu4ERxDGzEagj12oJAe24dX5Zao+PFKEZYYH//BRIQ6Sa9oAImdkeYF0ImnF+mArki0DNUjxGDu82jGQqwTRv4MgCgRVm656391e5R+aC7TTmQKGElG68D1zieQYN+BscmTU0e7Dm1ugX2C9W6ZpKYRRzjZsqpb3ZqGOkmQKg7BvF0pQqWlwQ2htSFKkIUHsjRRegEo2eRzY08LA6Ec= jiayuguang@PC-20241122OPDI"

    mkdir -p "$SSH_DIR"
    chown -R admin:admin "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    touch "$AUTH_KEYS_FILE"
    chown admin:admin "$AUTH_KEYS_FILE"
    chmod 600 "$AUTH_KEYS_FILE"

    if grep -qF "$SSH_KEY" "$AUTH_KEYS_FILE"; then
        log_message "${YELLOW}[警告]${NC} SSH 公钥已存在"
    else
        echo "$SSH_KEY" >> "$AUTH_KEYS_FILE"
        chmod 600 "$AUTH_KEYS_FILE"
        chown admin:admin "$AUTH_KEYS_FILE"
        log_message "${GREEN}[成功]${NC} SSH 公钥已添加"
    fi
}

display_device_id() {
    print_step "读取设备ID（业务SN）"
    local DEVICE_ID_FILE="/etc/.mac"
    if [ -f "$DEVICE_ID_FILE" ]; then
        DEVICE_ID=$(cat "$DEVICE_ID_FILE" | tr -d '[:space:]')
        mkdir -p /usr/local/edge/
        echo "$DEVICE_ID" > /usr/local/edge/device_code
        log_message "设备SN（业务ID）: ${GREEN}${DEVICE_ID}${NC}"

        hostname "$DEVICE_ID"
        echo "$DEVICE_ID" > /etc/hostname
        if [ -f /etc/hosts ]; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $DEVICE_ID/" /etc/hosts
        fi
        log_message "${GREEN}[成功]${NC} 主机名已设置为: $DEVICE_ID"
    else
        log_message "${YELLOW}[警告]${NC} 未找到 $DEVICE_ID_FILE"
    fi
}

show_installer_contents() {
    print_step "安装文件列表"
    if [ -d "$INSTALLER_DIR" ]; then
        ls -la "$INSTALLER_DIR/" 2>/dev/null | while read line; do
            log_message "  $line"
        done
    fi
}

# =============================================================================
# 地理位置与设备注册
# =============================================================================
get_location_info() {
    print_step "获取地理位置信息"
    local ip_info=$(curl -s --retry 3 --retry-delay 2 --connect-timeout 5 --max-time 10 myip.ipip.net)
    province=$(echo "$ip_info" | awk -F ' ' '{print $4}' | tr -d ',')
    city=$(echo "$ip_info" | awk -F ' ' '{print $5}' | tr -d ',')

    if [ -z "$province" ] || [ "$province" = "null" ]; then
        province="北京"; log_message "${YELLOW}[警告]${NC} 省份获取失败，使用默认值: 北京"
    fi
    if [ -z "$city" ] || [ "$city" = "null" ]; then
        city="北京"; log_message "${YELLOW}[警告]${NC} 城市获取失败，使用默认值: 北京"
    fi
    log_message "${GREEN}[成功]${NC} 地理位置: ${province} / ${city}"
}

generate_sign() {
    local timestamp="$1"
    local ak="$2"
    local sk="$3"
    local sign_string="${ak}${timestamp}${sk}"
    local md5_sign=$(echo -n "$sign_string" | md5sum | cut -d ' ' -f1)
    echo "ZYY${md5_sign}"
}

register_device() {
    local device_id="$1"
    local province="$2"
    local city="$3"
    local isp="$4"
    local remark="$5"
    local max_retries=3

    print_step "注册设备到云端"
    local device_remark="${remark:-${isp}-${device_id:0:8}}"

    for ((retry_count=0; retry_count<max_retries; retry_count++)); do
        local timestamp=$(date +%s)
        local sign=$(generate_sign "$timestamp" "$APP_KEY" "$SECRET_KEY")
        local request_data='{"devices":[{"device_id":"'"$device_id"'","remark":"'"$device_remark"'"}],"province":"'"$province"'","city":"'"$city"'","isp":"'"$isp"'"}'

        log_message "正在注册设备 (尝试 $((retry_count+1))/$max_retries)..."
        local response=$(curl -s -w "\n%{http_code}" --location --request POST "$API_URL" \
            --header "sign: $sign" \
            --header "verison: V1.0.0" \
            --header "appKey: $APP_KEY" \
            --header "timestamp: $timestamp" \
            --header "Content-Type: application/json" \
            --data "$request_data" \
            --connect-timeout $CURL_CONNECT_TIMEOUT \
            --max-time $CURL_MAX_TIMEOUT 2>&1)

        local curl_exit_code=$?
        if [ $curl_exit_code -ne 0 ]; then
            log_message "${YELLOW}[警告]${NC} curl 失败，退出码 $curl_exit_code"
            [ $retry_count -lt $((max_retries-1)) ] && { sleep 2; continue; }
            return 1
        fi

        local http_code=$(echo "$response" | tail -n1)
        local response_body=$(echo "$response" | sed '$d')

        if [ "$http_code" = "200" ]; then
            if echo "$response_body" | grep -q "全部绑定成功\|全部已存在"; then
                log_message "${GREEN}[成功]${NC} 设备注册成功"
                log_message "API响应: $response_body"

                local reg_info_file="/usr/local/edge/registration_info"
                echo "注册时间: $(date '+%Y-%m-%d %H:%M:%S')" > "$reg_info_file"
                echo "设备SN: $device_id" >> "$reg_info_file"
                echo "省份: $province" >> "$reg_info_file"
                echo "城市: $city" >> "$reg_info_file"
                echo "运营商: $isp" >> "$reg_info_file"
                echo "备注: $device_remark" >> "$reg_info_file"
                echo "API响应: $response_body" >> "$reg_info_file"
                chmod 644 "$reg_info_file"
                return 0
            else
                log_message "${YELLOW}[警告]${NC} 注册返回异常: $response_body"
            fi
        else
            log_message "${YELLOW}[警告]${NC} HTTP $http_code: $response_body"
        fi
        [ $retry_count -lt $((max_retries-1)) ] && sleep 2
    done

    log_message "${RED}[错误]${NC} 设备注册失败"
    return 1
}

# =============================================================================
# admin.zhouyi.top 接口请求（真实方案：appId + 时间戳 + HMAC-SHA256 签名）
# 若设置 ADMIN_TOKEN 则改用 Bearer；否则用内置/传入的 appId/AK/SK 签名。
# =============================================================================
admin_api_request() {
    local method="$1"
    local api_path="$2"
    local body="$3"
    local url="${ADMIN_API_HOST}${api_path}"

    log_message "请求: $method $url"
    log_message "请求体: $body"

    # 方式一：Bearer token（若设置 ADMIN_TOKEN 则优先）
    if [ -n "$ADMIN_TOKEN" ]; then
        curl -k -s -w "\n%{http_code}" --location --request "$method" "$url" \
            --header "Authorization: Bearer $ADMIN_TOKEN" \
            --header 'Content-Type: application/json' \
            --data "$body" \
            --connect-timeout $CURL_CONNECT_TIMEOUT \
            --max-time $CURL_MAX_TIMEOUT 2>&1
        return
    fi

    # 方式二（默认）：appId + 时间戳 + HMAC-SHA256 签名（test.sh 真实方案）
    local appid="$ADMIN_APPID"
    local ak="$ADMIN_AK"
    local sk="$ADMIN_SK"
    if [ -z "$appid" ] || [ -z "$ak" ] || [ -z "$sk" ]; then
        log_message "${YELLOW}[警告]${NC} 未配置后台凭证（ADMIN_APPID/AK/SK 或 ADMIN_TOKEN），跳过接口调用"
        return 1
    fi

    local timestamp=$(date +%s)
    local sign_str="${ak}:${timestamp}"
    local sign=$(echo -n "$sign_str" | openssl dgst -sha256 -hmac "$sk" | cut -d' ' -f2)

    curl -k -s -w "\n%{http_code}" --location --request "$method" "$url" \
        --header "appId: $appid" \
        --header "timestamp: $timestamp" \
        --header "sign: $sign" \
        --header 'Content-Type: application/json' \
        --data "$body" \
        --connect-timeout $CURL_CONNECT_TIMEOUT \
        --max-time $CURL_MAX_TIMEOUT 2>&1
}

# X-Token（JWT 激活 token）鉴权请求：admin 前端「状态流转」用的就是这个头
admin_api_request_xtoken() {
    local method="$1"
    local api_path="$2"
    local body="$3"
    local url="${ADMIN_API_HOST}${api_path}"

    log_message "请求(X-Token): $method $url"
    log_message "请求体: $body"

    curl -k -s -w "\n%{http_code}" --location --request "$method" "$url" \
        --header "X-Token: $NODE_ACTIVATE_TOKEN" \
        --header 'Content-Type: application/json' \
        --data "$body" \
        --connect-timeout $CURL_CONNECT_TIMEOUT \
        --max-time $CURL_MAX_TIMEOUT 2>&1
}

submit_business() {
    local node="$1"
    print_step "提交业务 ${BUSINESS_ID} 与带宽信息"

    if [ -z "$node" ]; then
        log_message "${YELLOW}[警告]${NC} 无设备SN，跳过业务提交"
        return 1
    fi

    # vendorSuggestCustomers=41 即业务 41（q2），transMode=1 默认直传
    local request_body="{\"nodeId\":\"$node\",\"vendorSuggestCustomers\":$BUSINESS_ID,\"transMode\":1,\"isCrossNetwork\":false,\"crossNetworkIsp\":null,\"isTransProv\":false,\"usbw\":200,\"bwNum\":1}"

    local response=$(admin_api_request POST "$ADMIN_NOMINAL_API" "$request_body")
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    log_message "响应 [HTTP $http_code]: $body"

    if [ "$http_code" = "200" ] && echo "$body" | grep -q '"code":0'; then
        log_message "${GREEN}[成功]${NC} 业务 ${BUSINESS_ID} 提交成功"
        return 0
    else
        log_message "${YELLOW}[警告]${NC} 业务 ${BUSINESS_ID} 提交失败或接口不匹配"
        return 1
    fi
}

transition_to_serving() {
    local node="$1"
    print_step "状态流转：待配置 -> 服务中（stateflow）"

    if [ -z "$node" ]; then
        log_message "${YELLOW}[警告]${NC} 无设备SN，跳过状态流转"
        return 1
    fi

    # 真实接口（从 admin.zhouyi.top 前端 bundle 还原并实测通过）：
    #   POST /api/edgeNode/stateflow
    #   Header: X-Token: <JWT 激活 token>
    #   Body:   {"nodes":["<SN>"],"stage":"inService"}
    #   stage: bound(待提交)/configured(待配置)/waitAudit(交付中)/inService(服务中)/gotOff(已下机)
    #   后台只允许 configured 与 inService 之间互转，其它值会报
    #   {"code":7,"msg":"设备只能流转到待配置或服务中"}
    local request_body
    if [ -n "${ADMIN_STATUS_BODY:-}" ]; then
        request_body="$ADMIN_STATUS_BODY"
    else
        request_body="{\"nodes\":[\"$node\"],\"stage\":\"${STATUS_TARGET:-inService}\"}"
    fi

    local response
    if [ -n "$NODE_ACTIVATE_TOKEN" ]; then
        response=$(admin_api_request_xtoken POST "$ADMIN_STATUS_API" "$request_body")
    else
        log_message "${YELLOW}[警告]${NC} 未提供 NODE_ACTIVATE_TOKEN；stateflow 需要 JWT（X-Token），尝试签名方式..."
        response=$(admin_api_request POST "$ADMIN_STATUS_API" "$request_body")
    fi

    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    log_message "响应 [HTTP $http_code]: $body"

    if [ "$http_code" = "200" ] && echo "$body" | grep -q '"code":0'; then
        log_message "${GREEN}[成功]${NC} 设备已流转到「服务中」"
        return 0
    else
        log_message "${YELLOW}[警告]${NC} 状态流转失败，请检查 ADMIN_STATUS_API 与请求体是否匹配"
        log_message "${YELLOW}[提示]${NC} 可手动在后台点击「服务中」，或设置 ADMIN_STATUS_BODY 环境变量自定义请求体"
        return 1
    fi
}

# =============================================================================
# Docker / IPES 部署 / ipes_onekey 拉满
# =============================================================================
check_docker_running() {
    command -v docker >/dev/null 2>&1 || return 1
    systemctl is-active --quiet docker || return 1
    return 0
}

install_docker_step() {
    print_step "安装 docker"
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
        log_message "${GREEN}[成功]${NC} docker 已安装并运行"
        return 0
    fi

    if ! yum install -y docker; then
        log_message "${YELLOW}[警告]${NC} docker 安装失败"; return 1
    fi

    mkdir -p /etc/docker
    tee /etc/docker/daemon.json <<-'EOF' >/dev/null
{
  "registry-mirrors": ["https://w2xkvcue.mirror.aliyuncs.com"]
}
EOF
    systemctl daemon-reload
    systemctl start docker
    systemctl enable docker

    if check_docker_running; then
        log_message "${GREEN}[成功]${NC} docker 已启动"
        return 0
    fi
    log_message "${YELLOW}[警告]${NC} docker 未正常启动"
    return 1
}

_run_remote_script_single() {
    local url="$1"
    shift
    local max_retries=5
    local retry_delay=3

    for ((attempt=1; attempt<=max_retries; attempt++)); do
        log_stderr "${CYAN}[信息]${NC} 获取远程脚本 (${attempt}/${max_retries}): ${url}"
        local script_content
        script_content=$(curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIMEOUT" "$url" 2>/dev/null)
        local curl_exit_code=$?

        if [ $curl_exit_code -eq 0 ] && [ -n "$script_content" ]; then
            printf '%s' "$script_content" | bash -s -- "$@"
            return $?
        fi

        local reason="未知错误(退出码:${curl_exit_code})"
        case $curl_exit_code in
            6)  reason="域名解析失败";;
            7)  reason="连接主机失败";;
            28) reason="操作超时";;
            22) reason="HTTP错误";;
        esac

        if [ $attempt -lt $max_retries ]; then
            log_stderr "${YELLOW}[警告]${NC} 获取失败(${reason})，${retry_delay}秒后重试..."
            sleep $retry_delay
        else
            log_stderr "${RED}[错误]${NC} 获取远程脚本失败(${reason})"
            return 1
        fi
    done
    return 1
}

run_remote_script_with_retry() {
    local origin_url="$1"
    shift
    local cdn_url="${origin_url//$ORIGIN_DOMAIN/$CDN_DOMAIN}"

    if _run_remote_script_single "$origin_url" "$@"; then
        return 0
    fi

    log_stderr "${YELLOW}[信息]${NC} 回源失败，切换到 CDN..."
    _run_remote_script_single "$cdn_url" "$@"
}

run_ipes_deploy() {
    print_step "执行 IPES 初始部署"

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'ipes'; then
        log_message "${CYAN}[信息]${NC} 检测到已存在 ipes 容器，执行健康检查..."
        local health_output
        health_output=$(docker exec ipes ./bin/ipes health 2>&1)
        local health_exit_code=$?
        log_message "健康检查输出:\n$health_output"

        if [ $health_exit_code -ne 0 ] || echo "$health_output" | grep -qi 'error'; then
            log_message "${YELLOW}[警告]${NC} ipes 健康检查异常，开始清理重建..."
            docker rm -f ipes
            rm -rf /data
            rm -rf /opt/ipes
            log_message "${GREEN}[成功]${NC} ipes 清理完成"
        else
            log_message "${GREEN}[成功]${NC} ipes 健康检查正常，无需清理"
        fi
    fi

    log_message "部署命令: ecache_docker_install_ali_ten.sh -t 2 -i 1 -n $NUM_DIRS（已打补丁：镜像 -> $IPES_IMAGE_MIRROR）"
    run_ecache_deploy
    return $?
}

# 官方 ecache 脚本内置的阿里云 ACR 凭据已失效（docker login 返回 unauthorized），
# 导致镜像拉不下来、ipes 容器起不来（实测：广州新机卡在这一步）。
# 这里下载脚本后打两处补丁：
#   1) 阿里云 ACR 私有镜像 -> 腾讯云公开镜像（匿名可拉，64e 工作节点用的就是它）
#   2) 中和失效的 docker login 调用
run_ecache_deploy() {
    local origin_url="http://oemtest.hejinyun.cn/shell/ecache_docker_install_ali_ten.sh"
    local cdn_url="${origin_url//$ORIGIN_DOMAIN/$CDN_DOMAIN}"
    local tmp_script="/tmp/.ecache_patched.sh"
    local url

    for url in "$origin_url" "$cdn_url"; do
        if curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIMEOUT" "$url" -o "$tmp_script" 2>/dev/null && [ -s "$tmp_script" ]; then
            sed -i "s#${ACR_IMAGE_DEAD}#${IPES_IMAGE_MIRROR}#g" "$tmp_script"
            sed -i 's#docker_login_for_image "\$DOCKER_IMAGE"#true#' "$tmp_script"
            log_message "ecache 已打补丁: 镜像 -> $IPES_IMAGE_MIRROR"
            bash "$tmp_script" -t 2 -i 1 -n "$NUM_DIRS"
            return $?
        fi
    done

    log_stderr "${RED}[错误]${NC} 获取 ecache 脚本失败"
    return 1
}

# IPES 稳定性看门狗：容器在但容器内 master 挂掉时自动拉起（每分钟一次）
install_ipes_watchdog() {
    print_step "安装 IPES 看门狗（master 挂掉自动拉起）"
    cat > /usr/local/bin/ipes_watchdog.sh <<'WATCHDOG'
#!/bin/bash
docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ipes$' || exit 0
if ! docker exec ipes sh -c 'ps -ef | grep -q "[i]pes start"' 2>/dev/null; then
  docker exec ipes /app/ipes/bin/ipes start >/dev/null 2>&1
  logger -t ipes_watchdog "ipes master was down -> restarted"
fi
WATCHDOG
    chmod +x /usr/local/bin/ipes_watchdog.sh
    ( crontab -l 2>/dev/null | grep -v ipes_watchdog; echo "* * * * * /usr/local/bin/ipes_watchdog.sh >/dev/null 2>&1" ) | crontab -
    systemctl enable crond >/dev/null 2>&1 || true
    systemctl start crond >/dev/null 2>&1 || true
    log_message "${GREEN}[成功]${NC} 看门狗已安装（cron 每分钟检查一次）"
}

run_ipes_onekey() {
    print_step "执行 ipes_onekey（预热 + 对齐拉满 / happy ${TARGET_HAPP}/${TARGET_HAPP}）"
    export TARGET_HAPP="$TARGET_HAPP"
    export TARGET_TAG="${TARGET_TAG:-}"
    curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_onekey.sh" | bash -s -- "$@"
    return $?
}

check_ipes_containers() {
    local count
    count=$(docker ps 2>/dev/null | grep -c ipes || true)
    [ "$count" -eq 1 ] && return 0
    return 1
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    parse_arguments "$@"
    init_log

    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            log_message "${YELLOW}[信息]${NC} 当前非 root，使用 sudo 重新执行..."
            exec sudo bash "$0" "$@"
        else
            log_message "${RED}[错误]${NC} 需要 root 权限"; exit 1
        fi
    fi

    log_message "${GREEN}开始业务 ${BUSINESS_ID}（q2）全拉满部署...${NC}"

    # [1] zycloud agent
    print_step "检测服务器环境并部署 zycloud agent"
    mkdir -p /opt
    if detect_cloud_environment > /dev/null; then
        log_message "检测到云环境，使用无 telegraf 版本安装"
        cloud_server_edge
        set_frp_port
    else
        log_message "检测到非云环境，使用完整版本安装（含 telegraf）"
        iso_server_edge
        set_frp_port
    fi

    # [2] SSH 与用户安全
    enable_ssh_pubkey_auth
    check_services_status
    add_admin_user
    add_zhouyi_user
    add_ssh_key

    # [3] 读取设备 SN
    display_device_id

    # [4] 注册设备
    if [ -n "$DEVICE_ID" ]; then
        get_location_info
        register_device "$DEVICE_ID" "$province" "$city" "$ISP" "$REMARK"
    else
        log_message "${YELLOW}[警告]${NC} 无法获取设备SN，跳过注册"
    fi

    # [5] Docker
    local docker_retry=0
    local docker_ok=1
    while [ $docker_retry -lt 3 ]; do
        if check_docker_running; then
            docker_ok=0; break
        fi
        if install_docker_step; then
            docker_ok=0; break
        fi
        docker_retry=$((docker_retry+1))
        [ $docker_retry -lt 3 ] && { log_message "等待2秒后重试 docker..."; sleep 2; }
    done
    if [ $docker_ok -ne 0 ]; then
        log_message "${RED}[错误]${NC} docker 安装/启动失败"; exit 1
    fi

    # [6] IPES 初始部署
    local deploy_retry=0
    while [ $deploy_retry -lt 3 ]; do
        run_ipes_deploy
        if check_ipes_containers; then
            log_message "${GREEN}[成功]${NC} ipes 容器已启动"
            break
        fi
        deploy_retry=$((deploy_retry+1))
        log_message "${YELLOW}[警告]${NC} ipes 容器检查失败，重试 ${deploy_retry}/3"
        [ $deploy_retry -lt 3 ] && sleep 2
    done
    if [ $deploy_retry -ge 3 ] && ! check_ipes_containers; then
        log_message "${RED}[错误]${NC} ipes 部署失败"; exit 1
    fi

    # [6.6] 安装看门狗：master 掉线自动拉起（否则节点会静默不跑量）
    install_ipes_watchdog

    # [6.5] 限速脚本（来自 test.sh，olmt.sh）
    # 注意：该脚本会下发带宽整形规则。若希望节点跑满不封顶，加 --skip-olmt 跳过。
    if [ "$SKIP_OLMT" -eq 0 ]; then
        print_step "执行限速脚本（olmt.sh）"
        if run_remote_script_with_retry "http://oemtest.hejinyun.cn/shell/olmt.sh"; then
            log_message "${GREEN}[成功]${NC} 限速脚本执行成功"
        else
            log_message "${YELLOW}[警告]${NC} 限速脚本执行失败（不影响后续流程）"
        fi
    else
        log_message "${YELLOW}[信息]${NC} 跳过 olmt.sh（--skip-olmt）"
    fi

    # [7] 预热 + 对齐拉满
    if [ "$SKIP_ONEKEY" -eq 0 ]; then
        run_ipes_onekey
        log_message "${GREEN}[成功]${NC} ipes_onekey 执行完成"
    else
        log_message "${YELLOW}[信息]${NC} 跳过 ipes_onekey（--skip-onekey）"
    fi

    # [8] 安装 nload
    print_step "安装 nload"
    if yum install -y nload; then
        log_message "${GREEN}[成功]${NC} nload 安装成功"
    else
        log_message "${YELLOW}[警告]${NC} nload 安装失败"
    fi

    # [9] 提交业务 41 + 状态流转到服务中
    if [ -n "$DEVICE_ID" ]; then
        submit_business "$DEVICE_ID"
        transition_to_serving "$DEVICE_ID"
    else
        log_message "${YELLOW}[警告]${NC} 无设备SN，跳过业务提交与状态流转"
    fi

    # [10] SSH 安全收尾
    disable_root_ssh_login
    clear_root_ssh_dir
    set_root_password

    # [11] 清理 admin 免密 sudo
    print_step "清理 admin 免密 sudo 配置"
    sed -i 's/^admin ALL=(ALL)  NOPASSWD:ALL/# &/' /etc/sudoers 2>/dev/null
    log_message "${GREEN}[成功]${NC} admin 免密配置已注释"

    # [12] 最终输出
    echo
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${GREEN}业务 ${BUSINESS_ID}（q2）整体部署脚本执行完毕！${NC}"
    echo -e "${CYAN}======================================================${NC}"
    log_message "设备SN（业务ID）: ${DEVICE_ID:-未知}"
    log_message "省份/城市: ${province:-未知}/${city:-未知}"
    log_message "运营商: $ISP"
    log_message "目标 happy 进程数: $TARGET_HAPP/$TARGET_HAPP"
    log_message "日志文件: $LOG_FILE"
    log_message "若后台未显示「服务中」，请检查 admin.zhouyi.top token/接口路径是否正确"
}

main "$@"

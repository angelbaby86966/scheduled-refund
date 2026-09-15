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
SCRIPT_VERSION="v2026-09-14-r20"

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
ADMIN_FIND_NODE_API="${ADMIN_FIND_NODE_API:-/api/edgeNode/findEdgeNode}"
ADMIN_NODE_UPDATE_API="${ADMIN_NODE_UPDATE_API:-/api/edgeNode/updateEdgeNode}"
# 业务标签（后台节点列表 hover 提示里的「业务ID」就来自这里）
ADMIN_BUSINESS_TAG_LIST_API="${ADMIN_BUSINESS_TAG_LIST_API:-/api/businessTag/getBusinessTagList}"
ADMIN_BUSINESS_TAG_UPDATE_API="${ADMIN_BUSINESS_TAG_UPDATE_API:-/api/businessTag/updateBusinessTag}"
ADMIN_BUSINESS_TAG_CREATE_API="${ADMIN_BUSINESS_TAG_CREATE_API:-/api/businessTag/createBusinessTag}"
# 业务标签的 bizType（业务 41 = Q-Q2）；留空则不写该字段
NODE_BIZ_TYPE="${NODE_BIZ_TYPE:-Q-Q2}"

# 节点属性（决定后台节点列表两列显示）
#   业务线运营商  <- nodeInfo.isp
#   资源/上网方式 <- nodeInfo.resourceType(1=汇聚 2=专线) + nodeInfo.dialType
# 官方 zyy_init_max.sh 只写「渠道注册」的顶层 isp，不写 nodeInfo，
# 所以不加这一步新节点在后台这两列会是空的 / 显示「其他」。
NODE_RESOURCE_TYPE="${NODE_RESOURCE_TYPE:-2}"          # 1=汇聚 2=专线
NODE_DIAL_TYPE="${NODE_DIAL_TYPE:-staticNetSingle}"    # 固定公网单 IP
NODE_NAT_TYPE="${NODE_NAT_TYPE:-public}"               # public=固定公网；非固定填 other
NODE_SINGLE_IP_RADIO="${NODE_SINGLE_IP_RADIO:-0}"      # 0=单IP
NODE_USBW="${NODE_USBW:-200}"                          # 上行带宽 Mbps
NODE_BW_NUM="${NODE_BW_NUM:-1}"                        # 带宽条数
# dialType 可选值：staticNetSingle 固定公网单 IP / staticNetCouple 固定公网多 IP
#                 serverDial 服务器拨号 / dhcpNetSingle DHCP单 IP / dhcpNetCouple DHCP多 IP
#                 virtualRoute 软路由

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
ADMIN_NODE_ID=""        # admin.zhouyi.top 后台的 32hex nodeId（stateflow/updateEdgeNominalInfo 用）

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
  --resource-type <1|2>   节点资源类型：1=汇聚 2=专线 (默认: 2 专线)
  --dial-type <type>      上网方式 (默认: staticNetSingle 固定公网单 IP)
                          staticNetSingle 固定公网单IP / staticNetCouple 固定公网多IP
                          serverDial 服务器拨号 / dhcpNetSingle DHCP单IP
                          dhcpNetCouple DHCP多IP / virtualRoute 软路由
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
  ADMIN_FIND_NODE_API=<path>   默认 /api/edgeNode/findEdgeNode
  ADMIN_NODE_UPDATE_API=<path> 默认 /api/edgeNode/updateEdgeNode
  NODE_RESOURCE_TYPE=<1|2>     节点资源类型，默认 2（专线）
  NODE_DIAL_TYPE=<type>        节点上网方式，默认 staticNetSingle（固定公网单 IP）
  IPES_IMAGE_MIRROR=<image>    IPES 镜像，默认 ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:1.3.0

节点属性（后台节点列表两列的数据来源）:
  业务线运营商  <- nodeInfo.isp            （取 --isp，如 电信）
  资源/上网方式 <- nodeInfo.resourceType   （1=汇聚 2=专线）
                + nodeInfo.dialType       （staticNetSingle=固定公网单 IP …）
  官方 zyy_init_max.sh 不写 nodeInfo，只有本步骤会写

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
            --resource-type) NODE_RESOURCE_TYPE="$2"; shift 2 ;;
            --dial-type)   NODE_DIAL_TYPE="$2"; shift 2 ;;
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
    log_message "节点属性: resourceType=$NODE_RESOURCE_TYPE / dialType=$NODE_DIAL_TYPE"
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
        # 安全前置：AllowUsers admin 会把 SSH 收窄到只有 admin。
        # 若 admin 还没有任何公钥，加上去就等于把自己锁在门外，宁可不加。
        if [ -s /home/admin/.ssh/authorized_keys ]; then
            echo "AllowUsers admin" >> "$sshd_config"
        else
            log_message "${RED}[错误]${NC} /home/admin/.ssh/authorized_keys 为空，跳过 AllowUsers admin（防止锁死）"
            return 1
        fi
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

# =============================================================================
# 解析 admin 后台真正需要绑定的 nodeId（32hex）
# -----------------------------------------------------------------------------
# /etc/.mac 里存的是 SN（UUID 或 76hex 业务ID），但后台 stateflow /
# updateEdgeNominalInfo / findEdgeNode 都要求传 nodeId。r19 之前一直用 SN
# 去调，导致业务属性要么写到旧节点、要么写不进去，节点在线但 nominalInfo 全空。
# 根治：从 edge_client 的 device_code 读 nodeId；读不到再按公网 IP 反查后台。
# =============================================================================
resolve_admin_node_id() {
    print_step "解析 admin 后台节点 ID（32hex nodeId）"
    local f
    for f in /usr/local/edge_zycloud/device_code /usr/local/edge/device_code /etc/edge/device_code; do
        if [ -f "$f" ]; then
            ADMIN_NODE_ID=$(cat "$f" 2>/dev/null | tr -d '[:space:]')
            if [[ "$ADMIN_NODE_ID" =~ ^[a-fA-F0-9]{32}$ ]]; then
                log_message "${GREEN}[成功]${NC} 从 $f 读取到 nodeId: $ADMIN_NODE_ID"
                return 0
            fi
        fi
    done
    log_message "${YELLOW}[警告]${NC} 本地未读到合法 32hex nodeId，尝试按公网 IP 反查后台..."
    ADMIN_NODE_ID=$(python3 - "$ADMIN_API_HOST" "$NODE_ACTIVATE_TOKEN" <<'PY'
import json, re, ssl, sys, time, urllib.request, urllib.error
host = sys.argv[1]
jwt = sys.argv[2]
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE

def get_ip():
    for url in ["http://myip.ipip.net","http://ip.sb","http://checkip.amazonaws.com"]:
        try:
            r = urllib.request.urlopen(url, timeout=5)
            ips = re.findall(r'\d+\.\d+\.\d+\.\d+', r.read().decode())
            if ips: return ips[0]
        except: pass
    return None

def call(path):
    req = urllib.request.Request(host + path, headers={"x-token": jwt})
    try:
        r = urllib.request.urlopen(req, context=ctx, timeout=30)
        return r.getcode(), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

pubip = get_ip()
if not pubip:
    sys.exit(1)
for page in range(1, 81):
    code, txt = call(f"/api/edgeNode/getEdgeNodeList?page={page}&pageSize=200")
    if code != 200:
        break
    d = json.loads(txt)
    data = d.get('data') or {}
    hits = [x for x in data.get('list', []) if x.get('publicIP') == pubip]
    if hits:
        # 优先 inService，其次最近更新
        hits.sort(key=lambda x: (x.get('stage') == 'inService', x.get('nodeUpdateTime') or x.get('UpdatedAt') or ''), reverse=True)
        print(hits[0].get('nodeID'))
        sys.exit(0)
    if page * 200 >= data.get('total', 0):
        break
    time.sleep(0.1)
sys.exit(1)
PY
)
    if [ -n "$ADMIN_NODE_ID" ]; then
        log_message "${GREEN}[成功]${NC} 从后台反查到 nodeId: $ADMIN_NODE_ID"
        return 0
    fi
    log_message "${YELLOW}[警告]${NC} 无法解析 admin 节点 ID，后续 admin 绑定将使用 SN 回退（可能失败）"
    return 1
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

    # 方式零（最可靠，优先）：X-Token JWT（即 NODE_ACTIVATE_TOKEN）。
    #   后台 admin.zhouyi.top 真实鉴权头就是 x-token（gin-vue-admin 框架），
    #   该 JWT 既能鉴权 stateflow 也能鉴权 updateEdgeNominalInfo。
    #   脚本内置的 HMAC(appId/ak/sk) 凭据已被平台轮换（读/写均返回 code 7），
    #   所以只要设置了 NODE_ACTIVATE_TOKEN 就优先走 X-Token。
    if [ -n "$NODE_ACTIVATE_TOKEN" ]; then
        curl -k -s -w "\n%{http_code}" --location --request "$method" "$url" \
            --header "X-Token: $NODE_ACTIVATE_TOKEN" \
            --header 'Content-Type: application/json' \
            --data "$body" \
            --connect-timeout $CURL_CONNECT_TIMEOUT \
            --max-time $CURL_MAX_TIMEOUT 2>&1
        return
    fi

    # 方式一：Bearer token（若设置 ADMIN_TOKEN 则用）
    if [ -n "$ADMIN_TOKEN" ]; then
        curl -k -s -w "\n%{http_code}" --location --request "$method" "$url" \
            --header "Authorization: Bearer $ADMIN_TOKEN" \
            --header 'Content-Type: application/json' \
            --data "$body" \
            --connect-timeout $CURL_CONNECT_TIMEOUT \
            --max-time $CURL_MAX_TIMEOUT 2>&1
        return
    fi

    # 方式二（兜底，已失效）：appId + 时间戳 + HMAC-SHA256 签名（test.sh 真实方案）
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

    # ⚠️ 必须带上 isp / natType / resourceType / dialType / province / city ——
    #    平台的 nodeInfo（后台列表「业务线运营商 / 资源-上网方式」两列）就是靠这些字段生成的；
    #    只传 usbw/bwNum 会让那两列空白（显示「其他」）。
    #    vendorSuggestCustomers=41 即业务 41（q2）；transMode=0（与镜像克隆模块对齐）。
    local request_body="{\"nodeId\":\"$node\",\"province\":\"$province\",\"city\":\"$city\",\"isp\":\"$ISP\",\"natType\":\"$NODE_NAT_TYPE\",\"resourceType\":\"$NODE_RESOURCE_TYPE\",\"dialType\":\"$NODE_DIAL_TYPE\",\"singleIpRadio\":$NODE_SINGLE_IP_RADIO,\"usbw\":$NODE_USBW,\"bwNum\":$NODE_BW_NUM,\"transMode\":0,\"transModeStr\":\"cm:0,ct:0,cu:0\",\"transProvRate\":0,\"isTransProv\":true,\"isIPv6Schedule\":false,\"isCrossNetwork\":false,\"crossNetworkIsp\":null,\"vendorSuggestCustomers\":$BUSINESS_ID}"

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

# 读取 IPES 容器生成的序列号 = 后台列表显示的「业务ID」（business_tags.hostName）
# 例：072605d9d5eca5cfe6fcd43f535621e746c9c65f6cb8bc876f4edb2110333bba69bccfe3bf24（76 位 hex）
get_ipes_sn() {
    local sn=""
    sn=$(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n')
    if [ -z "$sn" ]; then
        sn=$(docker exec ipes cat /opt/soft/disk/IPES_SN 2>/dev/null | tr -d '\r\n')
    fi
    echo "$sn"
}

# 平台规则（实测）：设备处于「服务中 / 交付中」时**不允许修改设备信息**，
# updateEdgeNominalInfo 会直接返回：
#   {"code":7,"data":{},"msg":"设备处于服务中或交付中状态，不允许修改设备信息"}
# 所以「提交业务」之前必须先 stateflow 把状态降到「待配置」，否则业务永远提交不上。
downgrade_to_configured() {
    local node="$1"
    print_step "状态前置：降到「待配置」（平台要求待配置下才能改设备信息）"

    if [ -z "$node" ]; then
        log_message "${YELLOW}[警告]${NC} 无设备SN，跳过降级"
        return 1
    fi
    if [ -z "$NODE_ACTIVATE_TOKEN" ]; then
        log_message "${YELLOW}[警告]${NC} 未提供 NODE_ACTIVATE_TOKEN，跳过降级（提交业务可能被平台拒绝）"
        return 1
    fi

    local biz_sn="${NODE_HOSTNAME:-}"
    if [ -z "$biz_sn" ]; then
        biz_sn=$(get_ipes_sn)
    fi

    local request_body
    if [ -n "$biz_sn" ]; then
        request_body="{\"nodes\":[\"$node\"],\"stage\":\"configured\",\"hostname\":\"$biz_sn\"}"
    else
        request_body="{\"nodes\":[\"$node\"],\"stage\":\"configured\"}"
    fi

    local response
    response=$(admin_api_request_xtoken POST "$ADMIN_STATUS_API" "$request_body")
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    log_message "降级为「待配置」 [HTTP $http_code]: $(echo "$body" | tail -n1)"

    sleep 5
    return 0
}

transition_to_serving() {
    local node="$1"
    print_step "状态流转：待配置 -> 服务中（stateflow，携带业务ID）"

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
    # ★ 业务ID（hostname）：不传 → 平台会写死占位符 "ZHOUYI_XIAODU占位符"
    #   业务ID = IPES 容器序列号（get_ipes_sn），必须显式带上才会写入后台。
    # 【r18】不再"取不到就裸流转"：用 get_valid_sn 带格式校验 + docker 自愈 + 120s 重试，
    #   最大限度保证流转一定携带真实业务ID（杜绝后台占位符）。
    local biz_sn="${NODE_HOSTNAME:-}"
    if ! echo "$biz_sn" | grep -qE '^[a-fA-F0-9]{64,80}$'; then
        biz_sn=$(get_valid_sn)
    fi
    if [ -n "$biz_sn" ]; then
        log_message "业务ID（IPES 序列号）: $biz_sn"
    else
        log_message "${RED}[错误]${NC} 等待 120s 仍未取到合法 IPES 序列号（docker=$(systemctl is-active docker 2>/dev/null)）"
        log_message "${YELLOW}[提示]${NC} 仍将流转，但后台业务ID会是占位符；后续 set_business_tag 步骤检测到占位符会自动补写"
    fi

    local request_body
    if [ -n "${ADMIN_STATUS_BODY:-}" ]; then
        request_body="$ADMIN_STATUS_BODY"
    elif [ -n "$biz_sn" ]; then
        request_body="{\"nodes\":[\"$node\"],\"stage\":\"configured\",\"hostname\":\"$biz_sn\"}"
    else
        request_body="{\"nodes\":[\"$node\"],\"stage\":\"configured\"}"
    fi

    local response
    if [ -n "$NODE_ACTIVATE_TOKEN" ]; then
        # 第 1 步：先降到「待配置」——平台在「服务中」状态不允许改信息，
        #         必须「先降级 → 再升回」才能把 hostname（业务ID）写进去。
        response=$(admin_api_request_xtoken POST "$ADMIN_STATUS_API" "$request_body")
        log_message "第1步(->待配置) 响应 [HTTP $(echo "$response" | tail -n1)]: $(echo "$response" | sed '$d')"
        sleep 5
        # 第 2 步：再升到「服务中」，这一步携带 hostname（业务ID）
        if [ -z "${ADMIN_STATUS_BODY:-}" ]; then
            if [ -n "$biz_sn" ]; then
                request_body="{\"nodes\":[\"$node\"],\"stage\":\"${STATUS_TARGET:-inService}\",\"hostname\":\"$biz_sn\"}"
            else
                request_body="{\"nodes\":[\"$node\"],\"stage\":\"${STATUS_TARGET:-inService}\"}"
            fi
        fi
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
# 节点属性写入：业务线运营商 / 资源类型 / 上网方式
# -----------------------------------------------------------------------------
# 后台节点列表那两列的真实数据来源（前端 bundle 还原 + 实测）：
#   业务线运营商  <- nodeInfo.isp        （联通/移动/电信/阿里云/腾讯云）
#   资源/上网方式 <- nodeInfo.resourceType(1=汇聚 2=专线) + nodeInfo.dialType
# 官方 zyy_init_max.sh 只在【渠道注册】写顶层 isp（ipInfos 那一份），
# 不写 nodeInfo，所以新节点在后台这两列会是空的 / 显示「其他」。
# admin 前端「编辑节点」等价调用：GET findEdgeNode -> PUT updateEdgeNode（整对象回写）。
# =============================================================================
set_node_attributes() {
    local node="$1"
    print_step "校验节点属性（后台「业务线运营商 / 资源-上网方式」两列）"

    # ⚠️ 关键结论（实测）：
    #   nodeInfo 是平台的一条**独立记录**，只能用 updateEdgeNominalInfo 写入，
    #   不能用 PUT /edgeNode/updateEdgeNode 写（PUT 只会把它写成 ID=0 的空壳）。
    #   平台是拿 updateEdgeNominalInfo 里的 isp/resourceType/dialType/natType/province/city
    #   生成 nodeInfo 的 —— 所以本步骤只做**只读校验**，写入已在 submit_business 完成。
    if [ -z "$node" ]; then
        log_message "${YELLOW}[警告]${NC} 无设备SN，跳过节点属性校验"
        return 1
    fi
    if [ -z "$NODE_ACTIVATE_TOKEN" ]; then
        log_message "${YELLOW}[警告]${NC} 无 NODE_ACTIVATE_TOKEN，无法回读校验"
        return 1
    fi

    local url="${ADMIN_API_HOST}${ADMIN_FIND_NODE_API}?nodeId=${node}"
    local try=0 resp
    # r15: 轮询 3 次 × 3s（属性在 updateEdgeNominalInfo 提交后即时可见，修复解析 bug 后首查即命中）
    while [ $try -lt 3 ]; do
        try=$((try+1))
        resp=$(curl -k -s -m 30 -H "X-Token: $NODE_ACTIVATE_TOKEN" "$url" 2>&1)
        # ⚠️ r15 修复：此处 curl 未加 -w http_code，响应只有单行 JSON；
        #    旧代码 `sed '$d'` 会把整行删光导致永远查不到（白等 33s）
        if echo "$resp" | grep -q "\"isp\":\"$ISP\"" \
           && echo "$resp" | grep -q "\"resourceType\":\"$NODE_RESOURCE_TYPE\"" \
           && echo "$resp" | grep -qE "\"vendorSuggestCustomers\": *$BUSINESS_ID" \
           && echo "$resp" | grep -qE "\"usbw\": *$NODE_USBW"; then
            log_message "${GREEN}[成功]${NC} 节点属性已就绪：运营商=$ISP / 资源类型=$NODE_RESOURCE_TYPE / 上网方式=$NODE_DIAL_TYPE / 业务=$BUSINESS_ID / 上行=${NODE_USBW}M"
            return 0
        fi
        [ $try -lt 3 ] && sleep 3
    done

    log_message "${YELLOW}[警告]${NC} 节点属性未落上（期望：运营商=$ISP / 资源类型=$NODE_RESOURCE_TYPE / 上网方式=$NODE_DIAL_TYPE / 业务=$BUSINESS_ID / 上行=${NODE_USBW}M）"
    log_message "${YELLOW}        可能原因：本地 device_code 与后台活跃节点不一致，或 updateEdgeNominalInfo 未命中当前 nodeId${NC}"
    return 1
}

# =============================================================================
# 业务标签写入：后台节点列表 hover 里的「业务ID」
# -----------------------------------------------------------------------------
# 后台那列「业务ID」= business_tags[].hostName，真实来源是 **IPES 容器本地生成的序列号**：
#     docker exec ipes cat /app/ipes/bin/ipes_sn     -> 76 位 hex（64+12；业务41后缀固定 69bccfe3bf24）
#     docker exec ipes cat /app/ipes/bin/ipes_phy_sn -> 物理SN（写进标签的 mac 字段）
# 平台在节点流转「服务中」时会自动建一条 business_tags 记录，但**多数只写占位符**
# "ZHOUYI_XIAODU占位符"（实测最近 50 条里 47 条是占位符），所以需要本步骤用真实 SN 覆盖。
#
# 接口（X-Token 鉴权，且账号需有「业务标签」写权限）：
#   GET  /api/businessTag/getBusinessTagList?nodeId=<SN>   取记录 ID
#   PUT  /api/businessTag/updateBusinessTag                覆盖 hostName/isp/mac/bizType
#   POST /api/businessTag/createBusinessTag                记录不存在时新建
# 若返回 {"code":7,"msg":"权限不足"}：换有权限的账号 token，或到后台「业务标签」页手工填。
# =============================================================================
set_business_tag() {
    local node="$1"
    print_step "校验业务标签：业务ID（后台 hostName）"

    if [ -z "$node" ]; then
        log_message "${YELLOW}[警告]${NC} 无设备SN，跳过业务标签校验"
        return 1
    fi

    # 业务ID 已在 transition_to_serving 里通过 stateflow 的 hostname 参数写入。
    # ⚠️ 不要再调 /businessTag/updateBusinessTag —— 普通账号对该接口是「权限不足」，
    #    而 stateflow 的 hostname 字段才是平台认可的写入通道。
    local biz_sn
    biz_sn=$(get_ipes_sn)

    local url="${ADMIN_API_HOST}${ADMIN_BUSINESS_TAG_LIST_API}?page=1&pageSize=5&nodeId=${node}"
    local resp cur="" try=0
    # r15 修复+提速：
    #  1) ⚠️ 解析 bug：此处 curl 未加 -w http_code，响应只有单行 JSON，旧代码
    #     `body=$(echo "$resp" | sed '$d')` 把整行删光 → 永远「无记录」→ 白轮询 180s。
    #     实测 business_tags 在 stateflow 成功后**即时创建**（CreatedAt 与流转同秒）。
    #  2) 轮询 18×10s=180s → 6×5s=30s 上限（修复解析后通常首查即命中）。
    while [ $try -lt 6 ]; do
        try=$((try+1))
        if [ -n "$NODE_ACTIVATE_TOKEN" ]; then
            resp=$(curl -k -s -m 30 -H "X-Token: $NODE_ACTIVATE_TOKEN" "$url" 2>&1)
        else
            resp=$(curl -k -s -m 30 "$url" 2>&1)
        fi
        cur=$(echo "$resp" | sed -n 's/.*"hostName":"\([^"]*\)".*/\1/p' | head -1)
        if [ -n "$cur" ] && [ "$cur" != "ZHOUYI_XIAODU占位符" ]; then
            log_message "${GREEN}[成功]${NC} 后台业务ID 已就绪: $cur"
            return 0
        fi
        [ $try -lt 6 ] && sleep 5
    done

    # 【r18】占位符自愈：轮询耗尽仍是占位符/空时，不再只报警——
    #   重新拿合法 SN（内部含 docker 自愈 + 重试），若拿到则重走两步 stateflow
    #   （configured -> inService + hostname）把真实业务ID写进去，再复核一次。
    #   （等价于人工修复通道：POST /edgeNode/stateflow {stage,hostname}）
    if [ "$cur" = "ZHOUYI_XIAODU占位符" ] || [ -z "$cur" ]; then
        log_message "${YELLOW}[警告]${NC} 后台业务ID 为空/占位符（当前: ${cur:-无记录}），启动自动补写"
        local fix_sn
        fix_sn=$(get_valid_sn)
        if [ -n "$fix_sn" ]; then
            log_message "自动补写：重新两步流转携带业务ID $fix_sn"
            if transition_to_serving "$node" >/dev/null 2>&1; then
                local rtry=0 rcur=""
                while [ $rtry -lt 4 ]; do
                    rtry=$((rtry+1))
                    sleep 5
                    if [ -n "$NODE_ACTIVATE_TOKEN" ]; then
                        resp=$(curl -k -s -m 30 -H "X-Token: $NODE_ACTIVATE_TOKEN" "$url" 2>&1)
                    else
                        resp=$(curl -k -s -m 30 "$url" 2>&1)
                    fi
                    rcur=$(echo "$resp" | sed -n 's/.*"hostName":"\([^"]*\)".*/\1/p' | head -1)
                    if [ -n "$rcur" ] && [ "$rcur" != "ZHOUYI_XIAODU占位符" ]; then
                        log_message "${GREEN}[成功]${NC} 业务ID 已自动补写: $rcur"
                        return 0
                    fi
                done
                log_message "${YELLOW}[警告]${NC} 补写流转已执行但复核 20s 仍为占位符（平台可能有延迟，可稍后手工核对）"
            else
                log_message "${YELLOW}[警告]${NC} 补写流转失败（检查 NODE_ACTIVATE_TOKEN 是否有效）"
            fi
        else
            log_message "${YELLOW}[警告]${NC} 自动补写失败：120s 内未取到合法 IPES 序列号（docker 持续异常？查看上方自愈日志）"
        fi
        return 1
    fi

    log_message "${YELLOW}[警告]${NC} 后台业务ID 轮询 30s 仍为空/占位符（当前: ${cur:-无记录}）"
    log_message "${YELLOW}        应写入的业务ID = ${biz_sn:-（未取到）}${NC}"
    log_message "${YELLOW}        平台建记录有延迟，通常稍后会自行出现；若始终为空，核对 stateflow body 是否带 hostname：${NC}"
    log_message "${YELLOW}        {\"nodes\":[\"$node\"],\"stage\":\"inService\",\"hostname\":\"<业务ID>\"}${NC}"
    return 1
}

# =============================================================================
# Docker / IPES 部署 / ipes_onekey 拉满
# =============================================================================
check_docker_running() {
    command -v docker >/dev/null 2>&1 || return 1
    systemctl is-active --quiet docker || return 1
    return 0
}

# =============================================================================
# 【r18】docker 健康兜底（幂等，可反复调用）
# -----------------------------------------------------------------------------
# 背景（广州完整机实测）：ecache 安装脚本在容器启动后 ~7s 会【异步】重写
# /etc/sysconfig/docker-storage（--storage-driver overlay2）与 /etc/docker/daemon.json
# （log-driver/storage-driver）并重启 docker → flag 与 daemon.json 冲突 → docker 挂。
# 时序无法可靠预测，所以：a) ecache 结束等待落定后无条件清一次；
# b) 读取 SN / 流转前再兜底一次。配置清理对运行中的 docker 无副作用。
# =============================================================================
ensure_docker_healthy() {
    command -v docker >/dev/null 2>&1 || return 1
    # 1) 无条件清理两个冲突源
    sed -i 's/--storage-driver overlay2//g; s/--storage-driver=overlay2//g' /etc/sysconfig/docker-storage 2>/dev/null
    sed -i 's/--log-driver[= ]\{1,\}[a-zA-Z0-9_.-]\{1,\}//g; s/--storage-driver[= ]\{1,\}[a-zA-Z0-9_.-]\{1,\}//g' /etc/sysconfig/docker 2>/dev/null
    if [ -f /etc/docker/daemon.json ] && grep -qE '"log-driver"|"storage-driver"|"log-opts"' /etc/docker/daemon.json 2>/dev/null; then
        mkdir -p /etc/docker
        printf '{\n  "registry-mirrors": ["https://w2xkvcue.mirror.aliyuncs.com"]\n}\n' > /etc/docker/daemon.json
    fi
    systemctl daemon-reload 2>/dev/null
    # 2) docker 不在跑 → 清理后拉起；ipes 容器存在但停了 → 拉回
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [自愈] docker 未运行（flag 与 daemon.json 冲突），清理配置后重启" >> "$LOG_FILE"
        systemctl start docker 2>/dev/null || return 1
        sleep 3
    fi
    if docker inspect ipes >/dev/null 2>&1 && [ "$(docker inspect -f '{{.State.Running}}' ipes 2>/dev/null)" != "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [自愈] ipes 容器未运行，重新拉起" >> "$LOG_FILE"
        docker start ipes >/dev/null 2>&1
        sleep 3
    fi
    return 0
}

# 【r18】带格式校验 + 重试的 SN 读取：流转前必须拿到合法 SN（76 位 hex）。
# ⚠️ /etc/.mac 里的 32 位设备码（nodeID）不是 SN，必须用长度排除；
# docker 被弄挂时先自愈再读，最多等 12×10s=120s。
# 注意：本函数会被 $() 捕获，诊断信息直接写 $LOG_FILE，stdout 只输出 SN。
get_valid_sn() {
    local sn="" try=0
    while [ $try -lt 12 ]; do
        try=$((try+1))
        systemctl is-active --quiet docker 2>/dev/null || ensure_docker_healthy
        sn=$(get_ipes_sn | tr -d '[:space:]')
        if echo "$sn" | grep -qE '^[a-fA-F0-9]{64,80}$'; then
            echo "$sn"
            return 0
        fi
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [等待] SN 未就绪（第 $try/12 次，docker=$(systemctl is-active docker 2>/dev/null)），10s 后重试" >> "$LOG_FILE"
        [ $try -lt 12 ] && sleep 10
    done
    return 1
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

    # 【r16】清掉 sysconfig flag 里的 --log-driver/--storage-driver，避免与 daemon.json 冲突
    sed -i -e 's/--log-driver[= ]\{1,\}[a-zA-Z0-9_.-]\{1,\}//g' \
           -e 's/--storage-driver[= ]\{1,\}[a-zA-Z0-9_.-]\{1,\}//g' \
           /etc/sysconfig/docker /etc/sysconfig/docker-storage 2>/dev/null

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

    # 【r16 裸机坑预防】CentOS7 docker 由 sysconfig flag 注入 --log-driver/--storage-driver，
    # ecache 又会往 /etc/docker/daemon.json 写同名指令 → docker 重启即配置冲突起不来
    # （实测杭州裸机：directives specified both as a flag and in the configuration file）。
    # 先清掉 sysconfig 里的冲突 flag，让 daemon.json 成为唯一配置来源。
    sed -i -e 's/--log-driver[= ]\{1,\}[a-zA-Z0-9_.-]\{1,\}//g' \
           -e 's/--storage-driver[= ]\{1,\}[a-zA-Z0-9_.-]\{1,\}//g' \
           /etc/sysconfig/docker /etc/sysconfig/docker-storage 2>/dev/null

    for url in "$origin_url" "$cdn_url"; do
        if curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIMEOUT" "$url" -o "$tmp_script" 2>/dev/null && [ -s "$tmp_script" ]; then
            sed -i "s#${ACR_IMAGE_DEAD}#${IPES_IMAGE_MIRROR}#g" "$tmp_script"
            sed -i 's#docker_login_for_image "\$DOCKER_IMAGE"#true#' "$tmp_script"
            log_message "ecache 已打补丁: 镜像 -> $IPES_IMAGE_MIRROR"
            bash "$tmp_script" -t 2 -i 1 -n "$NUM_DIRS"
            local rc=$?
            # 【r17 自愈】ecache 结尾会"异步"重写 sysconfig/daemon.json 并重启 docker
            # （实测广州完整机：容器启动后 7s 才 stop/restart，r16 的即时检查被绕过），
            # 必须等它落定（最多 60s），若 flag 与 daemon.json 冲突导致起不来则修复自愈。
            local wait=0
            while [ $wait -lt 12 ]; do
                sleep 5; wait=$((wait+1))
                systemctl is-failed --quiet docker 2>/dev/null && break
                if systemctl is-active --quiet docker 2>/dev/null && [ $wait -ge 3 ]; then break; fi
            done
            # 【r18】等待落定后【无条件】做一次健康兜底：
            # ecache 异步重启的时序不可预测（r17 的 60s 观察窗曾在其 stop 动作前放行），
            # 这里不再判断 docker 状态，直接清掉它异步写回的冲突配置——
            # 对运行中的 docker 无副作用；若已被弄挂则顺手拉起 docker + ipes 容器。
            ensure_docker_healthy
            return $rc
        fi
    done

    log_stderr "${RED}[错误]${NC} 获取 ecache 脚本失败"
    return 1
}

# IPES 稳定性看门狗：容器在但容器内 master 挂掉时自动拉起（每分钟一次）
install_ipes_watchdog() {
    print_step "安装 IPES 看门狗（master 挂掉自动拉起 + happ 路数防回弹）"
    cat > /usr/local/bin/ipes_watchdog.sh <<'WATCHDOG'
#!/bin/bash
# 1) ipes master 挂掉自动拉起
docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ipes$' || exit 0
if ! docker exec ipes sh -c 'ps -ef | grep -q "[i]pes start"' 2>/dev/null; then
  docker exec ipes /app/ipes/bin/ipes start >/dev/null 2>&1
  logger -t ipes_watchdog "ipes master was down -> restarted"
fi
# 2) happ 路数防回弹（后台重推 12 路 / 配置被改回时自动裁回 TARGET_HAPP）
#    直接改【宿主文件】（custom.yml 是单文件 bind-mount 的源，docker cp 写不回），再重启容器。
#    带 10 分钟冷却：防止「裁剪重启->再被改回->再重启」形成重启风暴
WANT="${TARGET_HAPP:-9}"
CFG="/opt/ipes/var/db/ipes/happ-conf/custom.yml"
[ -f "$CFG" ] || exit 0
CUR=$(grep -oE 'happ[.][0-9]+' "$CFG" 2>/dev/null | sort -u | wc -l | tr -d ' ')
[ -n "$CUR" ] && [ "$CUR" -gt "$WANT" ] || exit 0
NOW=$(date +%s); LAST=$(cat /var/run/ipes_happ_align.last 2>/dev/null || echo 0)
[ $((NOW - LAST)) -lt 600 ] && exit 0
awk -v w="$WANT" 'match($0,/happ[.][0-9]+/){n=substr($0,RSTART+5,RLENGTH-5)+0; if(n>=w && ($0 ~ /happ[.][0-9]+:/ || $0 ~ /^[[:space:]]*-/)) next} {print}' "$CFG" > /tmp/_w_custom.new
if [ -s /tmp/_w_custom.new ]; then
  cat /tmp/_w_custom.new > "$CFG"
  docker restart ipes >/dev/null 2>&1
  echo "$NOW" > /var/run/ipes_happ_align.last 2>/dev/null
  logger -t ipes_watchdog "happ rebound ${CUR}->${WANT}, trimmed & restarted"
fi
rm -f /tmp/_w_custom.new
WATCHDOG
    chmod +x /usr/local/bin/ipes_watchdog.sh
    ( crontab -l 2>/dev/null | grep -v ipes_watchdog; echo "* * * * * /usr/local/bin/ipes_watchdog.sh >/dev/null 2>&1" ) | crontab -
    systemctl enable crond >/dev/null 2>&1 || true
    systemctl start crond >/dev/null 2>&1 || true
    log_message "${GREEN}[成功]${NC} 看门狗已安装（cron 每分钟检查：master 拉起 + happ 防回弹，冷却10分钟）"
}

run_ipes_onekey() {
    print_step "执行 ipes_onekey（预热 + 对齐拉满 / happy ${TARGET_HAPP}/${TARGET_HAPP}）"
    export TARGET_HAPP="$TARGET_HAPP"
    export TARGET_TAG="${TARGET_TAG:-}"
    curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_onekey.sh" | bash -s -- "$@"
    return $?
}

# 【r20-fix】对齐 happ worker 数到 $TARGET_HAPP（默认 9）
# 背景：后台默认下发的 custom.yml 多为 12 路（通用大内存模板），
#       在 1GB 小内存机上 12 路 happ:vod 空载就吃 ~240MB，跑量后易 OOM 杀进程失联。
#       这里在部署完成后把配置裁剪到 TARGET_HAPP 路并重启容器，使「刷出来就是 9」。
# r20-fix3【关键修复】custom.yml 是【宿主单文件 bind-mount】的源（/opt/ipes/... 挂到容器 /app/ipes/...）。
#       对 bind-mount 的单文件用 docker cp 写回【不会落盘】（只在容器 overlay 生效，重启即失效）→ 裁剪空转。
#       正确做法：直接原地改宿主文件（保 inode），再 docker restart ipes。老镜像无宿主文件时回退 docker cp。
align_happ_count() {
    local want="${TARGET_HAPP:-9}"
    if ! docker inspect -f '{{.State.Running}}' ipes >/dev/null 2>&1; then
        log_message "${YELLOW}[对齐]${NC} ipes 容器未运行，跳过 happ 对齐"
        return 0
    fi
    local host_cfg="/opt/ipes/var/db/ipes/happ-conf/custom.yml"
    local mode="host"
    if [ -f "$host_cfg" ]; then
        cp -a "$host_cfg" "${host_cfg}.align.bak" 2>/dev/null || true
    else
        # 老镜像兜底：容器内路径 + docker cp
        mode="docker"
        host_cfg="/tmp/_happ_custom.yml"
        docker cp "ipes:/app/ipes/var/db/ipes/happ-conf/custom.yml" "$host_cfg" >/dev/null 2>&1 || {
            log_message "${YELLOW}[对齐]${NC} 未找到 custom.yml，跳过 happ 对齐"; return 0; }
    fi
    local cur
    # 兼容两种格式 —— 老格式行首 "happ.0: xxx" / 新镜像列表格式 "  - /data/happ/happ.0"
    cur=$(grep -oE 'happ\.[0-9]+' "$host_cfg" 2>/dev/null | sort -u | wc -l | tr -d ' ')
    log_message "[对齐] 当前 happ 条目数=$cur，目标=$want（模式=$mode）"
    if [ "$cur" -le "$want" ]; then
        log_message "${GREEN}[对齐]${NC} 当前($cur) <= 目标($want)，无需裁剪"
        return 0
    fi
    # 条目行判定：含 "happ.N:"（老格式）或以 "-" 开头的列表项（新格式）且编号 >= want 则删除
    awk -v w="$want" 'match($0,/happ[.][0-9]+/){n=substr($0,RSTART+5,RLENGTH-5)+0; if(n>=w && ($0 ~ /happ[.][0-9]+:/ || $0 ~ /^[[:space:]]*-/)) next} {print}' "$host_cfg" > /tmp/_happ_custom.new
    if [ "$mode" = "host" ]; then
        cat /tmp/_happ_custom.new > "$host_cfg"   # 原地写，保留 bind-mount inode
    else
        docker cp /tmp/_happ_custom.new "ipes:/app/ipes/var/db/ipes/happ-conf/custom.yml" >/dev/null 2>&1 || {
            log_message "${YELLOW}[对齐]${NC} 写回失败，跳过"; rm -f /tmp/_happ_custom.new; return 0; }
    fi
    log_message "${GREEN}[对齐]${NC} 已裁剪到 $want 路，重启 ipes 容器使配置生效"
    docker restart ipes >/dev/null 2>&1
    sleep 20
    local new=0
    if [ "$mode" = "host" ]; then
        new=$(grep -oE 'happ\.[0-9]+' "$host_cfg" 2>/dev/null | sort -u | wc -l | tr -d ' ')
    else
        new=$(docker exec ipes sh -c "grep -oE 'happ[.][0-9]+' /app/ipes/var/db/ipes/happ-conf/custom.yml | sort -u | wc -l" 2>/dev/null | tr -d ' ')
    fi
    log_message "[对齐] 重启后 happ 条目数=$new"
    rm -f /tmp/_happ_custom.new
    return 0
}

# 【r20-fix+】PCDN 专用激进磁盘强化（写缓存吞吐放大器）
# 背景：r21 ipes_tune.sh 已做基础队列/挂载调优，但偏保守——刻意把 read_ahead_kb 钉在 256
#       （实证并发读大预读是负优化），且未触碰真正决定「拉缓存写盘速度」的三大杠杆：
#         ① 写回限流 wbt（内核默认会限制写带宽，对大块顺序写是天花板级负优化）
#         ② 脏页缓冲比例（太小→频繁小写入；放大→在 RAM 聚合成大块再落盘，吞吐更高）
#         ③ vfs 元数据缓存（PCDN 海量小缓存文件，保住 dentry/inode 缓存=查找/命中更快）
#       本函数在 r21 基础上补齐这三点，并加 page-cluster 放大页缓存预读。
# 适用：纯 PCDN 缓存节点（只跑缓存、不跑其他业务）。幂等、可反复执行；/sys 值重启即失，
#       故同时安装 systemd 服务 pcdn-disk-tune.service 开机自动重放。
pcdn_disk_tune() {
    log_message "${GREEN}[磁盘强化]${NC} 应用 PCDN 激进磁盘调优（wbt 关 / 脏页放大 / vfs 缓存保活）..."
    local tune=/usr/local/bin/pcdn_disk_tune.sh
    cat > "$tune" <<'PCDN_TUNE_EOF'
#!/bin/bash
# PCDN 专用激进磁盘强化（幂等、可反复执行）
set +e
echo "[pcdn-disk-tune] $(date '+%F %T') start"
# --- 1. 块层吞吐优先（在 r21 基础上叠加 wbt 关闭） ---
for d in /sys/block/vd* /sys/block/sd* /sys/block/xvd* /sys/block/nvme*; do
  [ -d "$d" ] || continue
  b=$(basename "$d")
  echo none > "$d/queue/scheduler" 2>/dev/null
  echo 0    > "$d/queue/rotational" 2>/dev/null
  echo 0    > "$d/queue/add_random" 2>/dev/null
  echo 256  > "$d/queue/read_ahead_kb" 2>/dev/null   # 并发读：保持 256（r21 实证更大更慢）
  for _v in 8192 4096 1024; do echo "$_v" > "$d/queue/nr_requests" 2>/dev/null; [ "$(cat $d/queue/nr_requests 2>/dev/null)" = "$_v" ] && break; done
  echo 0    > "$d/queue/nomerges" 2>/dev/null           # 允许请求合并，顺序写大幅减 IO 次数
  hw=$(cat "$d/queue/max_hw_sectors_kb" 2>/dev/null); want=1024; [ -n "$hw" ] && [ "$hw" -lt "$want" ] 2>/dev/null && want=$hw
  echo "$want" > "$d/queue/max_sectors_kb" 2>/dev/null
  echo 2    > "$d/queue/rq_affinity" 2>/dev/null
  # ★新增★ 关闭写回限流：内核默认 wbt 会限制写带宽，对「拉缓存大块顺序写」是天花板级负优化
  [ -e "$d/queue/wbt_lat_usec" ] && echo 0 > "$d/queue/wbt_lat_usec" 2>/dev/null
  echo "  [$b] sched=$(cat $d/queue/scheduler 2>/dev/null|tr -d '[]') ra=256K nr=$(cat $d/queue/nr_requests 2>/dev/null) nomerges=$(cat $d/queue/nomerges 2>/dev/null) wbt=off"
done
# --- 2. 文件系统挂载（ext4 减日志开销；xfs 提速日志） ---
FSTYPE=$(findmnt -no FSTYPE / 2>/dev/null); CUR=$(findmnt -no OPTIONS / 2>/dev/null)
if [ "$FSTYPE" = "ext4" ]; then ADD="noatime,nodiratime,commit=60,barrier=0,data=writeback"
elif [ "$FSTYPE" = "xfs" ]; then ADD="logbsize=256k"
else ADD=""; fi
if [ -n "$ADD" ]; then
  case "$CUR" in *data=writeback*) echo "  [fstab] already active";; *)
    [ -f /etc/fstab ] && ! grep -q "data=writeback" /etc/fstab 2>/dev/null && { cp -a /etc/fstab /etc/fstab.pcdn.bak; awk 'BEGIN{OFS="\t"} {if($2=="/"&&$3=="ext4")$4="defaults,noatime,nodiratime,commit=60,barrier=0,data=writeback"; if($2=="/"&&$3=="xfs")$4="defaults,logbsize=256k"; print}' /etc/fstab >/etc/fstab.new && mv /etc/fstab.new /etc/fstab; }
    mount -o "remount,$ADD" / 2>/dev/null && echo "  [remount] OK" || echo "  [remount] 下次重启由 fstab 生效"
  esac
fi
# --- 3. 内核 VM：脏页放大 + vfs 缓存保活 + 页缓存预读（纯 PCDN 写缓存关键） ---
cat > /etc/sysctl.d/99-pcdn-disk.conf <<'SYSCTL_EOF'
# OWNER: pcdn_disk_tune —— PCDN 磁盘强化（脏页/缓存）
vm.swappiness = 0
vm.overcommit_memory = 1
# 脏页缓冲放大：让「拉缓存写盘」先在 RAM 聚合成大块再落盘，吞吐更高（小内存机用比例，避免写风暴卡死）
vm.dirty_background_ratio = 10
vm.dirty_ratio = 30
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 1000
# 元数据缓存保活：PCDN 海量小缓存文件，保住 dentry/inode 缓存=查找更快=命中更快
vm.vfs_cache_pressure = 50
# 页缓存预读放大：缓存读 miss 时一次多读 2MB 进 page cache（默认 128KB）
vm.page-cluster = 8
# 降低内存碎片：大块顺序写更容易凑出连续页
vm.min_free_kbytes = 65536
SYSCTL_EOF
sysctl -e -p /etc/sysctl.d/99-pcdn-disk.conf >/dev/null 2>&1
echo "[pcdn-disk-tune] done"
PCDN_TUNE_EOF
    chmod +x "$tune"
    bash "$tune"
    # 持久化：开机自动重放（/sys 重启即失）
    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/pcdn-disk-tune.service <<'UNIT_EOF'
[Unit]
Description=PCDN aggressive disk tune (reapply on boot)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pcdn_disk_tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable pcdn-disk-tune.service >/dev/null 2>&1
        log_message "${GREEN}[磁盘强化]${NC} 已安装开机自启服务 pcdn-disk-tune.service"
    fi
    log_message "${GREEN}[磁盘强化]${NC} PCDN 磁盘调优已应用（wbt=off, dirty 放大, vfs_cache=50, page-cluster=8）"
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

    # [3.5] 解析 admin 后台需要的 32hex nodeId（r20 根治：用 nodeId 而不是 SN 调 admin 接口）
    resolve_admin_node_id

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

    # [5.5] PCDN 专用优化前置：先拉满磁盘/内核吞吐，再部署业务
    # 关键顺序：让 ipes 容器在「已调优的内核」上启动，使首启预热、任何初始探测、业务提交
    # 都跑在 wbt=off / 脏页放大 / vfs 缓存保活 / 页缓存预读放大的环境里，给后台更干净的优质初评。
    pcdn_disk_tune

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

    # [7.5] 对齐 happ worker 数到 TARGET_HAPP（默认 9）
    # 后台默认下发 12 路时，这里裁到 9 并重启容器，确保「刷出来就是 9」，小内存机不再 OOM。
    align_happ_count

    # [8] 安装 nload（可选观测工具，r15 起改为**后台并行安装**，不再阻塞主流程）
    print_step "安装 nload（后台并行，不阻塞）"
    # ⚠️ epel-release 在没有外网/镜像慢时会卡很久（实测 7 分钟+）；nload 只是观测工具，
    #    不值得让它拖住后面的业务提交/流转。改为 nohup 后台装，主流程立即继续。
    if command -v nload >/dev/null 2>&1; then
        log_message "${GREEN}[成功]${NC} nload 已存在"
    else
        nohup setsid bash -c 'yum install -y epel-release >/dev/null 2>&1; yum install -y nload >/dev/null 2>&1' >/dev/null 2>&1 </dev/null &
        log_message "${GREEN}[信息]${NC} nload 已转入后台安装（PID=$!，不阻塞主流程；稍后 command -v nload 可查）"
    fi

    # [9] 降级「待配置」-> 提交业务 41 -> 升回「服务中」(带业务ID) -> 写节点属性
    # r20：必须用 ADMIN_NODE_ID（32hex）调 admin 接口；用 SN 调会写到错节点或写不进去。
    if [ -n "$ADMIN_NODE_ID" ]; then
        downgrade_to_configured "$ADMIN_NODE_ID"
        submit_business "$ADMIN_NODE_ID"
        transition_to_serving "$ADMIN_NODE_ID"
        set_node_attributes "$ADMIN_NODE_ID"
    elif [ -n "$DEVICE_ID" ]; then
        log_message "${YELLOW}[警告]${NC} 未解析到 admin nodeId，尝试用 SN 回退（极有可能无法绑定业务）"
        downgrade_to_configured "$DEVICE_ID"
        submit_business "$DEVICE_ID"
        transition_to_serving "$DEVICE_ID"
        set_node_attributes "$DEVICE_ID"
    else
        log_message "${YELLOW}[警告]${NC} 无设备SN，跳过业务提交与状态流转"
    fi

    # [9.5] 二次对齐 happ（r20-fix2）
    # 背景：[7.5] 裁剪后，[9] 提交业务41/流转「服务中」时后台可能重新下发 12 路模板覆盖配置，导致回弹。
    #       必须在业务注册完成之后再裁一次（r20-fix3 起改为直接改宿主文件，真正落盘生效）。
    # 兜底：后续若再被改回，由看门狗（ipes_watchdog.sh，每分钟）自动裁回，冷却10分钟。
    print_step "二次对齐 happ 路数（业务注册后回弹修复）"
    sleep 15   # 等后台配置下发落盘
    align_happ_count

    # [10] SSH 安全收尾
    disable_root_ssh_login
    clear_root_ssh_dir
    set_root_password

    # [11] admin 免密 sudo（默认【保留】，与金标准工作节点一致）
    # 注意：金标准节点(64e)的 sudoers 里 `admin ALL=(ALL)  NOPASSWD:ALL` 是保留的。
    #       注释掉会断掉平台侧经 admin 的操作通道，所以默认不动；确要清理时用
    #       环境变量 DISABLE_ADMIN_NOPASSWD=1 显式开启。
    if [ "${DISABLE_ADMIN_NOPASSWD:-0}" = "1" ]; then
        print_step "清理 admin 免密 sudo 配置（DISABLE_ADMIN_NOPASSWD=1）"
        sed -i 's/^admin ALL=(ALL)  NOPASSWD:ALL/# &/' /etc/sudoers 2>/dev/null
        log_message "${GREEN}[成功]${NC} admin 免密配置已注释"
    else
        log_message "${YELLOW}[信息]${NC} 保留 admin 免密 sudo（与金标准一致；如需清理设 DISABLE_ADMIN_NOPASSWD=1）"
    fi

    # [11.5] 校验业务ID（后台 hostName）
    # 放在最后：平台创建 business_tags 记录有 1~2 分钟延迟，
    # 让前面的 SSH 收尾工作（约 1 分钟）正好把延迟掩盖掉。
    if [ -n "$ADMIN_NODE_ID" ]; then
        set_business_tag "$ADMIN_NODE_ID"
    elif [ -n "$DEVICE_ID" ]; then
        set_business_tag "$DEVICE_ID"
    fi

    # [12] 最终输出
    echo
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${GREEN}业务 ${BUSINESS_ID}（q2）整体部署脚本执行完毕！${NC}"
    echo -e "${CYAN}======================================================${NC}"
    log_message "设备SN（业务ID）: ${DEVICE_ID:-未知}"
    log_message "admin 节点 ID: ${ADMIN_NODE_ID:-未知}（32hex，后台 stateflow/updateEdgeNominalInfo 用）"
    log_message "省份/城市: ${province:-未知}/${city:-未知}"
    log_message "运营商: $ISP"
    log_message "节点属性: 资源类型=$NODE_RESOURCE_TYPE(1=汇聚/2=专线) 上网方式=$NODE_DIAL_TYPE"
    log_message "目标 happy 进程数: $TARGET_HAPP/$TARGET_HAPP"
    log_message "日志文件: $LOG_FILE"
    log_message "若后台未显示「服务中」，请检查 admin.zhouyi.top token/接口路径是否正确"
}

main "$@"

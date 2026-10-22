#!/bin/bash

# ==============================================================================
# Shell脚本：自动化安装、配置和检查ZyCloud Agent相关服务和设备绑定
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 日志文件路径
LOG_FILE="/var/log/zycloud_agent_setup.log"

# 安装包配置
FRPC_CONFIG="/usr/local/frpc_zycloud/frpc.json"
INSTALLER_DIR="/opt/zyy_install"

# 定义文件URL和对应的MD5
declare -A CDN_URLS
declare -A SOURCE_URLS
declare -A FILE_MD5

# CDN链接（主）
CDN_URLS["zyy_install_notele.tgz"]="http://file.zhouyi.top/script/zyy_init_qudao/zyy_install_notele.tgz"
CDN_URLS["zyy_install.tgz"]="http://file.zhouyi.top/script/zyy_init_qudao/zyy_install.tgz"

# 回源链接（备）
SOURCE_URLS["zyy_install_notele.tgz"]="http://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init_qudao/zyy_install_notele.tgz"
SOURCE_URLS["zyy_install.tgz"]="http://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init_qudao/zyy_install.tgz"

# MD5校验值
FILE_MD5["zyy_install_notele.tgz"]="d0fa4d848b7fed3cefe6dcb61a1d4ecf"
FILE_MD5["zyy_install.tgz"]="81df6ae10363f379a39dddac0a14a2c0"

# API配置
API_URL="http://api.zhouyiy.com/qudao/device/v1/batch/create2"

# curl 超时设置（秒）
CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIMEOUT=30

# --- 初始化变量（注册功能所需）---
APP_KEY=""
SECRET_KEY=""
ISP=""
province=""
city=""

# --- 显示帮助信息 ---
show_help() {
    echo -e "${CYAN}用法: $0 [选项]${NC}"
    echo "选项:"
    echo "  --ak <appKey>     设置应用Key (必需)"
    echo "  --sk <secretKey>  设置密钥 (必需)"
    echo "  --isp <运营商>     设置运营商 (必需，如: 电信、联通、移动)"
    echo "  --help            显示此帮助信息"
    echo
    echo "示例:"
    echo "  $0 --ak eKg5vr29tDu6vYNu0i1RF55 --sk your_secret_key --isp 电信"
    exit 0
}

# --- 解析命令行参数 ---
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ak)
                APP_KEY="$2"
                shift 2
                ;;
            --sk)
                SECRET_KEY="$2"
                shift 2
                ;;
            --isp)
                ISP="$2"
                shift 2
                ;;
            --help)
                show_help
                ;;
            *)
                echo -e "${RED}[错误]${NC} 未知参数: $1"
                show_help
                ;;
        esac
    done

    # 验证必需参数
    local missing_params=0
    if [ -z "$APP_KEY" ]; then
        echo -e "${RED}[错误]${NC} 缺少参数: --ak"
        missing_params=1
    fi
    if [ -z "$SECRET_KEY" ]; then
        echo -e "${RED}[错误]${NC} 缺少参数: --sk"
        missing_params=1
    fi
    if [ -z "$ISP" ]; then
        echo -e "${RED}[错误]${NC} 缺少参数: --isp"
        missing_params=1
    fi

    if [ $missing_params -eq 1 ]; then
        echo
        show_help
        exit 1
    fi
}

# --- 日志记录函数 ---
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # 移除颜色代码后写入日志文件
    local clean_message=$(echo -e "$message" | sed -E 's/\x1B\[[0-9;]*[mGK]//g')
    echo "[$timestamp] $clean_message" >> "$LOG_FILE"
    # 同时输出到终端（带颜色）
    echo -e "$message"
}

# --- 辅助函数，用于打印带格式的步骤标题 ---
print_step() {
    local step_title="$1"
    echo -e "\n${CYAN}======================================================${NC}"
    echo -e "${CYAN}>> 步骤：$step_title${NC}"
    echo -e "${CYAN}======================================================${NC}"
}

# --- MD5校验函数 ---
check_md5() {
    local file_path=$1
    local file_name=$2
    local expected_md5=${FILE_MD5[$file_name]}

    if [ ! -f "$file_path" ]; then
        echo "文件 $file_path 不存在"
        return 1
    fi

    local actual_md5=$(md5sum "$file_path" | awk '{print $1}')

    if [ "$actual_md5" = "$expected_md5" ]; then
        echo "MD5校验通过: $file_name"
        return 0
    else
        echo "MD5校验失败: $file_name"
        echo "期望: $expected_md5"
        echo "实际: $actual_md5"
        return 1
    fi
}

# --- 检查并清理现有文件 ---
check_and_clean_existing_file() {
    local file_name=$1
    local file_path="/opt/${file_name}"

    if [ -f "$file_path" ]; then
        echo "发现已存在的文件: $file_path"

        # 校验MD5
        if check_md5 "$file_path" "$file_name"; then
            echo "文件完整有效，跳过下载"
            return 0  # 文件有效，无需下载
        else
            echo "文件损坏或MD5不匹配，删除旧文件"
            rm -f "$file_path"
            return 1  # 文件无效，需要重新下载
        fi
    else
        echo "未发现已存在的文件，需要下载"
        return 1  # 文件不存在，需要下载
    fi
}

# --- 带断点续传的下载函数 ---
download_file() {
    local url=$1
    local output_path=$2
    local max_retries=3
    local retry_delay=2

    for ((i=1; i<=max_retries; i++)); do
        echo "下载尝试 $i/$max_retries: $url"

        # 使用curl进行断点续传下载
        if curl -L -C - --connect-timeout 30 --max-time 600 --retry 1 --retry-delay 5 \
            -o "$output_path" "$url" 2>&1; then

            # 检查下载文件大小
            if [ -f "$output_path" ] && [ $(stat -c%s "$output_path") -gt 0 ]; then
                echo "下载成功: $url"
                return 0
            else
                echo "下载失败: 文件为空或不存在"
            fi
        else
            echo "下载失败: curl返回错误"
        fi

        if [ $i -lt $max_retries ]; then
            echo "等待 ${retry_delay} 秒后重试..."
            sleep $retry_delay
        fi
    done

    return 1
}

# --- 多源下载函数：CDN为主，回源为辅 ---
download_with_fallback() {
    local file_name=$1
    local local_path="/opt/${file_name}"
    local temp_path="${local_path}.part"

    # 检查现有文件是否有效
    if check_and_clean_existing_file "$file_name"; then
        echo "使用现有有效文件，无需下载"
        return 0
    fi

    # 清理临时文件
    [ -f "$temp_path" ] && rm -f "$temp_path"

    # 1. 优先尝试CDN链接，尝试3次
    local cdn_url="${CDN_URLS[$file_name]}"
    echo "开始从CDN下载 $file_name (主源)"

    if download_file "$cdn_url" "$temp_path"; then
        # 下载完成，移动到最终位置
        mv "$temp_path" "$local_path"

        # 校验MD5
        if check_md5 "$local_path" "$file_name"; then
            echo "CDN下载成功且校验通过"
            return 0
        else
            echo "CDN下载的文件MD5校验失败"
            rm -f "$local_path"
        fi
    else
        echo "CDN下载失败，尝试3次后放弃"
    fi

    # 2. CDN失败，切换到回源链接
    local source_url="${SOURCE_URLS[$file_name]}"
    echo "切换到回源链接下载 $file_name (备用源)"

    # 重新下载，不保留之前的临时文件
    [ -f "$temp_path" ] && rm -f "$temp_path"

    if download_file "$source_url" "$temp_path"; then
        mv "$temp_path" "$local_path"

        if check_md5 "$local_path" "$file_name"; then
            echo "回源下载成功且校验通过"
            return 0
        else
            echo "回源下载的文件MD5校验失败"
            rm -f "$local_path"
            return 1
        fi
    else
        echo "回源下载也失败"
        return 1
    fi
}

# --- 判断是否为阿里云和腾讯云服务器 ---
detect_cloud_environment() {
    # 检测阿里云
    if dmesg | grep -i alibaba > /dev/null 2>&1; then
        echo "aliyun"
        return 0
    fi

    # 检测腾讯云
    if dmesg | grep -i tencent > /dev/null 2>&1; then
        echo "tencent"
        return 0
    fi

    # 非云环境（物理机或虚拟机）
    echo "non_cloud"
    return 1
}

# --- 云环境安装 agent (不带telegraf) ---
cloud_server_edge() {
    local file_name="zyy_install_notele.tgz"

    # 下载部署包
    if ! download_with_fallback "$file_name"; then
        echo "错误: 下载 $file_name 失败"
        return 1
    fi

    # 解压
    echo "解压文件..."
    tar xf "/opt/${file_name}" -C /opt

    # 授权
    chmod -R +x /opt/zyy_install/*

    # 执行安装zyy并同步
    cd /opt/zyy_install/ && ./agent_installer install zycloud
}

# --- 非云主机安装 agent+telegraf ---
iso_server_edge() {
    local file_name="zyy_install.tgz"

    # 下载部署包
    if ! download_with_fallback "$file_name"; then
        echo "错误: 下载 $file_name 失败"
        return 1
    fi

    # 解压
    echo "解压文件..."
    tar xf "/opt/${file_name}" -C /opt

    # 授权
    chmod -R +x /opt/zyy_install/*
    #创建日志目录
    mkdir -p /var/log/telegraf
    #授权
    chown -R telegraf:telegraf /var/log/telegraf
    # 创建 telegraf 用户
    useradd -r -s /bin/false -d /etc/telegraf telegraf
    # 执行安装zyy并同步
    cd /opt/zyy_install/ && ./agent_installer install zycloud --enable-telegraf
}

# --- 动态获取SSH端口 ---
get_ssh_port() {
    local ssh_port

    # 方法1: 通过ss命令获取sshd监听端口
    ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)

    # 方法2: 如果方法1失败，尝试从sshd_config获取
    if [ -z "$ssh_port" ] || [ "$ssh_port" = "" ]; then
        if [ -f "/etc/ssh/sshd_config" ]; then
            ssh_port=$(grep -E "^Port[[:space:]]+[0-9]+" /etc/ssh/sshd_config | awk '{print $2}' | head -1)
        fi
    fi

    # 方法3: 如果还是获取不到，使用默认端口22
    if [ -z "$ssh_port" ] || [ "$ssh_port" = "" ]; then
        ssh_port=22
        warning_msg="${YELLOW}[警告]${NC} 无法检测到SSH端口，使用默认端口22。"
        log_message "$warning_msg"
    else
        success_msg="${GREEN}[成功]${NC} 检测到SSH端口: $ssh_port"
    fi

    echo "$ssh_port"
}

# --- 修改SSH配置文件启用公钥认证 ---
enable_ssh_pubkey_auth() {
    local sshd_config="/etc/ssh/sshd_config"
    local backup_file="${sshd_config}.backup.$(date +%Y%m%d_%H%M%S)"

    print_step "修改SSH配置启用公钥认证"

    # 检查配置文件是否存在
    if [ ! -f "$sshd_config" ]; then
        warning_msg="${YELLOW}[警告]${NC} SSH配置文件不存在: $sshd_config"
        log_message "$warning_msg"
        return 1
    fi

    # 备份原始配置文件
    cp "$sshd_config" "$backup_file"
    backup_msg="${GREEN}[成功]${NC} SSH配置文件已备份到: $backup_file"
    log_message "$backup_msg"

    # 检查是否已启用公钥认证
    if grep -q "^PubkeyAuthentication\s*yes" "$sshd_config"; then
        already_enabled_msg="${YELLOW}[信息]${NC} 公钥认证已启用，无需修改。"
        log_message "$already_enabled_msg"
        return 0
    fi

    # 检查是否有被注释的PubkeyAuthentication配置
    if grep -q "^#PubkeyAuthentication" "$sshd_config"; then
        # 取消注释并设置为yes
        sed_msg="取消注释并设置 PubkeyAuthentication 为 yes"
        log_message "$sed_msg"
        sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/g' "$sshd_config"
    else
        # 检查是否有未注释的PubkeyAuthentication配置但值不是yes
        if grep -q "^PubkeyAuthentication" "$sshd_config"; then
            # 修改现有的PubkeyAuthentication值为yes
            sed_msg="修改现有 PubkeyAuthentication 值为 yes"
            log_message "$sed_msg"
            sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/g' "$sshd_config"
        else
            # 在文件末尾添加配置
            append_msg="添加 PubkeyAuthentication yes 到配置文件末尾"
            log_message "$append_msg"
            echo -e "\n# Enable public key authentication" >> "$sshd_config"
            echo "PubkeyAuthentication yes" >> "$sshd_config"
        fi
    fi

    # 验证修改结果
    if grep -q "^PubkeyAuthentication\s*yes" "$sshd_config"; then
        success_msg="${GREEN}[成功]${NC} SSH公钥认证已启用"
        log_message "$success_msg"

        # 重启SSH服务使配置生效
        if systemctl restart sshd; then
            restart_msg="${GREEN}[成功]${NC} SSH服务重启成功"
            log_message "$restart_msg"
        else
            warning_msg="${YELLOW}[警告]${NC} SSH服务重启失败，请手动重启"
            log_message "$warning_msg"
        fi

        return 0
    else
        error_msg="${RED}[错误]${NC} SSH公钥认证配置失败"
        log_message "$error_msg"
        return 1
    fi
}

# --- 禁用SSH root登录，仅允许admin登录 ---
disable_root_ssh_login() {
    local sshd_config="/etc/ssh/sshd_config"
    local backup_file="${sshd_config}.backup.$(date +%Y%m%d_%H%M%S)"

    print_step "禁用 SSH root 登录"

    if [ ! -f "$sshd_config" ]; then
        warning_msg="${YELLOW}[警告]${NC} SSH配置文件不存在: $sshd_config"
        log_message "$warning_msg"
        return 1
    fi

    cp "$sshd_config" "$backup_file"
    backup_msg="${GREEN}[成功]${NC} SSH配置文件已备份到: $backup_file"
    log_message "$backup_msg"

    if grep -Eq "^PermitRootLogin[[:space:]]+no" "$sshd_config"; then
        already_disabled_msg="${YELLOW}[信息]${NC} SSH root 登录已被禁用，无需修改。"
        log_message "$already_disabled_msg"
    elif grep -q "^#PermitRootLogin" "$sshd_config"; then
        sed_msg="取消注释并设置 PermitRootLogin 为 no"
        log_message "$sed_msg"
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/g' "$sshd_config"
    elif grep -q "^PermitRootLogin" "$sshd_config"; then
        sed_msg="修改现有 PermitRootLogin 值为 no"
        log_message "$sed_msg"
        sed -i 's/^PermitRootLogin.*/PermitRootLogin no/g' "$sshd_config"
    else
        append_msg="添加 PermitRootLogin no 到配置文件末尾"
        log_message "$append_msg"
        echo -e "\n# Disable root SSH login" >> "$sshd_config"
        echo "PermitRootLogin no" >> "$sshd_config"
    fi

    if grep -Eq "^AllowUsers[[:space:]]+admin" "$sshd_config"; then
        already_allowed_msg="${YELLOW}[信息]${NC} SSH 仅允许 admin 登录配置已存在。"
        log_message "$already_allowed_msg"
    elif grep -q "^AllowUsers" "$sshd_config"; then
        sed_msg="修改现有 AllowUsers 配置为仅允许 admin"
        log_message "$sed_msg"
        sed -i 's/^AllowUsers.*/AllowUsers admin/g' "$sshd_config"
    else
        append_msg="添加 AllowUsers admin 到配置文件末尾"
        log_message "$append_msg"
        echo "AllowUsers admin" >> "$sshd_config"
    fi

    if grep -Eq "^PermitRootLogin[[:space:]]+no" "$sshd_config" && grep -Eq "^AllowUsers[[:space:]]+admin" "$sshd_config"; then
        success_msg="${GREEN}[成功]${NC} SSH root 登录已禁用，且仅允许 admin 登录"
        log_message "$success_msg"

        if systemctl restart sshd; then
            restart_msg="${GREEN}[成功]${NC} SSH服务重启成功"
            log_message "$restart_msg"
        else
            warning_msg="${YELLOW}[警告]${NC} SSH服务重启失败，请手动重启"
            log_message "$warning_msg"
        fi

        return 0
    else
        error_msg="${RED}[错误]${NC} SSH root 登录配置失败"
        log_message "$error_msg"
        return 1
    fi
}

# --- 清空 root 用户的 .ssh 目录内容 ---
clear_root_ssh_dir() {
    local root_ssh_dir="/root/.ssh"

    print_step "清空 root 用户 .ssh 目录"

    mkdir -p "$root_ssh_dir"
    if [ -d "$root_ssh_dir" ]; then
        find "$root_ssh_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
        chmod 700 "$root_ssh_dir"
        chown root:root "$root_ssh_dir"
        success_msg="${GREEN}[成功]${NC} root 用户 .ssh 目录内容已清空"
        log_message "$success_msg"
        return 0
    fi

    error_msg="${RED}[错误]${NC} 无法访问 root 用户 .ssh 目录"
    log_message "$error_msg"
    return 1
}

# --- 使用加密后的 root 密码哈希设置密码，不再使用明文密码 ---
set_root_password() {
    local root_password_hash='$6sQhmo2hOEsM'

    print_step "修改 root 密码"

    if usermod --password "$root_password_hash" root; then
        success_msg="${GREEN}[成功]${NC} root 密码已使用加密哈希更新，哈希值: $root_password_hash"
        log_message "$success_msg"
        return 0
    fi

    error_msg="${RED}[错误]${NC} 更新 root 密码失败"
    log_message "$error_msg"
    return 1
}

# --- 初始化日志文件 ---
init_log() {
    local log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
    fi
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    log_message "=== ZyCloud Agent 安装脚本开始执行 ==="
    log_message "日志文件: $LOG_FILE"
}

# ==================== 新增的注册功能函数（放在开头但最后执行） ====================

# --- 获取省份和城市信息 ---
get_location_info() {
    print_step "获取地理位置信息"

    # 获取IP信息
    local ip_info=$(curl -s myip.ipip.net)

    # 解析省份和城市
    province=$(echo "$ip_info" | awk -F ' ' '{print $4}')
    city=$(echo "$ip_info" | awk -F ' ' '{print $5}')

    # 去除可能的逗号
    province=$(echo "$province" | tr -d ',')
    city=$(echo "$city" | tr -d ',')

    # 检查省份是否为空，如果为空则使用默认值"北京"
    if [ -z "$province" ] || [ "$province" = "null" ] || [ "$province" = " " ]; then
        warning_msg="${YELLOW}[警告]${NC} 无法获取省份信息，使用默认值: 北京"
        log_message "$warning_msg"
        province="北京"
    fi

    # 检查城市是否为空，如果为空则使用默认值"北京"
    if [ -z "$city" ] || [ "$city" = "null" ] || [ "$city" = " " ]; then
        warning_msg="${YELLOW}[警告]${NC} 无法获取城市信息，使用默认值: 北京"
        log_message "$warning_msg"
        city="北京"
    fi

    location_msg="${GREEN}[成功]${NC} 地理位置信息: 省份=${province}, 城市=${city}"
    log_message "$location_msg"
}

# --- 生成签名 ---
generate_sign() {
    local timestamp="$1"
    local ak="$2"
    local sk="$3"

    # 生成待签名字符串: ak+timestamp+sk
    local sign_string="${ak}${timestamp}${sk}"

    # 计算MD5值
    local md5_sign=$(echo -n "$sign_string" | md5sum | cut -d ' ' -f1)

    # 添加前缀
    echo "ZYY${md5_sign}"
}

# --- 注册设备到API（带重试功能，根据业务code判断成功）---
register_device() {
    local device_id="$1"
    local province="$2"
    local city="$3"
    local isp="$4"
    local max_retries=3
    local retry_count=0

    print_step "注册设备到云端"

    while [ $retry_count -lt $max_retries ]; do
        # 获取当前时间戳
        local timestamp=$(date +%s)

        # 生成签名
        local sign=$(generate_sign "$timestamp" "$APP_KEY" "$SECRET_KEY")

        # 构建请求数据 - 使用更紧凑的格式，避免换行和空格问题
        local request_data='{"devices":[{"device_id":"'"$device_id"'","remark":"云主机"}],"province":"'"$province"'","city":"'"$city"'","isp":"'"$isp"'"}'

        retry_msg="正在注册设备 (尝试 $((retry_count+1))/$max_retries)..."
        log_message "$retry_msg"

        # 发送API请求，设置超时
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

        # 检查 curl 命令是否成功执行
        if [ $curl_exit_code -ne 0 ]; then
            warning_msg="${YELLOW}[警告]${NC} curl 命令执行失败，退出码: $curl_exit_code"
            log_message "$warning_msg"

            # 根据退出码判断错误类型
            case $curl_exit_code in
                7) warning_msg="  原因: Failed to connect to host (连接失败)";;
                28) warning_msg="  原因: Operation timeout (操作超时)";;
                35) warning_msg="  原因: SSL connect error (SSL连接错误)";;
                *) warning_msg="  原因: 未知错误";;
            esac
            log_message "$warning_msg"

            retry_count=$((retry_count+1))
            if [ $retry_count -lt $max_retries ]; then
                sleep_msg="等待2秒后重试..."
                log_message "$sleep_msg"
                sleep 2
                continue
            else
                error_msg="${RED}[错误]${NC} 设备注册失败，已达到最大重试次数"
                log_message "$error_msg"
                return 1
            fi
        fi

        # 解析响应状态码和内容
        local http_code=$(echo "$response" | tail -n1)
        local response_body=$(echo "$response" | sed '$d')

        # 检查 http_code 是否为数字
        if [[ "$http_code" =~ ^[0-9]+$ ]]; then
            if [ "$http_code" -eq 200 ]; then
                # 尝试解析JSON响应，获取code字段
                local business_code=$(echo "$response_body" | grep -o '"code":[^,}]*' | cut -d':' -f2 | tr -d ' ')
                local message=$(echo "$response_body" | grep -o '"message":"[^"]*"' | cut -d':' -f2 | tr -d '"')

                # 检查业务code是否为0（成功）
                if [ "$business_code" = "0" ]; then
                    success_msg="${GREEN}[成功]${NC} 设备注册成功"
                    log_message "$success_msg"
                    log_message "API响应: $response_body"

                    # 保存注册信息
                    local reg_info_file="/usr/local/edge/registration_info"
                    echo "注册时间: $(date '+%Y-%m-%d %H:%M:%S')" > "$reg_info_file"
                    echo "设备ID: $device_id" >> "$reg_info_file"
                    echo "省份: $province" >> "$reg_info_file"
                    echo "城市: $city" >> "$reg_info_file"
                    echo "运营商: $isp" >> "$reg_info_file"
                    echo "注册状态: 成功" >> "$reg_info_file"
                    echo "API响应: $response_body" >> "$reg_info_file"
                    chmod 644 "$reg_info_file"

                    return 0
                else
                    warning_msg="${YELLOW}[警告]${NC} 设备注册失败 (业务code: $business_code)"
                    log_message "$warning_msg"
                    log_message "API响应: $response_body"

                    # 根据业务code给出具体提示
                    case "$business_code" in
                        "-20") warning_msg="  原因: 设备联网异常 - 设备ID: $device_id，请检查网络连接" ;;
                        "-1") warning_msg="  原因: 参数错误" ;;
                        *) warning_msg="  原因: 未知错误" ;;
                    esac
                    log_message "$warning_msg"

                    # 如果是因为设备联网异常，可能不需要重试，直接退出
                    if [ "$business_code" = "-20" ]; then
                        error_msg="${RED}[错误]${NC} 设备联网异常，请检查设备网络后重试"
                        log_message "$error_msg"

                        # 保存失败信息
                        local reg_info_file="/usr/local/edge/registration_info"
                        echo "注册时间: $(date '+%Y-%m-%d %H:%M:%S')" > "$reg_info_file"
                        echo "设备ID: $device_id" >> "$reg_info_file"
                        echo "省份: $province" >> "$reg_info_file"
                        echo "城市: $city" >> "$reg_info_file"
                        echo "运营商: $isp" >> "$reg_info_file"
                        echo "注册状态: 失败 (设备联网异常)" >> "$reg_info_file"
                        echo "API响应: $response_body" >> "$reg_info_file"
                        chmod 644 "$reg_info_file"

                        return 1
                    fi

                    retry_count=$((retry_count+1))
                    if [ $retry_count -lt $max_retries ]; then
                        sleep_msg="等待2秒后重试..."
                        log_message "$sleep_msg"
                        sleep 2
                    else
                        error_msg="${RED}[错误]${NC} 设备注册失败，已达到最大重试次数"
                        log_message "$error_msg"
                        return 1
                    fi
                fi
            else
                warning_msg="${YELLOW}[警告]${NC} HTTP请求失败 (HTTP $http_code)"
                log_message "$warning_msg"
                log_message "API响应: $response_body"

                retry_count=$((retry_count+1))
                if [ $retry_count -lt $max_retries ]; then
                    sleep_msg="等待2秒后重试..."
                    log_message "$sleep_msg"
                    sleep 2
                else
                    error_msg="${RED}[错误]${NC} HTTP请求失败，已达到最大重试次数"
                    log_message "$error_msg"
                    return 1
                fi
            fi
        else
            warning_msg="${YELLOW}[警告]${NC} 无效的HTTP响应: $http_code"
            log_message "$warning_msg"

            retry_count=$((retry_count+1))
            if [ $retry_count -lt $max_retries ]; then
                sleep_msg="等待2秒后重试..."
                log_message "$sleep_msg"
                sleep 2
            else
                error_msg="${RED}[错误]${NC} 设备注册失败，已达到最大重试次数"
                log_message "$error_msg"
                return 1
            fi
        fi
    done
}

# --- 修改frpc.json配置文件 ---
set_frp_port(){
    # 获取SSH端口
    SSH_PORT=$(get_ssh_port)
    if [ -f "$FRPC_CONFIG" ]; then
        # 使用sed修改LocalPort的值
        sed -i "s/\"LocalPort\": [0-9]*/\"LocalPort\": $SSH_PORT/g" "$FRPC_CONFIG"

        if [ $? -eq 0 ]; then
            echo "已将 $FRPC_CONFIG 中的 LocalPort 更新为 $SSH_PORT"
            systemctl restart frpc_zycloud
        else
            echo "更新 $FRPC_CONFIG 失败"
        fi
    else
        echo "配置文件 $FRPC_CONFIG 不存在"
    fi
}

# --- 检查服务运行状态 ---
check_services_status() {
    print_step "检查所有相关服务的运行状态"

    local SERVICES_TO_CHECK=("frpc_zycloud" "edge_client_zycloud" "telegraf_zycloud")

    for service in "${SERVICES_TO_CHECK[@]}"; do
        if systemctl list-units --full -all | grep -q "$service.service"; then
            STATUS=$(systemctl is-active "$service" 2>/dev/null)
            if [ "$STATUS" == "active" ]; then
                log_message "  - 服务 ${CYAN}${service}${NC}: ${GREEN}● 运行中 (active)${NC}"
            else
                log_message "  - 服务 ${CYAN}${service}${NC}: ${RED}● 异常 (${STATUS})${NC}"
            fi
        else
            log_message "  - 服务 ${CYAN}${service}${NC}: ${YELLOW}○ 未安装或未注册${NC}"
        fi
    done
}

# --- 添加admin用户并配置sudo权限 ---
add_admin_user() {
    print_step "添加 admin 用户并配置 sudo 权限"

    if id "admin" &>/dev/null; then
        log_message "${YELLOW}[警告]${NC} 用户 'admin' 已存在，跳过创建。"
    else
        /usr/sbin/useradd admin
        if [ $? -eq 0 ]; then
            log_message "${GREEN}[成功]${NC} 用户 'admin' 创建完毕。"
            echo "%admin   ALL=(ALL) NOPASSWD:ALL,!/bin/su" >> /etc/sudoers
            log_message "${GREEN}[成功]${NC} 用户 'admin' 已添加到 sudoers 文件中。"
        else
            log_message "${RED}[错误]${NC} 创建用户 'admin' 失败。"
            return 1
        fi
    fi
    return 0
}

# --- 添加SSH公钥到authorized_keys ---
add_ssh_key() {
    print_step "添加 SSH 公钥到 authorized_keys"

    local SSH_DIR="/home/admin/.ssh"
    local AUTH_KEYS_FILE="$SSH_DIR/authorized_keys"
    local SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+qsk4/j2FQeDZKWkC8xI9RnSDFAkXmVO2SbToaoDF+eIsnJVIagtFvUkLA2r5pszEKFGWvoNkm0FrU8cqzfno1jkS3Y0j77rW++96qvf1fAA36PHHSYMtQ/aQCexptfBdVczARXM6/bzzBjtPHZ/SN4fS2bQ4RCwNouLYgwx1gsyi70XaoKbLdm5neqqX3IQK1OHACV2SkrX/libVze7cRNJlpYb6RpBpSq6TGLvqzXEHzNgVhM0HC5i8LWMdvNT8+txhYI+tWffYE8rn/KEeLmMwkyxLv45og9nQKrNaGh3agu4ERxDGzEagj12oJAe24dX5Zao+PFKEZYYH//BRIQ6Sa9oAImdkeYF0ImnF+mArki0DNUjxGDu82jGQqwTRv4MgCgRVm656391e5R+aC7TTmQKGElG68D1zieQYN+BscmTU0e7Dm1ugX2C9W6ZpKYRRzjZsqpb3ZqGOkmQKg7BvF0pQqWlwQ2htSFKkIUHsjRRegEo2eRzY08LA6Ec= jiayuguang@PC-20241122OPDI"

    # 确保.ssh目录存在并有正确的权限
    mkdir -p "$SSH_DIR"
    chown -R admin:admin "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    # 确保authorized_keys文件存在并有正确的权限
    touch "$AUTH_KEYS_FILE"
    chown admin:admin "$AUTH_KEYS_FILE"
    chmod 600 "$AUTH_KEYS_FILE"

    # 检查key是否存在，如果不存在则添加
    if grep -qF "$SSH_KEY" "$AUTH_KEYS_FILE"; then
        log_message "${YELLOW}[警告]${NC} SSH 公钥已存在于 $AUTH_KEYS_FILE。"
    else
        echo "$SSH_KEY" >> "$AUTH_KEYS_FILE"
        chmod 600 "$AUTH_KEYS_FILE"
        chown admin:admin "$AUTH_KEYS_FILE"
        log_message "${GREEN}[成功]${NC} SSH 公钥已添加到 authorized_keys。"
    fi
}

# --- 读取并显示设备ID ---
display_device_id() {
    print_step "读取设备ID"

    local DEVICE_ID_FILE="/etc/.mac"
    if [ -f "$DEVICE_ID_FILE" ]; then
        DEVICE_ID=$(cat "$DEVICE_ID_FILE")
        mkdir -p /usr/local/edge/
        cat /etc/.mac > /usr/local/edge/device_code
        log_message "设备ID为: ${GREEN}${DEVICE_ID}${NC}"

        hostname "$DEVICE_ID"
        echo "$DEVICE_ID" > /etc/hostname
        if [ -f /etc/hosts ]; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $DEVICE_ID/" /etc/hosts
        fi
        log_message "${GREEN}[成功]${NC} 主机名已设置为: $DEVICE_ID"
        echo "$DEVICE_ID"
    else
        log_message "${YELLOW}[警告]${NC} 未找到设备ID文件 ($DEVICE_ID_FILE)。"
        return 1
    fi
    return 0
}

# --- 显示安装目录内容 ---
show_installer_contents() {
    print_step "安装文件列表"
    if [ -d "$INSTALLER_DIR" ]; then
        log_message "安装目录 $INSTALLER_DIR 内容："
        ls -la "$INSTALLER_DIR/" 2>/dev/null | while read line; do
            log_message "  $line"
        done
    fi
}

# 解析命令行参数（新增）
parse_arguments "$@"

# 初始化日志
init_log

# --- 开始执行前，检查是否为root用户 ---
if [ "$(id -u)" -ne 0 ]; then
   error_msg="${RED}[错误]${NC} 此脚本必须以root权限运行。请使用 'sudo ./setup_agent.sh' 执行。"
   log_message "$error_msg"
   exit 1
fi

start_msg="${GREEN}脚本开始执行...${NC}"
log_message "$start_msg"

# --- 步骤 1: 检测云环境并安装 ---
print_step "检测服务器环境并安装Agent"

# 创建日志目录
mkdir -p "$(dirname "$LOG_FILE")"

# 检测云服务器时使用 notele上机
if detect_cloud_environment > /dev/null; then
    log_message "检测到云环境（阿里云/腾讯云），使用无telegraf版本安装"
    cloud_server_edge
    set_frp_port
else
    log_message "检测到非云环境（物理机/虚拟机），使用完整版本安装（含telegraf）"
    iso_server_edge
    set_frp_port
fi

# --- 步骤 2: 启用SSH公钥认证 ---
enable_ssh_pubkey_auth

# --- 步骤 3: 检查各个服务的运行情况 ---
check_services_status

# --- 步骤 4: 添加admin账号并添加到sudoer里 ---
add_admin_user

# --- 步骤 5: 添加ssh key 到 authorized_keys---
add_ssh_key

# --- 步骤 6: 输出当前设备的设备ID ---
display_device_id

# --- 步骤 7: 配置 SSH 安全限制、清空 root .ssh、修改 root 密码 ---
disable_root_ssh_login
clear_root_ssh_dir
set_root_password

# --- 步骤 8: 显示安装目录内容 ---
show_installer_contents

# ==================== 最后执行注册功能 ====================

# --- 步骤 9: 获取地理位置信息并注册设备 ---
if [ -n "$DEVICE_ID" ]; then
    # 获取地理位置信息
    get_location_info

    # 注册设备（带重试功能）
    # ★ 修复吞错 bug：注册失败必须非零退出，否则上游(q2 部署脚本)的 || mark_fail "绑定" 永不触发，
    #   会导致「绑定失败却显示成功、反复重跑」的静默死循环。
    if register_device "$DEVICE_ID" "$province" "$city" "$ISP"; then
        : # 注册成功
    else
        echo -e "${RED}[致命]${NC} 设备注册失败，脚本将以非零状态退出（exit 1）"
        log_message "[致命] 设备注册失败，exit 1（已修复吞错 bug，上游可正确捕获）"
        exit 1
    fi
else
    echo -e "${RED}[致命]${NC} 无法获取设备ID，注册步骤无法执行，脚本将以非零状态退出（exit 1）"
    log_message "[致命] 无法获取设备ID，注册跳过，exit 1（已修复吞错 bug）"
    exit 1
fi

# --- 结束 ---
echo -e "\n${CYAN}======================================================${NC}"
echo -e "${GREEN}所有任务执行完毕！${NC}"
echo -e "${CYAN}======================================================${NC}"

log_message "======================================================"
log_message "所有任务执行完毕！"
log_message "======================================================"
log_message "=== ZyCloud Agent 安装脚本执行完成 ==="

# 显示日志文件位置
echo -e "\n${YELLOW}提示:${NC}"
echo -e "  - 所有操作日志已保存到 ${LOG_FILE}"
echo -e "  - 安装文件位于: ${INSTALLER_DIR}"
echo -e "  - SSH公钥认证已启用"
if [ -n "$DEVICE_ID" ]; then
    echo -e "  - 设备注册状态: 已执行"
    echo -e "  - 注册信息保存: /usr/local/edge/registration_info"
fi
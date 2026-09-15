#!/bin/bash
# ==============================================================================
# ipes_onekey_bind.sh v20260915a — 一键全流程（严格按序执行）
#   1) 官方 zyy_init_max.sh：装 agent(/etc/.mac, edge_client, frpc, admin用户) + 识别省市 + create2 渠道绑定
#   2) 内核优化：BBR / RPS / sysctl（无 NOTRACK——20260915 上海断网事故版已弃用）
#   3) IPES 部署：r19 恢复版 full.sh（29fd754 定点）后台运行
#   4) 收尾：ipes_bind_auto.sh 后台运行（等容器就绪 → HMAC 改41/200M → 填业务ID → 流转服务中 → 终验）
# 用法:
#   curl -fsSL "<本脚本短链>" | bash -s -- --ak <渠道AK> --sk <渠道SK> --jwt <JWT> --isp 电信 [--num-dirs 12] [--province 省] [--city 市]
# 日志: /var/log/ipes_onekey.log （收尾阶段另见 /var/log/ipes_bind_auto.log）
# ==============================================================================
set -u
CH_AK=""; CH_SK=""; JWT=""; ISP="电信"; PROVINCE=""; CITY=""; NUM_DIRS="12"
FULL_COMMIT="29fd754ff6711cd1f7834eb779c4ab44f63a3768"  # r19 恢复版 ipes_deploy_full.sh（9-14 下午 3 点同版）
REPO_RAW="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund"
ZY_INIT_URL="https://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init/zyy_init_max.sh"
LOG="/var/log/ipes_onekey.log"
log(){ echo "[$(date '+%F %T')] $1" | tee -a "${LOG}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ak) CH_AK="$2"; shift 2;;
    --sk) CH_SK="$2"; shift 2;;
    --jwt) JWT="$2"; shift 2;;
    --isp) ISP="$2"; shift 2;;
    --num-dirs) NUM_DIRS="$2"; shift 2;;
    --province) PROVINCE="$2"; shift 2;;
    --city) CITY="$2"; shift 2;;
    *) shift;;
  esac
done
if [[ -z "${CH_AK}" || -z "${CH_SK}" || -z "${JWT}" ]]; then
  log "[FATAL] 缺少必填参数 --ak/--sk/--jwt"; exit 1
fi
log "=== onekey_bind v20260915a 开始 (isp=${ISP} num-dirs=${NUM_DIRS}) ==="

# ---------- 步骤1: 官方 init（agent 安装 + 识别省市 + create2 渠道绑定） ----------
log "[1/5] 拉取并执行官方 zyy_init_max.sh（agent 安装 + 识别城市 + 渠道绑定）..."
curl -fsSL -m 60 "${ZY_INIT_URL}" -o /root/zyy_init_max.sh
if ! grep -q 'batch/create2' /root/zyy_init_max.sh 2>/dev/null; then
  log "[WARN] 官方脚本下载/校验异常，尝试备用源重试..."
  curl -fsSL -m 60 "https://file.zhouyi.top/script/zyy_init/zyy_init_max.sh" -o /root/zyy_init_max.sh || true
fi
if grep -q 'batch/create2' /root/zyy_init_max.sh 2>/dev/null; then
  bash /root/zyy_init_max.sh --ak "${CH_AK}" --sk "${CH_SK}" --isp "${ISP}" >> "${LOG}" 2>&1
  log "[1/5] 官方 init 执行完毕（agent 已装、城市已识别、渠道已绑定）"
else
  log "[ERROR] 官方 init 两源均不可用——跳过，渠道绑定将由收尾阶段的 bind_auto 补做"
fi

# ---------- 步骤2: 识别省市（供后续属性提交；优先用户传入 > registration_info > ipip.net > 默认） ----------
if [[ -z "${PROVINCE}" || -z "${CITY}" ]]; then
  if [[ -f /usr/local/edge/registration_info ]]; then
    P=$(grep '^省份' /usr/local/edge/registration_info 2>/dev/null | awk '{print $2}')
    C=$(grep '^城市' /usr/local/edge/registration_info 2>/dev/null | awk '{print $2}')
    [[ -n "${P}" ]] && PROVINCE="${P}"
    [[ -n "${C}" ]] && CITY="${C}"
  fi
fi
if [[ -z "${PROVINCE}" || -z "${CITY}" ]]; then
  IP_INFO=$(curl -s -m 10 --retry 2 myip.ipip.net 2>/dev/null || true)
  P=$(echo "${IP_INFO}" | awk '{print $4}' | tr -d ',')
  C=$(echo "${IP_INFO}" | awk '{print $5}' | tr -d ',')
  [[ -n "${P}" && "${P}" != "null" ]] && PROVINCE="${P}"
  [[ -n "${C}" && "${C}" != "null" ]] && CITY="${C}"
fi
[[ -z "${PROVINCE}" ]] && PROVINCE="北京"
[[ -z "${CITY}" ]] && CITY="北京"
log "[2/5] 省市确定: ${PROVINCE} / ${CITY}"

# ---------- 步骤3: 内核优化（BBR / RPS / sysctl，无 NOTRACK） ----------
log "[3/5] 内核优化（BBR/RPS/sysctl，无 NOTRACK）..."
cat > /etc/sysctl.d/99-ipes.conf <<'EOF'
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_ecn = 0
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
vm.swappiness = 0
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.overcommit_memory = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000
net.core.rps_sock_flow_entries = 32768
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
EOF
modprobe nf_conntrack 2>/dev/null; modprobe tcp_bbr 2>/dev/null
sysctl -e -p /etc/sysctl.d/99-ipes.conf >> "${LOG}" 2>&1
sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
log "[3/5] 拥塞算法 = $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
# RPS：收包软中断摊到所有 CPU（单队列 virtio 网卡必做）
NIC=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [[ -n "${NIC}" ]]; then
  NCPU=$(nproc); MASK=$(printf '%x' $(( (1<<NCPU)-1 )))
  for q in /sys/class/net/${NIC}/queues/rx-*; do
    echo "${MASK}" > "${q}/rps_cpus" 2>/dev/null
    echo 4096 > "${q}/rps_flow_cnt" 2>/dev/null
  done
  log "[3/5] RPS 已配置 (nic=${NIC} mask=${MASK})"
fi
# 清理可能残留的 NOTRACK 规则（历史事故兜底）
iptables -t raw -F 2>/dev/null || true

# ---------- 步骤4: IPES 部署（r19 恢复版 full.sh，29fd754 定点；后台运行；已有容器则跳过） ----------
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'ipes'; then
  log "[4/5] 检测到 ipes 容器已存在，跳过部署"
else
  log "[4/5] 下载 r19 full.sh（29fd754 定点）并后台部署..."
  DOWNED=0
  for u in "${REPO_RAW}/${FULL_COMMIT}/ipes_deploy_full.sh" \
           "https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@${FULL_COMMIT:0:7}/ipes_deploy_full.sh"; do
    if curl -fsSL -m 60 "${u}" -o /root/ipes_full.sh && grep -q singleIpRadio /root/ipes_full.sh; then DOWNED=1; break; fi
  done
  if [[ ${DOWNED} -eq 1 ]]; then
    export NODE_ACTIVATE_TOKEN="${JWT}"
    nohup setsid bash /root/ipes_full.sh --ak "${CH_AK}" --sk "${CH_SK}" --isp "${ISP}" --num-dirs "${NUM_DIRS}" --skip-olmt \
      >/var/log/ipes_nohup.log 2>&1 </dev/null &
    log "[4/5] r19 部署已后台启动 PID=$! （日志 /var/log/ipes_nohup.log）"
  else
    log "[ERROR] full.sh 两源下载/校验均失败，部署未启动"; exit 1
  fi
fi

# ---------- 步骤5: 收尾 bind_auto 后台运行（改41/200 → 填业务ID → 流转服务中 → 终验） ----------
log "[5/5] 拉取收尾脚本 ipes_bind_auto.sh 并后台运行..."
BINDED=0
for u in "${REPO_RAW}/main/ipes_bind_auto.sh" "https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@main/ipes_bind_auto.sh"; do
  if curl -fsSL -m 30 "${u}" -o /root/ipes_bind_auto.sh && grep -q 'bind_auto' /root/ipes_bind_auto.sh; then BINDED=1; break; fi
done
if [[ ${BINDED} -eq 1 ]]; then
  nohup setsid bash /root/ipes_bind_auto.sh \
    --ak "${CH_AK}" --sk "${CH_SK}" --jwt "${JWT}" --isp "${ISP}" \
    --province "${PROVINCE}" --city "${CITY}" \
    >/var/log/ipes_bind_auto.log 2>&1 </dev/null &
  log "[5/5] bind_auto 已后台启动 PID=$! （日志 /var/log/ipes_bind_auto.log）"
else
  log "[ERROR] bind_auto 下载失败——请手动跑收尾脚本"
  exit 1
fi

log "=== onekey 前台部分结束。后台继续：部署(约10分钟) → 改41 → 填业务ID → 流转服务中 ==="
log "验收：约 15 分钟后查 /var/log/ipes_bind_auto.log 末尾的终验快照，或到渠道后台看节点（inService + online + 云主机备注）"

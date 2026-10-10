#!/usr/bin/env bash
# IPES 一键部署 r20 裸版（no-tune：不做任何系统调优，happy 进程 9）
# 用法：
#   curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/inline_deploy_r20_oss.sh | bash -s -- \
#     --ak 06d78b19bd0d9fc0aa300c6d \
#     --sk 16d6c46443308e62bb51f22c074a90ed \
#     --jwt eyJ... \
#     --isp 联通 [--province 浙江 --city 杭州 --num-dirs 12 --usbw 200]
# 未传 --province/--city 时，自动按本机公网 IP 识别；识别失败兜底为 浙江/杭州。
set +e
# [REV] wrapper-notune9-20260927（裸版：无任何系统调优，happy=9）
# [REV] wrapper-notune9-limit1-20261004（部署完成后自动融合限速 run_limit.sh，默认 23:59→18:45）
# [REV] q2-new-20261010（改用 Q2_test 官方脚本部署：install_docker-ce_v2.sh + ecache_auto_disk_install.sh -i 2 -t 2；
#        移除旧 full 脚本体系与 B1.5conntrack / B1.6 A级调优两段（纯净版）；新增 B1.9 对齐 happ 9 路）

AK=""; SK=""; JWT=""; ISP="联通"; PROVINCE=""; CITY=""; NUM_DIRS=9; USBW=200; BW_NUM=1
# 【limit1】部署完成后自动执行限速脚本：窗口内限速 4Mbps、窗口外全速冲刺（跨天窗口自动处理）
LIMIT_START="23:59"; LIMIT_END="18:45"; LIMIT_ENABLE=1
NODE_NAT_TYPE="public"; NODE_RESOURCE_TYPE=2; NODE_DIAL_TYPE="staticNetSingle"; NODE_SINGLE_IP_RADIO=0
ADMIN_API_HOST="https://admin.zhouyi.top"; BUSINESS_ID=41
# 【r20-finish】--finish-only：存量机「原地补齐」模式（透传给 full 脚本）
#   跳过安装/注册/容器重建，只补 [5.6]~[13]；容器不重建 → SN/身份不变 → 不掉量。
FINISH_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ak) AK="$2"; shift 2 ;;
    --sk) SK="$2"; shift 2 ;;
    --jwt|--token|--node-activate-token) JWT="$2"; shift 2 ;;
    --isp) ISP="$2"; shift 2 ;;
    --province) PROVINCE="$2"; shift 2 ;;
    --city) CITY="$2"; shift 2 ;;
    --num-dirs) NUM_DIRS="$2"; shift 2 ;;
    --usbw) USBW="$2"; shift 2 ;;
    --bw-num) BW_NUM="$2"; shift 2 ;;
    --business-id) BUSINESS_ID="$2"; shift 2 ;;
    --admin-host) ADMIN_API_HOST="$2"; shift 2 ;;
    --finish-only) FINISH_ONLY=1; shift ;;
    --limit-start) LIMIT_START="$2"; shift 2 ;;
    --limit-end) LIMIT_END="$2"; shift 2 ;;
    --no-limit) LIMIT_ENABLE=0; shift ;;
    *) echo "[WARN] 未知参数: $1"; shift ;;
  esac
done

if [ "${FINISH_ONLY:-0}" != "1" ] && [[ -z "$AK" || -z "$SK" || -z "$JWT" ]]; then
  echo "[ERROR] 缺少 --ak / --sk / --jwt，必须提供（--finish-only 原地补齐模式不注册设备，可免）"
  echo "示例：curl -fsSL ... | bash -s -- --ak <ak> --sk <sk> --jwt <jwt> --isp 联通"
  exit 1
fi

# 自动识别省份/城市（若未显式传入）
get_location_info() {
  local ip_info=$(curl -s myip.ipip.net 2>/dev/null)
  if [ -n "$ip_info" ]; then
    local p=$(echo "$ip_info" | awk -F ' ' '{print $4}' | tr -d ',')
    local c=$(echo "$ip_info" | awk -F ' ' '{print $5}' | tr -d ',')
    if [ -n "$p" ] && [ "$p" != "null" ] && [ "$p" != " " ]; then PROVINCE="$p"; fi
    if [ -n "$c" ] && [ "$c" != "null" ] && [ "$c" != " " ]; then CITY="$c"; fi
  fi
  # 兜底：识别失败仍用浙江/杭州
  [ -z "$PROVINCE" ] && PROVINCE="浙江"
  [ -z "$CITY" ] && CITY="杭州"
}
if [ -z "$PROVINCE" ] || [ -z "$CITY" ]; then
  echo "[INFO] 未提供 --province/--city，尝试根据公网 IP 自动识别..."
  get_location_info
  echo "[INFO] 使用地理位置: $PROVINCE / $CITY"
fi

# 【r20-fix6】移除 NOTRACK：iptables raw NOTRACK 会让回包脱离 conntrack，与 firewalld(nftables/iptables) 共存时
# 导致已建立连接回包被 INPUT 丢弃 → 云助手/SSH 断连（即此前"一跑脚本就断网"根因）。全脚本统一不再使用 NOTRACK。

# ============ B) 部署主体（q2-new-20261010：改用 Q2_test 脚本体系） ============
# 【2026-10-10 用户指定】改用官方Q2_test 部署链路，去掉旧的 ipes_deploy_full.sh 体系：
#   1) install_docker-ce_v2.sh     —— 装docker（含硬化/超时/重试）
#   2) ecache_auto_disk_install.sh —— Q2 部署调度器（自动判断有无数据盘并选分支）
#      它的参数只有 -t（镜像: 2=省外/ 3=省内）和 -i（reg_isp: 1电信/2联通/3移动），**没有路数参数**；
#      路数由脚本内部按「云环境固定 1 个目录 / 非云按 可用GB÷35」自动算。
#      因此 9 路在下面 B1.9 段单独对齐（复用 opt_align 已真机验证的逻辑）。
# 注意：不带 -s/--skip-olmt 等旧参数，保留 set -e 语义（任一步失败即中止）。
echo "===== [B] 安装 docker（install_docker-ce_v2.sh） ====="
if ! curl -fsSL -m 300 https://zyy-go.oss-cn-beijing.aliyuncs.com/script/install_docker/install_docker-ce_v2.sh | bash; then
  echo "[ERROR] install_docker-ce_v2.sh 执行失败（网络或源问题），部署中止"
  exit 1
fi
if ! command -v docker >/dev/null 2>&1 || ! systemctl is-active --quiet docker; then
  echo "[WARN] docker 未就绪（可能仍在启动），等待 20s 后复查"
  sleep 20
  systemctl is-active docker >/dev/null 2>&1 || { echo "[ERROR] docker 服务未起来，部署中止"; exit 1; }
fi
echo "[INFO] docker 就绪: $(docker --version 2>/dev/null)"

echo "===== [B] Q2 部署（ecache_auto_disk_install.sh -i 2 -t 2） ====="
if ! curl -fsSL -m 1800 https://zyy-go.oss-cn-beijing.aliyuncs.com/script/Q2_test/ecache_auto_disk_install.sh | bash -s -- -i 2 -t 2; then
  echo "[ERROR] ecache_auto_disk_install.sh 执行失败，部署中止"
  exit 1
fi
echo "[INFO] Q2 部署脚本执行完毕"

# 导出 token（旧流程里ipes_client 用它做激活，新脚本体系若需要同样有效）
export NODE_ACTIVATE_TOKEN="$JWT"
sed -i 's|^mirrorlist=|#mirrorlist=|g;s|^#\?baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null

# ============ B1.8) 设备注册到渠道云端（reg-20261010） ============
# 【为什么必须补这一段】Q2_test 官方链路（install_docker-ce_v2.sh +
#   ecache_auto_disk_install.sh → uninstall_ecache / umount_disk / auto_mount_disk /
#   ecache_docker_install(_ali_ten) / install_ipes_health_check）全链路实测**不含设备注册**
#   （4 个脚本里 batch/create2 与 channel API 均为0 处；ecache_docker_install_ali_ten.sh 里
#   API_BASE_URL/USERNAME/PASSWORD 是死代码，定义了从未使用）。
#   注册原本由旧 ipes_deploy_full.sh 负责，换链路后若不补，C 段按 device_code
#   在后台匹配不到节点 → 绑定与stateflow 全部失败（节点不会流转到 inService）。
# 逻辑与旧 full 脚本一致：取 32hex device_code + myip.ipip.net 定位 + ZYY+md5(ak+ts+sk) 签名。
CH_API_URL="http://api.zhouyiy.com/qudao/device/v1/batch/create2"
_ch_register() {
  local device_id="$1" province="$2" city="$3" isp="$4"
  local remark="${isp}-${device_id:0:8}"
  local ts sign body rc try
  for try in 1 2 3; do
    ts=$(date +%s)
    sign="ZYY$(echo -n "${AK}${ts}${SK}" | md5sum | cut -d' ' -f1)"
    body='{"devices":[{"device_id":"'"$device_id"'","remark":"'"$remark"'"}],"province":"'"$province"'","city":"'"$city"'","isp":"'"$isp"'"}'
    rc=$(curl -s -w '\n%{http_code}' --location --request POST "$CH_API_URL" \
      --header "sign: $sign" --header "verison: V1.0.0" \
      --header "appKey: $AK" --header "timestamp: $ts" \
      --header 'Content-Type: application/json' --data "$body" \
      --connect-timeout 10 --max-time 30 2>/dev/null)
    local code=$(printf '%s' "$rc" | tail -n1)
    local resp=$(printf '%s' "$rc" | sed '$d')
    if [ "$code" = "200" ] && printf '%s' "$resp" | grep -q '全部绑定成功\|全部已存在'; then
      echo "[INFO] 设备注册成功（尝试 $try）: $resp" | head -c 300; echo
      { echo "注册时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "设备SN: $device_id"; echo "省份: $province"; echo "城市: $city"
        echo "运营商: $isp"; echo "备注: $remark"; echo "API响应: $resp"; } \
        > /usr/local/edge/registration_info 2>/dev/null
      chmod 644 /usr/local/edge/registration_info 2>/dev/null
      return 0
    fi
    echo "[WARN] 注册返回异常（HTTP $code, 尝试 $try）: $(printf '%s' "$resp" | head -c 200)"
    sleep 2
  done
  echo "[ERROR] 设备注册失败（3 次重试耗尽）——C 段绑定可能失败，但不影响容器已起来"
  return 1
}

DC=""
for _f in /usr/local/edge_zycloud/device_code /usr/local/edge/device_code /etc/.mac; do
  if [ -s "$_f" ]; then DC=$(tr -d ' \r\n' < "$_f"); break; fi
done
if [ -n "$DC" ]; then
  _loc=$(curl -s --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 10 myip.ipip.net 2>/dev/null)
  _prov=$(printf '%s' "$_loc" | awk -F' ' '{print $4}' | tr -d ',')
  _city=$(printf '%s' "$_loc" | awk -F' ' '{print $5}' | tr -d ',')
  [ -z "$_prov" ] && _prov="$PROVINCE"
  [ -z "$_city" ] && _city="$CITY"
  echo "===== [B1.8] 设备注册（device=$DC / ${_prov:-?}${_city:-?} / $ISP） ====="
  _ch_register "$DC" "$_prov" "$_city" "$ISP" || true
else
  echo "[WARN] 未找到 device_code（32hex），跳过设备注册（后台绑定可能失败）"
fi

# ============ B1.9) happ 路数对齐到 9 路（happy9-20261010） ============
# 背景：新部署链路不接路数参数（实测 ecache_docker_install_ali_ten.sh 只认 -t/-i，
#   传 -n 会「未知选项」直接退出），且内部对云环境固定 1 个目录 → 与期望的 9 路不符。
# 做法：部署完成后按 opt_align 已真机验证的形态对齐（改 custom.yml + 建分片 + 重启容器）。
# 幂等：重复执行安全；-1 分片或配置异常时放弃替换，不破坏现场。
HAPP_ROOT=/data/happ
HAPP_CFG=/opt/ipes/var/db/ipes/happ-conf/custom.yml
if docker inspect ipes >/dev/null 2>&1 && [ -f "$HAPP_CFG" ]; then
  echo "===== [B1.9] happ 路数对齐 9 路 ====="
  if [ -d "$HAPP_ROOT/happ.0" ]; then
    _ref="$HAPP_ROOT/happ.0/xycould_base_info"
    for n in $(seq 0 8); do
      [ -d "$HAPP_ROOT/happ.$n" ] || mkdir -p "$HAPP_ROOT/happ.$n"
      # 每片都需要 base_info，否则 happ.N 起不来
      [ -s "$_ref" ] && [ ! -s "$HAPP_ROOT/happ.$n/xycould_base_info" ] \
        && cp -p "$_ref" "$HAPP_ROOT/happ.$n/xycould_base_info" 2>/dev/null
    done
    echo "[INFO] 9 个缓存分片就绪"
  else
    echo "[WARN] $HAPP_ROOT/happ.0 不存在（缓存未初始化），跳过建分片"
  fi

  # 改 custom.yml（先备份，生成后校验条数，不符则放弃）
  _bk="$HAPP_CFG.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$HAPP_CFG" "$_bk" 2>/dev/null
  _tmp=$(mktemp)
  {
    echo "# q2 happy9 $(date '+%F %T')"
    echo "args:"
    for n in $(seq 0 8); do echo "  - $HAPP_ROOT/happ.$n"; done
    grep -E '^reg_isp:' "$HAPP_CFG" 2>/dev/null
  } > "$_tmp"
  _cnt=$(grep -cE "^  - ${HAPP_ROOT}/happ\.[0-9]+$" "$_tmp")
  if [ "$_cnt" = "9" ]; then
    cp -p "$_tmp" "$HAPP_CFG" && rm -f "$_tmp"
    echo "[INFO] custom.yml 已设为 9 路（备份 $_bk）"
    echo "[INFO] 重启 ipes 使路数生效（约 30~60 秒断流）"
    docker restart ipes >/dev/null 2>&1
    sleep 25
    echo "[INFO] 容器状态: $(docker inspect -f '{{.State.Running}}' ipes 2>/dev/null) | happ 进程数: $(docker exec ipes sh -c 'ps -ef | grep -c "[h]app:vod"' 2>/dev/null | tr -d '\r')"
  else
    rm -f "$_tmp"
    echo "[WARN] 生成配置条数异常（$_cnt != 9），放弃替换custom.yml（保留现场）"
  fi
else
  echo "[WARN] 未检测到 ipes 容器或 custom.yml，跳过 happy9 对齐"
fi

# ============ B2) 单机互斥锁（q2-new-20261010） ============
# 背景：2026-09-17 上海新机事故 —— 同一台机上两份部署并发在跑，共用中间文件互相覆盖 → 容器全停。
# 做法：flock 单机互斥；重复调用直接退出，绝不产生第二份部署。
#注：旧版这里会 `exec setsid bash /root/ipes_full.sh ...`（后台跑 + 靠锁释放通知 B3 限速），
#   新部署链路里 full 脚本已不再使用，改为**前台顺序执行**（B 段已跑完），
#   因此这里的锁只用于「防并发重入」，跑完立即释放，B3 限速跟随器随即启动。
LOCK_FILE="/var/run/ipes_deploy.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[ERROR] 本机已有部署在运行（$LOCK_FILE 被占用），本次退出以避免两份互踩"
  echo "        确认前一份确已结束/卡死时可清理： rm -f $LOCK_FILE"
  exit 1
fi
echo "[INFO] 已获取部署锁 $LOCK_FILE（互斥生效）"
[ "${FINISH_ONLY:-0}" = "1" ] && echo "[INFO] --finish-only：仅做 happy9 对齐，不重装业务"
# B 段（docker + Q2 部署）已在前台执行完毕；此处仅等待锁释放给 B3 跟随器用。
flock -u 9
exec 9>&-
echo "[INFO] 部署主流程完成，释放锁（限速跟随器开始等待）"

# ============ B3) 部署完成后自动限速（limit1：融合 run_limit.sh） ============
# 跟随器：阻塞等待 $LOCK_FILE 锁释放（= ipes_full.sh 整体跑完）→ 等 120s 让容器/watchdog 稳定
#   → 执行 run_limit.sh 装限速（幂等，自装 cron：窗口内每10min补挂 + 结束清除 + @reboot 180s 自恢复）
# 日志：/var/log/ipes_limit_bg.log；--no-limit 可跳过；--limit-start/--limit-end 自定义窗口
if [ "$LIMIT_ENABLE" = "1" ]; then
  cat > /root/ipes_limit_after_deploy.sh <<LIM
#!/bin/bash
# 由 inline_deploy wrapper 生成：部署结束后自动限速
sleep 120
echo "[\$(date +'%F %T')] deploy finished, applying limit ($LIMIT_START -> $LIMIT_END) ..." >> /var/log/ipes_limit_bg.log
curl -fsSL -m 90 https://zyy-go.oss-cn-beijing.aliyuncs.com/script/limit/run_limit.sh | tr -d '\r' | bash -s -- "$LIMIT_START" "$LIMIT_END" >> /var/log/ipes_limit_bg.log 2>&1
echo "[\$(date +'%F %T')] limit done, exit=\$?" >> /var/log/ipes_limit_bg.log
LIM
  chmod +x /root/ipes_limit_after_deploy.sh
  ( flock "$LOCK_FILE" /root/ipes_limit_after_deploy.sh ) &
  LIMIT_PID=$!
  echo "已挂限速跟随器 PID=$LIMIT_PID：部署结束后自动执行 run_limit.sh（$LIMIT_START → $LIMIT_END），日志 /var/log/ipes_limit_bg.log"
else
  echo "[INFO] --no-limit：本次跳过自动限速"
fi

# ============ C) 业务绑定自修复（r20-fix4 根治版） ============
# 三大修复：
#   1) is_bound 读 nodeInfo（vendor/usbw 真正所在），不再读 nominalInfo（恒 0，导致永远误判未绑定→反复重绑）
#   2) 节点匹配优先用本机 device_code（32hex nodeID）精确匹配；按 IP 兜底时排除 status=offline 的孤儿记录
#   3) stateflow 的 hostname 必须用 76hex 真业务SN（ipes_sn），绝不用后台 sn 字段（那是 UUID，会毁掉业务标签）
cat > /root/ipes_repair_binding.py <<'PY'
import json, os, re, ssl, sys, time, urllib.request, urllib.error

JWT = os.environ.get('NODE_ACTIVATE_TOKEN','')
if not JWT:
    print("[ERROR] NODE_ACTIVATE_TOKEN 未设置"); sys.exit(1)

BASE = os.environ.get('ADMIN_API_HOST','https://admin.zhouyi.top')
BUSINESS_ID = int(os.environ.get('BUSINESS_ID','41'))
ISP = os.environ.get('ISP','联通')
PROVINCE = os.environ.get('PROVINCE','')
CITY = os.environ.get('CITY','')
NODE_NAT_TYPE = os.environ.get('NODE_NAT_TYPE','public')
NODE_RESOURCE_TYPE = int(os.environ.get('NODE_RESOURCE_TYPE','2'))
NODE_DIAL_TYPE = os.environ.get('NODE_DIAL_TYPE','staticNetSingle')
NODE_SINGLE_IP_RADIO = int(os.environ.get('NODE_SINGLE_IP_RADIO','0'))
NODE_USBW = int(os.environ.get('NODE_USBW','200'))
NODE_BW_NUM = int(os.environ.get('NODE_BW_NUM','1'))
DEPLOY_PID_FILE = os.environ.get('DEPLOY_PID_FILE','/var/run/ipes_deploy.pid')
# 【q2-new-20261010】部署改为前台顺序执行（不再后台跑 full 脚本），
#   所以这里只需等一个短窗口让容器与注册收尾，避免白等 25 分钟。
WAIT_DEPLOY_SEC = int(os.environ.get('REPAIR_WAIT_DEPLOY','30'))
# 等节点注册 + 76hex 业务SN 就绪，最长 30 分钟；SN 只在容器起来后才有
WAIT_READY_SEC = int(os.environ.get('REPAIR_WAIT_READY','1800'))

CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE

def log(msg): print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

def admin_call(path, body=None, method="GET"):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("x-token", JWT)
    if body is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(body).encode()
    try:
        r = urllib.request.urlopen(req, context=CTX, timeout=30)
        return r.getcode(), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def get_public_ip():
    for url in ["http://myip.ipip.net","http://ip.sb","http://checkip.amazonaws.com"]:
        try:
            r = urllib.request.urlopen(url, timeout=5)
            ips = re.findall(r'\d+\.\d+\.\d+\.\d+', r.read().decode().strip())
            if ips: return ips[0]
        except Exception: continue
    return None

def get_local_node_id():
    # edge_client 的 device_code 即后台 32hex nodeID（r19+ 已验证）
    for f in ["/usr/local/edge_zycloud/device_code"]:
        try:
            v = open(f).read().strip()
            if re.fullmatch(r'[0-9a-f]{32}', v): return v
        except Exception: pass
    return None

def get_real_sn():
    # 76hex 业务SN：只认容器内 ipes_sn / 宿主 IPES_SN，绝不用后台 sn（UUID）
    for cmd in ["docker exec ipes cat /app/ipes/bin/ipes_sn",
                "cat /opt/soft/disk/IPES_SN"]:
        try:
            v = os.popen(cmd + " 2>/dev/null").read().strip()
            if len(v) >= 60: return v
        except Exception: pass
    return None

def fetch_all_nodes(max_pages=80):
    out = []
    for page in range(1, max_pages + 1):
        code, txt = admin_call(f"/api/edgeNode/getEdgeNodeList?page={page}&pageSize=200")
        if code != 200:
            log(f"getEdgeNodeList page {page} failed HTTP {code}: {txt[:200]}"); break
        d = json.loads(txt)
        arr = (d.get('data') or {}).get('list', [])
        total = (d.get('data') or {}).get('total', 0)
        out.extend(arr)
        if page * 200 >= total: break
        time.sleep(0.15)
    return out

def pick_node(pubip, local_nid):
    nodes = fetch_all_nodes()
    if local_nid:
        for it in nodes:
            if it.get('nodeID') == local_nid:
                log(f"按 device_code 精确匹配到本机节点: {local_nid}")
                return it
        log(f"device_code={local_nid} 尚未出现在后台，等待注册...")
        return None
    # 兜底：按 IP 匹配，排除 offline 孤儿，优先 inService
    cands = [it for it in nodes if it.get('publicIP') == pubip and it.get('status') != 'offline']
    if not cands: return None
    stage_rank = {'inService': 3, 'configured': 2, 'waitAudit': 1}
    cands.sort(key=lambda x: (stage_rank.get(x.get('stage'), 0), x.get('nodeUpdateTime') or x.get('UpdatedAt') or ''), reverse=True)
    return cands[0]

def is_bound(ni):
    if not ni: return False
    if ni.get('stage') != 'inService': return False
    info = ni.get('nodeInfo') or {}          # ★ 绑定信息在 nodeInfo，nominalInfo 恒空是正常形态
    return info.get('vendorSuggestCustomers') == BUSINESS_ID and info.get('usbw') == NODE_USBW

def tag_ok(ni, sn):
    tags = ni.get('business_tags') or []
    return bool(tags) and any(t.get('hostName') == sn for t in tags)

def do_bind(node_id, sn, pubip, local_nid, max_try=6):
    for attempt in range(1, max_try + 1):
        log(f"为本机节点 {node_id} 补绑业务 {BUSINESS_ID}（第 {attempt}/{max_try} 次）")
        # 1) 先降到 configured（平台规则：inService/waitAudit 下 updateEdgeNominalInfo 返 code:7，必须先降）
        for _ in range(2):
            code, txt = admin_call("/api/edgeNode/stateflow", {"nodes": [node_id], "stage": "configured", "hostname": sn or ""}, "POST")
            log(f"  -> configured: HTTP {code} {txt[:120]}")
            time.sleep(1)
        # 2) 写 nodeInfo（唯一写通道）
        body = {
            "nodeId": node_id, "province": PROVINCE or "浙江", "city": CITY or "杭州",
            "isp": ISP, "natType": NODE_NAT_TYPE, "resourceType": NODE_RESOURCE_TYPE,
            "dialType": NODE_DIAL_TYPE, "singleIpRadio": NODE_SINGLE_IP_RADIO,
            "usbw": NODE_USBW, "bwNum": NODE_BW_NUM, "transMode": 0,
            "transModeStr": "cm:0,ct:0,cu:0", "transProvRate": 0, "isTransProv": True,
            "isIPv6Schedule": False, "isCrossNetwork": False, "crossNetworkIsp": None,
            "vendorSuggestCustomers": BUSINESS_ID
        }
        code, txt = admin_call("/api/edgeNode/updateEdgeNominalInfo", body, "POST")
        log(f"  -> updateEdgeNominalInfo: HTTP {code} {txt[:120]}")
        time.sleep(1)
        # 3) 升回服务中，携带真 76hex SN（hostname 绝不能用 UUID/空串，否则后台写占位符毁标签）
        code, txt = admin_call("/api/edgeNode/stateflow", {"nodes": [node_id], "stage": "inService", "hostname": sn or ""}, "POST")
        log(f"  -> inService: HTTP {code} {txt[:120]}")
        time.sleep(3)
        ni = pick_node(pubip, local_nid)
        if ni and is_bound(ni) and (not sn or tag_ok(ni, sn)):
            log(f"[OK] 修复成功（第 {attempt} 次）")
            return True
        time.sleep(5)
    log("[ERROR] 多次重试仍未达标")
    return False

def deploy_still_running():
    # Phase B 完整部署（ipes_full.sh）进程是否还在；不在则视为部署结束
    try:
        pid = int(open(DEPLOY_PID_FILE).read().strip())
    except Exception:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

def wait_for(predicate, total_sec, step_sec, label):
    waited = 0
    while waited < total_sec:
        if predicate():
            return True
        if waited % 60 == 0:
            log(f"等待{label}... ({waited}/{total_sec}s)")
        time.sleep(step_sec)
        waited += step_sec
    return predicate()

def main():
    pubip = get_public_ip()
    if not pubip: log("[ERROR] 无法获取公网 IP"); sys.exit(1)
    log(f"本机公网 IP: {pubip}")
    local_nid = get_local_node_id()
    log(f"本机 device_code(nodeID): {local_nid or '未读到，走IP兜底'}")

    # 1) 等 Phase B 完整部署进程结束（避免与它抢 stateflow；部署 8~20 分钟）
    if wait_for(lambda: not deploy_still_running(), WAIT_DEPLOY_SEC, 5, "部署进程结束"):
        log("部署进程已结束，进入绑定核验")
    else:
        log("[警告] 等待部署进程超时，仍继续尝试绑定核验")

    # 2) 等节点注册 + 76hex 业务SN 就绪（SN 只在容器起来后才有）
    sn = None
    ni = None
    deadline = time.time() + WAIT_READY_SEC
    while time.time() < deadline:
        if not sn:
            sn = get_real_sn()
            if sn: log(f"本机 76hex 业务SN: {sn[:20]}...{sn[-12:]}")
        ni = pick_node(pubip, local_nid)
        if ni and sn: break
        time.sleep(10)
    # ★ 关键：SN 缺失绝不流转——否则后台写占位符 ZHOUYI_XIAODU 毁掉业务标签
    if not ni or not sn:
        log(f"[ERROR] 超时仍未就绪（node={'有' if ni else '无'} sn={'有' if sn else '无'}），放弃（不绑定空 SN）")
        sys.exit(1)

    info = ni.get('nodeInfo') or {}
    log(f"节点: {ni.get('nodeID')} stage={ni.get('stage')} status={ni.get('status')} nodeInfo.vendor={info.get('vendorSuggestCustomers')} usbw={info.get('usbw')}")
    if is_bound(ni) and (not sn or tag_ok(ni, sn)):
        log("[OK] 已绑定且业务标签正确，无需修复"); sys.exit(0)
    ok = do_bind(ni.get('nodeID'), sn, pubip, local_nid)
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()

PY

# 持久化自修复环境（供重启后自愈钩子复用；含 JWT，属敏感，权限收紧）
umask 077
cat > /root/.ipes_repair_env <<ENV
export NODE_ACTIVATE_TOKEN='${JWT}'
export ADMIN_API_HOST='${ADMIN_API_HOST}'
export BUSINESS_ID='${BUSINESS_ID}'
export ISP='${ISP}'
export PROVINCE='${PROVINCE}'
export CITY='${CITY}'
export NODE_NAT_TYPE='${NODE_NAT_TYPE}'
export NODE_RESOURCE_TYPE='${NODE_RESOURCE_TYPE}'
export NODE_DIAL_TYPE='${NODE_DIAL_TYPE}'
export NODE_SINGLE_IP_RADIO='${NODE_SINGLE_IP_RADIO}'
export NODE_USBW='${NODE_USBW}'
export NODE_BW_NUM='${NODE_BW_NUM}'
export DEPLOY_PID_FILE='/var/run/ipes_deploy.pid'
ENV
chmod 600 /root/.ipes_repair_env

# 重启后自愈：部署末尾若触发内核升级重启，Phase C 进程会被 kill 而留下「待配置」。
# 这里装一个 @reboot 钩子，开机 60s 后重新跑绑定自修复（仅当节点尚未服务中才真正流转）。
cat > /root/ipes_repair_once.sh <<'WRAP'
#!/bin/bash
export PATH=/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin:$PATH
flock -n /var/lock/ipes_repair_once.lock true || exit 0
. /root/.ipes_repair_env 2>/dev/null || true
[ -n "$NODE_ACTIVATE_TOKEN" ] || exit 0
# @reboot 调用时等 60s 让网络/容器就绪；周期 cron 调用时传 nowait 跳过等待
[ "$1" = "nowait" ] || sleep 60
cd /root
python3 /root/ipes_repair_binding.py >>/var/log/ipes_repair_reboot.log 2>&1
WRAP
chmod 700 /root/ipes_repair_once.sh
# 幂等安装 @reboot + 周期任务（先清旧的再装，避免重复）
# @reboot：覆盖「内核升级重启 kill 掉 Phase C」场景
# */10 * * * *：覆盖「容器重建/业务 ID 漂移但宿主机未重启」场景
( crontab -l 2>/dev/null | grep -v 'ipes_repair_once.sh' ; \
  echo '@reboot /bin/bash /root/ipes_repair_once.sh' ; \
  echo '*/10 * * * * /bin/bash /root/ipes_repair_once.sh nowait' ) | crontab -

export NODE_ACTIVATE_TOKEN="$JWT" ADMIN_API_HOST BUSINESS_ID ISP PROVINCE CITY \
       NODE_NAT_TYPE NODE_RESOURCE_TYPE NODE_DIAL_TYPE NODE_SINGLE_IP_RADIO \
       NODE_USBW NODE_BW_NUM REPAIR_WAIT_DEPLOY=30

nohup setsid python3 /root/ipes_repair_binding.py >/var/log/ipes_repair.log 2>&1 </dev/null &
REPAIR_PID=$!
echo "已后台启动绑定自修复 PID=$REPAIR_PID"
echo ""
echo "部署日志：  见上方[B]/[B1.9] 段落输出"
echo "docker 日志： docker logs -f ipes"
echo "修复日志：  tail -f /var/log/ipes_repair.log"

#!/usr/bin/env bash
# IPES 一键部署 r21（OSS 短链版：调优 + 部署）
# 用法：
#   curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/inline_deploy_r21_oss.sh | bash -s -- \
#     --ak 06d78b19bd0d9fc0aa300c6d \
#     --sk 16d6c46443308e62bb51f22c074a90ed \
#     --jwt eyJ... \
#     --isp 电信 [--province 浙江 --city 杭州 --num-dirs 12 --usbw 200]
# 未传 --province/--city 时，自动按本机公网 IP 识别（多源、每个源都带超时）；
# 识别失败兜底为 浙江/杭州，并把结果透传给 ipes_deploy_full.sh（一次识别、两处一致）。
#
# ★20260915 修复"总卡在识别地区 / 看着没反应"★
#   ① 地区识别：官方 zyy_init 那行 `curl -s myip.ipip.net` 没带超时，机房侧一抖就无限等；
#      这里每个源都带 --max-time，主源失败自动换备源（ip-api 中文 / 云元数据 region-id）。
#   ② 调优步骤：原来 `bash ipes_tune.sh 2>&1 | tail -30` —— 管道会把 tune 的全部输出
#      憋到进程结束才吐，云助手日志就永远定在"使用地理位置"那一行，看起来像卡死。
#      改成「落盘 + 每 10s 心跳 + timeout 480 硬上限」，全程可见、有界。
#   ③ 下载：统一加 --connect-timeout，并多一个国内可达镜像源。
set +e
R21_REV="20260915e"

AK=""; SK=""; JWT=""; ISP="电信"; PROVINCE=""; CITY=""; NUM_DIRS=12; USBW=200; BW_NUM=1
NODE_NAT_TYPE="public"; NODE_RESOURCE_TYPE=2; NODE_DIAL_TYPE="staticNetSingle"; NODE_SINGLE_IP_RADIO=0
ADMIN_API_HOST="https://admin.zhouyi.top"; BUSINESS_ID=41

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
    *) echo "[WARN] 未知参数: $1"; shift ;;
  esac
done

if [[ -z "$AK" || -z "$SK" || -z "$JWT" ]]; then
  echo "[ERROR] 缺少 --ak / --sk / --jwt，必须提供"
  echo "示例（注意：值要写裸值，不要带尖括号 <>，否则会被 shell 当成输入重定向）："
  echo "  curl -fsSL ... | bash -s -- --ak 你的渠道AK --sk 你的渠道SK --jwt 你的JWT --isp 电信"
  exit 1
fi

echo "[r21] rev=$R21_REV  $(date '+%F %T')  host=$(hostname)  pid=$$"
echo "[r21] 本次参数: isp=$ISP num-dirs=$NUM_DIRS usbw=$USBW province=${PROVINCE:-自动} city=${CITY:-自动}"

# -----------------------------------------------------------------------------
# 自动识别省份/城市（若未显式传入）
#   与官方 zyy_init_max.sh 同源同算法：curl myip.ipip.net → awk -F' ' '{print $4/$5}'
#   （实测字段：[1]=当前 [2]=IP：x.x.x.x [3]=来自于：中国 [4]=省 [5]=市 [6]=运营商）
#   但官方那行没超时 —— 机房侧一抖就无限等，表现就是"卡在识别地区"。
#   这里每个源都带 --max-time；主源失败换备源；最后才落兜底值。
# -----------------------------------------------------------------------------
# 省名归一：ip-api 会返回"天津市/广东省"，而 ipip 返回"天津/广东"，统一成后者
geo_norm_prov() {
  printf '%s' "$1" | sed -e 's/省$//' -e 's/市$//' -e 's/壮族自治区$//' \
    -e 's/回族自治区$//' -e 's/维吾尔自治区$//' -e 's/自治区$//' -e 's/特别行政区$//'
}
geo_norm_city() { printf '%s' "$1" | sed -e 's/市$//'; }
# region-id（cn-shenzhen）→ 省市：内网元数据是最后的可靠兜底
geo_map_region() {
  case "$1" in
    cn-shenzhen)    echo "广东 深圳" ;;
    cn-guangzhou)   echo "广东 广州" ;;
    cn-heyuan)      echo "广东 河源" ;;
    cn-hangzhou)    echo "浙江 杭州" ;;
    cn-shanghai)    echo "上海 上海" ;;
    cn-beijing)     echo "北京 北京" ;;
    cn-qingdao)     echo "山东 青岛" ;;
    cn-wuhan*)      echo "湖北 武汉" ;;
    cn-chengdu)     echo "四川 成都" ;;
    cn-zhangjiakou) echo "河北 张家口" ;;
    cn-hongkong)    echo "中国香港 中国香港" ;;
    *)              echo "" ;;
  esac
}
get_location_info() {
  local ip_info p c rid loc j
  # ① 主源：myip.ipip.net（与官方一致）
  ip_info=$(curl -s --connect-timeout 4 --max-time 8 myip.ipip.net 2>/dev/null)
  if [ -n "$ip_info" ]; then
    p=$(printf '%s\n' "$ip_info" | awk -F ' ' '{print $4}' | tr -d ',')
    c=$(printf '%s\n' "$ip_info" | awk -F ' ' '{print $5}' | tr -d ',')
    [ -n "$p" ] && [ "$p" != "null" ] && PROVINCE="$p"
    [ -n "$c" ] && [ "$c" != "null" ] && CITY="$c"
  fi
  echo "[geo] 主源 myip.ipip.net      -> ${PROVINCE:-?} / ${CITY:-?}"
  # ② 备源：ip-api.com（中文 JSON，海外但常年可达）
  if [ -z "$PROVINCE" ] || [ -z "$CITY" ]; then
    j=$(curl -s --connect-timeout 4 --max-time 8 "http://ip-api.com/json/?lang=zh-CN&fields=regionName,city" 2>/dev/null)
    p=$(printf '%s' "$j" | sed -n 's/.*"regionName":"\([^"]*\)".*/\1/p')
    c=$(printf '%s' "$j" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
    [ -n "$p" ] && PROVINCE="$(geo_norm_prov "$p")"
    [ -n "$c" ] && CITY="$(geo_norm_city "$c")"
    echo "[geo] 备源 ip-api.com(zh-CN)  -> ${PROVINCE:-?} / ${CITY:-?}"
  fi
  # ③ 备源：阿里云元数据 region-id（内网 100.100.100.200，免 DNS、免公网）
  if [ -z "$PROVINCE" ] || [ -z "$CITY" ]; then
    rid=$(curl -s --connect-timeout 2 --max-time 3 "http://100.100.100.200/latest/meta-data/region-id" 2>/dev/null | tr -d '\r\n')
    loc=$(geo_map_region "$rid")
    if [ -n "$loc" ]; then PROVINCE=${loc%% *}; CITY=${loc##* }; fi
    echo "[geo] 备源 region-id(${rid:-无响应}) -> ${PROVINCE:-?} / ${CITY:-?}"
  fi
  # 兜底：识别失败仍用浙江/杭州
  [ -z "$PROVINCE" ] && PROVINCE="浙江"
  [ -z "$CITY" ] && CITY="杭州"
}
if [ -z "$PROVINCE" ] || [ -z "$CITY" ]; then
  echo "[INFO] 未提供 --province/--city，尝试根据公网 IP 自动识别..."
  get_location_info
  echo "[INFO] 使用地理位置: $PROVINCE / $CITY"
else
  echo "[INFO] 使用指定地理位置: $PROVINCE / $CITY"
fi

# ============ A) 系统调优（r21：磁盘吞吐 + 上下行）============
#   独立脚本 ipes_tune.sh：磁盘队列 / 挂载参数 / 内核 sysctl / 网卡 / nofile
#   幂等、可重复执行、装机后由 ipes-tune.service 开机自动重放
#   主脚本 r21 内嵌同一份调优作兜底（这里先跑一遍，后面所有步骤都受益）
TUNE_SHA="477dc50494d42f7675233f0cd75be52cef1cb5d9"
# ★防"静默下发旧版"★：ghproxy.net 对上游 raw 有 CDN 缓存（?t= 只绕它自己那层），
#   实测曾取回 28428B 旧版而不是 29404B 新版。故除"含 IPES TUNE"外，
#   还强制要求版本指纹相等；不相等即判过期 → 换下一个源（jsdelivr 按 commit SHA 取，不可变）。
TUNE_REV_EXPECT="20260915c"
TUNE1="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_tune.sh?t=$(date +%s)"
TUNE2="https://ghfast.top/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_tune.sh?t=$(date +%s)"
TUNE3="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@${TUNE_SHA}/ipes_tune.sh"
TUNE_OK=0
echo "[step 1/2][tune] 拉取调优脚本（3 个源依次尝试，每个源 --connect-timeout 5 -m 30）..."
for u in "$TUNE1" "$TUNE2" "$TUNE3"; do
  echo "  [tune] 尝试源: $(printf '%s' "$u" | sed -e 's|?t=[0-9]*||' | cut -c1-64)..."
  # 先下到临时文件：否则源不可达时 /root/ipes_tune.sh 会残留上一版，
  # 而后面 ipes_deploy_full.sh 的"版本一致性闸门"只认 OWNER 标记 → 会复用这个过期副本
  rm -f /root/.tune.try
  if curl -fsSL --connect-timeout 5 -m 30 "$u" -o /root/.tune.try 2>/dev/null \
     && grep -q "IPES TUNE" /root/.tune.try \
     && grep -q "TUNE_REV=\"$TUNE_REV_EXPECT\"" /root/.tune.try; then
    mv -f /root/.tune.try /root/ipes_tune.sh
    TUNE_OK=1; break
  fi
  if [ -s /root/.tune.try ] && grep -q "IPES TUNE" /root/.tune.try; then
    echo "[tune][WARN] 该源返回的 tune 版本过期（缺 TUNE_REV=${TUNE_REV_EXPECT}，多为 CDN 缓存），换下一个源"
  fi
  rm -f /root/.tune.try
done
if [ "$TUNE_OK" = "1" ]; then
  echo "[tune] $(grep -o 'TUNE_REV="[^"]*"' /root/ipes_tune.sh | head -1) $(grep -o 'TUNE_VER="[^"]*"' /root/ipes_tune.sh | head -1) applying ..."
  # ★不再 `| tail -30`★：管道会把 tune 的全部输出憋到进程结束才吐 → 云助手日志定在上一行
  #   不动，看着像卡死。改为落盘 + 心跳（每 10s 一行）+ timeout 480 硬上限。
  : > /var/log/ipes_tune_run.log
  timeout 480 bash /root/ipes_tune.sh >>/var/log/ipes_tune_run.log 2>&1 &
  TUNE_PID=$!
  while kill -0 "$TUNE_PID" 2>/dev/null; do
    sleep 10
    kill -0 "$TUNE_PID" 2>/dev/null || break
    echo "[tune] 运行中 $(date '+%H:%M:%S') | 最近: $(tail -1 /var/log/ipes_tune_run.log 2>/dev/null | cut -c1-90)"
  done
  wait "$TUNE_PID"; TUNE_RC=$?
  if [ "$TUNE_RC" = "124" ]; then
    echo "[tune][WARN] 480s 超时被强制结束 —— 调优可能只做了一半（不阻塞部署；可事后单跑 /usr/local/bin/ipes-tune.sh）"
  fi
  echo "[tune] 结束 rc=${TUNE_RC}，日志末尾 25 行："
  tail -25 /var/log/ipes_tune_run.log 2>/dev/null
else
  echo "[tune][WARN] 调优脚本下载失败（或两个源的内容都过期）；主脚本 r21 内嵌同一份，部署时会补做"
  # ★关键★：把过期副本删掉。否则下方 ipes_deploy_full.sh 的"版本一致性闸门"只认 OWNER 标记，
  # 会把这个旧版 cp 过去 —— 等于缓存过期照样上线。
  # 删掉后闸门回落到"内嵌正文"，而内嵌正文随 full_deploy 一起下发（下方 SRC 循环已校验其世代）。
  if [ -f /root/ipes_tune.sh ] && ! grep -q "TUNE_REV=\"$TUNE_REV_EXPECT\"" /root/ipes_tune.sh; then
    rm -f /root/ipes_tune.sh
    echo "[tune][WARN] 已移除过期副本 /root/ipes_tune.sh，避免被版本一致性闸门复用"
  fi
fi

# ============ B) 完整部署（r21：真实 nodeId 绑定 + 内嵌调优兜底）============
SRC_SHA="477dc50494d42f7675233f0cd75be52cef1cb5d9"
SRC_REV_EXPECT="20260915e"
SRC1="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_deploy_full.sh?t=$(date +%s)"
SRC2="https://ghfast.top/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_deploy_full.sh?t=$(date +%s)"
SRC3="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@${SRC_SHA}/ipes_deploy_full.sh"
echo "[step 2/2][deploy] 拉取部署脚本（约 110KB，3 个源依次尝试）..."
for u in "$SRC1" "$SRC2" "$SRC3"; do
  # 同样要求"含当前世代的内嵌 tune"：full_deploy 里内嵌的正是 tune 全文，含 TUNE_REV 指纹。
  # 这样即使 ghproxy 命中旧缓存，也会被识别并换源（jsdelivr 按 commit SHA 取，不可变）。
  rm -f /root/.full.try
  if curl -fsSL --connect-timeout 5 -m 60 "$u" -o /root/.full.try 2>/dev/null \
     && grep -q singleIpRadio /root/.full.try \
     && grep -q "FULL_REV=\"$SRC_REV_EXPECT\"" /root/.full.try \
     && grep -q "TUNE_REV=\"$TUNE_REV_EXPECT\"" /root/.full.try; then
    mv -f /root/.full.try /root/ipes_full.sh
    break
  fi
  if [ -s /root/.full.try ] && grep -q singleIpRadio /root/.full.try; then
    echo "[deploy][WARN] 该源返回的部署脚本世代过期（缺 FULL_REV=${SRC_REV_EXPECT}），换下一个源"
  fi
  rm -f /root/.full.try
done
sed -i 's|^mirrorlist=|#mirrorlist=|g;s|^#\?baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
# 三个源都拿不到正确世代的部署脚本时，宁可明确失败，也不要拿旧副本/空文件去做半套部署
if [ ! -s /root/ipes_full.sh ]; then
  echo "[deploy][ERROR] 三个源的部署脚本都不可用或已过期，已终止（请稍后重试或检查网络/镜像）"
  exit 1
fi
echo "[deploy] 已取回部署脚本 $(wc -c < /root/ipes_full.sh)B（世代校验通过：含 TUNE_REV=${TUNE_REV_EXPECT}）"
export NODE_ACTIVATE_TOKEN="$JWT"
# ★关键★ --province/--city 必须显式透传：否则 full.sh 会自己再识别一次（且它识别失败兜底是"北京"），
#   同一台机器两处地区对不上（r21 绑业务用一个地区、注册设备用另一个）。
nohup setsid bash /root/ipes_full.sh --ak "$AK" --sk "$SK" --isp "$ISP" --num-dirs "$NUM_DIRS" \
  --province "$PROVINCE" --city "$CITY" --skip-olmt >/var/log/ipes_nohup.log 2>&1 </dev/null &
DEPLOY_PID=$!
echo "已后台启动部署 PID=$DEPLOY_PID"
sleep 5
echo "[deploy] 启动 5s 后日志预览（完整日志：tail -f /var/log/ipes_nohup.log）："
tail -6 /var/log/ipes_nohup.log 2>/dev/null || echo "  (日志还没落盘)"

# ============ C) 业务绑定自修复 ============
cat > /root/ipes_repair_binding.py <<'PY'
import json, os, re, ssl, subprocess, sys, time, urllib.request, urllib.error

JWT = os.environ.get('NODE_ACTIVATE_TOKEN','')
if not JWT:
    print("[ERROR] NODE_ACTIVATE_TOKEN 未设置"); sys.exit(1)

BASE = os.environ.get('ADMIN_API_HOST','https://admin.zhouyi.top')
BUSINESS_ID = int(os.environ.get('BUSINESS_ID','41'))
ISP = os.environ.get('ISP','电信')
PROVINCE = os.environ.get('PROVINCE','')
CITY = os.environ.get('CITY','')
NODE_NAT_TYPE = os.environ.get('NODE_NAT_TYPE','public')
NODE_RESOURCE_TYPE = int(os.environ.get('NODE_RESOURCE_TYPE','2'))
NODE_DIAL_TYPE = os.environ.get('NODE_DIAL_TYPE','staticNetSingle')
NODE_SINGLE_IP_RADIO = int(os.environ.get('NODE_SINGLE_IP_RADIO','0'))
NODE_USBW = int(os.environ.get('NODE_USBW','200'))
NODE_BW_NUM = int(os.environ.get('NODE_BW_NUM','1'))

CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE

def log(msg): print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

def get_ipes_sn():
    """读容器内真正的 IPES 业务 SN（76 位 hex），用于 inService 的 hostname 字段。"""
    for path in ['/app/ipes/bin/ipes_sn', '/opt/soft/disk/IPES_SN']:
        try:
            out = subprocess.check_output(['docker','exec','ipes','cat',path], stderr=subprocess.DEVNULL, timeout=10)
            sn = out.decode('utf-8','replace').strip()
            if sn: return sn
        except Exception: continue
    return ''

def get_local_node_id():
    """读本机真实 nodeId（32 位 hex）：优先 /etc/.mac，其次 edge_zycloud/device_code。"""
    for path in ['/etc/.mac', '/usr/local/edge_zycloud/device_code', '/opt/soft/disk/device_code']:
        try:
            with open(path, 'r', errors='replace') as f:
                m = re.search(r'\b([0-9a-fA-F]{32})\b', f.read())
                if m: return m.group(1).lower()
        except Exception: continue
    for path in ['/etc/.mac', '/usr/local/edge_zycloud/device_code']:
        try:
            out = subprocess.check_output(['docker','exec','ipes','cat',path], stderr=subprocess.DEVNULL, timeout=10)
            m = re.search(r'\b([0-9a-fA-F]{32})\b', out.decode('utf-8','replace'))
            if m: return m.group(1).lower()
        except Exception: continue
    return ''

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

def node_is_ghost(it):
    """带 outLineTime 的记录=已下线/幽灵记录（同 IP 多机时最容易误绑），跳过。"""
    return bool((it or {}).get('outLineTime'))

def find_node_by_id(node_id):
    """按 nodeID 精确查询：后台支持 ?nodeID=<32hex> 过滤，服务端直接命中、快且唯一。"""
    try:
        code, txt = admin_call(f"/api/edgeNode/getEdgeNodeList?page=1&pageSize=20&nodeID={node_id}")
        if code != 200:
            log(f"getEdgeNodeList(nodeID) HTTP {code}: {txt[:200]}"); return None
        d = json.loads(txt)
        arr = (d.get('data') or {}).get('list', [])
        hit = [it for it in arr if (it.get('nodeID') or '').lower() == node_id.lower()]
        live = [it for it in hit if not node_is_ghost(it)]
        pool = live or hit
        if not pool: return None
        pool.sort(key=lambda x: x.get('nodeUpdateTime') or x.get('UpdatedAt') or '', reverse=True)
        return pool[0]
    except Exception as e:
        log(f"find_node_by_id 异常: {e}"); return None

def find_node_by_ip(pubip, max_pages=80):
    """兜底：按公网 IP 反查（翻页较慢），且必须过滤 outLineTime 幽灵记录。"""
    candidates = []
    for page in range(1, max_pages + 1):
        code, txt = admin_call(f"/api/edgeNode/getEdgeNodeList?page={page}&pageSize=200")
        if code != 200:
            log(f"getEdgeNodeList page {page} failed HTTP {code}: {txt[:200]}"); break
        d = json.loads(txt)
        arr = (d.get('data') or {}).get('list', [])
        total = (d.get('data') or {}).get('total', 0)
        for it in arr:
            if it.get('publicIP') == pubip and not node_is_ghost(it):
                candidates.append(it)
        if page * 200 >= total: break
        time.sleep(0.15)
    if not candidates: return None
    stage_rank = {'inService': 3, 'configured': 2, 'waitAudit': 1}
    candidates.sort(key=lambda x: (stage_rank.get(x.get('stage'), 0), x.get('nodeUpdateTime') or x.get('UpdatedAt') or ''), reverse=True)
    return candidates[0]

def node_info(it):
    """绑定信息在 nodeInfo（nominalInfo 恒为空，别读错字段）。"""
    return (it or {}).get('nodeInfo') or {}

def get_business_tag_hostname(node_id):
    """取后台「业务ID」= business_tags.hostName（该节点的第一条标签记录）。"""
    try:
        code, txt = admin_call(f"/api/businessTag/getBusinessTagList?page=1&pageSize=3&nodeId={node_id}")
        if code != 200:
            log(f"getBusinessTagList HTTP {code}: {txt[:160]}"); return None
        lst = (json.loads(txt).get('data') or {}).get('list') or []
        return (lst[0].get('hostName') or '') if lst else ''
    except Exception as e:
        log(f"getBusinessTagList 异常: {e}"); return None

def is_bound(it):
    """绑定完成的判据（与 ipes_deploy_full.sh 的 set_node_attributes 校验口径一致）：
        1) nodeInfo.vendorSuggestCustomers = 业务ID
        2) nodeInfo.usbw                   = 上行带宽
        3) nodeInfo.isp / resourceType     = 后台「业务线运营商 / 资源-上网方式」两列
        4) 业务ID = business_tags.hostName = 容器真实 IPES SN（76hex），不是占位符/UUID
    注意：**不要用 nodeInfo.ID / nodeInfo.boundTime 判定** —— 实测 updateEdgeNominalInfo
    返回 code:0 成功也不会写这两个字段（平台侧行为），大量在跑节点 nodeInfo.ID 恒为 0。
    """
    nfo = node_info(it)
    if not nfo: return False
    if nfo.get('vendorSuggestCustomers') != BUSINESS_ID: return False
    if nfo.get('usbw') != NODE_USBW: return False
    if nfo.get('isp') != ISP: return False
    if str(nfo.get('resourceType')) != str(NODE_RESOURCE_TYPE): return False
    # 业务标签校验（拿不到 SN 或拿不到标签时视为通过，避免误报）
    sn = get_ipes_sn()
    if sn:
        hn = get_business_tag_hostname((it or {}).get('nodeID') or '')
        if hn is not None and hn != sn:
            log(f"  业务ID 不符: business_tags.hostName={hn[:26]}... != IPES SN {sn[:26]}...")
            return False
    return True

def do_bind(node_id):
    log(f"为活跃节点 {node_id} 补绑业务 {BUSINESS_ID}")
    # 业务 ID 必须取容器内 76hex IPES SN，否则后台会写 UUID 占位符
    biz_sn = get_ipes_sn()
    if biz_sn:
        log(f"  -> 容器 IPES SN: {biz_sn[:16]}...{biz_sn[-12:]} (len={len(biz_sn)})")
    else:
        log("  -> [WARN] 未读到容器 IPES SN，inService 将不带 hostname")
    for stage in ['configured','configured']:
        code, txt = admin_call("/api/edgeNode/stateflow", {"nodes": [node_id], "stage": stage}, "POST")
        log(f"  -> {stage}: HTTP {code} {txt[:120]}")
        time.sleep(1)
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
    sf = {"nodes": [node_id], "stage": "inService"}
    if biz_sn: sf["hostname"] = biz_sn
    code, txt = admin_call("/api/edgeNode/stateflow", sf, "POST")
    log(f"  -> inService: HTTP {code} {txt[:120]}")

def main():
    # ★本机身份必须每轮 locate() 重读：重跑全量部署时 /etc/.mac、device_code 是在本脚本
    #   启动之后才重新生成的。若在 main 里只读一次，node_id 恒为空 → 整个进程退化成
    #   "公网 IP 全量反查" 慢路径（实测每轮 ~9 分钟全量分页 → 48 轮 = 小时级空转）。
    _st = {"nid": None, "warned": False}

    def locate():
        nid = get_local_node_id()
        if nid:
            if nid != _st["nid"]:
                _st["nid"] = nid
                log(f"本机真实 nodeId: {nid}")
            # 精确查询：命中即返回；未命中说明该身份还没在后台注册，直接进下一轮（1 次调用，秒级）
            return find_node_by_id(nid)
        if not _st["warned"]:
            _st["warned"] = True
            log("[WARN] 未读到本机 nodeId，暂用公网 IP 反查（一旦读到身份会自动改回精确查询）")
        pubip = get_public_ip()
        if pubip:
            log(f"（nodeID 未命中）本机公网 IP: {pubip}")
            return find_node_by_ip(pubip)
        return None

    it = None
    for i in range(48):
        it = locate()
        if it: break
        log(f"等待节点出现在后台... ({i+1}/48)"); time.sleep(10)
    if not it: log("[ERROR] 8 分钟未找到节点，放弃"); sys.exit(1)
    def describe(it):
        n = node_info(it)
        return (f"nodeID={it.get('nodeID')} stage={it.get('stage')} status={it.get('status')} "
                f"业务={n.get('vendorSuggestCustomers')} usbw={n.get('usbw')} isp={n.get('isp')} "
                f"resourceType={n.get('resourceType')}（nodeInfo.ID={n.get('ID')} 仅供参考，非绑定判据）")

    log("找到节点: " + describe(it))
    if is_bound(it): log("[OK] 已绑定，无需修复"); sys.exit(0)
    do_bind(it.get('nodeID'))
    time.sleep(2)
    it2 = locate()
    if is_bound(it2): log("[OK] 修复成功"); sys.exit(0)
    else:
        log("[ERROR] 修复后仍未达标 —— " + describe(it2))
        sys.exit(1)

if __name__ == '__main__':
    main()
PY

export NODE_ACTIVATE_TOKEN="$JWT" ADMIN_API_HOST BUSINESS_ID ISP PROVINCE CITY \
       NODE_NAT_TYPE NODE_RESOURCE_TYPE NODE_DIAL_TYPE NODE_SINGLE_IP_RADIO
# 注意：Python 读的是 NODE_USBW / NODE_BW_NUM，而 shell 变量名是 USBW / BW_NUM，
# 必须显式赋值导出，否则 --usbw/--bw-num 传入的值会被忽略、永远走默认 200/1。
export NODE_USBW="$USBW" NODE_BW_NUM="$BW_NUM"

nohup setsid python3 /root/ipes_repair_binding.py >/var/log/ipes_repair.log 2>&1 </dev/null &
REPAIR_PID=$!
echo "已后台启动绑定自修复 PID=$REPAIR_PID"
echo ""
echo "部署日志：  tail -f /var/log/ipes_nohup.log"
echo "修复日志：  tail -f /var/log/ipes_repair.log"

# ============ D) 部署后容器调优 + 健康看门狗（后台等容器起来再应用） ============
cat > /root/ipes_postopt.sh <<'EOF3'
#!/bin/bash
# 等 ipes 容器起来（最多 5 分钟）
for i in $(seq 1 60); do
  docker inspect ipes >/dev/null 2>&1 && break
  sleep 5
done
# 容器 I/O/CPU 优先级（live 生效，不重建容器、不动缓存）
docker update --blkio-weight 1000 --cpu-shares 1024 ipes 2>/dev/null
# 健康看门狗：容器挂了自动拉起 + /data 超 85% 告警
cat > /usr/local/bin/ipes-health.sh <<'HEOF'
#!/bin/bash
running=$(docker inspect -f '{{.State.Running}}' ipes 2>/dev/null)
if [ "$running" != "true" ]; then
  logger -t ipes-health "ipes not running -> restart"
  docker start ipes 2>/dev/null || { systemctl restart docker >/dev/null 2>&1; docker start ipes 2>/dev/null; }
fi
use=$(df -P /data 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
if [ -n "$use" ] && [ "$use" -ge 85 ] 2>/dev/null; then
  logger -t ipes-health "WARN /data usage ${use}% >= 85%"
fi
# ★必须显式 exit 0★：service 是 Type=oneshot，systemd 以【脚本退出码】判定成败。
#   旧版末行写作 `[ -n "$use" ] && [ "$use" -ge 85 ] && logger ...`：
#   磁盘用量低于 85%（即绝大多数健康机器）时整条 && 链返回 1 ⇒
#   每 2 分钟被 systemd 记一次 "Failed to start IPES health & disk watchdog"。
exit 0
HEOF
chmod +x /usr/local/bin/ipes-health.sh
cat > /etc/systemd/system/ipes-health.service <<'HEOF'
[Unit]
Description=IPES health & disk watchdog
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ipes-health.sh
HEOF
cat > /etc/systemd/system/ipes-health.timer <<'HEOF'
[Unit]
Description=Run IPES health watchdog every 2 min
[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
HEOF
systemctl daemon-reload 2>/dev/null
systemctl enable --now ipes-health.timer 2>/dev/null
echo "[postopt] blkio/cpu-priority + health watchdog applied at $(date)"
EOF3
chmod +x /root/ipes_postopt.sh
nohup setsid bash /root/ipes_postopt.sh >/var/log/ipes_postopt.log 2>&1 </dev/null &
echo "已后台启动容器调优/看门狗 PID=$!"

#!/usr/bin/env bash
# IPES 一键部署 r21（OSS 短链版：调优 + 部署）
# 用法：
#   curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/inline_deploy_r21_oss.sh | bash -s -- \
#     --ak 06d78b19bd0d9fc0aa300c6d \
#     --sk 16d6c46443308e62bb51f22c074a90ed \
#     --jwt eyJ... \
#     --isp 电信 [--province 浙江 --city 杭州 --num-dirs 12 --usbw 200]
# 未传 --province/--city 时，自动按本机公网 IP 识别；识别失败兜底为 浙江/杭州。
set +e

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

# ============ A) 系统调优（r21：磁盘吞吐 + 上下行）============
#   独立脚本 ipes_tune.sh：磁盘队列 / 挂载参数 / 内核 sysctl / 网卡 / nofile
#   幂等、可重复执行、装机后由 ipes-tune.service 开机自动重放
#   主脚本 r21 内嵌同一份调优作兜底（这里先跑一遍，后面所有步骤都受益）
TUNE_SHA="4082428fe8df7c9fcbf5ac524d6af2249eafd871"
TUNE1="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_tune.sh?t=$(date +%s)"
TUNE2="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@${TUNE_SHA}/ipes_tune.sh"
TUNE_OK=0
for u in "$TUNE1" "$TUNE2"; do
  curl -fsSL -m 30 "$u" -o /root/ipes_tune.sh 2>/dev/null && grep -q "IPES TUNE" /root/ipes_tune.sh && { TUNE_OK=1; break; }
done
if [ "$TUNE_OK" = "1" ]; then
  echo "[tune] $(grep -o 'TUNE_VER=\"[^\"]*\"' /root/ipes_tune.sh | head -1) applying ..."
  bash /root/ipes_tune.sh 2>&1 | tail -30
else
  echo "[tune][WARN] 调优脚本下载失败；主脚本 r21 内嵌同一份，部署时会补做"
fi

# ============ B) 完整部署（r21：真实 nodeId 绑定 + 内嵌调优兜底）============
SRC_SHA="4082428fe8df7c9fcbf5ac524d6af2249eafd871"
SRC1="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_deploy_full.sh?t=$(date +%s)"
SRC2="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@${SRC_SHA}/ipes_deploy_full.sh"
for u in "$SRC1" "$SRC2"; do
  curl -fsSL -m 60 "$u" -o /root/ipes_full.sh && grep -q singleIpRadio /root/ipes_full.sh && break
done
sed -i 's|^mirrorlist=|#mirrorlist=|g;s|^#\?baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
export NODE_ACTIVATE_TOKEN="$JWT"
nohup setsid bash /root/ipes_full.sh --ak "$AK" --sk "$SK" --isp "$ISP" --num-dirs "$NUM_DIRS" --skip-olmt >/var/log/ipes_nohup.log 2>&1 </dev/null &
DEPLOY_PID=$!
echo "已后台启动部署 PID=$DEPLOY_PID"

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
[ -n "$use" ] && [ "$use" -ge 85 ] && logger -t ipes-health "WARN /data usage ${use}% >= 85%"
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

#!/usr/bin/env bash
# IPES 部署 + 业务绑定自修复（根治「跑完脚本业务 41 没落盘」）
# 用法：以 root 在目标实例上执行整段。
set +e

# ============ A) 系统调优（BBR / RPS / NOTRACK，先于部署） ============
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
net.core.netdev_max_backlog = 100000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_ecn = 0
fs.file-max = 4000000
fs.inotify.max_user_watches = 1048576
vm.swappiness = 0
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 50
vm.vfs_cache_pressure = 10
vm.overcommit_memory = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_available_congestion_control = bbr cubic reno
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_notsent_lowat = 16384
net.core.default_qdisc = fq
net.core.netdev_budget = 1000
net.core.rps_sock_flow_entries = 32768
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 16384
net.ipv4.neigh.default.gc_thresh3 = 65536
net.ipv4.route.max_size = 2097152
EOF
modprobe nf_conntrack 2>/dev/null
sysctl -e -p /etc/sysctl.d/99-ipes.conf
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null
# RPS：收包软中断摊到所有 CPU（单队列 virtio 网卡必做）+ fq 队列规则(pacing)
nic=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [ -n "$nic" ]; then ncpu=$(nproc); mask=$(printf '%x' $(( (1<<ncpu)-1 ))); for q in /sys/class/net/$nic/queues/rx-*; do echo "$mask" > "$q/rps_cpus" 2>/dev/null; echo 4096 > "$q/rps_flow_cnt" 2>/dev/null; done; tc qdisc replace dev "$nic" root fq 2>/dev/null; fi
# 磁盘识别为SSD + 调度器/nomerges/read_ahead 优化(缓存读写更低延迟)
for d in /sys/block/vd* /sys/block/sd* /sys/block/xvd*; do
  [ -d "$d" ] || continue
  echo 0 > "$d/queue/rotational" 2>/dev/null
  echo none > "$d/queue/scheduler" 2>/dev/null
  echo 2048 > "$d/queue/read_ahead_kb" 2>/dev/null
  echo 1024 > "$d/queue/nr_requests" 2>/dev/null
  echo 2 > "$d/queue/nomerges" 2>/dev/null
done
# 开机自启: 重放磁盘+队列调优(避免重启回到默认)
cat > /usr/local/bin/ipes-tune.sh <<'EOF2'
#!/bin/bash
for d in /sys/block/vd* /sys/block/sd* /sys/block/xvd*; do
  [ -d "$d" ] || continue
  echo 0 > "$d/queue/rotational" 2>/dev/null
  echo none > "$d/queue/scheduler" 2>/dev/null
  echo 2048 > "$d/queue/read_ahead_kb" 2>/dev/null
  echo 1024 > "$d/queue/nr_requests" 2>/dev/null
  echo 2 > "$d/queue/nomerges" 2>/dev/null
done
nic=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$nic" ] && tc qdisc replace dev "$nic" root fq 2>/dev/null
EOF2
chmod +x /usr/local/bin/ipes-tune.sh
cat > /etc/systemd/system/ipes-tune.service <<'EOF2'
[Unit]
Description=IPES disk and qdisc tuning
After=network.target local-fs.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ipes-tune.sh

[Install]
WantedBy=multi-user.target
EOF2
systemctl daemon-reload 2>/dev/null
systemctl enable ipes-tune.service 2>/dev/null
# NOTRACK：纯 PCDN 节点关 conntrack 跟踪（高 PPS 不再被表满限流）
iptables -t raw -A PREROUTING -j NOTRACK 2>/dev/null; iptables -t raw -A OUTPUT -j NOTRACK 2>/dev/null

# ============ B) 完整部署（r20：渠道注册 + 绑业务41 + 流转服务中，根治用真实 nodeId 绑定） ============
SRC1="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_deploy_full.sh?t=$(date +%s)"
SRC2="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@a214464/ipes_deploy_full.sh"
for u in "$SRC1" "$SRC2"; do
  curl -fsSL -m 60 "$u" -o /root/ipes_full.sh && grep -q singleIpRadio /root/ipes_full.sh && break
done
sed -i 's|^mirrorlist=|#mirrorlist=|g;s|^#\?baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
export NODE_ACTIVATE_TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJVVUlEIjoiMzhjZTQ2YTctZDNkMi00YzVlLWJkNTYtM2I3YzFlMDNkNmYyIiwiSUQiOjQwLCJVc2VybmFtZSI6IjE3Njk1OTM3NzU2IiwiTmlja05hbWUiOiLlvKDnnb8iLCJBdXRob3JpdHlJZCI6MjEsIlVzZXJUeXBlIjoxLCJSZWxhdGVkUGFydHlJRCI6MCwiWnlVaWRzIjoiIiwiQnVmZmVyVGltZSI6ODY0MDAsImlzcyI6Inp5eSIsImF1ZCI6WyJHVkEiXSwiZXhwIjoxNzg5OTU1NTM5LCJuYmYiOjE3ODYwMTE3Mjd9.A22xANV1rOgbwLvbud3Uqo5iWWX-7VnVT-o16RS4wMg"
nohup setsid bash /root/ipes_full.sh --ak 06d78b19bd0d9fc0aa300c6d --sk 16d6c46443308e62bb51f22c074a90ed --isp 电信 --num-dirs 12 --skip-olmt >/var/log/ipes_nohup.log 2>&1 </dev/null &
DEPLOY_PID=$!
echo "已后台启动部署 PID=$DEPLOY_PID"

# ============ C) 业务绑定自修复（根治：用公网IP反查后台活跃节点并补绑） ============
cat > /root/ipes_repair_binding.py <<'PY'
import json, os, re, ssl, subprocess, sys, time, urllib.request, urllib.error

JWT = os.environ.get('NODE_ACTIVATE_TOKEN','')
if not JWT:
    print("[ERROR] NODE_ACTIVATE_TOKEN 未设置，无法修复绑定"); sys.exit(1)

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
    """读容器内真正的 IPES 业务 SN（76 位 hex），不要用后台 UUID sn。"""
    for path in ['/app/ipes/bin/ipes_sn', '/opt/soft/disk/IPES_SN']:
        try:
            out = subprocess.check_output(['docker','exec','ipes','cat',path], stderr=subprocess.DEVNULL, timeout=10)
            sn = out.decode('utf-8','replace').strip()
            if sn: return sn
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
            txt = r.read().decode().strip()
            ips = re.findall(r'\d+\.\d+\.\d+\.\d+', txt)
            if ips: return ips[0]
        except Exception: continue
    return None

def find_node_by_ip(pubip, max_pages=80):
    """按公网IP在后台列表里找真实活跃节点（取同IP里最近心跳且状态健康的）"""
    candidates = []
    for page in range(1, max_pages + 1):
        code, txt = admin_call(f"/api/edgeNode/getEdgeNodeList?page={page}&pageSize=200")
        if code != 200:
            log(f"getEdgeNodeList 第{page}页失败 HTTP {code}: {txt[:200]}"); break
        try:
            d = json.loads(txt)
        except Exception as e:
            log(f"JSON 解析失败: {e}"); break
        data = d.get('data') or {}
        total = data.get('total', 0)
        arr = data.get('list', [])
        for it in arr:
            if it.get('publicIP') == pubip:
                candidates.append(it)
        if page * 200 >= total:
            break
        time.sleep(0.15)
    if not candidates:
        return None
    # 优先：stage inService > configured > 其他；同状态取最近更新
    stage_rank = {'inService': 3, 'configured': 2, 'waitAudit': 1}
    candidates.sort(key=lambda x: (
        stage_rank.get(x.get('stage'), 0),
        x.get('nodeUpdateTime') or x.get('UpdatedAt') or ''
    ), reverse=True)
    return candidates[0]

def is_bound(node_info):
    if not node_info: return False
    if node_info.get('stage') != 'inService': return False
    ni = node_info.get('nominalInfo') or {}
    return ni.get('vendorSuggestCustomers') == BUSINESS_ID and ni.get('usbw') == NODE_USBW

def do_bind(node_id):
    log(f"开始为活跃节点 {node_id} 补绑业务 {BUSINESS_ID}")
    # 业务 ID 必须取容器内 76hex IPES SN，否则后台会写 UUID 占位符
    biz_sn = get_ipes_sn()
    log(f"  -> 容器 IPES SN: {biz_sn[:16]}...{biz_sn[-12:]} (len={len(biz_sn)})")
    # 1) 降到待配置
    code, txt = admin_call("/api/edgeNode/stateflow", {"nodes": [node_id], "stage": "configured"}, "POST")
    log(f"  -> configured: HTTP {code} {txt[:120]}")
    time.sleep(1)
    # 2) 写业务属性
    body = {
        "nodeId": node_id,
        "province": PROVINCE or "浙江",
        "city": CITY or "杭州",
        "isp": ISP,
        "natType": NODE_NAT_TYPE,
        "resourceType": NODE_RESOURCE_TYPE,
        "dialType": NODE_DIAL_TYPE,
        "singleIpRadio": NODE_SINGLE_IP_RADIO,
        "usbw": NODE_USBW,
        "bwNum": NODE_BW_NUM,
        "transMode": 0,
        "transModeStr": "cm:0,ct:0,cu:0",
        "transProvRate": 0,
        "isTransProv": True,
        "isIPv6Schedule": False,
        "isCrossNetwork": False,
        "crossNetworkIsp": None,
        "vendorSuggestCustomers": BUSINESS_ID
    }
    code, txt = admin_call("/api/edgeNode/updateEdgeNominalInfo", body, "POST")
    log(f"  -> updateEdgeNominalInfo: HTTP {code} {txt[:120]}")
    time.sleep(1)
    # 3) 复位待配置
    code, txt = admin_call("/api/edgeNode/stateflow", {"nodes": [node_id], "stage": "configured"}, "POST")
    log(f"  -> configured(reset): HTTP {code} {txt[:120]}")
    time.sleep(1)
    # 4) 升服务中（hostname=真SN）
    code, txt = admin_call("/api/edgeNode/stateflow", {"nodes": [node_id], "stage": "inService", "hostname": biz_sn}, "POST")
    log(f"  -> inService: HTTP {code} {txt[:120]}")

def main():
    pubip = get_public_ip()
    if not pubip:
        log("[ERROR] 无法获取公网 IP"); sys.exit(1)
    log(f"本机公网 IP: {pubip}")

    # 等部署把节点注册到后台（最多等 8 分钟）
    node_info = None
    for i in range(48):
        node_info = find_node_by_ip(pubip)
        if node_info: break
        log(f"后台尚未出现该 IP 节点，等待 10s...({i+1}/48)")
        time.sleep(10)
    if not node_info:
        log("[ERROR] 8 分钟内未在后台找到该公网 IP 的节点，放弃修复"); sys.exit(1)

    node_id = node_info.get('nodeID')
    stage = node_info.get('stage')
    ni = node_info.get('nominalInfo') or {}
    log(f"找到活跃节点: nodeId={node_id} stage={stage} vendor={ni.get('vendorSuggestCustomers')} usbw={ni.get('usbw')}")

    if is_bound(node_info):
        log(f"[OK] 节点 {node_id} 业务 {BUSINESS_ID} 已绑定，无需修复")
        sys.exit(0)

    # 未绑定：执行补绑
    do_bind(node_id)

    # 复核
    time.sleep(2)
    node_info = find_node_by_ip(pubip)
    if is_bound(node_info):
        log(f"[OK] 修复成功：节点 {node_id} 已绑定业务 {BUSINESS_ID} 并处于 inService")
        sys.exit(0)
    else:
        log(f"[ERROR] 修复后仍未达标：stage={node_info.get('stage') if node_info else 'null'} vendor={(node_info.get('nominalInfo') or {}).get('vendorSuggestCustomers') if node_info else 'null'}")
        sys.exit(1)

if __name__ == '__main__':
    main()
PY

# 传环境变量给修复脚本
export BUSINESS_ID ISP PROVINCE CITY NODE_NAT_TYPE NODE_RESOURCE_TYPE NODE_DIAL_TYPE \
       NODE_SINGLE_IP_RADIO NODE_USBW NODE_BW_NUM ADMIN_API_HOST

nohup setsid python3 /root/ipes_repair_binding.py >/var/log/ipes_repair.log 2>&1 </dev/null &
REPAIR_PID=$!
echo "已后台启动绑定自修复 PID=$REPAIR_PID"
echo ""
echo "查看部署日志：  tail -f /var/log/ipes_nohup.log"
echo "查看绑定修复日志：tail -f /var/log/ipes_repair.log"
echo "（修复程序会等待节点出现在后台，最长 8 分钟，然后自动补绑业务 41）"

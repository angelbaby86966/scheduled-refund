#!/bin/bash
# ============================================================
# 98bbb649 补跑脚本（只含 r2 的 [3/4]+[4/4]，跳过 [1]渠道绑定/[2]docker）
# 原因：机器 08:34 重置后 [1][2] 已完成（身份 b27fedd0…），整脚本重刷会生成第5个身份
# ============================================================
JWT="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJVVUlEIjoiMzhjZTQ2YTctZDNkMi00YzVlLWJkNTYtM2I3YzFlMDNkNmYyIiwiSUQiOjQwLCJVc2VybmFtZSI6IjE3Njk1OTM3NzU2IiwiTmlja05hbWUiOiLlvKDnnb8iLCJBdXRob3JpdHlJZCI6MjEsIlVzZXJUeXBlIjoxLCJSZWxhdGVkUGFydHlJRCI6MCwiWnlVaWRzIjoiIiwiQnVmZmVyVGltZSI6ODY0MDAsImlzcyI6Inp5eSIsImF1ZCI6WyJHVkEiXSwiZXhwIjoxNzkxMTY0NjE4LCJuYmYiOjE3OTA1NTk4MTh9.4vaCnaJQj6F9cUMjJJHsY4mDYV8ZG9bOGGNUcN4d5J4"
ISP="联通"
USBW=200
BWNUM=1
BIZ=26
echo "========== [3/4] 百度双实例部署 =========="
region="$(curl -s --max-time 5 ipinfo.io | grep '"region"' | cut -d '"' -f4 | tr '[:lower:]' '[:upper:]')"
if [ -z "$region" ]; then
  region="$(curl -s --max-time 5 'http://ip-api.com/line/?fields=regionName' | tr '[:lower:]' '[:upper:]' | head -1)"
fi
region="${region:-BEIJING}"
echo "[init] 探测省份: $region"

deploy_once() {
  curl -s https://zyy-go.oss-cn-beijing.aliyuncs.com/script/baidu/little_baidu_env.sh | bash -s -- \
  "-dm 1 -g 1 -gs 2 -ds 322122547200 -dt HDD -i eth0 -b 150 -o CUCC -a $region -d vda -tm 1 -ntpd 0" \
  "-dm 2 -g 1 -gs 2 -ds 322122547200 -dt HDD -i eth0 -b 150 -o CUCC -a $region -d vda -tm 1 -ntpd 0"
}

check_containers() {
  docker ps --format '{{.Names}}' | grep -qx 'ansujia-1' && docker ps --format '{{.Names}}' | grep -qx 'ansujia-2'
}

deploy_once
sleep 5
if check_containers; then
  echo "[init] 双实例部署成功"
else
  echo "[init] 双实例未就绪，重试一次部署..."
  deploy_once
  sleep 10
fi
docker ps --format '{{.Names}}\t{{.Status}}'
if check_containers; then
  echo "[init] ✅ 双实例(ansujia-1/2)就绪"
else
  echo "[init] ❌ 双实例仍未就绪，请检查上方部署日志（后续流转仍会继续）"
fi

echo "========== [4/4] 后台流转 待配置→服务中（强校验） =========="
python3 - "$JWT" "$ISP" "$USBW" "$BWNUM" "$BIZ" <<'PYEOF'
import sys, os, re, json, time, ssl, urllib.request, urllib.error

JWT, ISP, USBW, BWNUM, BIZ = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
BASE = "https://admin.zhouyi.top"
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE

def log(m): print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)

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
    except Exception as e:
        return 0, str(e)[:120]

def local_node_id():
    for f in ["/usr/local/edge_zycloud/device_code"]:
        try:
            v = open(f).read().strip()
            if re.fullmatch(r'[0-9a-f]{32}', v): return v
        except Exception: pass
    return None

def fetch_node(nid, max_pages=80):
    for page in range(1, max_pages + 1):
        code, txt = admin_call(f"/api/edgeNode/getEdgeNodeList?page={page}&pageSize=200")
        if code != 200:
            log(f"getEdgeNodeList HTTP {code}: {txt[:120]}"); return None
        d = json.loads(txt); data = d.get('data') or {}
        for it in (data.get('list') or []):
            if it.get('nodeID') == nid: return it
        if page * 200 >= (data.get('total') or 0): break
        time.sleep(0.2)
    return None

def flow(nid, stage):
    code, txt = admin_call("/api/edgeNode/stateflow", {"nodes": [nid], "stage": stage}, "POST")
    ok = code == 200 and '"code":0' in txt.replace(' ', '')
    log(f"stateflow -> {stage}: HTTP {code} {txt[:100]}")
    return ok

def nominal_update(nid, info):
    prov = info.get('province') or '浙江'
    city = info.get('city') or '杭州'
    body = {
        "nodeId": nid, "province": prov, "city": city,
        "isp": ISP, "natType": info.get('natType') or 'public',
        "resourceType": info.get('resourceType') if info.get('resourceType') is not None else 2,
        "dialType": info.get('dialType') or 'staticNetSingle',
        "singleIpRadio": info.get('singleIpRadio') if info.get('singleIpRadio') is not None else 0,
        "usbw": USBW, "bwNum": BWNUM, "transMode": 0,
        "transModeStr": "cm:0,ct:0,cu:0", "transProvRate": 0, "isTransProv": True,
        "isIPv6Schedule": False, "isCrossNetwork": False, "crossNetworkIsp": None,
        "vendorSuggestCustomers": BIZ
    }
    code, txt = admin_call("/api/edgeNode/updateEdgeNominalInfo", body, "POST")
    body_code = None
    try: body_code = json.loads(txt).get('code')
    except Exception: pass
    ok = code == 200 and body_code == 0
    log(f"updateEdgeNominalInfo(usbw={USBW}, bwNum={BWNUM}, 业务={BIZ}): HTTP {code} body_code={body_code} {'' if ok else txt[:120]}")
    return ok

def usbw_biz_ok(ni):
    info = ni.get('nodeInfo') or {}
    return info.get('usbw') == USBW and int(info.get('vendorSuggestCustomers') or -1) == BIZ

if not JWT:
    log("[SKIP] 未提供 --jwt，跳过流转（绑定与部署已完成）"); sys.exit(0)

# 轮询等本机 nodeID 出现在后台（注册同步有延迟）
nid = None; ni = None
for i in range(40):
    nid = local_node_id()
    if nid:
        ni = fetch_node(nid)
        if ni:
            log(f"后台已见本机节点: {nid} stage={ni.get('stage')} status={ni.get('status')}")
            break
        log(f"等待后台出现节点 {nid} ... ({i+1}/40)")
    else:
        log(f"等待本机 device_code 生成 ... ({i+1}/40)")
    time.sleep(15)

if not ni:
    log("[FAIL] 10 分钟内后台未见本机节点，流转终止（绑定/部署已完成，可稍后手动流转）"); sys.exit(1)

# 强校验 + 自动重试：最多 3 轮（降→写→升→回读）
final = None
for attempt in range(1, 4):
    if ni.get('stage') == 'inService' and usbw_biz_ok(ni):
        log(f"第{attempt}轮: 节点已在服务中且 usbw/业务正确")
        final = ni; break
    # 降级到 configured（inService 下直接写会 code:7）
    flow(nid, 'configured'); time.sleep(1)
    if nominal_update(nid, ni.get('nodeInfo') or {}):
        pass
    time.sleep(1)
    flow(nid, 'inService')
    time.sleep(8)
    ni = fetch_node(nid)
    if not ni:
        log(f"第{attempt}轮: 回读失败，重试"); continue
    i2 = ni.get('nodeInfo') or {}
    log(f"第{attempt}轮回读: stage={ni.get('stage')} isp={i2.get('isp')} usbw={i2.get('usbw')} 业务={i2.get('vendorSuggestCustomers')}")
    if ni.get('stage') == 'inService' and usbw_biz_ok(ni):
        final = ni; break
    time.sleep(5)

if final:
    log("✅ 流转完成且校验通过（inService + usbw/业务正确）")
else:
    log("❌ 流转未达预期（stage 或 usbw/业务不符），请后台人工处理")
    sys.exit(1)
PYEOF
echo "========== 装机完成 =========="

#!/bin/bash
# ============================================================
# 新云主机装机一键脚本 v2026-09-30-r5（根治版）
# 流程：① 渠道绑定(zyy_init_max) → ② docker安装(幂等) → ③ 百度双实例部署(-gs 2)
#       → ④ 后台流转 待配置→服务中（单条200m，业务d1=整型26，强校验+自动重试）
# 用法: bash init_full.sh --ak <渠道ak> --sk <渠道sk> --jwt <后台JWT> [--isp 联通] [--biz 26]
#       --isp 可自定义任意运营商字符串，默认 联通
#       --biz 业务整型ID，默认 26（即 d1；不是 q2）
# r5 根治三项：
#   A. 会话断开不再导致跑一半死掉：管道执行时自动落盘 + nohup 转后台，日志 /var/log/init_full_run.log
#   B. 重复执行不再生成新身份：[1] 检测到已有 device_code 直接跳过（除非 --force-bind）
#   C. [3] 幂等：按容器名逐个补缺，已存在的 ansujia-N 不重复部署
# 断点续跑：状态记在 /var/log/init_full_state，任何一步完成后重跑同一命令自动跳过已完成步骤
# ============================================================

ISP="联通"
USBW=200          # 单条 200M
BWNUM=1           # 单条
BIZ=26            # 业务整型ID：26 = d1（vendor_suggest_customers 是整型列）
FORCE_BIND=0      # --force-bind 时强制重跑 [1]（仅控制台已重置后使用）

# ---------- 参数解析 ----------
ORIG_ARGS=("$@")   # 原样保留（转后台时要传给子进程，shift 会消耗 $@）
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jwt) JWT="$2"; shift 2 ;;
    --ak)  AK="$2";  shift 2 ;;
    --sk)  SK="$2";  shift 2 ;;
    --isp) ISP="$2"; shift 2 ;;
    --biz) BIZ="$2"; shift 2 ;;
    --force-bind) FORCE_BIND=1; shift ;;
    *) echo "未知参数 $1"; shift ;;
  esac
done

# ak/sk 必填校验（不写死，每次由调用方传入）
if [ -z "$AK" ] || [ -z "$SK" ]; then
  echo "[FATAL] 必须传入渠道 ak/sk：bash init_full.sh --ak <渠道ak> --sk <渠道sk> --jwt <后台JWT> [--isp 联通] [--biz 26]"
  exit 1
fi

# ---------- [根治A] 自动转后台（防会话断开杀进程） ----------
SELF_PATH="/opt/init_full_r5.sh"
RUN_LOG="/var/log/init_full_run.log"
STATE="/var/log/init_full_state"   # 断点续跑状态文件
R5_SRC="${INIT_FULL_SRC:-https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@main/baidu/init_full_r5.sh}"
mark()     { echo "$1 $(date '+%F %T')" >> "$STATE"; }
done_step(){ grep -q "^$1 " "$STATE" 2>/dev/null; }
if [ -z "$__R5_DETACHED__" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$SELF_PATH" ]; then
  # 不是从标准路径跑的（典型：curl|bash 管道）：重新拉取落盘 + nohup 后台执行，立即返回
  if curl -fsSL --retry 3 --max-time 60 "$R5_SRC" -o "$SELF_PATH" && chmod +x "$SELF_PATH" \
     && grep -q "v2026-09-30-r5" "$SELF_PATH"; then
    __R5_DETACHED__=1 nohup bash "$SELF_PATH" "${ORIG_ARGS[@]}" > "$RUN_LOG" 2>&1 &
    echo "[r5] 已自动转后台执行（会话断开不影响）。"
    echo "[r5] 查看进度:  tail -f $RUN_LOG"
    exit 0
  fi
  echo "[r5] ⚠️ 落盘失败（$R5_SRC 不通？），退回前台继续执行。"
fi

echo "========== [1/4] 渠道绑定 =========="
DC_FILE="/usr/local/edge_zycloud/device_code"
if [ "$FORCE_BIND" -eq 0 ] && [ -s "$DC_FILE" ] && grep -qE '^[0-9a-f]{32}$' "$DC_FILE"; then
  # [根治B] 已有身份：跳过绑定，避免重刷生成新节点（重刷请先控制台重置，或加 --force-bind）
  echo "[r5] 检测到已有 device_code=$(cat "$DC_FILE")，跳过渠道绑定（防重复身份）。"
  echo "[r5] 如确要重新绑定：先在阿里云控制台重置系统盘，再加 --force-bind 重跑。"
  mark bind-skipped
else
  if done_step bind; then
    echo "[r5] 状态文件显示 bind 已完成，跳过。"
  else
    curl -s https://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init/zyy_init_max.sh | bash -s -- --ak "$AK" --sk "$SK" --isp "$ISP"
    mark bind
  fi
fi

echo "========== [2/4] docker 安装（幂等） =========="
if command -v docker >/dev/null 2>&1; then
  echo "[init] docker 已存在，跳过安装: $(docker --version 2>/dev/null)"
else
  echo "[init] 未检测到 docker，走阿里云源快速安装（nogpgcheck，不跑慢速官方脚本）..."
  # 阿里云 docker-ce 源（优先内网 mirrors.cloud.aliyuncs.com，同机房秒下）+ nogpgcheck + 清缓存重试×3
  pkill -9 yum 2>/dev/null; sleep 1; rm -f /var/run/yum.pid
  yum install -y yum-utils >/dev/null 2>&1
  yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo >/dev/null 2>&1
  # 内网源提速：阿里云机器访问 mirrors.cloud.aliyuncs.com 免公网带宽且快
  sed -i 's#mirrors.aliyun.com/docker-ce#mirrors.cloud.aliyuncs.com/docker-ce#g' /etc/yum.repos.d/docker-ce.repo 2>/dev/null
  yum clean all >/dev/null 2>&1; rm -rf /var/cache/yum
  for i in 1 2 3; do
    echo "[init] docker 安装 try $i（后台下载中，下方显示进度）..."
    yum install -y --nogpgcheck --setopt=docker-ce-stable.retries=5 \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      > /var/log/docker_install_init.log 2>&1 &
    YUMPID=$!
    # 每 15 秒打印一次进度心跳，避免看起来像卡死
    while kill -0 $YUMPID 2>/dev/null; do
      sleep 15
      echo "[init] ...下载/安装中 $(tail -1 /var/log/docker_install_init.log 2>/dev/null | grep -oE '[0-9]+/[0-9]+' | tail -1) elapsed=$((SECONDS))s"
    done
    wait $YUMPID
    command -v docker >/dev/null 2>&1 && break
    echo "[init] try $i 失败: $(tail -2 /var/log/docker_install_init.log | cut -c1-120)"
    # 内网源不通则回退公网源
    sed -i 's#mirrors.cloud.aliyuncs.com/docker-ce#mirrors.aliyun.com/docker-ce#g' /etc/yum.repos.d/docker-ce.repo 2>/dev/null
    yum clean all >/dev/null 2>&1; rm -rf /var/cache/yum; sleep 3
  done
  systemctl enable --now docker >/dev/null 2>&1
  sleep 3
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "[FATAL] docker 安装失败，终止部署（日志: /var/log/docker_install_init.log）"; exit 1
fi
systemctl is-active docker >/dev/null 2>&1 || systemctl start docker
echo "[init] docker 就绪: $(docker --version)"
mark docker

echo "========== [3/4] 百度双实例部署（幂等补缺） =========="
region="$(curl -s --max-time 5 ipinfo.io | grep '"region"' | cut -d '"' -f4 | tr '[:lower:]' '[:upper:]')"
if [ -z "$region" ]; then
  region="$(curl -s --max-time 5 'http://ip-api.com/line/?fields=regionName' | tr '[:lower:]' '[:upper:]' | head -1)"
fi
region="${region:-BEIJING}"
echo "[init] 探测省份: $region"

have_container() {
  docker ps -a --format '{{.Names}}' | grep -qx "ansujia-$1"
}

# [根治C] 按容器名逐个补缺：已存在的 ansujia-N 不动，只部署缺的
deploy_missing() {
  local need_deploy=0
  for n in 1 2; do
    if have_container "$n"; then
      echo "[init] ansujia-$n 已存在，跳过（不重复部署）"
    else
      need_deploy=1
      echo "[init] 部署 ansujia-$n ..."
      curl -s https://zyy-go.oss-cn-beijing.aliyuncs.com/script/baidu/little_baidu_env.sh | bash -s -- \
        "-dm $n -g 1 -gs 2 -ds 322122547200 -dt HDD -i eth0 -b 150 -o CUCC -a $region -d vda -tm 1 -ntpd 0"
    fi
  done
  echo $need_deploy
}

retry_done=0
need=$(deploy_missing)
sleep 5
if ! have_container 1 || ! have_container 2; then
  if [ "$retry_done" -eq 0 ]; then
    echo "[init] 双实例未就绪，重试一次补缺部署..."
    retry_done=1
    deploy_missing >/dev/null
    sleep 10
  fi
fi
docker ps --format '{{.Names}}\t{{.Status}}' | grep ansujia
if have_container 1 && have_container 2; then
  echo "[init] ✅ 双实例(ansujia-1/2)就绪"
  mark baidu
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
mark flow
echo "========== 装机完成（r5，日志: $RUN_LOG） =========="

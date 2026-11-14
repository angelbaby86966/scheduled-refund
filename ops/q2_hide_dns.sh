#!/bin/bash
# =============================================================================
# q2_hide_dns.sh —— 让云主机的「明文 DNS 查询 / 本机日志」里不再出现爱奇艺系域名
#
# 只解决域名可见性，不碰流量特征：
#   - 本机起一个极简 DoH 转发器（Python 标准库，无第三方依赖）
#   - dnsmasq 监听 127.0.0.1:53，把域名查询转成加密 HTTPS（RFC 8484）
#   - 明文 UDP 53 上只剩 DoH 端点自身的域名，爱奇艺域名不再出现
#   - 动态调度解析保持实时（不写死 hosts / 不写死 IP），不掉量
#   - 顺带治理本机日志：docker 日志轮转 + 超大日志清空 + journald 限额
#
# 用法：
#   bash q2_hide_dns.sh                    安装保活 + DNS 隐藏并自检
#   bash q2_hide_dns.sh --keepalive-only  只装看门狗保活，完全不碰 DNS
#   bash q2_hide_dns.sh --check           只检查前置条件，不改任何东西
#   bash q2_hide_dns.sh --status          查看当前状态（含保活）
#   bash q2_hide_dns.sh --rollback        还原 DNS（保活保留不动）
#   bash q2_hide_dns.sh --rollback-keepalive  单独移除看门狗保活
#   bash q2_hide_dns.sh --version         输出版本指纹
#
# 看门狗保活（独立于 DNS 安装，装在最前面，DNS 失败也不影响）：
#   · happ 路数 < 9  → docker restart 补拉回 9 路
#   · happ 路数 >= 9 → 完全不动（★ 超过 9 路不杀、不重启）
#   · docker 守护进程挂了 → systemctl/service 拉起
#   · ipes 容器挂了 → docker start；容器被删 → 按现网烘焙参数完整重建
#   · cron 每分钟 + @reboot；重置防抖默认 300s；日志 /var/log/q2_keepalive.log
#
# 可外置调整（随时改，不需要改脚本）：
#   Q2_HIDE_MODE=all|suffix        默认 all：除白名单一律走 DoH（最彻底）
#                                  suffix：只爱奇艺系后缀走 DoH（影响面最小）
#   Q2_IQY_SUFFIXES_FILE=/etc/q2/iqiyi_suffixes   后缀清单，每行一个
#   Q2_DOH_URLS="https://dns.alidns.com/dns-query,https://doh.pub/dns-query"
#   Q2_UPSTREAM=114.114.114.114    明文回退上游（DoH 全挂时 watchdog 用）
#   Q2_KA_HAPP_N=9                 保活目标路数
#   Q2_KA_DEBOUNCE=300             两次补拉之间的最小间隔（秒）
#   Q2_KA_TAKEOVER=1               1=摘掉旧 ipes_health_check cron 避免互殴，0=保留
#   Q2_KA_PATTERN='[h]app:vod'     容器内 happ 进程计数匹配串
#
# ⚠️ 边界：TLS SNI 里的域名需要服务端 ECH 才能加密，客户端单方面改不了；
#          上行流量模型（大上行/海量连接/UDP 打洞）与本脚本无关，照旧可见。
# =============================================================================
set -u
export LC_ALL=C

HIDE_DNS_VER="1.1.0-20261114"
KA_VER="1.0.0-20261114"
PYBIN="$(command -v python 2>/dev/null || command -v python3 2>/dev/null || true)"

# ── 看门狗保活（与 DNS 隐藏完全独立，安装顺序在 DNS 之前）──
KA_PATH="/usr/local/bin/q2_keepalive.sh"
KA_LOG="/var/log/q2_keepalive.log"
KA_STAMP="/tmp/.q2_ka_last_reset"
KA_N="${Q2_KA_HAPP_N:-9}"
KA_DEBOUNCE="${Q2_KA_DEBOUNCE:-300}"
KA_TAKEOVER="${Q2_KA_TAKEOVER:-1}"
KA_PATTERN="${Q2_KA_PATTERN:-[h]app:vod}"
KA_CONTAINER="${Q2_KA_CONTAINER:-ipes}"
KA_CFG="${Q2_KA_CFG:-/opt/ipes/var/db/ipes/happ-conf/custom.yml}"

SELF_PATH="/usr/local/bin/q2_hide_dns.sh"
DOH_PY="/usr/local/bin/q2_doh_proxy.py"
UNIT_FILE="/etc/systemd/system/q2-doh-proxy.service"
DNSMASQ_CONF="/etc/dnsmasq.d/q2-hide.conf"
STATE_DIR="/etc/q2"
RESOLV_BAK="${STATE_DIR}/resolv.conf.pre-hide"
SUFFIX_FILE="${Q2_IQY_SUFFIXES_FILE:-/etc/q2/iqiyi_suffixes}"
FAIL_FILE="/tmp/.q2_hide_dns_fail"
MODE="${Q2_HIDE_MODE:-all}"
DOH_URLS="${Q2_DOH_URLS:-https://dns.alidns.com/dns-query,https://doh.pub/dns-query}"
PROBE_IQY="www.iqiyi.com"
PROBE_ANY="www.baidu.com"

# 明文白名单：这些域名走原上游，避免 DoH 端点自解析死锁 + 保住阿里云内网解析
PLAIN_SUFFIXES="dns.alidns.com doh.pub aliyuncs.com aliyun.com"
DEFAULT_SUFFIXES="iqiyi.com qiyi.com qiyipic.com iqiyipic.com 71.am iqiyi.cn qiyi.cn"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die()  { log "❌ $*"; exit 1; }
ok()   { log "✅ $*"; }

# -----------------------------------------------------------------------------
# 用 Python 构造并发一个 DNS 查询包，验证指定 127.0.0.1:<port> 能正确应答
# 兼容 CentOS 7.9 自带 python2.7 与 python3
# -----------------------------------------------------------------------------
dns_probe() {
  local port="$1" name="$2"
  "${PYBIN}" - "${port}" "${name}" <<'PY'
import sys, socket, struct, random

def B(x):
    return ord(x) if isinstance(x, str) else x

port = int(sys.argv[1])
name = sys.argv[2]
tid = random.randint(0, 65535)
head = struct.pack('!HHHHHH', tid, 0x0100, 1, 0, 0, 0)
q = b''
for p in name.split('.'):
    q += bytes(bytearray([len(p)])) + p.encode('ascii')
pkt = head + q + b'\x00' + struct.pack('!HH', 1, 1)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(6)
try:
    s.sendto(pkt, ('127.0.0.1', port))
    data, _ = s.recvfrom(4096)
    if len(data) < 12:
        print('FAIL short'); sys.exit(1)
    rcode = B(data[3]) & 15
    ancount = (B(data[6]) << 8) | B(data[7])
    if rcode == 0 and ancount > 0:
        print('OK'); sys.exit(0)
    print('FAIL rcode=%d an=%d' % (rcode, ancount)); sys.exit(1)
except Exception as e:
    print('FAIL %s' % e); sys.exit(1)
PY
}

# -----------------------------------------------------------------------------
# DoH 转发器：UDP 5353 收到原始 DNS 报文 → POST 到 DoH 端点 → 应答原样回送
# -----------------------------------------------------------------------------
write_doh_proxy() {
  cat > "${DOH_PY}" <<'PY'
#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""极简 DoH 转发器（RFC 8484），Python 标准库，兼容 py2.7 / py3。"""
import os
import socket
import threading

try:
    from urllib.request import Request, urlopen
except ImportError:
    from urllib2 import Request, urlopen

URLS = [u for u in os.environ.get(
    'Q2_DOH_URLS',
    'https://dns.alidns.com/dns-query,https://doh.pub/dns-query'
).split(',') if u.strip()]
HOST, PORT = '127.0.0.1', 5353


def ask(pkt):
    last = None
    for url in URLS:
        try:
            req = Request(url, data=pkt, headers={
                'Content-Type': 'application/dns-message',
                'Accept': 'application/dns-message',
                'User-Agent': 'q2-doh/1.0',
            })
            return urlopen(req, timeout=5).read()
        except Exception as e:
            last = e
    if last:
        raise last
    raise RuntimeError('no DoH endpoint')


def handle(sock, pkt, addr):
    try:
        sock.sendto(ask(pkt), addr)
    except Exception:
        pass


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((HOST, PORT))
    while True:
        try:
            pkt, addr = s.recvfrom(4096)
        except Exception:
            continue
        t = threading.Thread(target=handle, args=(s, pkt, addr))
        t.daemon = True
        t.start()


if __name__ == '__main__':
    main()
PY
  chmod 755 "${DOH_PY}"
}

write_unit() {
  cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=q2 DoH forwarder (hide business domains from plaintext DNS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=Q2_DOH_URLS=${DOH_URLS}
ExecStart=${PYBIN} ${DOH_PY}
Restart=always
RestartSec=3
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF
}

# -----------------------------------------------------------------------------
# 解析原上游：优先取当前 resolv.conf，若已指向 127.0.0.1 则从备份取
# -----------------------------------------------------------------------------
resolve_upstream() {
  local u
  u="$(grep -E '^nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1)"
  if [ -z "${u}" ] && [ -f "${RESOLV_BAK}" ]; then
    u="$(grep -E '^nameserver[[:space:]]+' "${RESOLV_BAK}" 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1)"
  fi
  printf '%s' "${Q2_UPSTREAM:-${u:-114.114.114.114}}"
}

write_dnsmasq_conf() {
  local up="$1" sfx
  mkdir -p /etc/dnsmasq.d
  {
    echo "# q2_hide_dns ${HIDE_DNS_VER} — 自动生成，勿手工改"
    echo "listen-address=127.0.0.1"
    echo "bind-interfaces"
    echo "no-resolv"
    echo "cache-size=10000"
    echo "log-facility=/dev/null"
    echo "neg-ttl=30"
    for sfx in ${PLAIN_SUFFIXES}; do
      echo "server=/${sfx}/${up}"
    done
    if [ "${MODE}" = "suffix" ]; then
      for sfx in $(cat "${SUFFIX_FILE}" 2>/dev/null); do
        echo "server=/${sfx}/127.0.0.1#5353"
      done
      echo "server=${up}"
    else
      echo "server=127.0.0.1#5353"
    fi
  } > "${DNSMASQ_CONF}"
}

ensure_suffix_file() {
  mkdir -p "$(dirname "${SUFFIX_FILE}")"
  if [ ! -f "${SUFFIX_FILE}" ]; then
    for s in ${DEFAULT_SUFFIXES}; do echo "${s}"; done > "${SUFFIX_FILE}"
  fi
}

# -----------------------------------------------------------------------------
# resolv.conf 读写（部署脚本会 chattr +i 加锁，必须先解锁）
# -----------------------------------------------------------------------------
apply_resolv() {
  chattr -i /etc/resolv.conf 2>/dev/null || true
  printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
  chattr +i /etc/resolv.conf 2>/dev/null || true
}

rollback_resolv() {
  chattr -i /etc/resolv.conf 2>/dev/null || true
  if [ -f "${RESOLV_BAK}" ]; then
    cp -a "${RESOLV_BAK}" /etc/resolv.conf
  else
    printf 'nameserver 8.8.8.8\nnameserver 114.114.114.114\n' > /etc/resolv.conf
  fi
  chattr +i /etc/resolv.conf 2>/dev/null || true
}

# -----------------------------------------------------------------------------
install_cron() {
  local line="*/5 * * * * ${SELF_PATH} --watchdog >/dev/null 2>&1"
  ( crontab -l 2>/dev/null | grep -v 'q2_hide_dns.sh' || true; echo "${line}" ) | crontab - 2>/dev/null || true
}

# =============================================================================
# 看门狗保活：happ < N 补拉到 N，happ >= N 不动；docker / 容器挂了自动拉起
# 生成独立脚本 + 独立 cron，与 DNS 隐藏互不依赖
# =============================================================================
capture_ka_params() {
  # 从现网容器烘焙重建参数：容器被删时按原镜像 / 挂载 / 网络逐条重建，不写死
  KA_IMG=""; KA_NET="host"; KA_MARGS=""
  if docker inspect "${KA_CONTAINER}" >/dev/null 2>&1; then
    KA_IMG="$(docker inspect "${KA_CONTAINER}" --format '{{.Config.Image}}' 2>/dev/null || true)"
    KA_NET="$(docker inspect "${KA_CONTAINER}" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
    KA_MARGS="$(docker inspect "${KA_CONTAINER}" --format '{{range .Mounts}}-v {{.Source}}:{{.Destination}} {{end}}' 2>/dev/null || true)"
  fi
  KA_IMG="${Q2_KA_IMG:-${KA_IMG:-ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:latest}}"
  KA_NET="${Q2_KA_NET:-${KA_NET:-host}}"
  KA_MARGS="${Q2_KA_MARGS:-${KA_MARGS:-}}"
  log "保活烘焙：IMG=${KA_IMG} NET=${KA_NET} 挂载数=$(printf '%s' "${KA_MARGS}" | grep -o -- '-v ' | wc -l | tr -d ' ')"
}

write_keepalive() {
  {
    printf '#!/bin/bash\n'
    printf '# q2 看门狗保活 v%s（由 q2_hide_dns.sh 生成，请勿手工修改）\n' "${KA_VER}"
    printf '# 规则：happ < %s 补拉到 %s；happ >= %s 一律不动；docker / 容器挂了自动拉起\n' "${KA_N}" "${KA_N}" "${KA_N}"
    printf 'set -u\n'
    printf 'export LC_ALL=C\n'
    printf 'C="%s"\n' "${KA_CONTAINER}"
    printf 'N="%s"\n' "${KA_N}"
    printf 'DEBOUNCE="%s"\n' "${KA_DEBOUNCE}"
    printf 'PATTERN="%s"\n' "${KA_PATTERN}"
    printf 'IMG="%s"\n' "${KA_IMG}"
    printf 'NETMODE="%s"\n' "${KA_NET}"
    printf 'MARGS="%s"\n' "${KA_MARGS}"
    printf 'CFG="%s"\n' "${KA_CFG}"
    printf 'LOG="%s"\n' "${KA_LOG}"
    printf 'STAMP="%s"\n' "${KA_STAMP}"
    cat <<'KAEOF'

LOCK="/tmp/.q2_keepalive.lock"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }

# 计数口径与部署线验收一致：容器内 happ:vod 分片进程数
happ_cnt() {
  docker exec "$C" sh -c "ps -ef 2>/dev/null | grep -c '${PATTERN}'" 2>/dev/null | tr -d '\r\n'
}
container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$C"
}
num() {
  case "${1:-0}" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$1";; esac
}

# 防抖：重置后 DEBOUNCE 秒内不重复重启，避免 OOM 频发时每分钟断流
debounce_ok() {
  [ -f "$STAMP" ] || return 0
  local last now age
  # 读文件内容而非 stat -c %Y（后者是 GNU 专用，非 GNU 环境会静默退化成"允许重启"）
  last=$(num "$(cat "$STAMP" 2>/dev/null | tr -d '[:space:]')")
  now=$(date +%s)
  age=$(( now - last ))
  [ "$age" -ge "$DEBOUNCE" ]
}
mark() { date +%s > "$STAMP" 2>/dev/null || true; }

# S1 docker 守护进程自愈（CentOS 7：systemctl 优先，回落 service）
s1_docker() {
  if docker info >/dev/null 2>&1; then return 0; fi
  log "S1 docker 不可用，尝试拉起"
  systemctl start docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 12); do
    if docker info >/dev/null 2>&1; then
      log "S1 docker 已恢复（第 ${i} 次探测，约 $((i*5))s）"
      return 0
    fi
    sleep 5
  done
  log "S1 docker 拉起失败（等待 60s 仍不可用）"
  return 1
}

# S2 容器自愈：在跑→跳过；停了→docker start（保 SN 不变）；被删→按烘焙参数完整重建
s2_container() {
  if container_running; then return 0; fi
  log "S2 容器 ${C} 未运行，尝试拉起"
  if docker inspect "$C" >/dev/null 2>&1; then
    if docker start "$C" >/dev/null 2>&1; then
      log "S2 docker start 成功（保留原 SN）"
      sleep 15
      return 0
    fi
    log "S2 docker start 失败，改为完整重建"
    docker rm -f "$C" >/dev/null 2>&1 || true
  else
    log "S2 容器不存在，按烘焙参数完整重建"
  fi
  local out rc
  # shellcheck disable=SC2086  # MARGS 需要分词展开成多条 -v
  out=$(docker run -d --restart=always --name="$C" --network="$NETMODE" $MARGS \
        -v "$CFG:/app/ipes/var/db/ipes/happ-conf/custom.yml" \
        "$IMG" sh -c '/app/ipes/bin/ipes start && tail -f /dev/null' 2>&1)
  rc=$?
  log "S2 容器重建 rc=${rc} out=${out}"
  [ "$rc" = "0" ] || return 1
  sleep 20
  container_running
}

# S3 happ 路数：★ 只补低，不管高
s3_happ() {
  local cnt c i
  cnt=$(num "$(happ_cnt)")
  if [ "$cnt" -ge "$N" ]; then
    log "S3 happ=${cnt} >= ${N}，无需动作（超过 ${N} 路按规则不处理）"
    return 0
  fi
  log "S3 happ=${cnt} < ${N}，准备补拉"
  if ! debounce_ok; then
    log "S3 距上次重置不足 ${DEBOUNCE}s，本轮跳过（防反复断流）"
    return 0
  fi
  # 二次确认：debounce 检查与 restart 之间可能已被另一实例修好，避免重复断流
  c=$(num "$(happ_cnt)")
  if [ "$c" -ge "$N" ]; then
    log "S3 二次确认 happ=${c} >= ${N}，取消本轮 restart"
    return 0
  fi
  # 采用部署线验证过的路径：docker restart 会按 custom.yml 的 9 行 args 重新拉起全部分片
  log "S3 执行 docker restart ${C} 拉回 ${N} 路"
  docker restart "$C" >/dev/null 2>&1 || log "S3 docker restart 返回非 0"
  mark
  for i in $(seq 1 18); do
    sleep 5
    c=$(num "$(happ_cnt)")
    if [ "$c" -ge "$N" ]; then
      log "S3 已恢复 happ=${c}（第 ${i} 次验证，约 $((i*5))s）"
      return 0
    fi
  done
  c=$(num "$(happ_cnt)")
  log "S3 等待 90s 后 happ=${c} 仍未达 ${N}，保留现场等下轮"
  return 1
}

main() {
  touch "$LOG" 2>/dev/null; chmod 644 "$LOG" 2>/dev/null
  # 单实例互斥：cron 每分钟 + 手动触发可能撞在同一秒，两个进程同时看到掉路会重复 restart
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK" || exit 0
    if ! flock -n 9; then
      log "已有看门狗实例在运行，本轮退出（避免并发 restart）"
      exit 0
    fi
  fi
  # 1G 机器磁盘紧张，日志超 1MB 只保留最近 500 行（wc -c 比 stat -c %s 可移植）
  local sz
  sz=$(num "$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]')")
  if [ "$sz" -gt 1048576 ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
  fi
  if ! s1_docker; then log "主流程中止：docker 不可用（S1 已尝试自愈）"; exit 1; fi
  if ! s2_container; then log "主流程中止：容器不可用（S2 已尝试 start / 重建），下轮继续"; exit 1; fi
  s3_happ || true
  exit 0
}
main "$@"
KAEOF
  } > "${KA_PATH}"
  chmod 755 "${KA_PATH}"
}

install_keepalive() {
  log "===== 安装看门狗保活 v${KA_VER} ====="
  if [ "$(id -u)" != "0" ]; then log "⚠️ 非 root，跳过保活安装"; return 1; fi
  if ! command -v docker >/dev/null 2>&1; then log "⚠️ docker 命令不存在，跳过保活安装（不阻塞后续）"; return 1; fi
  if ! command -v crontab >/dev/null 2>&1; then log "⚠️ crontab 不存在，跳过保活安装"; return 1; fi

  capture_ka_params
  write_keepalive
  if ! bash -n "${KA_PATH}"; then
    log "❌ 保活脚本语法校验失败，未写 cron（DNS 流程继续）"
    return 1
  fi
  touch "${KA_LOG}" 2>/dev/null; chmod 644 "${KA_LOG}" 2>/dev/null

  local current filtered
  current="$(crontab -l 2>/dev/null || true)"
  filtered="$(printf '%s\n' "${current}" | grep -v 'q2_keepalive.sh' || true)"
  if [ "${KA_TAKEOVER}" = "1" ]; then
    # 旧保活是「happ != 9 就重启」的双向守恒，且 @reboot 带 bin/ipes stop 会停业务；
    # 两套并存会互相 restart，必须摘掉（Q2_KA_TAKEOVER=0 可保留）
    filtered="$(printf '%s\n' "${filtered}" \
      | grep -vE 'ipes_health_check|bin/ipes[[:space:]]+stop' || true)"
    log "已接管：移除旧 ipes_health_check / @reboot 停业务 cron（Q2_KA_TAKEOVER=0 可保留）"
  fi
  filtered="$(printf '%s\n' "${filtered}" | sed '/^[[:space:]]*$/d' || true)"
  {
    if [ -n "${filtered}" ]; then printf '%s\n' "${filtered}"; fi
    printf '* * * * * %s >/dev/null 2>&1\n' "${KA_PATH}"
    printf '@reboot sleep 120 && %s >/dev/null 2>&1\n' "${KA_PATH}"
  } | crontab - 2>/dev/null || { log "❌ crontab 写入失败，保活未生效"; return 1; }

  systemctl enable crond >/dev/null 2>&1 || true
  systemctl start crond >/dev/null 2>&1 || true
  ok "看门狗已装：${KA_PATH}（cron 每分钟 + @reboot）"
  log "规则：happ < ${KA_N} 补拉到 ${KA_N}；happ >= ${KA_N} 完全不动；docker / 容器挂了自动拉起"
  log "防抖：${KA_DEBOUNCE}s  日志：${KA_LOG}"
  return 0
}

remove_keepalive() {
  [ "$(id -u)" = "0" ] || die "需要 root 运行"
  local current filtered
  current="$(crontab -l 2>/dev/null || true)"
  filtered="$(printf '%s\n' "${current}" | grep -v 'q2_keepalive.sh' | sed '/^[[:space:]]*$/d' || true)"
  if [ -n "${filtered}" ]; then
    printf '%s\n' "${filtered}" | crontab - 2>/dev/null || true
  else
    printf '' | crontab - 2>/dev/null || true
  fi
  rm -f "${KA_PATH}" "${KA_STAMP}"
  ok "看门狗已移除（日志 ${KA_LOG} 保留）"
}

tidy_logs() {
  # docker 日志轮转：只写配置，不重启 docker（避免打断 9 路 happ；下次重启生效）
  if [ -f /etc/docker/daemon.json ]; then
    "${PYBIN}" - <<'PY'
import json
p = '/etc/docker/daemon.json'
try:
    d = json.load(open(p))
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
d.setdefault('log-driver', 'json-file')
o = d.setdefault('log-opts', {})
o['max-size'] = '20m'
o['max-file'] = '3'
with open(p, 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
  else
    mkdir -p /etc/docker
    printf '{"log-driver":"json-file","log-opts":{"max-size":"20m","max-file":"3"}}\n' > /etc/docker/daemon.json
  fi
  # 已经落盘的超大容器日志直接清空
  find /var/lib/docker/containers -name '*-json.log' -size +20M -exec truncate -s 0 {} \; 2>/dev/null || true
  journalctl --vacuum-size=100M >/dev/null 2>&1 || true
  : > /root/.bash_history 2>/dev/null || true
  # dnsmasq 自身不记录查询（配置里 log-facility=/dev/null，双保险）
}

self_install() {
  local src
  src="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  if [ -f "${src}" ] && [ "${src}" != "${SELF_PATH}" ]; then
    cp -f "${src}" "${SELF_PATH}" 2>/dev/null && chmod 755 "${SELF_PATH}" || true
  fi
}

precheck() {
  log "版本 ${HIDE_DNS_VER} / 模式 ${MODE}"
  [ "$(id -u)" = "0" ] || die "需要 root 运行"
  [ -n "${PYBIN}" ] || die "未找到 python 解释器（CentOS 7.9 自带 python2.7 即可）"
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemd"
  "${PYBIN}" -c 'import socket, struct, threading' || die "python 缺少标准库模块"
  if command -v dnsmasq >/dev/null 2>&1; then
    log "dnsmasq 已安装"
  else
    log "dnsmasq 未安装（安装阶段会 yum install -y dnsmasq）"
  fi
  log "原上游 DNS = $(resolve_upstream)"
  log "resolv.conf = $(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
  log "DoH 端点 = ${DOH_URLS}"
  log "前置检查完成（未改动任何文件）"
}

do_install() {
  precheck
  # ★ 保活独立于 DNS 安装，且刻意放在最前面：
  #   后面哪怕 yum 装 dnsmasq OOM 被杀、或 DoH 自检失败 die 退出，保活也已经生效。
  install_keepalive || log "⚠️ 看门狗安装未成功（不阻塞后续 DNS 流程）"
  mkdir -p "${STATE_DIR}"

  if ! command -v dnsmasq >/dev/null 2>&1; then
    log "安装 dnsmasq ..."
    yum install -y dnsmasq >/dev/null 2>&1 || die "dnsmasq 安装失败（检查 yum 源 / 流量包），未改动系统"
  fi

  ensure_suffix_file
  write_doh_proxy
  write_unit

  local up
  up="$(resolve_upstream)"
  [ -f "${RESOLV_BAK}" ] || cp -a /etc/resolv.conf "${RESOLV_BAK}"
  printf '%s\n' "${up}" > "${STATE_DIR}/dns_upstream"
  write_dnsmasq_conf "${up}"

  # 先验证 dnsmasq 配置语法，避免写出错误配置把 DNS 搞挂
  dnsmasq --test >/dev/null 2>&1 || { rm -f "${DNSMASQ_CONF}"; die "dnsmasq 配置语法校验失败，已移除配置"; }

  systemctl daemon-reload
  systemctl enable q2-doh-proxy >/dev/null 2>&1 || true
  systemctl restart q2-doh-proxy
  systemctl enable dnsmasq >/dev/null 2>&1 || true
  systemctl restart dnsmasq
  sleep 2

  # 三层自检：任何一层失败都不碰 resolv.conf
  log "自检 1/3：DoH 转发器 (127.0.0.1:5353) ..."
  dns_probe 5353 "${PROBE_IQY}" >/dev/null 2>&1 || die "DoH 转发自检失败，未改 resolv.conf（原配置保持不变）"
  log "自检 2/3：dnsmasq 解析爱奇艺域名 (127.0.0.1:53) ..."
  dns_probe 53 "${PROBE_IQY}" >/dev/null 2>&1 || die "dnsmasq 自检失败，未改 resolv.conf"
  log "自检 3/3：dnsmasq 解析通用域名 ..."
  dns_probe 53 "${PROBE_ANY}" >/dev/null 2>&1 || die "通用域名自检失败，未改 resolv.conf"

  apply_resolv
  log "resolv.conf 已指向本机（原配置备份在 ${RESOLV_BAK}）"

  # 端到端验证：getent 走 glibc → resolv.conf
  getent hosts "${PROBE_IQY}" >/dev/null 2>&1 || { rollback_resolv; die "端到端解析爱奇艺域名失败，已回滚 resolv.conf"; }
  getent hosts "${PROBE_ANY}" >/dev/null 2>&1 || { rollback_resolv; die "端到端解析通用域名失败，已回滚 resolv.conf"; }

  self_install
  install_cron
  tidy_logs

  ok "安装完成 · 版本 ${HIDE_DNS_VER}"
  log "明文 UDP 53 里现在只剩 ${PLAIN_SUFFIXES}，爱奇艺系域名走加密 HTTPS"
  log "动态解析保持实时（未写死 hosts/IP），派量不受影响"
  log "查询状态：bash ${SELF_PATH} --status"
  log "完整还原：bash ${SELF_PATH} --rollback"
  log "⚠️ docker 日志轮转配置已写入，需下次 docker 重启生效（挑低峰，保活会自动补回 happ 9）"
}

do_watchdog() {
  if dns_probe 53 "${PROBE_IQY}" >/dev/null 2>&1 && dns_probe 53 "${PROBE_ANY}" >/dev/null 2>&1; then
    rm -f "${FAIL_FILE}"
    exit 0
  fi
  local n
  n="$(cat "${FAIL_FILE}" 2>/dev/null || echo 0)"
  case "${n}" in ''|*[!0-9]*) n=0;; esac
  n=$((n + 1))
  printf '%s\n' "${n}" > "${FAIL_FILE}"
  if [ "${n}" -ge 3 ]; then
    log "连续 3 次 DNS 自检失败，自动恢复原 resolv.conf 以避免全机断解析"
    rollback_resolv
    rm -f "${FAIL_FILE}"
  fi
}

do_status() {
  echo "版本        : ${HIDE_DNS_VER}"
  echo "模式        : ${MODE}"
  echo "resolv.conf : $(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
  echo "备份        : $([ -f "${RESOLV_BAK}" ] && echo "${RESOLV_BAK}" || echo '无')"
  echo "dnsmasq     : $(systemctl is-active dnsmasq 2>/dev/null || echo 'n/a')"
  echo "DoH 转发    : $(systemctl is-active q2-doh-proxy 2>/dev/null || echo 'n/a')"
  echo "爱奇艺解析  : $(dns_probe 53 "${PROBE_IQY}" 2>/dev/null || echo 'FAIL')"
  echo "通用解析    : $(dns_probe 53 "${PROBE_ANY}" 2>/dev/null || echo 'FAIL')"
  echo "配置        : $([ -f "${DNSMASQ_CONF}" ] && echo "${DNSMASQ_CONF}" || echo '未安装')"
  echo "后缀清单    : $([ -f "${SUFFIX_FILE}" ] && echo "${SUFFIX_FILE} ($(wc -l < "${SUFFIX_FILE}") 行)" || echo '无')"
  echo "--- 看门狗保活 ---"
  echo "保活版本    : ${KA_VER}"
  echo "保活脚本    : $([ -x "${KA_PATH}" ] && echo "${KA_PATH}" || echo '未安装')"
  echo "保活 cron   : $(crontab -l 2>/dev/null | grep -c 'q2_keepalive.sh') 条"
  echo "路数规则    : < ${KA_N} 补拉；>= ${KA_N} 不动（超出不杀）"
  echo "防抖/日志   : ${KA_DEBOUNCE}s / ${KA_LOG}"
  echo "最近动作    : $(tail -n 1 "${KA_LOG}" 2>/dev/null || echo '无')"
}

do_rollback() {
  [ "$(id -u)" = "0" ] || die "需要 root 运行"
  rollback_resolv
  rm -f "${DNSMASQ_CONF}" "${DOH_PY}" "${UNIT_FILE}"
  systemctl stop q2-doh-proxy >/dev/null 2>&1 || true
  systemctl disable q2-doh-proxy >/dev/null 2>&1 || true
  systemctl restart dnsmasq >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  ( crontab -l 2>/dev/null | grep -v 'q2_hide_dns.sh' || true ) | crontab - 2>/dev/null || true
  rm -f "${FAIL_FILE}"
  ok "已回滚：resolv.conf 恢复、服务停止、cron 移除"
}

case "${1:-}" in
  --check)               precheck ;;
  --status)              do_status ;;
  --rollback)            do_rollback ;;
  --watchdog)            do_watchdog ;;
  --version)             echo "${HIDE_DNS_VER} / keepalive ${KA_VER}" ;;
  --keepalive-only)      install_keepalive ;;
  --rollback-keepalive)  remove_keepalive ;;
  *)                     do_install ;;
esac
exit 0

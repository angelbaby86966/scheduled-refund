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
#   bash q2_hide_dns.sh             安装并自检（失败自动回滚，不动 resolv.conf）
#   bash q2_hide_dns.sh --check    只检查前置条件，不改任何东西
#   bash q2_hide_dns.sh --status   查看当前状态
#   bash q2_hide_dns.sh --rollback 完整还原（恢复原 resolv.conf + 停服务）
#   bash q2_hide_dns.sh --version  输出版本指纹
#
# 可外置调整（随时改，不需要改脚本）：
#   Q2_HIDE_MODE=all|suffix        默认 all：除白名单一律走 DoH（最彻底）
#                                  suffix：只爱奇艺系后缀走 DoH（影响面最小）
#   Q2_IQY_SUFFIXES_FILE=/etc/q2/iqiyi_suffixes   后缀清单，每行一个
#   Q2_DOH_URLS="https://dns.alidns.com/dns-query,https://doh.pub/dns-query"
#   Q2_UPSTREAM=114.114.114.114    明文回退上游（DoH 全挂时 watchdog 用）
#
# ⚠️ 边界：TLS SNI 里的域名需要服务端 ECH 才能加密，客户端单方面改不了；
#          上行流量模型（大上行/海量连接/UDP 打洞）与本脚本无关，照旧可见。
# =============================================================================
set -u
export LC_ALL=C

HIDE_DNS_VER="1.0.0-20261114"
PYBIN="$(command -v python 2>/dev/null || command -v python3 2>/dev/null || true)"

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
  --check)    precheck ;;
  --status)   do_status ;;
  --rollback) do_rollback ;;
  --watchdog) do_watchdog ;;
  --version)  echo "${HIDE_DNS_VER}" ;;
  *)          do_install ;;
esac
exit 0

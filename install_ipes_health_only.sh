#!/bin/bash
# IPES 应用层保活 — 独立安装脚本（存量机补装专用）
# 与 ipes_deploy_full.sh 的 [6.7] install_ipes_health 同源同逻辑，单文件自包含。
#
# 用法（新机部署无需单独跑，deploy 脚本已内置 [6.7]）：
#   curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/r20-live/install_ipes_health_only.sh" | bash
#
# 行为：
#   - 写 /usr/local/bin/ipes_health_check.sh（每分钟：容器未运行->docker start；health 探测失败->docker restart，冷却 10 分钟）
#   - cron 精准维护：只替换 ipes_health_check 自己那一行，并清理渠道脚本历史写入的 @reboot `bin/ipes stop`
#   - 不触碰 watchdog / txlog / 日清 / ddos_guard / bbr_boot 等其它 cron
set -u
GREEN='\033[0;32m'; NC='\033[0m'
print_step(){ echo -e "${GREEN}[步骤]${NC} $*"; }
log_message(){ echo -e "$*"; }

install_ipes_health() {
    print_step "安装 IPES 保活（每分钟 health 探测 + 容器级兜底重启）"
    cat > /usr/local/bin/ipes_health_check.sh <<'HEALTH'
#!/usr/bin/env bash
# IPES 健康检查（融合版）：容器级 docker start 兜底 + 应用层 ./bin/ipes health 探测，
# 真正异常时才 docker restart 恢复；非交互、并对「探测命令不存在」做了跳过处理避免每分钟重启抖动。
LOG=/var/log/ipes_health.log
C=ipes
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
# 日志瘦身：超过 2MB 只留尾部 500 行（每分钟一条，约 60KB/天）
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
fi
echo "[$(ts)] 检查开始" >> "$LOG"
if ! docker ps --format '{{.Names}}' | grep -qx "$C"; then
  echo "[$(ts)] 容器未运行，尝试 docker start（SN 不变）" >> "$LOG"
  docker start "$C" >> "$LOG" 2>&1 && echo "[$(ts)] 已启动" >> "$LOG" || echo "[$(ts)] 启动失败，请检查" >> "$LOG"
  exit 0
fi
# 容器在跑，做应用层健康探测（./bin/ipes health 为 IPES 内部命令）
OUT=$(docker exec "$C" ./bin/ipes health 2>&1); RC=$?
# 探测命令本身不可用（容器内缺该命令 / exec 失败）-> 不重启，避免每分钟抖动
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qiE 'OCI runtime|exec: "|No such file|command not found'; then
  echo "[$(ts)] 健康探测命令不可用，跳过重启($OUT)" >> "$LOG"
  exit 0
fi
# 真正的服务异常 -> 重启容器恢复（同时恢复进程与容器内服务）
# 注意：正则只用【明确的失败特征】，绝不用裸 'error'（健康 JSON 常含 "errors":[] 会被误判，导致每分钟重启风暴）
if [ "$RC" -ne 0 ] || echo "$OUT" | grep -qiE 'connection refused|get services failed|unhealthy|not healthy|panic|refused to connect'; then
  # 重启冷却：10 分钟内只重启一次，避免健康探测偶发抖动引发每分钟重启、打断缓存写入
  LR=/var/lib/ipes-preheat/.last_health_restart
  now_ts=$(date +%s)
  last_ts=$(cat "$LR" 2>/dev/null || echo 0)
  if [ $((now_ts - last_ts)) -lt 600 ]; then
    echo "[$(ts)] 检测到异常但处于重启冷却期(10分钟)，本次跳过 ($OUT)" >> "$LOG"
    exit 0
  fi
  mkdir -p /var/lib/ipes-preheat 2>/dev/null
  echo "$now_ts" > "$LR" 2>/dev/null || true
  echo "[$(ts)] 检测到服务异常，准备 docker restart ($OUT)" >> "$LOG"
  docker restart "$C" >> "$LOG" 2>&1 && echo "[$(ts)] 已重启恢复" >> "$LOG" || echo "[$(ts)] 重启失败，请检查" >> "$LOG"
  exit 0
fi
echo "[$(ts)] 服务正常" >> "$LOG"
HEALTH
    chmod +x /usr/local/bin/ipes_health_check.sh
    touch /var/log/ipes_health.log 2>/dev/null
    # 精准重建 cron：只替换自己那一行；同时清掉渠道脚本历史写入的 @reboot `bin/ipes stop`（重启后停业务）
    ( crontab -l 2>/dev/null | grep -vE 'ipes_health_check|bin/ipes[[:space:]]+stop' ; \
      echo "* * * * * /usr/local/bin/ipes_health_check.sh >/dev/null 2>&1" ) | crontab -
    systemctl enable crond >/dev/null 2>&1 || true
    systemctl start crond >/dev/null 2>&1 || true
    log_message "${GREEN}[成功]${NC} 保活已安装（cron 每分钟：容器兜底启动 + health 探测，异常重启冷却10分钟）"
}

install_ipes_health

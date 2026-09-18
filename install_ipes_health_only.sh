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
# IPES 健康检查（融合版 + r20-fix11 硬自愈）：容器级 docker start 兜底 + 应用层 ./bin/ipes health 探测，
# 真正异常时才 docker restart 恢复；非交互、并对「探测命令不存在」做了跳过处理避免每分钟重启抖动。
# 容器 docker start 失败时，先执行 fix11_heal（xycould_base_info 目录/缺失 → 43B 文件）再重试启动。
LOG=/var/log/ipes_health.log
C=ipes
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
# 日志瘦身：超过 2MB 只留尾部 500 行（每分钟一条，约 60KB/天）
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
fi
echo "[$(ts)] 检查开始" >> "$LOG"

# ---------------------------------------------------------------------------
# 【r20-fix11 硬自愈】保证每个 /data/happ/happ.N/xycould_base_info 是 43B 文件而非目录。
#   根因：ecache/docker 会把缺失的挂载源自动补成【空目录】；docker-ce 对挂载类型校验严格，
#         目录会让容器 OCI create failed: not a directory → Exited(127)，此后 docker start
#         永远失败 → 节点"缓存还在但完全没有上下行"（2026-09-18 66d9ff7c 实测即此）。
#   修复：以 happ.0 的同名 43B 文件为模板，去掉坏目录后 cp 回来（幂等、不动缓存、不动 SN）。
#   内容只是每个 worker 的资源配额（disk_limit/mem_limit/cpu_core），各 happ 完全一致。
# ---------------------------------------------------------------------------
fix11_heal(){
  local ref=/data/happ/happ.0/xycould_base_info d p fixed=0
  [ -s "$ref" ] || return 1
  for d in /data/happ/happ.*; do
    [ -d "$d" ] || continue
    p="$d/xycould_base_info"
    if [ -d "$p" ]; then
      # 坏目录：为空则 rmdir；非空兜底 rm -rf（该路径是挂载源，正常必为 43B 文件，绝不会是数据目录）
      rmdir "$p" 2>/dev/null || rm -rf "$p" 2>/dev/null
    fi
    if [ ! -e "$p" ]; then
      # 缺失 / 刚删掉 → 用 happ.0 模板补回 43B 文件
      cp -f "$ref" "$p" 2>/dev/null && fixed=$((fixed+1))
    fi
  done
  if [ "$fixed" -gt 0 ]; then
    echo "[$(ts)] [fix11] 已修复 $fixed 个 xycould_base_info（目录/缺失 → 文件），准备重试启动" >> "$LOG"
    return 0
  fi
  return 1
}

if ! docker ps --format '{{.Names}}' | grep -qx "$C"; then
  echo "[$(ts)] 容器未运行，尝试 docker start（SN 不变）" >> "$LOG"
  if docker start "$C" >> "$LOG" 2>&1; then
    echo "[$(ts)] 已启动" >> "$LOG"
  else
    # docker start 失败 → 先查 fix11 挂载类型异常；修好再重试一次
    if fix11_heal; then
      if docker start "$C" >> "$LOG" 2>&1; then
        echo "[$(ts)] [fix11] 修复挂载后已启动" >> "$LOG"
      else
        echo "[$(ts)] [fix11] 修复后仍启动失败：$(docker inspect -f '{{.State.Error}}' "$C" 2>/dev/null | head -c 200)" >> "$LOG"
      fi
    else
      echo "[$(ts)] 启动失败且未发现 fix11 挂载异常，请检查" >> "$LOG"
    fi
  fi
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
    log_message "${GREEN}[成功]${NC} 保活已安装（cron 每分钟：容器兜底启动 + fix11 挂载自愈 + health 探测，异常重启冷却10分钟）"
}

install_ipes_health

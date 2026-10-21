#!/bin/bash
# ==============================================================================
# 真保活安装器 v2.1  ——  drop-in 替换 OSS 上被回滚的 6213B 假保活
#   能力（比 6213B 假货 / 21266B v2.0 更全）：
#     S1 容器没了→ docker start（保 SN 不变）
#     S2 服务/doctor 异常 → docker restart（10 分钟冷却防抖）
#     S3 挂载被 docker 补成目录 → fix11_heal 修复 xycould_base_info 再起
#     S4 happ 9 路守恒 → 容器内 happ:vod 进程数 != 9 自动 docker restart 拉回
#     S5 每分钟 cron 兜底
#   额外：安装时自动清理 crontab 里的 @reboot ... ipes stop 地雷
# ==============================================================================
HC_VER="2.1"
LOG=/var/log/ipes_health.log
echo "[真保活 v$HC_VER] 写入 /usr/local/bin/ipes_health_check.sh ..."
cat > /usr/local/bin/ipes_health_check.sh <<'ZYY_HEALTH_EOF'
#!/usr/bin/env bash
HC_VER="2.1"
# IPES 健康检查（融合版 + r20-fix11 硬自愈）：容器级 docker start 兜底 + 应用层 ./bin/ipes health 探测，
# 真正异常时才 docker restart 恢复；非交互、并对「探测命令不存在」做了跳过处理避免每分钟重启抖动。
# 容器 docker start 失败时，先执行 fix11_heal（xycould_base_info 目录/缺失 → 43B 文件）再重试启动。
# ★ 这正是「doctor 没了 / 容器没了，都会自动拉起」的实现：cron 每分钟跑一次，
#   容器不在就 docker start（保 SN 不变）；容器在但服务异常就 docker restart（冷却 10 分钟避免抖动）；
#   挂载类型异常（目录取代 43B 文件导致 Exited(127)）先 fix11 修复再起。
LOG=/var/log/ipes_health.log
C=ipes
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
fi
echo "[$(ts)] 检查开始" >> "$LOG"
fix11_heal(){
  local ref=/data/happ/happ.0/xycould_base_info d p fixed=0
  [ -s "$ref" ] || return 1
  for d in /data/happ/happ.*; do
    [ -d "$d" ] || continue
    p="$d/xycould_base_info"
    if [ -d "$p" ]; then
      rmdir "$p" 2>/dev/null || rm -rf "$p" 2>/dev/null
    fi
    if [ ! -e "$p" ]; then
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
OUT=$(docker exec "$C" ./bin/ipes health 2>&1); RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qiE 'OCI runtime|exec: "|No such file|command not found'; then
  echo "[$(ts)] 健康探测命令不可用，跳过重启($OUT)" >> "$LOG"
  exit 0
fi
if [ "$RC" -ne 0 ] || echo "$OUT" | grep -qiE 'connection refused|get services failed|unhealthy|not healthy|panic|refused to connect'; then
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
# happ 9 路守恒：v5 固定 9 路，容器内 happ:vod 进程数必须恒为 9；
# 容器活着但某路 happ 进程掉了（health 探针未必能查到分片数下降），这里兜底重启拉回 9 路。
HC=$(docker exec "$C" sh -c 'ps -ef 2>/dev/null | grep -c "[h]app:vod"' 2>/dev/null | tr -d '\r\n')
if [ "${HC:-0}" != "9" ]; then
  LR2=/var/lib/ipes-preheat/.last_happ_restart
  now_ts=$(date +%s)
  last_ts=$(cat "$LR2" 2>/dev/null || echo 0)
  if [ $((now_ts - last_ts)) -lt 600 ]; then
    echo "[$(ts)] happ 进程数=$HC(期望9) 但处于重启冷却期(10分钟)，本次跳过" >> "$LOG"
  else
    mkdir -p /var/lib/ipes-preheat 2>/dev/null
    echo "$now_ts" > "$LR2" 2>/dev/null || true
    echo "[$(ts)] happ 进程数=$HC(期望9)，准备 docker restart 拉回 9 路" >> "$LOG"
    docker restart "$C" >> "$LOG" 2>&1 && echo "[$(ts)] 已重启恢复 9 路" >> "$LOG" || echo "[$(ts)] 重启失败，请检查" >> "$LOG"
  fi
  exit 0
fi
echo "[$(ts)] 服务正常（happ=$HC）" >> "$LOG"
ZYY_HEALTH_EOF
chmod +x /usr/local/bin/ipes_health_check.sh
touch "$LOG" 2>/dev/null
echo "[真保活 v$HC_VER] 写入 cron（每分钟）+ 清理 @reboot 停业务地雷 ..."
( crontab -l 2>/dev/null | grep -vE 'ipes_health_check|bin/ipes[[:space:]]+stop' ; \
  echo "* * * * * /usr/local/bin/ipes_health_check.sh >/dev/null 2>&1" ) | crontab -
systemctl enable crond >/dev/null 2>&1 || true
systemctl start crond >/dev/null 2>&1 || true
echo "[真保活 v$HC_VER] 自检："
grep -m1 'HC_VER=' /usr/local/bin/ipes_health_check.sh
echo "  cron 条数: $(crontab -l 2>/dev/null | grep -cE 'ipes_health_check')"
echo "  @reboot地雷: $(crontab -l 2>/dev/null | grep -cE '@reboot.*ipes[[:space:]]+stop') 条（应为 0）"
echo "[真保活 v$HC_VER] 安装完成。"

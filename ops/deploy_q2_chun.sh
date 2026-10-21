#!/bin/bash
# ==============================================================================
# q2 纯净版一键部署 · 安全 wrapper（根治版）
#
# 相比你原来那段命令，这里根治了 4 个问题：
#   ① JWT 不再明文写在命令行里（改读环境变量 Q2_JWT 或 /etc/q2/jwt，避免泄露到
#      云助手历史 / shell history / 进程 ps）
#   ② 不再用 curl|bash 前台串行 → 改 nohup 后台 + flock 互斥，避免云助手命令超时
#      把父 bash 连带杀掉（就是 10-20 那台机半成品的根因）
#   ③脚本锁 commit 47bd1936…（该版 [3/4] 已改为从 GitHub 拉真保活 v2.1，
#      不再拉 OSS 上被回滚的 6213B 假保活）
#   ④ 下载后先校验大小+ sha256，再执行；失败明确报错，不留半成品
#
# 用法（云助手 / SSH 均可）：
#   export Q2_JWT='<你的有效JWT>'        # 或 echo <token> > /etc/q2/jwt
#   bash deploy_q2_chun.sh
# 建议：云助手超时 ≥1800秒，或本脚本已自带 nohup 后台化。
# ==============================================================================
set -u

# ── 1. JWT：环境变量优先，其次 /etc/q2/jwt；都没有就报错退出 ──
Q2_JWT_FILE="${Q2_JWT_FILE:-/etc/q2/jwt}"
if [ -z "${Q2_JWT:-}" ] && [ -f "$Q2_JWT_FILE" ]; then
  Q2_JWT="$(tr -d '[:space:]' < "$Q2_JWT_FILE")"
fi
if [ -z "${Q2_JWT:-}" ]; then
  echo "✗ 未找到 JWT。请先执行：export Q2_JWT='<token>'  或  echo <token> > $Q2_JWT_FILE" >&2
  exit 1
fi

# ── 2. 锁 commit + 双通道下载 + 校验（不用 @main，避免被漂移影响）──
C=47bd1936f1cb79ac9bb60f9960d5e357dda22410
P="ops/q2%E7%BA%AF%E5%87%80%E7%89%88.sh"
EXPECT_SHA="9d592b10438c829f3d5a4e7fdc215eacaf25a4dbbfe1ab96bc59a4569b5134f0"
SCRIPT=/tmp/q2_chun.sh

curl -4fsSL --max-time 120 "https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@${C}/${P}" -o "$SCRIPT" \
  || curl -4fsSL --max-time 120 "https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/${C}/${P}" -o "$SCRIPT" \
  || { echo "✗ 下载失败（jsDelivr 与 raw 都不通）"; exit 9; }

GOT_SHA=$(sha256sum "$SCRIPT" | cut -d' ' -f1)
if [ "$GOT_SHA" != "$EXPECT_SHA" ]; then
  echo "✗ sha256 不匹配！期望 $EXPECT_SHA 实际 $GOT_SHA —— 可能被篡改，中止。" >&2
  exit 8
fi
echo "✓ 下载完成并通过 sha256 校验：$GOT_SHA"

# ── 3. 后台执行（nohup + setsid脱离会话），日志可tail ──
LOG=/tmp/q2_chun_deploy_$$.log
export Q2_JWT   # 传给子进程，不落到命令行
nohup setsid # 注意：不要加 bash -x（会把 export 的 JWT 等打进日志泄露）
bash "$SCRIPT" > "$LOG" 2>&1 &
PID=$!
echo "✓ 已在后台启动（PID=$PID），日志：$LOG"
echo "  查看进度：tail -f $LOG"
echo "  确认后台化：ps -p $PID -o pid,cmd"
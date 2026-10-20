#!/bin/bash
# ==============================================================================
# 舟翼云 q2（业务41）一键部署 · v7 薄入口（只负责「首次落盘 + 派发」，不含部署逻辑）
#
# 定位：q2_stage.sh 是唯一实现体（bind/flow/deploy 全部分阶段 + 后台化 + 断点续跑），
#   本文件只做三件事：
#     ① 校验 token 就绪（外置，不内置密钥）
#     ② 四道校验下载 q2_stage.sh 到 /root/q2_stage.sh（发布时 __Q2_STAGE_URL__ 会被
#        publish_q2_staged.py 回填为「本次 commit 的 jsDelivr 钉版本 URL」）
#     ③ exec 移交：Q2_STAGE=all bash /root/q2_stage.sh（断点续跑由 q2_stage.sh 负责）
#
# 用法（二选一）：
#   A. 云助手「命令助手」人工粘贴（单台，超时建议 ≥1800s）：
#        export Q2_JWT=<token>
#        curl -fsSL --max-time 60 <发布后给出的 URL> | bash
#      （管道执行时 $0 不是本文件路径，q2_stage.sh 另有 self_path 回落机制兜底）
#
#   B. 先落盘再执行（更稳，推荐 200 台批量场景）：
#        curl -fsSL --max-time 60 -o /root/q2_oneclick_v7.sh <本文件 URL>
#        export Q2_JWT=<token> && bash /root/q2_oneclick_v7.sh
#
# token 外置优先级：export Q2_JWT=xxx  >  文件 ${Q2_JWT_FILE:-/etc/q2/jwt}
#   换 token 只改环境变量或重写该文件，无需改脚本；JWT 过期可即时更替。
# ==============================================================================
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

say() { echo "[$(date '+%F %T')] $*"; }

REMOTE_SCRIPT="${Q2_REMOTE_SCRIPT:-/root/q2_stage.sh}"
Q2_JWT_FILE="${Q2_JWT_FILE:-/etc/q2/jwt}"

# ── ① token 就绪校验（缺 token 直接退出 2，与 q2_stage.sh 内部判定区分）──
if [ -z "${Q2_JWT:-}" ] && [ -f "$Q2_JWT_FILE" ]; then
  Q2_JWT="$(tr -d '[:space:]' < "$Q2_JWT_FILE" 2>/dev/null || true)"
fi
if [ -z "${Q2_JWT:-}" ]; then
  say "❌ 未找到 JWT（token 外置，本脚本不内置密钥），退出码 2。两种就绪方式任选其一："
  say "   方式一（推荐，批量/控制端）：export Q2_JWT=<token> 后再执行本脚本"
  say "   方式二（单台常驻）：echo <token> > $Q2_JWT_FILE && chmod 600 $Q2_JWT_FILE"
  say "   token 过期后只需更新环境变量或该文件，无需改脚本。"
  exit 2
fi

# ── ② 四道校验下载 q2_stage.sh（发布时占位符被回填为钉版本 URL）──
# 占位符未被回填 = 本地/未发布副本直接拿来跑，必须显式报错，不能静默 curl 占位符
STAGE_URL="__Q2_STAGE_URL__"
if [ "$STAGE_URL" = "__Q2_STAGE_URL__" ] || [ -z "$STAGE_URL" ]; then
  say "❌ 下载源占位符 __Q2_STAGE_URL__ 未被回填：本文件是未发布副本。"
  say "   请改用发布后的 URL（publish_q2_staged.py 输出里的 jsDelivr 钉版本地址），"
  say "   或人工指定：STAGE_URL='https://cdn.jsdelivr.net/gh/<repo>@<sha>/q2_staged/q2_stage.sh' bash $0"
  exit 3
fi

say "===== q2 一键部署 v7 开始 $(date '+%F %T') ====="
say "下载源: $STAGE_URL"
mkdir -p "$(dirname "$REMOTE_SCRIPT")" 2>/dev/null || true

if [ ! -s "$REMOTE_SCRIPT" ]; then
  say "  ${REMOTE_SCRIPT} 不存在，开始下载…"
else
  say "  ${REMOTE_SCRIPT} 已存在（$(wc -c < "$REMOTE_SCRIPT" | tr -d ' ')B），跳过下载（幂等）"
fi

if [ ! -s "$REMOTE_SCRIPT" ]; then
  dl_ok=0
  for attempt in 1 2 3; do
    if curl -fsSL --connect-timeout 5 --max-time 60 "$STAGE_URL" -o "${REMOTE_SCRIPT}.part" 2>/dev/null; then
      # 校验1：非空且够长（q2_stage.sh 现约 93KB，<10KB 必为截断/错误页）
      if [ -s "${REMOTE_SCRIPT}.part" ] && [ "$(wc -c < "${REMOTE_SCRIPT}.part" | tr -d ' ')" -ge 10240 ]; then
        # 校验2：指纹必须是 q2_stage.sh 本体（含其独有标记）
        if grep -q "Q2_STAGE" "${REMOTE_SCRIPT}.part" 2>/dev/null; then
          # 校验3：不能是 HTML 错误页（jsDelivr 404/限流页）
          if head -c 2000 "${REMOTE_SCRIPT}.part" | grep -qiE "<!DOCTYPE html|<html|404: Not Found"; then
            say "  ✗ 第 ${attempt} 次：返回 HTML 错误页，重试…"
          # 校验4：语法必须正确（残缺 heredoc/管道截断在这一步现形）
          elif bash -n "${REMOTE_SCRIPT}.part" 2>/dev/null; then
            mv "${REMOTE_SCRIPT}.part" "$REMOTE_SCRIPT"
            chmod +x "$REMOTE_SCRIPT" 2>/dev/null || true
            dl_ok=1
            break
          else
            say "  ✗ 第 ${attempt} 次：bash -n 语法校验失败，重试…"
          fi
        else
          say "  ✗ 第 ${attempt} 次：指纹不匹配（缺 Q2_STAGE 标记），重试…"
        fi
      else
        say "  ✗ 第 ${attempt} 次：内容为空或过短（<10KB），重试…"
      fi
    else
      say "  ✗ 第 ${attempt} 次：curl 下载失败，重试…"
    fi
    rm -f "${REMOTE_SCRIPT}.part" 2>/dev/null || true
    sleep 3
  done

  if [ "$dl_ok" != "1" ]; then
    rm -f "${REMOTE_SCRIPT}.part" 2>/dev/null || true
    say "❌ 三次尝试均未能取到合格的 q2_stage.sh，退出码 1（不进入部署，避免误判）"
    say "   已尝试源: $STAGE_URL"
    exit 1
  fi
  say "  ✅ q2_stage.sh 已落盘: ${REMOTE_SCRIPT}（$(wc -c < "$REMOTE_SCRIPT" | tr -d ' ')B）"
fi

# 落盘后再做一次全量四道校验（覆盖「已存在跳过下载」路径：磁盘上的旧文件也须合格）
sz=$(wc -c < "$REMOTE_SCRIPT" | tr -d ' ')
if [ ! -s "$REMOTE_SCRIPT" ] || [ "$sz" -lt 10240 ]; then
  say "❌ $REMOTE_SCRIPT 为空或过短（${sz}B < 10240B），退出码 1"
  exit 1
fi
if ! grep -q "Q2_STAGE" "$REMOTE_SCRIPT" 2>/dev/null; then
  say "❌ $REMOTE_SCRIPT 指纹不匹配（缺 Q2_STAGE 标记），退出码 1"
  exit 1
fi
if head -c 2000 "$REMOTE_SCRIPT" | grep -qiE "<!DOCTYPE html|<html|404: Not Found"; then
  say "❌ $REMOTE_SCRIPT 是 HTML 错误页，退出码 1"
  exit 1
fi
if ! bash -n "$REMOTE_SCRIPT" 2>/dev/null; then
  say "❌ $REMOTE_SCRIPT bash -n 语法校验失败，退出码 1"
  exit 1
fi

# ── ③ exec 移交：Q2_STAGE=all（断点续跑/幂等/失败可判定全部由 q2_stage.sh 负责）──
say "移交执行: Q2_STAGE=all bash ${REMOTE_SCRIPT}（日志同步到 /var/log/ipes_nohup.log）"
exec env Q2_STAGE=all bash "$REMOTE_SCRIPT"

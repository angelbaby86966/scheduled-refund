#!/bin/bash
# ==============================================================================
# 舟翼云 q2（业务41）一键部署 · v6.2.1（加固版·组件自包含 + 全下载点多源重试）
#   ① 先绑定+注册 → 占位符流转「服务中」（节点立刻可被调度）
#   ② 部署（docker + Q2业务 + 9路一次做对 + 真SN回填 + 保活 + 限速）
#      以 setsid 后台运行，云助手命令秒回，真进度写 /var/log/ipes_nohup.log
#   纯净版：不做系统调优（cubic + pfifo_fast），happ 固定 9 路
#   v6.2 新增：① 镜像源【腾讯云 CCR 省外】youkai-latest:latest（youkai/youkai@6688 实测有效，绕开过期的阿里云北京仓库；失败时 OSS tar 兜底）
#             ② 限速【每分钟自愈】（窗口内 htb 规则丢失则 1 分钟内重建）
#   v6.2.1 新增：① Q2部署/保活/限速三组件 base64 内嵌（主路径零外部依赖，根治北京 OSS 瞬时抖动导致的 [2.3] 秒失败）
#             ② docker 安装/渠道绑定改 fetch_script 3 轮重试；docker 已就绪则跳过安装（重跑不再傻等 3 分钟）
#             ③ 限速自愈 watch 优先跑本地 run_limit 副本；④ 全部下载点统一「多轮 + 大小 + bash -n」校验
#
# ------------------------------------------------------------------
# ★★ 部署命令（务必用这个，禁止 `curl … | bash`）★★
#    `curl … | bash` 在下载失败（TCP reset / 404 / 超时）时，bash 收到空输入
#    仍会 exit 0，云助手因此显示「执行成功」，但机器上一个字节都没部署。
#    这是 v6 最致命的静默失败。v6.1 起改为：多源 → 落盘 → 校验 → 执行。
#
#   export Q2_JWT=<你的token>
#   /bin/bash /root/q2_oneclick_v6.sh --bootstrap
#
#   等价的自举命令（不依赖本文件的 --bootstrap，可直接复制粘贴）：
#   ★ 国内源（init-full-deploy.app.workbuddy.host）排在最前，深圳/广州等出网
#     不稳的机器优先走它，1 秒内拉到，内容与 GitHub 源同字节（sha256 一致）。
#
#   export Q2_JWT=<你的token>
#   D=/root/q2_oneclick_v6.sh
#   for U in \
#     "https://init-full-deploy.app.workbuddy.host/q2_oneclick_v6" \
#     "https://gh-proxy.com/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund@d7f2b12ece86635079b5c543cf66475d5186f72c/ops/q2_oneclick_v6.sh" \
#     "https://raw.githubusercontent.com/angelbaby86966/scheduled-refund@d7f2b12ece86635079b5c543cf66475d5186f72c/ops/q2_oneclick_v6.sh" \
#     "https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@d7f2b12ece86635079b5c543cf66475d5186f72c/ops/q2_oneclick_v6.sh"; do
#     curl -fsSL -m 90 "$U" -o "$D" 2>/dev/null && \
#     [ "$(wc -c <"$D")" -gt 3000 ] && bash -n "$D" 2>/dev/null && break
#     rm -f "$D"
#   done
#   [ -s "$D" ] || { echo "[FATAL] 下载失败"; exit 1; }
#   chmod +x "$D"; /bin/bash "$D"
#
# ------------------------------------------------------------------
# 用法：先备好 token（export Q2_JWT=xxx，或 echo <token> > /etc/q2/jwt）
#      云助手「命令助手」超时 ≥1200 秒（仅绑定时长）。
#      普通重跑：/bin/bash q2_oneclick_v6.sh
#      自举下载：/bin/bash q2_oneclick_v6.sh --bootstrap
#      后台部署子进程（勿手工调用）：/bin/bash q2_oneclick_v6.sh --internal-deploy
# ==============================================================================

# ==============================================================================
# 基础设施（bootstrap / 主流程 / 子进程共用，必须最先定义）
# ==============================================================================
LOG=/tmp/q2_v6_$$.log
touch "$LOG" 2>/dev/null || LOG=/dev/null
exec > >(tee -a "$LOG" 2>/dev/null) 2>&1
say() { echo "[$(date '+%H:%M:%S')] $*"; }
FAIL=""; mark_fail() { FAIL="${FAIL} $1"; say "  ✗ 失败：$1"; }
# 失败步骤汇总（去首尾空格 + 空格转逗号），供验收行与调用方 grep
fail_list() { printf '%s' "$FAIL" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/,/g'; }

# ==============================================================================
# ★ 通用下载器：多源依次尝试 → 落盘 → 校验（大小 + bash -n）→ 换下一个源
#   用法: fetch_script <输出文件> <最小字节> <超时秒> <尝试轮数> <URL...>
#   返回: 0=全部校验通过；1=所有源都失败
#   说明: 任何一次失败都不会让上层"看起来成功"，上层必须显式判断返回值。
# ==============================================================================
fetch_script() {
  local out="$1" min="$2" to="$3" rounds="$4"; shift 4
  local u tmp sz r
  mkdir -p "$(dirname "$out")" 2>/dev/null
  rm -f "$out" 2>/dev/null
  for r in $(seq 1 "$rounds"); do
    [ "$r" -gt 1 ] && say "     ↻ 第 $r/$rounds 轮重试…"
    for u in "$@"; do
      tmp="${out}.part.$$"
      rm -f "$tmp" 2>/dev/null
      say "     ↘ 源: $u"
      if ! curl -fsSL -m "$to" "$u" -o "$tmp" 2>/dev/null; then
        say "        ✗ 下载失败（网络错误/404/超时）"; rm -f "$tmp" 2>/dev/null; continue
      fi
      sz=$(wc -c <"$tmp" 2>/dev/null | tr -d ' ')
      case "${sz:-x}" in (''|*[!0-9]*) sz=0 ;; esac
      if [ "$sz" -lt "$min" ]; then
        say "        ✗ 内容过小（${sz}B < ${min}B，疑似被截断/网关拦截页）"
        rm -f "$tmp" 2>/dev/null; continue
      fi
      if ! bash -n "$tmp" 2>/dev/null; then
        say "        ✗ bash -n 语法校验失败（内容不是可执行脚本）"
        rm -f "$tmp" 2>/dev/null; continue
      fi
      if mv -f "$tmp" "$out" 2>/dev/null; then
        say "        ✅ 校验通过（${sz}B，bash -n OK）→ $out"
        return 0
      fi
      say "        ✗ 落盘失败：$out"
      rm -f "$tmp" 2>/dev/null
    done
  done
  rm -f "$out" 2>/dev/null
  return 1
}

# ==============================================================================
# ★ 通用二进制下载器（镜像 tar 等非脚本文件）：下载 → 大小校验 → 落盘
#   用法: fetch_blob <输出文件> <最小字节> <超时秒> <URL>
#   返回: 0=下载成功且大小达标；1=网络错误/过小
#   不校验内容语法（二进制），仅用最小字节防截断/网关拦截页。
# ==============================================================================
fetch_blob() {
  local out="$1" min="$2" to="$3" url="$4" tmp sz
  tmp="${out}.part.$$"; rm -f "$tmp" 2>/dev/null
  if ! curl -fsSL -m "$to" "$url" -o "$tmp" 2>/dev/null; then
    say "        ✗ 下载失败（网络错误/404/超时）"; rm -f "$tmp" 2>/dev/null; return 1
  fi
  sz=$(wc -c <"$tmp" 2>/dev/null | tr -d ' ')
  case "${sz:-x}" in (''|*[!0-9]*) sz=0 ;; esac
  if [ "$sz" -lt "$min" ]; then
    say "        ✗ 内容过小（${sz}B < ${min}B，疑似被截断/网关拦截页）"
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  if mv -f "$tmp" "$out" 2>/dev/null; then
    say "        ✅ 校验通过（${sz}B）→ $out"; return 0
  fi
  say "        ✗ 落盘失败：$out"; rm -f "$tmp" 2>/dev/null; return 1
}

# ==============================================================================
# ★ v6.2.1 内嵌组件（base64）：Q2部署 / 保活 / 限速 三个脚本打进本体
#   主路径零外部依赖——根治「OSS 瞬时抖动 → [2.3] curl 秒失败 → 容器起不来」。
#   解码后经「最小字节 + bash -n」双校验；内嵌失败才回落 OSS 多源重试。
#   组件来源与 sha256（2026-10-18 取自 zyy-go.oss-cn-beijing）：
#     ecache_auto_disk_install.sh   4caed75acd6a8130068a3858e55435e26472e5b0cb58b22f3db21d3302132704  (2756B)
#     install_ipes_health_check.sh  ab99f1c6256ff83a265a08799d939102a2b7e61ab12244311dfbc69a09301859  (6213B)
#     run_limit.sh                  ed5eb4da8877849199a90cd285a4477d96dae70c23e7a453a6d4e540276a35a0  (10629B)
# ==============================================================================
embed_out() {  # embed_out <输出文件> <最小字节> <base64变量名>；0=解码+校验通过
  local out="$1" min="$2" var="$3" tmp sz
  tmp=$(mktemp /tmp/_emb.XXXXXX) || return 1
  if printf '%s' "${!var}" | base64 -d >"$tmp" 2>/dev/null \
     && [ "$(wc -c <"$tmp" | tr -d ' ')" -ge "$min" ] \
     && bash -n "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$out" 2>/dev/null && chmod +x "$out" 2>/dev/null && return 0
  fi
  rm -f "$tmp" 2>/dev/null; return 1
}

EMB_Q2_B64="IyEvYmluL2Jhc2gKCiMg5qOA5p+l5piv5ZCm5pyJ6Zmk57O757uf55uY5aSW55qE5YW25LuW56Gs55uYCmNoZWNrX2FkZGl0aW9uYWxfZGlza3
MoKSB7CiAgICAjIOiOt+WPluezu+e7n+agueWIhuWMuuaJgOWcqOeahOejgeebmAogICAgcm9vdF9kaXNrPSQobHNibGsgLW4gLW8gUEtOQU1F
ICQoZGYgLyAtLW91dHB1dD1zb3VyY2UgfCB0YWlsIC0xKSAyPi9kZXYvbnVsbCkKICAgIAogICAgIyDnu5/orqHpmaTns7vnu5/nm5jlpJbnmo
Tlhbbku5bno4Hnm5jmlbDph48KICAgIGFkZGl0aW9uYWxfZGlza19jb3VudD0kKGxzYmxrIC1uZCAtbyBOQU1FIHwgZ3JlcCAtdiAiXiR7cm9v
dF9kaXNrfSQiIHwgZ3JlcCAtdiAi4pSU4pSAIiB8IGdyZXAgLXYgIuKUnOKUgCIgfCBncmVwIC12ICdzcjAnIHwgd2MgLWwpCiAgICAKICAgIG
lmIFsgJGFkZGl0aW9uYWxfZGlza19jb3VudCAtZ3QgMCBdOyB0aGVuCiAgICAgICAgZWNobyAi5qOA5rWL5Yiw57O757uf5pyJICR7YWRkaXRp
b25hbF9kaXNrX2NvdW50fSDlnZflhbbku5bnoaznm5giCiAgICAgICAgcmV0dXJuIDAgICMg5a2Y5Zyo5YW25LuW56Gs55uYCiAgICBlbHNlCi
AgICAgICAgZWNobyAi5pyq5qOA5rWL5Yiw6Zmk57O757uf55uY5aSW55qE5YW25LuW56Gs55uYIgogICAgICAgIHJldHVybiAxICAjIOS4jeWt
mOWcqOWFtuS7luehrOebmAogICAgZmkKfQoKIyDmmL7npLrnlKjms5Xkv6Hmga8KdXNhZ2UoKSB7CiAgICBlY2hvICLnlKjms5U6ICQwIC10ID
zlj4LmlbAxPiAtaSA85Y+C5pWwMj4iCiAgICBlY2hvICLkvovlpoI6ICQwIC10IHR5cGVfdmFsdWUgLWkgaWRfdmFsdWUiCiAgICBleGl0IDEK
fQoKIyDkuLvmiafooYzlh73mlbAKbWFpbigpIHsKICAgIGxvY2FsIHRfcGFyYW09IiIKICAgIGxvY2FsIGlfcGFyYW09IiIKCiAgICAjIOino+
aekOWRveS7pOihjOWPguaVsAogICAgd2hpbGUgW1sgJCMgLWd0IDAgXV07IGRvCiAgICAgICAgY2FzZSAkMSBpbgogICAgICAgICAgICAtdCkK
ICAgICAgICAgICAgICAgIHRfcGFyYW09IiQyIgogICAgICAgICAgICAgICAgc2hpZnQgMgogICAgICAgICAgICAgICAgOzsKICAgICAgICAgIC
AgLWkpCiAgICAgICAgICAgICAgICBpX3BhcmFtPSIkMiIKICAgICAgICAgICAgICAgIHNoaWZ0IDIKICAgICAgICAgICAgICAgIDs7CiAgICAg
ICAgICAgICopCiAgICAgICAgICAgICAgICBlY2hvICLmnKrnn6Xlj4LmlbA6ICQxIgogICAgICAgICAgICAgICAgdXNhZ2UKICAgICAgICAgIC
AgICAgIDs7CiAgICAgICAgZXNhYwogICAgZG9uZQoKICAgICMg5qOA5p+l5Y+C5pWw5piv5ZCm5a6M5pW0CiAgICBpZiBbIC16ICIkdF9wYXJh
bSIgXSB8fCBbIC16ICIkaV9wYXJhbSIgXTsgdGhlbgogICAgICAgIGVjaG8gIumUmeivrzogLXQg5ZKMIC1pIOWPguaVsOmDveaYr+W/hemcgO
eahCIKICAgICAgICB1c2FnZQogICAgZmkKCiAgICBlY2hvICLlvIDlp4vmiafooYznu7zlkIjohJrmnKwuLi4iCiAgICBlY2hvICLlj4LmlbAg
LXQ6ICR0X3BhcmFtIgogICAgZWNobyAi5Y+C5pWwIC1pOiAkaV9wYXJhbSIKCiAgICAjIOajgOafpeaYr+WQpuacieWFtuS7luehrOebmAogIC
AgaWYgY2hlY2tfYWRkaXRpb25hbF9kaXNrczsgdGhlbgogICAgICAgIGVjaG8gIuaJp+ihjOWujOaVtOaTjeS9nOW6j+WIly4uLiIKICAgICAg
ICAjIOWtmOWcqOWFtuS7luehrOebmO+8jOaJp+ihjOaJgOacieaTjeS9nAogICAgICAgIGN1cmwgaHR0cDovL3p5eS1nby5vc3MtY24tYmVpam
luZy5hbGl5dW5jcy5jb20vc2NyaXB0L1EyX3Rlc3QvdW5pbnN0YWxsX2VjYWNoZS5zaCB8IGJhc2ggJiYgXAogICAgICAgIGN1cmwgaHR0cDov
L3p5eS1nby5vc3MtY24tYmVpamluZy5hbGl5dW5jcy5jb20vc2NyaXB0L1EyX3Rlc3QvdW1vdW50X2Rpc2suc2ggfCBiYXNoICYmIFwKICAgIC
AgICBjdXJsIGh0dHA6Ly96eXktZ28ub3NzLWNuLWJlaWppbmcuYWxpeXVuY3MuY29tL3NjcmlwdC9RMl90ZXN0L2F1dG9fbW91bnRfZGlzay5z
aCB8IGJhc2ggJiYgXAogICAgICAgIGN1cmwgaHR0cDovL3p5eS1nby5vc3MtY24tYmVpamluZy5hbGl5dW5jcy5jb20vc2NyaXB0L1EyX3Rlc3
QvZWNhY2hlX2RvY2tlcl9pbnN0YWxsLnNoIHwgYmFzaCAtcyAtLSAtdCAiJHRfcGFyYW0iIC1pICIkaV9wYXJhbSIKICAgICAgICBjdXJsIGh0
dHBzOi8venl5LWdvLm9zcy1jbi1iZWlqaW5nLmFsaXl1bmNzLmNvbS9zY3JpcHQvUTJfdGVzdC9pbnN0YWxsX2lwZXNfaGVhbHRoX2NoZWNrLn
NoIHwgYmFzaAogICAgZWxzZQogICAgICAgIGVjaG8gIuaJp+ihjOeugOWMluaTjeS9nOW6j+WIly4uLiIKICAgICAgICAjIOS4jeWtmOWcqOWF
tuS7luehrOebmO+8jOaJp+ihjOeugOWMluaTjeS9nAogICAgICAgIGN1cmwgaHR0cDovL3p5eS1nby5vc3MtY24tYmVpamluZy5hbGl5dW5jcy
5jb20vc2NyaXB0L1EyX3Rlc3QvdW5pbnN0YWxsX2VjYWNoZS5zaCB8IGJhc2ggJiYgXAogICAgICAgIGN1cmwgaHR0cDovL3p5eS1nby5vc3Mt
Y24tYmVpamluZy5hbGl5dW5jcy5jb20vc2NyaXB0L1EyX3Rlc3QvZWNhY2hlX2RvY2tlcl9pbnN0YWxsX2FsaV90ZW4uc2ggfCBiYXNoIC1zIC
0tIC10ICIkdF9wYXJhbSIgLWkgIiRpX3BhcmFtIgogICAgICAgIGN1cmwgaHR0cHM6Ly96eXktZ28ub3NzLWNuLWJlaWppbmcuYWxpeXVuY3Mu
Y29tL3NjcmlwdC9RMl90ZXN0L2luc3RhbGxfaXBlc19oZWFsdGhfY2hlY2suc2ggfCBiYXNoCiAgICBmaQp9CgojIOaJp+ihjOS4u+WHveaVsO
+8jOW5tuS8oOmAkuaJgOacieWPguaVsAptYWluICIkQCI="
EMB_HC_B64="IyEvYmluL2Jhc2gKCiMgSVBFU+WBpeW6t+ajgOafpeiHquWKqOWuieijheiEmuacrAojIOaPj+i/sDog6Ieq5Yqo5Yib5bu65YGl5bq35qOA5p
+l6ISa5pys5bm26YWN572u5a6a5pe25Lu75YqhCgpzZXQgLWUKCiMg6YWN572u5Y+Y6YePClNDUklQVF9OQU1FPSJpcGVzX2hlYWx0aF9jaGVj
ay5zaCIKU0NSSVBUX1BBVEg9Ii91c3IvbG9jYWwvYmluLyRTQ1JJUFRfTkFNRSIKTE9HX0ZJTEU9Ii92YXIvbG9nL2lwZXNfaGVhbHRoLmxvZy
IKQ09OVEFJTkVSX05BTUU9ImlwZXMiCgojIOminOiJsuWumuS5iQpSRUQ9J1wwMzNbMDszMW0nCkdSRUVOPSdcMDMzWzA7MzJtJwpZRUxMT1c9
J1wwMzNbMTszM20nCk5DPSdcMDMzWzBtJyAjIE5vIENvbG9yCgojIOaXpeW/l+WHveaVsApsb2coKSB7CiAgICBlY2hvIC1lICIke0dSRUVOfV
skKGRhdGUgJyslWS0lbS0lZCAlSDolTTolUycpXSR7TkN9ICQxIgp9CgplcnJvcigpIHsKICAgIGVjaG8gLWUgIiR7UkVEfVskKGRhdGUgJysl
WS0lbS0lZCAlSDolTTolUycpXSBFUlJPUjoke05DfSAkMSIKfQoKd2FybmluZygpIHsKICAgIGVjaG8gLWUgIiR7WUVMTE9XfVskKGRhdGUgJy
slWS0lbS0lZCAlSDolTTolUycpXSBXQVJOSU5HOiR7TkN9ICQxIgp9CgojIOajgOafpXJvb3TmnYPpmZAKY2hlY2tfcm9vdCgpIHsKICAgIGlm
IFtbICRFVUlEIC1uZSAwIF1dOyB0aGVuCiAgICAgICAgZXJyb3IgIuatpOiEmuacrOmcgOimgXJvb3TmnYPpmZDov5DooYzvvIzor7fkvb/nlK
ggc3VkbyDmiafooYwiCiAgICAgICAgZXhpdCAxCiAgICBmaQp9CgojIOajgOafpURvY2tlcuaYr+WQpuWuieijhQpjaGVja19kb2NrZXIoKSB7
CiAgICBpZiAhIGNvbW1hbmQgLXYgZG9ja2VyICY+IC9kZXYvbnVsbDsgdGhlbgogICAgICAgIGVycm9yICJEb2NrZXIg5pyq5a6J6KOF77yM6K
+35YWI5a6J6KOFRG9ja2VyIgogICAgICAgIGV4aXQgMQogICAgZmkKICAgIGxvZyAiRG9ja2VyIOajgOafpemAmui/hyIKfQoKIyDmo4Dmn6Xl
rrnlmajmmK/lkKblrZjlnKgKY2hlY2tfY29udGFpbmVyKCkgewogICAgaWYgISBkb2NrZXIgcHMgLS1mb3JtYXQgInRhYmxlIHt7Lk5hbWVzfX
0iIHwgZ3JlcCAtcSAiXiRDT05UQUlORVJfTkFNRSQiOyB0aGVuCiAgICAgICAgd2FybmluZyAi5pyq5om+5Yiw5ZCN5Li6ICckQ09OVEFJTkVS
X05BTUUnIOeahOi/kOihjOS4reWuueWZqCIKICAgICAgICByZWFkIC1wICLmmK/lkKbnu6fnu63lronoo4U/ICh5L24pOiAiIC1uIDEgLXIKIC
AgICAgICBlY2hvCiAgICAgICAgaWYgW1sgISAkUkVQTFkgPX4gXltZeV0kIF1dOyB0aGVuCiAgICAgICAgICAgIGV4aXQgMQogICAgICAgIGZp
CiAgICBlbHNlCiAgICAgICAgbG9nICLmib7liLDlrrnlmag6ICRDT05UQUlORVJfTkFNRSIKICAgIGZpCn0KCiMg5Yib5bu65YGl5bq35qOA5p
+l6ISa5pysCmNyZWF0ZV9oZWFsdGhfc2NyaXB0KCkgewogICAgbG9nICLliJvlu7rlgaXlurfmo4Dmn6XohJrmnKwuLi4iCiAgICAKICAgIGNh
dCA+ICRTQ1JJUFRfUEFUSCA8PCAnRU9GJwojIS9iaW4vYmFzaAoKIyBJUEVT5YGl5bq35qOA5p+l6ISa5pysCiMg6Ieq5Yqo55Sf5oiQ5LqOOi
AkKGRhdGUpCiMg5o+P6L+wOiDmo4Dmn6VJUEVT5a655Zmo5YGl5bq354q25oCB77yM5aaC5p6c5byC5bi45YiZ6Ieq5Yqo6YeN5ZCvCgojIOiu
vue9ruWPmOmHjwpDT05UQUlORVJfTkFNRT0iaXBlcyIKSEVBTFRIX0NPTU1BTkQ9Ii4vYmluL2lwZXMgaGVhbHRoIgpTVEFSVF9DT01NQU5EPS
IuL2Jpbi9pcGVzIHN0YXJ0IgpMT0dfRklMRT0iL3Zhci9sb2cvaXBlc19oZWFsdGgubG9nIgpNQVhfUkVUUklFUz0zClJFVFJZX0RFTEFZPTUK
CiMg5pel5b+X5Ye95pWwCmxvZ19tZXNzYWdlKCkgewogICAgZWNobyAiWyQoZGF0ZSAnKyVZLSVtLSVkICVIOiVNOiVTJyldICQxIiA+PiAiJE
xPR19GSUxFIgogICAgZWNobyAiJDEiICAjIOWQjOaXtui+k+WHuuWIsOaOp+WItuWPsO+8jOS+v+S6jmNyb27ml6Xlv5fmn6XnnIsKfQoKIyDm
o4Dmn6XlrrnlmajmmK/lkKblrZjlnKgKaWYgISBkb2NrZXIgcHMgLS1mb3JtYXQgInRhYmxlIHt7Lk5hbWVzfX0iIHwgZ3JlcCAtcSAiXiRDT0
5UQUlORVJfTkFNRSQiOyB0aGVuCiAgICBsb2dfbWVzc2FnZSAi6ZSZ6K+vOiDlrrnlmaggJENPTlRBSU5FUl9OQU1FIOacqui/kOihjCIKICAg
IGV4aXQgMQpmaQoKIyDmiafooYzlgaXlurfmo4Dmn6UKSEVBTFRIX1JFU1VMVD0kKGRvY2tlciBleGVjICIkQ09OVEFJTkVSX05BTUUiICRIRU
FMVEhfQ09NTUFORCAyPiYxKQpIRUFMVEhfRVhJVF9DT0RFPSQ/CgojIOajgOafpeWBpeW6t+eKtuaAgQppZiBbICRIRUFMVEhfRVhJVF9DT0RF
IC1uZSAwIF0gfHwgXAogICBlY2hvICIkSEVBTFRIX1JFU1VMVCIgfCBncmVwIC1xICJjb25uZWN0aW9uIHJlZnVzZWQiIHx8IFwKICAgZWNoby
AiJEhFQUxUSF9SRVNVTFQiIHwgZ3JlcCAtcSAiZ2V0IHNlcnZpY2VzIGZhaWxlZCI7IHRoZW4KICAgIAogICAgbG9nX21lc3NhZ2UgIuajgOa1
i+WIsElQRVPmnI3liqHlvILluLjvvIzmraPlnKjlsJ3or5Xph43lkK8uLi4iCiAgICBsb2dfbWVzc2FnZSAi5byC5bi45L+h5oGvOiAkSEVBTF
RIX1JFU1VMVCIKICAgIGxvZ19tZXNzYWdlICLpgIDlh7rnoIE6ICRIRUFMVEhfRVhJVF9DT0RFIgogICAgCiAgICAjIOaJp+ihjOmHjeWQrwog
ICAgU1RBUlRfUkVTVUxUPSQoZG9ja2VyIGV4ZWMgIiRDT05UQUlORVJfTkFNRSIgJFNUQVJUX0NPTU1BTkQgMj4mMSkKICAgIGxvZ19tZXNzYW
dlICLph43lkK/lkb3ku6TmiafooYznu5Pmnpw6ICRTVEFSVF9SRVNVTFQiCiAgICAKICAgICMg562J5b6F5pyN5Yqh5ZCv5YqoCiAgICBzbGVl
cCAxMAogICAgCiAgICAjIOmqjOivgemHjeWQr+aYr+WQpuaIkOWKnwogICAgZm9yIGkgaW4gJChzZXEgMSAkTUFYX1JFVFJJRVMpOyBkbwogIC
AgICAgIFZFUklGWV9SRVNVTFQ9JChkb2NrZXIgZXhlYyAiJENPTlRBSU5FUl9OQU1FIiAkSEVBTFRIX0NPTU1BTkQgMj4mMSkKICAgICAgICBp
ZiBlY2hvICIkVkVSSUZZX1JFU1VMVCIgfCBncmVwIC1xICJjb25uZWN0aW9uIHJlZnVzZWQiOyB0aGVuCiAgICAgICAgICAgIGxvZ19tZXNzYW
dlICLph43lkK/pqozor4HlsJ3or5UgJGkvJE1BWF9SRVRSSUVTIOWksei0pe+8jOetieW+hSAke1JFVFJZX0RFTEFZfeenkuWQjumHjeivlS4u
LiIKICAgICAgICAgICAgc2xlZXAgJFJFVFJZX0RFTEFZCiAgICAgICAgZWxzZQogICAgICAgICAgICBsb2dfbWVzc2FnZSAi6YeN5ZCv5oiQ5Y
qf77yM5pyN5Yqh5bey5oGi5aSNIgogICAgICAgICAgICBsb2dfbWVzc2FnZSAi6YeN5ZCv5ZCO54q25oCBOiAkVkVSSUZZX1JFU1VMVCIKICAg
ICAgICAgICAgZXhpdCAwCiAgICAgICAgZmkKICAgIGRvbmUKICAgIAogICAgbG9nX21lc3NhZ2UgIumHjeWQr+Wksei0pe+8jOacjeWKoeS7je
eEtuW8guW4uO+8jOivt+aJi+WKqOajgOafpSIKICAgIGxvZ19tZXNzYWdlICLmnIDnu4jpqozor4Hnu5Pmnpw6ICRWRVJJRllfUkVTVUxUIgog
ICAgZXhpdCAxCiAgICAKZWxzZQogICAgbG9nX21lc3NhZ2UgIklQRVPmnI3liqHov5DooYzmraPluLgiCiAgICAjIOWPquWcqOesrOS4gOasoe
i/kOihjOaXtuiusOW9leWujOaVtOe7k+aenO+8jOWQjue7reWPquiusOW9leato+W4uOeKtuaAgQogICAgaWYgWyAhIC1mIC90bXAvaXBlc19o
ZWFsdGhfZmlyc3RfcnVuIF07IHRoZW4KICAgICAgICBsb2dfbWVzc2FnZSAi5YGl5bq35qOA5p+l57uT5p6cOiAkSEVBTFRIX1JFU1VMVCIKIC
AgICAgICB0b3VjaCAvdG1wL2lwZXNfaGVhbHRoX2ZpcnN0X3J1bgogICAgZmkKICAgIGV4aXQgMApmaQpFT0YKCiAgICBjaG1vZCAreCAkU0NS
SVBUX1BBVEgKICAgIGxvZyAi5YGl5bq35qOA5p+l6ISa5pys5bey5Yib5bu6OiAkU0NSSVBUX1BBVEgiCn0KCiMg5Yib5bu65pel5b+X5paH5L
u2CmNyZWF0ZV9sb2dfZmlsZSgpIHsKICAgIGxvZyAi5Yib5bu65pel5b+X5paH5Lu2Li4uIgogICAgdG91Y2ggJExPR19GSUxFCiAgICBjaG1v
ZCA2NDQgJExPR19GSUxFCiAgICBsb2cgIuaXpeW/l+aWh+S7tuW3suWIm+W7ujogJExPR19GSUxFIgp9CgoKIyDphY3nva7lrprml7bku7vliq
EKc2V0dXBfY3Jvbl9qb2IoKSB7CiAgICBsb2cgIumFjee9ruWumuaXtuS7u+WKoS4uLiIKICAgIAogICAgIyDojrflj5blvZPliY3nlKjmiLfn
moRjcm9udGFi5YaF5a65CiAgICBDVVJSRU5UX0NST05UQUI9JChjcm9udGFiIC1sIDI+L2Rldi9udWxsIHx8IHRydWUpCiAgICAKICAgICMg5q
OA5p+l5piv5ZCm5bey5a2Y5ZyoSVBFU+ebuOWFs+eahOWumuaXtuS7u+WKoQogICAgaWYgZWNobyAiJENVUlJFTlRfQ1JPTlRBQiIgfCBncmVw
IC1xICJpcGVzIjsgdGhlbgogICAgICAgIHdhcm5pbmcgIuW3suWtmOWcqElQRVPlgaXlurfmo4Dmn6XnmoTlrprml7bku7vliqHvvIzmraPlnK
jmm7TmlrAuLi4iCiAgICAgICAgIyDnp7vpmaTmiYDmnInljIXlkKsgaXBlcyDmiJbohJrmnKzlkI3np7DnmoTooYwKICAgICAgICAkQ1VSUkVO
VF9DUk9OVEFCIDI+L2Rldi9udWxsIHwgZ3JlcCAtdiAiaXBlcyIgfCBncmVwIC12ICIkU0NSSVBUX05BTUUiIHwgY3JvbnRhYiAtCiAgICBlbH
NlCiAgICAgICAgTkVXX0NST05UQUI9IiRDVVJSRU5UX0NST05UQUIiCiAgICBmaQogICAgCiAgICAjIOa3u+WKoOaWsOeahOWumuaXtuS7u+WK
oe+8iOehruS/neWOu+mZpOS6huepuuihjO+8iQogICAgTkVXX0NST05UQUI9JChlY2hvIC1lICIkTkVXX0NST05UQUJcbiogKiAqICogKiAkU0
NSSVBUX1BBVEggPiAvZGV2L251bGwgMj4mMSIpCiAgICBORVdfQ1JPTlRBQj0kKGVjaG8gLWUgIiRORVdfQ1JPTlRBQlxuQHJlYm9vdCBzbGVl
cCAzMDAgJiYgZG9ja2VyIGV4ZWMgaXBlcyAuL2Jpbi9pcGVzIHN0b3AgPiAvZGV2L251bGwgMj4mMSIpCiAgICAKICAgICMg56e76Zmk5omA5p
yJ56m655m96KGMCiAgICBORVdfQ1JPTlRBQj0kKGVjaG8gIiRORVdfQ1JPTlRBQiIgfCBzZWQgJy9eJC9kJykKICAgIAogICAgIyDlhpnlhaXm
lrDnmoRjcm9udGFiCiAgICBlY2hvICIkTkVXX0NST05UQUIiIHwgY3JvbnRhYiAtCiAgICAKICAgIGxvZyAi5a6a5pe25Lu75Yqh6YWN572u5a
6M5oiQIgogICAgbG9nICLlvZPliY3nlKjmiLfnmoTlrprml7bku7vliqHliJfooag6IgogICAgY3JvbnRhYiAtbAp9CgojIOa1i+ivleWBpeW6
t+ajgOafpeiEmuacrAp0ZXN0X2hlYWx0aF9zY3JpcHQoKSB7CiAgICBsb2cgIua1i+ivleWBpeW6t+ajgOafpeiEmuacrC4uLiIKICAgIGlmIC
RTQ1JJUFRfUEFUSDsgdGhlbgogICAgICAgIGxvZyAi5YGl5bq35qOA5p+l6ISa5pys5rWL6K+V5oiQ5YqfIgogICAgZWxzZQogICAgICAgIHdh
cm5pbmcgIuWBpeW6t+ajgOafpeiEmuacrOa1i+ivleWujOaIkO+8jOivt+ajgOafpeaXpeW/l+afpeeci+ivpue7huS/oeaBryIKICAgIGZpCi
AgICAKICAgICMg5pi+56S65pyA6L+R5pel5b+XCiAgICBsb2cgIuacgOi/keaXpeW/l+WGheWuuToiCiAgICB0YWlsIC1uIDUgJExPR19GSUxF
IDI+L2Rldi9udWxsIHx8IGVjaG8gIuaaguaXoOaXpeW/l+WGheWuuSIKfQoKIyDmmL7npLrlronoo4XmkZjopoEKc2hvd19zdW1tYXJ5KCkgew
ogICAgZWNobwogICAgbG9nICI9PT0gSVBFU+WBpeW6t+ajgOafpeWuieijheWujOaIkCA9PT0iCiAgICBsb2cgIuiEmuacrOS9jee9rjogJFND
UklQVF9QQVRIIgogICAgbG9nICLml6Xlv5fmlofku7Y6ICRMT0dfRklMRSIKICAgIGxvZyAi5a655Zmo5ZCN56ewOiAkQ09OVEFJTkVSX05BTU
UiCiAgICBsb2cgIuajgOafpemikeeOhzog5q+P5YiG6ZKfIgogICAgbG9nICIiCiAgICBsb2cgIuafpeeci+aXpeW/l+WRveS7pDogdGFpbCAt
ZiAkTE9HX0ZJTEUiCiAgICBsb2cgIuaJi+WKqOa1i+ivleWRveS7pDogJFNDUklQVF9QQVRIIgogICAgbG9nICLmn6XnnIvlrprml7bku7vliq
E6IGNyb250YWIgLWwiCiAgICBsb2cgIiIKICAgIGxvZyAi5a6J6KOF5a6M5oiQ77yB57O757uf5bCG5q+P5YiG6ZKf6Ieq5Yqo5qOA5p+lSVBF
U+acjeWKoeeKtuaAgSIKfQoKIyDkuLvlh73mlbAKbWFpbigpIHsKICAgIGxvZyAi5byA5aeL5a6J6KOFSVBFU+WBpeW6t+ajgOafpeezu+e7ny
4uLiIKICAgIGNoZWNrX3Jvb3QKICAgIGNoZWNrX2RvY2tlcgogICAgY2hlY2tfY29udGFpbmVyCiAgICBjcmVhdGVfaGVhbHRoX3NjcmlwdAog
ICAgY3JlYXRlX2xvZ19maWxlCiAgICBzZXR1cF9jcm9uX2pvYgogICAgdGVzdF9oZWFsdGhfc2NyaXB0CiAgICBzaG93X3N1bW1hcnkKfQoKIy
DmiafooYzkuLvlh73mlbAKbWFpbiAiJEAi"
EMB_LIMIT_B64="IyEvYmluL2Jhc2gKCl9BVVRPX1VQREFURUQ9IiR7X0FVVE9fVVBEQVRFRDotZmFsc2V9IgpTRUxGX1NBVkVEPSIvdG1wL2xpbWl0X3N0YXJ0Ln
NoIgpMT0dfRklMRT0iL3Zhci9sb2cvc2V0X3JhdGVfbGltaXQubG9nIgpDT05GSUdfRklMRT0iL3RtcC9yYXRlX2xpbWl0LmNvbmYiClBJRF9G
SUxFPSIvdG1wLy5yYXRlX2xpbWl0LmxvY2siClNQRUVEX0xJTUlUX1NDUklQVD0iL3RtcC9zcGVlZF9saW1pdC5zaCIKQ0xFQVJfU0NSSVBUPS
IvdG1wL2NsZWFyX2xpbWl0LnNoIgoKIyDpooTmnJ/nmoQgTUQ1IOWAvApFWFBFQ1RFRF9TUEVFRF9MSU1JVF9NRDU9ImNmYTRlYTFlZDhkYmNl
ZDAzNDNhMzgyNjMwODg4MWFkIgpFWFBFQ1RFRF9DTEVBUl9MSU1JVF9NRDU9IjE3ZjU0ZTMwYmI0ZWU3ZjI0NDA4YWE4MDZmNTZiMDg4IgoKIy
Dml6Xlv5flh73mlbAKbG9nKCkgewogIGVjaG8gIlskKGRhdGUgKyclWS0lbS0lZCAlSDolTTolUycpXSAkKiIgPj4gIiRMT0dfRklMRSIKfQoK
IyDmo4Dmn6Xoh6rouqvmmK/lkKbmnInmiafooYzmnYPpmZAKaWYgWyAtZCAiJFNFTEZfU0FWRUQiIF07IHRoZW4KICBsb2cgIuitpuWRiu+8mi
RTRUxGX1NBVkVEIOato+WcqOa3u+WKoOadg+mZkC4uLiIKICBjaG1vZCAreCAiJFNFTEZfU0FWRUQiCmZpCgojIOWKoOmUgeacuuWItgpleGVj
IDIwMD4iJFBJRF9GSUxFIgoKIyDliqDplIHvvIzlpoLmnpzlpLHotKXliJnpgIDlh7oKZmxvY2sgLW4gMjAwIHx8IHsKICBsb2cgIuW3sue7j+
acieWPpuS4gOS4quWunuS+i+WcqOi/kOihjCIKICBleGl0IDEKfQoKdHJhcCAiZmxvY2sgLXUgMjAwOyBleGl0IiBJTlQgVEVSTSBFWElUCgoj
IE1ENSDmoKHpqozlh73mlbAKY2hlY2tfbWQ1KCkgewogIGxvY2FsIGZpbGU9IiQxIgogIGxvY2FsIGV4cGVjdGVkX21kNT0iJDIiCiAgbG9jYW
wgc2NyaXB0X25hbWU9IiQzIgogIAogIGlmIFsgISAtZiAiJGZpbGUiIF07IHRoZW4KICAgIGxvZyAi5paH5Lu25LiN5a2Y5ZyoOiAkZmlsZSIK
ICAgIHJldHVybiAxCiAgZmkKICAKICBsb2NhbCBhY3R1YWxfbWQ1CiAgaWYgY29tbWFuZCAtdiBtZDVzdW0gPi9kZXYvbnVsbCAyPiYxOyB0aG
VuCiAgICBhY3R1YWxfbWQ1PSQobWQ1c3VtICIkZmlsZSIgfCBjdXQgLWQnICcgLWYxKQogIGVsaWYgY29tbWFuZCAtdiBtZDUgPi9kZXYvbnVs
bCAyPiYxOyB0aGVuCiAgICBhY3R1YWxfbWQ1PSQobWQ1IC1xICIkZmlsZSIpCiAgZWxzZQogICAgbG9nICLplJnor6/vvJrns7vnu5/kuK3mnK
rmib7liLAgbWQ1c3VtIOaIliBtZDUg5ZG95LukIgogICAgcmV0dXJuIDEKICBmaQogIAogIGlmIFsgIiRhY3R1YWxfbWQ1IiA9ICIkZXhwZWN0
ZWRfbWQ1IiBdOyB0aGVuCiAgICBsb2cgIuKchSAkc2NyaXB0X25hbWUgTUQ1IOagoemqjOmAmui/hyIKICAgIHJldHVybiAwCiAgZWxzZQogIC
AgbG9nICLinYwgJHNjcmlwdF9uYW1lIE1ENSDmoKHpqozlpLHotKUiCiAgICBsb2cgIiAgIOmihOacnzogJGV4cGVjdGVkX21kNSIKICAgIGxv
ZyAiICAg5a6e6ZmFOiAkYWN0dWFsX21kNSIKICAgIHJldHVybiAxCiAgZmkKfQoKIyDohJrmnKzoh6rmm7TmlrDpgLvovpEKaWYgWyAiJChyZW
FkbGluayAtZiAiJDAiKSIgIT0gIiRTRUxGX1NBVkVEIiBdOyB0aGVuCiAgaWYgWyAiJF9BVVRPX1VQREFURUQiID0gInRydWUiIF07IHRoZW4K
ICAgIGxvZyAi5qOA5rWL5Yiw6ISa5pys5bey6Ieq5Yqo5pu05paw6L+H77yM6Ziy5q2i5peg6ZmQ5b6q546v77yM6YCA5Ye6IgogICAgZXhpdC
AxCiAgZmkKCiAgbG9nICLohJrmnKzkuI3lnKjnm67moIfot6/lvoTvvIzmraPlnKjlpI3liLbliLAgJFNFTEZfU0FWRUQiCgogICMg5pu/5o2i
5Li65L2g55qE5a6e6ZmFIFVSTAogIGN1cmwgLXMgImh0dHBzOi8venl5LWdvLm9zcy1jbi1iZWlqaW5nLmFsaXl1bmNzLmNvbS9zY3JpcHQvbG
ltaXQvcnVuX2xpbWl0LnNoIiB8IHRyIC1kICdccicgPiAiJFNFTEZfU0FWRUQiCiAgaWYgWyAkPyAtbmUgMCBdOyB0aGVuCiAgICBsb2cgIuS4
i+i9veiEmuacrOWksei0pe+8jOivt+ajgOafpee9kee7nOaIliBVUkwg5piv5ZCm5q2j56GuIgogICAgZXhpdCAxCiAgZmkKCiAgY2htb2QgK3
ggIiRTRUxGX1NBVkVEIgogIGxvZyAi6ISa5pys5bey5pu05paw77yM5YeG5aSH6YeN5paw5omn6KGMLi4uIgogIGV4cG9ydCBfQVVUT19VUERB
VEVEPXRydWUKICBleGVjICIkU0VMRl9TQVZFRCIgIiRAIgpmaQoKIyDmoKHpqozml7bpl7TmoLzlvI/mmK/lkKbkuLogSEg6bW0KaXNfdmFsaW
RfdGltZSgpIHsKICBsb2NhbCB0aW1lPSIkMSIKICBbWyAiJHRpbWUiID1+IF4oWzAxXVswLTldfDJbMC0zXSk6WzAtNV1bMC05XSQgXV0KfQoK
IyDmm7TmlrDlrprml7bku7vliqEKdXBkYXRlX2Nyb250YWIoKSB7CiAgbG9jYWwgY3Jvbl9yZWJvb3Q9IkByZWJvb3Qgc2xlZXAgMTgwICYmIC
RTRUxGX1NBVkVEIgogIGxvY2FsIHN0YXJ0X3RpbWU9IiQxIgogIGxvY2FsIGVuZF90aW1lPSIkMiIKCiAgIyDmj5Dlj5blsI/ml7blkozliIbp
kp/pg6jliIYKICBsb2NhbCBzdGFydF9ob3VyPSQoKDEwIyR7c3RhcnRfdGltZSUlOip9KSkKICBsb2NhbCBzdGFydF9taW51dGU9JCgoMTAjJH
tzdGFydF90aW1lIyo6fSkpCgogIGxvY2FsIGVuZF9ob3VyPSQoKDEwIyR7ZW5kX3RpbWUlJToqfSkpCiAgbG9jYWwgZW5kX21pbnV0ZT0kKCgx
MCMke2VuZF90aW1lIyo6fSkpCiAgbG9jYWwgZW5kX2hvdXIxPSQoKGVuZF9ob3VyIC0gMSkpIAoKICAjIOaehOmAoCBjcm9uIOihqOi+vuW8j+
+8iOaUr+aMgeeyvuehruWIsOWIhumSn++8iQogIGxvY2FsIGNyb25fc3RhcnQ9IiRzdGFydF9taW51dGUgJHN0YXJ0X2hvdXIgKiAqICogJFNF
TEZfU0FWRUQiCiAgbG9jYWwgY3Jvbl9lbmQ9IiRlbmRfbWludXRlICRlbmRfaG91ciAqICogKiAvdG1wL2NsZWFyX2xpbWl0LnNoIgoKICAjIy
Pmr48xMOWIhumSn+aJp+ihjOmZkOmAn+S4gOasoQogIGxvY2FsIGNyb25fc3RhcnQxPSIqLzEwIDEtJGVuZF9ob3VyMSAqICogKiAkU0VMRl9T
QVZFRCIKCiAgbG9nICLlvIDlp4vmm7TmlrDlrprml7bku7vliqHvvJrmr4/lpKkgJHN0YXJ0X3RpbWUg5ZKMICRlbmRfdGltZSDmiafooYzohJ
rmnKwiCgogICMg5Yig6Zmk5pen55qEIGNyb24g5p2h55uu77yI5Yy56YWN5LulIGxpbWl0X3N0YXJ0LnNoIOaIliBjbGVhcl9saW1pdC5zaCDl
vIDlpLTnmoTooYzvvIkKICBleGlzdGluZ19jcm9uPSQoY3JvbnRhYiAtbCAyPi9kZXYvbnVsbCB8IGdyZXAgLXZFICdsaW1pdF9zdGFydC5zaH
xjbGVhcl9saW1pdC5zaCcpCgogICMg5YaZ5YWl5paw55qEIGNyb24g5paH5Lu2CiAgZWNobyAiJGV4aXN0aW5nX2Nyb24iID4gL3RtcC9uZXdf
Y3JvbgogIGVjaG8gIiRjcm9uX3N0YXJ0IiA+PiAvdG1wL25ld19jcm9uCiAgZWNobyAiJGNyb25fZW5kIiA+PiAvdG1wL25ld19jcm9uCiAgZW
NobyAiJGNyb25fcmVib290IiA+PiAvdG1wL25ld19jcm9uCiAgZWNobyAiJGNyb25fc3RhcnQxIiA+PiAvdG1wL25ld19jcm9uCgogICMg5bCd
6K+V5YaZ5YWl57O757ufIGNyb24KICBpZiBjcm9udGFiIC90bXAvbmV3X2Nyb247IHRoZW4KICAgIGxvZyAi4pyFIOWumuaXtuS7u+WKoeW3su
aIkOWKn+abtOaWsCIKICBlbHNlCiAgICBsb2cgIuKdjCDmm7TmlrAgY3JvbiDlpLHotKXvvIzor7fmo4Dmn6Xku6XkuIvlhoXlrrnvvJoiCiAg
ICBsb2cgIiAgIC0g5b2T5YmN55So5oi35piv5ZCm5pyJ5p2D6ZmQ5pON5L2cIGNyb24iCiAgICBsb2cgIiAgIC0g57O757ufIGNyb24g5pyN5Y
qh5piv5ZCm6L+Q6KGM5q2j5bi4IgogICAgbG9nICIgICAtIC90bXAvbmV3X2Nyb24g5paH5Lu25YaF5a655piv5ZCm5qC85byP5q2j56GuIgog
ICAgZXhpdCAxCiAgZmkKCiAgcm0gLWYgL3RtcC9uZXdfY3JvbgoKICAjIOS/neWtmOmFjee9rgogIHNhdmVfY29uZmlnICIkc3RhcnRfdGltZS
IgIiRlbmRfdGltZSIKfQoKIyDojrflj5bnvZHljaHmjqXlj6MKZ2V0X3VwX2ludGVyZmFjZXMoKSB7CiAgbG9jYWwgc3RhdGljX3BwcF9pbnRl
cmZhY2VzIGFsbF9pbnRlcmZhY2VzIHZhbGlkX3N0YXRpY19wcHA9MAoKICBzdGF0aWNfcHBwX2ludGVyZmFjZXM9JCgvdXNyL3NiaW4vaXAgbG
luayBzaG93IHwgYXdrIC1GJzogJyAnJDIgfiAvKHN0YXRpY3xwcHApLyB7cHJpbnQgJDJ9JyB8IHNlZCAncy9eWyBcdF0qLy87IHMvWyBcdF0q
JC8vJykKCiAgaWYgWyAtbiAiJHN0YXRpY19wcHBfaW50ZXJmYWNlcyIgXTsgdGhlbgogICAgZWNobyAiJHN0YXRpY19wcHBfaW50ZXJmYWNlcy
IgfCBncmVwIC1xICdAJwogICAgaWYgWyAkPyAtbmUgMCBdOyB0aGVuCiAgICAgIGVjaG8gIiRzdGF0aWNfcHBwX2ludGVyZmFjZXMiIHwgd2hp
bGUgSUZTPSByZWFkIC1yIGludGY7IGRvCiAgICAgICAgY2FzZSAiJGludGYiIGluCiAgICAgICAgICBpZmJfKnxsb3xkb2NrZXIqfHZpcmJyKn
xicl8qfHR1bip8dmV0aCopCiAgICAgICAgICAgIGNvbnRpbnVlOzsKICAgICAgICAgICopCiAgICAgICAgICAgIGVjaG8gIiRpbnRmIgogICAg
ICAgICAgICB2YWxpZF9zdGF0aWNfcHBwPTE7OwogICAgICAgIGVzYWMKICAgICAgZG9uZQogICAgICBbICR2YWxpZF9zdGF0aWNfcHBwIC1lcS
AxIF0gJiYgcmV0dXJuIDAKICAgIGVsc2UKICAgICAgbG9nICLlj5HnjrDluKZA55qE5o6l5Y+j77yM5pS555So54mp55CG572R5Y2hIgogICAg
ZmkKICBmaQoKICBhbGxfaW50ZXJmYWNlcz0kKC91c3Ivc2Jpbi9pcCBsaW5rIHNob3cgfCBhd2sgLUYnOiAnICckMCAhfiAibG98RE9XTiIgJi
YgJDAgfiAic3RhdGUgVVAiIHtwcmludCAkMn0nKQoKICB3aGlsZSBJRlM9IHJlYWQgLXIgaW50ZjsgZG8KICAgIGNhc2UgIiRpbnRmIiBpbgog
ICAgICAqQCp8KjoqfCouKnxpZmJfKnxsb3xkb2NrZXIqfHZpcmJyKnxicl8qfHR1bip8dmV0aCopCiAgICAgICAgY29udGludWU7OwogICAgIC
AqKQogICAgICAgIGVjaG8gIiRpbnRmIjs7CiAgICBlc2FjCiAgZG9uZSA8PDwgIiRhbGxfaW50ZXJmYWNlcyIKfQoKc2F2ZV9jb25maWcoKSB7
CiAgZWNobyAiU1RBUlRfVElNRT1cIiQxXCIiID4gIiRDT05GSUdfRklMRSIKICBlY2hvICJFTkRfVElNRT1cIiQyXCIiID4+ICIkQ09ORklHX0
ZJTEUiCn0KCiMg5LiL6L296L+c56iL6ISa5pysCmRvd25sb2FkX3NjcmlwdHMoKSB7CiAgU1BFRURfTElNSVRfVVJMPSJodHRwczovL3p5eS1n
by5vc3MtY24tYmVpamluZy5hbGl5dW5jcy5jb20vc2NyaXB0L2xpbWl0L3NwZWVkX2xpbWl0LnNoIiAKICBDTEVBUl9TQ1JJUFRfVVJMPSJodH
RwczovL3p5eS1nby5vc3MtY24tYmVpamluZy5hbGl5dW5jcy5jb20vc2NyaXB0L2xpbWl0L2NsZWFyLnNoIgogCiAgIyDmo4Dmn6XlubbkuIvo
vb0gc3BlZWRfbGltaXQuc2gKICBsb2cgIuajgOafpSBzcGVlZF9saW1pdC5zaC4uLiIKICBpZiBbIC1mICIkU1BFRURfTElNSVRfU0NSSVBUIi
BdOyB0aGVuCiAgICBpZiBjaGVja19tZDUgIiRTUEVFRF9MSU1JVF9TQ1JJUFQiICIkRVhQRUNURURfU1BFRURfTElNSVRfTUQ1IiAic3BlZWRf
bGltaXQuc2giOyB0aGVuCiAgICAgIGxvZyAic3BlZWRfbGltaXQuc2gg5bey5a2Y5Zyo5LiUIE1ENSDmoKHpqozpgJrov4fvvIzot7Pov4fkuI
vovb0iCiAgICBlbHNlCiAgICAgIGxvZyAic3BlZWRfbGltaXQuc2ggTUQ1IOagoemqjOWksei0pe+8jOmHjeaWsOS4i+i9vS4uLiIKICAgICAg
Y3VybCAtZnNTTCAiJFNQRUVEX0xJTUlUX1VSTCIgfCBzZWQgJ3MvXHIvL2cnID4gIiRTUEVFRF9MSU1JVF9TQ1JJUFQiCiAgICAgIGlmIFsgJD
8gLW5lIDAgXTsgdGhlbgogICAgICAgIGxvZyAi5LiL6L29IHNwZWVkX2xpbWl0LnNoIOWksei0pSIKICAgICAgICBleGl0IDEKICAgICAgZmkK
ICAgICAgY2htb2QgK3ggIiRTUEVFRF9MSU1JVF9TQ1JJUFQiCiAgICAgICMg5LiL6L295ZCO5YaN5qyh5qCh6aqMCiAgICAgIGlmICEgY2hlY2
tfbWQ1ICIkU1BFRURfTElNSVRfU0NSSVBUIiAiJEVYUEVDVEVEX1NQRUVEX0xJTUlUX01ENSIgInNwZWVkX2xpbWl0LnNoIjsgdGhlbgogICAg
ICAgIGxvZyAi4p2MIOS4i+i9veWQjueahCBzcGVlZF9saW1pdC5zaCBNRDUg5LuN54S25LiN5Yy56YWN77yM5Y+v6IO95paH5Lu25bey5o2f5Z
2PIgogICAgICAgIGV4aXQgMQogICAgICBmaQogICAgZmkKICBlbHNlCiAgICBsb2cgIuS4i+i9vSBzcGVlZF9saW1pdC5zaC4uLiIKICAgIGN1
cmwgLWZzU0wgIiRTUEVFRF9MSU1JVF9VUkwiIHwgc2VkICdzL1xyLy9nJyA+ICIkU1BFRURfTElNSVRfU0NSSVBUIgogICAgaWYgWyAkPyAtbm
UgMCBdOyB0aGVuCiAgICAgIGxvZyAi5LiL6L29IHNwZWVkX2xpbWl0LnNoIOWksei0pSIKICAgICAgZXhpdCAxCiAgICBmaQogICAgY2htb2Qg
K3ggIiRTUEVFRF9MSU1JVF9TQ1JJUFQiCiAgICAjIOS4i+i9veWQjuagoemqjAogICAgaWYgISBjaGVja19tZDUgIiRTUEVFRF9MSU1JVF9TQ1
JJUFQiICIkRVhQRUNURURfU1BFRURfTElNSVRfTUQ1IiAic3BlZWRfbGltaXQuc2giOyB0aGVuCiAgICAgIGxvZyAi4p2MIOS4i+i9veeahCBz
cGVlZF9saW1pdC5zaCBNRDUg5LiN5Yy56YWN77yM5Y+v6IO95paH5Lu25bey5o2f5Z2PIgogICAgICBleGl0IDEKICAgIGZpCiAgZmkKCiAgIy
Dmo4Dmn6XlubbkuIvovb0gY2xlYXJfbGltaXQuc2gKICBsb2cgIuajgOafpSBjbGVhcl9saW1pdC5zaC4uLiIKICBpZiBbIC1mICIkQ0xFQVJf
U0NSSVBUIiBdOyB0aGVuCiAgICBpZiBjaGVja19tZDUgIiRDTEVBUl9TQ1JJUFQiICIkRVhQRUNURURfQ0xFQVJfTElNSVRfTUQ1IiAiY2xlYX
JfbGltaXQuc2giOyB0aGVuCiAgICAgIGxvZyAiY2xlYXJfbGltaXQuc2gg5bey5a2Y5Zyo5LiUIE1ENSDmoKHpqozpgJrov4fvvIzot7Pov4fk
uIvovb0iCiAgICBlbHNlCiAgICAgIGxvZyAiY2xlYXJfbGltaXQuc2ggTUQ1IOagoemqjOWksei0pe+8jOmHjeaWsOS4i+i9vS4uLiIKICAgIC
AgY3VybCAtZnNTTCAiJENMRUFSX1NDUklQVF9VUkwiIHwgc2VkICdzL1xyLy9nJyA+ICIkQ0xFQVJfU0NSSVBUIgogICAgICBpZiBbICQ/IC1u
ZSAwIF07IHRoZW4KICAgICAgICBsb2cgIuS4i+i9vSBjbGVhcl9saW1pdC5zaCDlpLHotKUiCiAgICAgICAgZXhpdCAxCiAgICAgIGZpCiAgIC
AgIGNobW9kICt4ICIkQ0xFQVJfU0NSSVBUIgogICAgICAjIOS4i+i9veWQjuWGjeasoeagoemqjAogICAgICBpZiAhIGNoZWNrX21kNSAiJENM
RUFSX1NDUklQVCIgIiRFWFBFQ1RFRF9DTEVBUl9MSU1JVF9NRDUiICJjbGVhcl9saW1pdC5zaCI7IHRoZW4KICAgICAgICBsb2cgIuKdjCDkuI
vovb3lkI7nmoQgY2xlYXJfbGltaXQuc2ggTUQ1IOS7jeeEtuS4jeWMuemFje+8jOWPr+iDveaWh+S7tuW3suaNn+WdjyIKICAgICAgICBleGl0
IDEKICAgICAgZmkKICAgIGZpCiAgZWxzZQogICAgbG9nICLkuIvovb0gY2xlYXJfbGltaXQuc2guLi4iCiAgICBjdXJsIC1mc1NMICIkQ0xFQV
JfU0NSSVBUX1VSTCIgfCBzZWQgJ3MvXHIvL2cnID4gIiRDTEVBUl9TQ1JJUFQiCiAgICBpZiBbICQ/IC1uZSAwIF07IHRoZW4KICAgICAgbG9n
ICLkuIvovb0gY2xlYXJfbGltaXQuc2gg5aSx6LSlIgogICAgICBleGl0IDEKICAgIGZpCiAgICBjaG1vZCAreCAiJENMRUFSX1NDUklQVCIKIC
AgICMg5LiL6L295ZCO5qCh6aqMCiAgICBpZiAhIGNoZWNrX21kNSAiJENMRUFSX1NDUklQVCIgIiRFWFBFQ1RFRF9DTEVBUl9MSU1JVF9NRDUi
ICJjbGVhcl9saW1pdC5zaCI7IHRoZW4KICAgICAgbG9nICLinYwg5LiL6L2955qEIGNsZWFyX2xpbWl0LnNoIE1ENSDkuI3ljLnphY3vvIzlj6
/og73mlofku7blt7LmjZ/lnY8iCiAgICAgIGV4aXQgMQogICAgZmkKICBmaQp9CgojIOiuvue9ruS4iuihjOmZkOmAnwpzZXRfcmF0ZV9saW1p
dCgpIHsKICBsb2NhbCBpbnRlcmZhY2VzPSQxCiAgZm9yIGludGYgaW4gJGludGVyZmFjZXM7IGRvCiAgICBpZiBbWyAiJGludGYiID1+IF4oc3
RhdGljfHBwcCkgXV07IHRoZW4KICAgICAgbG9nICLomZrmi5/nvZHljaHvvJokaW50Zu+8jOS9v+eUqOS9jumAn+mZkOmAnyAoMTAyNEticHMp
IgogICAgICAiJFNQRUVEX0xJTUlUX1NDUklQVCIgLWEgIiRpbnRmIiAtdSAxMDI0CiAgICBlbHNlCiAgICAgIGxvZyAi54mp55CG572R5Y2h77
yaJGludGbvvIzkvb/nlKjpq5jpgJ/pmZDpgJ8gKDQwOTZLYnBzKSIKICAgICAgIiRTUEVFRF9MSU1JVF9TQ1JJUFQiIC1hICIkaW50ZiIgLXUg
NDA5NgogICAgZmkKICBkb25lCn0KCiMg5riF6Zmk6ZmQ6YCfCmNsZWFyX3JhdGVfbGltaXQoKSB7CiAgbG9jYWwgaW50ZXJmYWNlcz0kMQogIG
hhc19ydWxlcz1mYWxzZQogIGZvciBpbnRmIGluICRpbnRlcmZhY2VzOyBkbwogICAgaWYgL3Vzci9zYmluL3RjIHFkaXNjIHNob3cgZGV2ICIk
aW50ZiIgfCBncmVwIC1xICJyb290IjsgdGhlbgogICAgICBoYXNfcnVsZXM9dHJ1ZQogICAgICBicmVhawogICAgZmkKICBkb25lCiAgaWYgJG
hhc19ydWxlczsgdGhlbgogICAgbG9nICLmo4DmtYvliLDlt7LmnInop4TliJnvvIzlhYjmuIXpmaTlho3orr7nva4iCiAgICBiYXNoICRDTEVB
Ul9TQ1JJUFQKICBmaQp9CgojIOWcqOaXtumXtOWMuumXtOWGhQppbl9yYW5nZV90aW1lKCkgewogIGxvZyAi5b2T5YmN5Zyo6ZmQ6YCf5pe26Z
e05q615YaFICgkU1RBUlRfVElNRSAtICRFTkRfVElNRSnvvIzmraPlnKjlupTnlKjpmZDpgJ/op4TliJkuLi4iCiAgI2hhc19ydWxlcz1mYWxz
ZQogICNmb3IgaW50ZiBpbiAkaW50ZXJmYWNlczsgZG8KICAjICBpZiAvdXNyL3NiaW4vdGMgcWRpc2Mgc2hvdyBkZXYgIiRpbnRmIiB8IGdyZX
AgLXEgInJvb3QiOyB0aGVuCiAgIyAgICBoYXNfcnVsZXM9dHJ1ZQogICMgICAgYnJlYWsKICAjICBmaQogICNkb25lCiAgI2lmICRoYXNfcnVs
ZXM7IHRoZW4KICAgIGxvZyAi5qOA5rWL5Yiw5bey5pyJ6KeE5YiZ77yM5YWI5riF6Zmk5YaN6K6+572uIgogICAgYmFzaCAkQ0xFQVJfU0NSSV
BUCiAgI2ZpCiAgc2V0X3JhdGVfbGltaXQgIiRpbnRlcmZhY2VzIgp9CgptYWluKCkgewogIGlmIFsgJCMgLWdlIDIgXTsgdGhlbgogICAgU1RB
UlRfVElNRT0iJDEiCiAgICBFTkRfVElNRT0iJDIiCgogICAgaWYgISBpc192YWxpZF90aW1lICIkU1RBUlRfVElNRSIgfHwgISBpc192YWxpZF
90aW1lICIkRU5EX1RJTUUiOyB0aGVuCiAgICAgIGxvZyAi6ZSZ6K+v77ya5pe26Ze05qC85byP5LiN5ZCI5rOV77yM5b+F6aG75pivIEhIOm1t
IOagvOW8j++8iOS+i+WmgiAwOTozMO+8iSIKICAgICAgZXhpdCAxCiAgICBmaQoKICAgIHVwZGF0ZV9jcm9udGFiICIkU1RBUlRfVElNRSIgIi
RFTkRfVElNRSIKICBlbHNlCiAgICBpZiBbIC1mICIkQ09ORklHX0ZJTEUiIF07IHRoZW4KICAgICAgc291cmNlICIkQ09ORklHX0ZJTEUiCiAg
ICBlbHNlCiAgICAgIGxvZyAi5pyq5om+5Yiw6YWN572u5paH5Lu277yM5Lmf5pyq5Lyg5YWl5Y+C5pWw77yM6YCA5Ye6IgogICAgICBleGl0ID
EKICAgIGZpCiAgZmkKCiAgZG93bmxvYWRfc2NyaXB0cwoKICBpbnRlcmZhY2VzPSQoZ2V0X3VwX2ludGVyZmFjZXMpCiAgaWYgWyAteiAiJGlu
dGVyZmFjZXMiIF07IHRoZW4KICAgIGxvZyAi5pyq5om+5Yiw5Y+v55So572R5Y2h77yM6YCA5Ye6IgogICAgZXhpdCAxCiAgZmkKCiAgY3Vycm
VudF90aW1lPSQoZGF0ZSArIiVIJU0iKQogIHN0YXJ0X251bT0kKGVjaG8gIiRTVEFSVF9USU1FIiB8IHNlZCAncy86Ly8nKQogIGVuZF9udW09
JChlY2hvICIkRU5EX1RJTUUiIHwgc2VkICdzLzovLycpCgogIGlmIFsgIiRzdGFydF9udW0iIC1ndCAiJGVuZF9udW0iIF07IHRoZW4KICAgIC
AgaWYgWyAiJGN1cnJlbnRfdGltZSIgLWdlICIkc3RhcnRfbnVtIiBdIHx8IFsgIiRjdXJyZW50X3RpbWUiIC1sdCAiJGVuZF9udW0iIF07IHRo
ZW4KICAgICAgICAgICMg5pe26Ze05Zyo6IyD5Zu05YaF77yI6Leo5aSp5oOF5Ya177yJCiAgICAgICAgICBsb2cgIua4hemZpOmZkOmAnyIKIC
AgICAgICAgIGJhc2ggJENMRUFSX1NDUklQVAogICAgICAgICAgI+iuvue9rumZkOmAnwogICAgICAgICAgbG9nICLorr7nva7pmZDpgJ8iCiAg
ICAgICAgICBzZXRfcmF0ZV9saW1pdCAiJGludGVyZmFjZXMiCiAgICAgIGVsc2UKICAgICAgICAgICMg5LiN5Zyo6IyD5Zu05YaFCiAgICAgIC
AgICBsb2cgIuW9k+WJjeS4jeWcqOmZkOmAn+aXtumXtOauteWGhSAoJFNUQVJUX1RJTUUgLSAkRU5EX1RJTUUp77yM5q2j5Zyo5riF6Zmk5omA
5pyJ6ZmQ6YCf6KeE5YiZLi4uIgogICAgICAgICAgYmFzaCAkQ0xFQVJfU0NSSVBUCiAgICAgIGZpCiAgZWxzZQogICAgICBpZiBbICIkY3Vycm
VudF90aW1lIiAtZ2UgIiRzdGFydF9udW0iIF0gJiYgWyAiJGN1cnJlbnRfdGltZSIgLWx0ICIkZW5kX251bSIgXTsgdGhlbgogICAgICAgICAg
IyDml7bpl7TlnKjojIPlm7TlhoXvvIjmraPluLjmg4XlhrXvvIkKICAgICAgICAgIGxvZyAi5riF6Zmk6ZmQ6YCfIgogICAgICAgICAgYmFzaC
AkQ0xFQVJfU0NSSVBUCiAgICAgICAgICAj6K6+572u6ZmQ6YCfCiAgICAgICAgICBsb2cgIuiuvue9rumZkOmAnyIKICAgICAgICAgIHNldF9y
YXRlX2xpbWl0ICIkaW50ZXJmYWNlcyIKICAgICAgZWxzZQogICAgICAgICAgIyDkuI3lnKjojIPlm7TlhoUKICAgICAgICAgIGxvZyAi5b2T5Y
mN5LiN5Zyo6ZmQ6YCf5pe26Ze05q615YaFICgkU1RBUlRfVElNRSAtICRFTkRfVElNRSnvvIzmraPlnKjmuIXpmaTmiYDmnInpmZDpgJ/op4Tl
iJkuLi4iCiAgICAgICAgICBiYXNoICRDTEVBUl9TQ1JJUFQKICAgICAgZmkKICBmaQp9CgptYWluICIkQCIKZXhpdCAw"

# ==============================================================================
# ★ 自举段：安全地把自己下载到磁盘并执行（对应 v6 的缺陷①）
#   多源（国内源优先）→ gh-proxy.com → raw.githubusercontent.com → cdn.jsdelivr.net
#   国内源（WorkBuddy 静态托管）深圳/广州等出网不稳的机器也能 1 秒内拉到，
#   且返回的是与本文件同字节的内容（sha256 一致），无版本漂移。
#   全失败必须非 0 退出并打印 [FATAL]，绝不允许"静默成功"。
# ==============================================================================
Q2_REF="${Q2_REF:-280f9aec3bdfcd29ef2377e75dc4258862f53d58}"
Q2_RAW="https://raw.githubusercontent.com/angelbaby86966/scheduled-refund@${Q2_REF}/ops/q2_oneclick_v6.sh"
Q2_CDN="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@${Q2_REF}/ops/q2_oneclick_v6.sh"
# 国内源：WorkBuddy 静态托管（该站点禁止 .sh 扩展名，故用无扩展名文件名）
Q2_DOM="https://init-full-deploy.app.workbuddy.host/q2_oneclick_v6"
Q2_BOOT_DST="${Q2_BOOT_DST:-/root/q2_oneclick_v6.sh}"

q2_bootstrap() {
  say "===== q2 v6.2 自举下载（国内源优先 + 多源 + 落盘 + 校验，禁止 curl|bash）====="
  say "  目标: $Q2_BOOT_DST"
  if fetch_script "$Q2_BOOT_DST" 36000 90 2 \
      "${Q2_DOM}" \
      "https://gh-proxy.com/${Q2_RAW}" \
      "${Q2_RAW}" \
      "${Q2_CDN}"; then
    chmod +x "$Q2_BOOT_DST" 2>/dev/null
    say "  ✅ 主脚本已落盘并通过校验，开始执行：/bin/bash $Q2_BOOT_DST $*"
    exec /bin/bash "$Q2_BOOT_DST" "$@"
  fi
  # ↓↓↓ 绝不静默：所有源都失败 → 明确报错 + 非 0 退出 ↓↓↓
  echo "[FATAL] 下载失败：q2_oneclick_v6.sh 全部候选源均不可用或校验未通过（国内源 init-full-deploy.app.workbuddy.host / gh-proxy.com / raw.githubusercontent.com / cdn.jsdelivr.net）" >&2
  say "  ❌ [FATAL] 下载失败，未执行任何部署动作；请检查出网/代理后重试"
  exit 1
}

if [ "${1:-}" = "--bootstrap" ]; then
  shift
  q2_bootstrap "$@"
fi

# ==============================================================================
# 部署参数
# ==============================================================================
Q2_JWT_FILE="${Q2_JWT_FILE:-/etc/q2/jwt}"
if [ -z "${Q2_JWT:-}" ] && [ -f "$Q2_JWT_FILE" ]; then
  Q2_JWT="$(cat "$Q2_JWT_FILE" 2>/dev/null | tr -d '[:space:]')"
fi
: "${Q2_JWT:?未找到 JWT：请 export Q2_JWT=xxx，或 echo <新token> > $Q2_JWT_FILE（脚本已不再内置密钥）}"
JWT="$Q2_JWT"
CHAN_AK="${Q2_AK:-06d78b19bd0d9fc0aa300c6d}"
CHAN_SK="${Q2_SK:-16d6c46443308e62bb51f22c074a90ed}"
ISP="${Q2_ISP:-联通}"
PLACEHOLDER="ZHOUYI_XIAODU"
ADMIN_API="https://admin.zhouyi.top"
OSS="https://zyy-go.oss-cn-beijing.aliyuncs.com/script"
ADMIN_APPID="${Q2_APPID:-fg5c21pbzfgu6y2s2yqvanvr6uv99drq}"
ADMIN_AK="${Q2_ADMIN_AK:-ja3io44nq2m7hx63fjkpio7s422aksel}"
ADMIN_SK="${Q2_ADMIN_SK:-ydDGuguZ8COcJN4Ztl3Lsic3Z00zGEani8fYOPiYk2XXCuXQ1AHyy7E1sgV4dyDT}"
LIMIT_START="23:59"; LIMIT_END="18:25"; HAPP_N=9
# ★ 9 路就绪门限（对应 v6 的缺陷②）：有限重试，不再"提示一句就跳过"
READY_TRY="${Q2_READY_TRY:-6}"
READY_WAIT="${Q2_READY_WAIT:-15}"
READY_MISSING=""; NINE_OK=1

node_id() { cat /usr/local/edge_zycloud/device_code 2>/dev/null || cat /usr/local/edge/device_code 2>/dev/null || cat /etc/.mac 2>/dev/null; }
flow() { curl -fsS -m 30 -X POST "$ADMIN_API/api/edgeNode/stateflow" -H "Content-Type: application/json" \
  -H "X-Token: $JWT" -d "{\"nodes\":[\"$1\"],\"hostname\":\"$2\",\"stage\":\"$3\"}" 2>&1; }
submit_nominal() {
  local ts sign; ts=$(date +%s)
  sign=$(printf '%s' "${ADMIN_AK}:${ts}" | openssl dgst -sha256 -hmac "$ADMIN_SK" 2>/dev/null | cut -d' ' -f2)
  curl -fsS -k -m 30 -X POST "$ADMIN_API/api/edgeNode/updateEdgeNominalInfo" -H "Content-Type: application/json" \
    -H "appId: $ADMIN_APPID" -H "timestamp: $ts" -H "sign: $sign" \
    -d "{\"nodeId\":\"$1\",\"province\":\"$2\",\"city\":\"$3\",\"isp\":\"$ISP\",\"natType\":\"public\",\"resourceType\":\"2\",\"dialType\":\"staticNetSingle\",\"vendorSuggestCustomers\":41,\"usbw\":200,\"bwNum\":1,\"isCrossNetwork\":false,\"crossNetworkIsp\":null,\"isTransProv\":false,\"transMode\":1}" 2>&1
}
detect_loc() {
  local i p c; i=$(curl -s --retry 2 --max-time 10 myip.ipip.net 2>/dev/null)
  p=$(echo "$i"|awk -F' ' '{print $4}'|tr -d ','); c=$(echo "$i"|awk -F' ' '{print $5}'|tr -d ',')
  [ -z "$p" ] && p="浙江"; [ -z "$c" ] && c="杭州"; echo "${p}|${c}"
}

# ==============================================================================
# ★ 真 SN 读取：双路径 + 容器内/宿主机都试，取第一个"非空且长度 ≥ 60"的结果。
#   ⚠️ 路径必须是【单数 ipes】！机器实测铁证：
#      /app/ipes/bin/ipes_sn 存在（76字节），复数 /app/ipses/... 永失败。
#      v6/v6.1 早期版写成复数 → 真 SN 永远读空（18 轮全 0 字节）。
#      同理 Q2 官方 docker run 用 /app/ipes/bin/ipes start。
# ==============================================================================
SN_IN_PATHS="/app/ipes/bin/ipes_sn /usr/local/edge/ipes_sn"
SN_HOST_PATHS="/usr/local/edge_zycloud/ipes_sn /usr/local/edge/ipes_sn"
read_sn() {
  local p v
  SN=""
  for p in $SN_IN_PATHS; do
    v=$(docker exec ipes cat "$p" 2>/dev/null | tr -d '\r\n')
    if [ "${#v}" -ge 60 ]; then SN="$v"; SN_SRC="container:$p"; return 0; fi
    [ -n "$v" ] && say "     · 容器内 $p 有内容但仅 ${#v} 字节(<60)，继续换路径"
  done
  for p in $SN_HOST_PATHS; do
    [ -f "$p" ] || continue
    v=$(tr -d '\r\n' <"$p" 2>/dev/null)
    if [ "${#v}" -ge 60 ]; then SN="$v"; SN_SRC="host:$p"; return 0; fi
  done
  return 1
}
# 当前已存在的 SN（无则空），用于"避免用占位符覆盖真 SN"
sn_current() { read_sn >/dev/null 2>&1; printf '%s' "$SN"; }

# ==============================================================================
# ★ 就绪探测（对应 v6 的缺陷②）
#   返回 0 = 容器 + custom.yml + happ.0 全部就绪；否则把缺失项写进 READY_MISSING
#   ⚠️ CFG 路径必须是【单数 ipes】！机器实测：/opt/ipes/var/db/ipes/happ-conf/custom.yml。
#      写成复数 → [ -f "$CFG" ] 永假 → 9 路分支永远走 else → happ 永远 1 路。
# ==============================================================================
ROOT=/data/happ; CFG=/opt/ipes/var/db/ipes/happ-conf/custom.yml
# v6.2：镜像源【腾讯云 CCR 省外】—— ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:latest
#   （youkai/youkai@6688 实测有效，绕开已过期的阿里云北京个人版仓库；:latest 即平台省外镜像）
ALI_REG="crpi-0myzmqp9v99mnimv.cn-beijing.personal.cr.aliyuncs.com"   # 已过期·弃用
ALI_REPO="qy_q2/ipes-linux-amd64-youkai-latest:latest"                 # 已过期·弃用
ALI_USER="${Q2_ALI_USER:-nick5404979015}"                              # 已过期·弃用
ALI_PASS="${Q2_ALI_PASS:-zblove0222}"                                  # 已过期·弃用
# ★ 腾讯云 CCR 省外镜像（唯一外部源；凭据 youkai/youkai@6688 实测有效）
TENC_REG="ccr.ccs.tencentyun.com"
TENC_REPO="zyy_cloud/ipes-linux-amd64-youkai-latest:latest"
TENC_USER="${Q2_TENC_USER:-youkai}"
TENC_PASS="${Q2_TENC_PASS:-youkai@6688}"
IMG="${TENC_REG}/${TENC_REPO}"                                        # 默认镜像=腾讯云 CCR 省外
# ★ v6.2 OSS 镜像 tar 兜底（腾讯CCR拉不到时用）：私有对象+预签名GET URL（1年有效期），
#   sha256=该tar实测值，docker load 后与 IMG 一致。到期需用 _a34tools/build_oss_mirror.py 重新生成。
Q2_IMG_TAR_URL="${Q2_IMG_TAR_URL:-https://zyy-q2-mirror-41.oss-cn-shenzhen.aliyuncs.com/youkai/ipes-youkai-latest.tar.gz?OSSAccessKeyId=LTAI5t9vLpigzfS6vttQN85e&Expires=1823839584&Signature=Rt%2BFNsTes95b7eEMYpf42nEDF5g%3D}"
Q2_IMG_TAR_SHA256="${Q2_IMG_TAR_SHA256:-8df489523dd77daffdbc8c24cce0b6b52a93c6751fe3689e9f8a5f39794514d3}"
Q2_IMG_TAR_MIN="${Q2_IMG_TAR_MIN:-330909889}"
ready_probe() {
  READY_MISSING=""
  docker inspect ipes >/dev/null 2>&1 || READY_MISSING="$READY_MISSING 容器ipes"
  [ -f "$CFG" ] || READY_MISSING="$READY_MISSING custom.yml"
  [ -d "$ROOT/happ.0" ] || READY_MISSING="$READY_MISSING happ.0"
  [ -z "$READY_MISSING" ]
}
wait_ready() {
  local i=1
  while [ "$i" -le "$READY_TRY" ]; do
    if ready_probe; then say "     ✅ 就绪探测通过（第 $i/$READY_TRY 次）"; return 0; fi
    say "     ⏳ 未就绪（$i/$READY_TRY）缺少：$READY_MISSING → ${READY_WAIT}s 后重试"
    i=$((i+1))
    [ "$i" -le "$READY_TRY" ] && sleep "$READY_WAIT"
  done
  say "     ✗ 等待 $READY_TRY 次（$((READY_TRY * READY_WAIT))s）仍不就绪，缺少：$READY_MISSING"
  return 1
}

# ==============================================================================
# ★ v6.2 镜像拉取：腾讯云 CCR 省外（ccr.ccs.tencentyun.com，youkai/youkai@6688 实测有效）
#   - 唯一外部源即省外镜像（:latest）；失败时走 OSS tar 兜底（同一省外镜像的备用副本，需提前构建上传）
# ==============================================================================
q2_pull_image() {
  # 0) 配置 registry-mirror（加速基础层拉取，与平台一致；仅当 daemon.json 不存在时写入，避免覆盖既有配置）
  if [ -d /etc/docker ] && [ ! -f /etc/docker/daemon.json ]; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": ["https://stxam7vz.mirror.aliyuncs.com"]
}
EOF
    systemctl restart docker >/dev/null 2>&1; sleep 3
    if ! docker info >/dev/null 2>&1; then
      say "  ⚠️ docker 重启后未就绪，后续拉取可能失败"
    fi
    say "  · 已写入 docker registry-mirror: stxam7vz.mirror.aliyuncs.com（已重启 docker 生效）"
  fi
  # 1) 腾讯云 CCR 省外镜像（唯一外部源：youkai/youkai@6688 实测有效；:latest 即平台省外镜像）
  say "  [镜像] 腾讯云 CCR 省外：${TENC_REG}/${TENC_REPO}"
  # ★ v6.2 加固：本地已存在则直接复用，避免 registry 抖动/重登导致重跑失败（12:29 能拉、13:01 偶发握手失败）
  if docker image inspect "${TENC_REG}/${TENC_REPO}" >/dev/null 2>&1; then
    IMG="${TENC_REG}/${TENC_REPO}"
    say "  ✅ 本地已存在 ${IMG}，跳过拉取直接复用（如需强制刷新先 docker rmi 再跑）"
    return 0
  fi
  if docker login "${TENC_REG}" --username="${TENC_USER}" --password="${TENC_PASS}" >/dev/null 2>&1 \
     && docker pull "${TENC_REG}/${TENC_REPO}" >/dev/null 2>&1; then
    IMG="${TENC_REG}/${TENC_REPO}"
    say "  ✅ 腾讯云 CCR 镜像拉取成功 → $IMG"
    return 0
  fi
  # 拉取失败但本地恰好有（极端竞态兜底）：复用本地，不让整段失败
  if docker image inspect "${TENC_REG}/${TENC_REPO}" >/dev/null 2>&1; then
    IMG="${TENC_REG}/${TENC_REPO}"
    say "  ⚠️ 拉取失败但本地已存在 ${IMG}，复用本地镜像"
    return 0
  fi
  # 2) 腾讯云失败 → OSS 镜像 tar 兜底（同一省外镜像的备用副本，需提前 docker save 上传 OSS）
  #    ⚠️ 兜底前提：${TENC_REG}/${TENC_REPO} 已 docker save 成 tar 上传到 OSS，
  #       且 Q2_IMG_TAR_URL 指向可访问（公开或预签名）的下载地址；
  #       保存时必须带原 repo:tag，docker load 后才与 IMG 一致，后续 docker run 才认。
  say "  ⚠️ 腾讯云 registry 拉取失败，尝试 OSS 镜像兜底（同一省外镜像的备用副本）…"
  if [ -n "${Q2_IMG_TAR_URL:-}" ]; then
    say "  [镜像兜底] 从 OSS 下载镜像 tar: ${Q2_IMG_TAR_URL}"
    local tar=/tmp/q2_youkai.tar
    if fetch_blob "$tar" "${Q2_IMG_TAR_MIN:-300000000}" 1200 "${Q2_IMG_TAR_URL}"; then
      if [ -n "${Q2_IMG_TAR_SHA256:-}" ]; then
        local got; got=$(sha256sum "$tar" 2>/dev/null | awk '{print $1}')
        if [ "$got" != "${Q2_IMG_TAR_SHA256}" ]; then
          say "     ✗ sha256 校验失败（${got:-?} != ${Q2_IMG_TAR_SHA256}）"; rm -f "$tar"
          mark_fail "镜像兜底(sha256不符)"; return 1
        fi
      fi
      if docker load -i "$tar" >/dev/null 2>&1; then
        IMG="${TENC_REG}/${TENC_REPO}"
        say "  ✅ OSS 镜像兜底加载成功 → $IMG"
        rm -f "$tar"; return 0
      fi
      say "     ✗ docker load 失败"; rm -f "$tar"
    else
      say "     ✗ OSS tar 下载/大小校验失败"
    fi
  else
    say "     （未配置 Q2_IMG_TAR_URL，跳过 OSS 兜底）"
  fi
  # 兜底也失败：标红退出（腾讯云 + OSS 副本均不可用）
  mark_fail "镜像拉取(腾讯云失败 + OSS兜底失败：${TENC_REG}/${TENC_REPO})"
  return 1
}

# ==============================================================================
# ★ v6.2 限速自愈：窗口内若 eth0 上 htb 规则丢失，1 分钟内重建
#   - run_limit.sh 本身已含 @reboot + 每 10 分钟 cron 自愈（speed_limit.sh 自带 sfq + 交互高优 class）
#   - 这里额外加一个 systemd 每分钟 watch：弥补"窗口内 TC 被冲掉、距下次 10 分钟 cron 还有空窗"的漏洞
# ==============================================================================
q2_limit_watch_install() {
  local LSTART="$LIMIT_START" LEND="$LIMIT_END" DEV=eth0 OSSREF="$OSS"
  cat > /usr/local/bin/q2_limit_watch.sh <<EOF
#!/bin/bash
# q2 v6.2 限速自愈：处于限速窗口且 eth0 上 htb 规则丢失时，重跑 run_limit.sh 重建
LSTART="$LSTART"; LEND="$LEND"; DEV=eth0; OSSREF="$OSSREF"
hm() { local h=\$(date +%H|sed 's/^0//'); local m=\$(date +%M|sed 's/^0//'); echo \$((h*60+m)); }
now=\$(hm)
sm=\$((\${LSTART:0:2}*60+\${LSTART:3:2})); em=\$((\${LEND:0:2}*60+\${LEND:3:2}))
inwin=false
if [ \$sm -le \$em ]; then [ \$now -ge \$sm ] && [ \$now -lt \$em ] && inwin=true
else { [ \$now -ge \$sm ] || [ \$now -lt \$em ]; } && inwin=true; fi
if \$inwin; then
  if ! tc qdisc show dev \$DEV 2>/dev/null | grep -q "htb 1:"; then
    if [ -s /usr/local/bin/run_limit_v62.sh ]; then bash /usr/local/bin/run_limit_v62.sh "\$LSTART" "\$LEND"
    else curl -fsSL -m 180 "\$OSSREF/limit/run_limit.sh" -o /tmp/_wl.sh 2>/dev/null && [ -s /tmp/_wl.sh ] && bash /tmp/_wl.sh "\$LSTART" "\$LEND"; fi
  fi
fi
EOF
  chmod +x /usr/local/bin/q2_limit_watch.sh
  cat > /etc/systemd/system/q2-limit-watch.service <<'EOF'
[Unit]
Description=q2 limit self-heal
[Service]
Type=oneshot
ExecStart=/usr/local/bin/q2_limit_watch.sh
EOF
  cat > /etc/systemd/system/q2-limit-watch.timer <<'EOF'
[Unit]
Description=q2 limit self-heal timer (per minute)
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable --now q2-limit-watch.timer >/dev/null 2>&1
  local st=$(systemctl is-enabled q2-limit-watch.timer 2>/dev/null || echo n/a)
  say "  · 限速自愈 timer: $st（每分钟巡检，窗口内 htb 丢失即重建）"
}

LOCK=/var/run/ipes_deploy.lock
NOHUP_LOG=/var/log/ipes_nohup.log
STATUS_FILE=/var/log/ipes_deploy.status

# ==============================================================================
# 后台部署子进程：持有互斥锁，单台不互踩。云助手命令不在此阻塞。
# ==============================================================================
internal_deploy() {
  exec 9>"$LOCK" 2>/dev/null
  if ! flock -n 9 2>/dev/null; then
    say "❌ 本机已有部署在运行（锁被占用），本次后台子进程退出"
    return 1
  fi
  say ""; say "===== [后台] 部署：docker → Q2业务 → 9路 → 真SN回填 → 保活 → 限速 ====="

  # 2.2 docker + Q2 业务（官方链路）
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    say "  [2.2] docker 已就绪（$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')），跳过安装"
  else
    say "  [2.2] 安装 docker…"
    if fetch_script /tmp/_dk.sh 20000 300 3 "$OSS/install_docker/install_docker-ce_v2.sh"; then
      bash /tmp/_dk.sh || mark_fail "docker安装"
    else
      mark_fail "docker安装(下载失败:3轮全失败)"
    fi
  fi
  say "  docker: $(docker --version 2>/dev/null || echo 失败)"
  # v6.2：docker 就绪后先拉取镜像（阿里云优先，失败则 OSS tar 兜底；双失败直接判失败，不再"假成功"）
  if ! q2_pull_image; then
    mark_fail "镜像拉取失败(阿里云+OSS兜底均失败)"
    return 1
  fi
  say "  [2.3] Q2 业务部署（-i 2 -t 2）…"
  if embed_out /tmp/_q2.sh 2000 EMB_Q2_B64; then
    say "     · 组件来源：内嵌（零外部依赖）"
    bash /tmp/_q2.sh -i 2 -t 2 || mark_fail "Q2部署"
  elif fetch_script /tmp/_q2.sh 2000 300 3 "$OSS/Q2_test/ecache_auto_disk_install.sh" \
       && bash /tmp/_q2.sh -i 2 -t 2; then
    say "     · 组件来源：OSS 回落（内嵌解码失败时）"
  else
    mark_fail "Q2部署(内嵌解码失败且OSS 3轮重试全失败)"
  fi

  # 2.4 ★ 9 路在部署流程内一次做对（不是后面对齐）
  say "  [2.4] happ 路数一次做对（目标 ${HAPP_N} 路）…"
  for _w in $(seq 1 60); do
    docker inspect ipes >/dev/null 2>&1 && [ -d /data/happ/happ.0 ] && break
    say "     等容器初始化（$_w/60）…"; sleep 10
  done
  CUR=$(docker exec ipes ls -d /data/happ/happ.* 2>/dev/null | wc -l | tr -d ' ')
  say "     容器内实际可见 ${CUR:-0} 个分片（期望 $HAPP_N）"
  if [ "${CUR:-0}" = "$HAPP_N" ]; then
    say "     ✅ 已是 ${HAPP_N} 路，跳过"
  elif wait_ready; then
    REF="$ROOT/happ.0/xycould_base_info"
    for n in $(seq 0 $((HAPP_N-1))); do
      mkdir -p "$ROOT/happ.$n/hdata/cache" "$ROOT/happ.$n/hdata/config"
      [ -s "$REF" ] && [ ! -s "$ROOT/happ.$n/xycould_base_info" ] && cp -p "$REF" "$ROOT/happ.$n/xycould_base_info" 2>/dev/null
    done
    say "     分片目录就绪：$(ls -d $ROOT/happ.* 2>/dev/null | wc -l) 个"
    TMP=$(mktemp)
    { echo "# q2 happy${HAPP_N} $(date '+%F %T')"; echo "args:"
      for n in $(seq 0 $((HAPP_N-1))); do echo "  - $ROOT/happ.$n"; done
      grep -E '^reg_isp:' "$CFG" 2>/dev/null; } > "$TMP"
    CNT=$(grep -cE "^  - ${ROOT}/happ\.[0-9]+$" "$TMP")
    if [ "$CNT" != "$HAPP_N" ]; then
      rm -f "$TMP"; say "     ✗ 配置条数异常($CNT != $HAPP_N)，保留现场"
      NINE_OK=0; mark_fail "9路部署(配置条数异常:$CNT!=$HAPP_N)"
    else
      cp -p "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
      cp -p "$TMP" "$CFG"; rm -f "$TMP"
      say "     custom.yml 已设为 ${HAPP_N} 路"
      say "     重建容器挂载 ${HAPP_N} 路（断流 30-60 秒）…"
      docker stop ipes >/dev/null 2>&1
      docker rm -f ipes   >/dev/null 2>&1
      MARGS=""
      for n in $(seq 0 $((HAPP_N-1))); do
        MARGS="$MARGS -v $ROOT/happ.$n/hdata/cache:$ROOT/happ.$n/hdata/cache"
        MARGS="$MARGS -v $ROOT/happ.$n/hdata/config:$ROOT/happ.$n/hdata/config"
        MARGS="$MARGS -v $ROOT/happ.$n/xycould_base_info:$ROOT/happ.$n/xycould_base_info"
      done
      # shellcheck disable=SC2086
      # ⚠️ 挂载目标与启动命令必须是【单数 ipes】！与 Q2 官方 docker run 完全一致：
      #    -v /opt/ipes/.../custom.yml:/app/ipes/.../custom.yml + /app/ipes/bin/ipes start
      _drlog=$(mktemp)
      docker run -d --restart=always --name=ipes --network=host $MARGS \
        -v "$CFG:/app/ipes/var/db/ipes/happ-conf/custom.yml" \
        "$IMG" sh -c '/app/ipes/bin/ipes start && tail -f /dev/null' >"$_drlog" 2>&1
      RCD=$?
      say "     docker run 返回码=$RCD"
      if [ "$RCD" != "0" ]; then
        say "     ✗ docker run 报错（前 20 行）："
        sed 's/^/       /' "$_drlog" 2>/dev/null | head -20
        NINE_OK=0; mark_fail "9路部署(docker run 返回码=$RCD)"
      else
        rm -f "$_drlog"
      fi
      # 健康轮询：等 happ 进程达到 9 路（最多 60s），替代固定 sleep 40
      for _h in $(seq 1 12); do
        HP=$(docker exec ipes sh -c 'ps -ef | grep -c "[h]app"' 2>/dev/null | tr -d '\r')
        [ "${HP:-0}" = "$HAPP_N" ] && break
        sleep 5
      done
      NEW=$(docker exec ipes ls -d /data/happ/happ.* 2>/dev/null | wc -l | tr -d ' ')
      HP=$(docker exec ipes sh -c 'ps -ef | grep -c "[h]app"' 2>/dev/null | tr -d '\r')
      if [ "${NEW:-0}" = "$HAPP_N" ]; then
        say "     ✅ ${HAPP_N} 路已真正生效：容器内分片=$NEW happ进程=$HP"
      else
        say "     ❌ 重建后容器内分片=$NEW（期望$HAPP_N）；happ进程=$HP"
        say "        现场保留：$CFG.bak.* 可回滚；重跑本脚本会再修一次（幂等）"
        NINE_OK=0; mark_fail "9路部署(重建后分片=$NEW!=$HAPP_N)"
      fi
    fi
  else
    # ★ v6 这里只 say 一句就跳过 → 静默失败。v6.1 明确标红并计入失败。
    say "     ❌ 容器或 custom.yml 未就绪，已放弃本轮 9 路部署（重跑本脚本会再修一次）"
    NINE_OK=0; mark_fail "9路部署(未就绪:$READY_MISSING)"
  fi

  # 2.5 真 SN 回填 + 再流转（紧接部署，不分离）
  NID=$(node_id)
  say "  [2.5] 读真SN → 回填 → 再流转…"
  SN=""; SN_SRC=""
  for i in $(seq 1 18); do
    if read_sn; then
      say "     ✅ 取到真SN（${#SN}字节，来源 $SN_SRC）"; break
    fi
    say "     等 SN（$i/18，尝试 /app/ipes/bin/ipes_sn → /usr/local/edge/ipses_sn）…"; sleep 10
  done
  if [ ${#SN} -ge 60 ] && [ -n "$NID" ]; then
    LOC=$(detect_loc)
    say "     SN=${SN:0:16}…（${#SN}字节）"
    say "     降级→待配置: $(flow "$NID" "$SN" configured)"
    say "     提交属性(41/200M/${ISP}): $(submit_nominal "$NID" "${LOC%%|*}" "${LOC##*|}")"
    sleep 2
    say "     升回→服务中: $(flow "$NID" "$SN" inService)"
  else
    say "     ⚠️ 未取到真SN（${#SN}字节，来源 ${SN_SRC:-无}），重跑本脚本会自动只补这一步"
  fi

  # ==============================================================================
  say ""; say "===== [3/4] 安装保活 ====="
  # ★ 修 v6 的缺陷③（下载失败无重试无校验）+ 实测发现：OSS 上
  #   install_ipses_health_check.sh 返回 404，而 Q2 官方部署脚本
  #   （ecache_auto_disk_install.sh）自己会装 /usr/local/bin/ipes_health_check.sh
  #   + cron(* * * * *)，所以 v6 的保活段本来就是"误报失败"。
  #   新逻辑：① 已就绪(脚本+cron 都在) → ✅ 跳过，不算失败；
  #           ② 未就绪 → 多源 + 3 轮重试 + 落盘校验安装，装不上才 mark_fail。
  HC_SCRIPT=/tmp/_hc.sh
  HC_BIN=/usr/local/bin/ipes_health_check.sh
  # v6.2 修正：保活安装器真名是 install_ipes_health_check.sh（v6.1 误写文件名多一个字符，OSS 返回 404 死链）
  HC_URL="${Q2_HC_URL:-$OSS/Q2_test/install_ipes_health_check.sh}"
  # 若随脚本分发有本地副本则优先用（OSS 不可达也能装）；不存在再走上面的 OSS 源
  HC_LOCAL="$(dirname "${BASH_SOURCE[0]:-}")/install_ipes_health_check.sh"
  if [ -s "$HC_LOCAL" ] && cp -f "$HC_LOCAL" "$HC_SCRIPT" 2>/dev/null; then
    say "  · 保活安装器：用本地副本 $(basename "$HC_LOCAL")"
  fi
  hc_cron_cnt() { crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check'; }
  if [ -x "$HC_BIN" ] && [ "$(hc_cron_cnt)" -ge 1 ] 2>/dev/null; then
    say "  ✅ 保活已就绪：$HC_BIN 存在，cron $(hc_cron_cnt) 条，跳过安装"
  else
    say "  保活未就绪（HC_BIN=$([ -x "$HC_BIN" ] && echo 有 || echo 无)，cron $(hc_cron_cnt) 条），开始安装…"
    if [ -s "$HC_SCRIPT" ] || embed_out "$HC_SCRIPT" 200 EMB_HC_B64 \
       || fetch_script "$HC_SCRIPT" 200 120 3 "$HC_URL"; then
      say "  执行保活安装脚本…"
      if bash "$HC_SCRIPT"; then
        say "  ✅ 保活安装脚本执行完成"
      else
        mark_fail "保活(脚本执行返回码=$?)"
      fi
    else
      say "  ❌ 保活脚本下载失败（已尝试 $HC_URL，3 轮）"
      mark_fail "保活(下载失败:$HC_URL)"
    fi
  fi
  say "  保活cron: $(hc_cron_cnt) 条"

  # ==============================================================================
  say ""; say "===== [4/4] 挂限速 ${LIMIT_START} → ${LIMIT_END} ====="
  # ★ 限速脚本先落盘校验再执行（修 v6 的缺陷：curl|bash 下载失败仍"静默成功"）
  local lf=/tmp/_run_limit.sh
  if embed_out "$lf" 2000 EMB_LIMIT_B64; then
    say "     · 限速组件：内嵌"
  elif fetch_script "$lf" 2000 180 3 "$OSS/limit/run_limit.sh"; then
    say "     · 限速组件：OSS 回落"
  fi
  # 落本地副本，供每分钟自愈 watch 优先使用（自愈也不再依赖 OSS）
  [ -s "$lf" ] && cp -f "$lf" /usr/local/bin/run_limit_v62.sh 2>/dev/null \
    && chmod +x /usr/local/bin/run_limit_v62.sh 2>/dev/null
  if [ -s "$lf" ]; then
    bash "$lf" "$LIMIT_START" "$LIMIT_END"
    say "  · 限速脚本执行完成（若下方 qdisc 计数为 0 表示限速未生效，需重跑）"
  else
    say "  ❌ 限速脚本获取失败（内嵌解码失败且OSS 3轮重试全失败）"
    mark_fail "限速(脚本获取失败)"
  fi
  q2_limit_watch_install
  say "  qdisc=$(tc qdisc show dev eth0 2>/dev/null | grep -c htb) 条  cron=$(crontab -l 2>/dev/null | grep -cE 'limit_start|clear_limit') 条  heal-timer=$(systemctl is-enabled q2-limit-watch.timer 2>/dev/null || echo 无)"

  flock -u 9 2>/dev/null; exec 9>&-
  # ==============================================================================
  say ""; say "==================== 验收 ===================="
  say "容器     : $(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | tr '\n' ' ')"
  say "happ 路数: $(docker exec ipes ls /data/happ 2>/dev/null | grep -c happ)  (期望 9)"
  say "happ进程 : $(docker exec ipes sh -c 'ps -ef | grep -c "[h]app:vod"' 2>/dev/null | tr -d '\r')  (期望 9)"
  ACC_SN=""; ACC_SN_SRC=""
  SN=""; SN_SRC=""
  if read_sn >/dev/null 2>&1; then ACC_SN="$SN"; ACC_SN_SRC="$SN_SRC"; fi
  say "真SN     : ${ACC_SN:-未取到}  (来源 ${ACC_SN_SRC:-无})"
  say "SN 长度  : ${#ACC_SN}  (期望 76)"
  say "保活cron : $(hc_cron_cnt) 条（脚本 $([ -x "$HC_BIN" ] && echo 存在 || echo 缺失)）"
  say "限速     : qdisc $(tc qdisc show dev eth0 2>/dev/null | grep -c htb) / cron $(crontab -l 2>/dev/null | grep -cE 'limit_start|clear_limit') 条 / 自愈timer=$(systemctl is-enabled q2-limit-watch.timer 2>/dev/null || echo 无)"
  say "镜像源   : $IMG"
  say "纯净版   : CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null) Q=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)  (应 cubic + pfifo_fast)"
  say "nodeID   : $(node_id)"
  if [ "$NINE_OK" = "1" ]; then
    say "9路部署  : ✅ 完成"
  else
    say "9路部署  : ❌ 未完成（详见上文 9 路段落）"
  fi
  # ★ 汇总判定：调用方 grep 这一行即可，不必逐条读指标
  if [ -n "$FAIL" ]; then
    say "==== 总体结果:失败（失败步骤:$(fail_list)）===="
  else
    say "==== 总体结果:成功 ===="
  fi
  say "============ 后台部署完成 $(date '+%F %T') ============"
  # 机器可读状态文件（供云助手/巡检判断，避免再次"看起来成功"）
  {
    printf 'time=%s\n' "$(date '+%F %T')"
    printf 'node_id=%s\n' "$(node_id)"
    printf 'happ_shards=%s\n' "$(docker exec ipes ls /data/happ 2>/dev/null | grep -c happ)"
    printf 'nine_deploy=%s\n' "$([ "$NINE_OK" = "1" ] && echo OK || echo FAIL)"
    if [ -n "$FAIL" ]; then
      printf 'result=FAIL\nfailed_steps=%s\n' "$(fail_list)"
    else
      printf 'result=OK\nfailed_steps=\n'
    fi
  } > "$STATUS_FILE" 2>/dev/null
  say "  状态文件: $STATUS_FILE"
  [ -n "$FAIL" ] && return 1
  return 0
}

# ==============================================================================
# 主流程（云助手执行这段，秒回）：绑定 → 占位符流转 → 启动后台部署
# ==============================================================================
main_deploy() {
  say "===== q2 一键部署 v6.2（加固版）开始 $(date '+%F %T') ====="
  say "日志: $LOG"

  # 2.1 绑定 + 设备注册（无设备码时才做，已绑则跳过）
  NID=$(node_id)
  if [ -z "$NID" ] || ! grep -q "注册状态: 成功" /usr/local/edge/registration_info 2>/dev/null; then
    say "  [2.1] 渠道绑定 + 设备注册（zyy_init_max，5-10 分钟）…"
    if fetch_script /tmp/_bind.sh 20000 300 3 "$OSS/zyy_init/zyy_init_max.sh"; then
      bash /tmp/_bind.sh --ak "$CHAN_AK" --sk "$CHAN_SK" --isp "$ISP" || mark_fail "绑定"
    else
      mark_fail "绑定(zyy_init_max 下载失败:3轮全失败)"
    fi
    NID=$(node_id); say "  nodeID=${NID:-未生成}"
  else
    say "  [2.1] 已绑定，跳过"
  fi

  # ① 先提交业务属性(41/200M) + 占位符流转「服务中」—— 放在绑定之后，新机也立即拿到业务
  say ""; say "===== [1/4] 提交业务(41/200M) + 占位符流转「服务中」====="
  NID=$(node_id)
  if [ -n "$NID" ]; then
    LOC=$(detect_loc)
    # 容器若已起来则带真 SN，否则用占位符（避免重跑时用占位符覆盖真 SN）
    SN_NOW=$(sn_current)
    HOST="$PLACEHOLDER"; [ ${#SN_NOW} -ge 60 ] && HOST="$SN_NOW"
    # submit_nominal 要求节点在 configured 阶段（inService 下提交返回 code:7），先降配
    flow "$NID" "$HOST" "configured" >/dev/null 2>&1
    R2=$(submit_nominal "$NID" "${LOC%%|*}" "${LOC##*|}")
    case "$R2" in
      *'"code":0'*) say "  ✅ 已提交业务属性(41/200M/${ISP})" ;;
      *) say "  ⚠️ 属性提交未成功：$(echo "$R2" | head -c 80)" ;;
    esac
    R=$(flow "$NID" "$HOST" "inService")
    case "$R" in
      *'"code":0'*) say "  ✅ 已流转服务中（业务41/200M已挂 ${HOST:0:16}…，后台部署完成回填真SN）" ;;
      *) say "  ⚠️ 流转未成功：$(echo "$R" | head -c 80)" ;;
    esac
  else
    say "  ⚠️ 仍未取到 nodeID，流转跳过（后台部署完成后重跑本脚本可补）"
  fi

  # ② 启动后台部署（命令立即返回，真进度落 /var/log/ipes_nohup.log）
  say ""; say "===== 启动后台部署（setsid 脱离会话）====="
  # ⚠️ 关键（真实踩坑）：管道执行(`curl … | bash`)时 $0=="bash" 且 BASH_SOURCE 为空，
  #    `setsid "$0" --internal-deploy` 会变成 `bash --internal-deploy`
  #    → bash 报 "--internal-deploy: invalid option" 退出，后台部署【静默不启动】，
  #    日志里只剩一屏 bash 用法，且 deploy.status 永远不写 → 表现为"部署没成功"。
  #    对策：把脚本实体落到磁盘，再用 /bin/bash <文件> --internal-deploy 启动。
  #    ★ v6.1：落盘也走「多源 + 校验」，下载失败不再静默回落。
  #    落盘顺序：① BASH_SOURCE(文件执行场景) ② Q2_SELF_URL 多源自下载(管道场景)
  SELF="/etc/q2/q2_oneclick_v6.self.sh"
  mkdir -p /etc/q2 2>/dev/null
  # ① 文件执行场景：直接复制自身
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -s "${BASH_SOURCE[0]:-}" ]; then
    cp -f "${BASH_SOURCE[0]}" "$SELF" 2>/dev/null
    say "  · 自身落盘(复制 BASH_SOURCE) → $SELF"
  fi
  # ② 管道场景：BASH_SOURCE 为空，改用多源 + 校验自下载
  if [ ! -s "$SELF" ]; then
    say "  · 管道执行无本地路径，多源 + 校验自下载脚本 → $SELF"
    if fetch_script "$SELF" 3000 90 2 \
        "${Q2_DOM}" \
        "https://gh-proxy.com/${Q2_RAW}" \
        "${Q2_RAW}" \
        "${Q2_CDN}"; then
      say "  · 自下载校验通过"
    else
      say "  ❌ 自下载失败（全部源不可用/校验未通过）"
    fi
  fi
  if [ ! -s "$SELF" ]; then
    say "  ⚠️ 仍无法落盘，回落【前台】执行（会阻塞到部署完成，请把云助手超时调到 2400s）"
    internal_deploy
    return $?
  fi
  chmod +x "$SELF" 2>/dev/null
  setsid nohup /bin/bash "$SELF" --internal-deploy </dev/null >>"$NOHUP_LOG" 2>&1 &
  local pid=$!
  sleep 3
  if kill -0 "$pid" 2>/dev/null; then
    say "  ✅ 后台部署已启动（PID=$pid），云助手命令立即返回。"
  else
    say "  ⚠️ 后台进程未存活，回落【前台】执行（会阻塞，请把云助手超时调到 2400s）"
    internal_deploy
    return $?
  fi
  say "     真进度日志: tail -f $NOHUP_LOG"
  say "     验收命令  : grep '==== 总体结果' $STATUS_FILE"
  say "                docker ps --format '{{.Names}} {{.Status}}'"
  say "                docker exec ipes ls /data/happ | grep -c happ   （应 = 9）"
  say "                docker exec ipes sh -c 'ps -ef | grep -c \"[h]app\"'  （应 = 9）"
  say "============ 主流程结束，部署转入后台 $(date '+%F %T') ============"
}

if [ "${1:-}" = "--internal-deploy" ]; then
  exec >>"$NOHUP_LOG" 2>&1
  internal_deploy
  exit $?
fi

main_deploy
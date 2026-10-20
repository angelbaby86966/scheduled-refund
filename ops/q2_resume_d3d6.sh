#!/bin/bash
# ==============================================================================
# 舟翼云 q2 · 外科式续跑（只补没做的：d3 九路 → d4 真SN回填 → d5 保活 → d6 限速）
#
# 用途：v5 全串行部署在云助手超时被杀、停在 [2.3] 时，机台处于半成品状态
#       （已绑定已注册 / docker 已装 / 容器只有 happ.0 一路 / 无真SN / 无保活 / 无限速）。
#       本脚本【只补缺的部分】，绝不重跑绑定、绝不重跑 ecache、绝不碰 /etc/.mac。
#
# 铁律（踩过就炸）：
#   1) 不重跑 zyy_init_max —— 它会重装 agent，甚至重生成 /etc/.mac → 换身份 → 掉量/合并
#   2) 不重跑 ecache_auto_disk_install —— 它会清空 /data*/happ，把已建分片抹掉
#   3) 九路判据只能是「容器内 ls -d /data/happ/happ.* 可见数」+「容器内 happ 进程数」，
#      宿主机建了 9 个目录但容器只挂 1 个是经典假成功
#   4) docker run 的 -v 在创建时固化，docker restart 不会新增挂载 → 必须重建容器
#
# 用法（云助手命令助手，超时可只设 120s，本脚本自己后台化）：
#   export Q2_JWT=<token>
#   curl -fsSL --max-time 60 -o /tmp/q2_resume.sh <本脚本URL>
#   setsid nohup bash /tmp/q2_resume.sh > /var/log/q2_resume.log 2>&1 < /dev/null &
#   tail -f /var/log/q2_resume.log
#
# 环境变量：Q2_JWT（必填）｜Q2_ISP（默认 联通）｜Q2_LIMIT_START/END（默认 23:59/18:25）
# ==============================================================================

OSS="${Q2_OSS:-https://zyy-go.oss-cn-beijing.aliyuncs.com/script}"
ADMIN_API="${Q2_ADMIN_API:-https://admin.zhouyi.top}"
ISP="${Q2_ISP:-联通}"
HAPP_N=9
LIMIT_START="${Q2_LIMIT_START:-23:59}"; LIMIT_END="${Q2_LIMIT_END:-18:25}"

# 凭证：全部外置可覆盖；默认值同 v5（渠道 AK/SK + 后台 HMAC 三件套）
CHAN_AK="${Q2_AK:-06d78b19bd0d9fc0aa300c6d}"
CHAN_SK="${Q2_SK:-16d6c46443308e62bb51f22c074a90ed}"
ADMIN_APPID="${Q2_APPID:-fg5c21pbzfgu6y2s2yqvanvr6uv99drq}"
ADMIN_AK="${Q2_ADMIN_AK:-ja3io44nq2m7hx63fjkpio7s422aksel}"
ADMIN_SK="${Q2_ADMIN_SK:-ydDGuguZ8COcJN4Ztl3Lsic3Z00zGEani8fYOPiYk2XXCuXQ1AHyy7E1sgV4dyDT}"

Q2_JWT_FILE="${Q2_JWT_FILE:-/etc/q2/jwt}"
if [ -z "${Q2_JWT:-}" ] && [ -f "$Q2_JWT_FILE" ]; then
  Q2_JWT="$(tr -d '[:space:]' < "$Q2_JWT_FILE" 2>/dev/null)"
fi
: "${Q2_JWT:?未找到 JWT：请 export Q2_JWT=xxx，或 echo <token> > $Q2_JWT_FILE}"
JWT="$Q2_JWT"

LOG=/tmp/q2_resume_$$.log
touch "$LOG" 2>/dev/null || LOG=/dev/null
exec > >(tee -a "$LOG" 2>/dev/null) 2>&1
say() { echo "[$(date '+%H:%M:%S')] $*"; }
FAIL=""; FAIL_REASON=""
mark_fail() { FAIL="${FAIL} $1"; FAIL_REASON="${FAIL_REASON:+$FAIL_REASON,}$1"; say "  ✗ 失败：$1"; }


# ==============================================================================
# 内嵌「真保活 v2.0」组件（base64，21266 字节，解码后含 docker/容器自愈 + happ 恒定 9 路 + 43B base_info 修复）
# ==============================================================================
EMB_HC_B64='IyEvYmluL2Jhc2gKCiMgSVBFU+WBpeW6t+ajgOafpeiHquWKqOWuieijheiEmuacrO+8iOecn+S/nea0u+eJiCB2Mi4w77yJCiMg
5o+P6L+wOiDoh6rliqjliJvlu7oi55yf5L+d5rS7IuWBpeW6t+ajgOafpeiEmuacrOW5tumFjee9ruWumuaXtuS7u+WKoQojICAg
55yf5L+d5rS7ID0gZG9ja2VyIOiHquaEiCArIOWuueWZqOiHquaEiO+8iHN0YXJ0L+WujOaVtOmHjeW7uu+8iSsg6Lev5pWw5qCh
6aqMICsgaGFwcCDov5vnqIvmgZLlrpogTgojICAgICAgICAgICAgKyDmnI3liqHlgaXlurfmjqLmtLsgKyDpmLLmipYgKyDlhajn
qIvml6DkuqTkupIKIyAgIOKYhSDkuI7ml6fniYjnmoTlhbPplK7lt67lvILvvJrlronoo4Xml7bnlKggZG9ja2VyIGluc3BlY3Qg
5oqK546w572R5a655Zmo55qECiMgICAgIHt7LkNvbmZpZy5JbWFnZX19IOS4juWFqOmDqCBNb3VudHMg54OY54SZ6L+b55Sf5oiQ
55qE5L+d5rS76ISa5pys77yMCiMgICAgIOWuueWZqOiiq+WIoOWQjuWPr+aMieeOsOe9keWPguaVsOmAkOadoemHjeW7uu+8jOiA
jOS4jeaYr+WGmeatu+mVnOWDj+WQjeOAggoKIyDms6jmhI/vvJrmnKzlronoo4XlmajliLvmhI/kuI3kvb/nlKggc2V0IC1lIOKA
lOKAlCDlronoo4Xov4fnqIvopoEi5q+P5q2l5pi+5byP5Yik5patIu+8jAojICAg6YG/5YWN5p+Q5Liq6Z2e5YWz6ZSu5ZG95Luk
5aSx6LSl5bCx5Lit6YCU6YCA5Ye644CB55WZ5LiL5Y2K5aWXIGNyb24v5Y2K5Liq6ISa5pys77yI6YKj5q2j5piv6Z2Z6buY5aSx
6LSl77yJ44CCCnNldCAtdQoKIyDphY3nva7lj5jph48KU0NSSVBUX05BTUU9ImlwZXNfaGVhbHRoX2NoZWNrLnNoIgpTQ1JJUFRf
UEFUSD0iL3Vzci9sb2NhbC9iaW4vJFNDUklQVF9OQU1FIgpMT0dfRklMRT0iL3Zhci9sb2cvaXBlc19oZWFsdGgubG9nIgpDT05U
QUlORVJfTkFNRT0iaXBlcyIKSEFQUF9OPSIke1EyX0hDX0hBUFBfTjotOX0iCkNGRz0iJHtRMl9IQ19DRkc6LS9vcHQvaXBlcy92
YXIvZGIvaXBlcy9oYXBwLWNvbmYvY3VzdG9tLnltbH0iCiMg4piFIOe7hOS7tueJiOacrOWPt++8muS8muWOn+agt+WGmei/m+eU
n+aIkOeahOS/nea0u+iEmuacrO+8iEhDX1ZFUj0ieC55Iu+8ieOAggojICAg6YOo572y6ISa5pys5o2u5q2k5Yik5patIuW3suWu
ieijheeahOS/nea0u+aYr+WQpuWwseaYr+W9k+WJjeeJiOacrCLigJTigJQKIyAgIOaXp+eJiOWBh+S/nea0u+WQjOagt+a7oei2
syLohJrmnKzlnKggKyBjcm9uIOaciSLvvIzoi6XkuI3nnIvniYjmnKzlsLHkvJrmsLjov5zot7Pov4flronoo4XjgIEKIyAgIOec
n+S/nea0u+WboOatpOijheS4jeS4iuOAguWNh+e6pyBIQ19WRVIg5piv5by65Yi26YeN6KOF55qE5ZSv5LiA5byA5YWz44CCCkhD
X1ZFUj0iMi4wIgoKIyDpopzoibLlrprkuYnvvIjnlKggJCcuLi4nIEFOU0ktQyDlvJXlj7fnm7TmjqXlvpfliLDnnJ/lrp4gRVND
IOWtl+iKgu+8mgojICAgcHJpbnRmICclcycg5LiN5Lya6Kej6YeK5Y+C5pWw6YeM55qEIFwwMzMg6L2s5LmJ77yM6Iul55So5pmu
6YCa5Y2V5byV5Y+35a2Y5a2X6Z2i6YeP5Lya5Y6f5qC35omT5Y2w5Ye6ICJcMDMzWzA7MzJtIu+8iQpSRUQ9JCdcMDMzWzA7MzFt
JwpHUkVFTj0kJ1wwMzNbMDszMm0nCllFTExPVz0kJ1wwMzNbMTszM20nCk5DPSQnXDAzM1swbScgIyBObyBDb2xvcgoKIyAtLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KIyDm
l6Xlv5flh73mlbAKIyDimIUg5a6e546w57qm5a6a77ya5LiA5b6LIHByaW50ZiArIOWtl+mdoumHj+agvOW8j+S4siArICVzIOS8
oOWPgu+8jOemgeatoiAi5Lit5paHJHZhcuS4reaWhyIg5Y+M5byV5Y+35YaF5o+S5YC844CCCiMgICDljp/lm6DvvJptYWNPUyDo
h6rluKYgYmFzaCAzLjIg5Zyo44CM5Y+M5byV5Y+35YaFIG11bHRpYnl0ZSDlrZfpnaLph4/ntKfpgrvlj5jph4/mj5LlgLzjgI3n
moTlhpnms5XkuIoKIyAgIOWtmOWcqOWtl+iKgumUmeS9jSBidWcg4oCU4oCUIOWunua1i+WPmOmHj+WAvOiiq+aVtOauteWQnuaO
ie+8iGByYz0kcmNgIOi+k+WHuuaIkCBgcmM9YO+8ie+8jOebuOmCu+axieWtlwojICAg6aaW5a2X6IqC5Lii5aSx5a+86Ie06Z2e
5rOVIFVURi0444CCcHJpbnRmIOW9ouW8j+WcqCBiYXNoIDMuMiDkuI4gNC54IOS4iuWdh+ato+ehruOAggojICAg6LCD55So57qm
5a6a77yabG9nIDzmoLzlvI/kuLI+IFvlj4LmlbAuLi5d77yb5Y+C5pWw5Liq5pWw6aG75LiO5qC85byP5Liy5LitICVzIOS4quaV
sOS4gOiHtO+8mwojICAg5Y+q5pyJ5LiA5Liq5Y+C5pWw5pe25oyJ5a2X6Z2i6L6T5Ye677yI5Zug5q2k5raI5oGv6YeM5Y+v5a6J
5YWo5Ye6546wICXvvInjgIIKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0KX2hjX21zZygpIHsKICAgIGlmIFsgJCMgLWVxIDAgXTsgdGhlbiByZXR1cm4gMDsgZmkKICAg
IGlmIFsgJCMgLWVxIDEgXTsgdGhlbiBwcmludGYgJyVzJyAiJDEiOyByZXR1cm4gMDsgZmkKICAgIHByaW50ZiAtLSAiJEAiCn0K
CmxvZygpIHsKICAgIGxvY2FsIHRzCiAgICB0cz0kKGRhdGUgJyslWS0lbS0lZCAlSDolTTolUycpCiAgICBwcmludGYgJyVzWyVz
XSVzICVzXG4nICIkR1JFRU4iICIkdHMiICIkTkMiICIkKF9oY19tc2cgIiRAIikiCn0KCmVycm9yKCkgewogICAgbG9jYWwgdHMK
ICAgIHRzPSQoZGF0ZSAnKyVZLSVtLSVkICVIOiVNOiVTJykKICAgIHByaW50ZiAnJXNbJXNdIEVSUk9SOiVzICVzXG4nICIkUkVE
IiAiJHRzIiAiJE5DIiAiJChfaGNfbXNnICIkQCIpIgp9Cgp3YXJuaW5nKCkgewogICAgbG9jYWwgdHMKICAgIHRzPSQoZGF0ZSAn
KyVZLSVtLSVkICVIOiVNOiVTJykKICAgIHByaW50ZiAnJXNbJXNdIFdBUk5JTkc6JXMgJXNcbicgIiRZRUxMT1ciICIkdHMiICIk
TkMiICIkKF9oY19tc2cgIiRAIikiCn0KCiMg5qOA5p+lcm9vdOadg+mZkApjaGVja19yb290KCkgewogICAgaWYgW1sgJEVVSUQg
LW5lIDAgXV07IHRoZW4KICAgICAgICBlcnJvciAi5q2k6ISa5pys6ZyA6KaBcm9vdOadg+mZkOi/kOihjO+8jOivt+S9v+eUqCBz
dWRvIOaJp+ihjCIKICAgICAgICBleGl0IDEKICAgIGZpCn0KCiMg5qOA5p+lRG9ja2Vy5piv5ZCm5a6J6KOFCmNoZWNrX2RvY2tl
cigpIHsKICAgIGlmICEgY29tbWFuZCAtdiBkb2NrZXIgJj4vZGV2L251bGw7IHRoZW4KICAgICAgICBlcnJvciAiRG9ja2VyIOac
quWuieijhe+8jOivt+WFiOWuieijhURvY2tlciIKICAgICAgICBleGl0IDEKICAgIGZpCiAgICBsb2cgIkRvY2tlciDmo4Dmn6Xp
gJrov4ciCn0KCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tCiMg4piFIOS7jueOsOe9keWuueWZqOeDmOeEmemHjeW7uuWPguaVsO+8iOabv+S7o+aXp+eJiOeahCByZWFk
IC1wIOS6pOS6ku+8iQojICAgLSDlrrnlmajlnKjot5Eg4oaSIOaKkyB7ey5Db25maWcuSW1hZ2V9fSArIOWFqOmDqCBNb3VudHMo
LXYgc3JjOmRzdCkgKyBOZXR3b3JrTW9kZQojICAgLSDlrrnlmajkuI3lnKgg4oaSIOeUqOeOr+Wig+WPmOmHjy/pu5jorqTlgLzl
hZzlupXvvIjkuI3pmLvloZ7lronoo4XvvIwgY3JvbiDmr4/liIbpkp/kvJroh6rmhIjvvIkKIyAgIC0g5YWo56iL5peg5Lqk5LqS
77yM5LqR5Yqp5omLL2Nyb24g5LiL5LiN5Lya5oyC5q27CiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCmNhcHR1cmVfY29udGFpbmVyX3BhcmFtcygpIHsKICAgIGlmIGRv
Y2tlciBpbnNwZWN0ICIkQ09OVEFJTkVSX05BTUUiID4vZGV2L251bGwgMj4mMTsgdGhlbgogICAgICAgIEJBS0VEX0lNRz0kKGRv
Y2tlciBpbnNwZWN0ICIkQ09OVEFJTkVSX05BTUUiIC0tZm9ybWF0ICd7ey5Db25maWcuSW1hZ2V9fScgMj4vZGV2L251bGwgfHwg
dHJ1ZSkKICAgICAgICBCQUtFRF9ORVQ9JChkb2NrZXIgaW5zcGVjdCAiJENPTlRBSU5FUl9OQU1FIiAtLWZvcm1hdCAne3suSG9z
dENvbmZpZy5OZXR3b3JrTW9kZX19JyAyPi9kZXYvbnVsbCB8fCB0cnVlKQogICAgICAgICMgTW91bnRzIOi9rOaIkCAiLXYgc3Jj
OmRzdCIg5b2i5byP77yM5bC+6YOo5bim5LiA5Liq56m65qC85L6/5LqO55u05o6l5ou85o6lCiAgICAgICAgQkFLRURfTUFSR1M9
JChkb2NrZXIgaW5zcGVjdCAiJENPTlRBSU5FUl9OQU1FIiBcCiAgICAgICAgICAgIC0tZm9ybWF0ICd7e3JhbmdlIC5Nb3VudHN9
fS12IHt7LlNvdXJjZX19Ont7LkRlc3RpbmF0aW9ufX0ge3tlbmR9fScgMj4vZGV2L251bGwgfHwgdHJ1ZSkKICAgICAgICBsb2cg
J+W3suS7jueOsOe9keWuueWZqOeDmOeEmeWPguaVsO+8mklNRz0lcycgIiR7QkFLRURfSU1HOi3mnKrlj5bliLB9IgogICAgICAg
IGxvZyAnICDmjILovb3mlbDvvJolcyAgTmV0d29ya01vZGU9JXMnIFwKICAgICAgICAgICAgIiQoZWNobyAiJEJBS0VEX01BUkdT
IiB8IGdyZXAgLW8gJ1wtdiAnIHwgd2MgLWwgfCB0ciAtZCAnICcpIiAiJHtCQUtFRF9ORVQ6LeacquWPluWIsH0iCiAgICBlbHNl
CiAgICAgICAgd2FybmluZyAn5pyq5om+5Yiw5a655ZmoICVz77yM5pS555So6buY6K6kL+eOr+Wig+WPmOmHj+WPguaVsO+8iOWu
ieijheS4jemYu+Whnu+8jGNyb24g5Lya6Ieq5oSI77yJJyAiJENPTlRBSU5FUl9OQU1FIgogICAgZmkKCiAgICAjIOWFnOW6lem7
mOiupOWAvO+8iOWPr+iiq+eOr+Wig+WPmOmHj+imhueblu+8iQogICAgQkFLRURfSU1HPSIke1EyX0hDX0lNRzotJHtCQUtFRF9J
TUc6LWNjci5jY3MudGVuY2VudHl1bi5jb20venl5X2Nsb3VkL2lwZXMtbGludXgtYW1kNjQteW91a2FpLWxhdGVzdDpsYXRlc3R9
fSIKICAgIEJBS0VEX05FVD0iJHtRMl9IQ19ORVQ6LSR7QkFLRURfTkVUOi1ob3N0fX0iCiAgICBpZiBbIC16ICIke0JBS0VEX01B
UkdTOi19IiBdOyB0aGVuCiAgICAgICAgQkFLRURfTUFSR1M9IiR7UTJfSENfTUFSR1M6LX0iCiAgICBmaQogICAgIyDku43kuLrn
qbog4oaSIOaMiSA5IOi3r+agh+WHhue7k+aehOeUn+aIkO+8iOS4jumDqOe9suiEmuacrCB2Ni4yLjEg55qEIGRvY2tlciBydW4g
5LiA6Ie077yJCiAgICBpZiBbIC16ICIkQkFLRURfTUFSR1MiIF07IHRoZW4KICAgICAgICBsb2NhbCBuCiAgICAgICAgZm9yIG4g
aW4gJChzZXEgMCAkKChIQVBQX04tMSkpKTsgZG8KICAgICAgICAgICAgQkFLRURfTUFSR1M9IiRCQUtFRF9NQVJHUyAtdiAvZGF0
YS9oYXBwL2hhcHAuJG4vaGRhdGEvY2FjaGU6L2RhdGEvaGFwcC9oYXBwLiRuL2hkYXRhL2NhY2hlIgogICAgICAgICAgICBCQUtF
RF9NQVJHUz0iJEJBS0VEX01BUkdTIC12IC9kYXRhL2hhcHAvaGFwcC4kbi9oZGF0YS9jb25maWc6L2RhdGEvaGFwcC9oYXBwLiRu
L2hkYXRhL2NvbmZpZyIKICAgICAgICAgICAgQkFLRURfTUFSR1M9IiRCQUtFRF9NQVJHUyAtdiAvZGF0YS9oYXBwL2hhcHAuJG4v
eHljb3VsZF9iYXNlX2luZm86L2RhdGEvaGFwcC9oYXBwLiRuL3h5Y291bGRfYmFzZV9pbmZvIgogICAgICAgIGRvbmUKICAgICAg
ICBsb2cgJ+W3suaMiSAlcyDot6/moIflh4bnu5PmnoTnlJ/miJDmjILovb3lj4LmlbAnICIkSEFQUF9OIgogICAgZmkKfQoKIyDl
iJvlu7rlgaXlurfmo4Dmn6XohJrmnKzvvIjnnJ/kv53mtLvvvIkKY3JlYXRlX2hlYWx0aF9zY3JpcHQoKSB7CiAgICBsb2cgIuWI
m+W7uuecn+S/nea0u+WBpeW6t+ajgOafpeiEmuacrC4uLiIKCiAgICAjIDEpIOWktOmDqOWPguaVsO+8mueUseWuieijheaXtueD
mOeEme+8jOeUqOmdnuW8leWPtyBoZXJlZG9jIOWxleW8gAogICAgIyAyKSDkuLvkvZPpgLvovpHvvJrnlKjlvJXlj7cgaGVyZWRv
YyDljp/moLfokL3nm5jvvIjlhoXpg6ggJCDkuI3ooqvlronoo4XlmajlsZXlvIDvvIkKICAgIHsKICAgICAgICBwcmludGYgJyMh
L2Jpbi9iYXNoXG4nCiAgICAgICAgcHJpbnRmICcjID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PVxuJwogICAgICAgIHByaW50ZiAnIyBJUEVTIOecn+S/nea0u++8iOiH
quWKqOeUn+aIkOS6jiAlc++8jOivt+WLv+aJi+W3peS/ruaUue+8m+imgeaUueivt+aUuSBpbnN0YWxsZXIg5ZCO6YeN6KOF77yJ
XG4nICIkKGRhdGUgJyslRiAlVCcpIgogICAgICAgIHByaW50ZiAnIyAgIFMxIGRvY2tlciDoh6rmhIgg4oaSIFMyIOWuueWZqOiH
quaEiChzdGFydC/lrozmlbTph43lu7opIOKGkiBTMyBjdXN0b20ueW1sIOi3r+aVsOagoemqjFxuJwogICAgICAgIHByaW50ZiAn
IyAgIOKGkiBTNCBoYXBwIOi/m+eoi+aBkuWumiBOIOKGkiBTNSDmnI3liqHlgaXlurfmjqLmtLvvvJtTNiDpmLLmipbvvIxTNyDl
hajnqIvml6DkuqTkupJcbicKICAgICAgICBwcmludGYgJyMgICDph43lu7rlj4LmlbDnlLEgaW5zdGFsbGVyIOS7jueOsOe9keWu
ueWZqCBkb2NrZXIgaW5zcGVjdCDng5jnhJnvvIzli7/miYvmlLlcbicKICAgICAgICBwcmludGYgJyMgPT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09XG4nCiAgICAgICAg
cHJpbnRmICdDT05UQUlORVJfTkFNRT0iaXBlcyJcbicKICAgICAgICBwcmludGYgJ0hFQUxUSF9DT01NQU5EPSIuL2Jpbi9pcGVz
IGhlYWx0aCJcbicKICAgICAgICBwcmludGYgJ1NUQVJUX0NPTU1BTkQ9Ii4vYmluL2lwZXMgc3RhcnQiXG4nCiAgICAgICAgcHJp
bnRmICdTVE9QX0NPTU1BTkQ9Ii4vYmluL2lwZXMgc3RvcCJcbicKICAgICAgICBwcmludGYgJ0xPR19GSUxFPSIvdmFyL2xvZy9p
cGVzX2hlYWx0aC5sb2ciXG4nCiAgICAgICAgIyBIQ19WRVIg5piv57uZ6YOo572y6ISa5pysIGdyZXAg5qCh6aqM55So55qE54mI
5pys5qCH6K6w77yM5pys6ISa5pys6Ieq6Lqr5LiN5byV55So5a6DCiAgICAgICAgcHJpbnRmICcjIHNoZWxsY2hlY2sgZGlzYWJs
ZT1TQzIwMzQgICMgSENfVkVSIOaYr+eJiOacrOagh+iusO+8jOeUsemDqOe9suiEmuacrCBncmVwIOagoemqjO+8jOacrOiEmuac
rOiHqui6q+S4jeW8leeUqFxuJwogICAgICAgIHByaW50ZiAnSENfVkVSPSIlcyJcbicgIiRIQ19WRVIiCiAgICAgICAgcHJpbnRm
ICdIQVBQX049JXNcbicgIiRIQVBQX04iCiAgICAgICAgcHJpbnRmICdDRkc9IiVzIlxuJyAiJENGRyIKICAgICAgICBwcmludGYg
J0lNRz0iJXMiXG4nICIkQkFLRURfSU1HIgogICAgICAgIHByaW50ZiAnTkVUTU9ERT0iJXMiXG4nICIkQkFLRURfTkVUIgogICAg
ICAgIHByaW50ZiAnTUFSR1M9IiVzIlxuJyAiJEJBS0VEX01BUkdTIgogICAgICAgIHByaW50ZiAnUkVTRVRfU1RBTVA9Ii90bXAv
aXBlc19oY19sYXN0X3Jlc2V0IlxuJwogICAgICAgIHByaW50ZiAnUkVTRVRfREVCT1VOQ0U9MzYwMFxuJwogICAgICAgIGNhdCA8
PCdIQ0VPRicKCiMgc2hlbGxjaGVjayBkaXNhYmxlPVNDMjA4NiAgIyDkuIvmlrkgSEVBTFRIL1NUQVJUL1NUT1BfQ09NTUFORCDk
uI4gTUFSR1Mg6ZyA6KaB5YiG6K+N5bGV5byA77yM5bGe5Yi75oSP6KGM5Li6CgojIC0tLS0g5pel5b+X77yI5Y+q5YaZ5paH5Lu2
77yMY3JvbiDkuIvkuI3miZPlsY/vvIzpgb/lhY3pgq7ku7bovbDngrjvvIktLS0tCiMg5ZCMIGluc3RhbGxlcu+8mnByaW50ZiAr
IOWtl+mdoumHj+agvOW8j+S4siArICVzIOS8oOWPgu+8jOinhOmBvyBiYXNoIDMuMiBtdWx0aWJ5dGUg5o+S5YC86ZSZ5L2NIGJ1
ZwpfaGNfbXNnKCkgewogICAgaWYgWyAkIyAtZXEgMCBdOyB0aGVuIHJldHVybiAwOyBmaQogICAgaWYgWyAkIyAtZXEgMSBdOyB0
aGVuIHByaW50ZiAnJXMnICIkMSI7IHJldHVybiAwOyBmaQogICAgcHJpbnRmIC0tICIkQCIKfQpsb2coKSB7CiAgICBsb2NhbCB0
cwogICAgdHM9JChkYXRlICcrJVktJW0tJWQgJUg6JU06JVMnKQogICAgcHJpbnRmICdbJXNdICVzXG4nICIkdHMiICIkKF9oY19t
c2cgIiRAIikiID4+ICIkTE9HX0ZJTEUiIDI+L2Rldi9udWxsCn0KZXJyb3IoKSB7CiAgICBsb2NhbCB0cwogICAgdHM9JChkYXRl
ICcrJVktJW0tJWQgJUg6JU06JVMnKQogICAgcHJpbnRmICdbJXNdIEVSUk9SOiAlc1xuJyAiJHRzIiAiJChfaGNfbXNnICIkQCIp
IiA+PiAiJExPR19GSUxFIiAyPi9kZXYvbnVsbAp9Cndhcm5pbmcoKSB7CiAgICBsb2NhbCB0cwogICAgdHM9JChkYXRlICcrJVkt
JW0tJWQgJUg6JU06JVMnKQogICAgcHJpbnRmICdbJXNdIFdBUk5JTkc6ICVzXG4nICIkdHMiICIkKF9oY19tc2cgIiRAIikiID4+
ICIkTE9HX0ZJTEUiIDI+L2Rldi9udWxsCn0KCiMgLS0tLSDorqHmlbDlj6PlvoTkuI7lhajnur/pqozmlLbkuIDoh7QgLS0tLQpo
YXBwX3Byb2NfY250KCkgewogICAgZG9ja2VyIGV4ZWMgIiRDT05UQUlORVJfTkFNRSIgc2ggLWMgJ3BzIC1lZiB8IGdyZXAgLWMg
IltoXWFwcCInIDI+L2Rldi9udWxsIHwgdHIgLWQgJ1xyJwp9CmNvbnRhaW5lcl9ydW5uaW5nKCkgewogICAgZG9ja2VyIHBzIC0t
Zm9ybWF0ICd7ey5OYW1lc319JyAyPi9kZXYvbnVsbCB8IGdyZXAgLXEgIl4ke0NPTlRBSU5FUl9OQU1FfSQiCn0KCiMgLS0tLSBT
NiDpmLLmipbvvJrph43nva7liqjkvZzmiJDlip/lkI7miZPmiLPvvIwzNjAwcyDlhoXkuI3ph43lpI3ph43nva7vvIhjcm9uIOav
j+WIhumSn+i3ke+8jOS4jemYsuaKluS8muWPjeWkjeaWrea1ge+8iS0tLS0KZGVib3VuY2Vfb2soKSB7CiAgICBpZiBbICEgLWYg
IiRSRVNFVF9TVEFNUCIgXTsgdGhlbiByZXR1cm4gMDsgZmkKICAgIGxvY2FsIGxhc3Qgbm93IGFnZQogICAgbGFzdD0kKHN0YXQg
LWMgJVkgIiRSRVNFVF9TVEFNUCIgMj4vZGV2L251bGwgfHwgZWNobyAwKQogICAgbm93PSQoZGF0ZSArJXMpCiAgICBhZ2U9JCgo
IG5vdyAtICR7bGFzdDotMH0gKSkKICAgIFsgIiRhZ2UiIC1nZSAiJFJFU0VUX0RFQk9VTkNFIiBdCn0KbWFya19yZXNldCgpIHsK
ICAgIGRhdGUgKyVzID4gIiRSRVNFVF9TVEFNUCIgMj4vZGV2L251bGwKICAgIGxvZyAnUzYg5bey6K6w5b2V6YeN572u5pe26Ze0
5oiz77yaJXPvvIglc3Mg5YaF5LiN6YeN5aSN6YeN572u77yJJyAiJFJFU0VUX1NUQU1QIiAiJFJFU0VUX0RFQk9VTkNFIgp9Cgoj
IC0tLS0gUzEgZG9ja2VyIOWuiOaKpOi/m+eoi+iHquaEiO+8iENlbnRPUzfvvJpzeXN0ZW1jdGwg5LyY5YWI77yM5aSx6LSl5Zue
6JC9IHNlcnZpY2XvvIktLS0tCnMxX2RvY2tlcl9zZWxmaGVhbCgpIHsKICAgIGlmIGRvY2tlciBpbmZvID4vZGV2L251bGwgMj4m
MTsgdGhlbiByZXR1cm4gMDsgZmkKICAgIHdhcm5pbmcgIlMxIGRvY2tlciDlrojmiqTov5vnqIvkuI3lj6/nlKjvvIzlsJ3or5Xo
h6rmhIjigKYiCiAgICBzeXN0ZW1jdGwgc3RhcnQgZG9ja2VyID4vZGV2L251bGwgMj4mMSB8fCBzZXJ2aWNlIGRvY2tlciBzdGFy
dCA+L2Rldi9udWxsIDI+JjEgXAogICAgICAgIHx8IHdhcm5pbmcgIlMxIHN5c3RlbWN0bC9zZXJ2aWNlIOWdh+acquiDveWQr+WK
qCBkb2NrZXIiCiAgICBsb2NhbCBpCiAgICBmb3IgaSBpbiAkKHNlcSAxIDEyKTsgZG8KICAgICAgICBpZiBkb2NrZXIgaW5mbyA+
L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgICAgICAgICAgbG9nICdTMSBkb2NrZXIg6Ieq5oSI5oiQ5Yqf77yI56ysICVzIOasoeaO
oua1i++8jOe6piAlc3PvvIknICIkaSIgIiQoKGkqNSkpIgogICAgICAgICAgICByZXR1cm4gMAogICAgICAgIGZpCiAgICAgICAg
c2xlZXAgNQogICAgZG9uZQogICAgZXJyb3IgIlMxIGRvY2tlciDoh6rmhIjlpLHotKXvvIjnrYnlvoXnuqYgNjBzIOS7jeS4jeWP
r+eUqO+8iSIKICAgIHJldHVybiAxCn0KCiMgLS0tLSDlrrnlmajlrozmlbTph43lu7rvvJrkuI7pg6jnvbLohJrmnKwgdjYuMi4x
IOeahCBkb2NrZXIgcnVuIOmAkOWPguaVsOS4gOiHtCAtLS0tCiMgc2hlbGxjaGVjayBkaXNhYmxlPVNDMjA4Ngpjb250YWluZXJf
cmVidWlsZCgpIHsKICAgIGxvZyAn5a655Zmo6YeN5bu677yaSU1HPSVzICBORVRNT0RFPSVzJyAiJElNRyIgIiRORVRNT0RFIgog
ICAgbG9nICflrrnlmajph43lu7rvvJpNQVJHUz0lcycgIiRNQVJHUyIKICAgIGxvY2FsIG91dCByYwogICAgb3V0PSQoZG9ja2Vy
IHJ1biAtZCAtLXJlc3RhcnQ9YWx3YXlzIC0tbmFtZT0iJENPTlRBSU5FUl9OQU1FIiAtLW5ldHdvcms9IiRORVRNT0RFIiAkTUFS
R1MgXAogICAgICAgIC12ICIkQ0ZHOi9hcHAvaXBlcy92YXIvZGIvaXBlcy9oYXBwLWNvbmYvY3VzdG9tLnltbCIgXAogICAgICAg
ICIkSU1HIiBzaCAtYyAnL2FwcC9pcGVzL2Jpbi9pcGVzIHN0YXJ0ICYmIHRhaWwgLWYgL2Rldi9udWxsJyAyPiYxKQogICAgcmM9
JD8KICAgIGlmIFsgIiRyYyIgPSAiMCIgXTsgdGhlbgogICAgICAgIGxvZyAi5a655Zmo6YeN5bu65oiQ5YqfIgogICAgICAgIHJl
dHVybiAwCiAgICBmaQogICAgZXJyb3IgJ+WuueWZqOmHjeW7uuWksei0pe+8iHJjPSVz77yJ77yaJXMnICIkcmMiICIkb3V0Igog
ICAgcmV0dXJuIDEKfQoKIyAtLS0tIFMyIOWuueWZqOiHquaEiO+8muWcqOi3keKGkui3s+i/h++8m+WBnOS6huKGkmRvY2tlciBz
dGFydO+8m+S4jeWtmOWcqOKGkuWujOaVtOmHjeW7uiAtLS0tCnMyX2NvbnRhaW5lcl9zZWxmaGVhbCgpIHsKICAgIGlmIGNvbnRh
aW5lcl9ydW5uaW5nOyB0aGVuIHJldHVybiAwOyBmaQogICAgd2FybmluZyAnUzIg5a655ZmoICVzIOacquWcqOi/kOihjO+8jOi/
m+WFpeiHquaEiOKApicgIiRDT05UQUlORVJfTkFNRSIKICAgIGlmIGRvY2tlciBpbnNwZWN0ICIkQ09OVEFJTkVSX05BTUUiID4v
ZGV2L251bGwgMj4mMTsgdGhlbgogICAgICAgIGxvZyAiUzIg5a655Zmo5a2Y5Zyo5L2G5bey5YGc5q2i77yM5YWI5bCd6K+VIGRv
Y2tlciBzdGFydCIKICAgICAgICBpZiBkb2NrZXIgc3RhcnQgIiRDT05UQUlORVJfTkFNRSIgPi9kZXYvbnVsbCAyPiYxOyB0aGVu
CiAgICAgICAgICAgIGxvZyAiUzIgZG9ja2VyIHN0YXJ0IOaIkOWKnyIKICAgICAgICAgICAgcmV0dXJuIDAKICAgICAgICBmaQog
ICAgICAgIHdhcm5pbmcgIlMyIGRvY2tlciBzdGFydCDlpLHotKXvvIzmlLnkuLrlrozmlbTph43lu7oiCiAgICBlbHNlCiAgICAg
ICAgbG9nICJTMiDlrrnlmajkuI3lrZjlnKjvvIjooqvliKAv5pyq5Yib5bu677yJ77yM5omn6KGM5a6M5pW06YeN5bu6IgogICAg
ZmkKICAgIGNvbnRhaW5lcl9yZWJ1aWxkCn0KCiMgLS0tLSBTMyBjdXN0b20ueW1sIOi3r+aVsOagoemqjO+8miE9IE4g5YiZ5oyJ
5ZCM5qy+6YC76L6R6YeN5YaZ77yI5L+d55WZIHJlZ19pc3DvvIxhcmdzIOWGmSBOIOihjO+8ie+8jOWFiOWkh+S7vSAtLS0tCnMz
X2NvbmZpZ19zZWxmaGVhbCgpIHsKICAgIGlmIFsgISAtZiAiJENGRyIgXTsgdGhlbgogICAgICAgIHdhcm5pbmcgJ1MzICVzIOS4
jeWtmOWcqO+8jOi3s+i/h+i3r+aVsOagoemqjCcgIiRDRkciCiAgICAgICAgcmV0dXJuIDEKICAgIGZpCiAgICBsb2NhbCBjbnQK
ICAgIGNudD0kKGdyZXAgLWNFICJeICAtIC9kYXRhL2hhcHAvaGFwcFwuWzAtOV0rJCIgIiRDRkciIDI+L2Rldi9udWxsIHwgdHIg
LWQgJ1xyJykKICAgIGlmIFsgIiR7Y250Oi0wfSIgPSAiJEhBUFBfTiIgXTsgdGhlbgogICAgICAgIHJldHVybiAwCiAgICBmaQog
ICAgd2FybmluZyAnUzMgY3VzdG9tLnltbCDot6/mlbA9JXPvvIjmnJ/mnJsgJXPvvInvvIzph43lhpnigKYnICIke2NudDotMH0i
ICIkSEFQUF9OIgogICAgbG9jYWwgdHMgdG1wIG5jbnQKICAgIHRzPSQoZGF0ZSArJVklbSVkJUglTSVTKQogICAgY3AgLXAgIiRD
RkciICIkQ0ZHLmJhay4kdHMiIDI+L2Rldi9udWxsIHx8IHdhcm5pbmcgJ1MzIOWkh+S7veWksei0pe+8miVzJyAiJENGRy5iYWsu
JHRzIgogICAgdG1wPSQobWt0ZW1wKQogICAgeyBlY2hvICIjIHEyIGhhcHB5JHtIQVBQX059ICQoZGF0ZSAnKyVGICVUJykiOyBl
Y2hvICJhcmdzOiIKICAgICAgZm9yIG4gaW4gJChzZXEgMCAkKChIQVBQX04tMSkpKTsgZG8gZWNobyAiICAtIC9kYXRhL2hhcHAv
aGFwcC4kbiI7IGRvbmUKICAgICAgZ3JlcCAtRSAnXnJlZ19pc3A6JyAiJENGRyIgMj4vZGV2L251bGw7IH0gPiAiJHRtcCIKICAg
IG5jbnQ9JChncmVwIC1jRSAiXiAgLSAvZGF0YS9oYXBwL2hhcHBcLlswLTldKyQiICIkdG1wIiAyPi9kZXYvbnVsbCB8IHRyIC1k
ICdccicpCiAgICBpZiBbICIke25jbnQ6LTB9IiAhPSAiJEhBUFBfTiIgXTsgdGhlbgogICAgICAgIHJtIC1mICIkdG1wIgogICAg
ICAgIGVycm9yICdTMyDph43lhpnlkI7mnaHmlbDlvILluLgoJXMgIT0gJXMp77yM5L+d55WZ546w5Zy677yM5pyq5pS55Yqo6YWN
572uJyAiJHtuY250Oi0wfSIgIiRIQVBQX04iCiAgICAgICAgcmV0dXJuIDEKICAgIGZpCiAgICBpZiBjcCAtcCAiJHRtcCIgIiRD
RkciIDI+L2Rldi9udWxsOyB0aGVuCiAgICAgICAgcm0gLWYgIiR0bXAiCiAgICAgICAgbG9nICdTMyBjdXN0b20ueW1sIOW3sumH
jeWGmeS4uiAlcyDot6/vvIjlpIfku70gJXPvvIknICIkSEFQUF9OIiAiJENGRy5iYWsuJHRzIgogICAgICAgIHJldHVybiAyICAg
IyAyID0g6YWN572u5bey5Y+Y5pu077yM6ZyA6KaB6YeN5bu65a655Zmo5omN55Sf5pWICiAgICBmaQogICAgcm0gLWYgIiR0bXAi
CiAgICBlcnJvciAnUzMg5YaZ5YWlICVzIOWksei0pe+8jOS/neeVmeeOsOWcuicgIiRDRkciCiAgICByZXR1cm4gMQp9CgojIC0t
LS0gUzQgaGFwcCDov5vnqIvmgZLlrpogTu+8iOWPjOWQke+8mjxOIOaLieWIsCBO77yMPk4g54Gt5YiwIE7vvIktLS0tCnM0X2hh
cHBfY29uc3RhbnQoKSB7CiAgICBsb2NhbCBjbnQKICAgIGNudD0kKGhhcHBfcHJvY19jbnQpCiAgICBpZiBbICIke2NudDotMH0i
ID0gIiRIQVBQX04iIF07IHRoZW4KICAgICAgICByZXR1cm4gMAogICAgZmkKICAgIHdhcm5pbmcgJ1M0IGhhcHAg6L+b56iLPSVz
77yI5pyf5pyb5oGS5a6aICVz77yJ77yM6L+b5YWl6YeN572u4oCmJyAiJHtjbnQ6LTB9IiAiJEhBUFBfTiIKICAgICMg5YWI5oqT
5b2T5YmNIGhhcHAgUElEIOWIl+ihqO+8muihpeadgOWPquadgOaKk+WIsOeahCBQSUTvvIzkuKXnpoEgcGtpbGwgLWYgaGFwcCDk
uYvnsbvmjInlkI3lrZfpgJrmnYDvvIjpgb/lhY3or6/kvKQgbWFzdGVy77yJCiAgICBsb2NhbCBwaWRzCiAgICBwaWRzPSQoZG9j
a2VyIGV4ZWMgIiRDT05UQUlORVJfTkFNRSIgc2ggLWMgInBzIC1lZiB8IGdyZXAgJ1toXWFwcCcgfCBhd2sgJ3twcmludCBcJDJ9
JyIgMj4vZGV2L251bGwgfCB0ciAtZCAnXHInKQogICAgbG9nICdTNCDmipPlj5bliLAgaGFwcCBQSUQg5YiX6KGo77yaJXMnICIk
e3BpZHM6Le+8iOepuu+8iX0iCiAgICBsb2cgJ1M0IOaJp+ihjCBzdG9w77yaJXMnICIkU1RPUF9DT01NQU5EIgogICAgIyBzaGVs
bGNoZWNrIGRpc2FibGU9U0MyMDg2ICAjIOWRveS7pOWPmOmHj+mcgOWIhuivjeWxleW8gO+8iC4vYmluL2lwZXMgPOWtkOWRveS7
pD7vvIkKICAgIGRvY2tlciBleGVjICIkQ09OVEFJTkVSX05BTUUiICRTVE9QX0NPTU1BTkQgPi9kZXYvbnVsbCAyPiYxIHx8IHdh
cm5pbmcgIlM0IHN0b3Ag6L+U5Zue6Z2eIDAiCiAgICBzbGVlcCA1CiAgICBsb2NhbCBwCiAgICBmb3IgcCBpbiAkcGlkczsgZG8K
ICAgICAgICBkb2NrZXIgZXhlYyAiJENPTlRBSU5FUl9OQU1FIiBraWxsIC05ICIkcCIgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWUK
ICAgIGRvbmUKICAgIGxvZyAiUzQg5bey5a+55oqT5Y+W5Yiw55qE5bm45a2YIFBJRCDooaXmnYDlrozmiJDvvIjku4XnlKjmipPl
j5bliJfooajvvIzmnKrmjInlkI3lrZfpgJrmnYDvvIkiCiAgICBsb2cgJ1M0IOaJp+ihjCBzdGFydO+8miVzJyAiJFNUQVJUX0NP
TU1BTkQiCiAgICAjIHNoZWxsY2hlY2sgZGlzYWJsZT1TQzIwODYgICMg5ZG95Luk5Y+Y6YeP6ZyA5YiG6K+N5bGV5byA77yILi9i
aW4vaXBlcyA85a2Q5ZG95LukPu+8iQogICAgZG9ja2VyIGV4ZWMgIiRDT05UQUlORVJfTkFNRSIgJFNUQVJUX0NPTU1BTkQgPi9k
ZXYvbnVsbCAyPiYxIHx8IHdhcm5pbmcgIlM0IHN0YXJ0IOi/lOWbnumdniAwIgogICAgbG9jYWwgaQogICAgZm9yIGkgaW4gJChz
ZXEgMSAxMik7IGRvCiAgICAgICAgY250PSQoaGFwcF9wcm9jX2NudCkKICAgICAgICBpZiBbICIke2NudDotMH0iID0gIiRIQVBQ
X04iIF07IHRoZW4KICAgICAgICAgICAgbG9nICdTNCBoYXBwIOW3suaBouWkjeiHsyAlc++8iOesrCAlcyDmrKHpqozor4HvvIkn
ICIkY250IiAiJGkiCiAgICAgICAgICAgICMg5Y+q5pyJIuecn+eahOWBmuS6humHjee9riLmiY3miZPpmLLmipbmiLPvvJvoi6Xl
nKjml6DliqjkvZzml7bkuZ/miZPmiLPvvIwKICAgICAgICAgICAgIyDkvJrmiorpmLLmipbnqpflj6PkuI3mlq3mjqjlkI7vvIzl
r7zoh7TkuIvkuIDmrKHnnJ/lrp7mjonot6/ooqvor6/mjKHplb/ovr7kuIDlsI/ml7bjgIIKICAgICAgICAgICAgbWFya19yZXNl
dAogICAgICAgICAgICByZXR1cm4gMAogICAgICAgIGZpCiAgICAgICAgc2xlZXAgNQogICAgZG9uZQogICAgZXJyb3IgJ1M0IOmH
jee9ruWQjiBoYXBwIOS7jeS4uiAlc++8iOacn+acmyAlc++8ie+8jOWNh+e6p+i1sOWuueWZqOmHjeW7uicgIiR7Y250Oi0wfSIg
IiRIQVBQX04iCiAgICByZXR1cm4gMQp9CgojIC0tLS0gUzUg5pyN5Yqh5YGl5bq35o6i5rS777ya5byC5bi45YiZ6YeN5ZCv5pyN
5Yqh5bm26aqM6K+B77yI5L+d55WZ5pen54mI6K+t5LmJ77yJLS0tLQpzNV9oZWFsdGgoKSB7CiAgICBsb2NhbCByZXMgcmMgaQog
ICAgIyBzaGVsbGNoZWNrIGRpc2FibGU9U0MyMDg2ICAjIOWRveS7pOWPmOmHj+mcgOWIhuivjeWxleW8gO+8iC4vYmluL2lwZXMg
POWtkOWRveS7pD7vvIkKICAgIHJlcz0kKGRvY2tlciBleGVjICIkQ09OVEFJTkVSX05BTUUiICRIRUFMVEhfQ09NTUFORCAyPiYx
KQogICAgcmM9JD8KICAgIGlmIFsgIiRyYyIgPSAiMCIgXSBcCiAgICAgICAmJiAhIGVjaG8gIiRyZXMiIHwgZ3JlcCAtcSAiY29u
bmVjdGlvbiByZWZ1c2VkIiBcCiAgICAgICAmJiAhIGVjaG8gIiRyZXMiIHwgZ3JlcCAtcSAiZ2V0IHNlcnZpY2VzIGZhaWxlZCI7
IHRoZW4KICAgICAgICBsb2cgIlM1IOWBpeW6t+aOoua0u+ato+W4uCIKICAgICAgICByZXR1cm4gMAogICAgZmkKICAgIHdhcm5p
bmcgJ1M1IOWBpeW6t+aOoua0u+W8guW4uO+8iHJjPSVz77yJ77yaJXMnICIkcmMiICIkcmVzIgogICAgbG9nICdTNSDmiafooYzm
nI3liqHph43lkK/vvJolcycgIiRTVEFSVF9DT01NQU5EIgogICAgIyBzaGVsbGNoZWNrIGRpc2FibGU9U0MyMDg2ICAjIOWRveS7
pOWPmOmHj+mcgOWIhuivjeWxleW8gO+8iC4vYmluL2lwZXMgPOWtkOWRveS7pD7vvIkKICAgIGRvY2tlciBleGVjICIkQ09OVEFJ
TkVSX05BTUUiICRTVEFSVF9DT01NQU5EID4vZGV2L251bGwgMj4mMSB8fCB0cnVlCiAgICBzbGVlcCAxMAogICAgZm9yIGkgaW4g
JChzZXEgMSAzKTsgZG8KICAgICMgc2hlbGxjaGVjayBkaXNhYmxlPVNDMjA4NiAgIyDlkb3ku6Tlj5jph4/pnIDliIbor43lsZXl
vIDvvIguL2Jpbi9pcGVzIDzlrZDlkb3ku6Q+77yJCiAgICAgICAgcmVzPSQoZG9ja2VyIGV4ZWMgIiRDT05UQUlORVJfTkFNRSIg
JEhFQUxUSF9DT01NQU5EIDI+JjEpCiAgICAgICAgcmM9JD8KICAgICAgICBpZiBbICIkcmMiID0gIjAiIF0gJiYgISBlY2hvICIk
cmVzIiB8IGdyZXAgLXEgImNvbm5lY3Rpb24gcmVmdXNlZCI7IHRoZW4KICAgICAgICAgICAgbG9nICJTNSDph43lkK/lkI7mgaLl
pI3mraPluLgiCiAgICAgICAgICAgIHJldHVybiAwCiAgICAgICAgZmkKICAgICAgICB3YXJuaW5nICdTNSDph43lkK/pqozor4Eg
JXMvMyDlpLHotKXvvIznrYnlvoUgNXMg5ZCO6YeN6K+VJyAiJGkiCiAgICAgICAgc2xlZXAgNQogICAgZG9uZQogICAgZXJyb3Ig
IlM1IOacjeWKoemHjeWQr+WQjuS7jeW8guW4uO+8jOivt+S6uuW3peajgOafpSIKICAgIHJldHVybiAxCn0KCiMgLS0tLSDkuLvm
tYHnqIsgLS0tLQptYWluKCkgewogICAgdG91Y2ggIiRMT0dfRklMRSIgMj4vZGV2L251bGwKICAgIGNobW9kIDY0NCAiJExPR19G
SUxFIiAyPi9kZXYvbnVsbAoKICAgICMgUzEgZG9ja2VyIOWuiOaKpOi/m+eoiwogICAgaWYgISBzMV9kb2NrZXJfc2VsZmhlYWw7
IHRoZW4KICAgICAgICBlcnJvciAi5Li75rWB56iL5Lit5q2i77yaZG9ja2VyIOS4jeWPr+eUqO+8iFMxIOW3suWwneivleiHquaE
iO+8iSIKICAgICAgICBleGl0IDEKICAgIGZpCgogICAgIyBTMiDlrrnlmagKICAgIHMyX2NvbnRhaW5lcl9zZWxmaGVhbCB8fCB0
cnVlCiAgICBpZiAhIGNvbnRhaW5lcl9ydW5uaW5nOyB0aGVuCiAgICAgICAgZXJyb3IgJ+S4u+a1geeoi+S4reatou+8muWuueWZ
qCAlcyDkuI3lj6/nlKjvvIhTMiDlt7LlsJ3or5Ugc3RhcnQv6YeN5bu677yJJyAiJENPTlRBSU5FUl9OQU1FIgogICAgICAgIGV4
aXQgMQogICAgZmkKCiAgICBsb2NhbCBuZWVkX3JlYnVpbGQ9MCBjZmdfcmM9MAogICAgbG9jYWwgZGViX29rPTAKICAgIGRlYm91
bmNlX29rICYmIGRlYl9vaz0xCgogICAgIyBTMyBjdXN0b20ueW1sIOi3r+aVsOagoemqjO+8iOmHjeWGmeWQjumcgOmHjeW7uuWu
ueWZqOaJjeeUn+aViO+8iQogICAgczNfY29uZmlnX3NlbGZoZWFsOyBjZmdfcmM9JD8KICAgIGlmIFsgIiRjZmdfcmMiID0gIjIi
IF07IHRoZW4KICAgICAgICBpZiBbICIkZGViX29rIiA9ICIxIiBdOyB0aGVuCiAgICAgICAgICAgIGxvZyAiUzMg6YWN572u5bey
5Y+Y5pu077yM5qCH6K6w6ZyA6KaB6YeN5bu65a655ZmoIgogICAgICAgICAgICBuZWVkX3JlYnVpbGQ9MQogICAgICAgIGVsc2UK
ICAgICAgICAgICAgd2FybmluZyAnUzYg6Led5LiK5qyh6YeN572u5LiN6LazICVzc++8jOi3s+i/h+acrOi9rumHjeW7uu+8iOmY
suWPjeWkjeaWrea1ge+8iScgIiRSRVNFVF9ERUJPVU5DRSIKICAgICAgICBmaQogICAgZWxpZiBbICIkY2ZnX3JjIiAhPSAiMCIg
XTsgdGhlbgogICAgICAgIHdhcm5pbmcgJ1MzIOi3r+aVsOagoemqjOacqumAmui/h++8iHJjPSVz77yJ77yM5pys6L2u5LiN5o2u
5q2k6YeN5bu6JyAiJGNmZ19yYyIKICAgIGZpCgogICAgIyBTNCBoYXBwIOi/m+eoi+aBkuWumiBOCiAgICBpZiBbICIkZGViX29r
IiA9ICIxIiBdOyB0aGVuCiAgICAgICAgIyDms6jmhI/vvJptYXJrX3Jlc2V0IOW3suS4i+ayieWIsCBzNF9oYXBwX2NvbnN0YW50
IOWGhemDqCLph43nva7miJDlip8i5YiG5pSv77yMCiAgICAgICAgIyAgICAgICDov5nph4zkuI3lho3ph43lpI3miZPmiLPvvIjm
l6DliqjkvZzml7bkuI3miZPmiLPvvIzop4Hor6Xlh73mlbDlhoXms6jph4rvvInjgIIKICAgICAgICBpZiAhIHM0X2hhcHBfY29u
c3RhbnQ7IHRoZW4KICAgICAgICAgICAgbG9nICJTNCDoh6rouqvph43nva7lpLHotKXvvIzljYfnuqfotbDlrrnlmajph43lu7ro
t6/lvoQiCiAgICAgICAgICAgIG5lZWRfcmVidWlsZD0xCiAgICAgICAgZmkKICAgIGVsc2UKICAgICAgICB3YXJuaW5nICdTNiDo
t53kuIrmrKHph43nva7kuI3otrMgJXNz77yM6Lez6L+HIFM0IOmHjee9ru+8iOmYsuWPjeWkjeaWrea1ge+8iScgIiRSRVNFVF9E
RUJPVU5DRSIKICAgIGZpCgogICAgIyDph43lu7rot6/lvoTvvIhTMyDphY3nva7lj5jmm7Qg5oiWIFM0IOmHjee9ruWksei0pe+8
iQogICAgaWYgWyAiJG5lZWRfcmVidWlsZCIgPSAiMSIgXTsgdGhlbgogICAgICAgIGxvZyAi6L+b5YWl5a655Zmo6YeN5bu66Lev
5b6E77yI5pat5rWBIDMwLTYwc++8ieKApiIKICAgICAgICBkb2NrZXIgc3RvcCAiJENPTlRBSU5FUl9OQU1FIiA+L2Rldi9udWxs
IDI+JjEgfHwgdHJ1ZQogICAgICAgIGRvY2tlciBybSAtZiAiJENPTlRBSU5FUl9OQU1FIiA+L2Rldi9udWxsIDI+JjEgfHwgdHJ1
ZQogICAgICAgIGlmIGNvbnRhaW5lcl9yZWJ1aWxkOyB0aGVuCiAgICAgICAgICAgIG1hcmtfcmVzZXQKICAgICAgICAgICAgbG9j
YWwgaSBjbnQKICAgICAgICAgICAgZm9yIGkgaW4gJChzZXEgMSAxMik7IGRvCiAgICAgICAgICAgICAgICBjbnQ9JChoYXBwX3By
b2NfY250KQogICAgICAgICAgICAgICAgWyAiJHtjbnQ6LTB9IiA9ICIkSEFQUF9OIiBdICYmIGJyZWFrCiAgICAgICAgICAgICAg
ICBzbGVlcCA1CiAgICAgICAgICAgIGRvbmUKICAgICAgICAgICAgY250PSQoaGFwcF9wcm9jX2NudCkKICAgICAgICAgICAgaWYg
WyAiJHtjbnQ6LTB9IiA9ICIkSEFQUF9OIiBdOyB0aGVuCiAgICAgICAgICAgICAgICBsb2cgJ+mHjeW7uuWQjiBoYXBwPSVz77yM
5bey5oGi5aSN5oGS5a6aICVzJyAiJGNudCIgIiRIQVBQX04iCiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIGVycm9y
ICfph43lu7rlkI4gaGFwcD0lc++8jOS7jeS4jeetieS6jiAlc++8m+eOsOWcuuS/neeVme+8iCVzLmJhay4qIOWPr+Wbnua7mu+8
iScgIiR7Y250Oi0wfSIgIiRIQVBQX04iICIkQ0ZHIgogICAgICAgICAgICBmaQogICAgICAgIGVsc2UKICAgICAgICAgICAgZXJy
b3IgJ+WuueWZqOmHjeW7uuWksei0pe+8jOeOsOWcuuS/neeVme+8iCVzLmJhay4qIOWPr+Wbnua7mu+8iScgIiRDRkciCiAgICAg
ICAgZmkKICAgIGZpCgogICAgIyBTNSDmnI3liqHlgaXlurfmjqLmtLsKICAgIHM1X2hlYWx0aCB8fCB0cnVlCgogICAgZXhpdCAw
Cn0KCm1haW4gIiRAIgpIQ0VPRgogICAgfSA+ICIkU0NSSVBUX1BBVEgiCgogICAgY2htb2QgK3ggIiRTQ1JJUFRfUEFUSCIKICAg
IGxvZyAn55yf5L+d5rS76ISa5pys5bey5Yib5bu6OiAlcycgIiRTQ1JJUFRfUEFUSCIKfQoKIyDliJvlu7rml6Xlv5fmlofku7YK
Y3JlYXRlX2xvZ19maWxlKCkgewogICAgbG9nICLliJvlu7rml6Xlv5fmlofku7YuLi4iCiAgICB0b3VjaCAiJExPR19GSUxFIgog
ICAgY2htb2QgNjQ0ICIkTE9HX0ZJTEUiCiAgICBsb2cgJ+aXpeW/l+aWh+S7tuW3suWIm+W7ujogJXMnICIkTE9HX0ZJTEUiCn0K
CiMg6YWN572u5a6a5pe25Lu75Yqh77yI5bmC562J77ya5YWI5riFIGlwZXMg55u45YWz6KGM5YaN6KOF77yM6YeN5aSN5omn6KGM
5LiN5Y+g5Yqg77yJCnNldHVwX2Nyb25fam9iKCkgewogICAgbG9nICLphY3nva7lrprml7bku7vliqEuLi4iCgogICAgbG9jYWwg
Y3VycmVudAogICAgY3VycmVudD0kKGNyb250YWIgLWwgMj4vZGV2L251bGwgfHwgdHJ1ZSkKCiAgICBsb2NhbCBmaWx0ZXJlZAog
ICAgaWYgWyAtbiAiJGN1cnJlbnQiIF07IHRoZW4KICAgICAgICAjIOa4heaOieaXp+eahCBpcGVzIOWBpeW6t+ajgOafpeihjO+8
iOS/nea0u+iEmuacrCArIEByZWJvb3Qg6ZKp5a2Q77yJ77yM5L+d55WZ5YW25a6DIGNyb24g5LiN5YqoCiAgICAgICAgZmlsdGVy
ZWQ9JChwcmludGYgJyVzXG4nICIkY3VycmVudCIgXAogICAgICAgICAgICB8IGdyZXAgLXYgIiRTQ1JJUFRfUEFUSCIgXAogICAg
ICAgICAgICB8IGdyZXAgLXYgJ2lwZXMgLi9iaW4vaXBlcycgXAogICAgICAgICAgICB8IGdyZXAgLXYgJ2lwZXNfaGVhbHRoX2No
ZWNrJyBcCiAgICAgICAgICAgIHwgc2VkICcvXltbOnNwYWNlOl1dKiQvZCcpCiAgICBlbHNlCiAgICAgICAgZmlsdGVyZWQ9IiIK
ICAgIGZpCgogICAgbG9jYWwgbmV3dGFiCiAgICBuZXd0YWI9IiRmaWx0ZXJlZAoqICogKiAqICogJFNDUklQVF9QQVRIID4gL2Rl
di9udWxsIDI+JjEKQHJlYm9vdCBzbGVlcCAzMDAgJiYgZG9ja2VyIGV4ZWMgaXBlcyAuL2Jpbi9pcGVzIHN0b3AgPiAvZGV2L251
bGwgMj4mMSIKCiAgICBwcmludGYgJyVzXG4nICIkbmV3dGFiIiB8IHNlZCAnL15bWzpzcGFjZTpdXSokL2QnIHwgY3JvbnRhYiAt
CgogICAgbG9nICLlrprml7bku7vliqHphY3nva7lrozmiJAiCiAgICBsb2cgIuW9k+WJjeeUqOaIt+eahOWumuaXtuS7u+WKoeWI
l+ihqDoiCiAgICBjcm9udGFiIC1sIDI+L2Rldi9udWxsIHx8IHdhcm5pbmcgImNyb250YWIgLWwg6K+75Y+W5aSx6LSlIgp9Cgoj
IOa1i+ivleWBpeW6t+ajgOafpeiEmuacrO+8iOmdnuS6pOS6ku+8jOWksei0peS4jemYu+WhnuWuieijhe+8iQp0ZXN0X2hlYWx0
aF9zY3JpcHQoKSB7CiAgICBsb2cgIua1i+ivleecn+S/nea0u+iEmuacrC4uLiIKICAgIGlmICIkU0NSSVBUX1BBVEgiOyB0aGVu
CiAgICAgICAgbG9nICLnnJ/kv53mtLvohJrmnKzmtYvor5XmiJDlip8iCiAgICBlbHNlCiAgICAgICAgd2FybmluZyAi55yf5L+d
5rS76ISa5pys5rWL6K+V6L+U5Zue6Z2eIDDvvIzor7fmo4Dmn6Xml6Xlv5fmn6XnnIvor6bnu4bkv6Hmga/vvIjkuI3lvbHlk40g
Y3JvbiDmr4/liIbpkp/ph43or5XvvIkiCiAgICBmaQoKICAgIGxvZyAi5pyA6L+R5pel5b+X5YaF5a65OiIKICAgIHRhaWwgLW4g
OCAiJExPR19GSUxFIiAyPi9kZXYvbnVsbCB8fCBlY2hvICLmmoLml6Dml6Xlv5flhoXlrrkiCn0KCiMg5pi+56S65a6J6KOF5pGY
6KaBCnNob3dfc3VtbWFyeSgpIHsKICAgIGVjaG8KICAgIGxvZyAiPT09IElQRVMg55yf5L+d5rS75a6J6KOF5a6M5oiQID09PSIK
ICAgIGxvZyAn57uE5Lu254mI5pysOiAlcycgIiRIQ19WRVIiCiAgICBsb2cgJ+iEmuacrOS9jee9rjogJXMnICIkU0NSSVBUX1BB
VEgiCiAgICBsb2cgJ+aXpeW/l+aWh+S7tjogJXMnICIkTE9HX0ZJTEUiCiAgICBsb2cgJ+WuueWZqOWQjeensDogJXMnICIkQ09O
VEFJTkVSX05BTUUiCiAgICBsb2cgJ2hhcHAg55uu5qCH6Lev5pWwOiAlcycgIiRIQVBQX04iCiAgICBsb2cgJ2N1c3RvbS55bWw6
ICVzJyAiJENGRyIKICAgIGxvZyAn6YeN5bu66ZWc5YOPKOeDmOeEmSk6ICVzJyAiJEJBS0VEX0lNRyIKICAgIGxvZyAi5qOA5p+l
6aKR546HOiDmr4/liIbpkp8iCiAgICBsb2cgJ+iHquaEiOiDveWKmzogUzEgZG9ja2VyIC8gUzIg5a655ZmoKHN0YXJ0K+mHjeW7
uikgLyBTMyDot6/mlbAgLyBTNCBoYXBw5oGS5a6aJXMgLyBTNSDmnI3liqHlgaXlurcnICIkSEFQUF9OIgogICAgbG9nICfpmLLm
ipY6IOmHjee9ruaIkOWKn+WQjiAlc3Mg5YaF5LiN6YeN5aSN6YeN572uJyAiJHtSRVNFVF9ERUJPVU5DRTotMzYwMH0iCiAgICBs
b2cgIiIKICAgIGxvZyAn5p+l55yL5pel5b+X5ZG95LukOiB0YWlsIC1mICVzJyAiJExPR19GSUxFIgogICAgbG9nICfmiYvliqjm
tYvor5Xlkb3ku6Q6ICVzJyAiJFNDUklQVF9QQVRIIgogICAgbG9nICLmn6XnnIvlrprml7bku7vliqE6IGNyb250YWIgLWwiCiAg
ICBsb2cgIiIKICAgIGxvZyAi5a6J6KOF5a6M5oiQ77yB57O757uf5bCG5q+P5YiG6ZKf6Ieq5Yqo5beh5qOA5bm26Ieq5oSIIgp9
CgojIOS4u+WHveaVsAptYWluKCkgewogICAgbG9nICLlvIDlp4vlronoo4UgSVBFUyDnnJ/kv53mtLvns7vnu58uLi4iCiAgICBj
aGVja19yb290CiAgICBjaGVja19kb2NrZXIKICAgIGNhcHR1cmVfY29udGFpbmVyX3BhcmFtcwogICAgY3JlYXRlX2hlYWx0aF9z
Y3JpcHQKICAgIGNyZWF0ZV9sb2dfZmlsZQogICAgc2V0dXBfY3Jvbl9qb2IKICAgIHRlc3RfaGVhbHRoX3NjcmlwdAogICAgc2hv
d19zdW1tYXJ5Cn0KCiMg5omn6KGM5Li75Ye95pWwCm1haW4gIiRAIgo='

say "===== q2 外科式续跑开始 $(date '+%F %T') ====="
say "日志: $LOG"

# 互斥锁：与 v5 共用同一把，防止与残留部署进程互踩（flock 随进程退出自动释放）
LOCK=/var/run/ipes_deploy.lock
exec 9>"$LOCK" 2>/dev/null
if flock -n 9 2>/dev/null; then say "✅ 部署锁已获取"
else say "❌ 本机已有部署在运行（锁被占用），本次退出"; exit 1; fi

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
  [ -z "$p" ] && p="广东"; [ -z "$c" ] && c="深圳"; echo "${p}|${c}"
}

# ── 探测（唯一可信路数 = 容器内可见分片数）──
probe_shards() { docker exec ipes ls -d /data/happ/happ.* 2>/dev/null | wc -l | tr -d ' '; }
probe_procs()  { docker exec ipes sh -c 'ps -ef | grep -c "[h]app"' 2>/dev/null | tr -d '\r'; }
probe_snlen()  { docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n' | wc -c | tr -d ' '; }

NID=$(node_id)
say "nodeID=${NID:-未生成}"
[ -z "$NID" ] && mark_fail "拿不到 nodeID"
say "当前状态: 容器内分片=$(probe_shards) 进程=$(probe_procs) SN长度=$(probe_snlen)"

# ==============================================================================
# d3 · 九路一次做对（v5 已验证逻辑，路径修正为 ipes，非 ipeses）
# ==============================================================================
say ""; say "===== d3 · happ 路数一次做对（目标 ${HAPP_N} 路）====="
ROOT=/data/happ; CFG=/opt/ipes/var/db/ipes/happ-conf/custom.yml
IMG="ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:latest"
for _w in $(seq 1 20); do
  docker inspect ipes >/dev/null 2>&1 && [ -d "$ROOT/happ.0" ] && break
  say "     等容器初始化（$_w/20）…"; sleep 30
done
CUR=$(probe_shards)
say "     容器内实际可见 ${CUR:-0} 个分片（期望 $HAPP_N）"
if [ "${CUR:-0}" = "$HAPP_N" ]; then
  say "     ⏭SKIP[d3] 已是 ${HAPP_N} 路，不重建"
else
  if docker inspect ipes >/dev/null 2>&1 && [ -f "$CFG" ] && [ -d "$ROOT/happ.0" ]; then
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
      rm -f "$TMP"; say "     ✗ 配置条数异常($CNT != $HAPP_N)，保留现场"; mark_fail "9路配置"
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
      docker run -d --restart=always --name=ipes --network=host $MARGS \
        -v "$CFG:/app/ipes/var/db/ipes/happ-conf/custom.yml" \
        "$IMG" sh -c '/app/ipes/bin/ipes start && tail -f /dev/null' >/dev/null 2>&1
      RCD=$?
      say "     docker run 返回码=$RCD"
      for _h in $(seq 1 12); do
        HP=$(probe_procs)
        [ "${HP:-0}" = "$HAPP_N" ] && break
        sleep 5
      done
      NEW=$(probe_shards); HP=$(probe_procs)
      if [ "${NEW:-0}" = "$HAPP_N" ] && [ "${HP:-0}" = "$HAPP_N" ]; then
        say "     ✅ ${HAPP_N} 路已真正生效：容器内分片=$NEW happ进程=$HP"
      else
        say "     ⚠️ 重建后容器内分片=$NEW happ进程=$HP（期望 $HAPP_N）"
        mark_fail "九路未真正生效(分片=${NEW:-0},进程=${HP:-0})"
      fi
    fi
  else
    say "     ⚠️ 容器或 custom.yml 尚未就绪（$CFG），无法补 9 路"; mark_fail "九路前置缺失"
  fi
fi

# 硬闸：九路不成立就不回填 SN（不在残缺容器上回填，避免平台显示真SN却不跑量）
S9=$(probe_shards); P9=$(probe_procs)
if [ "${S9:-0}" != "$HAPP_N" ] || [ "${P9:-0}" != "$HAPP_N" ]; then
  say "  ✗ 九路复核失败（分片=${S9:-0} 进程=${P9:-0}）→【不进入 d4】，不在这台残缺容器上回填 SN"
  mark_fail "九路复核失败(分片=${S9:-0},进程=${P9:-0})"
fi

# ==============================================================================
# d4 · 读真SN → 降级 → 提交属性 → 升回「服务中」
# ==============================================================================
if [ -z "$FAIL" ]; then
  say ""; say "===== d4 · 读真SN → 回填 → 再流转 ====="
  SN=""
  for i in 1 2 3 4 5 6; do
    SN=$(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | tr -d '\r\n')
    [ ${#SN} -ge 60 ] && break
    say "     等 SN（$i/6，${#SN}字节）…"; sleep 30
  done
  if [ ${#SN} -ge 60 ] && [ -n "$NID" ]; then
    LOC=$(detect_loc)
    say "     SN=${SN:0:16}…（${#SN}字节）"
    say "     降级→待配置: $(flow "$NID" "$SN" configured)"
    say "     提交属性(41/200M/${ISP}): $(submit_nominal "$NID" "${LOC%%|*}" "${LOC##*|}")"
    sleep 2
    say "     升回→服务中: $(flow "$NID" "$SN" inService)"
  else
    say "     ⚠️ 未取到真SN（${#SN}字节）"; mark_fail "未取到真SN"
  fi
else
  say ""; say "===== d4 跳过（前置失败，不在残缺容器上回填 SN）====="
fi

# ==============================================================================
# d5 · 安装保活（内嵌「真保活 v2.0」，零外部依赖）
# ==============================================================================
say ""; say "===== d5 · 安装保活（真保活 v2.0）====="
if [ "$(crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check')" -ge 1 ] 2>/dev/null; then
  say "  ⏭SKIP[d5] crontab 已有保活条目"
else
  embed_decode() {
    local out="$1" min="$2" tmp sz
    tmp=$(mktemp /tmp/_emb.XXXXXX) || return 1
    if printf '%s' "${EMB_HC_B64}" | base64 -d >"$tmp" 2>/dev/null \
       && [ "$(wc -c <"$tmp" | tr -d ' ')" -ge "$min" ] \
       && bash -n "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$out" 2>/dev/null && chmod +x "$out" 2>/dev/null && return 0
    fi
    rm -f "$tmp" 2>/dev/null; return 1
  }
  if embed_decode /tmp/_hc.sh 20000; then
    say "  · 保活组件：内嵌（真保活 v2.0）"
    bash /tmp/_hc.sh || mark_fail "保活"
  else
    say "  · 内嵌解码失败，回落 OSS（旧版，带指纹校验）"
    curl -fsSL -m 120 "$OSS/Q2_test/install_ipes_health_check.sh" -o /tmp/_hc.sh 2>/dev/null
    if [ "$(md5sum /tmp/_hc.sh 2>/dev/null | cut -d' ' -f1)" = "5c1199b735365ffa043d1da4e1150d5f" ]; then
      bash /tmp/_hc.sh || mark_fail "保活"
    else
      say "  ✗ OSS 保活组件指纹不符，拒绝执行"; mark_fail "保活组件指纹不符"
    fi
  fi
fi
say "  保活cron: $(crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check') 条"

# ==============================================================================
# d6 · 挂限速 23:59 → 18:25
# ==============================================================================
say ""; say "===== d6 · 挂限速 ${LIMIT_START} → ${LIMIT_END} ====="
if [ "$(tc qdisc show dev eth0 2>/dev/null | grep -c htb)" -ge 1 ] 2>/dev/null || \
   [ "$(crontab -l 2>/dev/null | grep -cE 'limit_start|clear_limit')" -ge 1 ] 2>/dev/null; then
  say "  ⏭SKIP[d6] 限速已存在"
else
  # 限速组件带指纹校验：先落盘 → 校验 md5+size → 才执行（不做无校验的远程 | bash）
  curl -fsSL -m 180 "$OSS/limit/run_limit.sh" -o /tmp/_lim.sh 2>/dev/null
  LIM_MD5=$(md5sum /tmp/_lim.sh 2>/dev/null | cut -d' ' -f1)
  LIM_SZ=$(wc -c < /tmp/_lim.sh 2>/dev/null | tr -d ' ')
  if [ "$LIM_MD5" = "cfd94a2c95e45e22df79862f35030dff" ] && [ "${LIM_SZ:-0}" = "10629" ]; then
    say "  限速组件指纹校验通过（md5=$LIM_MD5 size=$LIM_SZ）"
    bash /tmp/_lim.sh "$LIMIT_START" "$LIMIT_END" || mark_fail "限速"
  else
    say "  ✗ 限速组件指纹不符（md5=$LIM_MD5 size=${LIM_SZ:-0}），拒绝执行"; mark_fail "限速组件指纹不符"
  fi
fi
say "  qdisc=$(tc qdisc show dev eth0 2>/dev/null | grep -c htb) 条  cron=$(crontab -l 2>/dev/null | grep -cE 'limit_start|clear_limit') 条"

flock -u 9 2>/dev/null; exec 9>&-

# ==============================================================================
# 验收：一行机器可读结论
# ==============================================================================
say ""; say "==================== 验收 ===================="
SH=$(probe_shards); PC=$(probe_procs); SL=$(probe_snlen)
HC=$(crontab -l 2>/dev/null | grep -cE 'ipes_health|health_check' | tr -d ' ')
QD=$(tc qdisc show dev eth0 2>/dev/null | grep -c htb | tr -d ' ')
say "容器     : $(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | tr '\n' ' ')"
say "happ 路数: ${SH:-0}  (期望 $HAPP_N)"
say "happ进程 : ${PC:-0}  (期望 $HAPP_N)"
say "真SN长度 : ${SL:-0}  (期望 76)"
say "保活cron : ${HC:-0} 条"
say "限速     : qdisc ${QD:-0} / cron $(crontab -l 2>/dev/null | grep -cE 'limit_start|clear_limit') 条"

if [ -n "$FAIL" ]; then
  say "RESUME_FAILED 失败步骤:${FAIL}"
  say "VERIFY shards=${SH:-0} procs=${PC:-0} snlen=${SL:-0} health_cron=${HC:-0} limit=${LIMIT_START}-${LIMIT_END} verdict=FAIL:${FAIL_REASON}"
  exit 1
fi
if [ "${SH:-0}" = "$HAPP_N" ] && [ "${PC:-0}" = "$HAPP_N" ] && [ "${SL:-0}" = "76" ]; then
  say "RESUME_DONE"
  say "VERIFY shards=${SH} procs=${PC} snlen=${SL} health_cron=${HC} limit=${LIMIT_START}-${LIMIT_END} verdict=OK"
  exit 0
fi
say "RESUME_FAILED 未达成功态"
say "VERIFY shards=${SH:-0} procs=${PC:-0} snlen=${SL:-0} health_cron=${HC} limit=${LIMIT_START}-${LIMIT_END} verdict=FAIL:shards=${SH:-0},procs=${PC:-0},snlen=${SL:-0}"
exit 1


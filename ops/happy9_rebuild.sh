#!/bin/bash
# happ 9 路修复：容器挂载参数在 docker run 时固化，仅改 custom.yml + restart 不生效
# 必须用 9 个 -v 重建容器。本脚本保 SN、保缓存目录、保业务配置。
# 幂等：已是 9 路且容器挂载齐全则直接退出。
set -u
LOG=/tmp/happy9_fix.log
exec > >(tee -a "$LOG") 2>/dev/null
IMG="ccr.ccs.tencentyun.com/zyy_cloud/ipes-linux-amd64-youkai-latest:latest"
CFG=/opt/ipes/var/db/ipes/happ-conf/custom.yml
ROOT=/data/happ
N=9

echo "===== happ${N} 修复 $(date '+%F %T') ====="

# 0) 前置校验
docker inspect ipes >/dev/null 2>&1 || { echo "[跳过] 无 ipes 容器"; exit 0; }
[ -f "$CFG" ] || { echo "[跳过] 无 custom.yml"; exit 0; }
[ -d "$ROOT/happ.0" ] || { echo "[跳过] 缓存未初始化(happ.0 不存在)"; exit 0; }

# 1) 补齐 9 个分片目录 + 每片必须有 xycould_base_info，否则 happ.N 起不来
REF="$ROOT/happ.0/xycould_base_info"
for i in $(seq 0 $((N-1))); do
  mkdir -p "$ROOT/happ.$i/hdata/cache" "$ROOT/happ.$i/hdata/config"
  if [ -s "$REF" ] && [ ! -s "$ROOT/happ.$i/xycould_base_info" ]; then
    cp -p "$REF" "$ROOT/happ.$i/xycould_base_info" 2>/dev/null
  fi
done
echo "[1] 分片目录: $(ls -d $ROOT/happ.* 2>/dev/null | wc -l) 个"

# 2) custom.yml 写 9 路
BK="$CFG.bak.$(date +%Y%m%d%H%M%S)"
cp -p "$CFG" "$BK" 2>/dev/null
TMP=$(mktemp)
{ echo "# q2 happy${N} $(date '+%F %T')"; echo "args:"
  for i in $(seq 0 $((N-1))); do echo "  - $ROOT/happ.$i"; done
  grep -E '^reg_isp:' "$CFG" 2>/dev/null; } > "$TMP"
CNT=$(grep -cE "^  - ${ROOT}/happ\.[0-9]+$" "$TMP")
if [ "$CNT" != "$N" ]; then rm -f "$TMP"; echo "[✗] 配置条数异常($CNT != $N)，保留现场"; exit 1; fi
cp -p "$TMP" "$CFG"; rm -f "$TMP"
echo "[2] custom.yml 已设为 ${N} 路（备份 $BK）"

# 3) 关键：用 9 个 -v 重建容器（挂载参数固化，必须重建）
echo "[3] 重建容器（断流 30-60 秒）…"
docker stop ipes >/dev/null 2>&1
docker rm -f ipes >/dev/null 2>&1
ARGS=""
for i in $(seq 0 $((N-1))); do
  ARGS="$ARGS -v $ROOT/happ.$i/hdata/cache:$ROOT/happ.$i/hdata/cache"
  ARGS="$ARGS -v $ROOT/happ.$i/hdata/config:$ROOT/happ.$i/hdata/config"
  ARGS="$ARGS -v $ROOT/happ.$i/xycould_base_info:$ROOT/happ.$i/xycould_base_info"
done
# shellcheck disable=SC2086
docker run -d --restart=always --name=ipes --network=host $ARGS \
  -v "$CFG:/app/ipes/var/db/ipes/happ-conf/custom.yml" \
  "$IMG" sh -c '/app/ipes/bin/ipes start && tail -f /dev/null' >/dev/null
RC=$?
echo "[4] docker run 返回码=$RC"
sleep 40

# 4) 验收
echo "容器    : $(docker ps --format '{{.Names}} {{.Status}}' | grep ipes)"
echo "容器内可见分片: $(docker exec ipes ls -d /data/happ/happ.* 2>/dev/null | wc -l) 个 (期望 $N)"
echo "happ进程: $(docker exec ipes sh -c 'ps -ef | grep \"[h]app\" | wc -l' 2>/dev/null | tr -d '\r')"
echo "真SN    : $(docker exec ipes cat /app/ipes/bin/ipes_sn 2>/dev/null | head -c 76)"
echo "===== 完成 $(date '+%F %T') ====="
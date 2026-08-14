#!/bin/bash
# 在 Oracle Cloud 永久免费 VM 上部署「定时退订」常驻任务
# 用法（VM 内，需 root 或 sudo）：
#   curl -fsSL https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/setup.sh -o setup.sh
#   chmod +x setup.sh
#   sudo bash setup.sh
set -e

echo "=== 部署定时退订到 Oracle VM ==="

PY=$(command -v python3 || true)
if [ -z "$PY" ]; then
  echo "未找到 python3，请先安装 Python 3（Oracle Linux / Ubuntu 默认已带）" >&2
  exit 1
fi
echo "python3: $($PY --version 2>&1)"

# 1. 准备目录并下载脚本（仓库为 public，免密）
mkdir -p /opt/scheduled-refund
SCRIPT=/opt/scheduled-refund/scheduled_refund.py
echo "下载 scheduled_refund.py ..."
curl -fsSL https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/scheduled_refund.py -o "$SCRIPT"
echo "脚本大小: $(wc -c < "$SCRIPT") 字节"

# 2. systemd service（每次定时触发跑一次脚本）
cat > /etc/systemd/system/scheduled-refund.service <<'EOF'
[Unit]
Description=Scheduled Aliyun Refund (one-click)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/scheduled-refund/scheduled_refund.py
StandardOutput=append:/var/log/scheduled-refund.log
StandardError=append:/var/log/scheduled-refund.log
EOF

# 3. systemd timer（每 10 分钟触发一次；VM 重启后自动恢复）
cat > /etc/systemd/system/scheduled-refund.timer <<'EOF'
[Unit]
Description=Run scheduled refund every 10 minutes

[Timer]
OnCalendar=*:0/10:00
Persistent=true
Unit=scheduled-refund.service

[Install]
WantedBy=timers.target
EOF

# 4. 启用并启动
systemctl daemon-reload
systemctl enable --now scheduled-refund.timer

echo "=== 定时器状态 ==="
systemctl status scheduled-refund.timer --no-pager || true
echo "下一次运行: $(systemctl show scheduled-refund.timer -p NextElapseUSec --value 2>/dev/null || echo 'n/a')"

# 5. 立即试跑一次验证
echo "=== 立即试跑一次（验证连通性）==="
systemctl start scheduled-refund.service
sleep 3
echo "--- 最近日志 ---"
tail -n 25 /var/log/scheduled-refund.log 2>/dev/null || journalctl -u scheduled-refund.service -n 25 --no-pager

echo ""
echo "部署完成 ✅"
echo "查看运行日志:  journalctl -u scheduled-refund.service -f"
echo "或查看文件:    tail -f /var/log/scheduled-refund.log"
echo "停止定时:      sudo systemctl stop scheduled-refund.timer"
echo "查看下次触发:  systemctl show scheduled-refund.timer -p NextElapseUSec --value"

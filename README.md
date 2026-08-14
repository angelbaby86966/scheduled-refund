# 定时退订 · 常驻云主机部署指南

解决「关闭浏览器就不到点退订」的问题：把退订脚本放到一台 **7×24 永远开机的云主机**上，
由系统定时器（systemd）每 10 分钟跑一次，完全不依赖浏览器、也不依赖不稳定的 GitHub Actions。

> 退订逻辑沿用已验证的 `scheduled_refund.py`（纯 Python 标准库，零依赖），只在 23:35–23:59（北京时间）
> 窗口内、且账号开启定时时才退订，重复凭证按 AK 去重只退一次。

---

## 推荐方案：阿里云 轻量应用服务器（¥38–68/年）

你本就有阿里云账号，连新注册都省了。轻量应用服务器自带公网 IP 和带宽，买完即可 SSH，
跑本脚本与在 Oracle 上完全一致（脚本已自动适配 Alibaba Cloud Linux 3 / Ubuntu）。

### 1. 购买并创建实例

1. 阿里云控制台 → **产品与服务 → 轻量应用服务器 → 创建实例**。
2. 镜像：选 **Alibaba Cloud Linux 3** 或 **Ubuntu 22.04**（均可，脚本自适应）。
3. 套餐：选 **2 核 2G**（新用户秒杀 ¥38/年、常规 ¥68/年；200M 峰值带宽、40G ESSD、含公网 IP）。
4. 设置实例密码（用于 SSH 登录，默认用户是 `root`）。
5. 创建后等状态变「运行中」，记下 **公网 IP**。

### 2. 放行 SSH（防火墙）

轻量应用服务器的防火墙在控制台「防火墙」标签页里配置（不是安全组）：
- 默认模板通常已含 **SSH(22)** 放行规则；若本地连不上，先来这里确认 22 端口已放行。

### 3. 登录并一键部署

本地终端：

```bash
ssh root@<公网IP>
```

登录后在 VM 内执行（一条命令搞定）：

```bash
curl -fsSL https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/setup.sh -o setup.sh
chmod +x setup.sh
sudo bash setup.sh
```

脚本会自动：装好依赖 → 拉取 `scheduled_refund.py` → 建 systemd 服务+定时器（每 10 分钟）
→ 立即试跑一次并打出日志。看到日志里出现「共读取 N 个用户配置」即表示连通正常。

---

## 备选方案：Oracle Cloud 永久免费 VM（0 元）

### 1. 注册 Oracle Cloud 免费账号

打开 https://www.oracle.com/cloud/free/ → 注册（免费，需信用卡验证但不扣费）。

### 2. 创建永久免费虚拟机（Always Free）

1. 控制台 → **Compute → 实例 → 创建实例**。
2. 映像：选 **Oracle Linux 9**（或 Ubuntu 22.04）。
3. 形状：点「更改形状」→ 选 **Ampere A1（VM.Standard.A1.Flex）**，OCPU=1、内存=6GB
   （在「4 OCPU / 24GB 永久免费额度」内，全球区域都免费）。
   ⚠️ 不要选 Micro（VM.Standard.E2.1.Micro）——只在部分区域免费，易踩坑。
4. 记下公网 IP 与 SSH 私钥（默认用户 `opc`，Ubuntu 为 `ubuntu`）。

### 3. 部署

```bash
chmod 600 你的私钥.key
ssh -i 你的私钥.key opc@<VM公网IP>
# 登录后：
curl -fsSL https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/setup.sh -o setup.sh
chmod +x setup.sh
sudo bash setup.sh
```

---

## 验证与日常维护（两种方案通用）

- 实时看日志：`journalctl -u scheduled-refund.service -f`
- 看文件日志：`tail -f /var/log/scheduled-refund.log`
- 看下次触发：`systemctl show scheduled-refund.timer -p NextElapseUSec --value`
- 停止定时：`sudo systemctl stop scheduled-refund.timer`
- 重启 VM 后定时器会自动恢复（`Persistent=true`）
- 更新脚本：重新跑一遍 `setup.sh` 即可；或等下次定时触发时自动自更新

**判断当晚是否真退了**：第二天看网页里各账号的「最后执行日期」是否变成当天；
或直接 `grep -i 退订 /var/log/scheduled-refund.log` 看当晚 23:35 前后的记录。

## 注意事项

- 云主机 7×24 在线，定时任务即持续生效；关浏览器、关本地电脑都不影响。
- 脚本只动 `user_data` 里 `schedule_enabled=true` 且设定时间在 **23:35–23:59** 的账号，其它不动。
- 阿里云 AK/SK 仍从你的 Supabase `user_data` 读取（与浏览器行为一致），VM 上不存任何密钥。
- 本仓库的 GitHub Actions 定时工作流已被 Disable（不可靠，会错过窗口）；如有需要可去
  Actions 页面重新启用，但两个调度器并存也不会重复退（脚本有按 AK 去重 + 窗口判断）。
- 安全提醒：之前用于推送的本仓库 GitHub PAT 如已不再需要，建议去 GitHub 撤销。

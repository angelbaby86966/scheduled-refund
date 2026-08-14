# 定时退订 · Oracle 永久免费云主机部署指南

解决「关闭浏览器就不到点退订」的问题：把退订脚本放到一台 **7×24 永远开机的免费云主机**上，
由系统定时器每 10 分钟跑一次，完全不依赖浏览器、也不依赖不稳定的 GitHub Actions。

> 退订逻辑沿用已验证的 `scheduled_refund.py`（纯 Python 标准库，零依赖），只在 23:35–23:59（北京时间）
> 窗口内、且账号开启定时时才退订，重复凭证按 AK 去重只退一次。

---

## 一、注册 Oracle Cloud 免费账号

1. 打开 https://www.oracle.com/cloud/free/ → 注册（**免费**，需信用卡验证，但不扣费）。
2. 注册时会让你选「主页区域（Home Region）」，选一个你顺眼的即可（下面用 Ampere 形状规避区域限制，所以区域不影响免费）。

## 二、创建永久免费虚拟机（Always Free）

1. 控制台 → **计算和存储 / Compute → 实例 → 创建实例**。
2. 映像（操作系统）：选 **Oracle Linux 9**（或 Ubuntu 22.04，均可）。
3. 形状（Shape）：点「更改形状」→ 选 **Ampere A1（VM.Standard.A1.Flex）**：
   - OCPU = **1**，内存 = **6 GB**（在「4 OCPU / 24 GB 永久免费额度」内，**全球所有区域都免费**）。
   - ⚠️ 不要选 Micro（VM.Standard.E2.1.Micro）——它只在部分区域永久免费，容易踩坑。
4. 网络：保持默认（会自动建 VCN 并放通入站 SSH 22）。
5. 密钥：选「生成 SSH 密钥对」并下载私钥（或粘贴你自己的公钥）。记下私钥文件。
6. 点创建，等几分钟变「正在运行」，记下 **公网 IP**。

## 三、登录 VM 并一键部署

本地终端（用下载的私钥）：

```bash
# Oracle Linux 默认用户是 opc；Ubuntu 是 ubuntu
chmod 600 你的私钥.key
ssh -i 你的私钥.key opc@<VM公网IP>
```

登录后，在 VM 里执行（一条命令搞定）：

```bash
curl -fsSL https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/setup.sh -o setup.sh
chmod +x setup.sh
sudo bash setup.sh
```

脚本会自动：装好目录 → 拉取 `scheduled_refund.py` → 建 systemd 服务+定时器（每 10 分钟）→
立即试跑一次并打出日志。看到日志里出现「共读取 N 个用户配置」即表示连通正常。

## 四、验证与日常维护

- 实时看日志：`journalctl -u scheduled-refund.service -f`
- 看文件日志：`tail -f /var/log/scheduled-refund.log`
- 看下次触发：`systemctl show scheduled-refund.timer -p NextElapseUSec --value`
- 停止定时：`sudo systemctl stop scheduled-refund.timer`
- 重启 VM 后定时器会自动恢复（Persistent=true）

**判断当晚是否真退了**：第二天看网页里各账号的「最后执行日期」是否变成当天；
或直接 `grep -i 退订 /var/log/scheduled-refund.log` 看当晚 23:35 前后的记录。

## 五、注意事项

- 这台 VM 是**永久免费 + 永远开机**，定时任务即 7×24 生效；关浏览器、关本地电脑都不影响。
- 脚本只动 `user_data` 里 `schedule_enabled=true` 且设定时间在 **23:35–23:59** 的账号，其它不动。
- 阿里云 AK/SK 仍从你的 Supabase `user_data` 读取（与浏览器行为一致），VM 上不存任何密钥。
- 若某天不再需要 GitHub Actions 那条不可靠的定时（可选）：去仓库
  `angelbaby86966/scheduled-refund` 的 Actions 页面把 `scheduled-refund` 工作流 **Disable** 即可，
  两个调度器并存也不会重复退（脚本有按 AK 去重 + 窗口判断）。
- 安全提醒：之前用于推送的本仓库 GitHub PAT 如已不再需要，建议去 GitHub 撤销。

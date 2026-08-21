# 阿里云轻量云定时自动退订

解决「关闭浏览器就不到点退订」的问题，把退订放到服务端按计划自动执行。
本仓库内置**两套互不冲突的方案**，按需选用：

- **方案 A（GitHub Actions 单账号版）**：最快接入，推代码 + 配 Secrets 即可，每天北京时间 23:35 自动跑。
- **方案 B（常驻云主机多账号版 / Python）**：部署到一台 7×24 云主机用 systemd 定时，不依赖 GitHub Actions，支持多账号。

---

## 方案 A：GitHub Actions 单账号定时退订（推荐快速接入）

### 原理

GitHub Actions 按计划运行（默认每天北京时间 23:35），自动：

1. 查询指定地域的轻量云服务器实例列表。
2. 对所有实例调用 BSS `RefundInstance` 真正退款。
3. 有界并发 + 全局 QPS 限速 + 限流自动退避重试 + 幂等 clientToken（不重复退款）。

脚本入口：`index.js`（Node.js，依赖 `@alicloud/pop-core`）。

### 部署步骤

#### 1. 设置 Secrets 和 Vars

进入仓库 **Settings → Secrets and variables → Actions**：

- `Secrets` → 新建 Repository secrets：
  - `ALIYUN_AK`：阿里云 AccessKeyId
  - `ALIYUN_SK`：阿里云 AccessKeySecret
- `Variables`（可选）→ 新建 Repository variables：
  - `REGIONS`：要退订的地域列表，例如 `cn-shenzhen,cn-chengdu`，不填则默认全部 6 个地域。

#### 2. 推送代码

```bash
cd /Users/zhangrui/WorkBuddy/2026-08-16-07-20-36/scheduled-refund
git push origin main
```

#### 3. 验证

进入仓库 **Actions → 阿里云轻量云定时自动退订 → Run workflow**，手动跑一次看日志。

### 修改定时时间

编辑 `.github/workflows/scheduled-refund.yml` 中的 cron：

```yaml
schedule:
  - cron: '35 15 * * *'   # 北京时间 23:35（UTC 15:35）
```

### 本地测试

```bash
export ALIYUN_AK=xxx
export ALIYUN_SK=xxx
export REGIONS=cn-shenzhen,cn-chengdu
npm install
npm run refund
```

---

## 方案 B：常驻云主机多账号定时退订（VM / Python 版）

把退订脚本放到一台 **7×24 永远开机的云主机**上，由系统定时器（systemd）每 10 分钟跑一次，
完全不依赖浏览器、也不依赖不稳定的 GitHub Actions。

> 退订逻辑沿用已验证的 `scheduled_refund.py`（纯 Python 标准库，零依赖），只在 23:35–23:59（北京时间）
> 窗口内、且账号开启定时时才退订，重复凭证按 AK 去重只退一次，且用按 region+instance 派生的
> **幂等 ClientToken** 跨执行去重，杜绝重复退款。

### 推荐方案：阿里云 轻量应用服务器（¥38–68/年）

1. 阿里云控制台 → **产品与服务 → 轻量应用服务器 → 创建实例**。
2. 镜像：选 **Alibaba Cloud Linux 3** 或 **Ubuntu 22.04**。
3. 套餐：选 **2 核 2G**（新用户秒杀 ¥38/年、常规 ¥68/年）。
4. 设置实例密码（默认用户 `root`），创建后记下 **公网 IP**。
5. 控制台「防火墙」标签页确认 **SSH(22)** 已放行。

登录并一键部署：

```bash
ssh root@<公网IP>
curl -fsSL https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/setup.sh -o setup.sh
chmod +x setup.sh
sudo bash setup.sh
```

脚本会自动：装依赖 → 拉取 `scheduled_refund.py` → 建 systemd 服务+定时器（每 10 分钟）
→ 立即试跑一次。看到日志里出现「共读取 N 个用户配置」即连通正常。

### 备选方案：Oracle Cloud 永久免费 VM（0 元）

1. 注册 https://www.oracle.com/cloud/free/ （需信用卡验证但不扣费）。
2. 创建 Always Free 实例：Oracle Linux 9 或 Ubuntu 22.04；形状选 **Ampere A1**（OCPU=1、内存=6GB）。
3. 部署命令同上方（把 `ssh` 换成 Oracle 的 `opc@<VM公网IP> -i 私钥.key`）。

### 验证与日常维护（方案 B 通用）

- 实时日志：`journalctl -u scheduled-refund.service -f`
- 文件日志：`tail -f /var/log/scheduled-refund.log`
- 下次触发：`systemctl show scheduled-refund.timer -p NextElapseUSec --value`
- 停止定时：`sudo systemctl stop scheduled-refund.timer`
- 更新脚本：重新跑一遍 `setup.sh`，或等下次定时触发时自动自更新

---

## 注意事项

- 退订脚本调用阿里云 BSS 退订接口，**会真正退款**，请确保 AK/SK 有 `AliyunBSSFullAccess` 权限。
- 默认地域：`cn-hangzhou,cn-beijing,cn-shanghai,cn-shenzhen,cn-chengdu,cn-guangzhou`。
- 方案 A 的 AK/SK 从 GitHub Secrets 读取；方案 B 的 AK/SK 从你的 Supabase `user_data` 读取（VM 上不存密钥）。
- 两套方案并存也不会重复退：方案 A 用固定 clientToken 幂等，方案 B 有按 AK 去重 + 窗口判断。
- 安全提醒：本仓库使用的 GitHub PAT 如已不再需要，请去 GitHub 撤销。

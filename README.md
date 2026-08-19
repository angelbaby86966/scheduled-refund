# 阿里云轻量云定时自动退订

服务端定时执行，**关闭浏览器也能到点退订**。

## 原理

GitHub Actions 按计划运行（默认每天北京时间 23:35），自动：

1. 查询指定地域的轻量云服务器实例列表。
2. 对所有实例调用 BSS `RefundInstance` 真正退款。
3. 内置全局 QPS 限速 + 全局限流冷却，避免触发阿里云账号级限流。

## 快速部署

### 1. 创建 GitHub 仓库

在 GitHub 上创建空仓库 `angelbaby86966/scheduled-refund`（不要初始化 README）。

### 2. 设置 Secrets 和 Vars

进入仓库 **Settings → Secrets and variables → Actions**：

- `Secrets` → 新建 Repository secrets：
  - `ALIYUN_AK`：阿里云 AccessKeyId
  - `ALIYUN_SK`：阿里云 AccessKeySecret
- `Variables`（可选）→ 新建 Repository variables：
  - `REGIONS`：要退订的地域列表，例如 `cn-shenzhen,cn-chengdu`，不填则默认全部 6 个地域。

### 3. 推送代码

```bash
cd /Users/zhangrui/WorkBuddy/2026-08-16-07-20-36/scheduled-refund
git init
git add .
git commit -m "init: scheduled refund"
git remote add origin https://github.com/angelbaby86966/scheduled-refund.git
git push -u origin main
```

### 4. 验证

进入仓库 **Actions → 阿里云轻量云定时自动退订 → Run workflow**，手动跑一次看日志。

## 修改定时时间

编辑 `.github/workflows/scheduled-refund.yml` 中的 cron：

```yaml
schedule:
  - cron: '35 15 * * *'   # 北京时间 23:35（UTC 15:35）
```

[cron 时区转换](https://www.timeanddate.com/worldclock/converter.html)

## 本地测试

```bash
export ALIYUN_AK=xxx
export ALIYUN_SK=xxx
export REGIONS=cn-shenzhen,cn-chengdu
npm install
npm run refund
```

## 注意事项

- 该脚本调用的是阿里云 BSS 退订接口，会真正退款，请确保 AK/SK 有 `AliyunBSSFullAccess` 权限。
- 地域列表默认：`cn-hangzhou,cn-beijing,cn-shanghai,cn-shenzhen,cn-chengdu,cn-guangzhou`。
- 若某地域无实例，会直接跳过。

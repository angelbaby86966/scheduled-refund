# 阿里云函数计算（FC）定时退订 · 已上线（2026-11-09 根治版）

## 配置总览（以下均为 2026-11-09 直连 FC API 实测回读，非推测）

| 项 | 值 |
|---|---|
| 服务 / 函数 | `scheduled-refund-svc` / `refund` |
| runtime / handler | **`python3.10` / `fc_main.handler`**（不是 nodejs20！） |
| 代码 | 单文件 `fc_main.py`，仓库源码 `fc/refund/fc_main.py` |
| 地域 / endpoint | `cn-hangzhou` / `https://<主账号UID>.cn-hangzhou.fc.aliyuncs.com` |
| 触发器① | `refund-trigger`：`0 35 15 * * *` = 北京 **23:35**，`enable=true` |
| 触发器② | `refund-trigger-fallback`：`0 50 15 * * *` = 北京 **23:50**，`payload={"immediate":true}`，`enable=true` |
| DRY_RUN | `false`（每日真退订） |
| 排除实例 | 读 Supabase `user_data.schedule_exclude_instance_ids`（全局合并）**＋** 函数环境变量 `EXCLUDE_INSTANCE_IDS`（前端排除文本框 7 个 ID 固化兜底）；三层拦截 + fail-closed |
| 函数描述 | `定时退订(张瑞瑶61) 排除实例保护 v2026-11-09（凭证按 Supabase 档案，DRY_RUN=false）` |

## 凭证方案（2026-11-09 全量换为「张瑞瑶61」）

- **部署 / 管理凭证**：GitHub Actions Secrets `ALIYUN_AK` / `ALIYUN_SK` **和** FC 函数环境变量
  `ALIYUN_AK` / `ALIYUN_SK`，均已换成用户 2026-11-09 提供的「张瑞瑶61」一套。
  STS `GetCallerIdentity` 验证有效（主账号 UID `1107***`）。
- **运行时退订凭证**：FC 代码与 Actions / Edge Function 一样，从 Supabase `user_data` 的
  `ak_profiles` 里按 `schedule_ak_ids` 勾选读取（当前勾选 张瑞瑶65/67/68/69）。
  **这套凭证本次没有改动** —— 换掉会改变退订目标账号，属于另一件事。
- FC 环境变量共 7 项：`DRY_RUN`、`SUPABASE_URL`、`SUPABASE_ANON_KEY`、
  `ALIYUN_AK`、`ALIYUN_SK`、`EXCLUDE_INSTANCE_IDS`、`EXCLUDE_PROTECT_VERSION`。

## 2026-11-09 事故根因（纠正此前两份错误结论）

网页「排除实例」文本框只把 ID 写进 Supabase，三套云端执行器原先都不读，
导致 11-08 晚把 7 台排除实例全部退掉（SWAS 释放后不可恢复）。

**此前文档/结论里两处判断是错的，已实测推翻：**

1. ~~FC 是 `nodejs20`、用 `fc/refund/index.js`~~ → 实际是 **python3.10 / fc_main.handler**，
   线上代码是 46KB 的 Python 全功能版（含并发退订、ClientToken 幂等、已退状态机）。
   按旧脚本推 Node 代码上去，函数会直接跑不起来。
2. ~~FC 因 AK 失效而空转、昨晚是 Edge Function 动的手~~ → 旧的 `ALIYUN_AK` 失效只影响
   **我们通过仓库 Secrets 探测/部署 FC 的通道**；FC 函数自己用 Supabase 里的用户凭证，
   `DRY_RUN=false`、两个触发器都启用，**昨晚真正退订的就是 FC（23:35 主 + 23:50 兜底）**，
   Edge Function 也可能参与。`_fc_heartbeat` 停在 9-15 不能作为 FC 停跑的证据。

**顺带修掉的隐藏 bug**：FC 容器复用会让 `IMMEDIATE` 环境变量跨调用残留。
23:50 fallback 触发器带 `{"immediate":true}` 调用过之后，同一容器里后续普通定时调用
也会被误判成「立即退订」而跳过 23:35–23:59 时间窗闸门。现在 handler 每次入口先清空
`IMMEDIATE`，再按本次 event 决定是否开启。

## 三套执行器统一保护（现状）

| 执行器 | 代码位置 | 状态 |
|---|---|---|
| GitHub Actions | `scheduled_refund.py` | ✅ 已上线；空跑日志「排除实例保护名单已加载：7 个」 |
| Supabase Edge Function | `supabase/functions/aliyun-proxy/index.ts` | ✅ 已部署到两个项目；真实排除 ID 调用返回 `exclude-list-protected` |
| 阿里云 FC | `fc/refund/fc_main.py` | ✅ **2026-11-09 已直连部署并线上验证** |

**fail-closed**：任何一套读不到 / 解析不了保护名单时，该套拒绝执行任何退订，
而不是「当名单为空继续退」。FC 另有 `EXCLUDE_INSTANCE_IDS` 环境变量固化文本框内容，
即使 Supabase 字段被误删、改格式，这 7 台依然不会被退。

## 部署与验证

- 部署：`ops/deploy_fc_refund.py`（由 `.github/workflows/deploy-fc-refund.yml` 手动触发，
  `mode=deploy`）。脚本会：探测函数 → 校验 runtime/handler → 上传 `fc_main.py` →
  回读并合并环境变量（带上原 `DRY_RUN` / Supabase 配置，避免全量替换丢字段）→
  从 Supabase 实时读取排除文本框名单写入 `EXCLUDE_INSTANCE_IDS`。
  凭证轮换后重跑一次 workflow 即可同步。
- 绝不要再引用 `fc/refund/index.js`：那是 2026-11-09 上午误判 runtime 时生成的 Node 版历史产物，
  已标注废弃，**不适用于本函数**。
- **本地断言**：7 组全通过（fail-closed / 三种格式兼容 / 全局合并 / ENV 兜底 /
  列举层剔除 / 退订前二次过滤 / BSS 调用最底层硬拦截 / main 拒绝执行），全程 mock 无真实请求。
- **线上回读**：`get_function_code` 下载的代码与仓库 `fc/refund/fc_main.py` 逐字节一致；
  环境变量 7 项齐全，`ALIYUN_AK=LTAI5t96***`，`EXCLUDE_INSTANCE_IDS` 7 个。
- **线上 invoke 验证**（空 payload、北京时间 11:35 不在窗口）：
  日志 `🛡️ 排除实例保护名单已加载：7 个（其中文本框兜底 7 个）`，`error=None`，
  **零 `RefundInstance` 请求、零退订**。

## 运行方式（与 GitHub Actions / Edge Function 并行）

- FC 定时器：每天 23:35 主触发 + 23:50 fallback 兜底。
- GitHub Actions `scheduled-refund`：UTC `25-59/10 15 * * *` = 北京 23:25–23:59 每 10 分钟。
- Edge Function：cron-job.org 每分钟按用户设定分钟匹配。
- 三套对同一批实例退订，已退 / 不存在会跳过，ClientToken 幂等，重复触发无副作用。

## 安全提醒

- **禁止用 `{"immediate": true}` 手动调用 FC 函数**：会跳过时间窗闸门，立即真退订现有实例。
  普通空 payload 调用在非窗口时段是安全的（本次已用这种方式验证）。
- 函数环境变量里是主账号 AK/SK，建议定期轮换；轮换后务必重跑
  `deploy-fc-refund.yml`（mode=deploy），让 Secrets 与 FC 环境变量保持一致。
- 三套执行器并存是长期隐患：以后任何保护逻辑都要同步三处，极易漏。

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
| 排除实例 | **权威名单 = Supabase `user_data.schedule_exclude_instance_ids`**（全局合并、实时跟随前端文本框）；三层拦截 + fail-closed。`EXCLUDE_INSTANCE_IDS` 只是部署快照，**仅诊断、不参与放行** |
| 函数描述 | `定时退订(张瑞瑶61) 排除实例保护 v2026-11-09b（凭证按 Supabase 档案，DRY_RUN=false）` |

## 凭证方案（2026-11-09 全量换为「张瑞瑶61」）

- **部署 / 管理凭证**：GitHub Actions Secrets `ALIYUN_AK` / `ALIYUN_SK` **和** FC 函数环境变量
  `ALIYUN_AK` / `ALIYUN_SK`，均已换成用户 2026-11-09 提供的「张瑞瑶61」一套。
  STS `GetCallerIdentity` 验证有效（主账号 UID `1107***`）。
- **运行时退订凭证**：FC 代码与 Actions / Edge Function 一样，从 Supabase `user_data` 的
  `ak_profiles` 里按 `schedule_ak_ids` 勾选读取（当前勾选 张瑞瑶65/67/68/69）。
  **这套凭证本次没有改动** —— 换掉会改变退订目标账号，属于另一件事。
- FC 环境变量共 7 项：`DRY_RUN`、`SUPABASE_URL`、`SUPABASE_ANON_KEY`、
  `ALIYUN_AK`、`ALIYUN_SK`、`EXCLUDE_INSTANCE_IDS`、`EXCLUDE_PROTECT_VERSION`。
  其中 `EXCLUDE_INSTANCE_IDS` 是部署时从文本框抓的快照（7 个 ID），只用于日志核对，
  **不参与放行**；`EXCLUDE_PROTECT_VERSION` 当前为 `2026-11-09-fc-python-v2`。

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

**fail-closed（三套统一规则，11:50 回归体检后定稿）**：

1. Supabase 读取失败 / 字段类型脏 → 该套**拒绝执行任何退订**；
2. **全体用户都缺 `schedule_exclude_instance_ids` 字段**（配置被误删）→ 同样拒绝执行，
   绝不当成「空名单继续退」；
3. 只要有用户带该字段（哪怕是空数组 = 用户主动清空）→ 以全局合并结果为准，
   前端改文本框**立即生效**，无需重新部署；
4. FC 的 `EXCLUDE_INSTANCE_IDS` 是部署快照，**只用于日志核对，不参与放行** ——
   若与 Supabase 名单取并集，用户在前端删掉某台后 FC 仍按旧快照保护，
   会与 Actions / Edge / 前端三套行为不一致（那台永远退不掉）。

## 部署与验证

- 部署：`ops/deploy_fc_refund.py`（由 `.github/workflows/deploy-fc-refund.yml` 手动触发，
  `mode=deploy`）。脚本会：探测函数 → 校验 runtime/handler → 上传 `fc_main.py` →
  回读并合并环境变量（带上原 `DRY_RUN` / Supabase 配置，避免全量替换丢字段）→
  从 Supabase 实时读取排除文本框名单写入 `EXCLUDE_INSTANCE_IDS` 快照（仅诊断）。
  凭证轮换后重跑一次 workflow 即可同步。
- 绝不要再引用 `fc/refund/index.js`：那是 2026-11-09 上午误判 runtime 时生成的 Node 版历史产物，
  已标注废弃，**不适用于本函数**。
- **本地断言**：体检 v2 共 **20 组**（FC 11 组 + Actions 9 组）全通过，
  覆盖 fail-closed / 三格式 / 全局合并 / 快照不参与放行 / 底层硬拦截 / 列举层 /
  退订前过滤 / 分页终止 / 受保护实例不空转 / 文本框实时跟随 / 字段误删拒绝 /
  handler 日志可见 / IMMEDIATE 残留；全程 mock，零真实请求。
- **线上回读**：`get_function_code` 下载的代码与仓库 `fc/refund/fc_main.py` 逐字节一致；
  环境变量 7 项齐全，`ALIYUN_AK=LTAI5t96***`，`EXCLUDE_INSTANCE_IDS` 7 个（仅快照）。
- **线上 invoke 验证**（空 payload、非时间窗）：
  日志 `🛡️ 排除实例保护名单已加载：7 个（来源：前端排除文本框 / Supabase 实时）`，
  `error=None`，**零 `RefundInstance` 请求、零退订**。

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

## 回归体检（2026-11-09 11:50，用户：「确定不会有啥 bug 吧」）

直连 FC 下载线上代码逐段审查 + mock 动态复现，查出并修掉 5 个缺陷：

| # | 缺陷 | 影响 | 修复 |
|---|---|---|---|
| 1 | `list_instances()` 用 `len(out) >= TotalCount` 判断翻页，out 是**过滤后**数量 | 账号里只剩排除机时会多翻页；极端情况下 API 超页返回首页会死循环 | 改为按原始 `insts` 条数 / `page * PAGE_SIZE` 判断（FC + Actions） |
| 2 | `drain_credential()` 只判断 `all_instances` 非空，targets 过滤在之后 | **保留排除机时每天必现**：连跑 12 轮「列全部地域→全被过滤→sleep」，白打 API 并误报「仍有实例」 | targets 为空立即 break（FC + Actions） |
| 3 | FC 把 `EXCLUDE_INSTANCE_IDS` 快照与 Supabase 名单取**并集** | 用户在前端删掉某台后 FC 仍按旧快照保护，那台永远退不掉，与另三套不一致 | 快照改为仅诊断；权威名单只有 Supabase，改文本框立即生效 |
| 4 | 主名单失败时 `sys.exit(1)`，`SystemExit` 穿透 handler 的 `except Exception` | FC 控制台只看到「函数失败」，看不到任何原因日志 | 改 `raise RuntimeError`，handler 返回 `ok=false + error + logs` |
| 5 | 「触发执行的用户数」用 `schedule_last_executed_date != 今天` 估算 | 不在时间窗时误报「触发 3 个用户」，实际一台没退 | 改为中性扫描数，实际触发看上方 ▶ 行 |

顺带补齐三套一致性：Actions 与 Edge 原先在**全体用户都缺排除字段**时会当成空名单继续退，
现在与 FC 一样 fail-closed 拒绝；Edge 还会对脏类型抛错而非静默忽略。

**未改动 / 已确认无问题**：前端浏览器端补跑在列举时就过滤排除实例且分页按 `TotalCount>100`
（无空转、无多翻页）；Edge `listAll()` 分页同样按 total 计算页数；Edge 定时 / 批量 /
单实例 / 探测四条退款路径全部经过 `assertNotExcluded()`；FC 容器复用 `IMMEDIATE` 残留已修。

**仍需注意的既有行为（非本次引入）**：
- `refund-trigger-fallback`（23:50，payload `immediate=true`）会跳过时间窗闸门，
  对**所有** `schedule_enabled` 用户执行，因此用户设定的 23:36 / 23:51 实际由 23:50 兜底统一执行，
  设定分钟不精确。排除保护对该路径同样生效。
- FC 默认禁用河源 / 武汉 / 乌兰察布 3 个地域，Edge 的地域表更宽；地域范围三套不完全一致。
- 三套并发对同一实例退订时 ClientToken 可能不同，但首次成功后实例释放，
  后续调用返回 `ResourceNotExists` 视为跳过，不会重复退款。

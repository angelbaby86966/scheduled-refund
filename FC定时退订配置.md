# 阿里云函数计算（FC）定时退订 · 已上线

> 目标：把"定时退订"放在阿里云自家免费额度内，关机 / 关浏览器 / 关机都照常跑，每天真定时、稳定。

## 配置总览
| 项 | 值 |
|---|---|
| 服务 | `scheduled-refund-svc` |
| 函数 | `refund`（runtime `nodejs20`，超时 600s，内存 256MB） |
| 触发器 | `refund-trigger`（timer） |
| Cron | `0 35 15 * * *` = **UTC 15:35 = 北京时间 23:35**，每天启用 |
| 覆盖地域 | 9 个：杭州 / 北京 / 上海 / 深圳 / 成都 / 广州 / 河源 / 武汉(`cn-wuhan-lr`) / 乌兰察布(`cn-wulanchabu`) |
| 退订逻辑 | 按地域 `ListInstances` 列出 → BSS `RefundInstance` 退订；非全额 / 已退 / 不存在自动跳过；限流自动退避重试 |
| DRY_RUN | 已设为 `false`（每日真退订） |
| 排除实例 | **统一读取 Supabase `user_data.schedule_exclude_instance_ids`**（2026-11-09 根治）；列举 / 退订前 / 退款调用三层过滤，名单读取失败一律拒绝退订 |

## 凭证方案
- **当前生效**：函数环境变量 `ALIYUN_AK` / `ALIYUN_SK`（用户授权，与主账号同源，GitHub Actions Secrets 同款）。
- **安全备选（已建好，暂未启用）**：RAM 角色 `scheduled-refund-fc-role`（策略 `swas:*` + `AliyunBSSFullAccess`）。因函数计算平台对服务角色 STS 临时凭证有独立缓存（TTL 内不随策略变更刷新），实测未能即时生效，故先走环境变量 AK 方案。待平台凭证缓存刷新后，可改函数读 `ALIBABA_CLOUD_*` 并删除环境变量，切回零长期密钥。

## 验证记录
- DRY_RUN 手动 invoke：9 地域 `ListInstances` 全部成功返回（当前账号实例数为 0，与一直退订吻合），武汉 `cn-wuhan-lr` 正确，无 error。
- 触发器已确认存在且 `enable=true`。

## 排除实例保护（2026-11-09 事故根治）

事故：网页「排除实例」只写到 Supabase，云端三套执行器都不读该字段，导致 11-08 晚
定时退订把用户配置的 7 台排除实例全部退掉（SWAS 释放后不可恢复）。

现在三套执行器共用同一份保护名单（全局合并所有用户的 `schedule_exclude_instance_ids`）：

| 执行器 | 代码位置 | 保护实现 |
|---|---|---|
| GitHub Actions | `scheduled_refund.py` | `load_exclude_ids()` + `list_instances()` / `drain_credential()` / `refund_instance()` 三层 |
| Supabase Edge Function | `supabase/functions/aliyun-proxy/index.ts` | `loadExcludeIds()` + `assertNotExcluded()` 覆盖批量 / 定时 / 单实例 / 探测全部入口 |
| 阿里云 FC | `fc/refund/index.js` | `loadExcludeIds()` + `refundOne()` 最底层硬拦截 |

**fail-closed**：任何一套读不到保护名单（Supabase 故障 / 网络异常 / 脏数据）时，
该套**拒绝执行任何退订**，而不是「当名单为空继续退」。这是防止再次误退的关键。

部署：FC 代码不走仓库自动同步，需通过 `.github/workflows/deploy-fc-refund.yml`
（使用仓库 Secrets `ALIYUN_AK` / `ALIYUN_SK`）手动触发一次部署；Edge Function 由
`deploy-edge-functions.yml` 在 main 变更时自动部署。

### 2026-11-09 实测结论（FC 自动部署通道当前不可用，但无残留风险）
- 用仓库 Secrets 调 STS `GetCallerIdentity` 返回
  `404 Specified access key is not found` → **`ALIYUN_AK` 已被删除**，FC 环境变量若同源则同样失效，
  FC 即使触发也调不通阿里云 API，无法退订任何实例；`_fc_heartbeat` 最后心跳停在 2026-09-15 亦吻合。
- 昨晚真正执行退订的是 **Supabase Edge Function `RunScheduledCancel`**（cron-job.org 每分钟、
  按 23:36 匹配），它用的是 `user_data` 里用户自己的 AK/SK，仍有效；该套已修复并线上验证通过。
- 若日后轮换 AK/SK，重跑 `deploy-fc-refund.yml`（mode=deploy）即可把 `fc/refund/index.js` 推上 FC；
  在那之前**建议在 FC 控制台停用 `refund-trigger`**，把定时退订统一收敛到已修复的两套。
- 修补版固定版本（可直接粘贴到 FC 控制台）：
  `https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@9e94c2ff9c226035a9a04088f02023d871dabb52/fc/refund/index.js`

## 运行方式（与 GitHub Actions 并行）
- FC 定时器：阿里云侧服务端，每天 23:35 自动触发。
- GitHub Actions `scheduled-refund`：每天 23:35 自动触发（cron `35 15 * * *` UTC）。
- 两者对**同一账号**实例退订，逻辑幂等（已退 / 不存在跳过），重复触发无副作用。如无必要，保留其一即可；两套并存也不冲突。

## 安全提醒
- 函数环境变量中存放的是**主账号** AK/SK，建议定期轮换（阿里云控制台「RAM → 安全凭证」）。
- 不要手动在 FC 控制台点"测试/调用"函数去验证——那会立即真退订账号下现有实例；依赖每天 23:35 自动跑即可。

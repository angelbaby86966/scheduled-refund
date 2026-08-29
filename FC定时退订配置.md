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

## 凭证方案
- **当前生效**：函数环境变量 `ALIYUN_AK` / `ALIYUN_SK`（用户授权，与主账号同源，GitHub Actions Secrets 同款）。
- **安全备选（已建好，暂未启用）**：RAM 角色 `scheduled-refund-fc-role`（策略 `swas:*` + `AliyunBSSFullAccess`）。因函数计算平台对服务角色 STS 临时凭证有独立缓存（TTL 内不随策略变更刷新），实测未能即时生效，故先走环境变量 AK 方案。待平台凭证缓存刷新后，可改函数读 `ALIBABA_CLOUD_*` 并删除环境变量，切回零长期密钥。

## 验证记录
- DRY_RUN 手动 invoke：9 地域 `ListInstances` 全部成功返回（当前账号实例数为 0，与一直退订吻合），武汉 `cn-wuhan-lr` 正确，无 error。
- 触发器已确认存在且 `enable=true`。

## 运行方式（与 GitHub Actions 并行）
- FC 定时器：阿里云侧服务端，每天 23:35 自动触发。
- GitHub Actions `scheduled-refund`：每天 23:35 自动触发（cron `35 15 * * *` UTC）。
- 两者对**同一账号**实例退订，逻辑幂等（已退 / 不存在跳过），重复触发无副作用。如无必要，保留其一即可；两套并存也不冲突。

## 安全提醒
- 函数环境变量中存放的是**主账号** AK/SK，建议定期轮换（阿里云控制台「RAM → 安全凭证」）。
- 不要手动在 FC 控制台点"测试/调用"函数去验证——那会立即真退订账号下现有实例；依赖每天 23:35 自动跑即可。

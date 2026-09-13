# IPES 业务 41 一键部署 — 最终执行命令

> 脚本：`ipes_deploy_full.sh`（**v2026-09-13-r14**，SHA `1c389aa2`）
> 主源（jsDelivr，锁定 commit）：
> `https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@1c389aa252930db32791a505ff31de14df10da75/ipes_deploy_full.sh`
> 备源（ghproxy，带时间戳穿透缓存）：
> `https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_deploy_full.sh?t=$(date +%s)`
>
> ⚠️ **不要直接用 ghproxy 裸链而不校验版本**——它会缓存旧脚本，我们实测踩过：
> 明明推了 r10，机器上 `curl` 下来还是 r9，导致修复没生效。命令里必须带**缓存穿透 + 内容校验**（见下）。

---

## ⚠️ 先分清两条命令（踩过坑）

| | **官方 `zyy_init_max.sh`** | **我方 `ipes_deploy_full.sh`** ✅ |
|---|---|---|
| 干什么 | 只做**初始化 + 渠道绑定**（zycloud agent、用户、SSH、注册设备） | 初始化**+ Docker + IPES 部署 + 拉满 + 提交业务 + 节点属性 + 状态流转（含业务ID）** |
| 跑完的样子 | 后台只有「绑定」；happy 还是镜像自带的 5；状态停在待配置/未流转 | happy **9~12/12**、业务 41 已提交、运营商/资源类型已写、状态**「服务中」**、**业务ID 已回填** |
| 典型误用 | 以为它能一键完工 → 结果「只是绑定了，没有部署和流转」 | 就是要它 |

官方那条（**只绑定**，别拿它当部署用）：

```bash
curl https://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init/zyy_init_max.sh | bash -s -- --ak <AK> --sk <SK> --isp 电信
```

---

## ✅ 完整版最终命令（自动流转 · 单行 · 直接复制）

> 把 `<渠道AK>` `<渠道SK>` `<JWT>` 换掉即可。

```bash
SRC1="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@1c389aa252930db32791a505ff31de14df10da75/ipes_deploy_full.sh"; SRC2="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_deploy_full.sh?t=$(date +%s)"; for u in "$SRC1" "$SRC2"; do curl -fsSL -m 60 "$u" -o /root/ipes_full.sh && grep -q singleIpRadio /root/ipes_full.sh && break; done; sed -i 's|^mirrorlist=|#mirrorlist=|g;s|^#\?baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null; export NODE_ACTIVATE_TOKEN="<JWT>"; nohup setsid bash /root/ipes_full.sh --ak <渠道AK> --sk <渠道SK> --isp 电信 --num-dirs 12 --skip-olmt >/var/log/ipes_nohup.log 2>&1 </dev/null & echo "已后台启动 PID=$!"
```

> `grep -q singleIpRadio` 是**内容校验**：不通过就换备用源，避免下到 CDN 缓存的旧脚本。

**这条命令按顺序做完 12 步：**

| # | 步骤 | 产出 |
|---|---|---|
| 1 | zycloud agent 安装 | `/etc/.mac` = 设备SN |
| 2 | SSH / 用户 / 公钥 | admin、zhouyi 用户，免密切换 |
| 3 | 读设备 SN | `DEVICE_ID` |
| 4 | 注册设备（渠道绑定） | 后台出现该节点 |
| 5 | Docker | 已装则跳过 |
| 6 | **IPES 部署**（自动打镜像补丁→腾讯云公开镜像） | `ipes` 容器 |
| 6.5 | 看门狗 | cron 每分钟防 master 掉线 |
| 6.6 | `olmt.sh` | `--skip-olmt` 则跳过（本机不限速） |
| 7 | **`ipes_onekey`** | **happy 拉满 9/9**、NAT/对齐/缓存/镜像重建 |
| 8 | nload | 流量观测 |
| 9 | **降级 → 业务41+节点属性 → 流转(带业务ID) → 校验** | 见下 |
| 10 | SSH 安全收尾 | 禁 root 登录、清 root `.ssh`、改 root 密码 |
| 11 | admin 免密 sudo | 默认**保留**（与金标准一致） |

**第 9 步顺序错就全白干**（平台上「服务中」不允许改设备信息）：

| 顺序 | 动作 | 说明 |
|---|---|---|
| 9.1 | `stateflow → configured` | 先降到「待配置」，平台此时才允许改信息（并会删掉旧的 business_tags 占位记录） |
| 9.2 | `POST /api/edgeNode/updateEdgeNominalInfo` | 提交业务 41 + **节点属性**：body 必须带 `isp / natType / resourceType / dialType / province / city`（后台那两列就是靠它生成的） |
| 9.3 | `stateflow → inService`，**带 `hostname` = IPES 序列号** | 升回服务中；后台「业务ID」这一步写进去 |
| 9.4 | 回读校验 `nodeInfo` + 轮询 `business_tags.hostName`（180s） | **只读**，不再写 |

> ⚠️ **不要用 `PUT /api/edgeNode/updateEdgeNode` 去写 nodeInfo** —— 实测只会把它写成 `ID=0` 的空壳。
> nodeInfo 的**唯一**写入通道是 9.2 的 `updateEdgeNominalInfo`。

---

## 🔑 关键点：业务ID 必须在流转时带上

后台「状态流转」接口 body 是**三个字段**，少一个就写占位符 `ZHOUYI_XIAODU占位符`：

```json
{"nodes":["<节点ID>"], "stage":"inService", "hostname":"<业务ID>"}
                                          ↑ 漏了它 → 后台业务ID永远是占位符
```

- **业务ID 取值**：`docker exec ipes cat /app/ipes/bin/ipes_sn`（76 位 hex，尾 `69bccfe3bf24`）
- **必须两步**：平台在「服务中」状态**不允许改信息**（`updateEdgeNominalInfo` 会回 `设备处于服务中或交付中状态，不允许修改设备信息`），所以脚本固定走「先降 configured → 再升 inService」。
- 脚本已内置（`get_ipes_sn()` + `transition_to_serving()`），**无需手工填**。

---

## 🚀 必须是「后台异步」执行

云助手 RunCommand 默认超时很短（约 60s），而本流程要下 50M+ agent、拉镜像、预热对齐，跑几分钟 → 会被判**「执行失败」**，其实脚本还在后台正常跑。

所以命令里必须有：**`nohup setsid ... >/var/log/ipes_nohup.log 2>&1 </dev/null & echo PID=$!`**

- 命令**秒返回**，不再被判超时失败
- 真实进度看 `/var/log/ipes_nohup.log`（含远程脚本的原始输出）
- 结构化日志看 `/var/log/ipes_full_deploy.log`

---

## 📋 批量下发（多台同时）

用仓库里的 `fleet_deploy.py`（读实例清单 → 并行下发同一条命令）：

```bash
python3 fleet_deploy.py <凭证文件:AK<换行>SK> <实例清单:region instanceId name>
```

清单格式（每行一台）：

```
cn-shenzhen d6e0bfa7faae41319f414747bb125757 乾亿益-4-ecuv
cn-shenzhen bd2ca0d7910d457c89911056af238154 乾亿益-4-7bgv
```

巡检（一行一台，看绑没绑 / 部没部署 / happ 数）：

```bash
python3 fleet_diag2.py <凭证文件> <实例清单>
```

---

## 🩺 验收一条命令

```bash
echo "happ=$(pgrep -c -f happ)"; docker exec ipes ./bin/ipes health 2>&1 | tail -2; ls /data/happ | wc -l; grep -E "执行完毕|服务中|业务 41|错误|失败" /var/log/ipes_full_deploy.log | tail -12
```

后台侧验收（需 JWT）：看 `stage=inService`、`nominalInfo.isp/resourceType/dialType`、业务标签 `hostName` 是否 = IPES 序列号。

---

## 参数速查

| 参数 / 环境变量 | 说明 |
|---|---|
| `--ak` / `--sk` | 渠道 appKey / secretKey |
| `--isp` | 运营商（电信 / 联通 / 移动） |
| `--num-dirs` | 缓存目录数，云环境一般 **12** |
| `--skip-olmt` | 跳过本机 `olmt.sh` 带宽整形（跑满不封顶） |
| `--skip-onekey` | 跳过预热对齐（**不推荐**，happy 就不会拉满） |
| `--node-token` | 节点激活 token（等价于设 `NODE_ACTIVATE_TOKEN`） |
| `--target-happ` | 目标 happy 数，默认 **9** |
| `--resource-type` | 资源类型：1=汇聚 / **2=专线**（默认 2） |
| `--dial-type` | 上网方式：**staticNetSingle=固定公网单IP**（默认） |
| `NODE_ACTIVATE_TOKEN` | JWT，**推荐用环境变量传**（命令短、不进参数历史） |
| `NODE_NAT_TYPE` | 默认 `public`（固定公网） |
| `NODE_SINGLE_IP_RADIO` | 默认 `0`（单 IP） |
| `NODE_USBW` / `NODE_BW_NUM` | 默认 `200` / `1` |
| `ADMIN_STATUS_BODY` | 覆盖 stateflow 请求体（接口变体时用） |

---

## ⚠️ 云助手 / 终端粘贴必读（已踩坑）

1. **整条必须是一行** —— 有换行会被当命令分隔，导致 `--ak 06d7...: No such file or directory` 并连带 `curl: (23) Failed writing body`。
2. **token / AK / SK 不要套 `< >`** —— `<` 是重定向符，会报 `syntax error near unexpected token newline'`。
3. 推荐 `export NODE_ACTIVATE_TOKEN="..."` 传 token，命令更短。

---

## `--skip-olmt` 是什么意思

| 加 `--skip-olmt` | 不加 |
|---|---|
| 不跑 `olmt.sh` | 执行 `olmt.sh` |
| 不设带宽上限 | `tc htb` 限速封顶 |
| 纯 PCDN 跑量机器 | 混合业务 / 保护带宽 |

> 注意：`--skip-olmt` 只跳过**本机脚本自己设的限速**。平台（edge_client）下发的限速（如 64e 的 4 Mbps）这个开关去不掉，要走平台提档。

---

## 安全提示

- 不要把真实 token 写进文档 / 仓库 / 命令历史。
- 每次批量部署收尾后，**轮换**已在对话中出现过的 JWT、渠道 AK/SK、阿里云 AK/SK、GitHub PAT。
- `set_root_password` 会把 root 密码置为平台统一哈希；`disable_root_ssh_login` 后**只有 admin 能 SSH**（云助手是独立通道，可兜底）。

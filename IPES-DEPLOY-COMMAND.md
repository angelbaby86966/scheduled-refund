# IPES 一键部署 r21 — 最终执行命令（含磁盘吞吐 + 上下行调优）

> **✅ 部署链路已在 2026-09-13 乾亿益-4-* 深圳克隆机 60 台全量实战验证**：60/60 服务中、业务 41、属性全落上、业务ID 全回填（详见 `IPES全量部署验收报告-60台-20260913.md`）
> **✅ r21 调优项已在黄金机（cn-hangzhou 9f2adaf7）逐项实测标定**（2026-09-14，数据见文末「性能调优」）
>
> 脚本：`ipes_deploy_full.sh`（**v20260915e**，commit `477dc50494`）
> 新增：`ipes_tune.sh`（独立调优脚本，可单独对已跑量机器热应用）
>
> 🆕 **2026-09-15 修复「日志总卡在识别地区」**（commit `477dc50494` / r21 rev `20260915e`）
> 1. 地区识别改为**多源 + 每源都带超时**：`myip.ipip.net`（主，`--max-time 8`）→ `ip-api.com`（备，中文，含"天津市→天津"归一）→ 阿里云元数据 `100.100.100.200` 的 `region-id`（备，内网免 DNS）→ 兜底 `浙江/杭州`。每一步都打印实际取值。
> 2. 调优步骤不再 `bash ipes_tune.sh | tail -30`（管道会把输出憋到进程结束才吐 → 日志看着像卡死），改为**落盘 `/var/log/ipes_tune_run.log` + 每 10s 心跳 + `timeout 480` 硬上限**，结束时打印末尾 25 行。
> 3. r21 把识别到的 `--province/--city` **透传给 full.sh**（full.sh 新增该参数），一次识别、两处一致；否则 full.sh 会自己再识别一次，兜底值是"北京"，容易和 r21 打架。
> 4. 下载源扩为 3 个（ghproxy.net / ghfast.top / jsdelivr@commit），统一 `--connect-timeout 5`；full.sh 新增 `FULL_REV` 世代指纹，拒绝 CDN 缓存的旧版。
> 5. 修掉一个隐蔽坑：**UTF-8 locale 下 bash 会把紧跟变量的中文当成变量名的一部分**（`"$X，日志"` → 整段变空），全仓 echo/log 里的 `$VAR` 已统一改成 `${VAR}`。
>
> 主源（jsDelivr，锁定 commit）：
> `https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@477dc50494d42f7675233f0cd75be52cef1cb5d9/ipes_deploy_full.sh`
> 备源（ghproxy，带时间戳穿透缓存）：
> `https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_deploy_full.sh?t=$(date +%s)`
>
> ⚠️ **不要直接用 ghproxy 裸链而不校验版本**——它会缓存旧脚本，实测踩过：推了 r10 机器上 curl 下来还是 r9。命令里必须带**缓存穿透 + 内容校验**。

---

## 🚀 最快路径：短链一键（调优 + 部署）

> ### ⚠️ 两个符号会把命令搞坏：`<>` 和 `$`（都踩过了）
>
> **① 尖括号 `<>` 是输入重定向，不是占位符**
> `--ak <06d78b19...>` 会报 `06d78b19...: No such file or directory` + `curl: (23) Failed writing body`，
> 脚本**一行都不会执行**（bash 的 stdin 被重定向到不存在的文件）。
>
> **② 已经填了值的参数前面，绝对不能再加 `$`**
> `"$06d78b19..."` → `$0` 展开成**脚本自身路径**并拼到前面 → `/<路径>/t-xxx.sh6d78b19...`
> `"$16d6c464..."` → `$1` 展开为空 → 值变成 `6d6c464...`（**开头的 `1` 没了**）
> `"$eyJhbGci..."` → `$eyJhbGci...J9` 被当变量名（未定义）→ 值变成 `.eyJVVUlEIjoi...`（**开头的 `e` 没了**）
>
> 这三个值都非空，脚本的「缺参检查」**拦不住**，会一路跑到渠道注册才失败。判别口诀：
> **`$` 只能出现在「变量名」前面（`"$AK"`），一旦你已经把真值写进去了，`$` 必须删掉。**
>
> 正确写法就是**光秃秃的值**（外面包一层双引号是允许且推荐的）：`--ak "06d78b19..."`。

**第一步：填值**（只替换等号右边的中文，**不要留 `$`、不要留 `<>`**）

```bash
AK=你的渠道AK
SK=你的渠道SK
JWT=你的JWT
```

**第二步：一条命令跑完**（用变量最保险：这里的 `$AK/$SK/$JWT` 是**必须保留**的，因为它们是变量名）

```bash
curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/inline_deploy_r21_oss.sh?t=$(date +%s)" | bash -s -- --ak "$AK" --sk "$SK" --jwt "$JWT" --isp 电信
```

<details><summary>等价的单行版（把「你的渠道AK」等中文整段替换成值；替换后**整条命令里除了 `$(date +%s)` 之外不应再出现任何 `$`，也不应有 `<>`**）</summary>

```bash
curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/inline_deploy_r21_oss.sh?t=$(date +%s)" | bash -s -- --ak 你的渠道AK --sk 你的渠道SK --jwt 你的JWT --isp 电信
```

</details>

这条短链按顺序做三件事：

| 段 | 动作 |
|---|---|
| **A** | 下载并执行 `ipes_tune.sh` —— 磁盘队列 / 挂载 / 内核 / 网卡 / nofile 调优（幂等，可重复跑） |
| **B** | 下载 `ipes_deploy_full.sh` r21 并**后台异步**执行完整部署（主脚本内嵌同一份调优作兜底） |
| **C** | 内嵌 Python 自修复：业务绑定 / 业务ID 回填（对齐后台数据） |

> 只想**给已跑量的机器加调优**（不重新部署）：
> ```bash
> curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_tune.sh?t=$(date +%s)" | bash
> ```

---

## ⚠️ 先分清两条命令（踩过坑）

| | **官方 `zyy_init_max.sh`** | **我方 `ipes_deploy_full.sh`** ✅ |
|---|---|---|
| 干什么 | 只做**初始化 + 渠道绑定** | 初始化**+ 调优 + Docker + IPES 部署 + 拉满 + 提交业务 + 属性 + 状态流转（含业务ID）** |
| 跑完的样子 | 后台只有「绑定」，happy 仍是镜像自带值 | happy **9~12/12**、业务 41 已提交、运营商/资源类型已写、状态**「服务中」**、**业务ID 已回填** |

---

## ✅ 完整版最终命令（手动模式，单行可直接复制）

```bash
SRC1="https://cdn.jsdelivr.net/gh/angelbaby86966/scheduled-refund@4082428fe8df7c9fcbf5ac524d6af2249eafd871/ipes_deploy_full.sh"; SRC2="https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_deploy_full.sh?t=$(date +%s)"; for u in "$SRC1" "$SRC2"; do curl -fsSL -m 60 "$u" -o /root/ipes_full.sh && grep -q singleIpRadio /root/ipes_full.sh && break; done; sed -i 's|^mirrorlist=|#mirrorlist=|g;s|^#\?baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null; export NODE_ACTIVATE_TOKEN="$JWT"; nohup setsid bash /root/ipes_full.sh --ak "$AK" --sk "$SK" --isp 电信 --num-dirs 12 --skip-olmt >/var/log/ipes_nohup.log 2>&1 </dev/null & echo "已后台启动 PID=$!"
```

**这条命令按顺序做完 13 步：**

| # | 步骤 | 产出 |
|---|---|---|
| **0** | **系统调优（r21 新增）** | 磁盘队列 / 挂载 / sysctl / 网卡 / nofile，并装 `ipes-tune.service` 开机重放 |
| 1 | zycloud agent 安装 | `/etc/.mac` = 设备SN |
| 2 | SSH / 用户 / 公钥 | admin、zhouyi 用户，免密切换 |
| 3 | 读设备 SN | `DEVICE_ID` |
| 3.5 | 解析 32hex nodeId | admin 接口用 nodeId 而非 SN |
| 4 | 注册设备（渠道绑定） | 后台出现该节点 |
| 5 | Docker | 已装则跳过；**5.5 按需重启使容器继承新 nofile** |
| 6 | **IPES 部署** | `ipes` 容器 |
| 6.5 | 看门狗 | cron 每分钟防 master 掉线 |
| 6.6 | `olmt.sh` | `--skip-olmt` 则跳过（本机不限速） |
| 7 | **`ipes_onekey`** | **happy 补齐到 `TARGET_HAPP`（默认 6）**、NAT/对齐/缓存/镜像重建 |
| 8 | nload | 流量观测 |
| 9 | **降级 → 业务41+节点属性 → 流转(带业务ID) → 校验** | 见下 |
| 10 | SSH 安全收尾 | 禁 root 登录、清 root `.ssh`、改 root 密码 |
| 11 | admin 免密 sudo | 默认**保留**（与金标准一致） |

**第 9 步顺序错就全白干**（平台上「服务中」不允许改设备信息）：

| 顺序 | 动作 | 说明 |
|---|---|---|
| 9.1 | `stateflow → configured` | 先降到「待配置」，平台此时才允许改信息 |
| 9.2 | `POST /api/edgeNode/updateEdgeNominalInfo` | 提交业务 41 + **节点属性**：`isp / natType / resourceType / dialType / province / city` |
| 9.3 | `stateflow → inService`，**带 `hostname` = IPES 序列号** | 升回服务中；后台「业务ID」这一步写进去 |
| 9.4 | 回读校验 `nodeInfo` + 轮询 `business_tags.hostName` | **只读**，不再写 |

> ⚠️ **不要用 `PUT /api/edgeNode/updateEdgeNode` 写 nodeInfo** —— 实测只会写成 `ID=0` 空壳。唯一写入通道是 9.2 的 `updateEdgeNominalInfo`。
>
> ✅ **9.4 校验口径（2026-09-14 订正）**：只看 4 项 —— `nodeInfo.vendorSuggestCustomers==41`、`nodeInfo.usbw==200`、`nodeInfo.isp==电信`、`nodeInfo.resourceType=="2"`，且节点顶层 `stage==inService`/`status==online`，外加 `business_tags.hostName == 容器 ipes_sn`（76hex 真SN）。
> ❌ **不要用 `nodeInfo.ID` / `nodeInfo.boundTime` / `nodeInfo.stage` 当判据**：`updateEdgeNominalInfo` 返回 `code:0 更新成功` 也不会写它们；实测 `?businessID=41` 共 2489 台里 752 台（30%，含 330 台 inService 已跑 10 天）都是 `ID=0 + boundTime=null`，属常见形态，不代表未绑定。官方 `ipes_deploy_full.sh` 的回读校验同样不 grep ID。

---

## 🔑 业务ID 必须在流转时带上

```json
{"nodes":["<节点ID>"], "stage":"inService", "hostname":"<业务ID>"}
                                          ↑ 漏了它 → 后台业务ID永远是占位符 ZHOUYI_XIAODU占位符
```

- **业务ID 取值**：`docker exec ipes cat /app/ipes/bin/ipes_sn`（76 位 hex）
- **必须两步**：平台在「服务中」不允许改信息（会回 `设备处于服务中或交付中状态，不允许修改设备信息`），故脚本固定走「先降 configured → 再升 inService」

---

## 🚀 必须是「后台异步」执行

云助手 RunCommand 默认超时约 60s，而本流程要下 50M+ agent、拉镜像、预热对齐 → 会被判「执行失败」，其实脚本还在后台跑。

所以命令里必须有：**`nohup setsid ... >/var/log/ipes_nohup.log 2>&1 </dev/null & echo PID=$!`**

---

## 💿 性能调优（r21 核心新增）—— 面向「磁盘吞吐要快、要大，PCDN 上下行要高」

### 调优项清单

| 类别 | 项目 | 调优前 | 调优后 | 目的 |
|---|---|---|---|---|
| **磁盘队列** | I/O 调度器 | `mq-deadline` | **`none`** | 虚拟化层已有队列，双层排队只增延迟 |
| | 设备类型 | `rotational=1`（当机械盘） | **`0`** | 让内核按 SSD/云盘路径处理 |
| | 预读 | 256K | **256K（保持）** | ★实测：调大只利单流、明显害并发，见下 |
| | 合并 | `nomerges=0` | `0` | 大块顺序写靠合并减少 IO 次数 |
| | 单次 IO 上限 | 512K | **1024K** | 更大请求 → 更少次数 → 更高吞吐 |
| | 完成中断亲和 | 1 | **2** | 回提交核，减少跨核 cache 反弹 |
| **文件系统** | 挂载参数 | `noatime,nodiratime,data=ordered` | **+`commit=60,nobarrier`** | 日志提交 5s→60s、关写屏障（云盘块存储有保护） |
| **内核内存** | 脏页阈值 | 40 / 30 | **20 / 10** | 1G 小内存下 40/30 单次回写洪峰可达 370M，读请求被长时间阻塞 |
| **连接数** | `nofile` | **4096** | **1048576** | 高并发上下行的硬门槛（含 docker 容器继承） |
| **UDP** | `udp_mem` | 22095/29462/44190 | **65536/98304/131072** | PCDN 上行大量 UDP 小包 |
| | `udp_rmem/wmem_min` | 16384 | **32768** | 单 socket 缓冲下限 |
| **TCP** | `tcp_limit_output_bytes` | 262144 | **1048576** | 高 BDP 链路单流发送不被压住 |
| | `tcp_autocorking` | 1 | **0** | 上行小包立即发出，降延迟 |
| | 缓冲 | 32M | **64M** | 高并发 + 高 BDP |
| | 拥塞控制 | cubic | cubic（**BBR 不可用**，见下） | — |
| **网卡** | `txqueuelen` | 1000 | **10000** | 高发送速率不丢包 |
| | ring buffer | 默认 | **4096/4096** | 高 PPS 小包不丢 |
| | qdisc | `fq_codel` | **`fq`** | pacing 队列 |
| | RPS | 已开 | 全核 mask + `rps_flow_cnt=4096` | 单队列 virtio 必做 |
| **conntrack** | hashsize | 7530 | **32768** | 降锁竞争 |
| | raw NOTRACK | 无 | **已加** | 高并发省 CPU |
| **空间** | 容器日志/悬挂镜像/journal | — | **安全回收** | 满盘会明显劣化写入 |

### 实测数据（黄金机 cn-hangzhou 9f2adaf7，CentOS 7.9 / 2C / 941MB / 30G 云盘）

| 测试项 | 调优前 | 调优后 | 变化 |
|---|---|---|---|
| **单流冷缓存顺序读 256M**（走页缓存，对应「上行读缓存」） | 224 MB/s | **290 MB/s** | **+29%** |
| **8 流并发冷缓存读**（对应「多路并发行」） | 230 MB/s | 232 MB/s | 持平 |
| **8 流并发写 direct**（对应「并发拉缓存」） | 126 MB/s | **135 MB/s** | **+7%** |
| 单流顺序写 direct | 127 MB/s | 130 MB/s | +2%（噪声内） |
| I/O 调度器对比（8 流并发读） | `mq-deadline` 175 MB/s | **`none` 201 MB/s** | +15% |

### ⚠️ 一个反直觉结论：预读**不要**调大

原基线把 `read_ahead_kb` 设成 2048，实测是**负优化**：

| `read_ahead_kb` | 单流读（3 轮中位） | 8 流并发读（3 轮中位） |
|---|---|---|
| **256（内核默认）** | 247 MB/s | **237 MB/s** |
| 1024 | 246 MB/s | 208 MB/s |
| 2048 | 254 MB/s | 191 MB/s |
| 4096 | 221 MB/s | **158 MB/s（-30%）** |

**并发读随预读增大单调下降**，单流基本无差异。PCDN 是多个 happy 进程并发读缓存 → 属并发场景 → **保持 256K**。

### 已知做不了的事（如实说明）

| 项目 | 状态 | 原因 |
|---|---|---|
| **BBR 拥塞控制** | ❌ 不可用 | 阿里云 SWAS 镜像内核 `3.10.0-1160` **裁剪掉了 `tcp_bbr.ko`**，`tcp_available_congestion_control` 只有 `cubic reno`，自动回落 cubic |
| **`nr_requests` 加深** | ❌ 不可写 | virtio-blk 在 `scheduler=none` 下固定 128，写 1024/4096 均被内核拒绝 |
| **磁盘容量/吞吐上限** | ⚠️ 未动 | 30G 盘已用 93%、内存仅 941MB：这是**硬件天花板**。软件调优只能逼近，真正「快、大」需升配（内存 + 盘），而升配当前撞两堵墙：账户余额 0 + 渠道机商品模块不含 60G+ 档 |

---

## 📋 批量下发（多台同时）

```bash
python3 fleet_deploy.py <凭证文件:AK换行SK> <实例清单:region instanceId name>
```
清单格式（每行一台）：
```
cn-shenzhen d6e0bfa7faae41319f414747bb125757 乾亿益-4-ecuv
```
巡检：`python3 fleet_diag2.py <凭证文件> <实例清单>`

> `fleet_deploy.py` 的 `SCRIPT_SHA` 已更新为 r21 的 commit `4082428fe8`，锁定版本避免 CDN 缓存旧脚本。

---

## 🩺 验收一条命令

```bash
echo "happ=$(pgrep -c -f happ)"; docker exec ipes ./bin/ipes health 2>&1 | tail -2; ls /data/happ | wc -l; grep -E "执行完毕|服务中|业务 41|错误|失败" /var/log/ipes_full_deploy.log | tail -12
```

**调优项验收**：

```bash
cat /sys/block/vda/queue/scheduler; cat /sys/block/vda/queue/read_ahead_kb; findmnt -no OPTIONS /; ulimit -Hn; sysctl net.ipv4.udp_mem vm.dirty_ratio net.ipv4.tcp_limit_output_bytes; systemctl is-enabled ipes-tune.service
```

预期：`[none] ...` / `256` / 含 `nobarrier,commit=60` / `1048576` / 见下表 / `enabled`

---

## 参数速查

| 参数 / 环境变量 | 说明 |
|---|---|
| `--ak` / `--sk` | 渠道 appKey / secretKey |
| `--isp` | 运营商（电信 / 联通 / 移动） |
| `--num-dirs` | 缓存目录数，云环境一般 **12** |
| `--skip-olmt` | 跳过本机 `olmt.sh` 带宽整形（跑满不封顶） |
| `--skip-onekey` | 跳过预热对齐（**不推荐**） |
| `--node-token` | 节点激活 token（等价 `NODE_ACTIVATE_TOKEN`） |
| `--target-happ` | 目标 happy 数，默认 **9** |
| `--resource-type` | 1=汇聚 / **2=专线**（默认 2） |
| `--dial-type` | **staticNetSingle=固定公网单IP**（默认） |
| `NODE_ACTIVATE_TOKEN` | JWT，**推荐用环境变量传** |
| `SKIP_TUNE` | **=1 跳过系统调优**（r21 新增，默认执行） |
| `IPES_TUNE_RESTART_DOCKER` | =1 时调优会重启 docker 让容器继承新 nofile（默认不重启，避免打断跑量） |

---

## ⚠️ 云助手 / 终端粘贴必读（已踩坑）

1. **整条必须是一行** —— 有换行会被当命令分隔。
2. **token / AK / SK 不要套 `< >`** —— `<` 是重定向符，会报语法错误。
3. 推荐 `export NODE_ACTIVATE_TOKEN="..."` 传 token。

---

## 🔒 调优脚本的在线安全性

`ipes_tune.sh` 可**在业务运行中**执行：

- 只做 `sysctl` / 队列写入 / **在线 remount**（不 umount）
- **不主动重启 docker**（避免打断跑量）；容器内 nofile 生效需 `IPES_TUNE_RESTART_DOCKER=1` 或重启机器
- 空间回收**只删悬挂镜像**（`docker image prune -f`）+ 截断 >50M 容器日志 + journal 轮转，**绝不删在用镜像/容器**
- 幂等：重复执行不会写坏配置；`/etc/fstab` 改动前自动备份

---

## 安全提示

- 不要把真实 token 写进文档 / 仓库 / 命令历史。
- 每次批量部署收尾后，**轮换**已在对话中出现过的 JWT、渠道 AK/SK、阿里云 AK/SK、GitHub PAT。

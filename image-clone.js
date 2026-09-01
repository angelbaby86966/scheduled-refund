/* =========================================================================
 * 黄金镜像克隆部署（PCDN 缓存节点）
 * 仅管理员 zhangruiyao 可用：UI 通过 admin-only-tab / admin-only-panel 隐藏，
 * 这里再做一次函数级权限兜底。
 * 依赖：AliyunClient.callCentralApi(action, params)（走 aliyun-proxy 代理，避免浏览器 CORS）
 *       AliyunClient.runCommandOnInstance(region, instanceIds, opts)（Cloud Assistant）
 *       AliyunClient.listInstances(region, options)
 *       REGION_INFO / LOCKED_PLAN_ID（app.js 全局）
 * ========================================================================= */
(function () {
  'use strict';

  function icLog(msg, type) {
    if (typeof window.log === 'function') { window.log(msg, type || 'info'); return; }
    console.log('[镜像克隆]', msg);
  }

  function icGuard() {
    if (typeof isAdmin === 'function' && !isAdmin()) {
      alert('⛔ 该功能仅管理员(zhangruiyao)可用');
      return false;
    }
    if (!window.AliyunClient || !AliyunClient.hasCredentials()) {
      alert('请先在「设置凭证」中配置阿里云 AK/SK');
      if (typeof showCredentialDialog === 'function') showCredentialDialog();
      return false;
    }
    return true;
  }

  function icGetRegion() {
    var el = document.getElementById('icRegion');
    return el ? el.value : 'cn-hangzhou';
  }

  // 页面加载时填充地域下拉 + 默认套餐
  function icInit() {
    var sel = document.getElementById('icRegion');
    if (sel && !sel.options.length && typeof REGION_INFO === 'object') {
      Object.keys(REGION_INFO).forEach(function (rid) {
        var o = document.createElement('option');
        o.value = rid; o.textContent = REGION_INFO[rid] + ' (' + rid + ')';
        sel.appendChild(o);
      });
    }
    var plan = document.getElementById('icPlanId');
    if (plan && !plan.value && typeof LOCKED_PLAN_ID !== 'undefined' && LOCKED_PLAN_ID) {
      plan.value = LOCKED_PLAN_ID;
    }
    var period = document.getElementById('icPeriod');
    if (period && !period.value) period.value = '1';
  }

  // ① 从实例创建自定义镜像
  async function icCreateImage() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var instId = (document.getElementById('icSrcInstance').value || '').trim();
    var name = (document.getElementById('icImageName').value || '').trim();
    if (!instId || !name) { alert('请填写「源实例ID」和「镜像名称」'); return; }
    var st = document.getElementById('icCreateImgStatus');
    st.innerHTML = '⏳ 正在从 ' + instId + ' 创建镜像「' + name + '」...';
    try {
      var r = await AliyunClient.callCentralApi('CreateCustomImage', {
        RegionId: region, InstanceId: instId, ImageName: name
      });
      st.innerHTML = '✅ 已提交，ImageId=' + (r.ImageId || r.imageId || '(处理中，稍后刷新镜像列表)');
      icLog('[镜像克隆] 创建镜像成功: ' + (r.ImageId || ''), 'success');
      setTimeout(icLoadImages, 3000);
    } catch (e) {
      st.innerHTML = '❌ 失败: ' + e.message;
      icLog('[镜像克隆] 创建镜像失败: ' + e.message, 'error');
    }
  }

  // 统一解析 ListImages 返回结构
  function icParseImages(r) {
    var imgs = [];
    if (r.Images && r.Images.Image) imgs = r.Images.Image;
    else if (Array.isArray(r.Images)) imgs = r.Images;
    else if (r.Image) imgs = r.Image;
    else if (Array.isArray(r.image)) imgs = r.image;
    return imgs;
  }

  // 统一解析 CreateInstances 返回的实例ID
  function icParseInstanceIds(r) {
    var ids = [];
    if (r.InstanceIdSets && r.InstanceIdSets.InstanceId) ids = r.InstanceIdSets.InstanceId;
    else if (r.InstanceIds) ids = r.InstanceIds;
    else if (Array.isArray(r.instanceIds)) ids = r.instanceIds;
    return ids;
  }

  function icSleep(ms) {
    return new Promise(function (resolve) { setTimeout(resolve, ms); });
  }

  // 过滤出本账号自定义镜像（前端过滤，因为 SWAS ListImages 不支持 ImageType 请求参数）
  function icFilterCustomImages(imgs) {
    return imgs.filter(function (im) {
      var t = String(im.ImageType || '').toLowerCase();
      if (t === 'custom') return true;
      if (t === 'system') return false;
      if (im.IsSelf === true || im.IsSelf === 'true' || im.Self === true || im.Self === 'true') return true;
      var n = String(im.ImageName || '');
      if (n.indexOf('golden-') === 0) return true;
      return false;
    });
  }

  // ② 列出本账号自定义镜像（仅自定义，不含官方系统镜像）
  async function icLoadImages() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var box = document.getElementById('icImagesList');
    var sel = document.getElementById('icImageSelect');
    box.innerHTML = '⏳ 加载中...';
    try {
      var r = await AliyunClient.callCentralApi('ListImages', {
        RegionId: region,
        PageSize: 100
      });
      var imgs = icFilterCustomImages(icParseImages(r));
      if (!imgs.length) {
        box.innerHTML = '⚠️ 该地域暂无自定义镜像。请确认「① 创建镜像」已成功生成（状态需为 Available，Creating 期间不显示）。';
        return;
      }
      sel.innerHTML = imgs.map(function (im) {
        var st = im.Status ? ' [' + im.Status + ']' : '';
        return '<option value="' + (im.ImageId || '') + '">' +
          (im.ImageName || im.ImageId) + ' (' + (im.ImageId || '') + ')' + st + '</option>';
      }).join('');
      box.innerHTML = '✅ 找到 ' + imgs.length + ' 个自定义镜像（仅你账号创建）';
      icLog('[镜像克隆] 列出 ' + imgs.length + ' 个自定义镜像', 'info');
    } catch (e) {
      box.innerHTML = '❌ 加载失败: ' + e.message;
      icLog('[镜像克隆] 加载镜像失败: ' + e.message, 'error');
    }
  }

  // 删除选中的自定义镜像
  async function icDeleteImage() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var sel = document.getElementById('icImageSelect');
    var imageId = sel ? sel.value : '';
    if (!imageId) { alert('请先「② 加载并选择」一个自定义镜像'); return; }
    var imageText = sel.options[sel.selectedIndex] ? sel.options[sel.selectedIndex].text : imageId;
    if (!confirm('确定删除自定义镜像？\n\n' + imageText + '\n\n此操作不可恢复，请确认该镜像未用于运行中的实例。')) return;

    var box = document.getElementById('icImagesList');
    box.innerHTML = '⏳ 正在删除 ' + imageId + ' ...';
    try {
      await AliyunClient.callCentralApi('DeleteCustomImage', {
        RegionId: region,
        ImageId: imageId
      });
      box.innerHTML = '✅ 已删除镜像 ' + imageId;
      icLog('[镜像克隆] 删除镜像成功: ' + imageId, 'success');
      sel.innerHTML = '';
      setTimeout(icLoadImages, 1000);
    } catch (e) {
      box.innerHTML = '❌ 删除失败: ' + e.message;
      icLog('[镜像克隆] 删除镜像失败: ' + e.message, 'error');
    }
  }

  // 只下单不扣费：调 SWAS CreateOrder
  // 兼容两种 Edge Function 版本：
  //   - 线上已部署的小写 createOrder（V3 签名，服务端透传 params，Commodity 需嵌套传）
  //   - 新版大写 CreateOrder（服务端拼 Commodity，扁平参数即可）
  // 先试小写；若 Edge Function 走到 default（返回 hint=aliyun-proxy alive）说明该 case 不存在，再试大写。
  function icIsAliveProbe(e) {
    var r = e && e.response;
    return !!(r && r.hint === 'aliyun-proxy alive');
  }

  async function icCreateOrder(region, imageId, planId, amount, period) {
    var fullParams = {
      RegionId: region,
      OrderType: 'Buy',
      Commodity: {
        Period: period,
        PeriodUnit: 'Month',
        PayType: 'Prepaid',
        CommodityType: 'Server',
        PlanId: planId,
        ImageId: imageId,
        Amount: amount,
        DataDiskSize: 0,
        AutoPay: false,
        AutoRenew: false
      }
      // 注意：CreateOrder 不支持 ClientToken 参数，传了可能被拒，故不带
    };
    var flatParams = {
      RegionId: region,
      ImageId: imageId,
      PlanId: planId,
      Amount: amount,
      Period: period,
      PeriodUnit: 'Month'
    };
    var attempts = [
      { action: 'createOrder', params: fullParams },
      { action: 'CreateOrder', params: flatParams }
    ];
    var lastErr = null;
    for (var i = 0; i < attempts.length; i++) {
      try {
        var r = await AliyunClient.callCentralApi(attempts[i].action, attempts[i].params);
        var orderId = r && (r.OrderId || r.orderId);
        if (orderId) return { OrderId: orderId, raw: r };
        lastErr = new Error('响应无 OrderId：' + JSON.stringify(r).slice(0, 200));
      } catch (e) {
        lastErr = e;
        // 该 action 未部署 → 换下一个；否则（真实业务错误）直接抛出
        if (icIsAliveProbe(e)) {
          icLog('[镜像克隆] action=' + attempts[i].action + ' 未在 Edge Function 部署，尝试下一个', 'info');
          continue;
        }
        throw e;
      }
    }
    throw lastErr || new Error('CreateOrder 调用失败');
  }

  // ③ 基于镜像开通新云主机
  async function icLaunchFromImage() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var sel = document.getElementById('icImageSelect');
    var imageId = sel ? sel.value : '';
    if (!imageId) { alert('请先「② 加载并选择」一个自定义镜像'); return; }
    var planId = (document.getElementById('icPlanId').value || '').trim();
    var amount = parseInt(document.getElementById('icAmount').value, 10) || 1;
    var period = parseInt(document.getElementById('icPeriod').value, 10) || 1;
    var autoPay = document.getElementById('icLaunchAutoPay').checked;
    if (!planId) { alert('请填写套餐 PlanId（默认已填锁定套餐，如被清空请补回）'); return; }
    if (amount < 1 || amount > 100) { alert('开通数量需在 1~100 之间'); return; }

    var st = document.getElementById('icLaunchStatus');
    var res = document.getElementById('icLaunchResult');
    st.innerHTML = '⏳ 基于镜像 ' + imageId + ' 开通 ' + amount + ' 台（' + region + '）...<br><span style="color:#d46b08;font-size:12px;">支付模式：' + (autoPay ? '自动支付（立即扣费）' : '生成待支付订单（不扣费）') + '</span>';
    res.innerHTML = '';
    try {
      var r;
      if (autoPay) {
        r = await AliyunClient.callCentralApi('CreateInstances', {
          RegionId: region,
          ImageId: imageId,
          PlanId: planId,
          Amount: amount,
          Period: period,
          PeriodUnit: 'Month',
          ClientToken: 'wb-ic-' + region + '-' + imageId + '-' + amount
        });
        var ids = icParseInstanceIds(r);
        st.innerHTML = '✅ 开通请求已提交（自动支付）';
        res.innerHTML = (ids.length ? ('🚀 新实例ID：<br><code>' + ids.join('</code><br><code>') + '</code>')
                                    : '下单已提交，请到阿里云控制台查看实例');
        icLog('[镜像克隆] 已开通 ' + amount + ' 台，镜像=' + imageId + ' 自动支付', 'success');
      } else {
        var ord = await icCreateOrder(region, imageId, planId, amount, period);
        st.innerHTML = '✅ 已生成待支付订单（不扣费）';
        res.innerHTML = '📋 订单号：<code>' + ord.OrderId + '</code><br>请前往阿里云控制台「费用中心 - 订单管理」支付。';
        icLog('[镜像克隆] 已生成待支付订单，镜像=' + imageId + ' 订单=' + ord.OrderId, 'success');
      }
    } catch (e) {
      st.innerHTML = '❌ 开通失败: ' + e.message;
      icLog('[镜像克隆] 开通失败: ' + e.message, 'error');
    }
  }

  // ====== ④ 黄金主机标准化脚本（打镜像前必做）— 内嵌模板，供管理员下载 ======
  var IC_TEMPLATES = {
    prep: {
      name: 'ipes-golden-prep.sh',
      body: [
'#!/bin/bash',
'# =====================================================================',
'# IPES / PCDN 黄金主机 去个性化清理脚本',
'# 用途：在【已装好 PCDN 缓存】的黄金主机上执行，清掉"机器独有"状态，',
'#       让基于它打的自定义镜像变成"首次运行"的干净态，避免克隆出重复节点身份。',
'# 时机：打自定义镜像（CreateCustomImage）之前执行。',
'# 注意：脚本会停止 IPES 服务，请在维护窗口执行。',
'# ⚠️ 请先按你的实际环境修改下方【需修改】变量！',
'# =====================================================================',
'set -e',
'',
'# ======= 【需修改】按你实际的 IPES / PCDN 部署调整 =======',
'IPES_SERVICE="ipes-agent"          # systemd 服务名（用 systemctl list-units | grep -i ipes 确认）',
'IPES_DATA_DIR="/var/lib/ipescache" # PCDN 节点身份/缓存数据目录（用 find / -iname "*ipes*" -type d 确认）',
'IPES_CONFIG_DIR="/etc/ipescache"   # 配置目录（若节点ID写死在配置里需一并清理）',
'# ===============================================================',
'',
'echo ">> [1/5] 停止 IPES 服务"',
'systemctl stop "$IPES_SERVICE" || systemctl stop "$IPES_SERVICE.service" || true',
'',
'echo ">> [2/5] 清理 PCDN 节点身份与缓存数据（让新机首启重新注册拿新节点ID）"',
'rm -rf "$IPES_DATA_DIR"/*',
'rm -rf "$IPES_DATA_DIR"/.[!.]* 2>/dev/null || true',
'# 若节点ID也写在配置里，取消下面两行注释：',
'# rm -f "$IPES_CONFIG_DIR"/node_id 2>/dev/null || true',
'# rm -f "$IPES_CONFIG_DIR"/*.token 2>/dev/null || true',
'',
'echo ">> [3/5] 重生成 SSH host key（否则所有克隆机共用一把主机密钥）"',
'rm -f /etc/ssh/ssh_host_*',
'ssh-keygen -A',
'',
'echo ">> [4/5] 重置 machine-id 与日志"',
'rm -f /etc/machine-id && systemd-machine-id-setup',
'rm -f /var/log/ipescache/*.log 2>/dev/null || true',
': > /etc/hostname',
'',
'echo ">> [5/5] 提示：请将 IPES 配置 listen/bind 改为 0.0.0.0，上报IP改为自动获取(eth0)，不要写死黄金主机公网IP"',
'echo "   修改位置通常在 $IPES_CONFIG_DIR 下的 yaml/json 配置。"',
'',
'echo "✅ 去个性化完成。请确认配置绑定的是 0.0.0.0 / 动态IP，然后即可打自定义镜像（CreateCustomImage）。"'
      ].join('\n') + '\n'
    },
    'firstboot-sh': {
      name: 'ipes-firstboot.sh',
      body: [
'#!/bin/bash',
'# =====================================================================',
'# IPES / PCDN 首启自举脚本（每台新克隆机第一次开机执行一次）',
'# 作用：设置唯一主机名 + 确保节点身份干净 + 启动缓存服务。',
'# 部署：放到 /usr/local/bin/ipes-firstboot.sh 并 chmod +x；',
'#       配合 ipes-firstboot.service 一起 enable，脚本末尾会 disable 自身确保只跑一次。',
'# ⚠️ 下方【需修改】变量需与去个性化脚本保持一致。',
'# =====================================================================',
'set -e',
'',
'# ======= 【需修改】 =======',
'IPES_SERVICE="ipes-agent"',
'IPES_DATA_DIR="/var/lib/ipescache"',
'# =========================',
'',
'# 唯一主机名（随机后缀，避免克隆机重名）',
'NEW_HOST="ipes-$(head -c4 /dev/urandom | xxd -p)"',
'echo "$NEW_HOST" > /etc/hostname',
'hostname "$NEW_HOST"',
'',
'# ============ 黄金镜像防御：清掉镜像里继承的旧身份 ============',
'# 防止黄金镜像去个性化不彻底导致多台克隆机共用同一个设备ID或IPES SN',
'rm -f /etc/.mac 2>/dev/null && echo "[$(date "+%F %T")] 已清 /etc/.mac" || true',
'rm -f /etc/edge_firstboot_done 2>/dev/null || true',
'rm -f /etc/ssh/ssh_host_* 2>/dev/null && ssh-keygen -A >/dev/null 2>&1 || true',
'if [ -f /etc/machine-id ]; then rm -f /etc/machine-id && systemd-machine-id-setup >/dev/null 2>&1 || true; fi',
'',
'# 清 IPES 数据目录，让容器启动后重新生成 SN',
'rm -rf "$IPES_DATA_DIR"/* 2>/dev/null || true',
'',
'# 重启 IPES 容器（如有）',
'if command -v docker >/dev/null 2>&1; then',
'  ipes_cid=$(docker ps -aq --filter "name=ipes" 2>/dev/null | head -1)',
'  [ -z "$ipes_cid" ] && ipes_cid=$(docker ps -aq 2>/dev/null | head -1)',
'  [ -n "$ipes_cid" ] && docker restart "$ipes_cid" >/dev/null 2>&1 || true',
'fi',
'',
'# 启动缓存服务',
'systemctl enable "$IPES_SERVICE" 2>/dev/null || true',
'systemctl start "$IPES_SERVICE" 2>/dev/null || true',
'',
'# 首启只跑一次',
'systemctl disable ipes-firstboot',
'',
'echo "✅ 首启自举完成，节点 $NEW_HOST 已启动 IPES 缓存服务。"'
      ].join('\n') + '\n'
    },
    'firstboot-svc': {
      name: 'ipes-firstboot.service',
      body: [
'[Unit]',
'Description=IPES / PCDN first-boot setup',
'After=network-online.target',
'Wants=network-online.target',
'',
'[Service]',
'Type=oneshot',
'ExecStart=/usr/local/bin/ipes-firstboot.sh',
'RemainAfterExit=yes',
'',
'[Install]',
'WantedBy=multi-user.target'
      ].join('\n') + '\n'
    }
  };

  function icDownload(filename, content) {
    if (typeof isAdmin === 'function' && !isAdmin()) {
      alert('⛔ 该功能仅管理员(zhangruiyao)可用');
      return;
    }
    try {
      var blob = new Blob([content], { type: 'text/plain;charset=utf-8' });
      var url = URL.createObjectURL(blob);
      var a = document.createElement('a');
      a.href = url; a.download = filename;
      document.body.appendChild(a); a.click();
      document.body.removeChild(a);
      setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
      icLog('[镜像克隆] 已下载模板: ' + filename, 'info');
    } catch (e) {
      icLog('[镜像克隆] 下载失败: ' + e.message, 'error');
      alert('下载失败: ' + e.message);
    }
  }

  function icDownloadTpl(key) {
    var t = IC_TEMPLATES[key];
    if (t) icDownload(t.name, t.body);
  }

  // ④ 一键执行标准化：在源实例ID上运行去个性化脚本
  async function icRunStandardizationOnSource() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var srcInstance = (document.getElementById('icSrcInstance').value || '').trim();
    if (!srcInstance) { alert('请先在「① 源实例ID」中填写要打镜像的实例'); return; }
    if (!confirm('确定在实例 ' + srcInstance + ' 上执行去个性化标准化？\n\n会停止 IPES、清理节点身份/缓存、重生成 SSH host key、重置 machine-id/hostname。')) return;

    var st = document.getElementById('icStdStatus');
    st.innerHTML = '⏳ 正在对 ' + srcInstance + ' 执行标准化...';
    icLog('[标准化] 在 ' + srcInstance + ' 执行去个性化脚本', 'info');

    var script = [
      '#!/bin/bash',
      'set -e',
      'exec > /var/log/ipes_golden_prep.log 2>&1',
      'echo "[$(date "+%F %T")] 开始去个性化标准化"',
      '',
      '# 停止 IPES 服务/容器',
      'if command -v docker >/dev/null 2>&1; then',
      '  docker stop ipes 2>/dev/null || true',
      '  docker rm ipes 2>/dev/null || true',
      'fi',
      'systemctl stop ipes-agent 2>/dev/null || true',
      'systemctl stop ipes 2>/dev/null || true',
      '',
      '# 清理 PCDN 节点身份与缓存数据',
      'for d in /data/happ /data/happ.* /var/lib/ipescache /var/lib/ipes /var/cache/ipes /etc/ipes /var/lib/zycloud /opt/zyy_install; do',
      '  [ -d "$d" ] && rm -rf "$d"/* "$d"/.[!.]* 2>/dev/null || true',
      'done',
      '',
      '# 清理旧设备ID与首启标记',
      'rm -f /etc/.mac /etc/edge_firstboot_done /etc/edge_firstboot.conf',
      '',
      '# 重生成 SSH host key',
      'rm -f /etc/ssh/ssh_host_*',
      'ssh-keygen -A',
      '',
      '# 重置 machine-id 与日志',
      'rm -f /etc/machine-id && systemd-machine-id-setup',
      'rm -f /var/log/ipes*.log /var/log/zycloud*.log /var/log/batch_preheat*.log 2>/dev/null || true',
      ': > /etc/hostname',
      '',
      'echo "[$(date "+%F %T")] 去个性化完成，请确认 IPES 配置绑定的是 0.0.0.0 / 动态IP，然后即可打自定义镜像。"'
    ].join('\n');

    try {
      await AliyunClient.runCommandOnInstance(region, [srcInstance], {
        name: 'ipes-golden-prep-' + Date.now(),
        content: script,
        type: 'RunShellScript',
        timeout: 300
      });
      st.innerHTML = '✅ 标准化命令已提交到 ' + srcInstance + '，请查看 /var/log/ipes_golden_prep.log';
      icLog('[标准化] 命令已提交: ' + srcInstance, 'success');
    } catch (e) {
      st.innerHTML = '❌ 标准化失败: ' + e.message;
      icLog('[标准化] 失败: ' + e.message, 'error');
    }
  }

  // ④ 一键全流程：标准化 → 打镜像 → 等 Available → 开通
  async function icRunFullAutoFlow() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var srcInstance = (document.getElementById('icSrcInstance').value || '').trim();
    var planId = (document.getElementById('icPlanId').value || '').trim();
    var amount = parseInt(document.getElementById('icAmount').value, 10) || 1;
    var period = parseInt(document.getElementById('icPeriod').value, 10) || 1;
    var autoPay = document.getElementById('icLaunchAutoPay').checked;
    if (!srcInstance) { alert('请填写「① 源实例ID」'); return; }
    if (!planId) { alert('请填写「③ 套餐 PlanId」'); return; }
    if (amount < 1 || amount > 100) { alert('开通数量需在 1~100 之间'); return; }
    if (!confirm('一键全流程将：\n1) 在 ' + srcInstance + ' 执行标准化\n2) 创建自定义镜像\n3) 等待镜像 Available\n4) 基于镜像开通 ' + amount + ' 台\n\n确定继续？')) return;

    var st = document.getElementById('icStdStatus');
    st.innerHTML = '⏳ 一键全流程开始...';
    try {
      st.innerHTML = '第 1/4 步：在 ' + srcInstance + ' 执行标准化...';
      await icRunStandardizationOnSource();
      icLog('[全流程] 标准化完成，等待 15 秒让实例状态稳定...', 'info');
      await icSleep(15000);

      var today = new Date().toISOString().slice(0, 10).replace(/-/g, '');
      var imageName = 'golden-' + region + '-' + today + '-' + Math.random().toString(36).substring(2, 6);
      st.innerHTML = '第 2/4 步：创建镜像 ' + imageName + '...';
      var createRes = await AliyunClient.callCentralApi('CreateCustomImage', {
        RegionId: region, InstanceId: srcInstance, ImageName: imageName
      });
      var imageId = createRes.ImageId || createRes.imageId;
      if (!imageId) throw new Error('创建镜像未返回 ImageId，响应：' + JSON.stringify(createRes));
      icLog('[全流程] 镜像已提交: ' + imageId, 'success');

      st.innerHTML = '第 3/4 步：等待镜像 ' + imageId + ' 变为 Available...';
      var foundImage = null, imageAvailable = false;
      for (var i = 0; i < 60; i++) {
        await icSleep(10000);
        var listRes = await AliyunClient.callCentralApi('ListImages', { RegionId: region, PageSize: 100 });
        var imgs = icFilterCustomImages(icParseImages(listRes));
        for (var k = 0; k < imgs.length; k++) {
          if (imgs[k].ImageId === imageId) { foundImage = imgs[k]; break; }
        }
        if (foundImage) {
          var st2 = foundImage.Status || '未知';
          icLog('[全流程] 第 ' + (i + 1) + ' 次检查，镜像状态=' + st2, 'info');
          if (st2 === 'Available') { imageAvailable = true; break; }
        }
      }
      if (!imageAvailable) throw new Error('等待镜像 Available 超时（10分钟）。当前镜像：' + (foundImage ? foundImage.Status : '未找到'));

      st.innerHTML = '第 4/4 步：基于镜像 ' + imageId + ' 开通 ' + amount + ' 台...<br><span style="color:#d46b08;font-size:12px;">支付模式：' + (autoPay ? '自动支付（立即扣费）' : '生成待支付订单（不扣费）') + '</span>';
      var launchRes;
      if (autoPay) {
        launchRes = await AliyunClient.callCentralApi('CreateInstances', {
          RegionId: region, ImageId: imageId, PlanId: planId,
          Amount: amount, Period: period, PeriodUnit: 'Month',
          ClientToken: 'wb-ic-flow-' + region + '-' + imageId + '-' + amount
        });
        var ids = icParseInstanceIds(launchRes);
        st.innerHTML = '✅ 一键全流程完成，新实例：' + (ids.length ? ids.join(' / ') : '（未返回，请去控制台查看）');
        icLog('[全流程] 完成，新实例: ' + (ids.length ? ids.join(', ') : '未返回'), 'success');
      } else {
        var ord2 = await icCreateOrder(region, imageId, planId, amount, period);
        st.innerHTML = '✅ 一键全流程完成，已生成待支付订单：<code>' + ord2.OrderId + '</code><br>请前往阿里云控制台「费用中心 - 订单管理」支付。';
        icLog('[全流程] 完成，待支付订单: ' + ord2.OrderId, 'success');
      }
      if (typeof renderAll === 'function') renderAll();
    } catch (e) {
      st.innerHTML = '❌ 一键全流程失败: ' + e.message;
      icLog('[全流程] 失败: ' + e.message, 'error');
    }
  }

  // ====== ⑤ 绑定舟翼云 ======
  var __icBindInstances = [];

  function icBuildBindScript(ak, sk, isp, clearMac) {
    var clearPart = clearMac ? (
      'echo "[$(date "+%F %T")] 清除旧 /etc/.mac"\n' +
      'rm -f /etc/.mac /etc/edge_firstboot_done /etc/edge_firstboot.conf\n'
    ) : '';
    return [
      '#!/bin/bash',
      'set -e',
      'exec > /var/log/zycloud_agent_setup.log 2>&1',
      'echo "[$(date "+%F %T")] 开始绑定舟翼云"',
      '',
      clearPart,
      '# 写入注册/绑定凭据',
      'cat > /etc/edge_firstboot.conf <<\'EOF\'',
      'APP_KEY="' + ak + '"',
      'SECRET_KEY="' + sk + '"',
      'ISP="' + isp + '"',
      '',
      '# 如需自动流转 待配置→服务中，请取消下面注释并填入 admin.zhouyi.top 状态流转接口',
      '# APPID=""',
      '# APPAK=""',
      '# APPSK=""',
      '# STATUS_API_URL="https://admin.zhouyi.top/api/edgeNode/updateEdgeStatus"',
      'EOF',
      '',
      '# 下载并执行首启注册绑定脚本',
      'echo "[$(date "+%F %T")] 下载 edge_firstboot_register.sh..."',
      'curl -fsSL https://angelbaby86966.github.io/scheduled-refund/edge_firstboot_register.sh -o /tmp/edge_firstboot_register.sh',
      'chmod +x /tmp/edge_firstboot_register.sh',
      'bash /tmp/edge_firstboot_register.sh',
      'echo "[$(date "+%F %T")] 绑定流程结束"'
    ].join('\n');
  }

  async function icLoadInstancesForBind() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var box = document.getElementById('icBindInstanceList');
    box.innerHTML = '⏳ 加载中...';
    try {
      var r = await AliyunClient.listInstances(region, { pageSize: 100 });
      var all = r.Instances || [];
      __icBindInstances = all.filter(function (it) {
        var st = String(it.Status || '').toLowerCase();
        return st === 'running';
      });
      if (!__icBindInstances.length) {
        box.innerHTML = '⚠️ 当前地域暂无运行中的实例';
        return;
      }
      var html = '<div style="display:flex;flex-direction:column;gap:6px;">' +
        '<label style="font-size:12px;display:flex;align-items:center;gap:6px;cursor:pointer;font-weight:600;">' +
          '<input type="checkbox" id="icBindSelectAll" checked onchange="icToggleBindSelectAll(this.checked)" /> 全选/取消全选' +
        '</label>';
      __icBindInstances.forEach(function (it, idx) {
        var ip = it.PublicIpAddress || it.InnerIpAddress || '-';
        html += '<label style="display:flex;align-items:center;gap:6px;cursor:pointer;font-size:13px;">' +
          '<input type="checkbox" class="ic-bind-chk" data-idx="' + idx + '" checked /> ' +
          '<span>' + (it.InstanceName || '') + ' <code>' + it.InstanceId + '</code> (' + ip + ')</span>' +
          '</label>';
      });
      html += '</div>';
      box.innerHTML = html;
      icLog('[绑定] 已加载 ' + __icBindInstances.length + ' 个运行中实例', 'info');
    } catch (e) {
      box.innerHTML = '❌ 加载失败: ' + e.message;
      icLog('[绑定] 加载失败: ' + e.message, 'error');
    }
  }

  function icToggleBindSelectAll(checked) {
    document.querySelectorAll('.ic-bind-chk').forEach(function (chk) { chk.checked = checked; });
  }

  async function icBindSelectedToZhouyi() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var ak = (document.getElementById('icBindAk').value || '').trim();
    var sk = (document.getElementById('icBindSk').value || '').trim();
    var isp = document.getElementById('icBindIsp').value;
    var clearMac = document.getElementById('icBindClearMac').checked;
    if (!ak || !sk) { alert('请填写舟翼云 appKey 和 secretKey'); return; }

    var checked = [];
    document.querySelectorAll('.ic-bind-chk:checked').forEach(function (chk) {
      var idx = parseInt(chk.dataset.idx, 10);
      if (__icBindInstances[idx]) checked.push(__icBindInstances[idx]);
    });
    if (!checked.length) { alert('请先「加载当前地域实例」并勾选要绑定的机器'); return; }
    if (!confirm('确定绑定 ' + checked.length + ' 台实例到舟翼云？\n运营商：' + isp + '\n' + (clearMac ? '会先清除 /etc/.mac 让每台重新生成设备ID。' : '不清除 /etc/.mac，若镜像带旧ID可能导致重复。'))) return;

    var st = document.getElementById('icBindStatus');
    st.innerHTML = '⏳ 开始绑定 ' + checked.length + ' 台实例...';
    var success = 0, fail = 0;
    for (var i = 0; i < checked.length; i++) {
      var inst = checked[i];
      var iid = inst.InstanceId;
      st.innerHTML = '⏳ 绑定第 ' + (i + 1) + '/' + checked.length + ' 台: ' + iid + '...';
      try {
        var script = icBuildBindScript(ak, sk, isp, clearMac);
        await AliyunClient.runCommandOnInstance(region, [iid], {
          name: 'zycloud-bind-' + iid + '-' + Date.now(),
          content: script,
          type: 'RunShellScript',
          timeout: 600
        });
        success++;
        icLog('[绑定] ' + iid + ' 命令已提交', 'success');
      } catch (e) {
        fail++;
        icLog('[绑定] ' + iid + ' 失败: ' + e.message, 'error');
      }
    }
    st.innerHTML = '✅ 绑定完成：成功 ' + success + ' 台，失败 ' + fail + ' 台。请登录实例查看 /var/log/zycloud_agent_setup.log';
  }

  function icFallbackCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    try { document.execCommand('copy'); alert('✅ 已复制到剪贴板'); }
    catch (e) { alert('复制失败，请手动选中复制'); }
    document.body.removeChild(ta);
  }

  function icCopyText(id) {
    var el = document.getElementById(id);
    if (!el) return;
    var text = el.textContent || el.innerText || '';
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        function () { alert('✅ 已复制到剪贴板'); },
        function () { icFallbackCopy(text); }
      );
    } else {
      icFallbackCopy(text);
    }
  }

  // 暴露到全局（供 onclick 调用）
  window.icInit = icInit;
  window.icDownloadTpl = icDownloadTpl;
  window.icCreateImage = icCreateImage;
  window.icLoadImages = icLoadImages;
  window.icDeleteImage = icDeleteImage;
  window.icLaunchFromImage = icLaunchFromImage;
  window.icRunStandardizationOnSource = icRunStandardizationOnSource;
  window.icRunFullAutoFlow = icRunFullAutoFlow;
  window.icLoadInstancesForBind = icLoadInstancesForBind;
  window.icToggleBindSelectAll = icToggleBindSelectAll;
  window.icBindSelectedToZhouyi = icBindSelectedToZhouyi;
  window.icCopyText = icCopyText;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', icInit);
  } else {
    icInit();
  }
})();

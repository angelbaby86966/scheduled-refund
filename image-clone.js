/* =========================================================================
 * 黄金镜像克隆部署（PCDN 缓存节点）
 * 仅管理员 zhangruiyao 可用：UI 通过 admin-only-tab / admin-only-panel 隐藏，
 * 这里再做一次函数级权限兜底。
 * 依赖：AliyunClient.callCentralApi(action, params)（走 aliyun-proxy 代理，避免浏览器 CORS）
 *       —— ② 加载镜像用 callCentralApi('ListImages', {ImageType:'Custom'}) 仅取自定义镜像，区别于批量下单的 listImages（返回官方系统镜像）
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

  // ② 列出本账号自定义镜像（仅自定义，不含官方系统镜像）
  async function icLoadImages() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var box = document.getElementById('icImagesList');
    var sel = document.getElementById('icImageSelect');
    box.innerHTML = '⏳ 加载中...';
    try {
      // 走通用代理直调 SWAS ListImages，并过滤 ImageType=Custom，
      // 否则会返回官方系统镜像（CentOS/Ubuntu 等），看不到自己打的镜像。
      var r = await AliyunClient.callCentralApi('ListImages', {
        RegionId: region,
        ImageType: 'Custom',
        PageSize: 100
      });
      var imgs = [];
      if (r.Images && r.Images.Image) imgs = r.Images.Image;
      else if (Array.isArray(r.Images)) imgs = r.Images;
      else if (r.Image) imgs = r.Image;
      else if (Array.isArray(r.image)) imgs = r.image;
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
    var autoPay = document.getElementById('icAutoPay').checked;
    if (!planId) { alert('请填写套餐 PlanId（默认已填锁定套餐，如被清空请补回）'); return; }
    if (amount < 1 || amount > 100) { alert('开通数量需在 1~100 之间'); return; }

    var st = document.getElementById('icLaunchStatus');
    var res = document.getElementById('icLaunchResult');
    st.innerHTML = '⏳ 基于镜像 ' + imageId + ' 开通 ' + amount + ' 台（' + region + '）...';
    res.innerHTML = '';
    try {
      var r = await AliyunClient.callCentralApi('CreateInstances', {
        RegionId: region,
        ImageId: imageId,
        PlanId: planId,
        Amount: amount,
        Period: period,
        PeriodUnit: 'Month',
        AutoPay: autoPay,
        ClientToken: 'wb-ic-' + Date.now() + '-' + Math.random().toString(36).substring(2, 8)
      });
      var ids = [];
      if (r.InstanceIdSets && r.InstanceIdSets.InstanceId) ids = r.InstanceIdSets.InstanceId;
      else if (r.InstanceIds) ids = r.InstanceIds;
      else if (Array.isArray(r.instanceIds)) ids = r.instanceIds;
      st.innerHTML = '✅ 开通请求已提交' + (autoPay ? '（自动支付）' : '（生成待支付订单）');
      res.innerHTML = (ids.length ? ('🚀 新实例ID：<br><code>' + ids.join('</code><br><code>') + '</code>')
                                  : '下单已提交，请到阿里云控制台查看实例/订单');
      icLog('[镜像克隆] 已开通 ' + amount + ' 台，镜像=' + imageId + (autoPay ? ' 自动支付' : ' 待支付'), 'success');
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
'# 双保险：再清一次节点身份',
'rm -rf "$IPES_DATA_DIR"/* 2>/dev/null || true',
'',
'# 启动缓存服务',
'systemctl enable "$IPES_SERVICE"',
'systemctl start "$IPES_SERVICE"',
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

  // 暴露到全局（供 onclick 调用）
  window.icInit = icInit;
  window.icDownloadTpl = icDownloadTpl;
  window.icCreateImage = icCreateImage;
  window.icLoadImages = icLoadImages;
  window.icLaunchFromImage = icLaunchFromImage;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', icInit);
  } else {
    icInit();
  }
})();

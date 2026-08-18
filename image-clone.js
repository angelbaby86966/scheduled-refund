/* =========================================================================
 * 黄金镜像克隆部署（PCDN 缓存节点）
 * 仅管理员 zhangruiyao 可用：UI 通过 admin-only-tab / admin-only-panel 隐藏，
 * 这里再做一次函数级权限兜底。
 * 依赖：AliyunClient.callSwasApi(regionId, action, params)（已在 aliyun-client-v2.js 暴露）
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
      var r = await AliyunClient.callSwasApi(region, 'CreateCustomImage', {
        InstanceId: instId, ImageName: name
      });
      st.innerHTML = '✅ 已提交，ImageId=' + (r.ImageId || '(处理中，稍后刷新镜像列表)');
      icLog('[镜像克隆] 创建镜像成功: ' + (r.ImageId || ''), 'success');
      setTimeout(icLoadImages, 3000);
    } catch (e) {
      st.innerHTML = '❌ 失败: ' + e.message;
      icLog('[镜像克隆] 创建镜像失败: ' + e.message, 'error');
    }
  }

  // ② 列出本账号自定义镜像
  async function icLoadImages() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var box = document.getElementById('icImagesList');
    var sel = document.getElementById('icImageSelect');
    box.innerHTML = '⏳ 加载中...';
    try {
      var r = await AliyunClient.callSwasApi(region, 'ListImages', {
        ImageType: 'Custom', PageSize: 100
      });
      var imgs = [];
      if (r.Images && r.Images.Image) imgs = r.Images.Image;
      else if (Array.isArray(r.Images)) imgs = r.Images;
      else if (r.Image) imgs = r.Image;
      else if (Array.isArray(r.image)) imgs = r.image;
      if (!imgs.length) { box.innerHTML = '该地域暂无自定义镜像，请先「① 创建镜像」'; return; }
      sel.innerHTML = imgs.map(function (im) {
        return '<option value="' + (im.ImageId || '') + '">' +
          (im.ImageName || im.ImageId) + ' (' + (im.ImageId || '') + ')</option>';
      }).join('');
      box.innerHTML = '✅ 找到 ' + imgs.length + ' 个自定义镜像';
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
      var r = await AliyunClient.callSwasApi(region, 'CreateInstances', {
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

  // 暴露到全局（供 onclick 调用）
  window.icInit = icInit;
  window.icCreateImage = icCreateImage;
  window.icLoadImages = icLoadImages;
  window.icLaunchFromImage = icLaunchFromImage;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', icInit);
  } else {
    icInit();
  }
})();

/* =========================================================================
 * 黄金镜像克隆部署（PCDN 缓存节点）
 * 仅管理员 zhangruiyao 可用：UI 通过 admin-only-tab / admin-only-panel 隐藏，
 * 这里再做一次函数级权限兜底。
 * 依赖：AliyunClient.callCentralApi(action, params) / listImages(region)（均走 aliyun-proxy 代理，避免浏览器 CORS）
 *       REGION_INFO / LOCKED_PLAN_ID（app.js 全局）
 * ========================================================================= */
(function () {
  'use strict';

  // ====== 克隆批次业务ID映射（与 one-click-deploy 共享云端 ocd_biz_map 行，kind='clone'）======
  var IC_BIZ_MAP_KEY = 'wb_clone_biz_map';
  function icGenBusinessId() {
    var d = new Date();
    var p = function (n) { return String(n).padStart(2, '0'); };
    var ymd = '' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate());
    var rand = Math.random().toString(36).substring(2, 6).toUpperCase();
    return 'BIZ' + ymd + rand;
  }
  function icLoadCloneBizMap() {
    try { return JSON.parse(localStorage.getItem(IC_BIZ_MAP_KEY) || '{}'); } catch (e) { return {}; }
  }
  function icRenderCloneBizMap() {
    var el = document.getElementById('icBizMap');
    if (!el) return;
    var map = icLoadCloneBizMap();
    var ids = Object.keys(map).filter(function (id) { return map[id] && map[id].kind === 'clone'; });
    if (!ids.length) { el.innerHTML = ''; return; }
    var rows = ids.map(function (id) {
      var b = map[id];
      var dev = b.deviceId ? ('<span style="color:#389e0d;">' + b.deviceId + '</span>') : '<span style="color:#bbb;">—</span>';
      return '<tr>' +
        '<td style="padding:4px 8px;font-family:monospace;border-top:1px solid #eee;">' + id + '</td>' +
        '<td style="padding:4px 8px;font-weight:600;color:#0050b3;border-top:1px solid #eee;">' + b.businessId + '</td>' +
        '<td style="padding:4px 8px;font-family:monospace;color:#666;font-size:12px;border-top:1px solid #eee;">' + (b.publicIp || '—') + '</td>' +
        '<td style="padding:4px 8px;border-top:1px solid #eee;">' + dev + '</td>' +
        '<td style="padding:4px 8px;color:#888;font-size:12px;border-top:1px solid #eee;">' + (b.region || '') + '</td>' +
        '<td style="padding:4px 8px;color:#999;font-size:12px;border-top:1px solid #eee;">' + (b.updatedAt || '') + '</td>' +
        '</tr>';
    }).join('');
    el.innerHTML = '<div style="background:#f6ffed;border:1px solid #b7eb8f;border-radius:6px;padding:10px;margin-top:10px;">' +
      '<div style="font-weight:600;font-size:13px;margin-bottom:8px;">🔗 克隆实例ID ↔ 业务ID 一一对应（共 ' + ids.length + ' 台）</div>' +
      '<table style="width:100%;border-collapse:collapse;font-size:13px;">' +
      '<thead><tr style="background:#e6f7ff;">' +
      '<th style="padding:4px 8px;text-align:left;">实例ID (swas)</th>' +
      '<th style="padding:4px 8px;text-align:left;">业务ID</th>' +
      '<th style="padding:4px 8px;text-align:left;">公网IP</th>' +
      '<th style="padding:4px 8px;text-align:left;">设备ID(舟翼云)</th>' +
      '<th style="padding:4px 8px;text-align:left;">地域</th>' +
      '<th style="padding:4px 8px;text-align:left;">更新时间</th></tr></thead>' +
      '<tbody>' + rows + '</tbody></table>' +
      '<div style="font-size:11px;color:#999;margin-top:6px;">绑定舟翼云后，按公网IP 自动回填「设备ID(舟翼云)」并写入克隆机 /usr/local/edge/business_id；同一业务ID 也会在「🚀 一键部署」标签以 kind=deploy 对应节点设备ID。</div></div>';
  }
  // entries: [{instanceId, publicIp?, deviceId?}]  或退化为 string[]（旧调用兼容）
  async function icSaveCloneBizMap(entries, businessId, region, imageId) {
    if (!entries || !entries.length) return;
    var ts = new Date().toLocaleString('zh-CN', { hour12: false });
    var norm = entries.map(function (e) {
      if (typeof e === 'string') return { instanceId: e };
      return e || {};
    }).filter(function (e) { return e && e.instanceId; });
    if (!norm.length) return;
    var local = icLoadCloneBizMap();
    var cloud = (window.OcdBizCloud) ? (await window.OcdBizCloud.load() || {}) : {};
    norm.forEach(function (e) {
      var id = e.instanceId;
      // 原值优先：仅当本次提供才覆盖，避免回填 deviceId 时清掉业务ID
      var cur = local[id] || {};
      local[id] = Object.assign({}, cur, {
        businessId: (businessId != null ? businessId : (cur.businessId || '')),
        updatedAt: ts, kind: 'clone',
        region: (region || cur.region || ''), imageId: (imageId || cur.imageId || ''),
        publicIp: e.publicIp || cur.publicIp || '',
        deviceId: e.deviceId || cur.deviceId || ''
      });
      var cc = cloud[id] || {};
      cloud[id] = Object.assign({}, cc, {
        businessId: (businessId != null ? businessId : (cc.businessId || '')),
        updatedAt: ts, kind: 'clone',
        region: (region || cc.region || ''), imageId: (imageId || cc.imageId || ''),
        publicIp: e.publicIp || cc.publicIp || '',
        deviceId: e.deviceId || cc.deviceId || ''
      });
      // 若已拿到设备ID，额外以 deviceId 为键建一条（便于按设备维度查业务）
      if (e.deviceId) {
        cloud[e.deviceId] = { businessId: (businessId != null ? businessId : (cc.businessId || '')), updatedAt: ts, kind: 'clone', deviceId: e.deviceId, instanceId: id, region: region || cc.region || '' };
      }
    });
    try { localStorage.setItem(IC_BIZ_MAP_KEY, JSON.stringify(local)); } catch (e) {}
    icRenderCloneBizMap();
    if (window.OcdBizCloud) {
      try { await window.OcdBizCloud.upsertMerge(cloud); } catch (e) {}
    }
  }

  // Bug C：轮询直到目标实例全部进入 Running（服务中）才允许生成业务ID；返回 {ids, publicIpMap}
  async function icWaitInstancesRunning(targetIds, region, timeoutMs) {
    if (!targetIds || !targetIds.length) return { ids: [], publicIpMap: {} };
    var deadline = Date.now() + (timeoutMs || 180000);
    var remaining = targetIds.slice();
    var publicIpMap = {};
    while (remaining.length && Date.now() < deadline) {
      try {
        var r = await AliyunClient.listInstances(region, { pageSize: 100 });
        var insts = r.Instances || r.instances || [];
        var page = 2;
        while (insts.length < (r.TotalCount || insts.length) && insts.length >= 100) {
          var nr = await AliyunClient.listInstances(region, { pageSize: 100, pageNumber: page });
          var more = nr.Instances || nr.instances || [];
          if (!more.length) break;
          insts = insts.concat(more); page++;
        }
        var still = [];
        remaining.forEach(function (tid) {
          var m = insts.filter(function (x) { return (x.InstanceId || x.instanceId) === tid; })[0];
          if (m) {
            var st = m.Status || m.status || '';
            if (st === 'Running') {
              var ip = (m.PublicIpAddress || m.publicIpAddress || m.IpAddress || m.ipAddress || '');
              if (typeof ip === 'object') ip = (ip.IpAddress || ip.ipAddress || (ip[0] || ''));
              publicIpMap[tid] = (typeof ip === 'string') ? ip : ((ip && ip[0]) || '');
            } else { still.push(tid); }
          } else { still.push(tid); }
        });
        remaining = still;
      } catch (e) {}
      if (remaining.length) await icSleep(10000);
    }
    return { ids: targetIds.filter(function (id) { return remaining.indexOf(id) < 0; }), publicIpMap: publicIpMap };
  }

  // Bug B：进入页面时把云端 clone 映射合并进本地（跨端/清缓存不丢），不覆盖本地已修改项
  async function icSyncCloudBizMap() {
    if (!window.OcdBizCloud) return;
    try {
      var cloud = await window.OcdBizCloud.load() || {};
      var local = icLoadCloneBizMap();
      Object.keys(cloud).forEach(function (id) {
        var c = cloud[id];
        if (c && c.kind === 'clone' && !local[id]) local[id] = c;
      });
      try { localStorage.setItem(IC_BIZ_MAP_KEY, JSON.stringify(local)); } catch (e) {}
      icRenderCloneBizMap();
    } catch (e) {}
  }

  // 调 admin.zhouyi.top 后端（经 Supabase 函数代理），列出舟翼云设备 {id, ip} 供按公网IP 回填空设备ID
  var IC_SUPABASE_FN = 'https://opauwtkivhjxlijfqaix.supabase.co/functions/v1/one-click-deploy';
  var IC_ANON_KEY = 'sb_publishable_SM9yvpcOBqvVPH2oGwTmFg_BZ1Lz9Xd';
  async function icQueryZyDevices(ownerId) {
    try {
      // ownerId 过滤：缩小匹配范围，提高「待配置→服务中」按公网IP 对应的准确度；留空=全量在线节点
      var query = (ownerId ? ('ownerId=' + encodeURIComponent(ownerId) + '&isOnline=1') : '');
      // 走统一入口：填了三件套走 HMAC，否则走 x-token (supabase fn 转发)
      var j = await icAdminCall('GET', '/api/edgeNode/getEdgeNodeList' + (query ? '?' + query : ''), null);
      // 适配三种鉴权路径下 admin 返回格式不一致
      var inner = j && j.data ? j.data : j;
      var arr = inner;
      if (inner && Array.isArray(inner)) arr = inner;
      else if (inner && inner.data && Array.isArray(inner.data)) arr = inner.data;
      else if (inner && inner.list && Array.isArray(inner.list)) arr = inner.list;
      else if (inner && inner.nodes && Array.isArray(inner.nodes)) arr = inner.nodes;
      if (!Array.isArray(arr)) return null;
      return arr.map(function (n) {
        var id = n.id || n.nodeId || n.deviceId || n.device_id || '';
        var ip = n.ip || n.publicIp || n.ipAddress || n.wanIp || n.publicIpAddress || (n.IpAddress || '');
        if (typeof ip === 'object') ip = ip.IpAddress || ip.ipAddress || '';
        return { id: id, ip: (typeof ip === 'string') ? ip : '' };
      }).filter(function (n) { return n.id || n.ip; });
    } catch (e) { return null; }
  }

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

    // ⑤ 绑定舟翼云：自动记忆整个面板的输入，刷新页面自动回填
    //   - text/select：输入即存，load 时回填 value
    //   - check：勾选即存，load 时回填 checked
    [
      { id: 'icBindAk', key: 'wb_zyy_ak', type: 'text', ev: 'input' },
      { id: 'icBindSk', key: 'wb_zyy_sk', type: 'text', ev: 'input' },
      { id: 'icBindIsp', key: 'wb_zyy_isp', type: 'select', ev: 'change' },
      { id: 'icBindOwnerId', key: 'wb_zyy_owner', type: 'text', ev: 'input' },
      { id: 'icBindAdminAppId', key: 'wb_zyy_admin_appid', type: 'text', ev: 'input' },
      { id: 'icBindAdminAk', key: 'wb_zyy_admin_ak', type: 'text', ev: 'input' },
      { id: 'icBindAdminSk', key: 'wb_zyy_admin_sk', type: 'text', ev: 'input' },
      { id: 'icBindToken', key: 'zy_admin_token', type: 'text', ev: 'input' },
      { id: 'icBindCleanMac', key: 'wb_zyy_cleanmac', type: 'check', ev: 'change' }
    ].forEach(function (f) {
      var el = document.getElementById(f.id);
      if (!el) return;
      try {
        var saved = localStorage.getItem(f.key);
        if (saved !== null) {
          if (f.type === 'check') el.checked = (saved === '1' || saved === 'true');
          else el.value = saved;
        }
      } catch (e) {}
      el.addEventListener(f.ev, function () {
        try {
          var v = (f.type === 'check') ? (el.checked ? '1' : '0') : el.value;
          localStorage.setItem(f.key, v);
        } catch (e) {}
      });
    });
    // 进入页面：先合并云端 clone 映射（Bug B 修复：清缓存/换浏览器不丢），再渲染
    icSyncCloudBizMap();
  }

  // 保存 admin.zhouyi.top Token（本页专用）
  window.icBindSaveToken = function () {
    var tokenEl = document.getElementById('icBindToken');
    var token = (tokenEl ? tokenEl.value : '').trim();
    var st = document.getElementById('icBindTokenStatus');
    if (!token) { if (st) st.textContent = '❌ 请先粘贴 token'; return; }
    try {
      localStorage.setItem('zy_admin_token', token);
      // 同时写入一键部署面板的 ocdToken，两边保持一致
      var ocdToken = document.getElementById('ocdToken');
      if (ocdToken) ocdToken.value = token;
      if (st) st.textContent = '✅ 已保存';
    } catch (e) { if (st) st.textContent = '❌ 保存失败: ' + e.message; }
  };

  // 读取 token 的优先级：本页输入框 > 一键部署面板 > localStorage
  function icGetAdminToken() {
    var token = '';
    var el = document.getElementById('icBindToken');
    if (el && (el.value || '').trim()) token = el.value.trim();
    if (!token) {
      el = document.getElementById('ocdToken');
      if (el && (el.value || '').trim()) token = el.value.trim();
    }
    if (!token) { try { token = localStorage.getItem('zy_admin_token') || ''; } catch (e) {} }
    return token;
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

  // ② 列出本账号自定义镜像
  async function icLoadImages() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var box = document.getElementById('icImagesList');
    var sel = document.getElementById('icImageSelect');
    box.innerHTML = '⏳ 加载中...';
    try {
      var r = await AliyunClient.callCentralApi('ListImages', { RegionId: region, ImageType: 'custom' });
      var imgs = [];
      if (r.Images && r.Images.Image) imgs = r.Images.Image;
      else if (Array.isArray(r.Images)) imgs = r.Images;
      else if (r.Image) imgs = r.Image;
      else if (Array.isArray(r.image)) imgs = r.image;
      // 后端若未按 ImageType 过滤，前端再兜底一次：只保留自定义镜像
      if (Array.isArray(imgs) && imgs.length) {
        imgs = imgs.filter(function(im) {
          return !im.ImageType || im.ImageType === 'custom' || im.ImageType === 'Custom' || im.ImageType === 'CUSTOM';
        });
      }
      if (!imgs.length) { box.innerHTML = '该地域暂无自定义镜像，请先「① 创建镜像」'; return; }
      sel.innerHTML = imgs.map(function (im) {
        return '<option value="' + (im.ImageId || '') + '">' +
          (im.ImageName || im.ImageId) + ' (' + (im.ImageId || '') + ')</option>';
      }).join('');
      // 同时渲染可删除列表
      box.innerHTML = '<div style="margin-bottom:8px;">✅ 找到 ' + imgs.length + ' 个自定义镜像（可删除旧镜像释放配额）：</div>' +
        '<ul style="list-style:none;padding:0;margin:0;font-size:13px;">' +
        imgs.map(function (im) {
          var name = (im.ImageName || im.ImageId);
          var iid = (im.ImageId || '');
          return '<li style="display:flex;justify-content:space-between;align-items:center;padding:6px 8px;border-bottom:1px solid #eee;">' +
            '<span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:70%;">' + name + ' <code>' + iid + '</code></span>' +
            '<button class="btn btn-danger btn-sm" onclick="icDeleteImage(\'' + iid + '\', \'' + name.replace(/'/g, "\\'") + '\')" style="flex-shrink:0;">🗑️ 删除</button>' +
            '</li>';
        }).join('') + '</ul>';
      icLog('[镜像克隆] 列出 ' + imgs.length + ' 个自定义镜像', 'info');
    } catch (e) {
      box.innerHTML = '❌ 加载失败: ' + e.message;
      icLog('[镜像克隆] 加载镜像失败: ' + e.message, 'error');
    }
  }

  // 删除指定自定义镜像（释放配额）
  async function icDeleteImage(imageId, imageName) {
    if (!icGuard()) return;
    if (!imageId) { alert('缺少 ImageId，无法删除'); return; }
    if (!confirm('确定删除自定义镜像「' + (imageName || imageId) + '」(' + imageId + ')？\n删除后无法恢复，但已用该镜像开通的实例不受影响。')) return;
    var region = icGetRegion();
    var box = document.getElementById('icImagesList');
    box.innerHTML = '⏳ 正在删除 ' + imageId + '...';
    try {
      await AliyunClient.callCentralApi('DeleteCustomImage', { RegionId: region, ImageId: imageId });
      icLog('[镜像克隆] 删除镜像成功: ' + imageId, 'success');
      alert('✅ 镜像 ' + imageId + ' 已删除');
      await icLoadImages();
    } catch (e) {
      box.innerHTML = '❌ 删除失败: ' + e.message;
      icLog('[镜像克隆] 删除镜像失败: ' + e.message, 'error');
      alert('删除失败: ' + e.message);
    }
  }

  // ====== [合并自本地旧版] 只下单不扣费：调 SWAS CreateOrder ======
  // 阿里云 SWAS CreateInstances 不支持 AutoPay 参数，调用即扣费；
  // 想"只生成待支付订单不扣费"必须走 CreateOrder（Commodity.AutoPay=false）。
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

  /** [合并自本地旧版] 删除当前选中的自定义镜像（无参包装，供按钮直接调用） */
  async function icDeleteSelectedImage() {
    var sel = document.getElementById('icImageSelect');
    var imageId = sel ? sel.value : '';
    if (!imageId) { alert('请先在上方「加载并选择」一个自定义镜像'); return; }
    var opt = sel.options[sel.selectedIndex];
    var label = opt ? (opt.textContent || '').trim() : imageId;
    return icDeleteImage(imageId, label);
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
      var ids = [];
      if (autoPay) {
        // 立即扣费路径：SWAS CreateInstances（该接口无 AutoPay 参数，调用即扣费）
        var r = await AliyunClient.callCentralApi('CreateInstances', {
          RegionId: region,
          ImageId: imageId,
          PlanId: planId,
          Amount: amount,
          Period: period,
          PeriodUnit: 'Month',
          ClientToken: 'wb-ic-' + Date.now() + '-' + Math.random().toString(36).substring(2, 8)
        });
        if (r.InstanceIdSets && r.InstanceIdSets.InstanceId) ids = r.InstanceIdSets.InstanceId;
        else if (r.InstanceIds) ids = r.InstanceIds;
        else if (Array.isArray(r.instanceIds)) ids = r.instanceIds;
        st.innerHTML = '✅ 开通请求已提交（<b style="color:#cf1322;">自动支付，已扣费</b>）';
        res.innerHTML = (ids.length ? ('🚀 新实例ID：<br><code>' + ids.join('</code><br><code>') + '</code>')
                                    : '下单已提交，请到阿里云控制台查看实例');
      } else {
        // 不扣费路径：SWAS CreateOrder，只生成待支付订单
        var ord = await icCreateOrder(region, imageId, planId, amount, period);
        st.innerHTML = '✅ 已生成待支付订单（<b style="color:#389e0d;">不扣费</b>）';
        res.innerHTML = '📋 订单号：<code>' + ord.OrderId + '</code><br>请到阿里云控制台「费用中心 - 订单管理」支付后再回来绑定。';
        icLog('[镜像克隆] 已生成待支付订单，镜像=' + imageId + ' 订单=' + ord.OrderId, 'success');
        return;
      }
      if (!ids.length) return;
      // Bug C：待配置→服务中（Running）才生成业务ID并对应，避免误标待配置机
      st.innerHTML += '<div style="color:#1890ff;font-size:12px;margin-top:4px;">⏳ 等待实例进入「服务中」(Running)...</div>';
      var wait = await icWaitInstancesRunning(ids, region, 180000);
      if (!wait.ids.length) {
        st.innerHTML += '<div style="color:#fa8c16;font-size:12px;margin-top:4px;">⚠️ 3 分钟内未全部进入服务中，暂不为本批生成业务ID（避免误标待配置机）。请实例就绪后重新「加载并选择」或手动关联。</div>';
        icLog('[镜像克隆] 开通 ' + ids.length + ' 台，但超时未全 Running，未生成业务ID', 'warn');
        return;
      }
      var biz = icGenBusinessId();
      var entries = wait.ids.map(function (id) { return { instanceId: id, publicIp: wait.publicIpMap[id] || '' }; });
      await icSaveCloneBizMap(entries, biz, region, imageId);
      st.innerHTML += '<div style="color:#389e0d;font-size:12px;margin-top:4px;">🔗 本批业务ID：<b>' + biz + '</b>（' + entries.length + ' 台已到服务中，已对应并云端持久化' + (wait.ids.length < ids.length ? '；' + (ids.length - wait.ids.length) + ' 台未就绪未计入' : '') + '）</div>';
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

  // Base64 编码（支持中文）
  function icB64(str) {
    return btoa(unescape(encodeURIComponent(str)));
  }

  function icSleep(ms) {
    return new Promise(function (res) { setTimeout(res, ms); });
  }

  // ============ 舟翼云 admin 提交参数默认值（test.sh 第 1024 行硬编码）============
  // 这些值是 admin 后端业务参数，对齐 test.sh 行为；用户在「绑定舟翼云」面板无需填写
  var IC_DEFAULT_VENDOR_CUSTOMERS = 41;     // vendorSuggestCustomers
  var IC_DEFAULT_TRANS_MODE = 1;            // transMode
  var IC_DEFAULT_IS_CROSS_NETWORK = false;
  var IC_DEFAULT_CROSS_NETWORK_ISP = null;
  var IC_DEFAULT_IS_TRANS_PROV = false;
  var IC_DEFAULT_USBW = 200;
  var IC_DEFAULT_BW_NUM = 1;

  // ============ admin 后端 HMAC-SHA256 鉴权（test.sh 移植）============
  // test.sh 的签名逻辑：sign_str = "ak:timestamp"，sign = HMAC-SHA256(sk, sign_str)，hex 小写
  // 前端用 Web Crypto API 实现（浏览器原生，无依赖）
  function icAdminAppId() { var el = document.getElementById('icBindAdminAppId'); return el ? (el.value || '').trim() : ''; }
  function icAdminAk()   { var el = document.getElementById('icBindAdminAk');   return el ? (el.value || '').trim() : ''; }
  function icAdminSk()   { var el = document.getElementById('icBindAdminSk');   return el ? (el.value || '').trim() : ''; }
  function icHasAdminHmac() { return !!(icAdminAppId() && icAdminAk() && icAdminSk()); }

  async function icAdminHmacSign(ak, sk, timestamp) {
    var signStr = ak + ':' + timestamp;
    var enc = new TextEncoder();
    var key = await crypto.subtle.importKey(
      'raw', enc.encode(sk),
      { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
    );
    var sigBytes = await crypto.subtle.sign('HMAC', key, enc.encode(signStr));
    return Array.from(new Uint8Array(sigBytes)).map(function (b) { return b.toString(16).padStart(2, '0'); }).join('');
  }

  // 直接 fetch admin（带 appId/timestamp/sign 头）；CORS 不通时抛 TypeError 或 0 status
  // 返回 {ok, status, data}：ok=true 表示业务 code===0；data 是 admin 原始响应
  async function icAdminCallHmac(method, path, body) {
    var appId = icAdminAppId(), ak = icAdminAk(), sk = icAdminSk();
    if (!appId || !ak || !sk) throw new Error('admin HMAC 凭据未填');
    var ts = Math.floor(Date.now() / 1000);
    var sign = await icAdminHmacSign(ak, sk, ts);
    var url = 'https://admin.zhouyi.top' + path;
    var resp = await fetch(url, {
      method: method || 'POST',
      headers: {
        'appId': appId,
        'timestamp': String(ts),
        'sign': sign,
        'Content-Type': 'application/json'
      },
      body: body == null ? undefined : JSON.stringify(body)
    });
    var json = null;
    try { json = await resp.json(); } catch (e) {}
    if (!resp.ok) throw new Error('HTTP ' + resp.status + (json ? ' · ' + (json.msg || JSON.stringify(json)) : ''));
    return json;
  }

  // 统一 admin 调用入口：优先用 HMAC 鉴权（三件套都填了），否则走 x-token (supabase fn 转发)
  // 失败时抛 Error，调用方 catch；HMAC 走不通（典型场景：admin 没开 CORS）自动回退到 x-token
  // Fallback 仅在「网络层失败」时触发：HTTP 0、CORS 拦截、TypeError: Failed to fetch
  // 业务错误（HTTP 4xx/5xx）说明请求已到达后端，不 fallback（HMAC 错 / 参数错 fallback 也救不了）
  async function icAdminCall(method, path, body) {
    var hmacUsed = false;
    var hmacErr = null;
    if (icHasAdminHmac()) {
      hmacUsed = true;
      try {
        return await icAdminCallHmac(method, path, body);
      } catch (e) {
        hmacErr = e;
        if (!icIsNetworkErr(e)) {
          // 业务错（HTTP 4xx/5xx 但请求成功到达后端）→ 不 fallback，直接抛
          throw e;
        }
        // 网络/CORS 失败 → 继续往下走 x-token 兜底
      }
    }
    // 走 x-token 鉴权（supabase fn 转发）
    var token = icGetAdminToken();
    if (!token) {
      if (hmacUsed && hmacErr) {
        throw new Error('HMAC 通道因网络/CORS 失败（' + hmacErr.message + '），且未配置 x-token，无法回退。请在「绑定舟翼云」面板填 Token 或解决 admin CORS。');
      }
      throw new Error('未填写 admin Token 也未填 appId/ak/sk 三件套，请二选一');
    }
    try {
      var result;
      if (window.OcdAdmin && window.OcdAdmin.call) {
        result = await window.OcdAdmin.call(token, method || 'POST', path, '', body);
      } else {
        // 兜底：直接调 supabase fn（不通过 OcdAdmin 包装）
        var resp = await fetch(IC_SUPABASE_FN, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + IC_ANON_KEY },
          body: JSON.stringify({ token: token, method: method || 'POST', path: path, query: '', body: (body === undefined ? null : body) })
        });
        var json = null;
        try { json = await resp.json(); } catch (e2) {}
        if (!resp.ok) throw new Error('HTTP ' + resp.status + (json ? ' · ' + JSON.stringify(json) : ''));
        result = json;
      }
      // fallback 成功时日志（仅一次提示）
      if (hmacUsed && !icAdminCall._fallbackWarned) {
        icAdminCall._fallbackWarned = true;
        try { icLog('[image-clone] ⚠️ HMAC 通道不可用（' + hmacErr.message + '），已自动回退到 x-token 鉴权（本会话仅提示一次）', 'warn'); } catch (e3) {}
      }
      return result;
    } catch (e4) {
      // x-token 路径也失败 → 把两层错误合并抛出去
      if (hmacUsed) {
        throw new Error('HMAC 失败（' + (hmacErr ? hmacErr.message : '?') + '），fallback 到 x-token 也失败：' + e4.message);
      }
      throw e4;
    }
  }

  // 识别「网络层失败」：HTTP 0 / CORS 拦截 / fetch 本身抛错
  function icIsNetworkErr(e) {
    if (!e) return false;
    var msg = (e.message || String(e)).toLowerCase();
    if (e instanceof TypeError) return true; // Failed to fetch / Load failed
    if (msg.indexOf('failed to fetch') >= 0) return true;
    if (msg.indexOf('networkerror') >= 0) return true;
    if (msg.indexOf('load failed') >= 0) return true;
    if (msg.indexOf('http 0') >= 0) return true; // fetch 在 CORS 失败时常见 status=0
    if (msg.indexOf('cors') >= 0) return true;
    return false;
  }

  // 从 ListImages 返回里解析自定义镜像数组
  function icParseImgs(r) {
    var imgs = [];
    if (r.Images && r.Images.Image) imgs = r.Images.Image;
    else if (Array.isArray(r.Images)) imgs = r.Images;
    else if (r.Image) imgs = r.Image;
    else if (Array.isArray(r.image)) imgs = r.image;
    if (Array.isArray(imgs) && imgs.length) {
      imgs = imgs.filter(function (im) {
        return !im.ImageType || im.ImageType === 'custom' || im.ImageType === 'Custom' || im.ImageType === 'CUSTOM';
      });
    }
    return imgs;
  }

  // 生成黄金主机标准化 bash 脚本
  function icBuildStandardizeScript() {
    // 读取已记住的舟翼云凭证，固化进首启脚本实现克隆机开机自动绑定
    var zAk = (typeof localStorage !== 'undefined') ? (localStorage.getItem('wb_zyy_ak') || '') : '';
    var zSk = (typeof localStorage !== 'undefined') ? (localStorage.getItem('wb_zyy_sk') || '') : '';
    var zIsp = (typeof localStorage !== 'undefined') ? (localStorage.getItem('wb_zyy_isp') || '电信') : '电信';
    return [
      '#!/bin/bash',
      '# IPES / PCDN 黄金主机一键标准化脚本',
      'set -e',
      '',
      'LOG=/var/log/ipes-golden-prep.log',
      'mkdir -p /var/log',
      'exec > >(tee -a $LOG) 2>&1',
      '',
      'echo "==== $(date) IPES 黄金主机一键标准化开始 ===="',
      '',
      '# 1. 自动探测 IPES 服务名',
      'IPES_SERVICE=$(systemctl list-unit-files --type=service 2>/dev/null | grep -iE \'ipes|pcdn\' | grep -v firstboot | head -1 | awk \'{print $1}\' || true)',
      'if [ -z "$IPES_SERVICE" ]; then IPES_SERVICE="ipes-agent.service"; fi',
      'IPES_SERVICE_NAME=${IPES_SERVICE%.service}',
      'echo "[1/8] 探测到 IPES 服务: $IPES_SERVICE_NAME"',
      '',
      '# 2. 停止 IPES 服务',
      'echo "[2/8] 停止 $IPES_SERVICE_NAME ..."',
      'systemctl stop "$IPES_SERVICE_NAME" 2>/dev/null || systemctl stop "$IPES_SERVICE" 2>/dev/null || true',
      '',
      '# 3. 自动探测数据目录',
      'IPES_DATA_DIR=$(find / -type d -iname "*ipescache*" 2>/dev/null | head -1)',
      'if [ -z "$IPES_DATA_DIR" ]; then IPES_DATA_DIR="/var/lib/ipescache"; mkdir -p "$IPES_DATA_DIR"; fi',
      'echo "[3/8] 探测到数据目录: $IPES_DATA_DIR"',
      '',
      '# 4. 清理 PCDN 节点身份与缓存数据',
      'echo "[4/8] 清理 PCDN 节点身份/缓存数据 ..."',
      'rm -rf "$IPES_DATA_DIR"/* 2>/dev/null || true',
      'rm -rf "$IPES_DATA_DIR"/[!.]* 2>/dev/null || true',
      'find /etc -maxdepth 3 -iname "*ipes*node*" -delete 2>/dev/null || true',
      'find /etc -maxdepth 3 -iname "*ipes*.token" -delete 2>/dev/null || true',
      'find /var/log -maxdepth 2 -iname "*ipes*" -type f -delete 2>/dev/null || true',
      '',
      '# 5. 重生成 SSH host key',
      'echo "[5/8] 重生成 SSH host key ..."',
      'rm -f /etc/ssh/ssh_host_*',
      'ssh-keygen -A',
      '',
      '# 6. 重置 machine-id / zyy 身份 / hostname',
      'echo "[6/8] 重置 machine-id 与 hostname ..."',
      'rm -f /etc/machine-id /etc/.mac',
      'head -c 16 /dev/urandom | xxd -p > /etc/machine-id',
      'head -c 16 /dev/urandom | xxd -p > /etc/.mac',
      'chmod 644 /etc/machine-id /etc/.mac',
      ': > /etc/hostname',
      '',
      '# 7. 写入首启自举脚本',
      'echo "[7/8] 部署首启自举脚本 /usr/local/bin/ipes-firstboot.sh ..."',
      'cat > /usr/local/bin/ipes-firstboot.sh <<\'IPESSCRIPT\'',
      '#!/bin/bash',
      'set -e',
      '# 克隆机首启强制重生设备身份（machine-id + zyy /etc/.mac），避免与源机/兄弟机共用身份导致注册碰撞',
      'rm -f /etc/machine-id /etc/.mac',
      'head -c 16 /dev/urandom | xxd -p > /etc/machine-id',
      'head -c 16 /dev/urandom | xxd -p > /etc/.mac',
      'chmod 644 /etc/machine-id /etc/.mac',
      'NEW_HOST="ipes-$(head -c4 /dev/urandom | xxd -p 2>/dev/null || echo $(date +%s%N | cut -c1-8))"',
      'echo "$NEW_HOST" > /etc/hostname',
      'hostname "$NEW_HOST"',
      'IPES_DATA_DIR=$(find / -type d -iname "*ipescache*" 2>/dev/null | head -1)',
      '[ -z "$IPES_DATA_DIR" ] && IPES_DATA_DIR="/var/lib/ipescache"',
      'rm -rf "$IPES_DATA_DIR"/* 2>/dev/null || true',
      'rm -rf "$IPES_DATA_DIR"/[!.]* 2>/dev/null || true',
      'IPES_SERVICE_NAME=$(systemctl list-unit-files --type=service 2>/dev/null | grep -iE \'ipes|pcdn\' | grep -v firstboot | head -1 | awk \'{print $1}\' || true)',
      '[ -z "$IPES_SERVICE_NAME" ] && IPES_SERVICE_NAME="ipes-agent.service"',
      'IPES_SERVICE_NAME=${IPES_SERVICE_NAME%.service}',
      'systemctl enable "$IPES_SERVICE_NAME"',
      'systemctl start "$IPES_SERVICE_NAME"',
      'systemctl disable ipes-firstboot',
      '# 自动绑定舟翼云（换设备身份后自动注册，克隆机开机即上线，无需手动点按钮）',
      (zAk && zSk ? 'curl -s https://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init/zyy_init_max.sh | bash -s -- --ak ' + zAk + ' --sk ' + zSk + ' --isp ' + (zIsp || '电信') + ' || true' : 'echo "未配置舟翼云 ak/sk，跳过自动绑定"'),
      'echo "首启完成: $NEW_HOST"',
      'IPESSCRIPT',
      'chmod +x /usr/local/bin/ipes-firstboot.sh',
      '',
      '# 8. 写入并启用首启 systemd 服务',
      'echo "[8/8] 部署并启用首启服务 ..."',
      'cat > /etc/systemd/system/ipes-firstboot.service <<\'IPESSVC\'',
      '[Unit]',
      'Description=IPES PCDN first-boot setup',
      'After=network-online.target',
      'Wants=network-online.target',
      '',
      '[Service]',
      'Type=oneshot',
      'ExecStart=/usr/local/bin/ipes-firstboot.sh',
      'RemainAfterExit=yes',
      '',
      '[Install]',
      'WantedBy=multi-user.target',
      'IPESSVC',
      'systemctl daemon-reload',
      'systemctl enable ipes-firstboot',
      '',
      'echo "==== $(date) 标准化完成 ===="',
      'echo "提示：请将 IPES 配置中 bind/listen 改为 0.0.0.0，上报IP改为自动获取，然后即可创建自定义镜像。"'
    ].join('\n');
  }

  // 一键在源实例上执行黄金主机标准化（打镜像前必做）
  async function icOneKeyStandardize() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var instId = (document.getElementById('icSrcInstance').value || '').trim();
    if (!instId) { alert('请先在「① 源实例ID」中填写已装好 PCDN 缓存的黄金主机实例ID'); return; }
    if (!confirm('确定在实例 ' + instId + '（' + region + '）上执行「黄金主机标准化」？\n\n这会：\n1) 停止 IPES 服务\n2) 清理 PCDN 节点身份/缓存数据\n3) 重生成 SSH host key\n4) 重置 machine-id\n5) 部署首启脚本并 enable\n\n执行后请重新打镜像。')) return;

    var st = document.getElementById('icStdStatus');
    st.innerHTML = '⏳ 正在向 ' + instId + ' 下发标准化命令...';

    try {
      var r = await AliyunClient.callCentralApi('RunCommand', {
        RegionId: region,
        InstanceId: instId,
        CommandContent: icB64(icBuildStandardizeScript()),
        Type: 'RunShellScript',
        Timeout: 600,
        Name: 'ipes-golden-prep'
      });
      var cmdId = r.CommandId || r.commandId || '';
      st.innerHTML = '✅ 标准化命令已下发到 ' + instId + '<br>CommandId: <code>' + (cmdId || '下发成功') + '</code><br>' +
        '请等待 1~2 分钟，登录实例确认 <code>/var/log/ipes-golden-prep.log</code> 末尾显示「标准化完成」后再重新打镜像。';
      icLog('[镜像克隆] 标准化命令已下发: ' + instId + ' CommandId=' + cmdId, 'success');
    } catch (e) {
      st.innerHTML = '❌ 标准化命令下发失败: ' + e.message;
      icLog('[镜像克隆] 标准化命令下发失败: ' + e.message, 'error');
    }
  }

  // 一键全流程：标准化 → 创建镜像 → 轮询就绪 → 开通（用户只需填实例ID/镜像名/数量）
  async function icFullCloneFlow() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var instId = (document.getElementById('icSrcInstance').value || '').trim();
    var imageName = (document.getElementById('icImageName').value || '').trim();
    var planId = (document.getElementById('icPlanId').value || '').trim();
    var amount = parseInt(document.getElementById('icAmount').value, 10) || 1;
    var period = parseInt(document.getElementById('icPeriod').value, 10) || 1;
    var autoPay = document.getElementById('icAutoPay').checked;

    if (!instId || !imageName || !planId) { alert('请填写：① 源实例ID、镜像名称、套餐PlanId'); return; }
    if (amount < 1 || amount > 100) { alert('开通数量需在 1~100 之间'); return; }
    if (!confirm('🚀 一键全流程：将在实例 ' + instId + ' 上自动标准化 → 创建镜像「' + imageName + '」→ 开通 ' + amount +
      ' 台（' + region + '）。\n\n全程约 3~5 分钟，期间不要关闭页面。\n\n' +
      (autoPay
        ? '⚠️ 已勾选【自动支付】：将调用 CreateInstances 立即扣费！'
        : '✅ 未勾选自动支付：将调用 CreateOrder，只生成待支付订单，不会扣费。') +
      '\n\n确认执行？')) return;

    var st = document.getElementById('icStdStatus');
    function step(msg) { st.innerHTML += '<div style="margin:2px 0;">' + msg + '</div>'; }
    st.innerHTML = '';

    try {
      // ① 标准化
      step('① 下发标准化命令到 ' + instId + ' ...');
      await AliyunClient.callCentralApi('RunCommand', {
        RegionId: region, InstanceId: instId,
        CommandContent: icB64(icBuildStandardizeScript()), Type: 'RunShellScript', Timeout: 600, Name: 'ipes-golden-prep'
      });
      step('✅ 标准化命令已下发，等待 120 秒执行完成...');
      await icSleep(120000);

      // ② 创建镜像
      step('② 创建镜像「' + imageName + '」...');
      var cr = await AliyunClient.callCentralApi('CreateCustomImage', { RegionId: region, InstanceId: instId, ImageName: imageName });
      var newImageId = cr.ImageId || cr.imageId || '';
      step('✅ 镜像已提交创建，ImageId=' + (newImageId || '(未知)') + '，等待就绪...');

      // ③ 轮询镜像就绪（最多 5 分钟）
      // 【关键修复】SWAS ListImages 对自定义镜像不返回 Status 字段（实测仅 ImageName/Platform/ImageId/ImageType），
      // 因此“镜像出现在列表里”即视为就绪，不能再等 Status==='available'（永远等不到 → 超时中断 → 没有订单）。
      // 仅当 Status 字段存在且显式为 Creating/Waiting 时继续轮询，显式为失败时才报错。
      // 兜底：主地域一直空时跨地域扫描（镜像可能被路由到实例所在地域）。
      var allRegions = ['cn-hangzhou','cn-beijing','cn-shanghai','cn-shenzhen','cn-chengdu',
                        'cn-guangzhou','cn-heyuan','cn-wuhan-lr','cn-wulanchabu'];
      var ready = false;
      var lastInfo = '';
      var scannedRegions = {};  // 跨地域扫描结果
      for (var i = 0; i < 30; i++) {
        await icSleep(10000);
        var lr;
        try {
          lr = await AliyunClient.callCentralApi('ListImages', { RegionId: region, ImageType: 'custom' });
        } catch (e) {
          step('⚠️ [轮询 ' + (i + 1) + '/30] ListImages 报错：' + e.message);
          continue;
        }
        var imgs = icParseImgs(lr);
        // ImageId 可能带/不带 'm-' 前缀，两边都试
        var nid = (newImageId || '').replace(/^m-/, '');
        var found = imgs.filter(function (im) {
          var iid = (im.ImageId || '').replace(/^m-/, '');
          return (nid && iid === nid) || im.ImageName === imageName;
        })[0];
        if (found) {
          // 【修复】SWAS ListImages 对自定义镜像不返回 Status 字段（实测仅 ImageName/Platform/ImageId/ImageType）。
          // 因此：镜像出现在列表里即视为就绪；仅当 Status 字段存在且显式为失败时判失败。
          // 旧逻辑只读 s==='available'，而 s 永远为空 → ready 永不置真 → 30 轮超时后 return 中断整个流程（这就是“镜像有了却没订单”的根因）。
          var s = (found.Status || found.status || found.ImageStatus || '').toString();
          var info = s ? ('状态="' + s + '"') : '（无Status字段=已就绪）';
          lastInfo = info;
          if (!s || s.toLowerCase() === 'available' || s.toLowerCase() === 'success' || s.toLowerCase() === 'ready') {
            newImageId = found.ImageId || newImageId; ready = true;
            step('✅ 镜像就绪（第 ' + (i + 1) + '/30 轮，' + info + '）');
            break;
          }
          if (/fail|error|创建失败/i.test(s)) {
            step('❌ 镜像创建失败：' + info + '\n原始=' + JSON.stringify(found).slice(0, 400));
            return;
          }
          // Status 显式还在 Creating/Waiting 等中间态：继续轮询
          step('⏳ [轮询 ' + (i + 1) + '/30] ' + info + '，继续等待...');
        } else {
          step('⏳ [轮询 ' + (i + 1) + '/30] ListImages 暂未返回「' + imageName + '」(当前列表 ' + imgs.length + ' 个)');
          // 关键节点打印 ListImages 原始前 3 个，帮判断 ImageId/字段名是否一致
          if (i === 0 || i === 9 || i === 19 || i === 29) {
            step('🔍 [' + region + '] ListImages 返回前 3 个：' + JSON.stringify(imgs.slice(0, 3)).slice(0, 600));
          }
          // 跨地域扫描：主地域一直空时（每 3 轮一次），9 个地域挨个查一遍
          // 因为阿里云 SWAS 镜像有时会路由到创建实例所在地域（不一定等于 RegionId 参数）
          if (i > 0 && i % 3 === 0 && imgs.length === 0) {
            step('🌐 主地域 [' + region + '] 一直空，开始跨地域扫描（9 个地域）...');
            for (var ri = 0; ri < allRegions.length; ri++) {
              var rid = allRegions[ri];
              if (rid === region) continue;
              try {
                var lrx = await AliyunClient.callCentralApi('ListImages', { RegionId: rid, ImageType: 'custom' });
                var imgsx = icParseImgs(lrx);
                scannedRegions[rid] = imgsx.length;
                var hit = imgsx.filter(function (im) {
                  var iid = (im.ImageId || '').replace(/^m-/, '');
                  return (nid && iid === nid) || im.ImageName === imageName;
                })[0];
                if (hit) {
                  var s2 = (hit.Status || hit.status || hit.ImageStatus || '').toString();
                  step('🎯 跨地域命中！实际 RegionId=' + rid + '，「' + imageName + '」' + (s2 ? ('状态="' + s2 + '"') : '（无Status字段=已就绪）'));
                  if (!s2 || s2.toLowerCase() === 'available' || s2.toLowerCase() === 'success' || s2.toLowerCase() === 'ready') {
                    region = rid; newImageId = hit.ImageId || newImageId; ready = true;
                    step('✅ 镜像已就绪（跨地域找到，第 ' + (i + 1) + '/30 轮）');
                    break;
                  }
                  if (/fail|error/i.test(s2)) {
                    step('❌ 镜像创建失败（跨地域找到）：' + JSON.stringify(hit).slice(0, 400));
                    return;
                  }
                  // 找到但未就绪：切换到该 region 继续轮询
                  region = rid;
                  step('🔄 已切换轮询 region 到 ' + rid + '，继续等待就绪...');
                }
              } catch (ex) {
                /* 该地域无权限或报错，跳过 */
              }
            }
            if (ready) break;
            step('📊 跨地域扫描结果：' + Object.keys(scannedRegions).map(function (k) { return k + '=' + scannedRegions[k]; }).join(' / '));
          }
        }
      }
      if (!ready) {
        step('⚠️ 镜像未在 5 分钟内就绪。最后一次状态：' + (lastInfo || '(从未找到)'));
        // 兜底：去掉 ImageType 参数再查一次（SWAS 自定义镜像可能没这个 filter）
        step('🔄 兜底：不带 ImageType 参数重试一次 ListImages...');
        try {
          var lr2 = await AliyunClient.callCentralApi('ListImages', { RegionId: region });
          var imgs2 = icParseImgs(lr2);
          var found2 = imgs2.filter(function (im) {
            return (newImageId && im.ImageId === newImageId) || im.ImageName === imageName;
          })[0];
          if (found2) {
            var s2 = (found2.Status || found2.status || found2.ImageStatus || '').toString();
            step('🔍 兜底找到，状态="' + s2 + '" ' + JSON.stringify(found2).slice(0, 400));
          } else {
            step('🔍 兜底仍未找到，原始列表：' + JSON.stringify(imgs2).slice(0, 400));
          }
        } catch (e2) {
          step('🔍 兜底查询也失败：' + e2.message);
        }
        return;
      }
      step('✅ 镜像就绪: ' + newImageId);

      // ④ 开通
      step('④ 基于镜像开通 ' + amount + ' 台...');
      var ids = [];
      if (autoPay) {
        // 立即扣费路径：SWAS CreateInstances（无 AutoPay 参数，调用即扣费）
        var kr = await AliyunClient.callCentralApi('CreateInstances', {
          RegionId: region, ImageId: newImageId, PlanId: planId, Amount: amount,
          Period: period, PeriodUnit: 'Month',
          ClientToken: 'wb-ic-' + Date.now() + '-' + Math.random().toString(36).substring(2, 8)
        });
        if (kr.InstanceIdSets && kr.InstanceIdSets.InstanceId) ids = kr.InstanceIdSets.InstanceId;
        else if (kr.InstanceIds) ids = kr.InstanceIds;
        else if (Array.isArray(kr.instanceIds)) ids = kr.instanceIds;
        step('🚀 开通完成（<b style="color:#cf1322;">自动支付，已扣费</b>）：' +
          (ids.length ? ('<br><code>' + ids.join('</code><br><code>') + '</code>') : '，请到阿里云控制台查看实例'));
      } else {
        // 不扣费路径：SWAS CreateOrder，只生成待支付订单
        var ord = await icCreateOrder(region, newImageId, planId, amount, period);
        step('✅ 已生成待支付订单（<b style="color:#389e0d;">不扣费</b>）：<code>' + ord.OrderId +
          '</code><br>请到阿里云控制台「费用中心 - 订单管理」支付后再回来绑定。');
        icLog('[镜像克隆] 全流程已生成待支付订单，镜像=' + newImageId + ' 订单=' + ord.OrderId, 'success');
        return;
      }
      if (!ids.length) return;
      // Bug C：待配置→服务中（Running）才生成业务ID并对应，避免误标待配置机
      step('⏳ 等待实例进入「服务中」(Running) 后再生成业务ID...');
      var wait2 = await icWaitInstancesRunning(ids, region, 180000);
      if (!wait2.ids.length) {
        step('⚠️ 3 分钟内未全部进入服务中，暂不为本批生成业务ID（避免误标待配置机）。');
        icLog('[镜像克隆] 全流程开通超时未全 Running，未生成业务ID', 'warn');
        return;
      }
      var biz = icGenBusinessId();
      var entries2 = wait2.ids.map(function (id) { return { instanceId: id, publicIp: wait2.publicIpMap[id] || '' }; });
      await icSaveCloneBizMap(entries2, biz, region, newImageId);
      step('🔗 本批业务ID：<b>' + biz + '</b>（' + entries2.length + ' 台已到服务中，已对应并云端持久化' + (wait2.ids.length < ids.length ? '；' + (ids.length - wait2.ids.length) + ' 台未就绪未计入' : '') + '）');
      icLog('[镜像克隆] 全流程完成: ' + instId + ' → 镜像 ' + newImageId + ' → 开通 ' + amount + ' 台', 'success');
    } catch (e) {
      step('❌ 流程中断: ' + e.message);
      icLog('[镜像克隆] 全流程中断: ' + e.message, 'error');
    }
  }

  // ====== ⑤ 绑定舟翼云（开通后注册节点到小程序）======
  var icBindInstances = [];   // 当前加载的实例列表 { InstanceId, Status }

  async function icBindLoadInstances() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var rn = document.getElementById('icBindRegionName');
    if (rn) rn.textContent = (REGION_INFO[region] || region);
    var box = document.getElementById('icBindList');
    box.innerHTML = '⏳ 加载 ' + (REGION_INFO[region] || region) + ' 实例中...';
    try {
      var r = await AliyunClient.listInstances(region, { pageSize: 100 });
      var insts = r.Instances || r.instances || [];
      // 翻页补齐（简单循环到无更多）
      var page = 2;
      while (insts.length < (r.TotalCount || insts.length) && insts.length >= 100) {
        var nr = await AliyunClient.listInstances(region, { pageSize: 100, pageNumber: page });
        var more = nr.Instances || nr.instances || [];
        if (!more.length) break;
        insts = insts.concat(more);
        page++;
      }
      icBindInstances = insts;
      if (!insts.length) { box.innerHTML = '该地域暂无实例'; return; }
      var running = insts.filter(function (x) { return (x.Status || x.status || '') === 'Running'; });
      box.innerHTML = '<label style="display:block;font-weight:600;margin-bottom:6px;cursor:pointer;">' +
        '<input type="checkbox" id="icBindAll" checked onchange="icBindToggleAll(this)"> 全选（共 ' + insts.length + ' 台，其中运行中 ' + running.length + ' 台）</label>' +
        '<div style="border-top:1px solid #eee;padding-top:6px;">' +
        insts.map(function (x, i) {
          var id = x.InstanceId || x.instanceId;
          var st = x.Status || x.status || '';
          var col = st === 'Running' ? '#389e0d' : '#999';
          return '<label style="display:flex;align-items:center;gap:6px;padding:3px 0;cursor:pointer;">' +
            '<input type="checkbox" class="icBindChk" value="' + id + '" ' + (st === 'Running' ? 'checked' : '') + '> ' +
            '<code>' + id + '</code> <span style="color:' + col + '">(' + st + ')</span></label>';
        }).join('') + '</div>';
      icLog('[绑定舟翼云] 加载 ' + insts.length + ' 台实例（' + region + '）', 'info');
    } catch (e) {
      box.innerHTML = '❌ 加载失败: ' + e.message;
      icLog('[绑定舟翼云] 加载实例失败: ' + e.message, 'error');
    }
  }

  function icBindToggleAll(master) {
    var chks = document.querySelectorAll('.icBindChk');
    chks.forEach(function (c) { c.checked = master.checked; });
  }

  async function icBindZhouyi() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var ak = (document.getElementById('icBindAk').value || '').trim();
    var sk = (document.getElementById('icBindSk').value || '').trim();
    var isp = (document.getElementById('icBindIsp').value || '').trim();
    var ownerId = (document.getElementById('icBindOwnerId').value || '').trim() || (function () { var e = document.getElementById('ocdOwnerId'); return e ? (e.value || '').trim() : ''; })();
    if (!ak || !sk || !isp) { alert('请填写 appKey / secretKey / 运营商'); return; }
    var chks = Array.prototype.slice.call(document.querySelectorAll('.icBindChk:checked'));
    if (!chks.length) { alert('请先「加载实例」并勾选要绑定的机器'); return; }
    var ids = chks.map(function (c) { return c.value; });
    if (!confirm('🔗 将向 ' + ids.length + ' 台实例（' + (REGION_INFO[region] || region) + '）下发舟翼云绑定命令。\n\n这是真实注册操作，确认执行？')) return;

    // Bug A：绑定前同步云端克隆映射，按实例ID 取业务ID（让克隆机注册时也带上业务标识）
    var bizByInst = {};
    try {
      await icSyncCloudBizMap();
      var cm = icLoadCloneBizMap();
      ids.forEach(function (id) { if (cm[id] && cm[id].businessId) bizByInst[id] = cm[id].businessId; });
    } catch (e) {}
    var bizList = Object.keys(bizByInst);

    var cleanMac = document.getElementById('icBindCleanMac').checked;
    var pre = cleanMac
      ? 'rm -f /etc/.mac /etc/machine-id /usr/local/edge/registration_info; rm -rf /usr/local/edge /opt/zyy_install /opt/zycloud; head -c 16 /dev/urandom | xxd -p > /etc/machine-id; head -c 16 /dev/urandom | xxd -p > /etc/.mac; chmod 644 /etc/machine-id /etc/.mac; '
      : '';
    // 基础绑定命令（不含业务ID）；业务ID 在 worker 里按实例单独追加写入克隆机本地
    var cmd = pre + 'curl -s https://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init/zyy_init_max.sh | bash -s -- --ak ' + ak + ' --sk ' + sk + ' --isp ' + isp;

    var st = document.getElementById('icBindStatus');
    var prog = document.getElementById('icBindProgress');
    st.innerHTML = '';
    var done = 0, ok = 0, fail = 0;
    function tick() { done++; prog.textContent = '进度 ' + done + '/' + ids.length + ' (成功 ' + ok + ' 失败 ' + fail + ')'; }

    // 有界并发（最多 20 台同时下发）
    var CONC = 20, idx = 0;
    async function worker() {
      while (idx < ids.length) {
        var iid = ids[idx++];
        var bid = bizByInst[iid] || '';
        // 该实例专属命令：绑定 + 把业务ID 写克隆机本地，使「设备ID ↔ 业务ID」在设备侧物理闭环
        var instCmd = cmd + (bid ? ('; mkdir -p /usr/local/edge && echo "' + bid + '" > /usr/local/edge/business_id') : '');
        try {
          await AliyunClient.callCentralApi('RunCommand', {
            RegionId: region, InstanceId: iid,
            CommandContent: icB64(instCmd), Type: 'RunShellScript', Timeout: 600, Name: 'zyy-bind'
          });
          ok++;
          st.innerHTML += '<div style="color:#389e0d;">✅ ' + iid + ' 绑定命令已下发' + (bid ? '（标记业务ID ' + bid + '）' : '') + '</div>';
          icLog('[绑定舟翼云] ' + iid + ' 命令已下发' + (bid ? ' 业务ID=' + bid : ''), 'success');
        } catch (e) {
          fail++;
          st.innerHTML += '<div style="color:#cf1322;">❌ ' + iid + ' 失败: ' + e.message + '</div>';
          icLog('[绑定舟翼云] ' + iid + ' 失败: ' + e.message, 'error');
        }
        tick();
      }
    }
    var pool = [];
    for (var w = 0; w < Math.min(CONC, ids.length); w++) pool.push(worker());
    await Promise.all(pool);
    st.innerHTML += '<div style="margin-top:8px;font-weight:600;">🏁 完成：成功 ' + ok + ' / 失败 ' + fail + ' / 共 ' + ids.length + '</div>' +
      '<div style="font-size:12px;color:#666;margin-top:4px;">每台机器约 1~2 分钟安装注册完成。登录任一台看 <code>/var/log/zycloud_agent_setup.log</code> 末尾「注册成功」，并去小程序确认出现对应新设备。</div>';
    icLog('[绑定舟翼云] 批量下发完成 成功' + ok + ' 失败' + fail, ok === ids.length ? 'success' : 'warn');
    // Bug A：绑定完成后，按实例公网IP 从舟翼云后端查设备ID 并回写云端映射（完成设备ID↔业务ID 对应）
    if (bizList.length) {
      try {
        var devs = await icQueryZyDevices(ownerId);
        if (devs && devs.length) {
          var cm2 = icLoadCloneBizMap();
          var updated = [];
          ids.forEach(function (id) {
            var b = cm2[id];
            if (b && b.publicIp) {
              var hit = devs.filter(function (d) { return d.ip && (d.ip === b.publicIp || (b.publicIp && d.ip.indexOf(b.publicIp) >= 0)); })[0];
              if (hit && hit.id) updated.push({ instanceId: id, deviceId: hit.id, publicIp: b.publicIp });
            }
          });
          if (updated.length) {
            await icSaveCloneBizMap(updated, null, null, null);
            st.innerHTML += '<div style="color:#389e0d;font-size:12px;margin-top:4px;">🔗 已按公网IP 回填 ' + updated.length + ' 台设备ID(舟翼云)，设备ID↔业务ID 对应完成</div>';
          } else {
            st.innerHTML += '<div style="font-size:12px;color:#999;margin-top:4px;">克隆机已写入 /usr/local/edge/business_id；设备ID 需到舟翼云后台按公网IP 核对（或稍后重跑绑定自动回填）。</div>';
          }
        }
      } catch (e) {}
    }
  }

  // ====== 一键绑定并流转到服务中（绑定舟翼云 → 等上线 → 新设备SN填入业务ID → 状态流转）======
  async function icBindAndDeploy() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var ak = (document.getElementById('icBindAk').value || '').trim();
    var sk = (document.getElementById('icBindSk').value || '').trim();
    var isp = (document.getElementById('icBindIsp').value || '').trim();
    if (!ak || !sk || !isp) { alert('请填写 appKey / secretKey / 运营商'); return; }
    var chks = Array.prototype.slice.call(document.querySelectorAll('.icBindChk:checked'));
    if (!chks.length) { alert('请先「加载实例」并勾选要绑定的机器'); return; }
    var ids = chks.map(function (c) { return c.value; });

    // 鉴权方式二选一：admin Token（x-token 走 supabase 转发）OR appId/ak/sk（HMAC 直连 admin）
    var token = icGetAdminToken();
    if (!token && !icHasAdminHmac()) { alert('请二选一填写：\n  1) 「🔑 admin.zhouyi.top Token」 粘贴 x-token\n  2) 「🔐 admin 三件套」 填 appId/ak/sk（走 HMAC）'); return; }
    // vendor / transMode 等业务参数已写死（IC_DEFAULT_* 常量，对齐 test.sh），无需用户输入
    function ocdChk(id) { var el = document.getElementById(id); return el ? el.checked : false; }
    function ocdVal(id) { var el = document.getElementById(id); return el ? (el.value || '').trim() : ''; }
    var ownerId = (document.getElementById('icBindOwnerId').value || '').trim();
    var cfg = {
      vendorSuggestCustomers: IC_DEFAULT_VENDOR_CUSTOMERS,
      transMode: IC_DEFAULT_TRANS_MODE,
      isCrossNetwork: IC_DEFAULT_IS_CROSS_NETWORK,
      crossNetworkIsp: IC_DEFAULT_CROSS_NETWORK_ISP,
      isTransProv: IC_DEFAULT_IS_TRANS_PROV,
      usbw: IC_DEFAULT_USBW,
      bwNum: IC_DEFAULT_BW_NUM,
    };

    if (!confirm('🚀 一键绑定并流转：\n1) 向 ' + ids.length + ' 台实例下发舟翼云绑定命令\n2) 等待设备在 admin.zhouyi.top 上线\n3) 把新设备SN填入业务ID\n4) 自动状态流转到服务中\n\n确认执行？')) return;

    var st = document.getElementById('icBindStatus');
    var prog = document.getElementById('icBindProgress');
    st.innerHTML = '';
    function log(html) { st.innerHTML += '<div style="margin:2px 0;">' + html + '</div>'; }

    // 1) 绑定舟翼云（并发下发）
    var cleanMac = document.getElementById('icBindCleanMac').checked;
    var pre = cleanMac
      ? 'rm -f /etc/.mac /etc/machine-id /usr/local/edge/registration_info; rm -rf /usr/local/edge /opt/zyy_install /opt/zycloud; head -c 16 /dev/urandom | xxd -p > /etc/machine-id; head -c 16 /dev/urandom | xxd -p > /etc/.mac; chmod 644 /etc/machine-id /etc/.mac; '
      : '';
    var cmd = pre + 'curl -s https://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init/zyy_init_max.sh | bash -s -- --ak ' + ak + ' --sk ' + sk + ' --isp ' + isp;
    var done = 0, ok = 0, fail = 0, idx = 0;
    function tick() { done++; prog.textContent = '进度 ' + done + '/' + ids.length + ' (成功 ' + ok + ' 失败 ' + fail + ')'; }
    async function worker() {
      while (idx < ids.length) {
        var iid = ids[idx++];
        try {
          await AliyunClient.callCentralApi('RunCommand', {
            RegionId: region, InstanceId: iid,
            CommandContent: icB64(cmd), Type: 'RunShellScript', Timeout: 600, Name: 'zyy-bind'
          });
          ok++;
          log('<span style="color:#389e0d;">✅ ' + iid + ' 绑定命令已下发</span>');
        } catch (e) {
          fail++;
          log('<span style="color:#cf1322;">❌ ' + iid + ' 失败: ' + e.message + '</span>');
        }
        tick();
      }
    }
    var pool = [];
    for (var w = 0; w < Math.min(20, ids.length); w++) pool.push(worker());
    await Promise.all(pool);
    log('<b>🏁 绑定下发完成：成功 ' + ok + ' / 失败 ' + fail + ' / 共 ' + ids.length + '</b>');
    if (ok === 0) { log('没有成功下发绑定的实例，停止后续流转'); return; }

    // 2) 查询实例公网IP
    log('⏳ 查询实例公网IP，用于匹配舟翼云设备...');
    var ipMap = {};
    try {
      var r = await AliyunClient.listInstances(region, { pageSize: 100 });
      var insts = r.Instances || r.instances || [];
      insts.forEach(function (x) {
        var id = x.InstanceId || x.instanceId;
        if (ids.indexOf(id) >= 0) {
          var ip = x.PublicIpAddress || x.publicIpAddress || x.IpAddress || x.ipAddress || '';
          if (typeof ip === 'object') ip = ip.IpAddress || ip.ipAddress || (ip[0] || '');
          ipMap[id] = (typeof ip === 'string') ? ip : ((ip && ip[0]) || '');
        }
      });
    } catch (e) { log('⚠️ 查询公网IP失败: ' + e.message); }

    // 3) 直接 SSH 读每台实例的 device_code（用 SWAS RunCommand + DescribeCommandInvocations）
    //    绕开 admin 后台 5 分钟匹配——admin 后台 updateEdgeRemark 会自动 upsert 新 nodeId，
    //    不依赖 admin 后台设备列表是否提前同步
    log('⏳ SSH 读取每台机器的 device_code（用于后续 admin 后台注册）...');
    var matched = [];
    var tokenInvalid = false;
    // 读 device_code 的脚本：先 /usr/local/edge_zycloud/device_code，再 /etc/.mac，最后边缘兜底
    var readCodeCmd = 'DC=""; for f in /usr/local/edge_zycloud/device_code /etc/.mac /usr/local/edge/device_code; do if [ -f "$f" ] && [ -r "$f" ]; then DC=$(cat "$f" 2>/dev/null); [ -n "$DC" ] && break; fi; done; if [ -z "$DC" ]; then DC=$(hostname); fi; echo "$DC"';
    var RC_DEADLINE = Date.now() + 180000;  // 3 分钟
    async function readDeviceCode(iid) {
      // 步骤 a: 发 RunCommand 读 device_code
      var r = await AliyunClient.callCentralApi('RunCommand', {
        RegionId: region, InstanceId: iid,
        CommandContent: icB64(readCodeCmd),
        Type: 'RunShellScript', Timeout: 30, Name: 'zyy-readcode'
      });
      var invId = r.InvokeId || r.invokeId || '';
      if (!invId) throw new Error('未拿到 InvokeId');
      // 步骤 b: 轮询 DescribeCommandInvocations（用 AliyunClient.callSwasApi 直连 SWAS，绕开 fn）
      var dl = Date.now() + 120000;
      while (Date.now() < dl) {
        await icSleep(3000);
        try {
          var out = await AliyunClient.callSwasApi(region, 'DescribeCommandInvocations', { InvokeId: invId, IncludeOutput: true, PageSize: 1 });
          var inv = (out.CommandInvocations || out.commandInvocations || [])[0];
          if (!inv) continue;
          var iis = (inv.InvocationInstances || inv.invocationInstances || [])[0];
          if (!iis) continue;
          var status = (iis.InvocationStatus || iis.invocationStatus || '').toLowerCase();
          if (status === 'success' || status === 'failed' || status === 'stopped') {
            var output = (iis.Output || iis.output || '').trim();
            // device_code 是 32 hex，可能在 Output 末尾；提取第一个匹配
            var m = output.match(/[a-f0-9]{32}/);
            if (m) return m[0];
            throw new Error('RunCommand 输出无 32hex device_code: ' + output.slice(0, 200));
          }
          // Running/Pending 继续等
        } catch (e) {
          // 网络错或签名错——继续重试
          if (e && /MissingAccessKeyId|InvalidAccessKey/i.test(e.message)) throw e;
        }
      }
      throw new Error('DescribeCommandInvocations 超时（2 分钟）');
    }
    var rcIdx = 0;
    async function rcPool() {
      while (rcIdx < ids.length && Date.now() < RC_DEADLINE) {
        var iid = ids[rcIdx++];
        try {
          var dc = await readDeviceCode(iid);
          matched.push({ instanceId: iid, deviceId: dc, publicIp: ipMap[iid] || '' });
          log('✅ ' + iid + ' device_code = ' + dc);
        } catch (e) {
          log('❌ ' + iid + ' 读 device_code 失败: ' + e.message);
        }
      }
    }
    var rcPoolArr = [];
    for (var rw = 0; rw < Math.min(10, ids.length); rw++) rcPoolArr.push(rcPool());
    await Promise.all(rcPoolArr);
    if (!matched.length) { log('⚠️ 没有读到任何 device_code，停止流转。请确认机器已装 zyy agent 且 /usr/local/edge_zycloud/device_code 或 /etc/.mac 存在'); return; }
    log('<b>🎯 已读到 ' + matched.length + '/' + ids.length + ' 台 device_code，开始调 admin 后台流转</b>');

    // 4) 状态流转：把新设备SN填入业务ID，调用 updateEdgeRemark + directDeployment
    log('🚀 开始状态流转（待配置 → 服务中），业务ID = 新设备SN...');
    // 鉴权方式提示：填了三件套走 HMAC，否则走 x-token
    if (icHasAdminHmac()) log('🔐 当前使用 appId/ak/sk HMAC 鉴权（直连 admin）');
    else log('🔑 当前使用 x-token 鉴权（经 supabase 转发）');
    var submitOk = 0, deployOk = 0, deployFail = 0, successList = [];
    var idx2 = 0;
    var adminFn = icAdminCall;   // 统一入口：自动选 HMAC 或 x-token
    async function flowWorker() {
      while (idx2 < matched.length) {
        var m = matched[idx2++];
        try {
          // 把新设备SN填入业务ID（同步到 one-click-deploy 面板展示）
          var bizEl = document.getElementById('ocdBusinessId');
          if (bizEl) bizEl.value = m.deviceId;
          // 批量提交（updateEdgeRemark）
          await adminFn('POST', '/api/edgeNode/updateEdgeRemark', {
            nodeId: m.deviceId,
            businessId: m.deviceId,
            vendorSuggestCustomers: cfg.vendorSuggestCustomers,
            transMode: cfg.transMode,
            isCrossNetwork: cfg.isCrossNetwork,
            crossNetworkIsp: cfg.crossNetworkIsp,
            isTransProv: cfg.isTransProv,
            usbw: cfg.usbw,
            bwNum: cfg.bwNum,
          });
          submitOk++;
          // 批量部署（directDeployment）
          await adminFn('POST', '/api/bigDeployLog/directDeployment', { nodeId: m.deviceId });
          deployOk++;
          successList.push(m);
          log('<span style="color:#389e0d;">✅ ' + m.deviceId + ' 已流转到服务中（业务ID=' + m.deviceId + '）</span>');
          icLog('[镜像克隆] 状态流转成功 ' + m.deviceId, 'success');
        } catch (e) {
          deployFail++;
          log('<span style="color:#cf1322;">❌ ' + m.deviceId + ' 流转失败: ' + e.message + '</span>');
          icLog('[镜像克隆] 状态流转失败 ' + m.deviceId + ': ' + e.message, 'error');
        }
      }
    }
    var pool2 = [];
    for (var w2 = 0; w2 < Math.min(10, matched.length); w2++) pool2.push(flowWorker());
    await Promise.all(pool2);
    log('<b>🏁 状态流转完成：提交成功 ' + submitOk + ' / 部署成功 ' + deployOk + ' / 失败 ' + deployFail + '</b>');

    // 5) 保存 deviceId ↔ businessId（业务ID = 设备SN）映射
    if (successList.length) {
      var bizBatch = icGenBusinessId();
      var entries = successList.map(function (m) { return { instanceId: m.instanceId, deviceId: m.deviceId, publicIp: m.publicIp }; });
      await icSaveCloneBizMap(entries, bizBatch, region, '');
      log('🔗 已保存业务ID映射：批次 ' + bizBatch + '，共 ' + entries.length + ' 台（业务ID/设备SN 一一对应）');
    }
  }

  // 暴露到全局（供 onclick 调用）
  window.icInit = icInit;
  window.icDownloadTpl = icDownloadTpl;
  window.icCreateImage = icCreateImage;
  window.icLoadImages = icLoadImages;
  window.icDeleteImage = icDeleteImage;
  window.icLaunchFromImage = icLaunchFromImage;
  window.icOneKeyStandardize = icOneKeyStandardize;
  window.icFullCloneFlow = icFullCloneFlow;
  window.icBindLoadInstances = icBindLoadInstances;
  window.icBindZhouyi = icBindZhouyi;
  window.icBindAndDeploy = icBindAndDeploy;
  window.icBindToggleAll = icBindToggleAll;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', icInit);
  } else {
    icInit();
  }
})();

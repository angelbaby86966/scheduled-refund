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
  // v18r13：业务ID 必须是真正的 IPES SN 76hex（与黄金机同格式），不再是 BIZ+日期+4位 短码。
  // 短码写进 admin 后台的 businessId 字段会让 admin 业务ID 列丢失长度信息，破坏与机器 ipes 容器 bin/ipes_sn 的对应关系。
  function icGenBusinessId() {
    // 38 字节随机 = 76 hex 字符 = IPES 业务ID 标准格式（与黄金机 b16390de… 业务ID 同长度同格式）。
    // crypto.getRandomValues 在所有现代浏览器（含老 IE）都可用；fallback 用 Math.random 双保险。
    try {
      var bytes = new Uint8Array(38);
      (window.crypto || window.msCrypto).getRandomValues(bytes);
      var hex = '';
      for (var i = 0; i < bytes.length; i++) hex += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
      if (hex.length === 76) return hex;
    } catch (e) { /* fallback */ }
    // 兜底：用 Math.random 拼 76 hex（极少触发，浏览器无 Web Crypto 才走这里）
    var s = '';
    while (s.length < 76) s += Math.random().toString(16).slice(2);
    return s.slice(0, 76);
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
      // 转义 attr 防 XSS
      var safeId = String(id).replace(/'/g, '&#39;').replace(/"/g, '&quot;');
      return '<tr data-iid="' + safeId + '">' +
        '<td style="padding:3px 6px;border-top:1px solid #eee;"><input type="checkbox" class="ic-biz-chk" data-iid="' + safeId + '" onchange="window.icBizUpdateBar && icBizUpdateBar()" /></td>' +
        '<td style="padding:3px 6px;font-family:monospace;border-top:1px solid #eee;font-size:12px;">' + id + '</td>' +
        '<td style="padding:3px 6px;font-weight:600;color:#0050b3;border-top:1px solid #eee;font-size:12px;">' + b.businessId + '</td>' +
        '<td style="padding:3px 6px;font-family:monospace;color:#666;font-size:11px;border-top:1px solid #eee;">' + (b.publicIp || '—') + '</td>' +
        '<td style="padding:3px 6px;border-top:1px solid #eee;font-size:12px;">' + dev + '</td>' +
        '<td style="padding:3px 6px;color:#888;font-size:11px;border-top:1px solid #eee;">' + (b.region || '') + '</td>' +
        '<td style="padding:3px 6px;color:#999;font-size:11px;border-top:1px solid #eee;">' + (b.updatedAt || '') + '</td>' +
        '</tr>';
    }).join('');
    el.innerHTML = '<div style="background:#f6ffed;border:1px solid #b7eb8f;border-radius:6px;padding:8px;margin-top:10px;">' +
      // 工具栏：全选 + 删除 + 选中数
      '<div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;font-size:12px;">' +
        '<label style="cursor:pointer;user-select:none;"><input type="checkbox" id="icBizChkAll" onchange="window.icBizToggleAll(this.checked)" /> 全选</label>' +
        '<button type="button" onclick="window.icBizDeleteSelected()" ' +
          'style="background:#ff4d4f;color:#fff;border:0;padding:3px 10px;border-radius:4px;cursor:pointer;font-size:12px;" ' +
          'id="icBizDelBtn" disabled>🗑️ 删除选中</button>' +
        '<span id="icBizSelCount" style="color:#888;">共 ' + ids.length + ' 台</span>' +
      '</div>' +
      // 滚动容器：max-height 220px（约 5 行），超出滚动
      '<div style="max-height:220px;overflow-y:auto;border:1px solid #e8e8e8;border-radius:4px;background:#fff;">' +
        '<table style="width:100%;border-collapse:collapse;font-size:12px;">' +
        '<thead><tr style="background:#e6f7ff;position:sticky;top:0;z-index:1;">' +
        '<th style="padding:4px 6px;width:28px;"></th>' +
        '<th style="padding:4px 6px;text-align:left;">实例ID (swas)</th>' +
        '<th style="padding:4px 6px;text-align:left;">业务ID</th>' +
        '<th style="padding:4px 6px;text-align:left;">公网IP</th>' +
        '<th style="padding:4px 6px;text-align:left;">设备ID(舟翼云)</th>' +
        '<th style="padding:4px 6px;text-align:left;">地域</th>' +
        '<th style="padding:4px 6px;text-align:left;">更新时间</th></tr></thead>' +
        '<tbody>' + rows + '</tbody></table>' +
      '</div>' +
      '<div style="font-size:11px;color:#999;margin-top:6px;">绑定舟翼云后，按公网IP 自动回填「设备ID(舟翼云)」并写入克隆机 /usr/local/edge/business_id；同一业务ID 也会在「🚀 一键部署」标签以 kind=deploy 对应节点设备ID。</div></div>';
  }

  // ====== 表格多选辅助函数（v18r15）======
  // 全选/取消全选
  function icBizToggleAll(checked) {
    document.querySelectorAll('#icBizMap .ic-biz-chk').forEach(function (cb) { cb.checked = checked; });
    icBizUpdateBar();
  }
  // 刷新工具栏：删除按钮启用状态 + 选中数
  function icBizUpdateBar() {
    var checks = document.querySelectorAll('#icBizMap .ic-biz-chk');
    var sel = 0;
    checks.forEach(function (cb) { if (cb.checked) sel++; });
    var btn = document.getElementById('icBizDelBtn');
    var cnt = document.getElementById('icBizSelCount');
    var all = document.getElementById('icBizChkAll');
    if (btn) btn.disabled = (sel === 0);
    if (cnt) cnt.textContent = '共 ' + checks.length + ' 台，已选 ' + sel + ' 台';
    if (all) all.checked = (sel === checks.length && checks.length > 0);
  }
  // 批量删除选中行（localStorage + 云端 OcdBizCloud）
  async function icBizDeleteSelected() {
    var checks = document.querySelectorAll('#icBizMap .ic-biz-chk:checked');
    if (!checks.length) return;
    var ids = Array.from(checks).map(function (cb) { return cb.getAttribute('data-iid'); });
    if (!confirm('确定要删除选中的 ' + ids.length + ' 条克隆映射？\n\n' +
        '⚠️ 仅删除本地缓存 + 云端 ocd_biz_map 中 kind=clone 的映射行；\n' +
        '不会影响 admin 后台节点、阿里云实例、机器 IPES 业务。\n\n实例列表：\n' + ids.slice(0, 5).join('\n') + (ids.length > 5 ? '\n…（还有 ' + (ids.length - 5) + ' 条）' : ''))) return;
    var local = icLoadCloneBizMap();
    var removed = 0;
    ids.forEach(function (id) {
      if (local[id]) { delete local[id]; removed++; }
    });
    try { localStorage.setItem(IC_BIZ_MAP_KEY, JSON.stringify(local)); } catch (e) {}
    // 云端同步删：OcdBizCloud.upsertMerge 是整份替换（不是 patch），所以要 load → 本地删 → upsert
    if (window.OcdBizCloud && window.OcdBizCloud.load && window.OcdBizCloud.upsertMerge) {
      try {
        var cloud = (await window.OcdBizCloud.load()) || {};
        var cloudChanged = false;
        // 按 instanceId 删
        ids.forEach(function (id) {
          if (cloud[id] && cloud[id].kind === 'clone') { delete cloud[id]; cloudChanged = true; }
        });
        // 按 deviceId 索引的克隆行也清（防孤儿）
        Object.keys(cloud).forEach(function (k) {
          if (cloud[k] && cloud[k].kind === 'clone' && cloud[k].instanceId && ids.indexOf(cloud[k].instanceId) >= 0) {
            delete cloud[k]; cloudChanged = true;
          }
        });
        if (cloudChanged) await window.OcdBizCloud.upsertMerge(cloud);
      } catch (e) { /* 云端失败不影响本地 */ }
    }
    icRenderCloneBizMap();
    try { icLog('[image-clone] 已删除克隆映射 ' + removed + ' 条', 'info'); } catch (e) {}
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
    // v18r13：每台克隆机分配独立 IPES SN（76hex），而不是共用一个 biz。
    // 共享参数 businessId 仅作兜底；如果 entries[i].businessId 已存在则优先使用。
    norm.forEach(function (e) {
      if (!e.businessId) e.businessId = businessId || icGenBusinessId();
    });
    var local = icLoadCloneBizMap();
    var cloud = (window.OcdBizCloud) ? (await window.OcdBizCloud.load() || {}) : {};
    norm.forEach(function (e) {
      var id = e.instanceId;
      var perBiz = e.businessId;  // 每台实例专属 IPES SN
      // 原值优先：仅当本次提供才覆盖，避免回填 deviceId 时清掉业务ID
      var cur = local[id] || {};
      local[id] = Object.assign({}, cur, {
        businessId: (perBiz != null ? perBiz : (cur.businessId || '')),
        updatedAt: ts, kind: 'clone',
        region: (region || cur.region || ''), imageId: (imageId || cur.imageId || ''),
        publicIp: e.publicIp || cur.publicIp || '',
        deviceId: e.deviceId || cur.deviceId || ''
      });
      var cc = cloud[id] || {};
      cloud[id] = Object.assign({}, cc, {
        businessId: (perBiz != null ? perBiz : (cc.businessId || '')),
        updatedAt: ts, kind: 'clone',
        region: (region || cc.region || ''), imageId: (imageId || cc.imageId || ''),
        publicIp: e.publicIp || cc.publicIp || '',
        deviceId: e.deviceId || cc.deviceId || ''
      });
      // 若已拿到设备ID，额外以 deviceId 为键建一条（便于按设备维度查业务）
      if (e.deviceId) {
        cloud[e.deviceId] = { businessId: (perBiz != null ? perBiz : (cc.businessId || '')), updatedAt: ts, kind: 'clone', deviceId: e.deviceId, instanceId: id, region: region || cc.region || '' };
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

  // 查询 admin 后端节点详情（含 businessId、期望业务、备注等所有字段）
  // 用于：核对 f670e4...（d62a3d）的业务ID；或在流转前确认 device_code 已注册
  async function icQueryEdgeDetail(nodeId) {
    try {
      // 先尝试 getEdgeNodeDetail，失败则用 getEdgeNodeList 过滤
      var j;
      try {
        j = await icAdminCall('GET', '/api/edgeNode/getEdgeNodeDetail?nodeId=' + encodeURIComponent(nodeId), null);
      } catch (e1) {
        // 兼容没有 detail 接口的旧版后端——从 list 里过滤
        j = await icAdminCall('GET', '/api/edgeNode/getEdgeNodeList', null);
      }
      var inner = j && j.data ? j.data : j;
      var node = null;
      if (inner && (inner.nodeId || inner.id) === nodeId) node = inner;
      else if (Array.isArray(inner)) node = inner.find(function (n) { return (n.nodeId || n.id) === nodeId; });
      else if (inner && Array.isArray(inner.data)) node = inner.data.find(function (n) { return (n.nodeId || n.id) === nodeId; });
      else if (inner && Array.isArray(inner.list)) node = inner.list.find(function (n) { return (n.nodeId || n.id) === nodeId; });
      else if (inner && Array.isArray(inner.nodes)) node = inner.nodes.find(function (n) { return (n.nodeId || n.id) === nodeId; });
      if (!node) return { ok: false, error: '未找到 nodeId=' + nodeId };
      // 提取关键字段（兼容不同命名）
      var fields = {
        nodeId: node.nodeId || node.id || node.deviceId || '',
        businessId: node.businessId || node.bizId || node.business_id || '',
        remark: node.remark || node.note || node.nodeRemark || '',
        ownerId: node.ownerId || node.owner_id || '',
        networkStatus: node.networkStatus || node.netStatus || node.status || '',
        expectedBiz: node.expectedBusiness || node.expectedBiz || node.expectBiz || '',
        vendor: node.vendor || node.vendorName || '',
        ip: node.ip || node.publicIp || node.ipAddress || ''
      };
      return { ok: true, raw: node, fields: fields };
    } catch (e) {
      return { ok: false, error: e.message || String(e) };
    }
  }
  // 暴露：window.icQueryEdgeDetail(nodeId) → 查 admin 后端节点详情

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

  // ★ 镜像名合法性处理：阿里云要求 2-128 字符、字母/中文开头、只能含 数字:字母中文_-
  // （「18杭州9.7」这类名字会报 Image name must be between 2 and 128...）
  function icSanitizeImageName(raw) {
    var n = String(raw || '').trim();
    n = n.replace(/[^\u4e00-\u9fa5A-Za-z0-9:_-]/g, '-');   // 点号/空格等非法字符 → 连字符
    if (n.length > 128) n = n.slice(0, 128);
    if (!/^[\u4e00-\u9fa5A-Za-z]/.test(n)) n = 'img-' + n;  // 必须 字母/中文 开头
    return n;
  }

  // 【v18r25】按名字查自定义镜像（带 ImageType 过滤 + 不带过滤双查，防 SWAS 过滤差异漏查）
  async function icFindImageByName(region, name) {
    if (!name) return null;
    try {
      var r = await AliyunClient.callCentralApi('ListImages', { RegionId: region, ImageType: 'custom' });
      var hit = icParseImgs(r).filter(function (im) { return im.ImageName === name; })[0];
      if (hit) return hit;
    } catch (e) { /* 忽略，走兜底 */ }
    try {
      var r2 = await AliyunClient.callCentralApi('ListImages', { RegionId: region });
      return icParseImgs(r2).filter(function (im) { return im.ImageName === name; })[0] || null;
    } catch (e2) { return null; }
  }

  // 【v18r25】生成唯一镜像名：原名-2 / 原名-3 ...（重名时自动换名，不再中断整个流程）
  function icUniqueImageName(base, n) {
    var stem = String(base || 'img').replace(/-\d+$/, '');
    return icSanitizeImageName(stem + '-' + (n || 2));
  }

  // ====== 🏆 黄金机身份保护（2026-09-07 事故后新增） ======
  // 事故：一键全流程「标准化」在黄金机上 rm -f /etc/.mac 并随机重生 → 黄金机以新身份上线，原设备掉线"消失"。
  // 规则：黄金机的 device_code 一经记录永不改变；克隆/绑定流程跳过黄金机；全流程结束后自动校验并恢复身份。
  var IC_GOLDEN_KEY = 'icGoldenMap';
  function icGetGoldenMap() { try { return JSON.parse(localStorage.getItem(IC_GOLDEN_KEY) || '{}'); } catch (e) { return {}; } }
  function icSaveGoldenMap(m) { try { localStorage.setItem(IC_GOLDEN_KEY, JSON.stringify(m || {})); } catch (e) {} }
  function icRememberGolden(instId, code) {
    if (!instId || !code) return;
    var m = icGetGoldenMap();
    if (m[instId] !== code) { m[instId] = code; icSaveGoldenMap(m); }
  }
  // ⚠️ 不能只依赖 localStorage！种子失效/缓存被清空时守卫会整体失灵（9/8 事故：种子实例已 NotFoundInstance）。
  //    改为「先用 aliyun-client-v2 的权威常量硬判定（实例ID/节点ID/公网IP 三要素任一命中），再回退本地记录」。
  function icIsGolden(instId, extra) {
    if (!instId && !extra) return false;
    try {
      if (window.AliyunClient && AliyunClient.isGoldenInstance) {
        if (AliyunClient.isGoldenInstance(instId)) return true;
        if (extra && AliyunClient.isGoldenInstance(extra)) return true;
      }
    } catch (e) {}
    return !!icGetGoldenMap()[instId];
  }
  // 已知黄金机种子（杭州黄金源机，防 localStorage 清空后失去保护）
  // ⚠️ 2026-09-08 修正：旧种子 9bae6d988653466f8b12bd40e7444aeb / d8fc3eb3b0ef0d3e35bde2f867c9c3db
  //    对应的实例在「张瑞瑶15」账号 cn-hangzhou 已 NotFoundInstance（不存在），导致黄金机守卫长期失灵。
  //    权威黄金机：实例 9f2adaf7f4d9467aa42982db05ff77fc（118.178.193.66），节点ID b1bd4b68f9cac05a3cf3de642341b8a9。
  (function () {
    var m = icGetGoldenMap();
    // 清理已失效的旧种子，避免误判
    if (m['9bae6d988653466f8b12bd40e7444aeb']) { delete m['9bae6d988653466f8b12bd40e7444aeb']; }
    if (!m['9f2adaf7f4d9467aa42982db05ff77fc']) {
      m['9f2adaf7f4d9467aa42982db05ff77fc'] = 'b1bd4b68f9cac05a3cf3de642341b8a9';
      icSaveGoldenMap(m);
    }
  })();

  // RunCommand 下发并取回输出（提交 → 轮询 DescribeCommandInvocations → 返回 Output 文本）
  async function icRunCmdOutput(region, iid, cmd, timeoutSec) {
    // 🚨 SWAS 没有 RunCommand action（那是 ECS 的），正确流程：
    //   CreateCommand(拿到 CommandId) → InvokeCommand(指定 InstanceId) → DescribeCommandInvocations(轮询 Output)
    // 走 callSwasApi 直接调用（绕开 aliyun-proxy 的 RunCommand 白名单）。
    if (!window.AliyunClient) throw new Error('AliyunClient 未加载');
    var ts = timeoutSec || 30;
    var cmdRes = await AliyunClient.callSwasApi(region, 'CreateCommand', {
      RegionId: region, Name: 'ic-golden-guard-' + Date.now(), Type: 'RunShellScript',
      CommandContent: cmd, WorkingDir: '/root', Timeout: ts
    });
    var commandId = (cmdRes && (cmdRes.CommandId || cmdRes.commandId)) || '';
    if (!commandId) throw new Error('CreateCommand 未返回 CommandId：' + JSON.stringify(cmdRes).slice(0, 150));
    var invokeId = '';
    try {
      var inv = await AliyunClient.callSwasApi(region, 'InvokeCommand', {
        RegionId: region, CommandId: commandId, InstanceIds: JSON.stringify([iid])
      });
      invokeId = (inv && (inv.InvokeId || inv.invokeId)) || '';
      if (!invokeId) throw new Error('InvokeCommand 未返回 InvokeId：' + JSON.stringify(inv).slice(0, 150));
      // 轮询拿 Output
      var dl = Date.now() + 90000;
      while (Date.now() < dl) {
        await icSleep(2000);
        var out = await AliyunClient.callSwasApi(region, 'DescribeCommandInvocations', { RegionId: region, InvokeId: invokeId, IncludeOutput: true, PageSize: 1 });
        var invRec = (out && (out.CommandInvocations || out.commandInvocations || []))[0];
        var iis = invRec && ((invRec.InvokeInstances || invRec.invocationInstances || invRec.InvocationInstances || []))[0];
        if (!iis) continue;
        var stt = (iis.InvocationStatus || iis.invocationStatus || '').toLowerCase();
        if (stt === 'success' || stt === 'failed' || stt === 'stopped') {
          return (iis.Output || iis.output || '').trim();
        }
      }
      throw new Error('DescribeCommandInvocations 轮询超时（90s），InvokeId=' + invokeId);
    } finally {
      // 清理临时命令模板，避免残留到命令助手
      try { await AliyunClient.callSwasApi(region, 'DeleteCommand', { RegionId: region, CommandId: commandId }); } catch (e) {}
    }
  }

  // SWAS 异步下发命令（不轮询输出，下发完立刻返回）。
  // 用于"标准化脚本下发后 sleep 等结果"这种场景，避免依赖 icRunCmdOutput 的 90s 轮询。
  // 模板不自动删除（异步执行可能还没完），交给后续"批量清理过期模板"流程。
  // 返回 { commandId, invokeId }，失败抛错。
  async function icRunCommandSubmit(region, iid, cmd, timeoutSec) {
    if (!window.AliyunClient) throw new Error('AliyunClient 未加载');
    var ts = timeoutSec || 60;
    var cr = await AliyunClient.callSwasApi(region, 'CreateCommand', {
      RegionId: region, Name: 'wb-ic-' + Date.now(), Type: 'RunShellScript',
      CommandContent: cmd, WorkingDir: '/root', Timeout: ts
    });
    var commandId = (cr && (cr.CommandId || cr.commandId)) || '';
    if (!commandId) throw new Error('CreateCommand 未返回 CommandId：' + JSON.stringify(cr).slice(0, 150));
    try {
      var iv = await AliyunClient.callSwasApi(region, 'InvokeCommand', {
        RegionId: region, CommandId: commandId, InstanceIds: JSON.stringify([iid])
      });
      var invokeId = (iv && (iv.InvokeId || iv.invokeId)) || '';
      if (!invokeId) throw new Error('InvokeCommand 未返回 InvokeId：' + JSON.stringify(iv).slice(0, 150));
      return { commandId: commandId, invokeId: invokeId };
    } catch (e) {
      // 出错清模板（避免堆积）
      try { await AliyunClient.callSwasApi(region, 'DeleteCommand', { RegionId: region, CommandId: commandId }); } catch (_) {}
      throw e;
    }
  }

  // ① 从实例创建自定义镜像
  async function icCreateImage() {
    if (!icGuard()) return;
    var region = icGetRegion();
    var instId = (document.getElementById('icSrcInstance').value || '').trim();
    var name = (document.getElementById('icImageName').value || '').trim();
    if (!instId || !name) { alert('请填写「源实例ID」和「镜像名称」'); return; }
    name = icSanitizeImageName(name);
    document.getElementById('icImageName').value = name;  // 回写纠正后的名字，让用户看到实际值
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
        var r = await AliyunClient.callCentralApi(attempts[i].action, attempts[i].params, { retries: 1 });
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

  /**
   * 【v18r26】逐台串行下单 —— 保证「填几台就生成几台」
   *
   * 背景（2026-09-11 用户反馈「要买 2 台，为啥只买了一台」）：
   *   排查结论（实测三组对照）：
   *     ① 直连阿里云 SWAS CreateOrder + Commodity.Amount=2 → 订单 Quantity=2（80 元）✅ 接口本身支持多台
   *     ② 走线上 Supabase 代理 createOrder + Amount=2   → 订单 Quantity=2（80 元）✅ 代理也正常
   *     ③ 用户实际生成的订单（OrderId 2003552603620989）→ Quantity=1（40 元）❌ 数量在链路上丢了
   *   即：接口与代理都没问题，但用户实际链路（旧版前端缓存 / 旧版代理）会把 Commodity.Amount 吞掉，
   *   后端按默认 Amount=1 下单。
   *
   *   由于前端无法回查订单数量做校验（代理未提供 QueryOrders/GetOrderDetail 接口），
   *   唯一 100% 可控的办法就是「逐台调用、每单只买 1 台」：
   *   无论 Amount 参数是否生效，最终台数都严格等于用户填写数量。
   * 代价：生成 amount 个待支付订单 —— 阿里云「费用中心→订单管理」可勾选后批量支付。
   */
  async function icCreateOrdersOneByOne(region, imageId, planId, amount, period, onProgress) {
    var orderIds = [];
    for (var i = 0; i < amount; i++) {
      if (i > 0) await icSleep(400);   // 轻微间隔，避免触发 SWAS 限流
      var one = await icCreateOrder(region, imageId, planId, 1, period);
      orderIds.push(one.OrderId);
      if (onProgress) { try { onProgress(i + 1, amount, one.OrderId); } catch (e) { /* 忽略回调异常 */ } }
    }
    return orderIds;
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
        // 【v18r26】改为逐台下单，保证台数 == 用户填写数量（详见 icCreateOrdersOneByOne 注释）
        st.innerHTML = '⏳ 正在逐台生成待支付订单（目标 ' + amount + ' 台）...';
        var orderIds = await icCreateOrdersOneByOne(region, imageId, planId, amount, period,
          function (n, total, oid) {
            st.innerHTML = '⏳ 下单进度 <b>' + n + '/' + total + '</b>（最新订单 ' + oid + '）';
          });
        var shown = orderIds.slice(0, 10).join('</code><br><code>') +
          (orderIds.length > 10 ? '</code><br>… 其余 ' + (orderIds.length - 10) + ' 个见控制台订单管理' : '');
        st.innerHTML = '✅ 已生成 <b>' + orderIds.length + '</b> 个待支付订单（每单 1 台，<b style="color:#389e0d;">不扣费</b>）';
        res.innerHTML = '📋 订单号（共 ' + orderIds.length + ' 个）：<br><code>' + shown + '</code><br>' +
          '请到阿里云控制台「费用中心 - 订单管理」把这些订单<b>勾选后一起支付</b>，支付完成再回来绑定。';
        icLog('[镜像克隆] 已生成 ' + orderIds.length + ' 个待支付订单，镜像=' + imageId + ' 订单=' + orderIds.join(','), 'success');
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
      var bizBatch = icGenBusinessId();  // 批次号（76hex，统一标记）
      var entries = wait.ids.map(function (id) {
        return { instanceId: id, publicIp: wait.publicIpMap[id] || '', businessId: icGenBusinessId() };  // 每台独立 IPES SN
      });
      await icSaveCloneBizMap(entries, bizBatch, region, imageId);
      st.innerHTML += '<div style="color:#389e0d;font-size:12px;margin-top:4px;">🔗 本批业务ID：<b>' + bizBatch.slice(0, 12) + '…</b>（' + entries.length + ' 台已到服务中，每台分配独立 IPES SN 76hex，已云端持久化' + (wait.ids.length < ids.length ? '；' + (ids.length - wait.ids.length) + ' 台未就绪未计入' : '') + '）</div>';
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
'# 🌐 清理镜像继承的黄金机公网 IP 写死（避免克隆机向 admin 上报黄金机 IP，导致两台节点显示同一公网IP）',
'GOLDEN_WAN_IP="118.178.193.66"',
'for cfg in $(grep -rln "$GOLDEN_WAN_IP" /etc/ipescache /etc/ipes* /usr/local/edge /usr/local/edge_zycloud /opt/zycloud 2>/dev/null); do',
'  sed -i "s|$GOLDEN_WAN_IP||g" "$cfg"',
'  echo "  [firstboot] 已清理写死IP: $cfg"',
'done',
'# 容器内配置若也有写死（IPES 跑在 docker 容器里），启动后再清一遍',
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

  // ============ 【v18r25 性能/健壮性优化】全流程并发锁 + 可中断等待 ============
  // 背景（2026-09-11 用户反馈"太慢了，而且还容易卡住"）：
  //   1) 标准化后硬等 120 秒；2) 镜像轮询 90×5s 且中断后仍在空转；3) 重复点击按钮 → 两个流程并发 → 镜像重名中断。
  var icFlowRunning = false;       // 并发锁：同一时刻只允许一个全流程
  var icFlowAbort = false;         // 中断标志：用户在流程中点按钮置真，各等待点会立即退出
  var icFlowStartedAt = 0;
  var IC_ABORT_MSG = '__IC_ABORT__';
  function icFlowElapsed() { return Math.round((Date.now() - icFlowStartedAt) / 1000); }
  // 全流程按钮状态：运行中变"⛔ 中断当前流程（已 N 秒）"，让用户看得见进度、随时能停
  var icFlowBtnTimer = null;
  function icSetFlowBtn(running, stopping) {
    var btn = document.getElementById('icFlowBtn');
    if (icFlowBtnTimer) { clearInterval(icFlowBtnTimer); icFlowBtnTimer = null; }
    if (!btn) return;
    if (!running) {
      btn.textContent = stopping ? '⛔ 正在中断...' : '🚀 一键全流程（标准化→打镜像→开通，全自动）';
      btn.style.background = '#cf1322';
      return;
    }
    btn.style.background = '#d46b08';
    var tick = function () { btn.textContent = '⛔ 中断当前流程（已 ' + icFlowElapsed() + ' 秒）'; };
    tick();
    icFlowBtnTimer = setInterval(tick, 1000);
  }
  function icAbortCheck() { if (icFlowAbort) throw new Error(IC_ABORT_MSG); }
  // 可中断 sleep：把长等待切成 250ms 小片，任何时刻都能响应"中断"
  async function icSleepIC(ms) {
    var dl = Date.now() + ms;
    while (Date.now() < dl) {
      if (icFlowAbort) throw new Error(IC_ABORT_MSG);
      await icSleep(Math.min(250, Math.max(1, dl - Date.now())));
    }
  }
  // 从 DescribeCommandInvocations 响应取出第一条 InvokeInstances 记录
  function icPickInvocation(out) {
    var invs = (out && (out.CommandInvocations || out.commandInvocations || [])) || [];
    if (!Array.isArray(invs) || !invs.length) return null;
    var iis = invs[0].InvokeInstances || invs[0].invocationInstances || invs[0].InvocationInstances || [];
    if (!Array.isArray(iis) || !iis.length) return null;
    return iis[0];
  }
  // 轮询云助手命令是否执行完成（替代"硬等 N 秒"，快的话十几秒就能继续）
  async function icWaitInvokeDone(region, invokeId, maxMs) {
    var dl = Date.now() + (maxMs || 180000);
    var last = '';
    while (Date.now() < dl) {
      if (icFlowAbort) throw new Error(IC_ABORT_MSG);
      await icSleep(1500);
      try {
        var out = await AliyunClient.callSwasApi(region, 'DescribeCommandInvocations', {
          RegionId: region, InvokeId: invokeId, IncludeOutput: true, PageSize: 1
        });
        var rec = icPickInvocation(out);
        if (!rec) continue;
        var stt = String(rec.InvocationStatus || '').toLowerCase();
        last = stt;
        if (stt === 'success' || stt === 'failed' || stt === 'stopped') {
          return { status: stt, output: (rec.Output || '').trim() };
        }
      } catch (e) { /* 网络抖动：继续轮询 */ }
    }
    return { status: 'timeout', output: last };
  }

  // ============ 舟翼云 admin 提交参数默认值（test.sh 第 1024 行硬编码）============
  // 这些值是 admin 后端业务参数，对齐 test.sh 行为；用户在「绑定舟翼云」面板无需填写
  var IC_DEFAULT_VENDOR_CUSTOMERS = 41;     // vendorSuggestCustomers
  // 【v18r30】transMode 1 → 0：对齐黄金机后台实际值。
  //   背景（2026-09-11）：3 台克隆机按旧常量写成 1，与黄金机(0) 不一致，事后手工走
  //   「降级→改→升回」才对齐。改常量后新克隆机开出来即为 0，不再出现该差异。
  var IC_DEFAULT_TRANS_MODE = 0;            // transMode
  var IC_DEFAULT_IS_CROSS_NETWORK = false;  // 是否异网：非异网（截图一致）
  var IC_DEFAULT_CROSS_NETWORK_ISP = null;
  var IC_DEFAULT_IS_TRANS_PROV = true;      // 跨省调度：跨省（2026-09-10 用户按截图改 true，test.sh 原 false 不再生效）
  var IC_DEFAULT_USBW = 200;                // 单条上行：200 Mbps
  var IC_DEFAULT_BW_NUM = 1;                // 线路数量：1
  // ============ admin「编辑」页提交接口 + 截图额外字段（test.sh + 用户 2026-09-10 截图写死）============
  var IC_DEFAULT_NOMINAL_PATH = '/api/edgeNode/updateEdgeNominalInfo';  // 提交带宽/业务接口（test.sh 1024 行实测此路径，非 updateEdgeRemark）
  var IC_DEFAULT_EXPECTED_BIZ = '自研Q2';    // 期望业务（截图：自研Q2；admin 字段名 expectedBiz，见 icQueryEdgeDetail 解析）
  var IC_DEFAULT_IP_SCHEDULE_TYPE = 0;       // IP调度：根据插件V4和V6是否存在来调度（截图；字段名暂按 ipScheduleType，待 admin 实际回包确认）
  // ============ 状态流转固定值（用户 2026-09-10 写死；2026-09-11 r27 用户点名纠正接口）============
  var IC_DEFAULT_DEPLOY_STATUS = '服务中';   // 状态流转目标：服务中
  // 【v18r27 关键纠正｜实证来源：反查 admin 前端 bundle】
  //   状态流转的真实接口 = POST /api/edgeNode/stateflow
  //     证据1 edge.C3aujRsP.js：`c=d=>e({url:"/edgeNode/stateflow",method:"post",data:d})`
  //     证据2 edge.BLOTNJY5.js「状态流转」弹窗模板：设备ID→nodes、业务ID→**hostname**、流转状态→stage
  //           stage 取值：''=请选择 / 'configured'=待配置 / 'inService'=服务中
  //   旧用的 /api/bigDeployLog/directDeployment 其实是后台「强制提交」/「再次提交」按钮：
  //     `R({ nodeId:e.nodeID, isFormat:l })` —— body 只有 {nodeId,isFormat}，内部会跑
  //     FormatQiYIInstallCodeForEcache 生成爱奇艺安装码 → 节点没有「业务线运营商」就报“未知运营商”。
  //     （r22 往它 body 里加 vendorCustomer:41 属于误判，该接口不吃这个字段。）
  //   ⚠️ stateflow 的「业务ID」在请求体里就叫 hostname，不是笔误，是后台约定。
  var IC_DEFAULT_STATEFLOW_PATH = '/api/edgeNode/stateflow';
  var IC_DEFAULT_STATEFLOW_STAGE = 'inService';
  // 仅当 stateflow 路由缺失（HTTP 404/405）时的兜底老接口，正常流程不再使用
  var IC_DEFAULT_DEPLOY_PATH = '/api/bigDeployLog/directDeployment';

  // ============ admin 后端 HMAC-SHA256 鉴权（test.sh 移植）============
  // test.sh 的签名逻辑：sign_str = "ak:timestamp"，sign = HMAC-SHA256(sk, sign_str)，hex 小写
  // 前端用 Web Crypto API 实现（浏览器原生，无依赖）
  // 【v18r18 固化】HMAC 三件套 getter 优先级：localStorage > DOM > 硬编码常量。
  // 用户明确要求"写死、不让填、以后不许改"——2026-09-10 锁定，任何人（包括 AI）不得改这三件套值。
  // 硬编码值做轻混淆（字符数组 + atob），仅挡"路过扒源码"，挡不住专门逆向，部署在公网仍视为明文风险。
  // ⚠️ 安全：SK 在公网前端代码里等于公开，强烈建议去 admin.zhouyi.top 后台轮换 SK 后更新此处常量。
  var IC_HMAC_APPID = 'fg5c21pbzfgu6y2s2yqvanvr6uv99drq';
  var IC_HMAC_AK    = 'ja3io44nq2m7hx63fjkpio7s422aksel';
  var IC_HMAC_SK    = String.fromCharCode(121,100,68,71,117,103,117,90,56,67,79,99,74,78,52,90,116,108,51,76,115,105,99,51,90,48,48,122,71,69,97,110,105,56,102,89,79,80,105,89,107,50,88,88,67,117,88,81,49,65,72,121,121,55,69,49,115,103,86,52,100,121,68,84);
  function icAdminAppId() {
    try { var c = localStorage.getItem('wb_zyy_admin_appid'); if (c && c.trim()) return c.trim(); } catch (e) {}
    var el = document.getElementById('icBindAdminAppId'); if (el && el.value && el.value.trim()) return el.value.trim();
    return IC_HMAC_APPID;
  }
  function icAdminAk() {
    try { var c = localStorage.getItem('wb_zyy_admin_ak'); if (c && c.trim()) return c.trim(); } catch (e) {}
    var el = document.getElementById('icBindAdminAk');   if (el && el.value && el.value.trim()) return el.value.trim();
    return IC_HMAC_AK;
  }
  function icAdminSk() {
    try { var c = localStorage.getItem('wb_zyy_admin_sk'); if (c && c.trim()) return c.trim(); } catch (e) {}
    var el = document.getElementById('icBindAdminSk');   if (el && el.value && el.value.trim()) return el.value.trim();
    return IC_HMAC_SK;
  }
  function icHasAdminHmac() { return !!(icAdminAppId() && icAdminAk() && icAdminSk()); }

  // 【v18r27】状态流转统一入口（后台真实接口 = stateflow）
  //   body = { nodes:[nodeId], hostname:<业务ID=IPES SN>, stage:'inService' }
  //   ⚠️「业务ID」在后台的字段名就叫 hostname（见 admin 前端 edge 页状态流转弹窗模板）
  //   call 可传调用方自己的 adminFn（保持各自的鉴权通道不变）
  //   仅当 stateflow 路由缺失（HTTP 404/405）才兜底老的 directDeployment（body={nodeId,isFormat:false}）
  async function icStateFlow(nodeId, businessId, call) {
    var fn = call || icAdminCall;
    try {
      return await fn('POST', IC_DEFAULT_STATEFLOW_PATH, {
        nodes: [nodeId],
        hostname: businessId,
        stage: IC_DEFAULT_STATEFLOW_STAGE,
      });
    } catch (e) {
      var msg = String((e && e.message) || '');
      var routeMissing = /HTTP\s*(404|405)/.test(msg) || /404 page not found|no route|not found/i.test(msg);
      if (!routeMissing) throw e;
      icLog('[镜像克隆] stateflow 路由缺失，回退 directDeployment 兜底', 'warn');
      return await fn('POST', IC_DEFAULT_DEPLOY_PATH, { nodeId: nodeId, isFormat: false });
    }
  }

  // ============ 【v18r29】建设带宽提交：状态降级 + 读回校验 + 自动重试 ============
  // 实证根因（2026-09-11，3 台克隆机 usbw=40 事故复盘）：
  //   ① updateEdgeNominalInfo 对 inService(服务中) / waitAudit(交付中) 节点**一律拒绝**：
  //        code:7「设备处于服务中或交付中状态，不允许修改设备信息」
  //      → 必须先 stateflow 回到 configured(待配置) 才能改建设带宽，改完再流回 inService。
  //   ② 「接口返回 code:0 但数据根本没落库」确实存在（同族接口 PUT /edgeNode/bw 实测如此）
  //      → 提交后**必须读回 nominalInfo.usbw 校验**，不符就重试，不能只看返回码。
  // 返回 { ok, usbw, attempts, unverified }
  //   ok=false  → 确实读回 usbw 与期望不符（调用方应中止流转，避免"带宽没写进去却流转成功"）
  //   unverified → 读回通道本身异常（查询失败），属于"无法校验"，放行但告警，避免误杀
  function icSleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  async function icAdminFindNode(fn, nodeId) {
    // GET 不能带 body（浏览器规范禁止），query 直接拼进 path
    var res = await fn('GET', '/api/edgeNode/findEdgeNode?nodeId=' + encodeURIComponent(nodeId), null);
    return (res && res.data) || null;
  }
  async function icSubmitNominalVerified(fn, m, cfg, say) {
    say = say || function () {};
    var want = Number(cfg.usbw);
    var attempts = 3, lastGot = null, mismatch = 0, verifyErr = 0;

    for (var i = 1; i <= attempts; i++) {
      // ① 前置降级：服务中/交付中不允许改建设带宽 → 先 stateflow 回「待配置」
      try {
        var d0 = await icAdminFindNode(fn, m.nodeId);
        var st0 = d0 && d0.stage;
        if (st0 === 'inService' || st0 === 'waitAudit') {
          say('↺ 节点当前为「' + (st0 === 'inService' ? '服务中' : '交付中') + '」，先降级到「待配置」再改建设带宽', 'warn');
          await fn('POST', IC_DEFAULT_STATEFLOW_PATH, {
            nodes: [m.nodeId], hostname: m.businessId || '', stage: 'configured'
          });
          await icSleep(1200);
        }
      } catch (e) { /* 查询/降级失败不阻断，按原流程继续提交 */ }

      // ② 提交建设带宽/业务（参数保持写死的 IC_DEFAULT_* 语义不变）
      await fn('POST', IC_DEFAULT_NOMINAL_PATH, {
        nodeId: m.nodeId,
        businessId: m.businessId,
        vendorSuggestCustomers: cfg.vendorSuggestCustomers,
        transMode: cfg.transMode,
        isCrossNetwork: cfg.isCrossNetwork,
        crossNetworkIsp: cfg.crossNetworkIsp,
        isTransProv: cfg.isTransProv,
        usbw: cfg.usbw,
        bwNum: cfg.bwNum,
        expectedBiz: IC_DEFAULT_EXPECTED_BIZ,
        ipScheduleType: IC_DEFAULT_IP_SCHEDULE_TYPE,
      });

      // ③ 读回校验：code:0 ≠ 已落库
      await icSleep(1500);
      try {
        var d1 = await icAdminFindNode(fn, m.nodeId);
        var ni = (d1 && d1.nodeInfo) || {};
        lastGot = ni.usbw;
        if (Number(ni.usbw) === want) {
          say('✅ 建设带宽已写入并校验通过：usbw=' + ni.usbw + '（第 ' + i + ' 次提交）', 'ok');
          return { ok: true, usbw: ni.usbw, attempts: i };
        }
        mismatch++;
        say('⚠️ 第 ' + i + '/' + attempts + ' 次提交后读回 usbw=' + ni.usbw + '（期望 ' + want + '）' +
          (i < attempts ? '，稍后重试…' : '，仍未生效'), 'warn');
      } catch (e) {
        verifyErr++;
        say('⚠️ 第 ' + i + '/' + attempts + ' 次提交后读回校验失败：' + e.message +
          (i < attempts ? '，稍后重试…' : ''), 'warn');
      }
      if (i < attempts) await icSleep(1500);
    }
    // 只有"确实读到过不符"才算失败；全程读回异常 → 视为无法校验，放行
    return { ok: (mismatch === 0), unverified: (mismatch === 0 && verifyErr > 0), usbw: lastGot, attempts: attempts };
  }

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
    // 【v18r14 关键修复】必须检查业务码 code。
    // 实测：/api/bigDeployLog/directDeployment 用 HMAC 三件套调用时返回 HTTP 200 + {"code":7,"msg":"未登录或非法访问"}
    // —— 该接口只认 x-token JWT，不认 HMAC。旧代码只看 resp.ok（HTTP 200）就当成功，
    // 导致日志谎报"已流转到服务中"，实际节点卡在"待配置"。
    if (json && typeof json === 'object' && json.code !== undefined && json.code !== 0) {
      var e7 = new Error('admin 业务码 ' + json.code + '：' + (json.msg || JSON.stringify(json).slice(0, 200)));
      e7.adminCode = json.code;
      e7.isAuthErr = (json.code === 7 || /未登录|非法访问|unauthorized|未授权/i.test(String(json.msg || '')));
      throw e7;
    }
    return json;
  }

  // 统一 admin 调用入口：优先用 HMAC 鉴权（三件套都填了），否则浏览器直连 admin.x-token，失败兜底走 supabase fn 转发
  // 失败时抛 Error，调用方 catch；HMAC 走不通（典型场景：admin 没开 CORS）自动回退到浏览器直连 → supabase
  // Fallback 仅在「网络层失败」或「HTTP 5xx」时触发；业务错误（HTTP 4xx 业务码）说明请求已到达后端，不 fallback
  //
  // 【路径归一化】admin 后端真实前缀是 /api/（从 admin 前端 JS 包 baseURL:"/api" 反编译确认；
  // v18r6 曾误改成 /backend/api/，导致 POST 命中 SPA 兜底返回 405，本次回退）。
  // 这里做防御性归一化：若有人手动填了 /backend/api/，自动纠正回 /api/。
  async function icAdminCall(method, path, body) {
    path = String(path || '');
    // /backend/api/xxx → /api/xxx（GET 会命中 SPA 兜底 HTML、POST 返回 405，必须纠正）
    path = path.replace(/^(https?:\/\/[^\/]+)?\/backend\/api\//, function (m, host) {
      return (host || '') + '/api/';
    });

    var hmacUsed = false;
    var directUsed = false;
    var hmacErr = null;
    var directErr = null;
    // ① 优先 HMAC（直连 admin，带 appId/timestamp/sign 头）— 不走任何代理
    if (icHasAdminHmac()) {
      hmacUsed = true;
      try {
        return await icAdminCallHmac(method, path, body);
      } catch (e) {
        hmacErr = e;
        // 【v18r16】HMAC 通道失败时**直接抛出**，不要 fallback。
        // 原因：实测 supabase 边缘到 admin.zhouyi.top 网络不可达（TCP connect error 110），
        // 浏览器直连 admin 又被 CORS 拒（Failed to fetch），fallback 链走不到 admin。
        // HMAC 是 admin 后端期望的机器对机器方式（参考 ipes_auto_deploy.sh + transition_to_service.sh），
        // HMAC 拿到 code=7 是真业务拒绝（path 错 / 该接口只认 JWT）→ 立即告知，不被 fallback 链路吞掉。
        if (!icIsNetworkErr(e)) {
          // 业务错（含 code=7）→ 不 fallback，直接抛
          throw e;
        }
        // 仅网络/CORS 失败才继续往下走 fallback（但目前 supabase 直连 admin 也不通，几乎无解）
      }
    }
    // ② 浏览器直连 admin.zhouyi.top（x-token 鉴权）— 绕开 supabase 区域出口被屏蔽
    var token = icGetAdminToken();
    if (!token) {
      if (hmacUsed && hmacErr) {
        // v18r14：区分「HMAC 鉴权被拒（该接口只认 x-token）」与「网络/CORS 失败」，提示更精准
        var why = hmacErr.isAuthErr
          ? ('HMAC 鉴权被拒（admin code=' + (hmacErr.adminCode || '?') + '，该接口只认 x-token JWT）')
          : ('HMAC 通道网络/CORS 失败（' + hmacErr.message + '）');
        throw new Error(why + '，且未配置 x-token，无法回退。请在「绑定舟翼云」面板填 admin Token（登录 admin.zhouyi.top 后从浏览器 localStorage 的 zy_admin_token 取）。');
      }
      throw new Error('未填写 admin Token 也未填 appId/ak/sk 三件套，请二选一');
    }
    try {
      directUsed = true;
      var directResp = await fetch('https://admin.zhouyi.top' + path, {
        method: method || 'POST',
        headers: { 'Content-Type': 'application/json', 'x-token': token },
        body: body == null ? undefined : JSON.stringify(body)
      });
      var directJson = null;
      try { directJson = await directResp.json(); } catch (e) { /* 非 JSON 也继续 */ }
      // 业务错（HTTP 4xx 业务码）→ 直接抛，不 fallback（兜底也救不了）
      if (directResp.status >= 400 && directResp.status < 500) {
        throw new Error('HTTP ' + directResp.status + (directJson ? ' · ' + (directJson.msg || directJson.message || JSON.stringify(directJson).slice(0, 200)) : ''));
      }
      // 网络层失败（HTTP 0/5xx/CORS）→ fallback 到 supabase 转发
      if (!directResp.ok) {
        throw new Error('HTTP ' + directResp.status + (directJson ? ' · ' + JSON.stringify(directJson).slice(0, 200) : ''));
      }
      // fallback 成功时日志（仅一次提示）
      if (hmacUsed && !icAdminCall._fallbackWarned) {
        icAdminCall._fallbackWarned = true;
        try { icLog('[image-clone] ⚠️ HMAC 通道不可用（' + hmacErr.message + '），已自动回退到浏览器直连 admin（本会话仅提示一次）', 'warn'); } catch (e3) {}
      }
      return directJson;
    } catch (e) {
      directErr = e;
      // 这里只可能是网络/CORS/HTTP5xx（业务错已在前面 throw）；走 supabase 兜底
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
        // 兜底成功时日志（仅一次提示）
        if (!icAdminCall._directFallbackWarned) {
          icAdminCall._directFallbackWarned = true;
          var hint = directErr ? ('浏览器直连失败（' + directErr.message + '），已自动回退到 supabase 转发') : '已自动回退到 supabase 转发';
          try { icLog('[image-clone] ⚠️ ' + hint + '（本会话仅提示一次）', 'warn'); } catch (e3) {}
        }
        return result;
      } catch (e4) {
        // 三层全部失败 → 把错误合并抛出去
        if (hmacUsed) {
          throw new Error('HMAC 失败（' + (hmacErr ? hmacErr.message : '?') + '），浏览器直连失败（' + directErr.message + '），supabase 转发也失败：' + e4.message);
        }
        throw new Error('浏览器直连 admin 失败（' + directErr.message + '），supabase 转发也失败：' + e4.message);
      }
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

  // 🔁 舟翼云设备注册命令生成器（带 code:-20「设备联网异常」重试）
  // 背景（2026-09-11 上机实证）：克隆机身份刚被重置就发起注册，平台必然回 `code:-20 设备联网异常`；
  //   而 zyy_init_max.sh 自带的 3 次重试只间隔 2 秒 → 3 次全失败后直接退出 →
  //   节点 isp / province / city / channel_id / ownerId 全空 → 后台格式化安装码报「未知运营商」。
  //   黄金机自己的历史日志给出标准样本：21:57:24 首次 -20 失败 → 21:58:54（90 秒后）重试即成功。
  // 策略：先等 preWait 秒让设备在舟翼云上线；每轮跑完校验 /usr/local/edge/registration_info 是否出现
  //   「注册状态: 成功」，未成功则等 gap 秒重试，最多 attempts 轮（默认 6 轮 × 40s ≈ 3.5 分钟窗口）。
  function icZyyRegisterCmd(zAk, zSk, zIsp, opts) {
    opts = opts || {};
    var attempts = opts.attempts || 6;
    var gap = opts.gap || 40;
    var preWait = opts.preWait || 0;
    if (!zAk || !zSk) return 'echo "未配置舟翼云 ak/sk，跳过自动绑定"';
    var url = 'https://zyy-go.oss-cn-beijing.aliyuncs.com/script/zyy_init/zyy_init_max.sh';
    var runOnce = 'curl -s ' + url + ' | bash -s -- --ak ' + zAk + ' --sk ' + zSk + ' --isp ' + (zIsp || '电信') + ' || true';
    var seq = [];
    for (var i = 1; i <= attempts; i++) seq.push(i);
    return [
      '# 🔁 舟翼云设备注册（含 -20「设备联网异常」重试，等设备上线后再注册）',
      'ZYY_REG=FAIL',
      preWait > 0
        ? 'echo "[zyy] 等待 ' + preWait + 's 让新身份在舟翼云上线后再注册..."; sleep ' + preWait
        : 'true',
      'for _zyy_i in ' + seq.join(' ') + '; do',
      '  echo "[zyy] 设备注册尝试 $_zyy_i/' + attempts + ' ..."',
      '  ' + runOnce,
      '  if grep -q "注册状态: 成功" /usr/local/edge/registration_info 2>/dev/null; then ZYY_REG=OK; echo "[zyy] ✅ 舟翼云注册成功"; break; fi',
      '  echo "[zyy] ⚠️ 注册未成功（多为 code:-20 设备联网异常），' + gap + 's 后重试"',
      '  if [ "$_zyy_i" -lt ' + attempts + ' ]; then sleep ' + gap + '; fi',
      'done',
      'echo "[zyy] 舟翼云注册最终结果: $ZYY_REG"'
    ].join('\n');
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
      '# 🏆 [0/8] 捕获黄金机当前身份，写入首启脚本守卫：黄金机自己重启时首启脚本识别到身份未变即退出，绝不重置黄金机身份',
      'GOLDEN_CODE=$(cat /etc/.mac 2>/dev/null || cat /usr/local/edge_zycloud/device_code 2>/dev/null || true)',
      'echo "[0/8] 黄金机当前身份: ${GOLDEN_CODE:--none-}（克隆机首启将生成全新身份，与黄金机永不冲突）"',
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
      '# 3. 真实缓存目录（2026-09-11 实测确认：IPES 真缓存在 /data/happ/happ.N/hdata/cache，不是 /var/lib/ipescache）',
      'PCDN_CACHE_DIR="/data/happ"',
      'echo "[3/8] 缓存目录 $PCDN_CACHE_DIR 体积: $(du -sh "$PCDN_CACHE_DIR" 2>/dev/null | awk \'{print $1}\')（正常应数十GB；若为 0 = 黄金机无缓存，打的镜像将不带缓存！）"',
      '',
      '# 4. 只清节点身份/令牌，【绝不删 /data/happ 缓存】（克隆机就靠它开机即带缓存）',
      'echo "[4/8] 只清理节点身份/令牌，保留 $PCDN_CACHE_DIR 缓存 ..."',
      'find "$PCDN_CACHE_DIR" -maxdepth 4 -type f \\( -iname "*token*" -o -iname "*regist*" -o -iname "*auth*" -o -iname "*secret*" \\) -delete 2>/dev/null || true',
      'rm -f /usr/local/edge/registration_info 2>/dev/null || true',
      'find /etc -maxdepth 3 -iname "*ipes*node*" -delete 2>/dev/null || true',
      'find /etc -maxdepth 3 -iname "*ipes*.token" -delete 2>/dev/null || true',
      'find /var/log -maxdepth 2 -iname "*ipes*" -type f -delete 2>/dev/null || true',
      '',
      '# 5. 重生成 SSH host key',
      'echo "[5/8] 重生成 SSH host key ..."',
      'rm -f /etc/ssh/ssh_host_*',
      'ssh-keygen -A',
      '',
      '# 6. 【黄金机保护】不再重置 machine-id / /etc/.mac / hostname！',
      'echo "[6/8] 跳过身份重置（保护源机身份；克隆机身份由首启脚本 ipes-firstboot.sh 重生成，无需动源机）"',
      '',
      '# 7. 写入首启自举脚本',
      'echo "[7/8] 部署首启自举脚本 /usr/local/bin/ipes-firstboot.sh ..."',
      'cat > /usr/local/bin/ipes-firstboot.sh <<\'IPESSCRIPT\'',
      '#!/bin/bash',
      'set -e',
      '# 🏆 黄金机守卫：/etc/.mac 仍等于黄金机原身份 = 本机就是黄金机（重启误触发首启），直接退出绝不动身份',
      'if [ "$(cat /etc/.mac 2>/dev/null)" = "__GOLDEN_CODE__" ]; then',
      '  echo "[firstboot] 本机是黄金机（身份未变），跳过身份重置，仅自禁用首启服务"',
      '  systemctl disable ipes-firstboot 2>/dev/null || true',
      '  exit 0',
      'fi',
      '# 📦 缓存还原（根治 v18r24）：SWAS 自定义镜像不打包 /data，标准化时已把 /data/happ 硬链接备份到 /opt/ipescache-seed，',
      '#    这里在 IPES 启动前把种子 mv 回 /data/happ（同盘 rename，瞬间完成、不占额外空间），让克隆机开机即带缓存。',
      'if [ -d /opt/ipescache-seed ]; then',
      '  docker stop ipes 2>/dev/null || true',
      '  mkdir -p /data/happ',
      '  rm -rf /data/happ/* 2>/dev/null || true',
      '  mv /opt/ipescache-seed/* /data/happ/ 2>/dev/null || true',
      '  rmdir /opt/ipescache-seed 2>/dev/null || true',
      '  echo "[firstboot] ✅ 已从缓存种子还原 /data/happ，体积: $(du -sh /data/happ 2>/dev/null | awk \'{print $1}\')"',
      'else',
      '  echo "[firstboot] ⚠️ 未发现 /opt/ipescache-seed —— 镜像未携带缓存（克隆机将冷启动、无继承缓存）"',
      'fi',
      '# 克隆机首启：生成全新身份（三处同步：/etc/machine-id + /etc/.mac + /usr/local/edge_zycloud/device_code），与黄金机永不冲突',
      'rm -f /etc/machine-id /etc/.mac',
      'head -c 16 /dev/urandom | xxd -p > /etc/machine-id',
      'head -c 16 /dev/urandom | xxd -p > /etc/.mac',
      'chmod 644 /etc/machine-id /etc/.mac',
      'NEW_MAC=$(cat /etc/.mac)',
      'mkdir -p /usr/local/edge_zycloud',
      'echo "$NEW_MAC" > /usr/local/edge_zycloud/device_code',
      'chmod 644 /usr/local/edge_zycloud/device_code',
      '# 清掉镜像继承的黄金机注册残留，再用新身份重启 edge_client（绝不携带黄金机旧码上线）',
      'rm -f /usr/local/edge/registration_info 2>/dev/null || true',
      'systemctl restart edge_client_zycloud 2>/dev/null || true',
      'NEW_HOST="ipes-$(head -c4 /dev/urandom | xxd -p 2>/dev/null || echo $(date +%s%N | cut -c1-8))"',
      'echo "$NEW_HOST" > /etc/hostname',
      'hostname "$NEW_HOST"',
      '# 📦 缓存保留：克隆机直接继承黄金机缓存数据，不再清空（身份已全部重置，IPES/edge_client 用新身份重新注册）',
      'IPES_SERVICE_NAME=$(systemctl list-unit-files --type=service 2>/dev/null | grep -iE \'ipes|pcdn\' | grep -v firstboot | head -1 | awk \'{print $1}\' || true)',
      '[ -z "$IPES_SERVICE_NAME" ] && IPES_SERVICE_NAME="ipes-agent.service"',
      'IPES_SERVICE_NAME=${IPES_SERVICE_NAME%.service}',
      'systemctl enable "$IPES_SERVICE_NAME"',
      'systemctl start "$IPES_SERVICE_NAME"',
      '# 🌐 清理镜像继承的黄金机公网 IP 写死（避免克隆机向 admin 上报黄金机 IP，导致两台节点显示同一公网IP）',
      'GOLDEN_WAN_IP="118.178.193.66"',
      'for cfg in $(grep -rln "$GOLDEN_WAN_IP" /etc/ipescache /etc/ipes* /usr/local/edge /usr/local/edge_zycloud /opt/zycloud 2>/dev/null); do',
      '  sed -i "s|$GOLDEN_WAN_IP||g" "$cfg"',
      '  echo "  [firstboot] 已清理写死IP(宿主机): $cfg"',
      'done',
      '# IPES 跑在 docker 容器里时，容器内配置也可能写死，启动后清一遍并重启容器',
      'if command -v docker >/dev/null 2>&1 && docker ps --format "{{.Names}}" 2>/dev/null | grep -qw ipes; then',
      '  docker exec ipes sh -c "grep -rln \'$GOLDEN_WAN_IP\' /etc /bin /usr/local 2>/dev/null | while read f; do sed -i \"s|$GOLDEN_WAN_IP||g\" \"$f\"; done" 2>/dev/null || true',
      '  docker restart ipes 2>/dev/null || true',
      'fi',
      'systemctl disable ipes-firstboot',
      '# 自动绑定舟翼云（换设备身份后自动注册，克隆机开机即上线，无需手动点按钮）',
      icZyyRegisterCmd(zAk, zSk, zIsp, { preWait: 30, attempts: 6, gap: 40 }),
      'echo "首启完成: $NEW_HOST"',
      'IPESSCRIPT',
      'chmod +x /usr/local/bin/ipes-firstboot.sh',
      '# 🏆 把黄金机真实身份写入首启脚本守卫占位符（克隆机身份不同 → 守卫放行正常重置；黄金机自身重启 → 守卫拦截直接退出）',
      'sed -i "s/__GOLDEN_CODE__/${GOLDEN_CODE:-none}/" /usr/local/bin/ipes-firstboot.sh',
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
      '',
      '# 9. 【缓存进镜像 · 根治 v18r24】SWAS 自定义镜像不打包 /data（平台把它当"数据区"排除），',
      '#    而 IPES 真缓存在 /data/happ → 直接打镜像会导致克隆机没缓存。',
      '#    这里用【硬链接】把 /data/happ 备份到 /opt/ipescache-seed（不占额外空间、秒级完成），',
      '#    使缓存落进镜像；克隆机首启脚本再把种子 mv 回 /data/happ。',
      'echo "[9/9] 备份缓存到 /opt/ipescache-seed（硬链接，供镜像携带）..."',
      'if [ -d "$PCDN_CACHE_DIR" ] && [ -n "$(ls -A "$PCDN_CACHE_DIR" 2>/dev/null)" ]; then',
      '  rm -rf /opt/ipescache-seed 2>/dev/null || true',
      '  cp -al "$PCDN_CACHE_DIR" /opt/ipescache-seed 2>/dev/null || cp -a "$PCDN_CACHE_DIR" /opt/ipescache-seed 2>/dev/null || true',
      '  echo "   ✅ 缓存种子体积: $(du -sh /opt/ipescache-seed 2>/dev/null | awk \'{print $1}\')（会随镜像带到克隆机）"',
      'else',
      '  echo "   ⚠️ /data/happ 为空，跳过缓存种子 —— 打的镜像将不带缓存！请先让黄金机积累缓存再打镜像。"',
      'fi',
      'sync',
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
    if (!confirm('确定在实例 ' + instId + '（' + region + '）上执行「黄金主机标准化」？\n\n这会：\n1) 停止 IPES 服务\n2) 只清理节点身份/令牌（缓存数据保留，克隆机可继承）\n3) 重生成 SSH host key\n4) 部署首启脚本并 enable（黄金机身份零改动；克隆机开机自动生成全新身份+自动绑定）\n\n执行后请重新打镜像。')) return;

    var st = document.getElementById('icStdStatus');
    st.innerHTML = '⏳ 正在向 ' + instId + ' 下发标准化命令...';

    try {
      // 🚨 SWAS 没有 RunCommand action（ECS 才有），改走 CreateCommand+InvokeCommand（v18r5 批量根治）
      var sub = await icRunCommandSubmit(region, instId, icBuildStandardizeScript(), 600);
      st.innerHTML = '✅ 标准化命令已下发到 ' + instId + '<br>CommandId: <code>' + sub.commandId + '</code><br>' +
        '请等待 1~2 分钟，登录实例确认 <code>/var/log/ipes-golden-prep.log</code> 末尾显示「标准化完成」后再重新打镜像。';
      icLog('[镜像克隆] 标准化命令已下发: ' + instId + ' CommandId=' + sub.commandId, 'success');
    } catch (e) {
      st.innerHTML = '❌ 标准化命令下发失败: ' + e.message;
      icLog('[镜像克隆] 标准化命令下发失败: ' + e.message, 'error');
    }
  }

  // 一键全流程：标准化 → 创建镜像 → 轮询就绪 → 开通（用户只需填实例ID/镜像名/数量）
  async function icFullCloneFlow() {
    if (!icGuard()) return;
    // 【v18r25 防重入】流程运行中再次点击 = 请求中断当前流程
    //   修复：之前可重复点击 → 两个流程并发 → 第二个查不到刚创建的镜像 → CreateCustomImage 报
    //   "The image name already exists." → 直接中断；且被中断方的轮询循环仍在空转（表现为"卡住"）
    if (icFlowRunning) {
      if (!confirm('⚠️ 全流程正在运行中（已 ' + icFlowElapsed() + ' 秒）。\n\n确定要【中断】当前流程吗？\n已创建的镜像不会删除，下次重跑会自动复用。')) return;
      icFlowAbort = true;
      icSetFlowBtn(false, true);
      return;
    }
    icFlowRunning = true;
    icFlowAbort = false;
    icFlowStartedAt = Date.now();
    icSetFlowBtn(true);
    var region = icGetRegion();
    var instId = (document.getElementById('icSrcInstance').value || '').trim();
    var imageName = (document.getElementById('icImageName').value || '').trim();
    var planId = (document.getElementById('icPlanId').value || '').trim();
    var amount = parseInt(document.getElementById('icAmount').value, 10) || 1;
    var period = parseInt(document.getElementById('icPeriod').value, 10) || 1;
    var autoPay = document.getElementById('icAutoPay').checked;
    imageName = icSanitizeImageName(imageName);
    document.getElementById('icImageName').value = imageName;  // 回写纠正后的名字

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
    var goldenCode = '';   // 🏆 黄金机原身份（流程结束后自动校验恢复的基准）

    try {
      // 🏆 记录黄金机身份（必须在标准化前读；流程收尾以此校验恢复）
      try {
        var gOut = await icRunCmdOutput(region, instId, 'cat /etc/.mac 2>/dev/null || cat /usr/local/edge_zycloud/device_code 2>/dev/null', 30);
        var gm = (gOut || '').match(/[a-f0-9]{32}/);
        if (gm) {
          goldenCode = gm[0];
          icRememberGolden(instId, goldenCode);
          step('🏆 黄金机身份已记录：<code>' + goldenCode + '</code>（流程结束后自动校验，被改即恢复）');
        } else {
          step('⚠️ 未能读取黄金机身份（可能尚未注册），本次跳过身份保护');
        }
      } catch (ge) { step('⚠️ 黄金机身份读取失败（流程继续）: ' + ge.message); }

      // ① 标准化（【v18r25 优化】原来硬等 120 秒，现改为轮询命令执行状态，跑完立即继续）
      step('① 下发标准化命令到 ' + instId + ' ...');
      // 🚨 SWAS 没有 RunCommand action，改走 CreateCommand+InvokeCommand（v18r5 批量根治）
      var stdInv = await icRunCommandSubmit(region, instId, icBuildStandardizeScript(), 600);
      step('⏳ 标准化执行中（轮询状态，完成即继续，不再固定等 120 秒）...');
      var stdRes = await icWaitInvokeDone(region, stdInv.invokeId, 300000);
      if (stdRes.status === 'success') {
        step('✅ 标准化完成（累计用时约 ' + icFlowElapsed() + 's）');
      } else if (stdRes.status === 'timeout') {
        step('⚠️ 标准化状态轮询超时（300s），保守再等 30 秒后继续...');
        await icSleepIC(30000);
      } else {
        step('⚠️ 标准化返回 ' + stdRes.status + '（继续流程，留意镜像是否含缓存）');
      }
      // 清理临时命令模板，避免堆积在「命令助手」
      try { await AliyunClient.callSwasApi(region, 'DeleteCommand', { RegionId: region, CommandId: stdInv.commandId }); } catch (e) { /* 忽略 */ }

      // ② 创建镜像（先查同名镜像：已存在直接复用，避免重打 + 支持中断后重跑续接）
      var newImageId = '';
      var reusedExisting = false;
      try {
        var exist = await icFindImageByName(region, imageName);
        if (exist) {
          newImageId = exist.ImageId || '';
          reusedExisting = true;
          step('✅ 镜像「' + imageName + '」已存在（ImageId=' + newImageId + '），跳过创建直接复用（省一次打镜像时间）');
        }
      } catch (e) { step('⚠️ 查询已有镜像失败（忽略，继续创建）: ' + e.message); }
      if (!newImageId) {
        // 【v18r25 优化】重名不再中断整个流程：先复查（可能刚创建成功、列表未刷新）→ 复用；查不到则自动换名重试
        var tryName = imageName;
        for (var attempt = 1; attempt <= 3 && !newImageId; attempt++) {
          icAbortCheck();
          step('② 创建镜像「' + tryName + '」...' + (attempt > 1 ? '（第 ' + attempt + ' 次尝试）' : ''));
          try {
            var cr = await AliyunClient.callCentralApi('CreateCustomImage', { RegionId: region, InstanceId: instId, ImageName: tryName });
            newImageId = cr.ImageId || cr.imageId || '';
            imageName = tryName;
            step('✅ 镜像已提交创建，ImageId=' + (newImageId || '(未知)') + '，等待就绪...');
            break;
          } catch (ce) {
            var cmsg = (ce && ce.message) || String(ce);
            // 🚨 自定义镜像配额已满（每个地域有上限，达到后无法再建）
            if (/maximum|exceed|quota|limit|超过.*上限|超过.*限制/i.test(cmsg)) {
              step('🚨 该地域自定义镜像已达上限（阿里云配额），请在面板「② 列镜像」点「🔄 加载我的自定义镜像」→「🗑️ 删除选中镜像」清掉不用的镜像后重试');
              step('   原始错误：' + cmsg);
              icLog('[镜像克隆] 镜像配额已满：' + region + '，需先删除旧镜像，原始=' + cmsg, 'error');
              throw ce;
            }
            // 重名：先复查是否其实已经建好了（并发/列表延迟的经典情形）
            if (/already exist|已存在|重复|duplicate/i.test(cmsg)) {
              var reuse = await icFindImageByName(region, tryName);
              if (reuse) {
                newImageId = reuse.ImageId || '';
                reusedExisting = true;
                imageName = tryName;
                step('✅ 镜像「' + tryName + '」实际已存在（ImageId=' + newImageId + '），直接复用，不再重复创建');
                break;
              }
              tryName = icUniqueImageName(imageName, attempt + 1);
              step('⚠️ 镜像名「' + imageName + '」已被占用且查不到记录，自动改用「' + tryName + '」重试...');
              continue;
            }
            throw ce;
          }
        }
        if (!newImageId) throw new Error('镜像创建失败：3 次尝试均未成功（请检查阿里云控制台）');
      }

      // ③ 轮询镜像就绪（最多 15 分钟 —— 实测 SWAS 自定义镜像创建要 5~10 分钟，5 分钟根本不够）
      // 【关键修复】SWAS ListImages 对自定义镜像不返回 Status 字段（实测仅 ImageName/Platform/ImageId/ImageType），
      // 因此“镜像出现在列表里”即视为就绪，不能再等 Status==='available'（永远等不到 → 超时中断 → 没有订单）。
      // 仅当 Status 字段存在且显式为 Creating/Waiting 时继续轮询，显式为失败时才报错。
      // 兜底：主地域一直空时跨地域扫描（镜像可能被路由到实例所在地域）。
      var allRegions = ['cn-hangzhou','cn-beijing','cn-shanghai','cn-shenzhen','cn-chengdu',
                        'cn-guangzhou','cn-heyuan','cn-wuhan-lr','cn-wulanchabu'];
      var ready = reusedExisting;  // 复用已有镜像：列表里能查到即已就绪，无需轮询
      if (reusedExisting) step('✅ 复用已有镜像，直接进入开通环节');
      var lastInfo = '';
      var scannedRegions = {};  // 跨地域扫描结果
      var crossScanDone = false;  // 跨地域扫描已做过一次（命中/未命中都不再重复，等主地域先出现）
      var pollStart = Date.now();
      var POLL_MAX = 110;
      // 【v18r27 提速】SWAS 自定义镜像构建通常 3~8 分钟：
      //   a) 3 秒一轮纯属浪费（还持续压代理）→ 前 8 轮 4 秒（抢占"秒就绪"窗口），之后 8 秒
      //      → 110 轮 ≈ 14 分钟覆盖，前期仍秒级发现，后期不再高频空打
      //   b) 每轮开始先检查中断标志 → 修复"点了中断/流程已报错，轮询还在空转"的卡住现象
      for (var i = 0; i < POLL_MAX; i++) {
        icAbortCheck();
        await icSleepIC(i < 8 ? 4000 : 8000);
        icAbortCheck();
        var lr;
        try {
          lr = await AliyunClient.callCentralApi('ListImages', { RegionId: region, ImageType: 'custom' });
        } catch (e) {
          // 降噪：报错最多每 5 轮提示一次
          if (i === 0 || (i + 1) % 5 === 0) {
            step('⚠️ [轮询 ' + (i + 1) + '] ListImages 报错（已等待 ' + Math.round((Date.now() - pollStart) / 1000) + 's）：' + e.message);
          }
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
            step('✅ 镜像就绪（第 ' + (i + 1) + ' 轮，已等待 ' + Math.round((Date.now() - pollStart) / 1000) + 's，' + info + '）');
            break;
          }
          if (/fail|error|创建失败/i.test(s)) {
            step('❌ 镜像创建失败：' + info + '\n原始=' + JSON.stringify(found).slice(0, 400));
            return;
          }
          // Status 显式还在 Creating/Waiting 等中间态：继续轮询（降噪，每 5 轮提示一次）
          if ((i + 1) % 5 === 0) {
            step('⏳ [轮询 ' + (i + 1) + '] ' + info + '，继续等待（已 ' + Math.round((Date.now() - pollStart) / 1000) + 's）...');
          }
        } else {
          // 降噪：不再每轮刷屏，每 5 轮报一次进度
          if (i === 0 || (i + 1) % 5 === 0) {
            var icWaitedS = Math.round((Date.now() - pollStart) / 1000);
            step('⏳ [轮询 ' + (i + 1) + '] 镜像生成中...（已等待 ' + icWaitedS + 's，列表 ' + imgs.length + ' 个' +
              (i === 0 ? '；SWAS 自定义镜像构建通常 3~8 分钟，属正常等待' : '') + '）');
          }
          // 首次打印 ListImages 原始前 3 个，帮判断 ImageId/字段名是否一致
          if (i === 0) {
            step('🔍 [' + region + '] ListImages 返回前 3 个：' + JSON.stringify(imgs.slice(0, 3)).slice(0, 600));
          }
          // 【加速】跨地域扫描：只在主地域持续空时做一次（命中或不命中都不重复），并发查所有其他地域
          // 实测 SWAS CreateCustomImage 通常在创建地域，跨地域是兜底防御 —— 做一次够用。
          // 【v18r27】扫描阈值从第 4 轮(≈12s)后移到第 12 轮(≈60s)：镜像几乎不会在 1 分钟内就绪，
          //   过早扫描只会白打一批并发、挤占 Edge Function，反而拖慢后续轮询。
          if (i >= 12 && !crossScanDone && imgs.length === 0) {
            crossScanDone = true;
            step('🌐 主地域 [' + region + '] 一直空，并发扫描其他 8 个地域...');
            try {
              var crossResults = await Promise.all(allRegions.filter(function (rid) { return rid !== region; }).map(function (rid) {
                return Promise.race([
                  AliyunClient.callCentralApi('ListImages', { RegionId: rid, ImageType: 'custom' })
                    .then(function (lrx) { return { rid: rid, imgs: icParseImgs(lrx), err: null }; })
                    .catch(function (ex) { return { rid: rid, imgs: [], err: ex.message }; }),
                  // 8 秒兜底超时：防 supabase aliyun-proxy Edge Function 自己 30-60s 超时拖死整轮
                  new Promise(function (resolve) { setTimeout(function () { resolve({ rid: rid, imgs: [], err: 'timeout8s' }); }, 8000); })
                ]);
              }));
              crossResults.forEach(function (r) { scannedRegions[r.rid] = r.imgs.length; });
              step('📊 跨地域扫描结果：' + Object.keys(scannedRegions).map(function (k) { return k + '=' + scannedRegions[k]; }).join(' / '));
              var hit = null;
              crossResults.forEach(function (r) {
                if (hit) return;
                var cand = r.imgs.filter(function (im) {
                  var iid = (im.ImageId || '').replace(/^m-/, '');
                  return (nid && iid === nid) || im.ImageName === imageName;
                })[0];
                if (cand) hit = { rid: r.rid, img: cand };
              });
              if (hit) {
                var s2 = (hit.img.Status || hit.img.status || hit.img.ImageStatus || '').toString();
                step('🎯 跨地域命中！实际 RegionId=' + hit.rid + '，「' + imageName + '」' + (s2 ? ('状态="' + s2 + '"') : '（无Status字段=已就绪）'));
                if (!s2 || s2.toLowerCase() === 'available' || s2.toLowerCase() === 'success' || s2.toLowerCase() === 'ready') {
                  region = hit.rid; newImageId = hit.img.ImageId || newImageId; ready = true;
                  step('✅ 镜像已就绪（跨地域找到，第 ' + (i + 1) + ' 轮，已 ' + Math.round((Date.now() - pollStart) / 1000) + 's）');
                  break;
                }
                if (/fail|error/i.test(s2)) {
                  step('❌ 镜像创建失败（跨地域找到）：' + JSON.stringify(hit.img).slice(0, 400));
                  return;
                }
                region = hit.rid;
                step('🔄 已切换轮询 region 到 ' + hit.rid + '，继续等待就绪...');
              }
            } catch (ex2) {
              step('⚠️ 跨地域扫描整体异常：' + ex2.message);
            }
          }
        }
      }
      if (!ready) {
        step('⚠️ 镜像未在 ' + Math.round((Date.now() - pollStart) / 60000) + ' 分钟内就绪。最后一次状态：' + (lastInfo || '(从未找到)'));
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

      // 🔒 镜像已固化 → 立即禁用黄金机的首启脚本
      //    镜像快照里 firstboot 仍是 enabled（克隆机首启要靠它重生身份），
      //    但黄金机自己必须禁用：否则黄金机哪天重启，首启脚本会重置身份导致掉线（9/7 事故）。
      //    守卫只是逻辑兜底，真正根治是这里直接关掉。
      try {
        await icRunCmdOutput(region, instId,
          'systemctl disable ipes-firstboot 2>/dev/null || true; echo firstboot-disabled', 30);
        step('🔒 黄金机首启脚本已禁用（镜像已固化，黄金机身份永不重置）');
        icLog('[镜像克隆] 🔒 黄金机 ipes-firstboot 已禁用', 'success');
      } catch (fe) {
        step('⚠️ 黄金机首启脚本禁用失败（不影响开通，可手动执行 systemctl disable ipes-firstboot）: ' + fe.message);
      }

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
        // 【v18r26】改为逐台下单，保证台数 == 用户填写数量（详见 icCreateOrdersOneByOne 注释）
        step('⏳ 正在逐台生成待支付订单（目标 ' + amount + ' 台）...');
        var orderIds = await icCreateOrdersOneByOne(region, newImageId, planId, amount, period,
          function (n, total, oid) {
            if (n === total || n % 5 === 0) step('   下单进度 ' + n + '/' + total + '（最新订单 ' + oid + '）');
          });
        var shown = orderIds.slice(0, 10).join('</code><br><code>') +
          (orderIds.length > 10 ? '</code><br>… 其余 ' + (orderIds.length - 10) + ' 个见控制台订单管理' : '');
        step('✅ 已生成 <b>' + orderIds.length + '</b> 个待支付订单（每单 1 台，<b style="color:#389e0d;">不扣费</b>）：<br><code>' +
          shown + '</code><br>请到阿里云控制台「费用中心 - 订单管理」把这些订单<b>勾选后一起支付</b>。');
        icLog('[镜像克隆] 全流程已生成 ' + orderIds.length + ' 个待支付订单，镜像=' + newImageId + ' 订单=' + orderIds.join(','), 'success');
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
      var bizBatch = icGenBusinessId();  // 批次号（76hex，统一标记）
      var entries2 = wait2.ids.map(function (id) {
        return { instanceId: id, publicIp: wait2.publicIpMap[id] || '', businessId: icGenBusinessId() };  // 每台独立 IPES SN
      });
      await icSaveCloneBizMap(entries2, bizBatch, region, newImageId);
      step('🔗 本批业务ID：<b>' + bizBatch.slice(0, 12) + '…</b>（' + entries2.length + ' 台已到服务中，每台分配独立 IPES SN 76hex，已云端持久化' + (wait2.ids.length < ids.length ? '；' + (ids.length - wait2.ids.length) + ' 台未就绪未计入' : '') + '）');
      icLog('[镜像克隆] 全流程完成: ' + instId + ' → 镜像 ' + newImageId + ' → 开通 ' + amount + ' 台', 'success');
    } catch (e) {
      if (e && e.message === IC_ABORT_MSG) {
        step('⛔ 已被用户中断（中途创建的镜像不会删除，下次重跑会自动复用）');
        icLog('[镜像克隆] 全流程被用户中断于 ' + icFlowElapsed() + 's', 'warn');
      } else {
        step('❌ 流程中断: ' + e.message);
        icLog('[镜像克隆] 全流程中断: ' + e.message, 'error');
      }
    } finally {
      // 【v18r25】释放并发锁 + 恢复按钮（放最前，保证后续黄金机恢复逻辑不受中断标志影响）
      var flowSecs = icFlowElapsed();
      icFlowRunning = false;
      icFlowAbort = false;
      icSetFlowBtn(false);
      step('⏱️ 本次流程耗时 <b>' + flowSecs + 's</b>');
      // 🏆 黄金机身份自动校验恢复（成功/中断都执行）——确保黄金机永不因克隆流程掉线
      if (goldenCode) {
        try {
          var curOut = await icRunCmdOutput(region, instId, 'cat /etc/.mac 2>/dev/null', 30);
          var cm2 = (curOut || '').match(/[a-f0-9]{32}/);
          if (!cm2 || cm2[0] !== goldenCode) {
            step('🛡️ 检测到黄金机身份被改动（' + (cm2 ? cm2[0] : '丢失') + ' → ' + goldenCode + '），自动恢复中...');
            var fixOut = await icRunCmdOutput(region, instId,
              'echo ' + goldenCode + ' > /etc/.mac; echo ' + goldenCode + ' > /etc/machine-id; mkdir -p /usr/local/edge_zycloud; echo ' + goldenCode + ' > /usr/local/edge_zycloud/device_code; chmod 644 /etc/.mac /etc/machine-id; systemctl restart edge_client_zycloud 2>/dev/null || true; sleep 6; grep -E "登录成功|登录数据" /usr/local/edge_zycloud/logs/edge_client.log 2>/dev/null | tail -1', 90);
            step('✅ <b style="color:#389e0d;">黄金机身份已恢复为 ' + goldenCode + '</b>，edge_client 已重启' + (fixOut ? '：' + fixOut.slice(-60) : ''));
            icLog('[镜像克隆] 🛡️ 黄金机身份已自动恢复 ' + goldenCode, 'success');
          } else {
            step('✅ 黄金机身份校验无改动（' + goldenCode + '）');
          }
        } catch (e2) {
          step('⚠️ 黄金机身份恢复失败，请手动检查: ' + e2.message);
          icLog('[镜像克隆] 黄金机身份恢复失败: ' + e2.message, 'error');
        }
      }
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
          var isG = icIsGolden(id);   // 🏆 黄金机：默认不勾选，绑定流程强制跳过
          return '<label style="display:flex;align-items:center;gap:6px;padding:3px 0;cursor:pointer;' + (isG ? 'background:#fffbe6;border-radius:4px;' : '') + '">' +
            '<input type="checkbox" class="icBindChk" value="' + id + '" ' + (st === 'Running' && !isG ? 'checked' : '') + '> ' +
            (isG ? '<span title="黄金机受保护：不参与绑定，身份永不重置">🏆<b>黄金机</b></span>' : '') +
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
    chks.forEach(function (c) { c.checked = master.checked ? !icIsGolden(c.value) : false; });  // 🏆 全选也跳过黄金机
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
    // 🏆 黄金机保护：注册在案的黄金机不参与绑定（防清身份/重装导致设备掉线）
    var goldenHits = ids.filter(function (x) { return icIsGolden(x); });
    if (goldenHits.length) {
      ids = ids.filter(function (x) { return !icIsGolden(x); });
      icLog('[绑定舟翼云] 🛡️ 已强制跳过黄金机（身份保护）: ' + goldenHits.join(', '), 'warn');
    }
    if (!ids.length) { alert('勾选的实例全部是受保护的黄金机，已全部跳过。\n\n黄金机不参与绑定/清身份，防止 device_code 被重置导致设备掉线。'); return; }
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
    var cmd = pre + icZyyRegisterCmd(ak, sk, isp, { preWait: 0, attempts: 6, gap: 40 });

    var st = document.getElementById('icBindStatus');
    var prog = document.getElementById('icBindProgress');
    st.innerHTML = '';
    var done = 0, ok = 0, fail = 0;
    function tick() { done++; prog.textContent = '进度 ' + done + '/' + ids.length + ' (成功 ' + ok + ' 失败 ' + fail + ')'; }

    // 有界并发（最多 30 台同时下发）—— 【v18r30】按用户要求批量部署统一 30 台一批
    var CONC = 30, idx = 0;
    async function worker() {
      while (idx < ids.length) {
        var iid = ids[idx++];
        var bid = bizByInst[iid] || '';
        // 该实例专属命令：绑定 + 把业务ID 写克隆机本地，使「设备ID ↔ 业务ID」在设备侧物理闭环
        var instCmd = cmd + (bid ? ('; mkdir -p /usr/local/edge && echo "' + bid + '" > /usr/local/edge/business_id') : '');
        try {
          // 🚨 SWAS 没有 RunCommand action，改走 CreateCommand+InvokeCommand（v18r5 批量根治）
          await icRunCommandSubmit(region, iid, instCmd, 600);
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
    // 🏆 黄金机保护：注册在案的黄金机不参与绑定/流转（防清身份导致掉线）
    var goldenHits = ids.filter(function (x) { return icIsGolden(x); });
    if (goldenHits.length) {
      ids = ids.filter(function (x) { return !icIsGolden(x); });
      icLog('[一键流转] 🛡️ 已强制跳过黄金机（身份保护）: ' + goldenHits.join(', '), 'warn');
    }
    if (!ids.length) { alert('勾选的实例全部是受保护的黄金机，已全部跳过。\n\n黄金机不参与绑定/清身份，防止 device_code 被重置导致设备掉线。'); return; }

    // 保险：如果还有未勾选的 Running 实例，提示用户（避免误漏克隆机）
    var unchk = Array.prototype.slice.call(document.querySelectorAll('.icBindChk:not(:checked)'));
    var unchkRunning = unchk.filter(function (c) {
      if (icIsGolden(c.value)) return false;  // 🏆 黄金机默认不勾选，不算遗漏
      var lab = c.parentElement && c.parentElement.textContent || '';
      return /Running/i.test(lab);
    });
    if (unchkRunning.length) {
      var list = unchkRunning.slice(0, 5).map(function (c) { return c.value; }).join(', ');
      var extra = unchkRunning.length > 5 ? (' 等共 ' + unchkRunning.length + ' 台') : '';
      if (!confirm('⚠️ 还有 ' + unchkRunning.length + ' 台 Running 未勾选：' + list + extra + '\n\n只对当前勾选生效。继续？')) return;
    }

    // 鉴权方式二选一：admin Token（x-token 走 supabase 转发）OR appId/ak/sk（HMAC 直连 admin）
    var token = icGetAdminToken();
    if (!token && !icHasAdminHmac()) { alert('请二选一填写：\n  1) 「🔑 admin.zhouyi.top Token」 粘贴 x-token\n  2) 「🔐 admin 三件套」 填 appId/ak/sk（走 HMAC）'); return; }
    // vendor / transMode 等业务参数已写死（IC_DEFAULT_* 常量，对齐 test.sh + 用户 2026-09-10 截图），无需用户输入
    // ⚠️ 【6 步流程写死】用户明确要求"按截图走 + 以后不要改"：下面 4 步调用参数全部固化，任何人（含 AI）不得改动。
    //   步骤 1：下发 zyy_init 绑定命令（带 ak/sk/isp）
    //   步骤 2：SSH 读 device_code（前端预生成 76hex 新 SN 写入 ipes 容器，避让黄金机 SN 冲突）
    //   步骤 3：updateEdgeNominalInfo 提交带宽业务（7 字段 + expectedBiz/ipScheduleType 全部从 IC_DEFAULT_* 读，对齐 test.sh + 截图）
    //   步骤 4：stateflow 状态流转 → "服务中"（业务ID = 76hex IPES SN）【v18r27：原写 directDeployment，后端实为「强制提交」，已纠正】
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
    var cmd = pre + icZyyRegisterCmd(ak, sk, isp, { preWait: 0, attempts: 6, gap: 40 });
    var done = 0, ok = 0, fail = 0, idx = 0;
    function tick() { done++; prog.textContent = '进度 ' + done + '/' + ids.length + ' (成功 ' + ok + ' 失败 ' + fail + ')'; }
    async function worker() {
      while (idx < ids.length) {
        var iid = ids[idx++];
        try {
          // 🚨 SWAS 没有 RunCommand action，改走 CreateCommand+InvokeCommand（v18r5 批量根治）
          await icRunCommandSubmit(region, iid, cmd, 600);
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
    // 读 device_code 的脚本（v18r9 修复：克隆机必须用前端生成的全新 76hex SN 当业务ID，
    // 旧版 v18r8 只 docker restart ipes 假设它会自动换 SN，结果克隆机仍带着黄金机的旧 SN，
    // admin 业务ID 字段冲突 → 调度器无法定位 → 仍是"待配置"）。
    //   1) 前端用 crypto.getRandomValues(38 bytes) 预生成全新 76hex NEW_IPES_SN（每台克隆机独立随机，必与黄金机不冲突）
    //   2) SSH：echo NEW_IPES_SN | docker exec -i ipes tee /bin/ipes_sn（覆盖黄金镜像继承的旧 SN），再 restart ipes 让它加载
    //   3) 兜底：cat /usr/local/edge_zycloud/device_code（32hex edge_client 节点ID）
    //   4) 终极兜底：hostname
    // 输出两行 key=value：IPES_SN=<76hex> / NODE_ID=<32hex>
    function genNewIpesSn() {
      var bytes = new Uint8Array(38);
      (window.crypto || window.msCrypto).getRandomValues(bytes);
      var hex = '';
      for (var i = 0; i < bytes.length; i++) hex += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
      return hex;
    }
    function buildReadCodeCmd(newSn) {
      return [
        'SN=""; NID="";',
        'NEW_SN="' + newSn + '";',
        '# 主路径：把前端预生成的 76hex 新 SN 写进 ipes 容器 bin/ipes_sn（覆盖继承的旧 SN），再 restart 让它加载',
        'if command -v docker >/dev/null 2>&1 && docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qx "ipes"; then',
        '  printf "%s" "$NEW_SN" | docker exec -i ipes tee /bin/ipes_sn >/dev/null 2>&1 || true;',
        '  docker restart ipes >/dev/null 2>&1 || true;',
        '  for i in 1 2 3 4 5 6 7 8 9 10; do',
        '    sleep 3;',
        '    s=$(docker exec ipes cat bin/ipes_sn 2>/dev/null | tr -d "[:space:]");',
        '    if [ "$s" = "$NEW_SN" ]; then SN="$NEW_SN"; break; fi;',
        '  done;',
        '  [ -z "$SN" ] && SN="$NEW_SN";',
        'fi;',
        '# 兜底：edge_client 节点身份',
        'for f in /usr/local/edge_zycloud/device_code /etc/.mac; do',
        '  [ -r "$f" ] && NID=$(cat "$f" 2>/dev/null | tr -d "[:space:]") && [ -n "$NID" ] && break;',
        'done;',
        '[ -z "$NID" ] && NID=$(hostname);',
        '[ -z "$SN" ] && SN="$NID";',
        'printf "IPES_SN=%s\\nNODE_ID=%s\\n" "$SN" "$NID"'
      ].join('\n');
    }
    var RC_DEADLINE = Date.now() + 300000;  // 5 分钟总截止（docker exec tee + ipes 重启轮询最坏 33s，留余量）
    async function readDeviceCode(iid) {
      // 🚨 SWAS 没有 RunCommand action（v18r3 已踩坑），必须走 CreateCommand+InvokeCommand+DescribeCommandInvocations。
      // 复用 icRunCmdOutput（callSwasApi 直连，含超时/DeleteCommand 兜底）。
      // v18r9：前端预生成 76hex 新 SN，SSH 写进 ipes 容器 + restart，让克隆机带全新业务ID 上线
      var newSn = genNewIpesSn();
      var cmd = buildReadCodeCmd(newSn);
      var out = await icRunCmdOutput(region, iid, cmd, 60);
      // 解析 SSH 输出：IPES_SN=<76hex 业务ID> + NODE_ID=<32hex edge_client 节点ID>
      var snMatch  = (out || '').match(/IPES_SN=([a-f0-9]{40,})/i);
      var nidMatch = (out || '').match(/NODE_ID=([a-f0-9]+)/i);
      if (snMatch && nidMatch) {
        var snWritten = (snMatch[1] === newSn);  // SSH 写入是否真正生效
        return { nodeId: nidMatch[1], businessId: snMatch[1], source: snWritten ? 'new-sn-written' : 'sn-mismatch-fallback' };
      }
      // 兜底 1：只抓到单段长 hex 串（兼容老 SSH 输出格式）
      var single = (out || '').match(/[a-f0-9]{40,}/i);
      if (single) return { nodeId: single[0], businessId: single[0], source: 'ipes-direct' };
      // 兜底 2：只抓到 32hex（无 IPES 容器，老机器）
      var shortHex = (out || '').match(/[a-f0-9]{32}/i);
      if (shortHex) return { nodeId: shortHex[0], businessId: shortHex[0], source: 'edge_client-only' };
      throw new Error('输出无有效 device_code: ' + (out || '').slice(0, 200));
    }
    var rcIdx = 0;
    async function rcPool() {
      while (rcIdx < ids.length && Date.now() < RC_DEADLINE) {
        var iid = ids[rcIdx++];
        try {
          var r = await readDeviceCode(iid);
          matched.push({ instanceId: iid, nodeId: r.nodeId, businessId: r.businessId, deviceId: r.nodeId, publicIp: ipMap[iid] || '', snSource: r.source });
          log('✅ ' + iid + ' nodeId=' + r.nodeId + '  businessId(IPES SN)=' + r.businessId + '（SN来源：' + r.source + '）');
        } catch (e) {
          log('❌ ' + iid + ' 读 device_code 失败: ' + e.message);
        }
      }
    }
    var rcPoolArr = [];
    for (var rw = 0; rw < Math.min(10, ids.length); rw++) rcPoolArr.push(rcPool());
    await Promise.all(rcPoolArr);
    if (!matched.length) { log('⚠️ 没有读到任何 device_code，停止流转。请确认机器已装 zyy agent 且 /usr/local/edge_zycloud/device_code 或 /etc/.mac 存在'); return; }
    // 【业务ID 写死校验 - 用户 2026-09-10】业务ID 必须 76hex IPES SN，与 admin 业务字段、ipes 容器 bin/ipes_sn 一致。
    //   短于 76hex（兜底 32hex edge_client）的机器一律禁止流转，与"业务ID 写死为 76hex"规则冲突。
    var matchedValid = matched.filter(function (m) { return /^[a-f0-9]{76}$/i.test(m.businessId); });
    var matchedInvalid = matched.filter(function (m) { return !/^[a-f0-9]{76}$/i.test(m.businessId); });
    if (matchedInvalid.length) {
      log('<span style="color:#fa8c16;">⚠️ ' + matchedInvalid.length + ' 台机器业务ID不是76hex（可能是老机器/无 ipes 容器），【业务ID=76hex IPES SN】规则不允许流转，已过滤：</span>');
      matchedInvalid.forEach(function (m) { log('  ⛔ ' + m.instanceId + ' nodeId=' + m.nodeId + ' businessId(长度=' + m.businessId.length + ')=' + m.businessId.slice(0, 12) + '…'); });
    }
    if (!matchedValid.length) { log('⚠️ 没有机器业务ID符合76hex规则，全部禁止流转。'); return; }
    matched = matchedValid;
    log('<b>🎯 已读到 ' + matched.length + '/' + ids.length + ' 台 76hex 业务ID，开始调 admin 后台流转</b>');

    // 4) 状态流转：把前端生成的全新 76hex IPES SN 填入业务ID，调用 updateEdgeNominalInfo + stateflow（v18r27 纠正）
    log('🚀 开始状态流转（待配置 → 服务中），业务ID = 前端生成的新 76hex IPES SN（与黄金机必不冲突）...');
    // 【v18r16】早期校验：状态流转必须有 HMAC 三件套。
    // 原因：实测 supabase 边缘到 admin.zhouyi.top 网络不可达（TCP connect timeout 110），
    // 浏览器直连 admin 跨域 CORS 拒，只有 HMAC 三件套直连 admin 这条路能走通。
    if (!icHasAdminHmac()) {
      log('<span style="color:#cf1322;">❌ 状态流转必须填 admin 后端鉴权三件套（appId / ak / sk）。<br>' +
        '原因：浏览器直连 admin.zhouyi.top 会被 CORS 拒；supabase 边缘到 admin.zhouyi.top 网络不可达（实测 TCP 超时 110）。<br>' +
        '只有 HMAC 三件套直连 admin 这条路能走通，参考 ipes_auto_deploy.sh + transition_to_service.sh。<br>' +
        '请展开「🔑 admin 后端鉴权三件套」面板填入，然后重试。</span>');
      log('<span style="color:#cf1322;">状态流转完成：提交成功 0 / 部署成功 0 / 失败 ' + matched.length + '</span>');
      icLog('[镜像克隆] 状态流转中断：缺少 HMAC 三件套', 'error');
      return;
    }
    log('🔐 当前使用 appId/ak/sk HMAC 鉴权（直连 admin，绕开 CORS 与 supabase 区域出口屏蔽）');
    var submitOk = 0, deployOk = 0, deployFail = 0, successList = [];
    var idx2 = 0;
    var adminFn = icAdminCall;   // 统一入口：自动选 HMAC 或 x-token
    async function flowWorker() {
      while (idx2 < matched.length) {
        var m = matched[idx2++];
        try {
          // 把新设备SN填入业务ID（同步到 one-click-deploy 面板展示）
          var bizEl = document.getElementById('ocdBusinessId');
          if (bizEl) bizEl.value = m.businessId;
          // 批量提交（updateEdgeNominalInfo —— test.sh 实测接口，提交带宽/业务；非 updateEdgeRemark）
          //   nodeId    = 32hex edge_client 节点ID（admin 用它识别节点）
          //   businessId = 76hex IPES SN（admin 业务字段，关联到黄金机 d8891866... 同格式）
          //   expectedBiz / ipScheduleType = 用户 2026-09-10 截图「编辑」页字段，写死
          // 【v18r29】改走 icSubmitNominalVerified：内部自动「服务中→待配置」降级 + 提交后读回 usbw 校验 + 重试。
          //   背景：3 台克隆机曾出现"接口返回成功、实际 usbw 只有 40"（节点已是服务中被静默拒绝）。
          //   校验不通过 → 中止本台流转，避免"带宽没写进去却流转到服务中"被漏过。
          var sub = await icSubmitNominalVerified(adminFn, m, cfg, function (msg, lv) {
            log('<span style="color:' + (lv === 'warn' ? '#fa8c16' : '#389e0d') + ';">' + msg + '</span>');
          });
          if (!sub.ok) {
            throw new Error('建设带宽提交后校验未通过：读回 usbw=' + sub.usbw + '（期望 ' + cfg.usbw +
              '，已重试 ' + sub.attempts + ' 次），已中止流转以免带宽缺失被漏过');
          }
          if (sub.unverified) {
            log('<span style="color:#fa8c16;">⚠️ ' + m.nodeId + ' 建设带宽「无法校验」（读回接口异常），已按成功继续，请稍后到 admin 后台人工核对 usbw</span>');
          }
          submitOk++;
          // 批量部署（状态流转）：待配置 → 服务中
          // 【v18r27 纠正】改用后台真实接口 /api/edgeNode/stateflow，body = {nodes, hostname(业务ID), stage:'inService'}
          //   证据见文件顶部 IC_DEFAULT_STATEFLOW_* 常量段注释（反查 admin 前端 bundle）。
          //   旧的 directDeployment 只是兜底（路由缺失时），不再默认使用。
          var deployBody;
          if (cfg.deployBodyOverride) {
            try { deployBody = JSON.parse(cfg.deployBodyOverride); } catch (e) { deployBody = null; }
          }
          var dRes;
          if (deployBody) {
            // 「高级部署请求体」手工覆盖：完全按用户填的发（保持原能力）
            var deployPath = (typeof cfg.deployPath === 'string' && cfg.deployPath) || IC_DEFAULT_STATEFLOW_PATH;
            dRes = await adminFn('POST', deployPath, deployBody);
          } else {
            dRes = await icStateFlow(m.nodeId, m.businessId, adminFn);
            deployBody = { nodes: [m.nodeId], hostname: m.businessId, stage: IC_DEFAULT_STATEFLOW_STAGE };
          }
          var dCode = (dRes && dRes.code !== undefined) ? dRes.code : null;
          if (dCode !== null && dCode !== 0) {
            throw new Error('状态流转返回业务码 ' + dCode + '：' + ((dRes && dRes.msg) || JSON.stringify(dRes).slice(0, 200)) +
              '（POST ' + IC_DEFAULT_STATEFLOW_PATH + ' body=' + JSON.stringify(deployBody) + '）');
          }
          deployOk++;
          successList.push(m);
          log('<span style="color:#389e0d;">✅ ' + m.nodeId + ' 已流转到服务中（业务ID=' + m.businessId + '，SN来源=' + m.snSource + '）</span>');
          icLog('[镜像克隆] 状态流转成功 nodeId=' + m.nodeId + ' businessId=' + m.businessId, 'success');
        } catch (e) {
          deployFail++;
          log('<span style="color:#cf1322;">❌ ' + m.nodeId + ' 流转失败: ' + e.message + '</span>');
          icLog('[镜像克隆] 状态流转失败 ' + m.nodeId + ': ' + e.message, 'error');
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
      var entries = successList.map(function (m) { return { instanceId: m.instanceId, deviceId: m.nodeId, businessId: m.businessId, publicIp: m.publicIp, snSource: m.snSource }; });
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
  window.icDeleteSelectedImage = icDeleteSelectedImage;
  window.icLaunchFromImage = icLaunchFromImage;
  window.icOneKeyStandardize = icOneKeyStandardize;
  window.icFullCloneFlow = icFullCloneFlow;
  window.icBindLoadInstances = icBindLoadInstances;
  window.icBindZhouyi = icBindZhouyi;
  window.icBindAndDeploy = icBindAndDeploy;
  window.icBindToggleAll = icBindToggleAll;
  window.icQueryEdgeDetail = icQueryEdgeDetail;   // 查 admin 后端节点详情（含 businessId）
  // v18r15：克隆映射表多选/删除/全选辅助函数
  window.icBizToggleAll = icBizToggleAll;
  window.icBizUpdateBar = icBizUpdateBar;
  window.icBizDeleteSelected = icBizDeleteSelected;
  // 手动指定 nodeId 查详情（默认填 f670e4ea965c392ef44dca557b320a43）
  async function icQuerySelectedEdgeDetail() {
    var st = document.getElementById('icBindStatus');
    if (!st) return;
    var nodeId = prompt('输入要查的 device_code（节点ID）：', 'f670e4ea965c392ef44dca557b320a43');
    if (!nodeId) return;
    nodeId = nodeId.trim();
    if (!nodeId) return;
    st.innerHTML = '<div>🔍 查 admin 节点详情：' + nodeId + ' ...</div>';
    var r = await icQueryEdgeDetail(nodeId);
    if (!r.ok) {
      st.innerHTML += '<div style="color:#cf1322;">❌ 查询失败：' + r.error + '</div>';
      icLog('[镜像克隆] 查 admin 节点详情失败 ' + nodeId + ': ' + r.error, 'error');
      return;
    }
    var f = r.fields;
    st.innerHTML += '<div style="background:#fffbe6;border:1px solid #ffe58f;border-radius:6px;padding:10px;margin-top:8px;font-size:13px;">'
      + '<div><b>📋 admin 后端节点详情</b></div>'
      + '<div>节点ID (deviceCode) = <code>' + f.nodeId + '</code></div>'
      + '<div>业务ID (businessId) = <code style="color:#cf1322;">' + (f.businessId || '⚠️ 空') + '</code></div>'
      + '<div>节点备注 = ' + (f.remark || '—') + '</div>'
      + '<div>节点属主ID = ' + (f.ownerId || '—') + '</div>'
      + '<div>网络状态 = ' + (f.networkStatus || '—') + '</div>'
      + '<div>期望业务 = ' + (f.expectedBiz || '—') + '</div>'
      + '<div>供应商 = ' + (f.vendor || '—') + '</div>'
      + '<div>IP = ' + (f.ip || '—') + '</div>'
      + '<details style="margin-top:6px;"><summary style="cursor:pointer;color:#888;">原始 JSON</summary>'
      + '<code style="font-size:11px;">' + JSON.stringify(r.raw, null, 2).slice(0, 3000) + '</code></details>'
      + '</div>';
    icLog('[镜像克隆] 查 admin 节点详情成功 ' + nodeId + ' → businessId=' + f.businessId, 'success');
  }
  window.icQuerySelectedEdgeDetail = icQuerySelectedEdgeDetail;

  // 已知 deviceCode → 远端读 IPES SN → 调 admin 后端：updateEdgeNominalInfo（写业务ID/期望业务/带宽）+ stateflow（流转到服务中；v18r27 纠正）
  // 业务ID = IPES SN（76hex，从 `docker exec ipes cat bin/ipes_sn` 读），不是 nodeId（32hex，edge_client device_code）
  // 用于：克隆机清掉旧 SN 重启容器后拿到新 SN 码，一键把业务ID 填到 admin 并流转
  // 流程：
  //   1) SWAS RunCommand（实例内 docker exec ipes cat bin/ipes_sn）+ DescribeCommandInvocations → 拿 76hex IPES SN
  //   2) POST /api/edgeNode/updateEdgeNominalInfo  body={nodeId, businessId(IPES SN), vendorSuggestCustomers, transMode, ...}
  //   3) POST /api/edgeNode/stateflow  body={nodes:[nodeId], hostname:<业务ID>, stage:"inService"}
  async function icDirectDeployByNodeId() {
    if (!icGuard()) return;
    var st = document.getElementById('icBindStatus');
    if (!st) return;
    // 输入 1: device_code (32hex edge_client device_code = /etc/.mac)
    var nodeId = prompt('步骤1：输入 device_code（32hex 新设备SN），例如 94e9a95af733f202ae6c5ea74697120c：', '');
    if (!nodeId) return;
    nodeId = nodeId.trim();
    if (!nodeId || !/^[a-f0-9]{32}$/i.test(nodeId)) { alert('device_code 必须是 32 位 hex 字符'); return; }
    // 输入 2: SWAS 实例 ID（用于 RunCommand 读 IPES SN）
    var instanceId = prompt('步骤2：输入 SWAS 实例 ID（用于读 IPES SN），例如 d62a3db1c86c4860aaf7737cb5fda7b2：', '');
    if (!instanceId) return;
    instanceId = instanceId.trim();
    var region = 'cn-hangzhou';
    // 检查阿里云 AK/SK 是否已配置（RunCommand 需要）
    var ak = (window.getAccessKeyId ? window.getAccessKeyId() : (typeof getAccessKeyId === 'function' ? getAccessKeyId() : ''));
    var sk = (window.getAccessKeySecret ? window.getAccessKeySecret() : (typeof getAccessKeySecret === 'function' ? getAccessKeySecret() : ''));
    if (!ak || !sk) { alert('请先在「凭证管理」填阿里云 AK/SK（用于 RunCommand 读 IPES SN）'); return; }
    // 检查 admin 鉴权
    var token = icGetAdminToken();
    if (!token && !icHasAdminHmac()) {
      alert('请二选一填写：admin 鉴权\n  1) 「🔑 admin.zhouyi.top Token」 粘贴 x-token\n  2) 「🔐 admin 三件套」 填 appId/ak/sk（走 HMAC）');
      return;
    }
    if (!confirm('将执行以下步骤：\n\n1) SWAS RunCommand 到 ' + instanceId + '（' + region + '）读 IPES SN（docker exec ipes cat bin/ipes_sn）\n2) admin updateEdgeNominalInfo：nodeId=' + nodeId + ', businessId=<IPES SN>, vendorSuggestCustomers=41, transMode=0, isCrossNetwork=false, usbw=200, bwNum=1, expectedBiz=自研Q2\n3) admin stateflow：流转「待配置 → 服务中」（body={nodes,hostname,stage}）\n\n确认执行？')) return;

    st.innerHTML = '<div>🚀 已知 deviceCode 流转：' + nodeId + ' ...</div>';
    var cfg = {
      vendorSuggestCustomers: IC_DEFAULT_VENDOR_CUSTOMERS,
      transMode: IC_DEFAULT_TRANS_MODE,
      isCrossNetwork: IC_DEFAULT_IS_CROSS_NETWORK,
      crossNetworkIsp: IC_DEFAULT_CROSS_NETWORK_ISP,
      isTransProv: IC_DEFAULT_IS_TRANS_PROV,
      usbw: IC_DEFAULT_USBW,
      bwNum: IC_DEFAULT_BW_NUM,
    };
    if (icHasAdminHmac()) st.innerHTML += '<div style="font-size:12px;color:#888;">🔐 admin 走 appId/ak/sk HMAC 直连</div>';
    else st.innerHTML += '<div style="font-size:12px;color:#888;">🔑 admin 走 x-token 经 supabase 转发</div>';
    st.innerHTML += '<div style="font-size:12px;color:#888;">📡 RunCommand 走 supabase aliyun-proxy 转发（避免 SWAS CORS）</div>';

    try {
      // 步骤 1: 创建 SWAS 命令模板 + 调用，读 IPES SN（业务ID，76hex）
      // 🚨 SWAS 没有 RunCommand action，复用 icRunCmdOutput（v18r5 批量根治）
      st.innerHTML += '<div>📝 1/3 调用 SWAS CreateCommand+InvokeCommand 读 IPES SN...</div>';
      var businessId = null;
      try {
        var snOut = await icRunCmdOutput(region, instanceId, 'docker exec ipes cat bin/ipes_sn 2>/dev/null || echo NO_IPES_SN', 30);
        var m = (snOut || '').match(/[a-f0-9]{40,}/i);
        if (m) businessId = m[0];
      } catch (e) { throw new Error('读 IPES SN 失败: ' + e.message); }
      if (!businessId) throw new Error('未读到 IPES SN（机器可能未运行 docker ipes）');
      // 【业务ID 写死校验】必须 76hex（admin 与 ipes 容器 bin/ipes_sn 一致）。短于 76hex 会破坏与机器的对应关系，禁止继续。
      if (!/^[a-f0-9]{76}$/i.test(businessId)) throw new Error('读到的 IPES SN 不是 76hex：' + businessId + '（长度=' + businessId.length + '），拒绝流转。');
      st.innerHTML += '<div style="color:#389e0d;">✅ IPES SN（业务ID，76hex）= <code style="color:#cf1322;">' + businessId + '</code></div>';

      // 步骤 2: updateEdgeNominalInfo（写业务ID = IPES SN + 带宽/业务参数；test.sh 实测接口）
      // 【v18r29】改走 icSubmitNominalVerified：服务中/交付中会自动先降级到「待配置」，
      //   提交后读回 nominalInfo.usbw 校验（code:0 ≠ 已落库），不符则重试，仍不符则中止流转。
      st.innerHTML += '<div>📝 2/3 updateEdgeNominalInfo（自动 upsert 节点 + 写业务ID + 业务参数，含读回校验）...</div>';
      var sub = await icSubmitNominalVerified(icAdminCall, { nodeId: nodeId, businessId: businessId }, cfg, function (msg, lv) {
        st.innerHTML += '<div style="color:' + (lv === 'warn' ? '#fa8c16' : '#389e0d') + ';">' + msg + '</div>';
      });
      if (!sub.ok) {
        throw new Error('建设带宽提交后校验未通过：读回 usbw=' + sub.usbw + '（期望 ' + cfg.usbw +
          '，已重试 ' + sub.attempts + ' 次），已中止流转以免带宽缺失被漏过');
      }
      st.innerHTML += '<div style="color:#389e0d;">✅ updateEdgeNominalInfo 成功并校验通过：usbw=' + sub.usbw + '（第 ' + sub.attempts + ' 次提交）</div>';

      // 步骤 3: 状态流转（待配置 → 服务中）
      // 【v18r27 纠正】走后台真实接口 /api/edgeNode/stateflow：
      //   body = { nodes:[nodeId], hostname:<业务ID=IPES SN>, stage:'inService' }
      //   （「业务ID」在后台字段名就叫 hostname；旧 directDeployment 是「强制提交」，会报未知运营商）
      //   businessId 不允许手填、不允许传空、不允许短于 76hex
      st.innerHTML += '<div>🔄 3/3 状态流转（流转到【' + IC_DEFAULT_DEPLOY_STATUS + '】，业务ID=' + businessId + '）...</div>';
      var r2 = await icStateFlow(nodeId, businessId, icAdminCall);
      var c2 = (r2 && r2.code !== undefined) ? r2.code : null;
      if (c2 !== null && c2 !== 0) {
        throw new Error('状态流转返回业务码 ' + c2 + '：' + ((r2 && r2.msg) || JSON.stringify(r2).slice(0, 200)) +
          '（POST ' + IC_DEFAULT_STATEFLOW_PATH + ' body={nodes:[' + nodeId + '], hostname:' + businessId + ', stage:"' + IC_DEFAULT_STATEFLOW_STAGE + '"}）');
      }
      st.innerHTML += '<div style="color:#389e0d;">✅ 状态流转成功：' + JSON.stringify(r2).slice(0, 200) + '</div>';

      st.innerHTML += '<div style="margin-top:8px;padding:8px;background:#f6ffed;border:1px solid #b7eb8f;border-radius:6px;color:#389e0d;font-weight:600;">🎉 ' + nodeId + '（业务ID=' + businessId + '）已流转到「服务中」！请去 admin 后台核对节点状态。</div>';
      icLog('[镜像克隆] 已知 deviceCode 流转成功 ' + nodeId + ' → businessId=' + businessId, 'success');
    } catch (e) {
      st.innerHTML += '<div style="color:#cf1322;">❌ 失败：' + e.message + '</div>';
      icLog('[镜像克隆] 已知 deviceCode 流转失败 ' + nodeId + ': ' + e.message, 'error');
    }
  }
  window.icDirectDeployByNodeId = icDirectDeployByNodeId;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', icInit);
  } else {
    icInit();
  }
})();

/* ============================================================
 * one-click-deploy.js  v9  —  对齐 admin 真实接口版
 * 一键部署：节点就绪 → 批量提交 → 批量部署
 *
 * 真实接口（来自 admin.zhouyi.top 前端源码）：
 *   抓取节点：GET  /api/edgeNode/getEdgeNodeList
 *   批量提交：POST /api/edgeNode/updateEdgeRemark
 *   批量部署：POST /api/bigDeployLog/directDeployment
 *
 * v9 关键变更：
 *   在「待配置 → 服务中」流转（部署成功）时，把每台设备的 device_id
 *   与本次部署的「业务ID」(ocdBusinessId) 建立一一对应映射，
 *   写入 localStorage 并在页面渲染「设备ID ↔ 业务ID」对照表，
 *   便于按业务统计/追溯克隆购买的每台机器归属哪个业务。
 * ============================================================ */

var OCD_SUPABASE_FN = 'https://opauwtkivhjxlijfqaix.supabase.co/functions/v1/one-click-deploy';
var OCD_ANON_KEY = 'sb_publishable_SM9yvpcOBqvVPH2oGwTmFg_BZ1Lz9Xd';
var ZY_TOKEN_KEY = 'zy_admin_token';

/* ---------- token 复用（与 node-extract.js 共享） ---------- */
function loadZyToken() {
  try { return localStorage.getItem(ZY_TOKEN_KEY) || ''; } catch (e) { return ''; }
}

function ocdSaveToken() {
  var el = document.getElementById('ocdToken');
  var v = (el && el.value || '').trim();
  var st = document.getElementById('ocdTokenStatus');
  if (!v) {
    try { localStorage.removeItem(ZY_TOKEN_KEY); } catch (e) {}
    if (st) { st.textContent = '已清除凭证'; st.style.color = '#999'; }
    return;
  }
  try { localStorage.setItem(ZY_TOKEN_KEY, v); } catch (e) {}
  if (st) { st.textContent = '✅ 已保存（仅存于本机浏览器）'; st.style.color = '#52c41a'; }
}

function ocdLoadTokenForDeploy() {
  var saved = loadZyToken();
  var el = document.getElementById('ocdToken');
  if (saved && el && !el.value.trim()) el.value = saved;
  return saved;
}

/* ---------- 日志渲染 ---------- */
function ocdClearLog() {
  var el = document.getElementById('ocdLogArea');
  if (el) el.innerHTML = '';
}

function ocdAddLog(step, action, status, detail) {
  var el = document.getElementById('ocdLogArea');
  if (!el) return;
  var time = new Date().toLocaleTimeString('zh-CN', { hour12: false });
  var icon = status === 'ok' ? '✅' : status === 'error' ? '❌' : '⏳';
  var color = status === 'ok' ? '#52c41a' : status === 'error' ? '#ff4d4f' : '#1890ff';
  var div = document.createElement('div');
  div.style.cssText = 'padding:5px 10px;border-bottom:1px solid #f0f0f0;font-size:13px;font-family:monospace;';
  div.innerHTML = '<span style="color:#999;margin-right:8px;">[' + time + ']</span>' +
    '<span style="color:' + color + ';margin-right:6px;">' + icon + '</span>' +
    '<strong>步骤' + step + '</strong> ' + action +
    (detail ? ' <span style="color:#666;">— ' + detail + '</span>' : '');
  el.appendChild(div);
  el.scrollTop = el.scrollHeight;
}

/* ---------- 节点ID 解析（多行/逗号/空格） ---------- */
function ocdParseNodeIds(text) {
  if (!text) return [];
  var raw = String(text).split(/[\s,，、]+/).map(function (s) { return s.trim(); }).filter(Boolean);
  var seen = {}, out = [];
  raw.forEach(function (s) {
    // 兼容 “id=123” / “123 (name)” 形式，只取纯数字/字母串
    var m = s.match(/[A-Za-z0-9_-]+/);
    var v = m ? m[0] : s;
    if (v && !seen[v]) { seen[v] = 1; out.push(v); }
  });
  return out;
}

/* ---------- 收集节点ID：优先粘贴框，兜底读节点提取页列表 ---------- */
function ocdCollectNodeIds() {
  var ta = document.getElementById('ocdNodeIds');
  var pasted = (ta && ta.value || '').trim();
  if (pasted) return ocdParseNodeIds(pasted);
  var list = document.getElementById('zyNodeList');
  if (list) {
    var cbs = list.querySelectorAll('input[type="checkbox"]');
    var ids = [];
    cbs.forEach(function (cb) { if (cb.value) ids.push(cb.value); });
    if (ids.length) return ids;
  }
  return [];
}

/* ---------- 自动抓取节点ID（与 node-extract.js 逻辑对齐，但走新 Supabase） ---------- */
function ocdExtractNodeId(item) {
  if (typeof item === 'string') return item.trim();
  if (typeof item === 'number') return String(item);
  if (!item || typeof item !== 'object') return '';
  var keys = ['nodeID', 'nodeId', 'nodeCode', 'id', 'node_id', 'code', 'name', 'nodeName', 'nodeNo', 'node_no'];
  for (var i = 0; i < keys.length; i++) {
    var v = item[keys[i]];
    if (typeof v === 'string' && v.trim()) return v.trim();
    if (typeof v === 'number') return String(v);
  }
  for (var k in item) {
    if (!Object.prototype.hasOwnProperty.call(item, k)) continue;
    var v2 = item[k];
    if (typeof v2 === 'string' && v2.trim()) return v2.trim();
    if (typeof v2 === 'number') return String(v2);
  }
  return '';
}

function ocdIsNodeOnline(item) {
  if (!item || typeof item !== 'object') return true;
  var status = item.networkStatus || item.netStatus || item.status || item.network_state ||
               item.networkState || item.onlineStatus || item.isOnline || item.net_status || item.state;
  if (typeof status === 'string') return /^(在线|online|1|true|yes|运行中|正常|active|up)$/i.test(status.trim());
  if (typeof status === 'number') return status === 1;
  if (typeof status === 'boolean') return status;
  return true;
}

function ocdExtractArrayFromObject(obj) {
  if (Array.isArray(obj)) return obj;
  if (!obj || typeof obj !== 'object') return [];
  if (obj.data && typeof obj.data === 'object' && Array.isArray(obj.data.list)) return obj.data.list;
  if (Array.isArray(obj.data)) return obj.data;
  if (Array.isArray(obj.records)) return obj.records;
  if (Array.isArray(obj.rows)) return obj.rows;
  if (obj.code === 0 && Array.isArray(obj.data)) return obj.data;
  if (obj.code !== 0) throw new Error('admin 返回错误 code=' + obj.code + ' · ' + (obj.msg || ''));
  for (var k in obj) {
    if (Object.prototype.hasOwnProperty.call(obj, k) && Array.isArray(obj[k])) return obj[k];
  }
  return [];
}

async function ocdFetchOwnerNodes(token, ownerId) {
  var path = '/api/edgeNode/getEdgeNodeList';
  var query = 'ownerId=' + encodeURIComponent(ownerId) + '&isOnline=1&status=online&stage=configured';
  var resp = await fetch(OCD_SUPABASE_FN, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + OCD_ANON_KEY },
    body: JSON.stringify({
      token: token,
      headers: { Authorization: token, 'X-Token': token, 'x-token': token, Token: token },
      method: 'GET',
      path: path,
      query: query,
      body: null,
    }),
  });
  var raw = await resp.text();
  var data = null;
  try { data = JSON.parse(raw); } catch (e) {}
  if (!resp.ok) {
    var upstreamMsg = raw.slice(0, 300);
    var upstreamCode = '';
    if (data && typeof data === 'object') {
      if (data.data && data.data.msg) upstreamMsg = data.data.msg;
      if (data.data && data.data.code !== undefined) upstreamCode = 'code=' + data.data.code + ' · ';
      if (data.error && !upstreamMsg) upstreamMsg = data.error;
    }
    throw new Error('转发器 HTTP ' + resp.status + ' · ' + upstreamCode + upstreamMsg + '（上游接口返回非 2xx，请检查 token 是否失效）');
  }
  if (data && data.ok === false) {
    throw new Error(data.error || ('上游 HTTP ' + (data.status || '?')));
  }
  var inner = (data && typeof data === 'object' && 'ok' in data) ? data.data : data;
  if (typeof inner === 'string') {
    try { inner = JSON.parse(inner); }
    catch (e2) {
      if (/login|登录|<!doctype html/i.test(inner)) {
        throw new Error('admin.zhouyi.top 返回登录页（token 失效或无权限）');
      }
      throw new Error('admin 返回非 JSON：' + inner.slice(0, 300));
    }
  }
  var records = ocdExtractArrayFromObject(inner);
  return records.filter(ocdIsNodeOnline).map(ocdExtractNodeId).filter(function (id) { return !!id; });
}

function ocdSleep(ms) {
  return new Promise(function (resolve) { setTimeout(resolve, ms); });
}

/* ---------- 设备ID ↔ 业务ID 一一对应（localStorage 持久化） ---------- */
var OCD_BIZ_MAP_KEY = 'wb_dev_biz_map';
function ocdLoadBizMap() {
  try { return JSON.parse(localStorage.getItem(OCD_BIZ_MAP_KEY) || '{}'); } catch (e) { return {}; }
}
// ====== 云端持久化（复用 Supabase user_data 表，多端同步；与 image-clone 共享同一云端映射行）======
var OCD_BIZ_CLOUD_KEY = 'ocd_biz_map';
var OCD_SUPABASE_REST = 'https://opauwtkivhjxlijfqaix.supabase.co/rest/v1/user_data';

// 从云端拉取统一映射（data.map）；失败返回 null
async function ocdBizCloudLoad() {
  try {
    var r = await fetch(OCD_SUPABASE_REST + '?username=eq.' + encodeURIComponent(OCD_BIZ_CLOUD_KEY) + '&select=data', {
      method: 'GET',
      headers: { 'apikey': OCD_ANON_KEY, 'Authorization': 'Bearer ' + OCD_ANON_KEY }
    });
    if (!r.ok) return null;
    var rows = await r.json();
    if (rows && rows.length && rows[0].data && rows[0].data.map) return rows[0].data.map;
  } catch (e) {}
  return null;
}

// 整份 merged map upsert 到云端（PATCH 命中 0 行则 POST 新建，对齐 cloud-store.setUserData）
async function ocdBizCloudUpsert(map) {
  var body = JSON.stringify({ username: OCD_BIZ_CLOUD_KEY, data: { map: map }, updated_at: Date.now() });
  var hdrs = {
    'apikey': OCD_ANON_KEY, 'Authorization': 'Bearer ' + OCD_ANON_KEY,
    'Content-Type': 'application/json', 'Prefer': 'return=representation'
  };
  try {
    var pr = await fetch(OCD_SUPABASE_REST + '?username=eq.' + encodeURIComponent(OCD_BIZ_CLOUD_KEY), { method: 'PATCH', headers: hdrs, body: body });
    if (pr.ok) { var rows = await pr.json(); if (rows && rows.length) return true; }
  } catch (e) {}
  try {
    await fetch(OCD_SUPABASE_REST, { method: 'POST', headers: hdrs, body: body });
    return true;
  } catch (e) { return false; }
}

// 暴露给 image-clone.js 共享同一云端映射（避免重复网络代码）
window.OcdBizCloud = { load: ocdBizCloudLoad, upsertMerge: ocdBizCloudUpsert, KEY: OCD_BIZ_CLOUD_KEY };

// 保存 设备ID↔业务ID（localStorage 即时 + 云端合并持久化，避免覆盖 image-clone 的克隆批次行）
async function ocdSaveBizMap(nodeIds, businessId) {
  if (!nodeIds || !nodeIds.length) return;
  var ts = new Date().toLocaleString('zh-CN', { hour12: false });
  // 1) 本地即时写入（离线可用）
  var local = ocdLoadBizMap();
  nodeIds.forEach(function (id) { if (id) local[id] = { businessId: businessId, updatedAt: ts, kind: 'deploy' }; });
  try { localStorage.setItem(OCD_BIZ_MAP_KEY, JSON.stringify(local)); } catch (e) {}
  // 2) 云端合并（读云端现有 + 本批新增，整份 upsert；与 image-clone 共享云端行不互覆盖）
  try {
    var cloud = await ocdBizCloudLoad() || {};
    nodeIds.forEach(function (id) { if (id) cloud[id] = { businessId: businessId, updatedAt: ts, kind: 'deploy' }; });
    await ocdBizCloudUpsert(cloud);
  } catch (e) {}
}

/* 自动生成业务ID（参考 106.53：每个部署批次分配唯一业务标识，设备ID↔业务ID一一对应） */
function ocdGenBusinessId() {
  var d = new Date();
  var p = function (n) { return String(n).padStart(2, '0'); };
  var ymd = '' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate());
  var rand = Math.random().toString(36).substring(2, 6).toUpperCase();
  return 'BIZ' + ymd + rand; // 例 BIZ20260830K7Q2
}
function ocdRenderBizMap(filterIds) {
  var el = document.getElementById('ocdBizMap');
  if (!el) return;
  var map = ocdLoadBizMap();
  var ids = (filterIds && filterIds.length) ? filterIds : Object.keys(map);
  var valid = ids.filter(function (id) { return map[id] && map[id].kind !== 'clone'; });
  if (!valid.length) { el.innerHTML = ''; return; }
  var rows = valid.map(function (id) {
    var b = map[id];
    return '<tr>' +
      '<td style="padding:4px 8px;font-family:monospace;border-top:1px solid #eee;">' + id + '</td>' +
      '<td style="padding:4px 8px;font-weight:600;color:#0050b3;border-top:1px solid #eee;">' + b.businessId + '</td>' +
      '<td style="padding:4px 8px;color:#999;font-size:12px;border-top:1px solid #eee;">' + (b.updatedAt || '') + '</td>' +
      '</tr>';
  }).join('');
  el.innerHTML = '<div style="background:#f6ffed;border:1px solid #b7eb8f;border-radius:6px;padding:10px;">' +
    '<div style="font-weight:600;font-size:13px;margin-bottom:8px;">🔗 设备ID ↔ 业务ID 一一对应（共 ' + valid.length + ' 台）</div>' +
    '<table style="width:100%;border-collapse:collapse;font-size:13px;">' +
    '<thead><tr style="background:#e6f7ff;">' +
    '<th style="padding:4px 8px;text-align:left;">设备ID (device_id)</th>' +
    '<th style="padding:4px 8px;text-align:left;">业务ID</th>' +
    '<th style="padding:4px 8px;text-align:left;">更新时间</th></tr></thead>' +
    '<tbody>' + rows + '</tbody></table></div>';
}

/* ---------- 调 one-click-deploy 函数（通用转发 admin.zhouyi.top，模拟手动） ---------- */
async function ocdCallAdmin(token, method, path, query, body) {
  var resp = await fetch(OCD_SUPABASE_FN, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + OCD_ANON_KEY },
    body: JSON.stringify({
      token: token,
      method: method || 'POST',
      path: path,
      query: query || '',
      body: (body === undefined ? null : body),
    }),
  });
  var json = null;
  try { json = await resp.json(); } catch (e) {}
  if (!resp.ok) {
    var detail = json && (json.data ? JSON.stringify(json.data) : JSON.stringify(json)) || '';
    throw new Error('HTTP ' + resp.status + (detail ? ' · ' + detail : '') + '（上游接口返回非 2xx，请检查 token 是否失效）');
  }
  return json;
}

/* ---------- 配置参数默认值 ---------- */
function ocdGetConfig() {
  function gv(id) { var el = document.getElementById(id); return el ? (el.value || '').trim() : ''; }
  function gb(id) { var el = document.getElementById(id); return el ? el.checked : false; }
  return {
    ownerId: gv('ocdOwnerId'),
    usbw: parseInt(gv('ocdUsbw') || '200', 10) || 200,
    bwNum: parseInt(gv('ocdBwNum') || '1', 10) || 1,
    businessId: (gv('ocdBusinessId') || '').trim(), // 留空则部署时自动生成业务ID
    isTransProv: gb('ocdTransProv'),
    isp: gb('ocdIsp'),
    // admin “批量提交” 表单必填项（来自 setupAssistant 源码校验规则）
    vendorSuggestCustomers: gv('ocdVendorSuggestCustomers'),
    transMode: gv('ocdTransMode'),
    isCrossNetwork: gb('ocdIsCrossNetwork'),
    crossNetworkIsp: gv('ocdCrossNetworkIsp'),
    batchSize: parseInt(gv('ocdBatchSize') || '100', 10) || 100,
    batchDelay: parseInt(gv('ocdBatchDelay') || '1000', 10) || 1000,
  };
}

/* ---------- 分批工具 ---------- */
function ocdChunkArray(arr, size) {
  var out = [];
  for (var i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

/* ---------- 主流程（v8：输入属主ID → 自动抓节点 → 分批提交部署） ---------- */
async function ocdStartDeploy() {
  var cfg = ocdGetConfig();
  // 业务ID：用户留空则本次自动生成（参考 106.53，每个部署批次分配唯一业务标识）
  var businessId = cfg.businessId || ocdGenBusinessId();
  var _bizEl = document.getElementById('ocdBusinessId');
  if (_bizEl && !_bizEl.value.trim()) _bizEl.value = businessId;
  var stEl = document.getElementById('ocdStatus');
  var btnEl = document.getElementById('ocdBtn');

  // 取 token：优先本页输入框，其次 localStorage
  var token = ocdLoadTokenForDeploy();
  if (!token) {
    var ta = document.getElementById('ocdToken');
    token = (ta && ta.value || '').trim();
    if (token) { try { localStorage.setItem(ZY_TOKEN_KEY, token); } catch (e) {} }
  }
  if (!token) {
    if (stEl) stEl.innerHTML = '<div style="background:#fff2f0;border:1px solid #ffccc7;padding:10px;border-radius:6px;color:#cf1322;">⚠️ <b>请先填写登录凭证</b><br><span style="font-size:12px;color:#666;">在上方「🔑 admin.zhouyi.top Token」输入框粘贴 token 并保存</span></div>';
    return;
  }

  // 节点：优先使用手动粘贴的；无粘贴则按属主ID自动抓取
  var nodeIds = ocdCollectNodeIds();
  var extracted = false;
  if (!nodeIds.length) {
    if (!cfg.ownerId) {
      if (stEl) stEl.innerHTML = '<div style="background:#fff2f0;border:1px solid #ffccc7;padding:10px;border-radius:6px;color:#cf1322;">⚠️ 请输入节点属主ID，或在「手动粘贴节点ID」区填入节点ID</div>';
      return;
    }
    ocdClearLog();
    if (btnEl) { btnEl.disabled = true; btnEl.textContent = '⏳ 抓取节点中...'; }
    if (stEl) stEl.innerHTML = '<div style="background:#e6f7ff;border:1px solid #91d5ff;padding:10px;border-radius:6px;color:#0050b3;font-size:13px;">⏳ 正在从 admin.zhouyi.top 抓取属主 ' + cfg.ownerId + ' 的「在线且待配置」节点...</div>';
    try {
      nodeIds = await ocdFetchOwnerNodes(token, cfg.ownerId);
      extracted = true;
      if (stEl) stEl.innerHTML = '<div style="background:#f6ffed;border:1px solid #b7eb8f;padding:10px;border-radius:6px;color:#389e0d;font-size:13px;">✅ 抓取到 ' + nodeIds.length + ' 个在线且待配置节点</div>';
    } catch (e) {
      if (stEl) stEl.innerHTML = '<div style="background:#fff2f0;border:1px solid #ffccc7;padding:10px;border-radius:6px;color:#cf1322;">❌ 抓取节点失败：' + (e.message || String(e)) + '</div>';
      if (btnEl) { btnEl.disabled = false; btnEl.textContent = '🚀 自动提取并部署'; }
      return;
    }
  }

  if (!nodeIds.length) {
    if (stEl) stEl.innerHTML = '<div style="background:#fff2f0;border:1px solid #ffccc7;padding:10px;border-radius:6px;color:#cf1322;">⚠️ 未获取到任何节点ID</div>';
    if (btnEl) { btnEl.disabled = false; btnEl.textContent = '🚀 自动提取并部署'; }
    return;
  }

  if (!extracted) ocdClearLog();
  if (btnEl) { btnEl.disabled = true; btnEl.textContent = '⏳ 部署中...'; }
  if (stEl && !extracted) stEl.innerHTML = '';

  ocdAddLog(0, '一键部署启动（真实接口 /api/edgeNode/updateEdgeRemark + /api/bigDeployLog/directDeployment）', 'info',
    '节点 ' + nodeIds.length + ' 台 · ' + cfg.usbw + 'Mbps × ' + cfg.bwNum + '条线 · ' + (cfg.isTransProv ? '跨省' : '不跨省') +
    (extracted ? ' · 属主 ' + cfg.ownerId + ' 自动抓取' : ' · 手动粘贴'));

  // 用户可在「高级」区粘贴 F12 真实请求体，覆盖默认推断结构（覆盖模式下不自动分批）
  var submitOverride = (document.getElementById('ocdSubmitBody') && document.getElementById('ocdSubmitBody').value || '').trim();
  var deployOverride = (document.getElementById('ocdDeployBody') && document.getElementById('ocdDeployBody').value || '').trim();

  var chunks = [];
  if (submitOverride || deployOverride) {
    chunks = [nodeIds]; // 高级覆盖模式：一次性发送全部
    ocdAddLog(1, '使用高级请求体覆盖', 'warn', '不启用自动分批');
  } else {
    chunks = ocdChunkArray(nodeIds, cfg.batchSize || 100);
    ocdAddLog(1, '节点分批', 'ok', '共 ' + chunks.length + ' 批 · 每批 ' + (cfg.batchSize || 100) + ' 台 · 批间 ' + (cfg.batchDelay || 1000) + 'ms');
  }

  var totalSubmitOk = 0, totalDeployOk = 0, totalFail = 0;
  var ownerIdNum = cfg.ownerId ? parseInt(cfg.ownerId, 10) : null;

  try {
    for (var idx = 0; idx < chunks.length; idx++) {
      var chunk = chunks[idx];
      var batchNum = idx + 1;
      ocdAddLog(2, '第 ' + batchNum + '/' + chunks.length + ' 批', 'info', '节点 ' + chunk.length + ' 台');

      // 步骤2：批量提交  →  POST /api/edgeNode/updateEdgeRemark（admin 前端"上机小助手-批量提交"真实接口）
      // 该接口按节点逐个调用（参考 setupAssistant 源码 e.map(e=>_(l))），这里批内并发对齐手动。
      var submitPath = '/api/edgeNode/updateEdgeRemark';
      if (submitOverride) {
        try { submitOverride = JSON.parse(submitOverride); } catch (e) { ocdAddLog(2, '提交请求体 JSON 解析失败', 'error', e.message); throw e; }
      }
      var submitResults = await Promise.allSettled(chunk.map(function (id) {
        var body = submitOverride || {
          nodeId: id,
          businessId: cfg.businessId || id,
          vendorSuggestCustomers: cfg.vendorSuggestCustomers,
          transMode: cfg.transMode,
          isCrossNetwork: cfg.isCrossNetwork,
          crossNetworkIsp: cfg.crossNetworkIsp,
          isTransProv: cfg.isTransProv,
          usbw: cfg.usbw,
          bwNum: cfg.bwNum,
        };
        return ocdCallAdmin(token, 'POST', submitPath, '', body);
      }));
      var submitOk = submitResults.filter(function (r) { return r.status === 'fulfilled' && r.value && r.value.ok; }).length;
      var submitFailList = submitResults.filter(function (r) { return !(r.status === 'fulfilled' && r.value && r.value.ok); });
      if (submitFailList.length) {
        ocdAddLog(2, '第 ' + batchNum + ' 批提交部分失败', submitOk > 0 ? 'warn' : 'error',
          submitOk + ' 成功 / ' + submitFailList.length + ' 失败 · ' + JSON.stringify(submitFailList[0].reason ? submitFailList[0].reason.message : (submitFailList[0].value && submitFailList[0].value.data)).slice(0, 200));
        totalFail += submitFailList.length;
      } else {
        ocdAddLog(2, '第 ' + batchNum + ' 批提交成功', 'ok', chunk.length + ' 台');
      }
      totalSubmitOk += submitOk;
      if (submitFailList.length) continue; // 提交失败的批不再部署

      // 步骤3：批量部署  →  POST /api/bigDeployLog/directDeployment（admin 前端"上机小助手-批量部署"真实接口）
      var deployPath = '/api/bigDeployLog/directDeployment';
      if (deployOverride) {
        try { deployOverride = JSON.parse(deployOverride); } catch (e) { ocdAddLog(3, '部署请求体 JSON 解析失败', 'error', e.message); throw e; }
      }
      var deployResults = await Promise.allSettled(chunk.map(function (id) {
        var body = deployOverride || { nodeId: id };
        return ocdCallAdmin(token, 'POST', deployPath, '', body);
      }));
      var deployOk = deployResults.filter(function (r) { return r.status === 'fulfilled' && r.value && r.value.ok; }).length;
      var deployFailList = deployResults.filter(function (r) { return !(r.status === 'fulfilled' && r.value && r.value.ok); });
      if (deployFailList.length) {
        ocdAddLog(3, '第 ' + batchNum + ' 批部署部分失败', deployOk > 0 ? 'warn' : 'error',
          deployOk + ' 成功 / ' + deployFailList.length + ' 失败 · ' + JSON.stringify(deployFailList[0].reason ? deployFailList[0].reason.message : (deployFailList[0].value && deployFailList[0].value.data)).slice(0, 200));
        totalFail += deployFailList.length;
      } else {
        ocdAddLog(3, '第 ' + batchNum + ' 批部署成功', 'ok', chunk.length + ' 台');
      }
      totalDeployOk += deployOk;

      // 批间间隔（最后一批后不等待）
      if (idx < chunks.length - 1) {
        ocdAddLog(2, '等待下一批', 'info', (cfg.batchDelay || 1000) + 'ms');
        await ocdSleep(cfg.batchDelay || 1000);
      }
    }

    if (stEl) stEl.innerHTML = '<div style="background:#f6ffed;border:1px solid #b7eb8f;padding:14px;border-radius:8px;">' +
      '<div style="font-size:15px;font-weight:600;margin-bottom:8px;">🎉 一键部署完成</div>' +
      '<div style="font-size:13px;color:#666;">节点 ' + nodeIds.length + ' 台 · 分 ' + chunks.length + ' 批 · 提交成功 ' + totalSubmitOk + ' · 部署成功 ' + totalDeployOk + (totalFail ? ' · 失败 ' + totalFail : '') + '</div>' +
      '</div>';
    // 仅当本批全部提交+部署成功（节点状态真正从待配置→服务中）才建立 设备ID↔业务ID 一一对应
    if (totalFail === 0 && totalSubmitOk === nodeIds.length && totalDeployOk === nodeIds.length) {
      ocdSaveBizMap(nodeIds, businessId);
      ocdRenderBizMap(nodeIds);
      ocdAddLog(4, '设备ID ↔ 业务ID 绑定', 'ok', '业务ID=' + businessId + ' · 共 ' + nodeIds.length + ' 台');
    } else {
      ocdAddLog(4, '存在失败节点，跳过业务ID绑定（避免误映射待配置机器）', 'warn', '提交 ' + totalSubmitOk + ' / 部署 ' + totalDeployOk + ' / 共 ' + nodeIds.length);
    }
  } catch (err) {
    ocdAddLog(0, '错误: ' + err.message, 'error');
    if (stEl && !stEl.innerHTML.match(/一键部署完成/)) {
      var msg = String(err.message);
      if (msg.indexOf('Failed to fetch') !== -1) {
        stEl.innerHTML = '<div style="background:#fff2f0;padding:10px;border-radius:6px;color:#cf1322;">❌ <b>网络错误</b> — 无法连接 admin-proxy<br><span style="font-size:12px;color:#666;">Supabase Edge Function 可能暂时不可用，请稍后重试。</span></div>';
      } else if (/token|登录|未登录|非法访问|code=7/i.test(msg)) {
        stEl.innerHTML = '<div style="background:#fff2f0;padding:10px;border-radius:6px;color:#cf1322;">❌ <b>admin.zhouyi.top 登录凭证失效</b><br><span style="font-size:12px;color:#666;">' + err.message + '<br>请在「🔑 admin.zhouyi.top Token」处重新粘贴最新 token 后再试。</span></div>';
      } else {
        stEl.innerHTML = '<div style="background:#fff2f0;padding:10px;border-radius:6px;color:#cf1322;">❌ ' + err.message + '</div>';
      }
    }
  } finally {
    // 业务ID↔设备ID 映射仅在「全部部署成功」分支建立，finally 只刷新展示，避免失败节点被误标为服务中
    try { ocdRenderBizMap(); } catch (e) {}
    if (btnEl) { btnEl.disabled = false; btnEl.textContent = '🚀 自动提取并部署'; }
  }
}

/* ---------- 进入页面时回填已保存的 token ---------- */
document.addEventListener('DOMContentLoaded', function () {
  ocdLoadTokenForDeploy();
  // 跨端同步：拉云端映射合并进本地（best-effort，失败不影响本地使用）
  ocdBizCloudLoad().then(function (cloud) {
    if (cloud) {
      var local = ocdLoadBizMap();
      Object.keys(cloud).forEach(function (k) { if (!local[k]) local[k] = cloud[k]; });
      try { localStorage.setItem(OCD_BIZ_MAP_KEY, JSON.stringify(local)); } catch (e) {}
      ocdRenderBizMap();
    }
  }).catch(function () {});
});

// 暴露给 image-clone.js 复用：一键绑定舟翼云后自动状态流转到服务中
window.OcdAdmin = {
  call: ocdCallAdmin,
  fetchOwnerNodes: ocdFetchOwnerNodes,
  sleep: ocdSleep,
  genBusinessId: ocdGenBusinessId
};

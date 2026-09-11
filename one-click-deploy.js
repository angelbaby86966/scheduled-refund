/* ============================================================
 * one-click-deploy.js  v16  —  对齐 admin 真实接口 + 带宽写入校验版
 * 一键部署：节点就绪 → 批量提交 → 批量部署
 *
 * 真实接口（来自 admin.zhouyi.top 前端源码）：
 *   抓取节点：GET  /api/edgeNode/getEdgeNodeList
 *   批量提交：POST /api/edgeNode/updateEdgeNominalInfo   ← v16 纠正
 *   状态流转：POST /api/edgeNode/stateflow
 *   （/api/bigDeployLog/directDeployment 是后台「强制提交/再次提交」按钮，不是状态流转，仅兜底）
 *
 * v16 关键变更（用户 2026-09-11 点名解封）：
 *   ① 批量提交接口纠正：updateEdgeRemark → updateEdgeNominalInfo
 *      （image-clone.js 早在 r20 就查明真接口是 updateEdgeNominalInfo；
 *        updateEdgeRemark 对带宽/业务字段静默无效 —— 一键部署这条路一直是白提交的）
 *   ② 提交前若节点已是「服务中/交付中」，自动 stateflow 降级到「待配置」
 *      （后台规则：建设带宽只能在待配置阶段提交，否则返回 code:7 拒绝）
 *   ③ 提交后读回 nominalInfo.usbw 校验，不符则重试 3 次；确实不符则中止该台流转
 *      （code:0 ≠ 已落库，杜绝「带宽没写进去却流转成功」）
 *   ④ 请求体补齐 expectedBiz / ipScheduleType（与 image-clone.js 契约一致）
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

/* 自动生成业务ID：v18r13 改为真正的 IPES SN 76hex（38 字节随机 = 76 hex 字符），与黄金机业务ID 同格式同长度。
 * 旧 BIZ+日期+4位 短码会让 admin 后台 businessId 字段丢失长度信息，破坏与机器 ipes 容器 bin/ipes_sn 的对应关系。
 * 用 crypto.getRandomValues 保证与黄金机/已存在节点零冲突；fallback 用 Math.random。 */
function ocdGenBusinessId() {
  try {
    var bytes = new Uint8Array(38);
    (window.crypto || window.msCrypto).getRandomValues(bytes);
    var hex = '';
    for (var i = 0; i < bytes.length; i++) hex += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
    if (hex.length === 76) return hex;
  } catch (e) { /* fallback */ }
  var s = '';
  while (s.length < 76) s += Math.random().toString(16).slice(2);
  return s.slice(0, 76);
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
      // 【v16】多通道注入 token：读接口（findEdgeNode 等）在转发器只认 x-token 头，
      //   POST 多传这几个 header 无副作用（与 ocdFetchOwnerNodes 保持一致）。
      headers: { Authorization: token, 'X-Token': token, 'x-token': token, Token: token },
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

/* ---------- 节点状态读取 / 建设带宽提交（v16 新增，与 image-clone.js r29 同契约） ---------- */

// 提交建设带宽接口 + 状态流转接口（写死，来自 admin 前端 bundle 反查）
var OCD_NOMINAL_PATH = '/api/edgeNode/updateEdgeNominalInfo';
var OCD_STATEFLOW_PATH = '/api/edgeNode/stateflow';
var OCD_EXPECTED_BIZ = '自研Q2';
var OCD_IP_SCHEDULE_TYPE = 0;

// 从 ocdCallAdmin 的返回里取出 admin 响应体的内层 data
//   ocdCallAdmin 返回 { ok, data }；data = admin 响应体 { code, data, msg }
function ocdUnwrapAdmin(resp) {
  var d = resp && resp.data;
  if (d && d.data !== undefined) return d.data;
  return d || null;
}

// 读取单个节点（stage / nodeInfo）
async function ocdReadNode(token, nodeId) {
  var resp = await ocdCallAdmin(token, 'GET', '/api/edgeNode/findEdgeNode', 'nodeId=' + encodeURIComponent(nodeId), null);
  var inner = ocdUnwrapAdmin(resp);
  var code = resp && resp.data && resp.data.code;
  if (code !== undefined && code !== 0) {
    throw new Error('findEdgeNode 返回业务码 ' + code + '：' + ((resp.data && resp.data.msg) || ''));
  }
  return inner || {};
}

// 提交建设带宽（含：前置降级 + 提交 + 读回校验重试）
//   m = { nodeId, businessId }；cfg = ocdGetConfig()；say = function(msg, level)
//   返回 { ok, usbw, attempts, unverified }
//     ok=false        → 确实读到 usbw 不符（校验失败，调用方应中止该台流转）
//     unverified=true → 读回通道本身异常，属"无法校验"，放行但告警
async function ocdSubmitNominalVerified(token, m, cfg, say) {
  say = say || function () {};
  var want = Number(cfg.usbw);
  var attempts = 3, lastGot = null, mismatch = 0, verifyErr = 0, lastResp = null;

  for (var i = 1; i <= attempts; i++) {
    // ① 前置降级：服务中/交付中不允许改建设带宽 → 先 stateflow 回「待配置」
    try {
      var d0 = await ocdReadNode(token, m.nodeId);
      var st0 = d0 && d0.stage;
      if (st0 === 'inService' || st0 === 'waitAudit') {
        say('↺ 节点当前为「' + (st0 === 'inService' ? '服务中' : '交付中') + '」，先降级到「待配置」再改建设带宽', 'warn');
        await ocdCallAdmin(token, 'POST', OCD_STATEFLOW_PATH, '', {
          nodes: [m.nodeId], hostname: m.businessId || '', stage: 'configured'
        });
        await ocdSleep(1200);
      }
    } catch (e) { /* 查询/降级失败不阻断，按原流程继续提交 */ }

    // ② 提交建设带宽/业务（接口已纠正为 updateEdgeNominalInfo）
    lastResp = await ocdCallAdmin(token, 'POST', OCD_NOMINAL_PATH, '', {
      nodeId: m.nodeId,
      businessId: m.businessId,
      vendorSuggestCustomers: cfg.vendorSuggestCustomers,
      transMode: cfg.transMode,
      isCrossNetwork: cfg.isCrossNetwork,
      crossNetworkIsp: cfg.crossNetworkIsp,
      isTransProv: cfg.isTransProv,
      usbw: cfg.usbw,
      bwNum: cfg.bwNum,
      expectedBiz: OCD_EXPECTED_BIZ,
      ipScheduleType: OCD_IP_SCHEDULE_TYPE,
    });

    // ③ 读回校验：code:0 ≠ 已落库
    await ocdSleep(1500);
    try {
      var d1 = await ocdReadNode(token, m.nodeId);
      var ni = (d1 && d1.nodeInfo) || {};
      lastGot = ni.usbw;
      if (Number(ni.usbw) === want) {
        say('✅ 建设带宽已写入并校验通过：usbw=' + ni.usbw + '（第 ' + i + ' 次提交）', 'ok');
        return { ok: true, usbw: ni.usbw, attempts: i, resp: lastResp };
      }
      mismatch++;
      say('⚠️ 第 ' + i + '/' + attempts + ' 次提交后读回 usbw=' + ni.usbw + '（期望 ' + want + '）' +
        (i < attempts ? '，稍后重试…' : '，仍未生效'), 'warn');
    } catch (e) {
      verifyErr++;
      say('⚠️ 第 ' + i + '/' + attempts + ' 次提交后读回校验失败：' + (e.message || e) +
        (i < attempts ? '，稍后重试…' : ''), 'warn');
    }
    if (i < attempts) await ocdSleep(1500);
  }
  return { ok: (mismatch === 0), unverified: (mismatch === 0 && verifyErr > 0), usbw: lastGot, attempts: attempts, resp: lastResp };
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

  ocdAddLog(0, '一键部署启动（真实接口 /api/edgeNode/updateEdgeNominalInfo + /api/edgeNode/stateflow）', 'info',
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

      // 步骤2：批量提交  →  POST /api/edgeNode/updateEdgeNominalInfo
      //   【v16 接口纠正，用户 2026-09-11 点名解封】
      //   ⚠️ 旧代码用的是 /api/edgeNode/updateEdgeRemark（名称来自"上机小助手-批量提交"），
      //      但 image-clone.js 在 r20 已实测查明：真正写带宽/业务的是 updateEdgeNominalInfo；
      //      updateEdgeRemark 对本流程要写的字段静默无效 —— 一键部署的带宽提交一直是空转的。
      //   ✅ 现改为每台走 ocdSubmitNominalVerified：服务中/交付中自动先降级到「待配置」
      //      → 提交 → 读回 nominalInfo.usbw 校验（不符重试 3 次；确实不符则中止该台，不进流转）。
      //      批内并发，对齐手动操作。
      if (submitOverride) {
        try { submitOverride = JSON.parse(submitOverride); } catch (e) { ocdAddLog(2, '提交请求体 JSON 解析失败', 'error', e.message); throw e; }
      }
      var submitResults = await Promise.allSettled(chunk.map(function (id) {
        // 高级覆盖模式：完全按用户填的发（保持原能力，不做校验）
        if (submitOverride) {
          return ocdCallAdmin(token, 'POST', OCD_NOMINAL_PATH, '', submitOverride);
        }
        var m = { nodeId: id, businessId: cfg.businessId || id };
        return ocdSubmitNominalVerified(token, m, cfg, function (msg, lv) {
          ocdAddLog(2, '节点 ' + String(id).slice(0, 12) + '…', lv === 'warn' ? 'warn' : 'ok', msg);
        }).then(function (v) {
          if (!v.ok) {
            throw new Error('建设带宽读回校验失败：usbw=' + v.usbw + '（期望 ' + cfg.usbw + '），已中止该台流转');
          }
          if (v.unverified) {
            ocdAddLog(2, '节点 ' + String(id).slice(0, 12) + '…', 'warn', '读回校验通道异常，无法确认带宽是否落库（已放行）');
          }
          return v.resp; // 保持 r.value = { ok, data } 结构，下方判定逻辑不变
        });
      }));
      // 【v18r14】同样按 admin 业务码 data.code 判定，不只看 supabase 层 ok
      var submitOk = submitResults.filter(function (r) {
        if (!(r.status === 'fulfilled' && r.value && r.value.ok)) return false;
        var d = r.value.data;
        return !(d && d.code !== undefined && d.code !== 0);
      }).length;
      var submitFailList = submitResults.filter(function (r) {
        if (!(r.status === 'fulfilled' && r.value && r.value.ok)) return true;
        var d = r.value.data;
        return !!(d && d.code !== undefined && d.code !== 0);
      });
      if (submitFailList.length) {
        var sf = submitFailList[0];
        var sfDetail = '';
        try {
          sfDetail = sf.reason ? sf.reason.message
            : (sf.value && sf.value.data ? ('admin code=' + sf.value.data.code + ' ' + (sf.value.data.msg || '')) : JSON.stringify(sf.value));
        } catch (e2) { sfDetail = String(e2); }
        ocdAddLog(2, '第 ' + batchNum + ' 批提交部分失败', submitOk > 0 ? 'warn' : 'error',
          submitOk + ' 成功 / ' + submitFailList.length + ' 失败 · ' + String(sfDetail).slice(0, 200));
        totalFail += submitFailList.length;
      } else {
        ocdAddLog(2, '第 ' + batchNum + ' 批提交成功', 'ok', chunk.length + ' 台');
      }
      totalSubmitOk += submitOk;
      if (submitFailList.length) continue; // 提交失败的批不再部署

      // 步骤3：状态流转（待配置 → 服务中）
      // 【v18r28 接口纠正，用户 2026-09-11 点名解封】
      //   ⚠️ /api/bigDeployLog/directDeployment 不是状态流转！它在后台是「强制提交 / 再次提交」按钮，
      //      body 只有 { nodeId, isFormat }，内部会跑 FormatQiYIInstallCodeForEcache 生成爱奇艺安装码，
      //      节点没有「业务线运营商」时直接报「未知运营商」。
      //   ✅ 真状态流转 = POST /api/edgeNode/stateflow
      //      body = { nodes:[nodeId], hostname:<业务ID>, stage:'inService' }
      //      （后台「状态流转」弹窗把「业务ID」绑到 hostname 这个 key；stage: configured=待配置 / inService=服务中）
      //   与 image-clone.js 的 icStateFlow()（r27）保持同一契约。
      var deployPath = '/api/edgeNode/stateflow';
      if (deployOverride) {
        try { deployOverride = JSON.parse(deployOverride); } catch (e) { ocdAddLog(3, '部署请求体 JSON 解析失败', 'error', e.message); throw e; }
      }
      var deployResults = await Promise.allSettled(chunk.map(function (id) {
        // 业务ID：优先取顶部填写值 / clone biz map；没有则传空串（后台允许，实测 code:0 正常流转）
        var bid = cfg.businessId || (window.icLoadCloneBizMap && (function(){ var m = window.icLoadCloneBizMap()[id] || {}; return m.businessId || ''; })()) || '';
        var body = deployOverride || { nodes: [id], hostname: bid, stage: 'inService' };
        return ocdCallAdmin(token, 'POST', deployPath, '', body);
      }));
      // 【v18r14 关键修复】不能只看 supabase 层的 ok（那只代表 HTTP 通了）。
      // admin 业务码在 data.code 里：实测 directDeployment 不认 HMAC、token 失效时会返回
      // HTTP 200 + {"code":7,"msg":"未登录或非法访问"}，旧逻辑会谎报"部署成功"。
      var deployOk = deployResults.filter(function (r) {
        if (!(r.status === 'fulfilled' && r.value && r.value.ok)) return false;
        var d = r.value.data;
        return !(d && d.code !== undefined && d.code !== 0);
      }).length;
      var deployFailList = deployResults.filter(function (r) {
        if (!(r.status === 'fulfilled' && r.value && r.value.ok)) return true;
        var d = r.value.data;
        return !!(d && d.code !== undefined && d.code !== 0);
      });
      if (deployFailList.length) {
        var firstFail = deployFailList[0];
        var failDetail = '';
        try {
          failDetail = firstFail.reason ? firstFail.reason.message
            : (firstFail.value && firstFail.value.data
                ? ('admin code=' + firstFail.value.data.code + ' ' + (firstFail.value.data.msg || ''))
                : JSON.stringify(firstFail.value));
        } catch (e) { failDetail = String(e); }
        ocdAddLog(3, '第 ' + batchNum + ' 批部署部分失败', deployOk > 0 ? 'warn' : 'error',
          deployOk + ' 成功 / ' + deployFailList.length + ' 失败 · ' + String(failDetail).slice(0, 200));
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

/* ---------- 进入页面时回填已保存的 token + 一键绑定相关字段 ---------- */
document.addEventListener('DOMContentLoaded', function () {
  ocdLoadTokenForDeploy();
  // 一键绑定并流转所需的两个必填项（image-clone.js 里 icBindAndDeploy 会校验）：
  //   - 供应商建议客户 vendorSuggestCustomers
  //   - 传输模式 transMode
  // 这两个 input 在「一键部署」面板里，刷新后必须从 localStorage 回填，否则绿色按钮会一直弹 alert
  [
    { id: 'ocdVendorSuggestCustomers', key: 'wb_zyy_vendor_customers', type: 'text', ev: 'input' },
    { id: 'ocdTransMode',              key: 'wb_zyy_trans_mode',       type: 'text', ev: 'input' }
  ].forEach(function (f) {
    var el = document.getElementById(f.id);
    if (!el) return;
    try {
      var saved = localStorage.getItem(f.key);
      if (saved !== null && !(el.value || '').trim()) el.value = saved;
    } catch (e) {}
    el.addEventListener(f.ev, function () {
      try { localStorage.setItem(f.key, el.value); } catch (e) {}
    });
  });
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

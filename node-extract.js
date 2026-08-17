/* ============================================================
 * node-extract.js  v5
 * 节点ID提取工具（集成到「阿里云工作台」原有网页）
 *
 * v5 架构：浏览器 →  Supabase Edge Function (one-click-deploy 通用转发)  → admin.zhouyi.top
 * 原因：旧的 node-search 专用函数内部写死了 /smallNode/getEdgeNodeList，
 *      而该接口对你账号 (AuthorityId 21) 无 casbin 权限；
 *      one-click-deploy 函数是通用转发器（POST + token + method + path + query + body），
 *      可以按用户在「高级模式」里指定的任意 path/参数调 admin.zhouyi.top。
 *
 * 两种模式：
 *   1) 粘贴模式：从后台复制节点ID贴进来 → 格式化 → 全选复制
 *   2) 自动抓取：填入 token → 点按钮 → 通用 Edge Function 转发到 admin
 *      → 在 admin 资源池按属主ID查在线节点 → 返回所有节点ID → 全选复制
 *   3) 高级模式：默认已预填 /smallNode/getEdgeNodeList，但如果 admin 后台
 *      真实接口名不一致，可手动指定 method / path / query 覆盖（{ownerId} 占位）
 * ============================================================ */

var OCD_SUPABASE_FN = 'https://vgddxxgjcogxcpiycsej.supabase.co/functions/v1/one-click-deploy';
var OCD_ANON_KEY = 'sb_publishable_AqRbhxlzaDzPNR1nZTw-4A_c1VQ1Nch';
var ZY_TOKEN_KEY = 'zy_admin_token';
var ZY_ADV_KEY = 'zy_advanced';   // localStorage key 用于记住用户的「高级模式」覆盖

/* ---------- token 存取 ---------- */
function saveZyToken() {
  var el = document.getElementById('zyToken');
  var v = (el && el.value || '').trim();
  var status = document.getElementById('zyTokenStatus');
  if (!v) {
    localStorage.removeItem(ZY_TOKEN_KEY);
    if (status) status.textContent = '已清除凭证';
    if (status) status.style.color = '#999';
    return;
  }
  localStorage.setItem(ZY_TOKEN_KEY, v);
  if (status) { status.textContent = '✅ 已保存（仅存于本机浏览器）'; status.style.color = '#52c41a'; }
}

function loadZyToken() {
  try { return localStorage.getItem(ZY_TOKEN_KEY) || ''; } catch (e) { return ''; }
}

/* ---------- 解析粘贴的节点ID ---------- */
function parseNodeIds(text) {
  if (!text) return [];
  var parts = text.split(/[\s,;，；\n\r]+/);
  var set = {};
  var out = [];
  parts.forEach(function (p) {
    p = (p || '').trim();
    if (!p) return;
    if (!set[p]) { set[p] = true; out.push(p); }
  });
  return out;
}

function escapeHtmlText(text) {
  return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#039;');
}

/* ---------- 把 admin 返回的对象/字符串统一为节点ID ---------- */
function extractNodeId(item) {
  if (typeof item === 'string') return item.trim();
  if (typeof item === 'number') return String(item);
  if (!item || typeof item !== 'object') return '';
  // 常见字段（按后台资源池列表推测）
  var keys = ['nodeID', 'nodeId', 'nodeCode', 'id', 'node_id', 'code', 'name', 'nodeName', 'nodeNo', 'node_no'];
  for (var i = 0; i < keys.length; i++) {
    var v = item[keys[i]];
    if (typeof v === 'string' && v.trim()) return v.trim();
    if (typeof v === 'number') return String(v);
  }
  // 兜底：取第一个非空字符串/数字字段
  for (var k in item) {
    if (!Object.prototype.hasOwnProperty.call(item, k)) continue;
    var v2 = item[k];
    if (typeof v2 === 'string' && v2.trim()) return v2.trim();
    if (typeof v2 === 'number') return String(v2);
  }
  return '';
}

function isNodeOnline(item) {
  if (!item || typeof item !== 'object') return true; // 无法判断时保留
  var status = item.networkStatus || item.netStatus || item.status || item.network_state ||
               item.networkState || item.onlineStatus || item.isOnline || item.net_status || item.state;
  if (typeof status === 'string') {
    return /^(在线|online|1|true|yes|运行中|正常|active|up)$/i.test(status.trim());
  }
  if (typeof status === 'number') return status === 1;
  if (typeof status === 'boolean') return status;
  return true;
}

function normalizeNodeArray(arr) {
  if (!Array.isArray(arr)) return [];
  return arr.filter(isNodeOnline).map(extractNodeId).filter(function (id) { return !!id; });
}

/* ---------- 渲染结果列表 ---------- */
function renderZyNodes(ids, ownerLabel) {
  var wrap = document.getElementById('zyResultWrap');
  var list = document.getElementById('zyNodeList');
  var count = document.getElementById('zyCount');
  var ownerLbl = document.getElementById('zyOwnerLabel');
  if (!wrap || !list) return;
  list.innerHTML = '';
  if (!ids || !ids.length) {
    wrap.style.display = 'none';
    return;
  }
  var frag = document.createDocumentFragment();
  ids.forEach(function (raw, i) {
    var id = extractNodeId(raw);
    if (!id) return;
    var row = document.createElement('label');
    row.style.cssText = 'display:flex;align-items:center;gap:8px;padding:6px 8px;border-bottom:1px solid #f5f5f5;cursor:pointer;font-family:monospace;font-size:13px;';
    row.innerHTML =
      '<input type="checkbox" class="zy-node-cb" value="' + escapeHtmlText(id) + '" onchange="zyUpdateSelCount()" checked> ' +
      '<span>' + escapeHtmlText(id) + '</span>';
    frag.appendChild(row);
  });
  list.appendChild(frag);
  wrap.style.display = 'block';
  if (count) count.textContent = ids.length;
  if (ownerLbl) ownerLbl.textContent = ownerLabel || '-';
  zyUpdateSelCount();
}

function zyUpdateSelCount() {
  var cbs = document.querySelectorAll('.zy-node-cb');
  var checked = document.querySelectorAll('.zy-node-cb:checked');
  var el = document.getElementById('zySelectedCount');
  if (el) el.textContent = '已选 ' + checked.length + ' / ' + cbs.length + ' 个';
}

function zyToggleAll() {
  var master = document.getElementById('zySelectAll');
  var on = master ? master.checked : true;
  document.querySelectorAll('.zy-node-cb').forEach(function (cb) { cb.checked = on; });
  zyUpdateSelCount();
}

function zyCopySelected() {
  var checked = document.querySelectorAll('.zy-node-cb:checked');
  var ids = Array.prototype.map.call(checked, function (cb) { return cb.value; });
  if (!ids.length) { alert('请先勾选要复制的节点ID'); return; }
  var text = ids.join('\n');
  copyText(text);
  var st = document.getElementById('zySearchStatus');
  if (st) st.innerHTML = '✅ 已复制 <strong>' + ids.length + '</strong> 个节点ID 到剪贴板';
}

function copyText(text) {
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text);
      return;
    }
  } catch (e) {}
  var ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand('copy'); } catch (e) {}
  document.body.removeChild(ta);
}

/* ---------- 粘贴模式 ---------- */
function zyImportPaste() {
  var ta = document.getElementById('zyPaste');
  var text = ta ? ta.value : '';
  var ids = parseNodeIds(text);
  if (!ids.length) {
    var st = document.getElementById('zySearchStatus');
    if (st) st.innerHTML = '⚠️ 没有解析到节点ID，请检查粘贴内容';
    return;
  }
  renderZyNodes(ids, '粘贴导入');
  var st = document.getElementById('zySearchStatus');
  if (st) st.innerHTML = '✅ 已导入 <strong>' + ids.length + '</strong> 个节点ID（去重后）';
}

/* ---------- 缓存（会话内，避免重复等待慢接口） ---------- */
var ZY_CACHE_TTL = 5 * 60 * 1000;  // 5 分钟
function zyCacheKey(ownerId) { return 'zy_node_cache_' + ownerId; }
function zyGetCache(ownerId) {
  try {
    var raw = sessionStorage.getItem(zyCacheKey(ownerId));
    if (!raw) return null;
    var o = JSON.parse(raw);
    if (Date.now() - o.ts > ZY_CACHE_TTL) return null;
    return o.ids;
  } catch (e) { return null; }
}
function zySetCache(ownerId, ids) {
  try { sessionStorage.setItem(zyCacheKey(ownerId), JSON.stringify({ ts: Date.now(), ids: ids })); } catch (e) {}
}

/* ---------- 单个属主：经通用转发器抓取（v6：增强诊断 + 透传多 header） ---------- */
async function zyFetchOwner(token, ownerId, opts) {
  opts = opts || {};
  var method = (opts.method || 'GET').toUpperCase();
  var path   = opts.path || '/api/edgeNode/getEdgeNodeList';
  var queryTpl = opts.query || 'ownerId={ownerId}&isOnline=1';
  var query  = queryTpl.replace(/\{ownerId\}/g, encodeURIComponent(ownerId));

  // 同时尝试把 token 放到常见 header，兼容不同转发器/后台实现
  var upstreamHeaders = {};
  upstreamHeaders['Authorization'] = token;
  upstreamHeaders['X-Token'] = token;
  upstreamHeaders['x-token'] = token;
  upstreamHeaders['Token'] = token;

  var resp = await fetch(OCD_SUPABASE_FN, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + OCD_ANON_KEY },
    body: JSON.stringify({
      token: token,
      headers: upstreamHeaders,
      method: method,
      path: path,
      query: query,
      body: null,
    }),
    signal: opts.signal,
  });

  // 拿到响应后：HTTP 200 但 body 不是 JSON 也要识别（admin 鉴权失败时返回的是 HTML 登录页）
  var raw = await resp.text();
  var data = null;
  try { data = JSON.parse(raw); } catch (e) {}

  if (!resp.ok) {
    var snippet = raw ? ' · 响应片段: ' + raw.slice(0, 300) : '';
    throw new Error('转发器 HTTP ' + resp.status + snippet);
  }

  // one-click-deploy 通用转发器：成功 {ok:true,status,data}；失败 {ok:false,error}
  if (data && data.ok === false) {
    // 转发器上行失败（network/timeout/HTTP error）
    var detail = data.error || ('上游 HTTP ' + (data.status || '?'));
    var upstreamSnippet = data.data ? ' · 上游响应片段: ' + String(data.data).slice(0, 300) : '';
    throw new Error(detail + upstreamSnippet);
  }

  var records = [];
  if (data && typeof data === 'object' && 'ok' in data) {
    // ok:true 路径：data.data 可能是 JSON 字符串或对象
    var inner = data.data;
    if (typeof inner === 'string') {
      // 试解析；解析不了判定为「鉴权失效被重定向到登录页（HTML）」
      try { inner = JSON.parse(inner); }
      catch (e2) {
        var preview = inner.slice(0, 300);
        if (/login|登录|<!doctype html/i.test(inner)) {
          throw new Error('admin.zhouyi.top 返回了登录页（token 失效/无权限/路径错）。\n路径：' + method + ' ' + path + '?' + query + '\n响应片段：' + preview + '\n建议：① 重新登录 admin.zhouyi.top 后抓最新 token；② 检查「⚙ 高级」里的 path/query 是否和后台真实接口一致。');
        }
        throw new Error('admin 返回非 JSON。\n路径：' + method + ' ' + path + '?' + query + '\n片段：' + preview);
      }
    }
    records = extractArrayFromObject(inner);
  } else {
    // 罕见：直接裸 JSON（不是 one-click-deploy 的 {ok,...} 包装）—尝试提数
    records = extractArrayFromObject(data);
  }

  // 过滤「在线」并把对象统一为节点ID字符串
  return normalizeNodeArray(records);
}

function extractArrayFromObject(obj) {
  if (Array.isArray(obj)) return obj;
  if (!obj || typeof obj !== 'object') return [];
  // 兼容 {data:{list:[],total,...}}（admin.zhouyi.top 资源池列表）
  if (obj.data && typeof obj.data === 'object' && Array.isArray(obj.data.list)) return obj.data.list;
  if (Array.isArray(obj.data)) return obj.data;
  if (Array.isArray(obj.records)) return obj.records;
  if (Array.isArray(obj.rows)) return obj.rows;
  if (obj.code === 0 && Array.isArray(obj.data)) return obj.data;
  if (obj.code !== 0) throw new Error('admin 返回错误 code=' + obj.code + ' · ' + (obj.msg || ''));
  // 兜底：再尝试平铺对象
  for (var k in obj) {
    if (Object.prototype.hasOwnProperty.call(obj, k) && Array.isArray(obj[k])) return obj[k];
  }
  return [];
}

/* ---------- 高级模式：localStorage 序列化保存/读取 ---------- */
function loadAdvancedConfig() {
  try {
    var raw = localStorage.getItem(ZY_ADV_KEY);
    if (!raw) return null;
    var o = JSON.parse(raw);
    if (!o || typeof o !== 'object') return null;
    // 自动把旧默认错误路径升级到新真实路径
    if (o.path === '/smallNode/getEdgeNodeList') {
      o.path = '/api/edgeNode/getEdgeNodeList';
      try { localStorage.setItem(ZY_ADV_KEY, JSON.stringify(o)); } catch (e) {}
    }
    return o;
  } catch (e) { return null; }
}
function saveAdvancedConfig(cfg) {
  try { localStorage.setItem(ZY_ADV_KEY, JSON.stringify(cfg || {})); } catch (e) {}
}
function applyAdvancedToInputs() {
  var cfg = loadAdvancedConfig() || {};
  var setVal = function (id, v) { var el = document.getElementById(id); if (el && v != null) el.value = v; };
  setVal('zyApiMethod', cfg.method);
  setVal('zyApiPath',   cfg.path);
  setVal('zyApiQuery',  cfg.query);
  var hint = document.getElementById('zyAdvancedHint');
  if (hint) hint.textContent = cfg.method || cfg.path ? '（已记忆你的覆盖 · 仅本机）' : '';
}
function readAdvancedFromInputs() {
  return {
    method: (document.getElementById('zyApiMethod')  || {}).value || 'GET',
    path:   (document.getElementById('zyApiPath')    || {}).value || '/smallNode/getEdgeNodeList',
    query:  (document.getElementById('zyApiQuery')   || {}).value || 'ownerId={ownerId}&isOnline=1',
  };
}
function zySaveAdvanced() {
  var cfg = readAdvancedFromInputs();
  saveAdvancedConfig(cfg);
  var hint = document.getElementById('zyAdvancedHint');
  if (hint) { hint.textContent = '✅ 已记忆（仅本机）'; hint.style.color = '#52c41a'; }
}
function zyResetAdvanced() {
  try { localStorage.removeItem(ZY_ADV_KEY); } catch (e) {}
  var def = { method: 'GET', path: '/api/edgeNode/getEdgeNodeList', query: 'ownerId={ownerId}&isOnline=1' };
  var setVal = function (id, v) { var el = document.getElementById(id); if (el) el.value = v; };
  setVal('zyApiMethod', def.method);
  setVal('zyApiPath',   def.path);
  setVal('zyApiQuery',  def.query);
  var hint = document.getElementById('zyAdvancedHint');
  if (hint) { hint.textContent = '已还原默认'; hint.style.color = '#999'; }
}

/* ---------- 自动抓取（v5：通用转发 + 高级模式 + 短超时 + 自动重试 1 次） ---------- */
async function zySearchNodes() {
  var ownerEl = document.getElementById('zyOwnerId');
  var rawOwner = (ownerEl && ownerEl.value || '').trim();
  var st = document.getElementById('zySearchStatus');
  var btn = document.getElementById('zySearchBtn');

  // 抓取时若用户改了高级模式输入框，先保存记忆
  var advCfg = readAdvancedFromInputs();
  saveAdvancedConfig(advCfg);

  // 取 token
  var token = loadZyToken();
  if (!token) {
    var ta = document.getElementById('zyToken');
    token = (ta && ta.value || '').trim();
    if (token) saveZyToken();
  }
  if (!token) {
    var details = document.querySelector('#tab-node details');
    if (details) details.open = true;
    var ta2 = document.getElementById('zyToken');
    if (ta2) { ta2.focus(); ta2.style.borderColor = '#ff4d4f'; ta2.style.boxShadow = '0 0 0 2px rgba(255,77,79,0.2)'; }
    if (st) st.innerHTML = '<div style="background:#fff2f0;border:1px solid #ffccc7;padding:10px 12px;border-radius:6px;color:#cf1322;">⚠️ <b>请先填写登录凭证</b><br><span style="font-size:12px;color:#666;">展开上方「🔑 登录凭证」区域 → 粘贴 token → 点「💾 保存凭证」<br>获取方式：登录 admin.zhouyi.top → F12 → 网络(Network) → 随便点一个请求 → 找请求头 <b>x-token</b> 的值</span></div>';
    return;
  }

  // 支持多属主：逗号/空格/换行分隔
  var ownerIds = rawOwner.split(/[\s,;，；\n\r]+/).map(function (s) { return s.trim(); }).filter(Boolean);
  if (!ownerIds.length) {
    var ownerEl2 = document.getElementById('zyOwnerId');
    if (ownerEl2) { ownerEl2.focus(); ownerEl2.style.borderColor = '#ff4d4f'; }
    if (st) st.innerHTML = '<div style="background:#fff2f0;border:1px solid #ffccc7;padding:10px 12px;border-radius:6px;color:#cf1322;">⚠️ <b>请输入节点属主ID</b><br><span style="font-size:12px;color:#666;">支持一次填多个属主（逗号/空格/换行分隔），并行抓取更快</span></div>';
    return;
  }

  if (btn) { btn.disabled = true; btn.textContent = '⏳ 抓取中...'; }

  // 先查缓存（命中则跳过网络）
  var allIds = [];
  var fromCache = 0;
  var toFetch = [];
  ownerIds.forEach(function (oid) {
    var cached = zyGetCache(oid);
    if (cached) { allIds = allIds.concat(cached); fromCache += cached.length; }
    else { toFetch.push(oid); }
  });

  var noTimeoutEl = document.getElementById('zyNoTimeout');
  var noTimeout = noTimeoutEl ? noTimeoutEl.checked : true;
  if (st) st.innerHTML = '⏳ 并行抓取中：' + ownerIds.length + ' 个属主（' + (fromCache ? fromCache + ' 个命中缓存 · ' : '') + toFetch.length + ' 个需联网）…<br><small style="color:#999">当前 path: ' + (advCfg.path || '/api/edgeNode/getEdgeNodeList') + ' · ' + (noTimeout ? '已取消超时，耐心等' : '单请求超时 45 秒，自动重试 1 次') + '</small>';

  var errors = [];
  if (toFetch.length) {
    var controller = new AbortController();
    var timer = null;
    if (!noTimeout) {
      timer = setTimeout(function () { controller.abort(); }, 45000);
    }
    try {
      var results = await Promise.all(toFetch.map(function (oid) {
        // 单属主：失败自动重试 1 次（间隔 1.5s）
        function once() {
          return zyFetchOwner(token, oid, {
            method: advCfg.method, path: advCfg.path, query: advCfg.query,
            signal: controller.signal
          });
        }
        function success(ids) {
          zySetCache(oid, ids);
          return { oid: oid, ids: ids, ok: true };
        }
        function fail(err) {
          return { oid: oid, ids: [], ok: false, err: (err.message || String(err)) + '（已重试 1 次）' };
        }
        return once().then(success).catch(function (e1) {
          return new Promise(function (resolve) {
            setTimeout(function () {
              once().then(function (ids) { resolve(success(ids)); }).catch(function (e2) { resolve(fail(e2)); });
            }, 2500);
          });
        });
      }));
      results.forEach(function (r) {
        if (r.ok) { allIds = allIds.concat(r.ids); }
        else { errors.push(r.oid + '：' + r.err); }
      });
    } catch (e) {
      // 整体超时等（通常已被逐项 catch，这里是兜底）
      errors.push('全局异常：' + (e.message || String(e)));
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  // 去重
  var seen = {}, dedup = [];
  allIds.forEach(function (id) { if (!seen[id]) { seen[id] = true; dedup.push(id); } });

  if (dedup.length) {
    var ownerLabel = ownerIds.length === 1 ? ownerIds[0] : (ownerIds.length + ' 个属主');
    renderZyNodes(dedup, ownerLabel);
    var msg = '✅ 抓取到 <strong>' + dedup.length + '</strong> 个在线节点（' + ownerLabel + '）';
    if (errors.length) msg += '<br><span style="color:#fa8c16;">⚠️ ' + errors.length + ' 个属主失败：' + errors.join('；') + '</span>';
    if (st) st.innerHTML = msg;
  } else {
    var failMsg;
    if (errors.length) {
      failMsg = '❌ 抓取失败（已重试 1 次）：' + errors.join('；');
      failMsg += '<br><small style="color:#666;">💡 排查：<b>①</b> 在 admin.zhouyi.top 后台按 F12 抓「资源池列表」的请求 URL/参数，填到上方「⚙ 高级」区即可切换到正确的接口；<b>②</b> 检查 token 是否过期。</small>';
    } else {
      failMsg = '❌ 未抓取到任何节点（该属主可能无在线节点或权限不足）';
    }
    if (st) st.innerHTML = failMsg;
  }

  if (btn) { btn.disabled = false; btn.textContent = '🔍 自动抓取节点ID'; }
}

/* ---------- 测试连接：快速探测 admin 是否通 / token 是否有效 ---------- */
async function zyTestConnection() {
  var st = document.getElementById('zySearchStatus');
  var token = loadZyToken();
  if (!token) {
    var ta = document.getElementById('zyToken');
    token = (ta && ta.value || '').trim();
    if (token) saveZyToken();
  }
  if (!token) {
    if (st) st.innerHTML = '<div style="background:#fff2f0;border:1px solid #ffccc7;padding:10px 12px;border-radius:6px;color:#cf1322;">⚠️ 请先填写并保存 admin.zhouyi.top 的登录凭证</div>';
    return;
  }
  if (st) st.innerHTML = '⏳ 正在测试连接…';
  try {
    var advCfg = readAdvancedFromInputs();
    saveAdvancedConfig(advCfg);
    var upstreamHeaders = { Authorization: token, 'X-Token': token, 'x-token': token, Token: token };
    var resp = await fetch(OCD_SUPABASE_FN, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + OCD_ANON_KEY },
      body: JSON.stringify({ token: token, headers: upstreamHeaders, method: advCfg.method, path: advCfg.path, query: advCfg.query.replace(/\{ownerId\}/g, '0'), body: null }),
    });
    var raw = await resp.text();
    var data = null;
    try { data = JSON.parse(raw); } catch (e) {}
    var status = (data && data.status) || '?';
    var upstreamRaw = (data && data.data) || raw;
    var preview = String(upstreamRaw).slice(0, 500);
    var isLoginPage = /login|登录|<!doctype html/i.test(preview);
    var isJson = false, parsed = null;
    try { parsed = JSON.parse(upstreamRaw); isJson = true; } catch (e) {}

    var html = '<div style="background:#f6ffed;border:1px solid #b7eb8f;padding:10px 12px;border-radius:6px;color:#389e0d;">✅ 转发器正常，上游 HTTP ' + status + '</div>';
    if (isLoginPage) {
      html = '<div style="background:#fff2f0;border:1px solid #ffccc7;padding:10px 12px;border-radius:6px;color:#cf1322;">❌ 上游返回了登录页（token 失效或无权限）<br><small style="color:#666;">路径：' + advCfg.method + ' ' + advCfg.path + '?' + advCfg.query.replace(/\{ownerId\}/g, '0') + '</small></div>';
    } else if (isJson) {
      html = '<div style="background:#f6ffed;border:1px solid #b7eb8f;padding:10px 12px;border-radius:6px;color:#389e0d;">✅ 上游返回 JSON（code=' + (parsed.code != null ? parsed.code : '无') + '）<br><small style="color:#666;">路径：' + advCfg.method + ' ' + advCfg.path + '?' + advCfg.query.replace(/\{ownerId\}/g, '0') + '</small></div>';
    }
    html += '<details style="margin-top:8px;font-size:12px;color:#666;"><summary>查看原始响应前 500 字</summary><pre style="background:#f5f5f5;padding:8px;border-radius:4px;overflow:auto;max-height:200px;white-space:pre-wrap;word-break:break-all;margin-top:6px;">' + escapeHtmlText(preview) + '</pre></details>';
    if (st) st.innerHTML = html;
  } catch (e) {
    if (st) st.innerHTML = '<div style="background:#fff2f0;border:1px solid #ffccc7;padding:10px 12px;border-radius:6px;color:#cf1322;">❌ 测试连接失败：' + escapeHtmlText(e.message || String(e)) + '</div>';
  }
}

function zyClearResults() {
  var ta = document.getElementById('zyPaste');
  if (ta) ta.value = '';
  renderZyNodes([], '-');
  var st = document.getElementById('zySearchStatus');
  if (st) st.innerHTML = '';
}

/* 进入该标签页时回填已保存的 token + 高级模式 */
document.addEventListener('DOMContentLoaded', function () {
  var saved = loadZyToken();
  var ta = document.getElementById('zyToken');
  if (saved && ta) { ta.value = saved; }
  var tok = document.getElementById('zyToken');
  if (tok) tok.addEventListener('input', function() { this.style.borderColor = ''; this.style.boxShadow = ''; });
  var own = document.getElementById('zyOwnerId');
  if (own) own.addEventListener('input', function() { this.style.borderColor = ''; });

  // 高级模式：把上次保存的覆盖回填到输入框
  applyAdvancedToInputs();
  // 监听高级模式 details 打开/输入：每次修改实时回写 localStorage（这样切换 tab 也不丢）
  var advIds = ['zyApiMethod', 'zyApiPath', 'zyApiQuery'];
  advIds.forEach(function (id) {
    var el = document.getElementById(id);
    if (el) el.addEventListener('input', function () {
      saveAdvancedConfig(readAdvancedFromInputs());
      var h = document.getElementById('zyAdvancedHint');
      if (h) { h.textContent = '已自动记忆（仅本机）'; h.style.color = '#52c41a'; }
    });
  });
});

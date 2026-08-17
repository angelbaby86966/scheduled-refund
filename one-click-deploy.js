/* ============================================================
 * one-click-deploy.js  v4  —  “模拟手动”版
 * 一键部署：节点就绪 → 批量提交 → 批量部署
 *
 * v4 关键变更（解决“权限不足”）：
 *   自动流程原本走 Edge Function 内部写死的 /smallNode/xxx 接口，
 *   你的账号(AuthorityId 21)没有该 casbin 权限 → 报“权限不足”。
 *   而你在网页「手动部署」走的是 /deploy/deploy 系列（你有权限）。
 *   所以 v4 改为“模拟手动”：
 *     ① 节点ID 不再自动抓取（/smallNode/getEdgeNodeList 同样无权限），
 *        改由你从「节点ID提取」页复制粘贴（手动也是这么干的）；
 *     ② 提交/部署改走 /deploy/deploy（手动路径），经通用 admin-proxy 转发；
 *     ③ 支持在「高级」区粘贴 F12 抓到的真实请求体，100% 对齐手动参数。
 * ============================================================ */

var OCD_SUPABASE_FN = 'https://vgddxxgjcogxcpiycsej.supabase.co/functions/v1/one-click-deploy';
var OCD_ANON_KEY = 'sb_publishable_AqRbhxlzaDzPNR1nZTw-4A_c1VQ1Nch';
var ZY_TOKEN_KEY = 'zy_admin_token';

/* ---------- token 复用（与 node-extract.js 共享） ---------- */
function loadZyToken() {
  try { return localStorage.getItem(ZY_TOKEN_KEY) || ''; } catch (e) { return ''; }
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
  if (!resp.ok) throw new Error('HTTP ' + resp.status);
  return await resp.json();
}

/* ---------- 配置参数默认值 ---------- */
function ocdGetConfig() {
  return {
    ownerId: (document.getElementById('ocdOwnerId') && document.getElementById('ocdOwnerId').value || '').trim(),
    usbw: parseInt(document.getElementById('ocdUsbw') && document.getElementById('ocdUsbw').value || '200', 10) || 200,
    bwNum: parseInt(document.getElementById('ocdBwNum') && document.getElementById('ocdBwNum').value || '1', 10) || 1,
    businessId: parseInt(document.getElementById('ocdBusinessId') && document.getElementById('ocdBusinessId').value || '41', 10) || 41,
    isTransProv: document.getElementById('ocdTransProv') ? document.getElementById('ocdTransProv').checked : true,
    isp: document.getElementById('ocdIsp') ? document.getElementById('ocdIsp').checked : false,
    batchSize: parseInt(document.getElementById('ocdBatchSize') && document.getElementById('ocdBatchSize').value || '100', 10) || 100,
    batchDelay: parseInt(document.getElementById('ocdBatchDelay') && document.getElementById('ocdBatchDelay').value || '100', 10) || 100,
  };
}

/* ---------- 主流程（v4：模拟手动，走 /deploy/deploy） ---------- */
async function ocdStartDeploy() {
  var cfg = ocdGetConfig();
  var stEl = document.getElementById('ocdStatus');
  var btnEl = document.getElementById('ocdBtn');

  // 取 token
  var token = loadZyToken();
  if (!token) {
    var ta = document.getElementById('zyToken');
    token = (ta && ta.value || '').trim();
    if (token) { try { localStorage.setItem(ZY_TOKEN_KEY, token); } catch (e) {} }
  }
  if (!token) {
    var details = document.querySelectorAll('#tab-node details');
    if (details.length) details[0].open = true;
    if (stEl) stEl.innerHTML = '<div style="background:#fff2f0;border:1px solid #ffccc7;padding:10px;border-radius:6px;color:#cf1322;">⚠️ <b>请先填写登录凭证</b><br><span style="font-size:12px;color:#666;">在「📋 节点ID提取」标签页的凭证区粘贴 token 并保存</span></div>';
    return;
  }

  // 节点
  var nodeIds = ocdCollectNodeIds();
  if (!nodeIds.length) {
    if (stEl) stEl.innerHTML = '<div style="background:#fff2f0;border:1px solid #ffccc7;padding:10px;border-radius:6px;color:#cf1322;">⚠️ 请先提供节点ID<br><span style="font-size:12px;color:#666;">在下方「节点ID」框粘贴（从「节点ID提取」页复制），或使用 F12 在 admin.zhouyi.top 手动部署时复制的请求体</span></div>';
    return;
  }

  ocdClearLog();
  if (btnEl) { btnEl.disabled = true; btnEl.textContent = '⏳ 部署中...'; }
  if (stEl) stEl.innerHTML = '';

  ocdAddLog(0, '一键部署启动（模拟手动 /deploy/deploy）', 'info',
    '节点 ' + nodeIds.length + ' 台 · ' + cfg.usbw + 'Mbps × ' + cfg.bwNum + '条线 · ' + (cfg.isTransProv ? '跨省' : '不跨省'));

  if (stEl) stEl.innerHTML = '<div style="background:#e6f7ff;border:1px solid #91d5ff;padding:10px;border-radius:6px;color:#0050b3;font-size:13px;">⏳ 正在模拟手动调用 /deploy/deploy（经 admin-proxy 转发，绕开 CORS）...</div>';

  try {
    // 步骤1：节点就绪
    ocdAddLog(1, '节点就绪', 'ok', nodeIds.length + ' 台已载入');

    // 用户可在「高级」区粘贴 F12 真实请求体，覆盖默认推断结构
    var submitOverride = (document.getElementById('ocdSubmitBody') && document.getElementById('ocdSubmitBody').value || '').trim();
    var deployOverride = (document.getElementById('ocdDeployBody') && document.getElementById('ocdDeployBody').value || '').trim();

    // 步骤2：批量提交
    var submitBody;
    if (submitOverride) {
      try { submitBody = JSON.parse(submitOverride); }
      catch (e) { ocdAddLog(2, '提交请求体 JSON 解析失败', 'error', e.message); throw e; }
    } else {
      // 默认推断结构（GVA deploy 表常见字段）。如与手动不符，请用「高级」粘贴真实 body
      submitBody = {
        ownerId: cfg.ownerId ? parseInt(cfg.ownerId, 10) : null,
        nodeIds: nodeIds,
        usbw: cfg.usbw,
        bwNum: cfg.bwNum,
        businessId: cfg.businessId,
        isTransProv: cfg.isTransProv,
        isp: cfg.isp,
        batchSize: cfg.batchSize,
        batchDelay: cfg.batchDelay,
      };
    }
    ocdAddLog(2, '批量提交（POST /deploy/deploy）', 'info', '节点 ' + nodeIds.length + ' 台' + (submitOverride ? ' · 使用粘贴的真实请求体' : ''));
    var r2 = await ocdCallAdmin(token, 'POST', '/deploy/deploy', '', submitBody);
    if (!r2.ok) {
      ocdAddLog(2, '批量提交失败', 'error', 'HTTP ' + r2.status + ' · ' + JSON.stringify(r2.data).slice(0, 200));
      throw new Error('批量提交失败：' + (r2.data && (r2.data.msg || r2.data.error) || r2.status));
    }
    ocdAddLog(2, '批量提交成功', 'ok', JSON.stringify(r2.data).slice(0, 200));

    // 步骤3：批量部署
    var deployBody;
    if (deployOverride) {
      try { deployBody = JSON.parse(deployOverride); }
      catch (e) { ocdAddLog(3, '部署请求体 JSON 解析失败', 'error', e.message); throw e; }
    } else {
      deployBody = {
        nodeIds: nodeIds,
        ownerId: cfg.ownerId ? parseInt(cfg.ownerId, 10) : null,
        usbw: cfg.usbw,
        bwNum: cfg.bwNum,
        businessId: cfg.businessId,
        isTransProv: cfg.isTransProv,
        isp: cfg.isp,
      };
    }
    ocdAddLog(3, '批量部署（POST /deploy/deploy）', 'info', deployOverride ? '使用粘贴的真实请求体' : '默认推断结构');
    var r3 = await ocdCallAdmin(token, 'POST', '/deploy/deploy', '', deployBody);
    if (!r3.ok) {
      ocdAddLog(3, '批量部署失败', 'error', 'HTTP ' + r3.status + ' · ' + JSON.stringify(r3.data).slice(0, 200));
      throw new Error('批量部署失败：' + (r3.data && (r3.data.msg || r3.data.error) || r3.status));
    }
    ocdAddLog(3, '批量部署成功', 'ok', JSON.stringify(r3.data).slice(0, 200));

    if (stEl) stEl.innerHTML = '<div style="background:#f6ffed;border:1px solid #b7eb8f;padding:14px;border-radius:8px;">' +
      '<div style="font-size:15px;font-weight:600;margin-bottom:8px;">🎉 一键部署完成（模拟手动）</div>' +
      '<div style="font-size:13px;color:#666;">节点 ' + nodeIds.length + ' 台 · 提交/部署均走 /deploy/deploy（你有权限的路径）</div>' +
      '</div>';
  } catch (err) {
    ocdAddLog(0, '错误: ' + err.message, 'error');
    if (stEl && !stEl.innerHTML.match(/一键部署完成/)) {
      if (String(err.message).indexOf('Failed to fetch') !== -1) {
        stEl.innerHTML = '<div style="background:#fff2f0;padding:10px;border-radius:6px;color:#cf1322;">❌ <b>网络错误</b> — 无法连接 admin-proxy<br><span style="font-size:12px;color:#666;">Supabase Edge Function 可能暂时不可用，请稍后重试。</span></div>';
      } else {
        stEl.innerHTML = '<div style="background:#fff2f0;padding:10px;border-radius:6px;color:#cf1322;">❌ ' + err.message + '</div>';
      }
    }
  } finally {
    if (btnEl) { btnEl.disabled = false; btnEl.textContent = '🚀 开始一键部署'; }
  }
}

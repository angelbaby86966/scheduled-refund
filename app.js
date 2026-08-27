/**
 * 阿里云云主机批量管理工作台 - 前端逻辑 v3.5
 * 纯前端版本：直接调用阿里云 API，无需后端服务器
 * 支持管理员/普通用户角色管理 + 多账号数据隔离
 */
console.log('%c[app.js] v44 已加载 - 退订失败回退:控制台按钮+ProductCode探测工具', 'background:#3b82f6;color:white;padding:4px 8px;font-weight:bold;border-radius:4px;');
console.log('[app.js] 加载时间:', new Date().toISOString(), 'WB_SUPABASE_FUNCTIONS:', window.WB_SUPABASE_FUNCTIONS);

// ====== 用户命名空间（多账号数据隔离） ======
function getUserPrefix() {
  try {
    if (currentUser && currentUser.user) return 'wb_' + currentUser.user + '_';
  } catch(e) {}
  return 'wb_default_';
}

// ====== 登录检查 v2（双重存储保险） ======
(function() {
  var KEY = 'wb_logged_in_v2';
  var loggedIn = false;
  try {
    if (sessionStorage.getItem(KEY)) { loggedIn = true; }
    else if (localStorage.getItem(KEY)) {
      try { sessionStorage.setItem(KEY, localStorage.getItem(KEY)); } catch(e) {}
      loggedIn = true;
    }
  } catch(e) {}
  if (!loggedIn) {
    window.location.replace('login.html');
  }
})();

// ====== 当前用户信息 ======
var currentUser = null;
(function() {
  try {
    var key = 'wb_logged_in_v2';
    var raw = sessionStorage.getItem(key) || localStorage.getItem(key);
    if (raw) { currentUser = JSON.parse(raw); }
  } catch(e) {}
})();

// ====== 用户管理（管理员权限） ======
// 用户数据现在从云端 Supabase 读取，localStorage 作为缓存
var USERS_KEY = 'wb_users_cache';

function getUserDB() {
  try {
    var db = localStorage.getItem(USERS_KEY);
    if (db) return JSON.parse(db);
  } catch(e) {}
  return { admin: 'zhangruiyao', users: {} };
}

function saveUserDB(db) {
  try { localStorage.setItem(USERS_KEY, JSON.stringify(db)); return true; }
  catch(e) { return false; }
}

function isAdmin() {
  return currentUser && currentUser.role === 'admin';
}

function showUserManager() {
  if (!isAdmin()) return;
  document.getElementById('userMgrModal').style.display = 'flex';
  renderUserList();
}

function hideUserManager() {
  document.getElementById('userMgrModal').style.display = 'none';
}

function renderUserList() {
  var container = document.getElementById('userListContainer');
  container.innerHTML = '<div style="color:#999;text-align:center;padding:12px;">☁️ 正在从云端加载...</div>';

  // 从云端刷新用户数据
  if (window.CloudStore) {
    CloudStore.getAllUsers(true).then(function(db) {
      saveUserDB(db);
      renderUserListFromDB(db);
    }).catch(function(err) {
      // 云端失败，用本地缓存
      var db = getUserDB();
      renderUserListFromDB(db);
      container.innerHTML = '<div style="color:#faad14;text-align:center;padding:4px;font-size:12px;">⚠️ 云端加载失败，显示本地缓存</div>' + container.innerHTML;
    });
  } else {
    renderUserListFromDB(getUserDB());
  }
}

function renderUserListFromDB(db) {
  var container = document.getElementById('userListContainer');
  var users = db.users || {};
  var keys = Object.keys(users);

  if (keys.length === 0) {
    container.innerHTML = '<div style="color:#999;text-align:center;padding:12px;">暂无普通用户</div>';
    return;
  }

  var html = '<table style="width:100%;font-size:13px;border-collapse:collapse;">' +
    '<tr style="border-bottom:1px solid #eee;"><th style="text-align:left;padding:6px;">用户名</th><th style="text-align:left;padding:6px;">创建时间</th><th style="text-align:center;padding:6px;">操作</th></tr>';

  for (var i = 0; i < keys.length; i++) {
    var u = users[keys[i]];
    var time = u.createdAt ? new Date(u.createdAt).toLocaleDateString('zh-CN') : '-';
    html += '<tr style="border-bottom:1px solid #f0f0f0;">' +
      '<td style="padding:8px 6px;">' + escapeHtmlText(keys[i]) + '</td>' +
      '<td style="padding:8px 6px;color:#999;">' + time + '</td>' +
      '<td style="padding:8px 6px;text-align:center;">' +
        '<button onclick="deleteUser(\'' + escapeHtmlText(keys[i]) + '\')" style="color:#ff4d4f;border:none;background:none;cursor:pointer;font-size:12px;" ' +
        (keys[i] === 'xiaoshi' ? 'disabled title="默认用户不可删除" style="color:#ccc;"' : '') + '>删除</button>' +
      '</td></tr>';
  }
  html += '</table>';
  container.innerHTML = html;
}

function escapeHtmlText(text) {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#039;');
}

function addUser() {
  var nameEl = document.getElementById('newUserName');
  var passEl = document.getElementById('newUserPass');
  var msgEl = document.getElementById('addUserMsg');
  var username = (nameEl.value || '').trim();
  var password = (passEl.value || '').trim();

  if (!username || !password) {
    msgEl.innerHTML = '<span style="color:#ff4d4f;">用户名和密码不能为空</span>';
    return;
  }
  if (!/^[a-zA-Z0-9_]+$/.test(username)) {
    msgEl.innerHTML = '<span style="color:#ff4d4f;">用户名只能包含英文、数字和下划线</span>';
    return;
  }
  if (username === 'zhangruiyao') {
    msgEl.innerHTML = '<span style="color:#ff4d4f;">不能使用管理员用户名</span>';
    return;
  }

  msgEl.innerHTML = '<span style="color:#1890ff;">☁️ 正在写入云端...</span>';

  // 从云端检查并写入
  CloudStore.getAllUsers(true).then(function(db) {
    if (db.users && db.users[username]) {
      msgEl.innerHTML = '<span style="color:#ff4d4f;">用户 "' + escapeHtmlText(username) + '" 已存在</span>';
      return Promise.reject('exists');
    }
    return CloudStore.addUser(username, password, currentUser.user);
  }).then(function() {
    msgEl.innerHTML = '<span style="color:#52c41a;">✅ 用户 "' + escapeHtmlText(username) + '" 新增成功（已同步云端）</span>';
    nameEl.value = '';
    passEl.value = '';
    renderUserList();
  }).catch(function(err) {
    if (err === 'exists') return;
    var text = err.message || String(err);
    var friendly = text;
    if (/duplicate key|23505|app_users_pkey/i.test(text)) {
      friendly = '用户名「' + escapeHtmlText(username) + '」已存在，或用户表自增ID序列冲突。' +
        '若用户名未重复，请去 Supabase 控制台执行：SELECT setval(\'app_users_id_seq\', (SELECT MAX(id) FROM app_users));';
    }
    msgEl.innerHTML = '<span style="color:#ff4d4f;">❌ 添加失败: ' + friendly + '</span>';
  });
}

function deleteUser(username) {
  if (username === 'xiaoshi') {
    alert('xiaoshi 是默认用户，不可删除');
    return;
  }
  if (username === currentUser.user) {
    alert('不能删除自己');
    return;
  }
  if (!confirm('确定删除用户 "' + username + '"？删除后该用户将无法登录。')) return;

  // 从云端删除
  if (window.CloudStore) {
    CloudStore.deleteUser(username).then(function() {
      renderUserList();
    }).catch(function(err) {
      alert('删除失败: ' + (err.message || err));
    });
  } else {
    var db = getUserDB();
    if (db.users) delete db.users[username];
    saveUserDB(db);
    renderUserList();
  }
}

function exportUserDB() {
  var resultEl = document.getElementById('exportResult');
  resultEl.innerHTML = '<span style="color:#1890ff">☁️ 正在从云端加载...</span>';
  if (!window.CloudStore) {
    resultEl.innerHTML = '<span style="color:#ff4d4f">云端模块未加载</span>';
    return;
  }
  CloudStore.getAllUsers().then(function(db) {
    saveUserDB(db);
    try {
      var jsonStr = JSON.stringify(db, null, 2);
      // 复制到剪贴板
      var textarea = document.createElement('textarea');
      textarea.value = jsonStr;
      textarea.style.position = 'fixed';
      textarea.style.left = '-9999px';
      document.body.appendChild(textarea);
      textarea.select();
      var success = document.execCommand('copy');
      document.body.removeChild(textarea);

      if (success) {
        resultEl.innerHTML = '<span style="color:#52c41a">✅ 已复制用户数据库到剪贴板（云端数据）</span>';
      } else {
        prompt('请复制以下用户数据库 JSON：', jsonStr);
        resultEl.innerHTML = '<span style="color:#1890ff">已弹出复制窗口</span>';
      }
    } catch(e) {
      resultEl.innerHTML = '<span style="color:#ff4d4f">❌ 导出失败: ' + e.message + '</span>';
    }
  }).catch(function(err) {
    resultEl.innerHTML = '<span style="color:#ff4d4f">❌ 加载失败: ' + (err.message || err) + '</span>';
  });
}

function updateUserBadge() {
  var badge = document.getElementById('userBadge');
  if (!badge) return;
  var roleLabel = isAdmin() ? '👑 管理员' : '👤 普通用户';
  var roleColor = isAdmin() ? '#f59e0b' : '#1677ff';
  badge.innerHTML = '<span style="padding:4px 10px;border-radius:12px;font-size:12px;font-weight:600;background:' + roleColor + ';color:#fff;">' + roleLabel + ': ' + currentUser.user + '</span>';
}

function updateAdminUI() {
  var btn = document.getElementById('userMgrBtn');
  if (btn && isAdmin()) {
    btn.style.display = 'inline-block';
  }
}

// 全局错误捕获
window.onerror = function(msg, url, line) {
  console.error('[JS ERROR]', msg, 'at', url, 'line', line);
  var container = document.getElementById('logArea');
  if (container) {
    var entry = document.createElement('div');
    entry.className = 'log-entry log-error';
    entry.textContent = '[' + new Date().toLocaleTimeString('zh-CN') + '] ❌ JS错误: ' + msg + ' (行' + line + ')';
    container.appendChild(entry);
    container.scrollTop = container.scrollHeight;
  }
};

window.addEventListener('unhandledrejection', function(event) {
  console.error('[UNHANDLED REJECTION]', event.reason);
  var container = document.getElementById('logArea');
  if (container) {
    var entry = document.createElement('div');
    entry.className = 'log-entry log-error';
    var errMsg = event.reason ? (event.reason.message || String(event.reason)) : '未知错误';
    entry.textContent = '[' + new Date().toLocaleTimeString('zh-CN') + '] ❌ 异步错误: ' + errMsg;
    container.appendChild(entry);
    container.scrollTop = container.scrollHeight;
  }
});

// ====== 状态 ======
var state = {
  hasCredentials: false,
  regionData: {},
  selectedRegions: new Set(),
  selectedInstances: new Map(),
  allTemplates: [],
  regionCommands: {},
  refundItems: [],          // 非全额退订搜索结果
  refundSelected: new Set(), // 已勾选的实例 ID
  scheduleTimerId: null,     // 前端定时退订 setTimeout ID
};

var REGION_INFO = {
  'cn-hangzhou':  '杭州',
  'cn-beijing':   '北京',
  'cn-shanghai':  '上海',
  'cn-shenzhen':  '深圳',
  'cn-chengdu':   '成都',
  'cn-guangzhou': '广州',
  'cn-heyuan':    '河源',
  'cn-wuhan-lr':  '武汉',
  'cn-qingdao':   '青岛',
};

var REGION_COLORS = {
  'cn-hangzhou':  '#1677ff',
  'cn-beijing':   '#ef4444',
  'cn-shanghai':  '#f59e0b',
  'cn-shenzhen':  '#10b981',
  'cn-chengdu':   '#f97316',
  'cn-guangzhou': '#8b5cf6',
  'cn-heyuan':    '#06b6d4',
  'cn-wuhan-lr':  '#ec4899',
  'cn-qingdao':   '#84cc16',
};

// 超时设置的 fetch 封装（用于直接调用阿里云 API 的防超时）
function safeApiCall(promiseFn, timeoutMs) {
  var tm = timeoutMs || 300000;
  return new Promise(function(resolve, reject) {
    var timer = setTimeout(function() { reject(new Error('请求超时')); }, tm);
    promiseFn().then(function(v) { clearTimeout(timer); resolve(v); })
              .catch(function(e) { clearTimeout(timer); reject(e); });
  });
}

// 带超时的 fetch（AbortController），单个请求不会无限挂起
async function fetchWithTimeout(url, options, timeoutMs) {
  timeoutMs = timeoutMs || 60000;
  var controller = new AbortController();
  var timer = setTimeout(function() {
    try { controller.abort(); } catch(e) {}
  }, timeoutMs);
  try {
    return await fetch(url, Object.assign({}, options, { signal: controller.signal }));
  } finally {
    clearTimeout(timer);
  }
}

// ====== 日志 ======
function log(msg, level) {
  level = level || 'info';
  var area = document.getElementById('logArea');
  var time = new Date().toLocaleTimeString('zh-CN');
  area.innerHTML += '<div class="log-entry log-' + level + '">[' + time + '] ' + msg + '</div>';
  area.scrollTop = area.scrollHeight;
}

function clearLogs() {
  document.getElementById('logArea').innerHTML = '<div class="log-entry log-info">日志已清空。</div>';
}

// ====== 凭证管理 ======
function renderCredentialProfiles() {
  var list = document.getElementById('credProfileList');
  var cur = document.getElementById('credCurrentValue');
  var hint = document.getElementById('credCurrentHint');
  var bar = document.getElementById('credCurrentBar');
  if (!list) return;

  var profiles = AliyunClient.listProfiles();
  var active = AliyunClient.getActiveProfile();

  if (active) {
    cur.textContent = '🎯 ' + active.name + ' · ' + active.ak_id_hint;
    hint.textContent = '(' + profiles.length + ' 个凭证)';
    bar.classList.add('active');
  } else {
    cur.textContent = '未选择';
    hint.textContent = '(' + profiles.length + ' 个凭证)';
    bar.classList.remove('active');
  }

  if (!profiles.length) {
    list.innerHTML = '<div class="cred-profile-empty">尚未保存任何凭证 · 下方填表保存第一条</div>';
    return;
  }
  function esc(s) {
    return String(s).replace(/[<>&"]/g, function(c) { return { '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]; });
  }
  list.innerHTML = profiles.map(function(p) {
    var radio = p.active ? '✓' : '○';
    var safeName = esc(p.name);
    return ''
      + '<div class="cred-profile-item' + (p.active ? ' active' : '') + '" data-name="' + safeName + '">'
      + '  <div class="cred-profile-radio">' + radio + '</div>'
      + '  <div class="cred-profile-name">'
      + '    <div class="cred-profile-name-text">' + safeName + '</div>'
      + '    <div class="cred-profile-meta">'
      + '      <span class="cred-profile-ak">' + p.ak_id_hint + '</span>'
      + (p.note ? '      <span>' + esc(p.note) + '</span>' : '')
      + '    </div>'
      + '  </div>'
      + '  <div class="cred-profile-actions">'
      + (p.active
          ? '    <button class="btn-use" disabled style="opacity:0.55;cursor:default;">使用中</button>'
          : '    <button class="btn-use" data-action="use" data-name="' + safeName + '">使用</button>')
      + '    <button class="btn-delete" data-action="delete" data-name="' + safeName + '">删除</button>'
      + '  </div>'
      + '</div>';
  }).join('');

  Array.prototype.forEach.call(list.querySelectorAll('button[data-action]'), function(btn) {
    btn.addEventListener('click', function(e) {
      e.stopPropagation();
      var action = btn.getAttribute('data-action');
      var name = btn.getAttribute('data-name');
      if (action === 'use') useCredentialProfile(name);
      else if (action === 'delete') deleteCredentialProfile(name);
    });
  });
  Array.prototype.forEach.call(list.querySelectorAll('.cred-profile-item'), function(row) {
    row.addEventListener('click', function() {
      var name = row.getAttribute('data-name');
      var active = AliyunClient.getActiveProfile();
      if (active && active.name === name) return;
      useCredentialProfile(name);
    });
  });
}

function showCredentialDialog() {
  if (window.AliyunClient && AliyunClient.pullProfilesFromCloud) {
    Promise.resolve(AliyunClient.pullProfilesFromCloud()).then(function() {
      renderCredentialProfiles();
    }).catch(function() { renderCredentialProfiles(); });
  } else {
    renderCredentialProfiles();
  }

  var akInput = document.getElementById('accessKeyId');
  var skInput = document.getElementById('accessKeySecret');
  var nameInput = document.getElementById('credProfileName');
  if (akInput) { akInput.value = ''; akInput.placeholder = '输入 AccessKey ID'; }
  if (skInput) skInput.value = '';
  if (nameInput) { nameInput.value = ''; }

  document.getElementById('credentialModal').style.display = 'flex';
}

function hideCredentialDialog() {
  document.getElementById('credentialModal').style.display = 'none';
}

async function saveCredentials() {
  var nameInput = document.getElementById('credProfileName');
  var name = (nameInput && nameInput.value || '').trim() || '默认';
  var ak = (document.getElementById('accessKeyId').value || '').trim();
  var sk = (document.getElementById('accessKeySecret').value || '').trim();

  // 没填 AK/SK 但填了名字 → 视为「切换到现有凭证」
  if (!ak && !sk) {
    var profiles = AliyunClient.listProfiles();
    var matched = profiles.find(function(p) { return p.name === name; });
    if (matched) {
      await useCredentialProfile(name);
      hideCredentialDialog();
      return;
    }
    alert('请填写完整的 AccessKey ID 和 Secret；或者填入一个已存在的凭证名称来切换。');
    return;
  }
  if (!ak || !sk) { alert('请填写完整的 AccessKey ID 和 Secret'); return; }

  try {
    await AliyunClient.saveProfile({
      name: name,
      ak_id: ak,
      ak_secret: sk,
      setActive: true
    });
  } catch (e) {
    alert('保存失败：' + e.message);
    return;
  }

  state.hasCredentials = true;
  updateCredentialBar();
  hideCredentialDialog();
  document.getElementById('accessKeyId').value = '';
  document.getElementById('accessKeySecret').value = '';
  if (nameInput) nameInput.value = '';

  log('✅ 凭证「' + name + '」已保存并切换为当前凭证', 'success');

  // 🔍 自动检测 BSS 权限
  try {
    log('🔍 正在检测 AK 的 BSS 权限...', 'info');
    var permCheck = await AliyunClient.checkBssPermission();
    if (permCheck.ok && permCheck.hasBssAccess) {
      log('✅ AliyunBSSFullAccess 权限正常，退订功能可用', 'success');
    } else {
      log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
      log('⚠️ 未检测到 AliyunBSSFullAccess 权限！', 'warn');
      log('   ' + (permCheck.error || '权限不足'), 'warn');
      log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
      var ramUrl = 'https://ram.console.aliyun.com/users/';
      var opened = window.open(ramUrl, '_blank');
      log('👉 已自动打开 RAM 控制台，请为当前子账号添加 AliyunBSSFullAccess 权限：', 'info');
      log('   操作步骤：找到对应 RAM 用户 → 添加权限 → 搜索 AliyunBSSFullAccess → 勾选确定', 'info');
      if (!opened) {
        log('⚠️ 浏览器阻止了弹窗，请手动打开：' + ramUrl, 'warn');
      }
    }
  } catch (e) {
    log('⚠️ 权限检测失败: ' + e.message, 'warn');
  }

  // 刷新所有地域
  await refreshAllRegions();
}

async function useCredentialProfile(name) {
  try {
    await AliyunClient.useProfile(name);
    state.hasCredentials = true;
    updateCredentialBar();
    renderCredentialProfiles();
    log('🔁 已切换凭证到「' + name + '」', 'info');
    await refreshAllRegions();
  } catch (e) {
    alert('切换失败：' + e.message);
  }
}

async function deleteCredentialProfile(name) {
  if (!confirm('确定删除凭证「' + name + '」？删除后无法恢复。')) return;
  try {
    await AliyunClient.deleteProfile(name);
    var profiles = AliyunClient.listProfiles();
    if (!profiles.length) {
      state.hasCredentials = false;
    }
    updateCredentialBar();
    renderCredentialProfiles();
    log('🗑️ 已删除凭证「' + name + '」', 'warn');
  } catch (e) {
    alert('删除失败：' + e.message);
  }
}

function updateCredentialBar() {
  var bar = document.getElementById('credStatus');
  if (!bar) return;
  if (state.hasCredentials) {
    var info = AliyunClient.getCredentialsInfo();
    var active = AliyunClient.getActiveProfile();
    var nameLabel = active ? '「' + active.name + '」' : '';
    var akHint = info.accessKeyId ? (' · ' + info.accessKeyId.substring(0, 6) + '...') : '';
    var count = info.profileCount ? ' · 共 ' + info.profileCount + ' 个' : '';
    bar.innerHTML = '🟢 ' + currentUser.user + nameLabel + akHint + count;
    bar.style.color = '#52c41a';
  } else {
    bar.innerHTML = '🔴 未配置凭证';
    bar.style.color = '#ff4d4f';
  }
}

// ====== 退出登录 ======
function logout() {
  AliyunClient.clearCredentials();
  if (window.CloudStore) CloudStore.clearCache();
  try { sessionStorage.removeItem('wb_logged_in_v2'); } catch(e) {}
  try { sessionStorage.removeItem('wb_logged_in'); } catch(e) {}
  try { localStorage.removeItem('wb_logged_in_v2'); } catch(e) {}
  window.location.replace('login.html');
}

// ====== 地域概览 ======
async function refreshAllRegions() {
  if (!state.hasCredentials) {
    log('⚠️ 请先设置凭证', 'warn');
    return;
  }

  try {
    log('🌍 正在加载地域概览...', 'info');
    var regionIds = Object.keys(REGION_INFO);
    var results = await Promise.all(regionIds.map(function(rid) {
      return AliyunClient.listInstances(rid, { pageSize: 1 }).then(function(r) {
        return { regionId: rid, name: REGION_INFO[rid], totalCount: r.TotalCount || 0, error: null };
      }).catch(function(err) {
        return { regionId: rid, name: REGION_INFO[rid], totalCount: 0, error: err.message };
      });
    }));

    results.forEach(function(r) {
      state.regionData[r.regionId] = { name: r.name, totalCount: r.totalCount, error: r.error, instances: [] };
    });

    renderRegionCards();
    log('✅ 地域概览加载完成', 'success');
  } catch (err) {
    log('❌ 加载地域概览失败: ' + err.message, 'error');
  }
}

function renderRegionCards() {
  var container = document.getElementById('regionCards');
  var regionIds = Object.keys(REGION_INFO);

  container.innerHTML = regionIds.map(function(rid) {
    var rd = state.regionData[rid] || { name: REGION_INFO[rid], totalCount: 0, error: null };
    var isSelected = state.selectedRegions.has(rid);
    var cardClass = isSelected ? 'region-card selected' : 'region-card';

    if (rd.error) {
      return '<div class="' + cardClass + '" onclick="toggleRegion(\'' + rid + '\')">' +
        '<div class="region-check"></div>' +
        '<div class="region-name">' + rd.name + '</div>' +
        '<div class="region-error">⚠ ' + (rd.error || '').substring(0, 30) + '</div>' +
        '</div>';
    }
    return '<div class="' + cardClass + '" onclick="toggleRegion(\'' + rid + '\')">' +
      '<div class="region-check"></div>' +
      '<div class="region-name">' + rd.name + '</div>' +
      '<div class="region-count">共 <strong>' + rd.totalCount + '</strong> 台</div>' +
      '</div>';
  }).join('');

  document.getElementById('regionSummary').style.display = 'block';
  document.getElementById('selectedRegionCount').textContent = state.selectedRegions.size;
  updateSelectAllBtn();
  updateBatchUnsubBtn();
}

function toggleRegion(regionId) {
  if (!state.regionData[regionId]) return;

  if (state.selectedRegions.has(regionId)) {
    state.selectedRegions.delete(regionId);
    var toRemove = [];
    for (var _i = 0, _entries = state.selectedInstances.entries();;) {
      var _n = _entries.next(); if (_n.done) break;
      var _kv = _n.value;
      if (_kv[1].regionId === regionId) toRemove.push(_kv[0]);
    }
    toRemove.forEach(function(id) { state.selectedInstances.delete(id); });
  } else {
    state.selectedRegions.add(regionId);
  }
  renderRegionCards();

  if (state.selectedRegions.size > 0) {
    loadAllSelectedRegionInstances();
  } else {
    state.selectedInstances.clear();
    renderInstances();
    updateSelectedList();
  }
}

function selectAllRegions() {
  Object.keys(REGION_INFO).forEach(function(rid) {
    if (state.regionData[rid] && !state.regionData[rid].error) {
      state.selectedRegions.add(rid);
    }
  });
  renderRegionCards();
  loadAllSelectedRegionInstances();
}

function deselectAllRegions() {
  state.selectedRegions.clear();
  state.selectedInstances.clear();
  renderRegionCards();
  renderInstances();
  updateSelectedList();
}

function updateSelectAllBtn() {
  var btn = document.getElementById('regionSelectAllBtn');
  var total = Object.keys(REGION_INFO).length;
  if (state.selectedRegions.size === total) {
    btn.textContent = '取消全选';
    btn.onclick = deselectAllRegions;
  } else {
    btn.textContent = '全选地域';
    btn.onclick = selectAllRegions;
  }
}

// ====== 实例加载 ======
async function loadAllSelectedRegionInstances() {
  if (state.selectedRegions.size === 0) return;

  log('🔄 加载实例...', 'info');
  var regionIds = Array.from(state.selectedRegions);

  var results = await Promise.all(regionIds.map(function(rid) {
    return AliyunClient.listInstances(rid, { pageSize: 100 }).then(function(data) {
      state.regionData[rid].instances = data.Instances || [];
      log('  ' + REGION_INFO[rid] + ': ' + (data.Instances ? data.Instances.length : 0) + ' 台', 'info');
    }).catch(function(err) {
      log('  ' + REGION_INFO[rid] + ': 加载失败 - ' + err.message, 'error');
      state.regionData[rid].instances = [];
    });
  }));

  renderInstances();
  log('✅ 实例加载完成', 'success');
  loadAllRegionTemplatesSilent();
}

async function loadAllRegionTemplatesSilent() {
  var regionIds = Object.keys(REGION_INFO);
  try {
    var results = await Promise.all(regionIds.map(function(rid) {
      return AliyunClient.listFirewallTemplates(rid).then(function(data) {
        return { regionId: rid, success: true, templates: data.FirewallTemplates || [] };
      }).catch(function(err) {
        return { regionId: rid, success: false, templates: [], error: err.message };
      });
    }));

    var nameMap = {};
    results.forEach(function(r) {
      if (!r.success) return;
      r.templates.forEach(function(t) {
        if (!nameMap[t.Name]) nameMap[t.Name] = { name: t.Name, description: t.Description, regionTemplates: {} };
        nameMap[t.Name].regionTemplates[r.regionId] = t.FirewallTemplateId;
      });
    });
    state.allTemplates = Object.values(nameMap);
    updateStep2TemplateName();
  } catch (err) { /* 静默 */ }
}

function renderInstances() {
  var container = document.getElementById('instanceList');
  var allInstances = [];

  var _sids = Array.from(state.selectedRegions);
  for (var i = 0; i < _sids.length; i++) {
    var rid = _sids[i];
    var rd = state.regionData[rid];
    if (!rd || !rd.instances) continue;
    for (var j = 0; j < rd.instances.length; j++) {
      var inst = rd.instances[j];
      allInstances.push({
        InstanceId: inst.InstanceId,
        InstanceName: inst.InstanceName,
        Status: inst.Status,
        BusinessStatus: inst.BusinessStatus,
        PublicIpAddress: inst.PublicIpAddress,
        InnerIpAddress: inst.InnerIpAddress,
        ResourceSpec: inst.ResourceSpec,
        _regionId: rid,
        _regionName: REGION_INFO[rid]
      });
    }
  }

  if (state.selectedRegions.size === 0) {
    container.innerHTML = '<div class="empty-state">请在「地域概览」中选择地域以加载实例</div>';
    document.getElementById('instanceCount').textContent = '先选择地域';
    return;
  }

  if (allInstances.length === 0) {
    container.innerHTML = '<div class="empty-state">所选地域暂无实例</div>';
    document.getElementById('instanceCount').textContent = '共 0 台';
    return;
  }

  document.getElementById('instanceCount').textContent = '共 ' + allInstances.length + ' 台（' + state.selectedRegions.size + ' 个地域）';

  container.innerHTML = allInstances.map(function(inst) {
    var isChecked = state.selectedInstances.has(inst.InstanceId);
    var status = inst.Status || 'Unknown';
    var statusClass = 'other', statusText = status;
    if (status === 'Running') { statusClass = 'running'; statusText = '运行中'; }
    else if (status === 'Stopped') { statusClass = 'stopped'; statusText = '已停止'; }
    else if (status === 'Pending') statusText = '准备中';
    else if (status === 'Starting') statusText = '启动中';
    else if (status === 'Stopping') statusText = '停止中';

    var bizStatus = inst.BusinessStatus === 'Expired' ? 'expired' : '';
    var expClass = bizStatus || statusClass;

    return '<div class="instance-item" onclick="toggleInstance(\'' + inst.InstanceId + '\',\'' + inst._regionId + '\',\'' + inst._regionName + '\', this)" data-id="' + inst.InstanceId + '">' +
      '<input type="checkbox" ' + (isChecked ? 'checked' : '') + ' id="cb-' + inst.InstanceId + '" onclick="event.stopPropagation(); toggleInstanceCheck(\'' + inst.InstanceId + '\',\'' + inst._regionId + '\',\'' + inst._regionName + '\')" />' +
      '<div class="instance-info">' +
        '<div class="instance-name"><span class="instance-tag">' + inst._regionName + '</span> ' + escapeHtml(inst.InstanceName || inst.InstanceId) + '</div>' +
        '<div class="instance-meta">' + (inst.PublicIpAddress || inst.InnerIpAddress || '无IP') + ' · ' + (inst.ResourceSpec ? inst.ResourceSpec.Cpu + '核' + inst.ResourceSpec.Memory + 'G' : '') +
          '<span class="status-badge ' + expClass + '">' + (inst.BusinessStatus === 'Expired' ? '已过期' : statusText) + '</span>' +
        '</div>' +
      '</div>' +
      '<div class="instance-actions">' +
        '<button class="btn btn-xs btn-unsub" onclick="event.stopPropagation(); unsubscribeSingleInstance(\'' + inst._regionId + '\',\'' + inst.InstanceId + '\')" title="退订该实例（调用阿里云 DeleteInstance 释放，不可逆）">退订</button>' +
      '</div></div>';
  }).join('');

  // 实例列表渲染后同步"批量退订"按钮状态
  updateBatchUnsubBtn();
}

function escapeHtml(text) {
  var div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

function toggleInstance(instanceId, regionId, regionName, rowEl) {
  var cb = rowEl.querySelector('input[type="checkbox"]');
  cb.checked = !cb.checked;
  toggleInstanceCheck(instanceId, regionId, regionName);
}

function toggleInstanceCheck(instanceId, regionId, regionName) {
  if (state.selectedInstances.has(instanceId)) {
    state.selectedInstances.delete(instanceId);
  } else {
    state.selectedInstances.set(instanceId, { regionId: regionId, name: regionName });
  }
  updateSelectedList();
}

function selectAllInstances() {
  var _sids = Array.from(state.selectedRegions);
  for (var i = 0; i < _sids.length; i++) {
    var rid = _sids[i];
    var rd = state.regionData[rid];
    if (!rd || !rd.instances) continue;
    for (var j = 0; j < rd.instances.length; j++) {
      state.selectedInstances.set(rd.instances[j].InstanceId, { regionId: rid, name: REGION_INFO[rid] });
    }
  }
  renderInstances();
  updateSelectedList();
}

function deselectAllInstances() {
  state.selectedInstances.clear();
  renderInstances();
  updateSelectedList();
}

function updateSelectedList() {
  var count = state.selectedInstances.size;
  document.getElementById('selectedCount').textContent = count + ' 台';
  var container = document.getElementById('selectedList');

  if (count === 0) {
    container.innerHTML = '<div class="empty-state">未选择实例</div>';
    return;
  }

  var items = [];
  for (var _i2 = 0, _entries2 = state.selectedInstances.entries();;) {
    var _n2 = _entries2.next(); if (_n2.done) break;
    var kv = _n2.value;
    var iid = kv[0], info = kv[1];
    var instName = iid.substring(0, 8) + '...';
    for (var ri = 0, _sids2 = Array.from(state.selectedRegions); ri < _sids2.length; ri++) {
      var rid2 = _sids2[ri];
      var rd2 = state.regionData[rid2];
      if (!rd2 || !rd2.instances) continue;
      var found = null;
      for (var k = 0; k < rd2.instances.length; k++) {
        if (rd2.instances[k].InstanceId === iid) { found = rd2.instances[k]; break; }
      }
      if (found) { instName = found.InstanceName || instName; break; }
    }
    items.push('<div class="selected-item"><span>' + instName + '<span class="region-tag">' + info.name + '</span></span>' +
      '<button class="remove-btn" onclick="removeSelected(\'' + iid + '\')" title="取消选择">✕</button></div>');
  }
  container.innerHTML = items.join('');
}

function removeSelected(instanceId) {
  state.selectedInstances.delete(instanceId);
  renderInstances();
  updateSelectedList();
}

function getSelectedByRegion() {
  var groups = {};
  for (var _i3 = 0, _entries3 = state.selectedInstances.entries();;) {
    var _n3 = _entries3.next(); if (_n3.done) break;
    var kv2 = _n3.value;
    var iid2 = kv2[0], info2 = kv2[1];
    if (!groups[info2.regionId]) groups[info2.regionId] = [];
    groups[info2.regionId].push(iid2);
  }
  return groups;
}

// ====== 标签页 ======
function switchTab(tabName) {
  var tabs = document.querySelectorAll('.tab');
  for (var i = 0; i < tabs.length; i++) tabs[i].classList.remove('active');
  var contents = document.querySelectorAll('.tab-content');
  for (var j = 0; j < contents.length; j++) contents[j].classList.remove('active');
  document.querySelector('.tab[data-tab="' + tabName + '"]').classList.add('active');
  document.getElementById('tab-' + tabName).classList.add('active');
}

// ====== 防火墙 ======

async function loadAllRegionTemplates() {
  var regionIds = Object.keys(REGION_INFO);
  log('🔄 正在从阿里云同步防火墙模板...', 'info');
  try {
    var results = await Promise.all(regionIds.map(function(rid) {
      return AliyunClient.listFirewallTemplates(rid).then(function(data) {
        return { regionId: rid, success: true, templates: data.FirewallTemplates || [] };
      }).catch(function(err) {
        return { regionId: rid, success: false, templates: [], error: err.message };
      });
    }));

    var nameMap = {};
    results.forEach(function(r) {
      if (!r.success) return;
      r.templates.forEach(function(t) {
        if (!nameMap[t.Name]) nameMap[t.Name] = { name: t.Name, description: t.Description, regionTemplates: {} };
        nameMap[t.Name].regionTemplates[r.regionId] = t.FirewallTemplateId;
      });
    });
    state.allTemplates = Object.values(nameMap);
    updateStep2TemplateName();
    log('✅ 加载了 ' + state.allTemplates.length + ' 个模板（跨 ' + regionIds.length + ' 个地域）', 'success');
  } catch (err) {
    log('❌ 加载模板失败: ' + err.message, 'error');
  }
}

function updateStep2TemplateName() {
  var container = document.getElementById('fwRegionGrid');
  if (!container) return;

  var regionIds = Object.keys(REGION_INFO);

  if (state.allTemplates.length === 0) {
    container.innerHTML = '<p style="grid-column:1/-1; text-align:center; color:#999; padding:20px;">暂无模板，请先在步骤一中创建</p>';
    return;
  }

  container.innerHTML = regionIds.map(function(rid) {
    var regionName = REGION_INFO[rid];
    var color = REGION_COLORS[rid];
    var available = state.allTemplates.filter(function(t) { return t.regionTemplates[rid]; });

    // 没有可用模板时显示占位
    if (available.length === 0) {
      return '<div class="fw-region-item">' +
        '<div class="fw-region-label"><span class="region-dot" style="background:' + color + ';"></span>' + regionName + '</div>' +
        '<select class="select" disabled><option value="">暂无可用模板</option></select>' +
        '<div class="fw-region-hint" style="color:#e74c3c;">请先创建模板</div>' +
        '</div>';
    }

    // 构造选项，默认选中第一个
    var opts = available.map(function(t, idx) {
      return '<option value="' + t.name + '"' + (idx === 0 ? ' selected' : '') + '>' + t.name + '</option>';
    }).join('');

    // 如果用户之前选过别的模板，保留用户的选择
    var savedValue = state._fwRegionSelections && state._fwRegionSelections[rid];
    if (savedValue) {
      opts = opts.replace(/ selected/g, '');
      opts = opts.replace('value="' + savedValue + '"', 'value="' + savedValue + '" selected');
    }

    return '<div class="fw-region-item">' +
      '<div class="fw-region-label"><span class="region-dot" style="background:' + color + ';"></span>' + regionName + '</div>' +
      '<select class="select" data-region="' + rid + '" onchange="onFwRegionTemplateChange(\'' + rid + '\')">' +
        opts +
      '</select>' +
      '<div class="fw-region-hint">' + available.length + ' 个模板可用</div>' +
      '</div>';
  }).join('');
}

function onFwRegionTemplateChange(regionId) {
  var sel = document.querySelector('select[data-region="' + regionId + '"]');
  if (!sel) return;
  if (!state._fwRegionSelections) state._fwRegionSelections = {};
  state._fwRegionSelections[regionId] = sel.value || null;
}

async function batchApplyAllTemplates() {
  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('🛡️ 开始批量执行防火墙模板...', 'info');

  try {
    if (!state.allTemplates || state.allTemplates.length === 0) {
      log('❌ 暂无可用模板，请先点击「🔄 同步阿里云模板」', 'error');
      return;
    }

    var regionSelections = {};
    var regionIds = Object.keys(REGION_INFO);
    var anySelected = false;

    for (var i = 0; i < regionIds.length; i++) {
      var rid = regionIds[i];
      var sel = document.querySelector('select[data-region="' + rid + '"]');
      if (sel && sel.value) { regionSelections[rid] = sel.value; anySelected = true; }
    }

    if (!anySelected) {
      log('❌ 请至少为1个地域选择防火墙模板', 'error');
      return;
    }

    log('📋 已选择模板的地域：' + Object.keys(regionSelections).map(function(r) { return REGION_INFO[r]; }).join('、'), 'info');

    // 全选地域 + 加载实例
    state.selectedRegions.clear();
    for (var j = 0; j < regionIds.length; j++) { state.selectedRegions.add(regionIds[j]); }
    renderRegionCards();

    // 加载所有地域的全部实例（带翻页，不限 100 台上限）
    log('🔄 加载全部实例...', 'info');
    await Promise.all(regionIds.map(async function(rid2) {
      try {
        var allInsts = [];
        var pageNum = 1;
        var pageSize = 100;
        while (true) {
          var data = await AliyunClient.listInstances(rid2, { pageSize: pageSize, pageNumber: pageNum });
          var insts = data.Instances || [];
          allInsts = allInsts.concat(insts);
          var total = data.TotalCount || 0;
          if (pageNum * pageSize >= total || insts.length === 0) break;
          pageNum++;
        }
        if (!state.regionData[rid2]) state.regionData[rid2] = { name: REGION_INFO[rid2], totalCount: 0, error: null, instances: [] };
        state.regionData[rid2].instances = allInsts;
        state.regionData[rid2].totalCount = allInsts.length;
      } catch(err) {
        if (!state.regionData[rid2]) state.regionData[rid2] = { name: REGION_INFO[rid2], totalCount: 0, error: null, instances: [] };
        state.regionData[rid2].instances = [];
        log('⚠️ [' + REGION_INFO[rid2] + '] 加载实例失败: ' + err.message, 'warn');
      }
    }));
    renderInstances();

    var totalSuccess = 0, totalFail = 0;

    // 地域之间并行执行，每个地域内部按 10 台分批（阿里云 ApplyFirewallTemplate 单次上限 10 个 InstanceId）
    await Promise.all(regionIds.map(async function(rid3) {
      var templateName = regionSelections[rid3];
      if (!templateName) return;

      var tmpl = state.allTemplates.find(function(t) { return t.name === templateName; });
      if (!tmpl || !tmpl.regionTemplates[rid3]) { log('❌ [' + REGION_INFO[rid3] + '] 模板映射有问题', 'error'); return; }

      var templateId = tmpl.regionTemplates[rid3];
      var rd = state.regionData[rid3];
      var instanceIds = (rd && rd.instances || []).map(function(inst) { return inst.InstanceId; });

      if (instanceIds.length === 0) { log('⚠️ [' + REGION_INFO[rid3] + '] 无实例，跳过', 'warn'); return; }

      var BATCH_SIZE = 10;     // 阿里云 ApplyFirewallTemplate 单次最多 10 个 InstanceId
      var BATCH_DELAY = 300;   // 批间间隔 ms
      var batchCount = Math.ceil(instanceIds.length / BATCH_SIZE);
      log('🛡️ [' + REGION_INFO[rid3] + '] ' + instanceIds.length + ' 台分 ' + batchCount + ' 批执行（每批最多10台）', 'info');

      for (var b = 0; b < instanceIds.length; b += BATCH_SIZE) {
        var batch = instanceIds.slice(b, b + BATCH_SIZE);
        var batchNum = Math.floor(b / BATCH_SIZE) + 1;
        try {
          var result = await AliyunClient.applyFirewallTemplate(rid3, templateId, batch);
          totalSuccess++;
          log('  ✅ [' + REGION_INFO[rid3] + '] 第' + batchNum + '/' + batchCount + '批 (' + batch.length + '台): TaskId=' + (result.TaskId || 'OK'), 'success');
        } catch (err) {
          totalFail++;
          log('  ❌ [' + REGION_INFO[rid3] + '] 第' + batchNum + '/' + batchCount + '批 (' + batch.length + '台): ' + (err.message || err), 'error');
        }
        // 批间停顿避免限流
        if (b + BATCH_SIZE < instanceIds.length) {
          await new Promise(function(r) { setTimeout(r, BATCH_DELAY); });
        }
      }
    }));

    log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
    log('📊 防火墙模板批量执行完成: 成功 ' + totalSuccess + ' 批, 失败 ' + totalFail + ' 批', totalFail === 0 ? 'success' : 'warn');
  } catch (err) {
    log('❌ 严重错误: ' + err.message, 'error');
    console.error(err);
  }
}

// ====== 命令助手 ======

async function loadAllRegionCommands() {
  var regionIds = Object.keys(REGION_INFO);
  log('🔄 正在从阿里云同步命令列表...', 'info');
  try {
    var results = await Promise.all(regionIds.map(function(rid) {
      return AliyunClient.listCommands(rid).then(function(data) {
        state.regionCommands[rid] = (data.Commands || []).map(function(c) {
          return { commandId: c.CommandId, name: c.Name || c.CommandId, type: c.Type || 'RunShellScript', description: c.Description || '' };
        });
        return { regionId: rid, success: true, totalCount: data.TotalCount || 0 };
      }).catch(function(err) {
        state.regionCommands[rid] = [];
        return { regionId: rid, success: false, error: err.message };
      });
    }));

    updateCmdRegionGrid();
    var totalCmds = 0;
    for (var i = 0; i < results.length; i++) { totalCmds += (results[i].totalCount || 0); }
    log('✅ 加载了 ' + totalCmds + ' 条命令（跨 ' + regionIds.length + ' 个地域）', 'success');
  } catch (err) {
    log('❌ 加载命令失败: ' + err.message, 'error');
  }
}

function updateCmdRegionGrid() {
  var container = document.getElementById('cmdRegionGrid');
  if (!container) return;
  var regionIds = Object.keys(REGION_INFO);

  container.innerHTML = regionIds.map(function(rid) {
    var regionName = REGION_INFO[rid];
    var color = REGION_COLORS[rid];
    var commands = state.regionCommands[rid] || [];

    var selectHtml;
    if (commands.length === 0) {
      selectHtml = '<select class="select" data-region="' + rid + '" disabled><option value="">暂无命令</option></select>';
    } else {
      var opts = commands.map(function(c, i) {
        return '<option value="' + c.commandId + '"' + (i === 0 ? ' selected' : '') + '>' + c.name + ' (' + (c.type || 'Shell') + ')' + '</option>';
      }).join('');
      selectHtml = '<select class="select" data-region="' + rid + '" onchange="onCmdRegionChange(\'' + rid + '\')">' + opts + '</select>';
    }

    if (state._cmdRegionSelections && state._cmdRegionSelections[rid] && commands.length > 0) {
      selectHtml = selectHtml.replace('value="' + state._cmdRegionSelections[rid] + '"', 'value="' + state._cmdRegionSelections[rid] + '" selected');
    }

    return '<div class="fw-region-item">' +
      '<div class="fw-region-label"><span class="region-dot" style="background:' + color + ';"></span>' + regionName + '</div>' +
      selectHtml +
      (commands.length > 0 ? '<div class="fw-region-hint">' + commands.length + ' 条命令可用</div>' : '<div class="fw-region-hint" style="color:#e74c3c;">暂无命令</div>') +
      '</div>';
  }).join('');
}

function onCmdRegionChange(regionId) {
  var sel = document.querySelector('#cmdRegionGrid select[data-region="' + regionId + '"]');
  if (!sel) return;
  if (!state._cmdRegionSelections) state._cmdRegionSelections = {};
  state._cmdRegionSelections[regionId] = sel.value || null;
}

async function batchExecuteAllCommands() {
  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('💻 开始批量执行命令...（每批最多 100 台，超出自动分批）', 'info');

  try {
    if (!state.regionCommands || Object.keys(state.regionCommands).length === 0) {
      log('❌ 暂无可用命令，请先点击「🔄 同步阿里云命令」', 'error');
      return;
    }

    var regionIds = Object.keys(REGION_INFO);
    var regionSelections = {};

    for (var i = 0; i < regionIds.length; i++) {
      var rid = regionIds[i];
      var commands = state.regionCommands[rid] || [];
      var sel = document.querySelector('#cmdRegionGrid select[data-region="' + rid + '"]');
      if (commands.length > 0 && sel && sel.value) { regionSelections[rid] = sel.value; }
    }

    if (Object.keys(regionSelections).length === 0) {
      log('❌ 没有任何地域有可执行命令', 'error');
      return;
    }

    // 全选地域 + 完整加载实例（自动翻页）
    state.selectedRegions.clear();
    for (var j = 0; j < regionIds.length; j++) { state.selectedRegions.add(regionIds[j]); }
    renderRegionCards();

    if (!state.regionData) state.regionData = {};

    log('🔄 加载全部实例（含翻页）...', 'info');
    await Promise.all(regionIds.map(function(rid2) {
      return (async function() {
        if (!state.regionData[rid2]) state.regionData[rid2] = { name: REGION_INFO[rid2], totalCount: 0, error: null, instances: [] };
        try {
          var first = await AliyunClient.listInstances(rid2, { pageSize: 100 });
          var all = (first.Instances || []).slice();
          var total = first.TotalCount || all.length;
          var pages = Math.ceil(total / 100);
          if (pages > 1) {
            // 多页：按顺序拉取剩余页（避免触发并发 QPS 限流）
            for (var p = 2; p <= pages; p++) {
              var d2 = await AliyunClient.listInstances(rid2, { pageSize: 100, pageNumber: p });
              all = all.concat(d2.Instances || []);
              // 页间间隔，避免翻页 QPS 限流
              if (p < pages) await new Promise(function(r) { setTimeout(r, 200); });
            }
          }
          state.regionData[rid2].instances = all;
          state.regionData[rid2].totalCount = total;
        } catch (err) {
          state.regionData[rid2].instances = [];
          log('⚠️ 加载 [' + REGION_INFO[rid2] + '] 实例失败: ' + (err.message || err), 'warn');
        }
      })();
    }));
    renderInstances();

    // 📊 统计待执行
    var grandTotal = 0;
    var summaryLines = [];
    var selRids = Object.keys(regionSelections);
    for (var gi = 0; gi < selRids.length; gi++) {
      var gRid = selRids[gi];
      var n = ((state.regionData[gRid] || {}).instances || []).length;
      grandTotal += n;
      if (n > 0) summaryLines.push('  ' + REGION_INFO[gRid] + ': ' + n + ' 台');
    }
    log('📊 待执行: ' + grandTotal + ' 台', 'info');
    summaryLines.forEach(function(l) { log(l, 'info'); });

    if (grandTotal === 0) {
      log('⚠️ 没有找到任何实例', 'warn');
      return;
    }

    log('🔄 逐个地域执行命令（每批最多 100 台，并发地域之间并行）...', 'info');
    var totalSuccess = 0, totalFail = 0;
    var BATCH_SIZE = 100;      // 阿里云 InvokeCommand 硬上限：单次 ≤100 台
    var BATCH_DELAY = 400;     // 批间间隔 ms（每批之间的串行等待，避免触发 QPS 限流）

    // 地域之间并行；每个地域内部按 100 台分批循环
    await Promise.all(selRids.map(async function(rid3) {
      var cmdId = regionSelections[rid3];
      var rd = state.regionData[rid3];
      var instances = (rd && rd.instances) || [];
      if (instances.length === 0) { log('⚠️ [' + REGION_INFO[rid3] + '] 无实例，跳过', 'warn'); return; }

      var instanceIds = instances.map(function(inst) { return inst.InstanceId; });
      var regionSuccess = 0, regionFail = 0;
      var batchCount = Math.ceil(instanceIds.length / BATCH_SIZE);
      if (batchCount > 1) {
        log('🔄 [' + REGION_INFO[rid3] + '] ' + instanceIds.length + ' 台 → 自动分 ' + batchCount + ' 批（每批最多 ' + BATCH_SIZE + ' 台）', 'info');
      }

      // 每个地域内部：按 100 台顺序循环（保证 QPS 安全）
      for (var bi = 0; bi < instanceIds.length; bi += BATCH_SIZE) {
        var batchIdx = Math.floor(bi / BATCH_SIZE) + 1;
        var slice = instanceIds.slice(bi, bi + BATCH_SIZE);
        if (batchCount > 1) {
          log('   📦 [' + REGION_INFO[rid3] + '] 第 ' + batchIdx + '/' + batchCount + ' 批：' + slice.length + ' 台…', 'info');
        }
        try {
          var result = await AliyunClient.invokeCommand(rid3, cmdId, slice);
          regionSuccess += slice.length;
          var lastInvoke = result && (result.InvokeId || result.InvokeId === '' ? result.InvokeId : '');
          if (batchCount > 1) {
            log('   ✅ [' + REGION_INFO[rid3] + '] 第 ' + batchIdx + ' 批完成 → InvokeId=' + (lastInvoke || 'OK'), 'success');
          } else {
            log('✅ [' + REGION_INFO[rid3] + '] ' + slice.length + ' 台 → InvokeId=' + (lastInvoke || 'OK'), 'success');
          }
        } catch (err) {
          regionFail += slice.length;
          log('   ❌ [' + REGION_INFO[rid3] + '] 第 ' + batchIdx + ' 批 (' + slice.length + ' 台) 失败: ' + (err.message || err), 'error');
        }
        // 批间间隔（最后一批不等待）
        if (bi + BATCH_SIZE < instanceIds.length) await new Promise(function(r) { setTimeout(r, BATCH_DELAY); });
      }

      // 累计到全局（异步闭包，外层 Promise.all 后统一打印；这里先填到一个对象上）
      if (!state._cmdBatchStats) state._cmdBatchStats = {};
      state._cmdBatchStats[rid3] = { success: regionSuccess, fail: regionFail };
    }));

    // 汇总
    var statsRids = Object.keys(state._cmdBatchStats || {});
    for (var si = 0; si < statsRids.length; si++) {
      totalSuccess += state._cmdBatchStats[statsRids[si]].success;
      totalFail += state._cmdBatchStats[statsRids[si]].fail;
    }
    state._cmdBatchStats = null;

    log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
    log('🏁 批量执行完成: 成功 ' + totalSuccess + ' 台, 失败 ' + totalFail + ' 台', totalFail === 0 ? 'success' : 'warn');
    log('💡 提示：执行结果可在阿里云控制台「服务器运维 → 命令助手 → 执行历史」查看每台机器的输出', 'info');
  } catch (err) {
    log('❌ 严重错误: ' + err.message, 'error');
    console.error(err);
  }
}

// ====== 定时退订 ======
function initScheduleTimePicker() {
  var hourSel = document.getElementById('scheduleHour');
  var minuteSel = document.getElementById('scheduleMinute');
  if (!hourSel || !minuteSel) return;
  // 定时时间仅允许 23:35–23:59
  var optH = document.createElement('option');
  optH.value = '23';
  optH.textContent = '23';
  hourSel.appendChild(optH);
  for (var m = 35; m <= 59; m++) {
    var opt2 = document.createElement('option');
    opt2.value = String(m).padStart(2, '0');
    opt2.textContent = String(m).padStart(2, '0');
    minuteSel.appendChild(opt2);
  }
}

function toggleCancelMode() {
  var mode = document.querySelector('input[name="cancelMode"]:checked').value;
  document.getElementById('scheduledTimeGroup').style.display = mode === 'scheduled' ? 'block' : 'none';
  document.getElementById('confirmGroup').style.display = mode === 'scheduled' ? 'none' : 'block';
  checkConfirm();
}

function checkConfirm() {
  var radio = document.querySelector('input[name="cancelMode"]:checked');
  var mode = radio ? radio.value : 'immediate';
  var btn = document.getElementById('cancelBtn');
  if (!btn) return;
  if (mode === 'scheduled') {
    var hEl = document.getElementById('scheduleHour');
    var mEl = document.getElementById('scheduleMinute');
    btn.disabled = !(hEl && mEl && hEl.value !== '' && mEl.value !== '');
  } else {
    var inputEl = document.getElementById('confirmInput');
    btn.disabled = !(inputEl && inputEl.value.trim() === '确认退订');
  }
}

async function executeCancel() {
  var radio = document.querySelector('input[name="cancelMode"]:checked');
  var mode = radio ? radio.value : 'immediate';

  if (mode === 'scheduled') {
    // 定时退订：保存到云端 + 设置前端定时器
    var hEl = document.getElementById('scheduleHour');
    var mEl = document.getElementById('scheduleMinute');
    var hourStr = hEl ? hEl.value : '';
    var minuteStr = mEl ? mEl.value : '';
    
    if (!hourStr || hourStr === '' || !minuteStr || minuteStr === '') {
      alert('请选择执行时间');
      return;
    }

    log('⏰ 正在保存定时退订任务...', 'info');

    var hourNum = parseInt(hourStr, 10);
    var minuteNum = parseInt(minuteStr, 10);

    // 定时退订时间仅允许 23:35–23:59
    if (!(hourNum === 23 && minuteNum >= 35 && minuteNum <= 59)) {
      alert('定时退订时间只能设置在 23:35 到 23:59 之间');
      return;
    }

    // 【关键】定时退订由 Supabase 云端定时(pg_cron)执行，与电脑/浏览器开关无关。
    // 必须保证云端配置完整：时间 + 开关 + AK/SK 都要落地到 Supabase，否则云端到点无凭证可退。
    if (!(window.AliyunClient && AliyunClient.hasCredentials && AliyunClient.hasCredentials())) {
      log('❌ 请先在「设置凭证」里填写并保存 AccessKey，否则云端到点无凭证可退订', 'error');
      alert('请先设置并保存阿里云 AccessKey 凭证，再保存定时任务');
      return;
    }
    var ak = AliyunClient.getAccessKeyId();
    var sk = AliyunClient.getAccessKeySecret();

    try {
      if (window.CloudStore && currentUser && currentUser.user) {
        // 原子写入：时间 + 开关 + 凭证，确保云端配置完整（GitHub Actions 每10分钟读取并执行）
        await CloudStore.updateUserData(currentUser.user, {
          schedule_hour: hourNum,
          schedule_minute: minuteNum,
          schedule_enabled: true,
          ak_id: ak,
          ak_secret: sk,
        });
        // 回读云端确认已落库
        var saved = await CloudStore.getUserData(currentUser.user, true);
        var ok = saved && saved.schedule_enabled && saved.ak_id && saved.ak_secret;
        if (!ok) {
          log('⚠️ 云端未确认到完整配置（时间或凭证缺失），请检查网络后重新保存', 'warn');
        } else {
          log('✅ 配置已保存到云端：每晚 ' + hourStr + ':' + minuteStr + '（23:35–23:59 窗口）自动退订（GitHub Actions 云端调度，关电脑/关浏览器也会按时执行）', 'success');
        }
      } else {
        log('⚠️ 未登录云端账号，配置仅本地生效；请登录后再保存，云端调度才会接管', 'warn');
      }

      renderScheduledTasks();
    } catch(e) {
      log('❌ 保存失败: ' + e.message, 'error');
    }
    return;
  }

  // 立即退订
  var confirmInput = document.getElementById('confirmInput').value.trim();
  if (confirmInput !== '确认退订') { alert('请输入"确认退订"以确认操作'); return; }

  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
  log('🗑️ 开始【退订退款】所有地区的所有云主机（BSS RefundInstance，真正退款）...', 'warn');
  log('⏳ 正在查询实例列表...', 'warn');

  try {
    // 第1步：遍历所有地域获取实例
    var regionIds = Object.keys(REGION_INFO);
    var allInstances = [];
    var byRegion = {};

    for (var i = 0; i < regionIds.length; i++) {
      var rid = regionIds[i];
      try {
        var pageData = await AliyunClient.listInstances(rid, { pageSize: 100 });
        var instances = pageData.Instances || [];
        var totalCount = pageData.TotalCount || 0;

        // 如果超过100条，翻页获取
        if (totalCount > 100) {
          var totalPages = Math.ceil(totalCount / 100);
          for (var p = 2; p <= totalPages; p++) {
            var nextPage = await AliyunClient.listInstances(rid, { pageNumber: p, pageSize: 100 });
            instances = instances.concat(nextPage.Instances || []);
          }
        }

        byRegion[rid] = instances;
        for (var j = 0; j < instances.length; j++) {
          allInstances.push({ regionId: rid, instanceId: instances[j].InstanceId, name: instances[j].InstanceName, status: instances[j].Status });
        }
      } catch (err) {
        log('  ⚠️ [' + REGION_INFO[rid] + '] 查询失败: ' + err.message, 'warn');
      }
    }

    if (allInstances.length === 0) {
      log('✅ 未发现任何实例，无需退订', 'success');
      document.getElementById('confirmInput').value = '';
      document.getElementById('cancelBtn').disabled = true;
      return;
    }

    log('📋 共发现 ' + allInstances.length + ' 台实例，分布在 ' + Object.keys(byRegion).length + ' 个地域', 'info');
    for (var _rid2 = 0, _rkeys = Object.keys(byRegion); _rid2 < _rkeys.length; _rid2++) {
      var _rk = _rkeys[_rid2];
      log('   • [' + (REGION_INFO[_rk] || _rk) + '] ' + byRegion[_rk].length + ' 台', 'info');
    }

    // 第2步：按地域有界并发退订（并发≤REFUND_CONCURRENCY，速率≤REFUND_QPS/秒，限流自动退避重试，稳定 token 幂等不重复退款）
    var refundTotals = await refundByRegionParallel(byRegion, { recordFailures: true });
    var totalSuccess = refundTotals.success, totalSkipped = refundTotals.skipped,
        totalLocked = refundTotals.locked, totalFail = refundTotals.fail;

    log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
    log('🏁 退订（退款）完成: 成功 ' + totalSuccess + ' 台, 跳过 ' + totalSkipped + ' 台, 锁定 ' + totalLocked + ' 台, 失败 ' + totalFail + ' 台',
      totalFail === 0 ? 'success' : 'warn');
    if (totalFail > 0 || totalLocked > 0) {
      log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
      log('⚠️ 有 ' + (totalFail + totalLocked) + ' 台没能自动退订。可能原因：', 'warn');
      log('   • BSS API 仅支持【直销客户】，分销账号无法调用', 'warn');
      log('   • AK/SK 没勾选 AliyunBSSFullAccess 权限', 'warn');
      log('   • 该实例为活动订单/无剩余金额/已到退款期限', 'warn');
    }

    await refreshAllRegions();
    deselectAllRegions();
    document.getElementById('confirmInput').value = '';
    document.getElementById('cancelBtn').disabled = true;
  } catch (err) {
    log('❌ 退订失败: ' + err.message, 'error');
    console.error(err);
  }
}

/**
 * 探测哪个 ProductCode 对该实例可用（诊断工具）
 * 需要用户在控制台已经看到要退订的实例 ID
 */
async function probeProductCode() {
  var inputEl = document.getElementById('probeInstanceId');
  if (!inputEl) {
    log('❌ 找不到 #probeInstanceId 输入框', 'error');
    return;
  }
  var iid = (inputEl.value || '').trim();
  if (!iid) {
    log('⚠️ 请先输入要探测的实例 ID', 'warn');
    return;
  }
    log('🔬 正在探测实例 ' + iid + ' 的可用 ProductCode...', 'info');
  try {
    var resp = await AliyunClient.probeProductCode(iid);
    log('🔬 Edge Function 原始响应: ' + JSON.stringify(resp), 'info');
    if (!resp.success) {
      log('❌ 探测失败: ' + (resp.error || '未知错误'), 'error');
      return;
    }
    var trials = (resp.trials || []);
    log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
    log('🔬 ProductCode 探测结果（按尝试顺序）:', 'info');
    for (var i = 0; i < trials.length; i++) {
      var t = trials[i];
      if (t.ok) {
        log('   ✅ "' + t.code + '" → 成功！使用此 code 即可退订', 'success');
      } else {
        var label = t.commodityError ? '⚠️ 商品不支持（试下一个）' : '❌ 不适用';
        log('   ' + label + ' "' + t.code + '" → ' + (t.error || '失败'), 'info');
      }
    }
    log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  } catch (err) {
    log('❌ 探测失败: ' + err.message, 'error');
  }
}

// ====== 非全额退订：搜索 + 批量退款 ======

function extractRefundAmount(data) {
  if (!data) return null;
  var d = data.Data || data;
  if (d.RefundAmount !== undefined && d.RefundAmount !== null && d.RefundAmount !== '') return Number(d.RefundAmount);
  if (d.ExpectedRefundAmount !== undefined && d.ExpectedRefundAmount !== null && d.ExpectedRefundAmount !== '') return Number(d.ExpectedRefundAmount);
  if (d.RefundFee !== undefined && d.RefundFee !== null && d.RefundFee !== '') return Number(d.RefundFee);
  if (d.refundAmount !== undefined && d.refundAmount !== null && d.refundAmount !== '') return Number(d.refundAmount);
  return null;
}

async function searchRefundableInstances() {
  if (!state.hasCredentials) { log('⚠️ 请先设置阿里云凭证', 'warn'); return; }

  var statusEl = document.getElementById('refundSearchStatus');
  var resultEl = document.getElementById('refundSearchResult');
  var btn = document.getElementById('searchRefundBtn');

  try {
    if (btn) { btn.disabled = true; btn.textContent = '⏳ 搜索中...'; }
    if (statusEl) statusEl.textContent = '正在遍历所有地域查询实例...';
    if (resultEl) resultEl.style.display = 'none';
    state.refundItems = [];
    state.refundSelected.clear();

    // 1. 获取所有实例
    var regionIds = Object.keys(REGION_INFO);
    var allInstances = [];
    for (var i = 0; i < regionIds.length; i++) {
      var rid = regionIds[i];
      try {
        var pageData = await AliyunClient.listInstances(rid, { pageSize: 100 });
        var instances = pageData.Instances || [];
        var totalCount = pageData.TotalCount || 0;
        if (totalCount > 100) {
          var totalPages = Math.ceil(totalCount / 100);
          for (var p = 2; p <= totalPages; p++) {
            var nextPage = await AliyunClient.listInstances(rid, { pageNumber: p, pageSize: 100 });
            instances = instances.concat(nextPage.Instances || []);
          }
        }
        for (var j = 0; j < instances.length; j++) {
          allInstances.push({ regionId: rid, instance: instances[j] });
        }
      } catch (err) {
        log('  ⚠️ [' + (REGION_INFO[rid] || rid) + '] 查询失败: ' + err.message, 'warn');
      }
    }

    if (allInstances.length === 0) {
      if (statusEl) statusEl.textContent = '未找到任何实例。';
      return;
    }

    if (statusEl) statusEl.textContent = '已找到 ' + allInstances.length + ' 台实例，正在通过 BSS 询价探测可退订设备（直连 business.aliyuncs.com）...';

    // 2. 用 BSS InquiryPriceRefundInstance（ProductCode=ace_eweb）探测每个实例
    var items = [];
    for (var k = 0; k < allInstances.length; k++) {
      var item = allInstances[k];
      var inst = item.instance;
      var iid = inst.InstanceId;
      var regionName = REGION_INFO[item.regionId] || item.regionId;

      if (statusEl) statusEl.textContent = '探测中 ' + (k + 1) + '/' + allInstances.length + ' ...';

      var refundable = false;
      var probeError = null;
      var refundAmount = null;

      try {
        var probeResp = await AliyunClient.probeRefundable(iid);
        if (probeResp && probeResp.success) {
          var d = (probeResp.data && probeResp.data.Data) ? probeResp.data.Data : (probeResp.data || {});
          refundAmount = d.RefundAmount || d.ExpectedRefundAmount || d.RefundFee || null;
          refundable = true;
        } else {
          probeError = probeResp.message || probeResp.code || '未知错误';
        }
      } catch (err) {
        probeError = (err && (err.code || err.message)) || String(err);
      }

      items.push({
        regionId: item.regionId,
        regionName: regionName,
        instanceId: iid,
        instanceName: inst.InstanceName || iid,
        productName: '轻量应用服务器',
        creationTime: inst.CreationTime,
        expiredTime: inst.ExpiredTime,
        chargeType: inst.ChargeType,
        refundable: refundable,
        refundAmount: refundAmount,
        probeError: probeError
      });
    }

    state.refundItems = items;

    var refundableCount = items.filter(function(x) { return x.refundable; }).length;
    if (refundableCount === 0) {
      if (statusEl) statusEl.innerHTML = '未找到可通过 BSS 退订的实例。<br><small>请确认账号为直销客户且实例可非全额退订。</small>';
    } else {
      if (statusEl) statusEl.textContent = '找到 ' + refundableCount + ' 台可退订设备（共探测 ' + items.length + ' 台），已自动勾选，请核对后点击右下角「立即退订」。';
    }

    renderRefundList();
    if (resultEl) resultEl.style.display = 'block';
  } catch (err) {
    log('❌ 搜索失败: ' + err.message, 'error');
    if (statusEl) statusEl.textContent = '搜索失败：' + err.message;
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = '🔍 搜索非全额退订设备'; }
  }
}

function clearRefundSearch() {
  state.refundItems = [];
  state.refundSelected.clear();
  var statusEl = document.getElementById('refundSearchStatus');
  var resultEl = document.getElementById('refundSearchResult');
  var listEl = document.getElementById('refundList');
  var selectAllEl = document.getElementById('refundSelectAll');
  if (statusEl) statusEl.textContent = '';
  if (resultEl) resultEl.style.display = 'none';
  if (listEl) listEl.innerHTML = '';
  if (selectAllEl) selectAllEl.checked = false;
  updateRefundSelectedCount();
}

function renderRefundList() {
  var listEl = document.getElementById('refundList');
  var selectAllEl = document.getElementById('refundSelectAll');
  if (!listEl) return;

  if (state.refundItems.length === 0) {
    listEl.innerHTML = '<div class="refund-empty">暂无数据，点击上方按钮搜索</div>';
    if (selectAllEl) selectAllEl.checked = false;
    updateRefundSelectedCount();
    return;
  }

  var html = '';
  for (var i = 0; i < state.refundItems.length; i++) {
    var item = state.refundItems[i];
    var checked = state.refundSelected.has(item.instanceId) ? 'checked' : '';
    var timeRange = (item.creationTime || '') + ' 至 ' + (item.expiredTime || '');
    var statusHtml = '';
    if (item.refundable) {
      var amtStr = item.refundAmount !== null && item.refundAmount !== undefined
        ? '<span class="refund-amount">¥ ' + Number(item.refundAmount).toFixed(2) + '</span>'
        : '<span style="color:#16a34a;font-weight:600;font-size:13px;">✅ 可退订</span>';
      statusHtml = amtStr;
    } else if (item.probeError) {
      statusHtml = '<span style="color:#999;font-size:12px;">不可退订：' + escapeHtml(item.probeError) + '</span>';
    } else {
      statusHtml = '<span style="color:#999;font-size:12px;">未探测</span>';
    }

    html += '<div class="refund-item' + (item.refundable ? '' : ' refund-item-disabled') + '">' +
      '<input type="checkbox" ' + checked + ' onchange="toggleRefundSelect(\'' + item.instanceId + '\')" ' + (item.refundable ? '' : 'disabled') + ' />' +
      '<div class="refund-item-info">' +
        '<div class="refund-item-title">' + escapeHtml(item.productName) + ' · ' + escapeHtml(item.instanceName) + '</div>' +
        '<div class="refund-item-meta">' + escapeHtml(item.instanceId) + ' · ' + escapeHtml(item.regionName) + ' · ' + escapeHtml(timeRange) + '</div>' +
      '</div>' +
      '<div class="refund-item-amount">' + statusHtml + '</div>' +
    '</div>';
  }
  listEl.innerHTML = html;

  if (selectAllEl) selectAllEl.checked = state.refundSelected.size === state.refundItems.length && state.refundItems.length > 0;
  updateRefundSelectedCount();
}

function toggleRefundSelect(instanceId) {
  if (state.refundSelected.has(instanceId)) {
    state.refundSelected.delete(instanceId);
  } else {
    state.refundSelected.add(instanceId);
  }
  renderRefundList();
}

function toggleRefundSelectAll() {
  var selectAllEl = document.getElementById('refundSelectAll');
  if (!selectAllEl) return;
  if (selectAllEl.checked) {
    for (var i = 0; i < state.refundItems.length; i++) {
      state.refundSelected.add(state.refundItems[i].instanceId);
    }
  } else {
    state.refundSelected.clear();
  }
  renderRefundList();
}

function updateRefundSelectedCount() {
  var countEl = document.getElementById('refundSelectedCount');
  var btn = document.getElementById('refundNowBtn');
  var count = state.refundSelected.size;
  if (countEl) countEl.textContent = '已选 ' + count + ' 台';
  if (btn) btn.disabled = count === 0;
}

async function refundSelectedInstances() {
  if (state.refundSelected.size === 0) { log('⚠️ 请先勾选要退订的实例', 'warn'); return; }
  if (!state.hasCredentials) { log('⚠️ 请先设置阿里云凭证', 'warn'); return; }

  var selectedItems = [];
  for (var i = 0; i < state.refundItems.length; i++) {
    if (state.refundSelected.has(state.refundItems[i].instanceId)) {
      selectedItems.push(state.refundItems[i]);
    }
  }

  var totalAmount = selectedItems.reduce(function(sum, item) { return sum + (Number(item.refundAmount) || 0); }, 0);
  var confirmMsg = '确定要退订 ' + selectedItems.length + ' 台实例吗？\n\n' +
    '• 调用阿里云 BSS RefundInstance 真正退款（直连 business.aliyuncs.com）\n' +
    '• 预计退款总额：¥ ' + totalAmount.toFixed(2) + '\n' +
    '• 操作不可逆，实例将被释放，数据不可恢复！';
  if (!confirm(confirmMsg)) return;

  var btn = document.getElementById('refundNowBtn');
  try {
    if (btn) { btn.disabled = true; btn.textContent = '⏳ 退订中...'; }

    log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
    log('🗑️ 开始非全额退订：' + selectedItems.length + ' 台实例（按地区并行，每地区每批 50 台，批间 3 秒）', 'warn');

    // 按地区分组，复用 refundByRegionParallel 并行退订
    var byRegion = {};
    for (var j = 0; j < selectedItems.length; j++) {
      var item = selectedItems[j];
      if (!byRegion[item.regionId]) byRegion[item.regionId] = [];
      byRegion[item.regionId].push({ InstanceId: item.instanceId, instanceId: item.instanceId });
    }

    var rt = await refundByRegionParallel(byRegion, {});
    var success = rt.success, skip = rt.skipped, fail = rt.fail + rt.locked;

    log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
    log('🏁 非全额退订完成：成功 ' + success + ' 台，跳过 ' + skip + ' 台，失败 ' + fail + ' 台', fail === 0 ? 'success' : 'warn');
    if (fail > 0) {
      log('⚠️ 失败常见原因：', 'warn');
      log('   • BSS API 仅支持【直销客户】，分销账号无法调用', 'warn');
      log('   • AK/SK 未勾选 AliyunBSSFullAccess 权限', 'warn');
      log('   • 该实例为活动订单/无剩余金额/已到退款期限', 'warn');
    }

    await refreshAllRegions();
    clearRefundSearch();
  } catch (err) {
    log('❌ 批量退款执行出错: ' + err.message, 'error');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = '🗑️ 立即退订'; updateRefundSelectedCount(); }
  }
}

// ====== 定时任务显示 ======
async function renderScheduledTasks() {
  var container = document.getElementById('scheduledTasksContainer');
  var listEl = document.getElementById('scheduledTaskList');
  if (!container || !listEl) return;

  if (!window.CloudStore || !currentUser || !currentUser.user) return;

  try {
    var data = await CloudStore.getUserData(currentUser.user);
    var hour = data.schedule_hour;
    var minute = data.schedule_minute;
    var enabled = data.schedule_enabled;

    if (enabled && hour !== undefined && minute !== undefined) {
      var timeStr = String(hour).padStart(2, '0') + ':' + String(minute).padStart(2, '0');
      var lastDateStr = data.schedule_last_executed_date;
      var lastInfo = '';
      if (lastDateStr) {
        lastInfo = '<small style="color:#16a34a">✅ 上次执行：' + lastDateStr + '</small><br>';
      } else {
        lastInfo = '<small style="color:#999">⏳ 尚未执行过（首次执行后会自动记录日期）</small><br>';
      }
      listEl.innerHTML =
        '<div class="task-item" style="padding:12px; background:#f0f9ff; border:1px solid #bae6fd; border-radius:6px;">' +
        '<div style="display:flex; justify-content:space-between; align-items:center;">' +
        '<div>' +
        '<strong>⏰ 每天 ' + timeStr + ' 自动退订</strong><br>' +
        lastInfo +
        '<small style="color:#666">执行窗口：每晚 23:35–23:59（其余时间不执行）。① 服务端调度器（cron/Edge Function）到点自动退订；② 浏览器打开/切回本页时若处于窗口且到点，会立即补跑。退订=释放实例，立即生效不再计费。</small>' +
        '</div>' +
        '<div style="display:flex; flex-direction:column; gap:6px;">' +
        '<button class="btn btn-danger" style="padding:4px 12px; font-size:12px;" onclick="runScheduledCancelNow()">🚀 立即执行</button>' +
        '<button class="btn btn-outline" style="padding:4px 12px; font-size:12px;" onclick="removeScheduledTask()">取消定时</button>' +
        '</div>' +
        '</div>' +
        '</div>';
      container.style.display = 'block';
    } else {
      container.style.display = 'none';
    }
  } catch(e) {
    console.warn('renderScheduledTasks error', e);
  }
  // 每次渲染后尝试自动触发 / 布防定时退订
  checkAndRunScheduledRefund();
}

// ====== 前端定时退订自动触发（补跑 + 到点触发）======
// 注意：浏览器关闭后无法运行 JS。真正的“关浏览器也执行”必须由服务端调度器
// （GitHub Actions / Supabase Cron）完成。本函数只让「打开网页 / 切回前台 / 恢复联网」
// 时自动触发，使设计文档中声称的 ② 补跑 真正生效。
function getBeijingDate() {
  var now = new Date();
  var utcMs = now.getTime() + now.getTimezoneOffset() * 60000;
  return new Date(utcMs + 8 * 3600000); // 中国无夏令时，固定 UTC+8
}

async function checkAndRunScheduledRefund() {
  if (!window.CloudStore || !currentUser || !currentUser.user) return;
  if (!state.hasCredentials) return;

  var data;
  try {
    data = await CloudStore.getUserData(currentUser.user);
  } catch (e) { return; }

  if (!data || !data.schedule_enabled) {
    if (state.scheduleTimerId) { clearTimeout(state.scheduleTimerId); state.scheduleTimerId = null; }
    return;
  }
  var hour = data.schedule_hour;
  var minute = data.schedule_minute;
  if (hour === undefined || hour === null || minute === undefined || minute === null) return;

  // 定时时间只允许 23:35–23:59，其余时间不执行
  if (!(hour === 23 && minute >= 35 && minute <= 59)) {
    if (state.scheduleTimerId) { clearTimeout(state.scheduleTimerId); state.scheduleTimerId = null; }
    log('❌ 定时时间必须在 23:35–23:59 之间，已忽略该任务', 'error');
    return;
  }

  var bj = getBeijingDate();
  var target = new Date(bj);
  target.setHours(parseInt(hour, 10), parseInt(minute, 10), 0, 0);
  var nowMs = bj.getTime();
  var targetMs = target.getTime();
  // 是否处于允许的执行窗口 23:35–23:59（北京时间）
  var inWindow = (bj.getHours() === 23 && bj.getMinutes() >= 35);

  if (nowMs < targetMs) {
    // 未到点 → 布防定时器（页面保持打开时到点自动触发）
    var delayMs = targetMs - nowMs;
    if (state.scheduleTimerId) { clearTimeout(state.scheduleTimerId); state.scheduleTimerId = null; }
    state.scheduleTimerId = setTimeout(function () {
      CloudStore.getUserData(currentUser.user).then(function (d) {
        var t = getBeijingDate();
        var win = (t.getHours() === 23 && t.getMinutes() >= 35);
        if (d && d.schedule_enabled && win) {
          log('⏰ 定时时间到，自动执行定时退订...', 'warn');
          executeScheduledRefund();
        }
      }).catch(function () {});
    }, delayMs);
    log('⏳ 已布防前端定时器：今天 ' + String(hour).padStart(2, '0') + ':' + String(minute).padStart(2, '0') + ' 自动退订（需保持本页打开；关闭浏览器则依赖服务端调度器）', 'info');
  } else if (inWindow) {
    // 已过点且处于执行窗口 → 立即补跑（不限制每天次数）
    log('⏰ 检测到 ' + String(hour).padStart(2, '0') + ':' + String(minute).padStart(2, '0') + ' 已过且处于执行窗口，立即执行定时退订...', 'warn');
    executeScheduledRefund();
  } else {
    // 已过点但不在窗口（如过了 23:59）→ 不执行，等待明天窗口
    if (state.scheduleTimerId) { clearTimeout(state.scheduleTimerId); state.scheduleTimerId = null; }
  }
}

async function removeScheduledTask() {
  if (!confirm('确定取消定时退订任务？')) return;
  if (!window.CloudStore || !currentUser || !currentUser.user) return;
  try {
    await CloudStore.updateUserData(currentUser.user, {
      schedule_enabled: false,
    });
    // 清除前端定时器
    if (state.scheduleTimerId) {
      clearTimeout(state.scheduleTimerId);
      state.scheduleTimerId = null;
    }
    log('✅ 定时退订任务已取消', 'success');
    renderScheduledTasks();
  } catch(e) {
    alert('取消失败: ' + e.message);
  }
}

// ====== 前端执行定时退款（BSS RefundInstance） ======
async function executeScheduledRefund() {
  if (!state.hasCredentials) {
    log('❌ 定时退订失败：未配置 AK/SK', 'error');
    return;
  }

  var nowStr = new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' });
  log('⏰ 北京时间 ' + nowStr + '，开始执行定时退订', 'warn');

  // 记录最后执行日期（仅用于监控，不再作为「每天只跑一次」的闸门）—— 统一用【北京时间】日期，与 cron 脚本保持一致
  try {
    if (window.CloudStore && currentUser && currentUser.user) {
      var todayStr = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Shanghai' }); // YYYY-MM-DD (北京时间)
      await CloudStore.updateUserData(currentUser.user, {
        schedule_last_executed_date: todayStr,
      });
    }
  } catch(e) {}

  // 遍历全部凭证（多 profile 各退各的实例）
  var profiles = [];
  try { profiles = AliyunClient.listProfiles() || []; } catch(e) { profiles = []; }
  if (!profiles.length) profiles = [{ name: '默认' }];

  // 按 AK 去重：同一账号内相同 AK 视为重复凭证，只退一次（不影响不同账号）
  var _seenAk = {};
  var _dedup = 0;
  for (var _k = 0; _k < profiles.length; _k++) {
    var _a = (profiles[_k].ak_id || '').trim();
    if (_a) { if (_seenAk[_a]) continue; _seenAk[_a] = true; }
    _dedup++;
  }
  log('🔑 共扫描 ' + profiles.length + ' 个凭证，去重后 ' + _dedup + ' 个（重复凭证只退一次）', 'info');

  var originalActive = '';
  try { var ap = AliyunClient.getActiveProfile(); if (ap) originalActive = ap.name; } catch(e) {}

  var grandSuccess = 0, grandSkip = 0, grandFail = 0;
  var _seenAkRun = {};

  for (var pi = 0; pi < profiles.length; pi++) {
    var prof = profiles[pi];
    // 去重：与其他凭证 AK 相同时跳过（重复凭证只退一次）
    var _profAk = (prof.ak_id || '').trim();
    if (_profAk && _seenAkRun[_profAk]) {
      log('⚠️ 凭证「' + prof.name + '」与其他凭证 AK 相同，已跳过（重复凭证只退一次）', 'warn');
      continue;
    }
    if (_profAk) _seenAkRun[_profAk] = true;
    try {
      await AliyunClient.useProfile(prof.name);
    } catch(e) {
      log('  ⚠️ 切换到凭证「' + prof.name + '」失败: ' + (e && e.message ? e.message : e), 'warn');
      continue;
    }
    log('──── 凭证「' + prof.name + '」────', 'warn');

    // 逐个凭证「退干净再退下一个」：每轮「列全部实例 → 退订 → 复查」，直到该凭证名下再无实例
    var _maxRounds = 12;
    var _round = 0;
    var _profSuccess = 0, _profSkip = 0, _profFail = 0;
    while (_round < _maxRounds) {
      _round++;
      // 获取该凭证下的所有实例
      var regionIds = Object.keys(REGION_INFO);
      var allInstances = [];
      for (var i = 0; i < regionIds.length; i++) {
        var rid = regionIds[i];
        try {
          var pageData = await AliyunClient.listInstances(rid, { pageSize: 100 });
          var instances = pageData.Instances || [];
          var totalCount = pageData.TotalCount || 0;
          if (totalCount > 100) {
            var totalPages = Math.ceil(totalCount / 100);
            for (var p = 2; p <= totalPages; p++) {
              var nextPage = await AliyunClient.listInstances(rid, { pageNumber: p, pageSize: 100 });
              instances = instances.concat(nextPage.Instances || []);
            }
          }
          for (var j = 0; j < instances.length; j++) {
            allInstances.push({ regionId: rid, instanceId: instances[j].InstanceId, name: instances[j].InstanceName });
          }
        } catch (err) {
          log('  ⚠️ [' + (REGION_INFO[rid] || rid) + '] 查询失败: ' + err.message, 'warn');
        }
      }

      if (allInstances.length === 0) {
        log('✅ 凭证「' + prof.name + '」第 ' + _round + ' 轮复查：已无实例（退订完成）', 'success');
        break;
      }

      // 按地域聚合实例
      var byRegion = {};
      for (var ai = 0; ai < allInstances.length; ai++) {
        var a = allInstances[ai];
        (byRegion[a.regionId] = byRegion[a.regionId] || []).push(a);
      }

      log('🔄 第 ' + _round + ' 轮：退订 ' + allInstances.length + ' 台（有界并发，限流自动退避）...', 'warn');
      var rt = await refundByRegionParallel(byRegion, {});
      var success = rt.success, skip = rt.skipped, fail = rt.fail + rt.locked;
      _profSuccess += success; _profSkip += skip; _profFail += fail;

      log('  🔁 凭证「' + prof.name + '」第 ' + _round + ' 轮：成功 ' + success + ' 台，累计 ' + _profSuccess + '（继续复查…）', 'info');
      await new Promise(function(r){ setTimeout(r, 800); }); // 让阿里云侧状态刷新（已缩短到 0.8s 以加快退订节奏）
    }
    if (_round >= _maxRounds) {
      log('  ⚠️ 凭证「' + prof.name + '」达到最大轮数仍有实例，停止以免死循环', 'warn');
    }
    grandSuccess += _profSuccess; grandSkip += _profSkip; grandFail += _profFail;
    log('🏁 凭证「' + prof.name + '」退订完成：成功 ' + _profSuccess + ' 台，跳过 ' + _profSkip + ' 台，失败 ' + _profFail + ' 台', _profFail === 0 ? 'success' : 'warn');
    if (typeof rt !== 'undefined' && rt && rt.locked > 0) log('   🔒 其中 ' + rt.locked + ' 台为不可退订（已跳过，不再重试）', 'warn');
    if (_profFail > 0) {
      log('⚠️ 失败常见原因：BSS 仅支持直销客户 / 未勾选 AliyunBSSFullAccess / 实例不可退订', 'warn');
    }
  }

  // 还原用户原本选中的活跃凭证
  if (originalActive) {
    try { await AliyunClient.useProfile(originalActive); } catch(e) {}
  }

  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
  log('🏁 全部凭证退订完成：成功 ' + grandSuccess + ' 台，跳过 ' + grandSkip + ' 台，失败 ' + grandFail + ' 台', grandFail === 0 ? 'success' : 'warn');

  await refreshAllRegions();
}

async function runScheduledCancelNow() {
  if (!confirm('🚀 立即触发退订？\n\n这会立即调用 BSS RefundInstance 退订所有地域的所有云主机。\n\n确认继续？')) return;

  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
  log('🚀 立即触发定时退订...', 'warn');

  await executeScheduledRefund();
  renderScheduledTasks();
}

// ====== 批量下单（云端版：调用 SWAS-OPEN API 真下单） ======
var ORDER_DEFAULT_PRICE = 40;
var LOCKED_PLAN_ID = 'swas.s.c2m1s30b1.linux';
var LOCKED_IMAGE_NAME = 'CentOS-7.9';
var LOCKED_IMAGE_ID = 'bdde0344f65942f3adce35d421732c87';  // 锁定 CentOS-7.9，跳过镜像列表查询

// 当前订单结果（待支付的订单ID列表）
var state = state || {};
state.orderResults = [];

// 加载套餐信息（占位 - 阿里云 ListPlans API 需要特殊权限）
function loadOrderPlans() {
  log('🔄 正在加载阿里云轻量应用服务器套餐信息...', 'info');
  log('💡 当前使用默认套餐：' + LOCKED_PLAN_ID + ' (' + LOCKED_IMAGE_NAME + ', ¥' + ORDER_DEFAULT_PRICE + '/月)', 'info');
  log('⚠️ 阿里云 SWAS-OPEN ListPlans API 需要额外权限。如需自定义套餐，请联系瑞瑶', 'info');

  // 重新渲染套餐信息（从阿里云获取真实价格如果 API 可用）
  refreshOrderPlanInfo();
}

async function refreshOrderPlanInfo() {
  var planInfoBar = document.getElementById('planInfoBar');
  if (!planInfoBar) return;

  // 显示加载状态
  var html = '<div class="plan-spec">' +
    '<span class="spec-item">⚡ 2 vCPU</span>' +
    '<span class="spec-item">💾 1 GiB</span>' +
    '<span class="spec-item">💿 系统盘</span>' +
    '<span class="spec-item">🌐 200 Mbps</span>' +
    '<span class="spec-item">📡 1 IPv4</span>' +
    '<span class="spec-item price">¥' + ORDER_DEFAULT_PRICE + '/月</span>' +
    '</div>' +
    '<button class="btn btn-sm" onclick="loadOrderPlans()">🔄 刷新套餐</button>';
  planInfoBar.innerHTML = html;

  // 尝试调用 ListPlans（如果 API 可用）——通过 Edge Function 代理，避开 CORS
  if (window.AliyunClient && AliyunClient.hasCredentials()) {
    try {
      var plans = await AliyunClient.listPlans('cn-hangzhou');

      if (plans && plans.Plans && plans.Plans.length > 0) {
        var matched = plans.Plans.find(function(p) {
          return p.PlanId === LOCKED_PLAN_ID;
        });
        if (matched && matched.Price && matched.Price.MonthPrice) {
          ORDER_DEFAULT_PRICE = parseFloat(matched.Price.MonthPrice) || ORDER_DEFAULT_PRICE;
          log('✅ 已从阿里云获取最新价格：¥' + ORDER_DEFAULT_PRICE + '/月', 'success');
        }
      }
    } catch (err) {
      console.warn('ListPlans 调用失败:', err);
      // 静默失败，使用默认价格
    }
  }

  updateOrderSummary();
}

function initOrderGrid() {
  var container = document.getElementById('orderRegionGrid');
  var summary = document.getElementById('orderSummary');
  var regionIds = Object.keys(REGION_INFO);

  var items = regionIds.map(function(rid) {
    return '<div class="order-region-item" id="order-item-' + rid + '">' +
      '<div class="region-name">📍 ' + REGION_INFO[rid] + '</div>' +
      '<div class="region-plan" id="order-plan-' + rid + '" style="color:#52c41a">' +
        '<span class="plan-id">' + LOCKED_PLAN_ID + '</span> · ' + LOCKED_IMAGE_NAME + ' · ¥' + ORDER_DEFAULT_PRICE + '/月</div>' +
      '<div class="region-input"><label>数量:</label>' +
        '<input type="number" class="input input-sm" min="0" max="100" value="0" data-region="' + rid + '" oninput="updateOrderSummary()" /></div>' +
      '</div>';
  }).join('');

  container.innerHTML = items;
  if (summary) summary.style.display = 'block';
  updateOrderSummary();
}

function updateOrderSummary() {
  var totalCount = 0;
  var totalPrice = 0;
  var inputs = document.querySelectorAll('#orderRegionGrid input[type="number"]');
  for (var i = 0; i < inputs.length; i++) {
    var regionId = inputs[i].dataset.region;
    var count = parseInt(inputs[i].value) || 0;
    if (count > 0) {
      totalCount += count;
      totalPrice += count * ORDER_DEFAULT_PRICE;
    }
  }
  var countEl = document.getElementById('orderTotalCount');
  var priceEl = document.getElementById('orderTotalPrice');
  if (countEl) countEl.textContent = totalCount;
  if (priceEl) priceEl.textContent = '¥' + totalPrice.toFixed(2);
}

// 为某个地域选出最适合下单的镜像（现在直接锁定 CentOS-7.9，不再调接口查 91 个镜像）
async function resolveImageForRegion(regionId) {
  log('🖼️  ' + REGION_INFO[regionId] + ' 使用锁定镜像：' + LOCKED_IMAGE_NAME + ' (' + LOCKED_IMAGE_ID + ')', 'info');
  return { ImageId: LOCKED_IMAGE_ID, ImageName: LOCKED_IMAGE_NAME };
}

// ====== 批量下单核心：调用阿里云 CreateOrder API ======
async function batchCreateInstances() {
  var inputs = document.querySelectorAll('#orderRegionGrid input[type="number"]');
  var regionOrders = [];

  for (var i = 0; i < inputs.length; i++) {
    var count = parseInt(inputs[i].value) || 0;
    var rid = inputs[i].dataset.region;
    if (count > 0) {
      regionOrders.push({ regionId: rid, count: count, regionName: REGION_INFO[rid] });
    }
  }

  if (regionOrders.length === 0) {
    log('⚠️ 请先输入至少一个地域的下单数量', 'warn');
    return;
  }

  // 检查凭证
  if (!AliyunClient.hasCredentials()) {
    log('❌ 未设置阿里云凭证，无法下单', 'error');
    showCredentialDialog();
    return;
  }

  var totalInstances = regionOrders.reduce(function(s, r) { return s + r.count; }, 0);
  log('🚀 开始批量下单：共 ' + totalInstances + ' 台，跨 ' + regionOrders.length + ' 个地域', 'info');

  var orderResultEl = document.getElementById('orderResult');
  var orderResultListEl = document.getElementById('orderResultList');
  orderResultListEl.innerHTML = '<div style="color:#666;">下单中，请稍候...</div>';
  orderResultEl.style.display = 'block';

  state.orderResults = [];

  // 🔧 v35 修复：之前 for (var j=0;...) 循环内 var j = await resp.json() 重名导致循环提前终止
  // 现在改为 map + Promise.all 并发执行 6 个地域下单（每个地域独立 try-catch，单个失败不影响其他）
  log('📦 准备下单地区列表：' + regionOrders.map(function(o){return o.regionName+'×'+o.count;}).join('、'), 'info');

  // 实际下单处理函数（独立 try-catch，单个地区失败不影响其他地区；内置 3 次重试）
  async function processOrder(order, orderIndex) {
    log('📍 [' + (orderIndex+1) + '/' + regionOrders.length + '] ' + order.regionName + '：下单 ' + order.count + ' 台...', 'info');
    try {
      // 🔍 先查该地域可用镜像（按地域缓存 30 分钟）
      var imgPick = await resolveImageForRegion(order.regionId);
      if (!imgPick) {
        throw new Error('该地域无可用镜像，跳过');
      }
      console.log('%c[app.js] 下单走 Edge Function 代理 (hardcoded URL)', 'background:#ff5722;color:white;padding:2px 6px;font-weight:bold;');
      // 🔒 硬编码 URL，不再依赖 window.WB_SUPABASE_FUNCTIONS 全局变量（避免任何缓存导致全局变量未定义）
      var PROXY_URL = 'https://opauwtkivhjxlijfqaix.supabase.co/functions/v1/aliyun-proxy';
      var akId = (window.AliyunClient && AliyunClient.getCredentialsInfo) ? AliyunClient.getCredentialsInfo().accessKeyId : '';
      var akSecret = '';
      try {
        // 从 localStorage 拿 SK
        var u = (function(){ try { return JSON.parse(sessionStorage.getItem('wb_logged_in_v2') || localStorage.getItem('wb_logged_in_v2') || '{}').user || 'default'; } catch(e){ return 'default'; } })();
        var skKeyName = (u !== 'default' ? 'wb_' + u + '_ak_secret' : 'wb_default_ak_secret');
        akSecret = localStorage.getItem(skKeyName) || '';
        // 也尝试从 CloudStore 缓存拿
        if (!akSecret && window.CloudStore && CloudStore.getUserDataSync) {
          var ud = CloudStore.getUserDataSync(u);
          if (ud && ud.ak_secret) akSecret = ud.ak_secret;
        }
      } catch(e) { console.warn('[app.js] 读 SK 失败', e); }

      if (!akId || !akSecret) {
        throw new Error('请先设置阿里云 AK/SK 凭证');
      }

      var commodity = {
        PlanId: LOCKED_PLAN_ID,
        ImageId: imgPick.ImageId,   // ⚠️ 必须传 hash 格式 ImageId（不是 ImageName）
        Amount: order.count,
        Period: 1,
        PeriodUnit: 'Month',
        PayType: 'Prepaid',
        CommodityType: 'Server',
        AutoPay: false,  // 不自动支付 → 生成待支付订单
        AutoRenew: false,
        DataDiskSize: 0,
      };

      // 幂等令牌：同一 order 对象（同地区同数量同批次）永远用同一个 ClientToken，
      // 重试/复用同一 order 时不会重复下单；不同的 order 对象仍各自唯一（不会误吞合法新开批次）。
      if (!order._clientToken) {
        order._clientToken = 'wb-open-' + order.regionId + '-' + order.count + '-' + Date.now();
      }
      var clientToken = order._clientToken;

      // 🔄 重试：网络抖动 / Edge Function 偶发超时 / signal aborted 时自动重试
      var maxAttempts = 3;
      var lastError = null;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          if (attempt > 1) {
            log('⏳ ' + order.regionName + ' 第 ' + attempt + ' 次尝试...', 'warn');
          }
          var resp = await fetchWithTimeout(PROXY_URL, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              action: 'createOrder',
              ak_id: akId,
              ak_secret: akSecret,
              params: {
                RegionId: order.regionId,
                OrderType: 'Buy',
                Commodity: commodity,
                ClientToken: clientToken
              }
            })
          }, 120000); // 下单超时 60s→120s：深圳等慢地区一次过，减少重试等待
          // 🔧 v35 修复：用 resultJson 避免和外层 for 循环变量 j 冲突
          var resultJson = await resp.json();
          var response = resultJson.success ? resultJson.data : null;
          if (!resultJson.success) throw new Error(resultJson.error || '下单失败');

          if (response && response.OrderId) {
            log('✅ ' + order.regionName + ' 订单已创建：' + response.OrderId + '（' + order.count + ' 台，已生成待支付订单）', 'success');
            state.orderResults.push({
              region: order.regionName,
              regionId: order.regionId,
              count: order.count,
              orderId: response.OrderId,
              status: 'pending_payment',
              price: (order.count * ORDER_DEFAULT_PRICE).toFixed(2)
            });
            return; // 成功，跳出重试循环
          } else {
            throw new Error('API 返回异常：' + JSON.stringify(response).substring(0, 200));
          }
        } catch (attemptErr) {
          lastError = attemptErr;
          var retryable = /aborted|timeout|failed to fetch|network|超时|fetch|signal/i.test(attemptErr.message || '');
          if (!retryable || attempt === maxAttempts) {
            throw attemptErr; // 不可重试或已用尽次数，抛给外层
          }
          log('⚠️ ' + order.regionName + ' 第 ' + attempt + ' 次失败：' + attemptErr.message + '，2秒后重试...', 'warn');
          await new Promise(function(r){ setTimeout(r, 2000); });
        }
      }
    } catch (err) {
      log('❌ ' + order.regionName + ' 下单失败：' + err.message, 'error');
      state.orderResults.push({
        region: order.regionName,
        regionId: order.regionId,
        count: order.count,
        status: 'failed',
        error: err.message
      });
    }
  }

  // ⚡ 各地区一起并行下单（用户要求提速）
  // 保留 fetchWithTimeout(60s) + 3 次重试 + ClientToken 幂等，作为超时/抖动兜底
  log('🚀 ' + regionOrders.length + ' 个地区并行下单：' + regionOrders.map(function(o){ return o.regionName + '×' + o.count; }).join('、'), 'info');
  await Promise.all(regionOrders.map(function(order, idx){ return processOrder(order, idx); }));

  // 渲染订单结果
  renderOrderResults();

  // 阿里云控制台订单列表链接
  log('💡 所有订单已生成，可在阿里云控制台「订单管理 → 我的订单」中查看并支付', 'info');
  log('🔗 https://usercenter2.aliyun.com/order/list?orderType=UNPAID', 'info');
}

function renderOrderResults() {
  var listEl = document.getElementById('orderResultList');
  if (!listEl || !state.orderResults || state.orderResults.length === 0) return;

  var html = state.orderResults.map(function(r, idx) {
    if (r.status === 'pending_payment') {
      return '<div style="padding:12px;background:#fff7e6;border:1px solid #ffd591;border-radius:6px;margin-bottom:8px;">' +
        '<div style="display:flex;justify-content:space-between;align-items:center;">' +
          '<div><strong>📋 ' + r.region + ' · ' + r.count + ' 台</strong><br/>' +
          '<span style="font-size:12px;color:#666;">订单ID: ' + r.orderId + '</span><br/>' +
          '<span style="font-size:13px;color:#fa8c16;">💰 总价 ¥' + r.price + '/月</span></div>' +
          '<button class="btn btn-sm btn-primary" onclick="goToPay(\'' + r.orderId + '\')">💳 去支付</button>' +
        '</div></div>';
    } else {
      return '<div style="padding:12px;background:#fff1f0;border:1px solid #ffa39e;border-radius:6px;margin-bottom:8px;">' +
        '<strong>❌ ' + r.region + ' · ' + r.count + ' 台</strong><br/>' +
        '<span style="font-size:12px;color:#cf1322;">错误: ' + (r.error || '未知错误') + '</span></div>';
    }
  }).join('');

  listEl.innerHTML = html;
}

function goToPay(orderId) {
  // 跳转到阿里云订单详情页
  var url = 'https://usercenter2.aliyun.com/order/detail/' + orderId;
  window.open(url, '_blank');
}

// ====== 批量提升配额 ======
async function batchApplyQuota(desireValue) {
  desireValue = desireValue || 500;
  if (!AliyunClient.hasCredentials()) {
    log('❌ 未设置阿里云凭证，无法提交配额申请', 'error');
    showCredentialDialog();
    return;
  }

  var regionIds = Object.keys(REGION_INFO);
  log('📈 开始批量提升配额到 ' + desireValue + '，共 ' + regionIds.length + ' 个地区', 'info');

  var successCount = 0;
  var failCount = 0;
  var results = [];

  // Quota Center CreateQuotaApplication 流控约 4/s，地区间串行+250ms 间隔，避免触发限流
  for (var i = 0; i < regionIds.length; i++) {
    var rid = regionIds[i];
    var rname = REGION_INFO[rid];
    log('📍 [' + (i + 1) + '/' + regionIds.length + '] ' + rname + '：提交配额申请...', 'info');
    try {
      var res = await AliyunClient.createQuotaApplication(rid, desireValue, '业务扩展，需批量创建轻量应用服务器实例');
      successCount++;
      var appId = (res && res.ApplicationId) ? res.ApplicationId : (res && res.RequestId) ? res.RequestId : '-';
      results.push({ region: rname, regionId: rid, status: 'submitted', applicationId: appId, raw: res });
      log('   ✅ ' + rname + ' 申请已提交（ID: ' + appId + '）', 'success');
    } catch (err) {
      failCount++;
      var msg = (err && err.message) ? err.message : String(err);
      results.push({ region: rname, regionId: rid, status: 'failed', error: msg });
      log('   ❌ ' + rname + ' 提交失败：' + msg, 'error');
    }
    if (i < regionIds.length - 1) {
      await new Promise(function(r) { setTimeout(r, 250); });
    }
  }

  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('🏁 配额申请完成：成功 ' + successCount + ' 个地区，失败 ' + failCount + ' 个地区', failCount === 0 ? 'success' : 'warn');
  log('💡 审批通常约 5 分钟，可在阿里云控制台「配额中心 → 申请历史」查看结果', 'info');

  // 简单渲染结果到提额面板
  var listEl = document.getElementById('quotaRegionList');
  if (listEl) {
    var html = results.map(function(r) {
      if (r.status === 'submitted') {
        return '<div style="padding:10px;background:#f6ffed;border:1px solid #b7eb8f;border-radius:6px;margin-bottom:8px;">' +
          '<strong>✅ ' + r.region + '</strong> · 申请 ID: ' + escHtml(r.applicationId) + '</div>';
      } else {
        return '<div style="padding:10px;background:#fff1f0;border:1px solid #ffa39e;border-radius:6px;margin-bottom:8px;">' +
          '<strong>❌ ' + r.region + '</strong> · 失败: ' + escHtml(r.error) + '</div>';
      }
    }).join('');
    listEl.innerHTML = html || '<div class="empty-state">暂无结果</div>';
  }
}

function escHtml(s) {
  return String(s).replace(/[<>&"]/g, function(c) { return { '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]; });
}

// ====== 初始化 ======
async function init() {
  // 显示用户角色
  updateUserBadge();
  updateAdminUI();

  initOrderGrid();
  initScheduleTimePicker();
  checkConfirm();
  renderScheduledTasks();

  // 从云端预加载用户数据（凭证、AI 设置等）到本地缓存
  // 关键：换电脑时 localStorage 是空的，必须从云端拉取凭证
  if (window.CloudStore && currentUser && currentUser.user) {
    // 第一次尝试
    var cloudOK = false;
    try {
      var data = await CloudStore.preload(currentUser.user);
      cloudOK = !!(data && data.ak_id);
      console.log('[init] preload #1: cloudOK=' + cloudOK + ' has_ak=' + !!(data && data.ak_id));
    } catch(e) {
      console.warn('[init] preload #1 失败:', e.message);
    }

    // 如果第一次没拿到凭证，重试一次（forceReload 跳过缓存）
    if (!cloudOK) {
      log('🔄 正在从云端加载凭证...', 'info');
      try {
        var data2 = await CloudStore.forceReloadUserData(currentUser.user);
        cloudOK = !!(data2 && data2.ak_id);
        console.log('[init] preload #2 (force): cloudOK=' + cloudOK);
      } catch(e) {
        console.warn('[init] preload #2 失败:', e.message);
      }
    }

    // 第三次重试（延迟 1 秒）
    if (!cloudOK) {
      await new Promise(function(r) { setTimeout(r, 1000); });
      try {
        var data3 = await CloudStore.forceReloadUserData(currentUser.user);
        cloudOK = !!(data3 && data3.ak_id);
        console.log('[init] preload #3 (delayed): cloudOK=' + cloudOK);
      } catch(e) {
        console.warn('[init] preload #3 失败:', e.message);
      }
    }
  }

  // v6: 从云端拉取多凭证 profile（如果用户已经在其他设备保存过多凭证）
  try {
    if (window.AliyunClient && AliyunClient.pullProfilesFromCloud) {
      var syncRes = await AliyunClient.pullProfilesFromCloud();
      console.log('[init] pullProfilesFromCloud:', JSON.stringify(syncRes));
    }
  } catch(e) { console.warn('[init] pullProfilesFromCloud 失败:', e.message); }

  // 检查凭证（从 localStorage，已由 preload 同步；或从 CloudStore 缓存）
  state.hasCredentials = AliyunClient.hasCredentials();
  console.log('[init] hasCredentials=' + state.hasCredentials + ' user=' + (currentUser ? currentUser.user : 'null') + ' profiles=' + (AliyunClient.listProfiles ? AliyunClient.listProfiles().length : 0));
  updateCredentialBar();

  // 凭证就绪后，再次尝试布防 / 补跑定时退订
  checkAndRunScheduledRefund();

  log('✅ 页面初始化完成（云端版 v6.0 · 多凭证管理 · 下单走 Edge Function 代理 · 任意设备可登录）', 'success');

  if (state.hasCredentials) {
    await refreshAllRegions();
  } else {
    log('⚠️ 未能从云端加载凭证，请手动设置（设置后自动同步到云端，下次换电脑自动加载）', 'warn');
    showCredentialDialog();
  }

}

document.addEventListener('DOMContentLoaded', init);

// 监听定时退订输入
document.addEventListener('DOMContentLoaded', function() {
  var hourEl = document.getElementById('scheduleHour');
  var minuteEl = document.getElementById('scheduleMinute');
  if (hourEl) hourEl.addEventListener('change', checkConfirm);
  if (minuteEl) minuteEl.addEventListener('change', checkConfirm);
});

// 切回前台 / 恢复联网时，补跑可能漏掉的定时退订
document.addEventListener('visibilitychange', function() {
  if (document.visibilityState === 'visible') checkAndRunScheduledRefund();
});
window.addEventListener('online', function() { checkAndRunScheduledRefund(); });

// ==================== AI 助手 ====================

var aiState = {
  open: false,
  loading: false,
  useFastModel: false,
  history: [],
  abortController: null,
  totalTokens: 0,
  modelMenuOpen: false,
  apiBase: 'https://api.zhouyitoken.com/v1',
  apiKey: 'sk-oYx7JC9whjoGXe6woTFu4npX9yxDiMRl04BjFOIZuszOuzF5'
};

// 初始化：从 localStorage 加载 AI 设置（按用户隔离）
(function() {
  try {
    var pfx = getUserPrefix();
    var saved = localStorage.getItem(pfx + 'ai_settings');
    if (saved) {
      var s = JSON.parse(saved);
      if (s.apiBase) aiState.apiBase = s.apiBase;
      if (s.apiKey) aiState.apiKey = s.apiKey;
      if (s.defaultModel === 'haiku') aiState.useFastModel = true;
    }
    // 加载累计 token
    var tok = localStorage.getItem(pfx + 'ai_tokens');
    if (tok) aiState.totalTokens = parseInt(tok) || 0;
  } catch(e) {}
  updateAIModelUI();
})();

function updateAIModelUI() {
  var badge = document.getElementById('aiRelayBadge');
  var name = document.getElementById('aiModelName');
  var count = document.getElementById('aiTokenCount');
  if (name) name.textContent = aiState.useFastModel ? 'Haiku' : 'Sonnet';
  if (badge) badge.textContent = '🟢 中转站';
  if (count) {
    if (aiState.totalTokens > 0) {
      count.style.display = 'inline';
      count.textContent = formatTokens(aiState.totalTokens);
    } else {
      count.style.display = 'none';
    }
  }
}

function formatTokens(n) {
  if (n < 1000) return n + ' tokens';
  if (n < 1000000) return (n/1000).toFixed(1) + 'K tokens';
  return (n/1000000).toFixed(1) + 'M tokens';
}

function toggleAIChat() {
  aiState.open = !aiState.open;
  var panel = document.getElementById('aiChatPanel');
  var fab = document.getElementById('aiFab');
  var menu = document.getElementById('aiModelMenu');
  if (aiState.open) {
    panel.style.display = 'flex';
    fab.classList.add('ai-fab-hidden');
    document.getElementById('aiChatInput').focus();
  } else {
    panel.style.display = 'none';
    fab.classList.remove('ai-fab-hidden');
    if (menu) menu.style.display = 'none';
    aiState.modelMenuOpen = false;
  }
}

function toggleAIModelMenu() {
  aiState.modelMenuOpen = !aiState.modelMenuOpen;
  var menu = document.getElementById('aiModelMenu');
  if (menu) menu.style.display = aiState.modelMenuOpen ? 'block' : 'none';
}

function selectAIModel(model) {
  aiState.useFastModel = (model === 'haiku');
  aiState.modelMenuOpen = false;
  var menu = document.getElementById('aiModelMenu');
  if (menu) menu.style.display = 'none';

  // 更新选项状态
  var opts = menu ? menu.querySelectorAll('.ai-model-option') : [];
  opts.forEach(function(o) {
    o.classList.toggle('active', o.dataset.model === model);
  });

  updateAIModelUI();
  addAILog('info', '已切换为 ' + (model === 'haiku' ? 'Haiku（快速模式）' : 'Sonnet（智能模式）'));
}

function showAIKeyDialog() {
  var modal = document.getElementById('aiKeyModal');
  if (!modal) return;
  document.getElementById('aiApiBase').value = aiState.apiBase;
  document.getElementById('aiApiKey').value = aiState.apiKey;
  document.getElementById('aiDefaultModel').value = aiState.useFastModel
    ? 'claude-haiku-4-5-20251001'
    : 'claude-sonnet-4-5-20250929';
  modal.style.display = 'flex';
}

function hideAIKeyDialog() {
  var modal = document.getElementById('aiKeyModal');
  if (modal) modal.style.display = 'none';
}

function saveAIKey() {
  aiState.apiBase = document.getElementById('aiApiBase').value.trim();
  aiState.apiKey = document.getElementById('aiApiKey').value.trim();
  var model = document.getElementById('aiDefaultModel').value;
  aiState.useFastModel = model.includes('haiku');

  // 保存到 localStorage（按用户隔离）
  try {
    localStorage.setItem(getUserPrefix() + 'ai_settings', JSON.stringify({
      apiBase: aiState.apiBase,
      apiKey: aiState.apiKey,
      defaultModel: aiState.useFastModel ? 'haiku' : 'sonnet'
    }));
  } catch(e) {}

  // 同步到云端
  if (window.CloudStore && currentUser && currentUser.user) {
    CloudStore.updateUserData(currentUser.user, {
      ai_settings: { apiBase: aiState.apiBase, apiKey: aiState.apiKey, defaultModel: aiState.useFastModel ? 'haiku' : 'sonnet' },
      ai_tokens: aiState.totalTokens
    });
  }

  // 同步到 AIClient
  if (window.AIClient && aiState.apiKey) {
    AIClient.setKey(aiState.apiKey);
    AIClient.setBase(aiState.apiBase);
  }

  updateAIModelUI();
  hideAIKeyDialog();
  addAILog('success', '中转站设置已保存');
}

function clearAIChat() {
  aiState.history = [];
  var container = document.getElementById('aiChatMessages');
  container.innerHTML = '<div class="ai-msg ai-msg-bot"><div class="ai-msg-avatar">🤖</div><div class="ai-msg-bubble">🟢 <b>中转站模式</b> · 对话已清空<br>有什么可以帮你的？</div></div>';
}

function addAILog(type, text) {
  if (typeof addLog === 'function') {
    addLog(type, '[AI] ' + text);
  }
}

function buildAIContext() {
  var ctx = [];
  ctx.push('当前用户: ' + (currentUser && currentUser.user ? currentUser.user : '未知'));
  ctx.push('');

  var allInstances = [];
  if (state.regionData) {
    Object.keys(state.regionData).forEach(function(rid) {
      var r = state.regionData[rid];
      if (r && r.instances) {
        r.instances.forEach(function(inst) {
          allInstances.push({
            region: r.name || rid,
            name: inst.InstanceName || inst.InstanceId,
            id: inst.InstanceId,
            status: inst.Status || inst.InstanceState,
            plan: inst.PlanId,
            publicIp: inst.PublicAddress || '无',
            expired: inst.ExpiredTime || '未知'
          });
        });
      }
    });
  }

  if (allInstances.length > 0) {
    ctx.push('当前管理云主机共 ' + allInstances.length + ' 台：');
    allInstances.forEach(function(inst, i) {
      ctx.push((i+1) + '. ' + inst.name + ' [' + inst.region + '] ' + inst.status + ' IP:' + inst.publicIp + ' 到期:' + inst.expired);
    });
  } else {
    ctx.push('当前未加载实例数据（可能凭证未设置或未刷新地域）。');
  }

  ctx.push('');
  ctx.push('用户可能问的问题包括：分析实例配置、推荐防火墙规则、生成运维命令、评估退订风险、成本优化等。请用中文简洁回答。');

  return ctx.join('\n');
}

function sendAIMessage() {
  var input = document.getElementById('aiChatInput');
  var text = input.value.trim();
  if (!text || aiState.loading) return;

  input.value = '';
  input.style.height = 'auto';

  appendAIMessage('user', text);
  aiState.history.push({ role: 'user', content: text });

  aiState.loading = true;
  var loadingId = appendAILoading();

  var systemPrompt = '你是阿里云轻量应用服务器（SWAS）管理助手。你帮助用户管理云主机实例，包括：防火墙配置、命令执行、实例退订、批量下单等。\n\n以下是当前工作台状态：\n' + buildAIContext();

  var messages = [{ role: 'system', content: systemPrompt }];
  var recentHistory = aiState.history.slice(-20);
  messages = messages.concat(recentHistory);

  aiState.abortController = new AbortController();

  // 使用 AIClient，自动使用中转站 API
  var apiBase = aiState.apiBase;
  var apiKey = aiState.apiKey;
  var useFast = aiState.useFastModel;

  // 确保 AIClient 使用正确的设置
  if (window.AIClient) {
    if (apiKey) AIClient.setKey(apiKey);
  }

  window.AIClient.chatStream(messages, function(chunk) {
    if (chunk.done) {
      aiState.loading = false;
      removeAILoading(loadingId);
      if (chunk.content) {
        aiState.history.push({ role: 'assistant', content: chunk.content });
        // 累计 token（如果返回了 usage）
        if (chunk.usage && chunk.usage.total_tokens) {
          aiState.totalTokens += chunk.usage.total_tokens;
          try { localStorage.setItem(getUserPrefix() + 'ai_tokens', aiState.totalTokens); } catch(e) {}
          // 同步 token 到云端
          if (window.CloudStore && currentUser && currentUser.user) {
            CloudStore.updateUserData(currentUser.user, { ai_tokens: aiState.totalTokens });
          }
          updateAIModelUI();
        }
      }
      aiState.abortController = null;
      document.getElementById('aiChatInput').focus();
    } else {
      updateAILoading(loadingId, chunk.full);
    }
  }, {
    fast: useFast,
    signal: aiState.abortController.signal
  }).catch(function(err) {
    aiState.loading = false;
    removeAILoading(loadingId);
    aiState.abortController = null;
    if (err.name !== 'AbortError') {
      appendAIMessage('bot', '❌ 请求失败: ' + (err.message || '网络错误') + '\n\n💡 提示：请检查中转站设置（点击 ⚙️）');
      addAILog('error', '调用失败: ' + err.message);
    }
  });

  addAILog('info', '发送问题: ' + text.substring(0, 50));
}

function handleAIInputKey(e) {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendAIMessage();
  }
  setTimeout(function() {
    var input = document.getElementById('aiChatInput');
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 120) + 'px';
  }, 0);
}

function appendAIMessage(role, content) {
  var container = document.getElementById('aiChatMessages');
  var isBot = role === 'bot' || role === 'assistant';
  var div = document.createElement('div');
  div.className = 'ai-msg ' + (isBot ? 'ai-msg-bot' : 'ai-msg-user');
  div.innerHTML = '<div class="ai-msg-avatar">' + (isBot ? '🤖' : '👤') + '</div><div class="ai-msg-bubble">' + escapeHtml(content) + '</div>';
  container.appendChild(div);
  container.scrollTop = container.scrollHeight;
}

function appendAILoading() {
  var container = document.getElementById('aiChatMessages');
  var id = 'ai-loading-' + Date.now();
  var div = document.createElement('div');
  div.id = id;
  div.className = 'ai-msg ai-msg-bot';
  div.innerHTML = '<div class="ai-msg-avatar">🤖</div><div class="ai-msg-bubble ai-loading"><span class="ai-dot"></span><span class="ai-dot"></span><span class="ai-dot"></span></div>';
  container.appendChild(div);
  container.scrollTop = container.scrollHeight;
  return id;
}

function updateAILoading(id, content) {
  var el = document.getElementById(id);
  if (!el) return;
  var bubble = el.querySelector('.ai-msg-bubble');
  if (bubble) {
    bubble.className = 'ai-msg-bubble';
    bubble.textContent = content;
  }
  var container = document.getElementById('aiChatMessages');
  container.scrollTop = container.scrollHeight;
}

function removeAILoading(id) {
  var el = document.getElementById(id);
  if (el) el.remove();
}

function escapeHtml(text) {
  var div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML.replace(/\n/g, '<br>');
}

// 点击面板外部关闭
document.addEventListener('click', function(e) {
  if (!aiState.open) return;
  var panel = document.getElementById('aiChatPanel');
  var fab = document.getElementById('aiFab');
  var menu = document.getElementById('aiModelMenu');
  if (panel && fab && !panel.contains(e.target) && !fab.contains(e.target)) {
    toggleAIChat();
  }
  // 关闭模型菜单
  if (aiState.modelMenuOpen && menu && !menu.contains(e.target) && e.target.id !== 'aiModelBtn') {
    aiState.modelMenuOpen = false;
    menu.style.display = 'none';
  }
});

// ====== 自定义命令（一次性输入，对所有地域的全部云主机执行，不保存） ======

function openCustomCommandModal() {
  var modal = document.getElementById('customCommandModal');
  if (modal) modal.style.display = 'flex';
}

function closeCustomCommandModal() {
  var modal = document.getElementById('customCommandModal');
  if (modal) modal.style.display = 'none';
  // 清空命令内容（不保存命令，按需求"每次输入不一样"）
  var contentEl = document.getElementById('ccContent');
  if (contentEl) contentEl.value = '';
}

async function executeCustomCommandToAllRegions() {
  var typeEl = document.querySelector('input[name="ccType"]:checked');
  var nameEl = document.getElementById('ccName');
  var contentEl = document.getElementById('ccContent');
  var dirEl = document.getElementById('ccWorkingDir');
  var timeoutEl = document.getElementById('ccTimeout');
  var btn = document.getElementById('ccExecuteBtn');

  var type = typeEl ? typeEl.value : 'RunShellScript';
  var name = nameEl ? nameEl.value.trim() : '';
  var content = contentEl ? contentEl.value : '';
  var workingDir = dirEl ? dirEl.value.trim() : '/root';
  var timeout = timeoutEl ? parseInt(timeoutEl.value, 10) : 60;

  if (!content || !content.trim()) {
    log('❌ 命令内容不能为空', 'error');
    return;
  }
  if (isNaN(timeout) || timeout < 10 || timeout > 86400) {
    log('❌ 超时时间必须在 10~86400 秒之间', 'error');
    return;
  }

  // 命令名不填就给个默认（仅用于日志）
  var finalName = name || ('custom-' + new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19));

  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('✏️ 开始执行自定义命令: [' + finalName + '] type=' + type + ' 6个地域全部云主机', 'info');
  log('   命令内容（共 ' + content.length + ' 字符）：\n' + content, 'info');

  // 检查凭证
  if (!AliyunClient.hasCredentials()) {
    log('❌ 缺少阿里云 AK/SK 凭证，请先在右上角设置', 'error');
    return;
  }

  // 锁按钮，防止重复点
  if (btn) { btn.disabled = true; btn.textContent = '⏳ 执行中…'; }

  // 立即关闭弹窗，避免挡住操作日志
  closeCustomCommandModal();

  // 1) 加载 6 个地域的全部实例（只调用 listInstances，运维类 API 走地域 endpoint 不需要代理）
  var regionIds = Object.keys(REGION_INFO);
  log('🔄 加载 6 个地域的实例…', 'info');
  if (!state.regionData) state.regionData = {};

  await Promise.all(regionIds.map(function(rid) {
    return AliyunClient.listInstances(rid, { pageSize: 100 }).then(function(data) {
      if (!state.regionData[rid]) state.regionData[rid] = { name: REGION_INFO[rid], totalCount: 0, error: null, instances: [] };
      var allInsts = data.Instances || [];
      // 如果有更多页，继续翻
      var total = data.TotalCount || allInsts.length;
      var pages = Math.ceil(total / 100);
      if (pages <= 1) {
        state.regionData[rid].instances = allInsts;
        state.regionData[rid].totalCount = total;
      } else {
        // 多页：这里为简化直接拉取每页
        var chain = Promise.resolve(allInsts);
        for (var p = 2; p <= pages; p++) {
          (function(pn) {
            chain = chain.then(function(arr) {
              return AliyunClient.listInstances(rid, { pageSize: 100, pageNumber: pn }).then(function(d2) {
                return arr.concat(d2.Instances || []);
              });
            });
          })(p);
        }
        return chain.then(function(full) {
          state.regionData[rid].instances = full;
          state.regionData[rid].totalCount = total;
        });
      }
    }).catch(function(err) {
      if (!state.regionData[rid]) state.regionData[rid] = { name: REGION_INFO[rid], totalCount: 0, error: null, instances: [] };
      state.regionData[rid].instances = [];
      log('⚠️ 加载 [' + REGION_INFO[rid] + '] 实例失败: ' + (err.message || err), 'warn');
    });
  }));

  // 统计总实例
  var grandTotal = 0;
  var summaryLines = [];
  regionIds.forEach(function(rid) {
    var rd = state.regionData[rid] || {};
    var n = (rd.instances || []).length;
    grandTotal += n;
    if (n > 0) summaryLines.push('  ' + REGION_INFO[rid] + ': ' + n + ' 台');
  });
  log('📊 待执行: ' + grandTotal + ' 台', 'info');
  summaryLines.forEach(function(l) { log(l, 'info'); });

  if (grandTotal === 0) {
    log('⚠️ 没有找到任何实例', 'warn');
    if (btn) { btn.disabled = false; btn.textContent = '🚀 执行到全部地域'; }
    return;
  }

  // 2) 对每个地域的实例批量执行自定义命令
  //    【优化】SWAS InvokeCommand 单次支持最多 100 台：每批 100 台只发 1 次请求，
  //    把 600 台从 600 次请求降到 ~6 次/地域，从根上规避 QPS 限流。
  var opts = {
    type: type,
    name: finalName,
    content: content,
    workingDir: workingDir,
    timeout: timeout
  };

  var BATCH_SIZE = 100;        // SWAS InvokeCommand 单次最多 100 台（一次请求覆盖整批）
  var BATCH_DELAY = 400;       // 批间间隔 ms（保守，进一步降 QPS）
  var FALLBACK_BATCH = 20;     // 整批失败时的降级批大小（逐台重试，避免再次限流）
  var totalSuccess = 0, totalFail = 0, totalInvokeIds = [];

  await Promise.all(regionIds.map(async function(rid) {
    var rd = state.regionData[rid];
    var instances = (rd && rd.instances) || [];
    if (instances.length === 0) { log('⚠️ [' + REGION_INFO[rid] + '] 无实例，跳过', 'warn'); return; }

    var batchCount = Math.ceil(instances.length / BATCH_SIZE);
    log('🔄 [' + REGION_INFO[rid] + '] 开始执行 ' + instances.length + ' 台（自动分 ' + batchCount + ' 批，每批最多 ' + BATCH_SIZE + ' 台，单次请求下发）…', 'info');

    // 每 BATCH_SIZE 台一次批量 InvokeCommand（1 次请求覆盖整批）
    for (var i = 0; i < instances.length; i += BATCH_SIZE) {
      var batchIdx = Math.floor(i / BATCH_SIZE) + 1;
      var slice = instances.slice(i, i + BATCH_SIZE);
      var ids = slice.map(function(inst) { return inst.InstanceId; });

      try {
        var data = await AliyunClient.runCommandOnInstance(rid, ids, opts);
        totalSuccess += slice.length;
        var invId = data && data.InvokeId ? data.InvokeId : null;
        if (invId) totalInvokeIds.push(invId);
        if (batchCount > 1) log('   ✅ [' + REGION_INFO[rid] + '] 第 ' + batchIdx + '/' + batchCount + ' 批：' + slice.length + ' 台下发成功（InvokeId ' + invId + '）', 'info');
      } catch (err) {
        // 整批失败（极少数，多为个别实例 ID 异常）→ 降级逐台重试，最大限度保证成功
        log('   ⚠️ [' + REGION_INFO[rid] + '] 第 ' + batchIdx + ' 批整批失败，降级逐台重试：' + (err.message || err), 'warn');
        for (var j = 0; j < slice.length; j += FALLBACK_BATCH) {
          var sub = slice.slice(j, j + FALLBACK_BATCH);
          var subRs = await Promise.all(sub.map(function(inst) {
            return AliyunClient.runCommandOnInstance(rid, [inst.InstanceId], opts).then(function() {
              return { ok: true, instanceId: inst.InstanceId };
            }).catch(function(e) {
              return { ok: false, err: (e && e.message) || String(e), instanceId: inst.InstanceId };
            });
          }));
          subRs.forEach(function(r) {
            if (r.ok) { totalSuccess++; }
            else { totalFail++; log('  ❌ [' + REGION_INFO[rid] + '] ' + r.instanceId + ' 失败: ' + r.err, 'error'); }
          });
        }
      }
      // 批间停顿，避免限流
      if (i + BATCH_SIZE < instances.length) await new Promise(function(r) { setTimeout(r, BATCH_DELAY); });
    }
    log('✅ [' + REGION_INFO[rid] + '] ' + instances.length + ' 台下发完成', 'success');
  }));

  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('📊 自定义命令执行完成: 成功 ' + totalSuccess + ' 台，失败 ' + totalFail + ' 台', totalFail === 0 ? 'success' : 'warn');
  if (totalInvokeIds.length > 0) log('📋 InvokeId 示例: ' + totalInvokeIds.slice(0, 3).join(', ') + (totalInvokeIds.length > 3 ? ' …' : ''), 'info');
  log('💡 提示：执行结果可在阿里云控制台「服务器运维 → 命令助手 → 执行历史」查看每台机器的输出', 'info');

  if (btn) { btn.disabled = false; btn.textContent = '🚀 执行到全部地域'; }
  // 关掉弹窗（不清空命令内容，让用户看到刚执行的内容）
  closeCustomCommandModal();
}

// =====================================================================
// 批量创建命令模板
// =====================================================================
function openCreateCommandModal() {
  var modal = document.getElementById('createCommandModal');
  if (modal) { modal.style.display = 'flex'; initCrCmdRegionCheckboxes(); }
}
function closeCreateCommandModal() {
  var modal = document.getElementById('createCommandModal');
  if (modal) modal.style.display = 'none';
}
function initCrCmdRegionCheckboxes() {
  var container = document.getElementById('crCmdRegionCheckboxes');
  if (!container) return;
  var regionIds = Object.keys(REGION_INFO);
  container.innerHTML = regionIds.map(function(rid) {
    return '<label style="cursor:pointer; font-size:13px;"><input type="checkbox" name="crCmdRegion" value="' + rid + '" checked> ' + REGION_INFO[rid] + '</label>';
  }).join('');
}
function selectAllCrCmdRegions() {
  var cbs = document.querySelectorAll('input[name="crCmdRegion"]');
  for (var i = 0; i < cbs.length; i++) cbs[i].checked = true;
}
function deselectAllCrCmdRegions() {
  var cbs = document.querySelectorAll('input[name="crCmdRegion"]');
  for (var i = 0; i < cbs.length; i++) cbs[i].checked = false;
}
async function batchCreateCommands() {
  var name = document.getElementById('crCmdName').value.trim();
  var typeEl = document.querySelector('input[name="crCmdType"]:checked');
  var type = typeEl ? typeEl.value : 'RunShellScript';
  var content = document.getElementById('crCmdContent').value;
  var desc = document.getElementById('crCmdDesc').value.trim();
  var workingDir = document.getElementById('crCmdWorkingDir').value.trim() || '/root';
  var timeout = parseInt(document.getElementById('crCmdTimeout').value, 10) || 60;
  var btn = document.getElementById('crCmdExecuteBtn');

  if (!name) { log('❌ 命令名称不能为空', 'error'); return; }
  if (!content || !content.trim()) { log('❌ 命令内容不能为空', 'error'); return; }
  if (isNaN(timeout) || timeout < 10 || timeout > 86400) { log('❌ 超时时间必须在 10~86400 秒之间', 'error'); return; }

  var selectedRegions = [];
  var cbs = document.querySelectorAll('input[name="crCmdRegion"]:checked');
  for (var i = 0; i < cbs.length; i++) selectedRegions.push(cbs[i].value);
  if (selectedRegions.length === 0) { log('❌ 请至少选择一个目标地域', 'error'); return; }
  if (!AliyunClient.hasCredentials()) { log('❌ 请先设置阿里云凭证', 'error'); return; }

  if (btn) { btn.disabled = true; btn.textContent = '⏳ 创建中…'; }
  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('📝 批量创建命令: [' + name + '] type=' + type + ' 共 ' + selectedRegions.length + ' 个地域', 'info');

  var totalSuccess = 0, totalFail = 0;
  var createParams = { name: name, type: type, content: content, description: desc, workingDir: workingDir, timeout: timeout };

  for (var j = 0; j < selectedRegions.length; j++) {
    var rid = selectedRegions[j];
    try {
      var result = await AliyunClient.createCommand(rid, createParams);
      totalSuccess++;
      log('  ✅ [' + REGION_INFO[rid] + '] 创建成功 → CommandId=' + (result.CommandId || 'OK'), 'success');
    } catch (err) {
      totalFail++;
      log('  ❌ [' + REGION_INFO[rid] + '] 创建失败: ' + (err.message || err), 'error');
    }
    if (j < selectedRegions.length - 1) await new Promise(function(r) { setTimeout(r, 200); });
  }
  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('📊 批量创建完成: 成功 ' + totalSuccess + ', 失败 ' + totalFail, totalFail === 0 ? 'success' : 'warn');
  log('💡 提示：创建成功后请点击「同步阿里云命令」刷新列表', 'info');
  if (btn) { btn.disabled = false; btn.textContent = '🚀 批量创建命令'; }
  closeCreateCommandModal();
}

// =====================================================================
// 批量删除命令模板
// =====================================================================
var _delCmdState = { commands: {}, selected: {} };
function openDeleteCommandModal() { document.getElementById('deleteCommandModal').style.display = 'flex'; }
function closeDeleteCommandModal() { document.getElementById('deleteCommandModal').style.display = 'none'; _delCmdState = { commands: {}, selected: {} }; }

async function loadDeleteCommandList() {
  var regionIds = Object.keys(REGION_INFO);
  log('🔄 加载所有地域命令列表...', 'info');
  _delCmdState = { commands: {}, selected: {} };
  var container = document.getElementById('delCmdListContainer');
  container.innerHTML = '<p style="color:#999; text-align:center; padding:20px;">⏳ 加载中...</p>';

  for (var i = 0; i < regionIds.length; i++) {
    var rid = regionIds[i];
    try {
      var data = await AliyunClient.listCommands(rid);
      _delCmdState.commands[rid] = (data.Commands || []).map(function(c) {
        return { commandId: c.CommandId, name: c.Name || c.CommandId, type: c.Type || 'Shell' };
      });
    } catch (err) {
      _delCmdState.commands[rid] = [];
      log('⚠️ [' + REGION_INFO[rid] + '] 加载失败: ' + err.message, 'warn');
    }
    if (i < regionIds.length - 1) await new Promise(function(r) { setTimeout(r, 200); });
  }
  renderDeleteCommandList();
  log('✅ 命令列表加载完成', 'success');
}

function renderDeleteCommandList() {
  var container = document.getElementById('delCmdListContainer');
  var regionIds = Object.keys(REGION_INFO);
  var html = '', totalCount = 0;
  for (var i = 0; i < regionIds.length; i++) {
    var rid = regionIds[i];
    var cmds = _delCmdState.commands[rid] || [];
    totalCount += cmds.length;
    if (cmds.length === 0) continue;
    html += '<div style="margin-bottom:10px;"><strong style="color:' + (REGION_COLORS[rid] || '#333') + ';">' + REGION_INFO[rid] + ' (' + cmds.length + ' 条)</strong></div>';
    for (var j = 0; j < cmds.length; j++) {
      var c = cmds[j];
      var checked = _delCmdState.selected[c.commandId] ? 'checked' : '';
      html += '<label style="display:flex; align-items:center; gap:8px; padding:5px 8px; cursor:pointer; font-size:13px; border-bottom:1px solid #f0f0f0;">' +
        '<input type="checkbox" ' + checked + ' onchange="toggleDelCmdSelect(\'' + c.commandId + '\')"> ' +
        c.name + ' <span style="color:#999; font-size:11px;">(' + c.type + ')</span></label>';
    }
  }
  if (totalCount === 0) html = '<p style="color:#999; text-align:center; padding:20px;">所有地域均无命令模板</p>';
  container.innerHTML = html;
  updateDelCmdBtn();
}

function toggleDelCmdSelect(commandId) {
  if (_delCmdState.selected[commandId]) delete _delCmdState.selected[commandId];
  else _delCmdState.selected[commandId] = true;
  updateDelCmdBtn();
}

function updateDelCmdBtn() {
  var btn = document.getElementById('delCmdBtn');
  var count = Object.keys(_delCmdState.selected).length;
  if (btn) { btn.disabled = count === 0; btn.textContent = count > 0 ? ('🗑️ 删除选中命令 (' + count + ')') : '🗑️ 删除选中命令'; }
}

async function batchDeleteCommands() {
  var selectedIds = Object.keys(_delCmdState.selected);
  if (selectedIds.length === 0) return;
  if (!confirm('确定删除 ' + selectedIds.length + ' 条命令模板？此操作不可恢复！')) return;

  var byRegion = {};
  for (var rid in _delCmdState.commands) {
    var cmds = _delCmdState.commands[rid];
    for (var i = 0; i < cmds.length; i++) {
      if (_delCmdState.selected[cmds[i].commandId]) {
        if (!byRegion[rid]) byRegion[rid] = [];
        byRegion[rid].push(cmds[i].commandId);
      }
    }
  }
  var btn = document.getElementById('delCmdBtn');
  if (btn) { btn.disabled = true; btn.textContent = '⏳ 删除中…'; }

  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('🗑️ 批量删除命令: ' + selectedIds.length + ' 条', 'info');
  var totalSuccess = 0, totalFail = 0;
  for (var rid2 in byRegion) {
    var ids = byRegion[rid2];
    for (var j = 0; j < ids.length; j++) {
      try {
        await AliyunClient.deleteCommand(rid2, ids[j]);
        totalSuccess++;
        log('  ✅ [' + REGION_INFO[rid2] + '] 已删除: ' + ids[j], 'success');
      } catch (err) {
        totalFail++;
        log('  ❌ [' + REGION_INFO[rid2] + '] 删除失败: ' + ids[j] + ' - ' + (err.message || err), 'error');
      }
      await new Promise(function(r) { setTimeout(r, 100); });
    }
  }
  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('📊 批量删除完成: 成功 ' + totalSuccess + ', 失败 ' + totalFail, totalFail === 0 ? 'success' : 'warn');
  await loadDeleteCommandList();
  await loadAllRegionCommands();
}

// 一键删除所有地域的全部命令模板
async function deleteAllCommands() {
  // 如果尚未加载命令，先同步一次
  var hasLoaded = state.regionCommands && Object.keys(state.regionCommands).length > 0;
  var regionIds = Object.keys(REGION_INFO);
  if (!hasLoaded) {
    log('🔄 尚未加载命令列表，先同步阿里云命令...', 'info');
    await loadAllRegionCommands();
  }

  var allCommands = [];
  for (var i = 0; i < regionIds.length; i++) {
    var rid = regionIds[i];
    var cmds = (state.regionCommands && state.regionCommands[rid]) || [];
    for (var j = 0; j < cmds.length; j++) {
      allCommands.push({ regionId: rid, commandId: cmds[j].commandId, name: cmds[j].name });
    }
  }

  if (allCommands.length === 0) {
    log('❌ 当前没有任何可删除的命令模板', 'error');
    return;
  }

  if (!confirm('⚠️ 危险操作！\n\n确定要一键删除所有地域共 ' + allCommands.length + ' 条命令模板吗？\n此操作不可恢复！')) {
    return;
  }

  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('🗑️ 一键删除所有命令: 共 ' + allCommands.length + ' 条', 'info');

  var totalSuccess = 0, totalFail = 0;
  for (var k = 0; k < allCommands.length; k++) {
    var item = allCommands[k];
    try {
      await AliyunClient.deleteCommand(item.regionId, item.commandId);
      totalSuccess++;
      log('  ✅ [' + REGION_INFO[item.regionId] + '] 已删除: ' + (item.name || item.commandId), 'success');
    } catch (err) {
      totalFail++;
      log('  ❌ [' + REGION_INFO[item.regionId] + '] 删除失败: ' + (item.name || item.commandId) + ' - ' + (err.message || err), 'error');
    }
    if (k < allCommands.length - 1) await new Promise(function(r) { setTimeout(r, 100); });
  }

  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('📊 一键删除完成: 成功 ' + totalSuccess + ', 失败 ' + totalFail, totalFail === 0 ? 'success' : 'warn');

  // 刷新本地命令列表与UI
  state.regionCommands = {};
  updateCmdRegionGrid();
  log('💡 已清空本地命令缓存，如需更新请重新点击「同步阿里云命令」', 'info');
}

// =====================================================================
// 批量创建防火墙模板
// =====================================================================
var _fwRuleCounter = 0;
function openCreateFirewallModal() {
  var modal = document.getElementById('createFirewallModal');
  if (modal) { modal.style.display = 'flex'; _fwRuleCounter = 0; document.getElementById('createFwName').value = ''; document.getElementById('createFwDesc').value = ''; document.getElementById('createFwRulesContainer').innerHTML = ''; addFwRuleRow(); initCreateFwRegionCheckboxes(); }
}
function closeCreateFirewallModal() { document.getElementById('createFirewallModal').style.display = 'none'; }
function initCreateFwRegionCheckboxes() {
  var container = document.getElementById('createFwRegionCheckboxes');
  if (!container) return;
  var regionIds = Object.keys(REGION_INFO);
  container.innerHTML = regionIds.map(function(rid) {
    return '<label style="cursor:pointer; font-size:13px;"><input type="checkbox" name="createFwRegion" value="' + rid + '" checked> ' + REGION_INFO[rid] + '</label>';
  }).join('');
}
function selectAllCreateFwRegions() {
  var cbs = document.querySelectorAll('input[name="createFwRegion"]');
  for (var i = 0; i < cbs.length; i++) cbs[i].checked = true;
}
function deselectAllCreateFwRegions() {
  var cbs = document.querySelectorAll('input[name="createFwRegion"]');
  for (var i = 0; i < cbs.length; i++) cbs[i].checked = false;
}
function addFwRuleRow() {
  _fwRuleCounter++;
  var container = document.getElementById('createFwRulesContainer');
  var row = document.createElement('div');
  row.className = 'firewall-rule-row';
  row.id = 'fwRuleRow' + _fwRuleCounter;
  row.innerHTML =     '<select data-field="protocol" style="padding:6px; border:1px solid #ccc; border-radius:4px; min-width:80px;">' +
    '<option value="TCP">TCP</option><option value="UDP">UDP</option><option value="TCP+UDP" selected>TCP+UDP</option><option value="ICMP">ICMP</option>' +
    '</select>' +
    '<input type="text" data-field="port" placeholder="端口 (如 80 或 1-65535)" value="1/65535" style="flex:1; min-width:140px; padding:6px; border:1px solid #ccc; border-radius:4px;">' +
    '<input type="text" data-field="cidr" placeholder="来源CIDR" value="0.0.0.0/0" style="flex:1; min-width:120px; padding:6px; border:1px solid #ccc; border-radius:4px;">' +
    '<input type="text" data-field="remark" placeholder="备注" value="全部TCP+UDP" style="flex:1; min-width:80px; padding:6px; border:1px solid #ccc; border-radius:4px;">' +
    '<button class="btn btn-danger" onclick="removeFwRuleRow(\'fwRuleRow' + _fwRuleCounter + '\')" style="font-size:12px; padding:4px 8px;">✕</button>';
  row.style.display = 'flex';
  row.style.gap = '6px';
  row.style.alignItems = 'center';
  row.style.marginBottom = '6px';
  container.appendChild(row);
}
function removeFwRuleRow(rowId) { var row = document.getElementById(rowId); if (row) row.remove(); }
function collectFwRulesFromUI() {
  var rows = document.querySelectorAll('#createFwRulesContainer .firewall-rule-row');
  var rules = [];
  for (var i = 0; i < rows.length; i++) {
    var protocol = rows[i].querySelector('[data-field="protocol"]').value;
    var port = rows[i].querySelector('[data-field="port"]').value.trim();
    var cidr = rows[i].querySelector('[data-field="cidr"]').value.trim();
    var remark = rows[i].querySelector('[data-field="remark"]').value.trim();
    if (!port) continue;
    rules.push({ RuleProtocol: protocol, Port: port, SourceCidrIp: cidr || '0.0.0.0/0', Remark: remark || '' });
  }
  return rules;
}
async function batchCreateFirewallTemplates() {
  var name = document.getElementById('createFwName').value.trim();
  var desc = document.getElementById('createFwDesc').value.trim();
  var rules = collectFwRulesFromUI();
  var btn = document.getElementById('createFwExecuteBtn');

  if (!name) { log('❌ 模板名称不能为空', 'error'); return; }
  if (rules.length === 0) { log('❌ 请至少添加一条防火墙规则', 'error'); return; }

  var selectedRegions = [];
  var cbs = document.querySelectorAll('input[name="createFwRegion"]:checked');
  for (var i = 0; i < cbs.length; i++) selectedRegions.push(cbs[i].value);
  if (selectedRegions.length === 0) { log('❌ 请至少选择一个目标地域', 'error'); return; }
  if (!AliyunClient.hasCredentials()) { log('❌ 请先设置阿里云凭证', 'error'); return; }

  if (btn) { btn.disabled = true; btn.textContent = '⏳ 创建中…'; }
  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('🛡️ 批量创建防火墙: [' + name + '] 共 ' + selectedRegions.length + ' 个地域, ' + rules.length + ' 条规则', 'info');

  var totalSuccess = 0, totalFail = 0;
  for (var j = 0; j < selectedRegions.length; j++) {
    var rid = selectedRegions[j];
    try {
      var result = await AliyunClient.createFirewallTemplate(rid, name, desc, rules);
      totalSuccess++;
      log('  ✅ [' + REGION_INFO[rid] + '] 创建成功 → TemplateId=' + (result.FirewallTemplateId || 'OK'), 'success');
    } catch (err) {
      totalFail++;
      log('  ❌ [' + REGION_INFO[rid] + '] 创建失败: ' + (err.message || err), 'error');
    }
    if (j < selectedRegions.length - 1) await new Promise(function(r) { setTimeout(r, 200); });
  }
  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('📊 批量创建完成: 成功 ' + totalSuccess + ', 失败 ' + totalFail, totalFail === 0 ? 'success' : 'warn');
  log('💡 提示：创建成功后请点击「同步阿里云模板」刷新列表', 'info');
  if (btn) { btn.disabled = false; btn.textContent = '🚀 批量创建模板'; }
  closeCreateFirewallModal();
}

// =====================================================================
// 批量删除防火墙模板
// =====================================================================
var _delFwState = { templates: {}, selected: {} };
function openDeleteFirewallModal() { document.getElementById('deleteFirewallModal').style.display = 'flex'; }
function closeDeleteFirewallModal() { document.getElementById('deleteFirewallModal').style.display = 'none'; _delFwState = { templates: {}, selected: {} }; }

async function loadDeleteFirewallList() {
  var regionIds = Object.keys(REGION_INFO);
  log('🔄 加载所有地域防火墙模板...', 'info');
  _delFwState = { templates: {}, selected: {} };
  var container = document.getElementById('delFwListContainer');
  container.innerHTML = '<p style="color:#999; text-align:center; padding:20px;">⏳ 加载中...</p>';

  for (var i = 0; i < regionIds.length; i++) {
    var rid = regionIds[i];
    try {
      var data = await AliyunClient.listFirewallTemplates(rid);
      _delFwState.templates[rid] = (data.FirewallTemplates || []).map(function(t) {
        return { templateId: t.FirewallTemplateId, name: t.Name, description: t.Description || '' };
      });
    } catch (err) {
      _delFwState.templates[rid] = [];
      log('⚠️ [' + REGION_INFO[rid] + '] 加载失败: ' + err.message, 'warn');
    }
    if (i < regionIds.length - 1) await new Promise(function(r) { setTimeout(r, 200); });
  }
  renderDeleteFirewallList();
  log('✅ 防火墙模板列表加载完成', 'success');
}

function renderDeleteFirewallList() {
  var container = document.getElementById('delFwListContainer');
  var regionIds = Object.keys(REGION_INFO);
  var html = '', totalCount = 0;
  for (var i = 0; i < regionIds.length; i++) {
    var rid = regionIds[i];
    var tmpls = _delFwState.templates[rid] || [];
    totalCount += tmpls.length;
    if (tmpls.length === 0) continue;
    html += '<div style="margin-bottom:10px;"><strong style="color:' + (REGION_COLORS[rid] || '#333') + ';">' + REGION_INFO[rid] + ' (' + tmpls.length + ' 个)</strong></div>';
    for (var j = 0; j < tmpls.length; j++) {
      var t = tmpls[j];
      var checked = _delFwState.selected[t.templateId] ? 'checked' : '';
      html += '<label style="display:flex; align-items:center; gap:8px; padding:5px 8px; cursor:pointer; font-size:13px; border-bottom:1px solid #f0f0f0;">' +
        '<input type="checkbox" ' + checked + ' onchange="toggleDelFwSelect(\'' + t.templateId + '\')"> ' +
        t.name + (t.description ? ' <span style="color:#999; font-size:11px;">- ' + t.description + '</span>' : '') + '</label>';
    }
  }
  if (totalCount === 0) html = '<p style="color:#999; text-align:center; padding:20px;">所有地域均无防火墙模板</p>';
  container.innerHTML = html;
  updateDelFwBtn();
}

function toggleDelFwSelect(templateId) {
  if (_delFwState.selected[templateId]) delete _delFwState.selected[templateId];
  else _delFwState.selected[templateId] = true;
  updateDelFwBtn();
}

function updateDelFwBtn() {
  var btn = document.getElementById('delFwBtn');
  var count = Object.keys(_delFwState.selected).length;
  if (btn) { btn.disabled = count === 0; btn.textContent = count > 0 ? ('🗑️ 删除选中模板 (' + count + ')') : '🗑️ 删除选中模板'; }
}

async function batchDeleteFirewallTemplates() {
  var selectedIds = Object.keys(_delFwState.selected);
  if (selectedIds.length === 0) return;
  if (!confirm('确定删除 ' + selectedIds.length + ' 个防火墙模板？此操作不可恢复！')) return;

  var byRegion = {};
  for (var rid in _delFwState.templates) {
    var tmpls = _delFwState.templates[rid];
    for (var i = 0; i < tmpls.length; i++) {
      if (_delFwState.selected[tmpls[i].templateId]) {
        if (!byRegion[rid]) byRegion[rid] = [];
        byRegion[rid].push(tmpls[i].templateId);
      }
    }
  }
  var btn = document.getElementById('delFwBtn');
  if (btn) { btn.disabled = true; btn.textContent = '⏳ 删除中…'; }

  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('🗑️ 批量删除防火墙模板: ' + selectedIds.length + ' 个', 'info');
  var totalSuccess = 0, totalFail = 0;
  for (var rid2 in byRegion) {
    var ids = byRegion[rid2];
    try {
      await AliyunClient.deleteFirewallTemplates(rid2, ids);
      totalSuccess += ids.length;
      log('  ✅ [' + REGION_INFO[rid2] + '] ' + ids.length + ' 个模板已删除', 'success');
    } catch (err) {
      totalFail += ids.length;
      log('  ❌ [' + REGION_INFO[rid2] + '] 删除失败: ' + (err.message || err), 'error');
    }
    await new Promise(function(r) { setTimeout(r, 200); });
  }
  log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
  log('📊 批量删除完成: 成功 ' + totalSuccess + ', 失败 ' + totalFail, totalFail === 0 ? 'success' : 'warn');
  await loadDeleteFirewallList();
  await loadAllRegionTemplates();
}

// =====================================================================
// 批量重启（按所选地域的所有云主机）
// =====================================================================

/** 把所有所选地域的实例收集成 { regionId, instance }[]  */
async function collectInstancesFromSelectedRegions() {
  if (state.selectedRegions.size === 0) {
    throw new Error('请先在「地域概览」勾选地域（点地域卡片或「全选地域」）');
  }
  if (!state.hasCredentials) throw new Error('请先设置阿里云凭证');
  var regionIds = Array.from(state.selectedRegions);
  // 强制刷一次该地域的实例（避免缓存为空）
  var groups = [];
  for (var i = 0; i < regionIds.length; i++) {
    var rid = regionIds[i];
    var rd = state.regionData[rid];
    if (!rd || !rd.instances || rd.instances.length === 0) {
      try {
        var data = await AliyunClient.listInstances(rid, { pageSize: 100 });
        var insts = (data && data.Instances) || [];
        if (!state.regionData[rid]) state.regionData[rid] = { name: REGION_INFO[rid], totalCount: 0, instances: [] };
        state.regionData[rid].instances = insts;
        state.regionData[rid].totalCount = data.TotalCount || insts.length;
        log('  ' + REGION_INFO[rid] + '：拉取 ' + insts.length + ' 台', 'info');
      } catch (err) {
        log('  ' + REGION_INFO[rid] + '：拉取失败 - ' + err.message, 'error');
        continue;
      }
    }
    rd = state.regionData[rid];
    rd.instances.forEach(function(inst) { groups.push({ regionId: rid, instance: inst }); });
  }
  return groups;
}

async function batchRebootSelectedRegions() {
  var btn = null;
  try {
    var groups;
    try { groups = await collectInstancesFromSelectedRegions(); }
    catch (err) { log('⚠️ ' + err.message, 'warn'); return; }
    if (groups.length === 0) { log('⚠️ 所选地域暂无云主机', 'warn'); return; }

    var regionCount = new Set(groups.map(function(g) { return g.regionId; })).size;
    var confirmMsg = '确定要重启 ' + regionCount + ' 个地域、共 ' + groups.length + ' 台云主机吗？\n\n' +
      '• 操作系统会重启，连接会短暂中断\n' +
      '• 数据不会丢失\n' +
      '• 每批 50 台并发执行（无数量限制）';
    if (!confirm(confirmMsg)) return;

    btn = event && event.target;
    if (btn) { btn.disabled = true; btn.textContent = '⏳ 重启中...'; }

    log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
    log('🔁 开始批量重启：' + groups.length + ' 台（' + regionCount + ' 个地域）', 'info');

    var CONCURRENCY = 50;
    var totalSuccess = 0, totalFail = 0;
    var byRegion = {};
    groups.forEach(function(g) { (byRegion[g.regionId] = byRegion[g.regionId] || []).push(g); });

    // 6 个地域并行
    var regionPromises = Object.keys(byRegion).map(function(rid) {
      var arr = byRegion[rid];
      return (async function() {
        log('  ▶ [' + REGION_INFO[rid] + '] 重启 ' + arr.length + ' 台...', 'info');
        for (var i = 0; i < arr.length; i += CONCURRENCY) {
          var slice = arr.slice(i, i + CONCURRENCY);
          var rs = await Promise.all(slice.map(function(g) {
            return AliyunClient.rebootInstance(g.regionId, g.instance.InstanceId).then(function() {
              return { ok: true, id: g.instance.InstanceId };
            }).catch(function(err) {
              return { ok: false, id: g.instance.InstanceId, err: (err && err.message) || String(err) };
            });
          }));
          rs.forEach(function(r) {
            if (r.ok) { totalSuccess++; }
            else { totalFail++; log('    ❌ ' + r.id + ' 失败: ' + r.err, 'error'); }
          });
          if (i + CONCURRENCY < arr.length) await new Promise(function(r) { setTimeout(r, 200); });
        }
        log('  ✅ [' + REGION_INFO[rid] + '] 完成', 'success');
      })();
    });
    await Promise.all(regionPromises);

    log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
    log('📊 批量重启完成：成功 ' + totalSuccess + ' 台，失败 ' + totalFail + ' 台', totalFail === 0 ? 'success' : 'warn');
  } catch (err) {
    log('❌ 批量重启出错: ' + err.message, 'error');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = '🔁 批量重启'; }
  }



}

// =====================================================================
// 批量退订 / 单实例退订（参考「乾亿益云主机管理平台」的退订按钮设计）
// 使用阿里云 DeleteInstance 释放实例，普通账号即可执行，不依赖 BSS RefundInstance 退款权限
// =====================================================================

// DeleteInstance 错误模式识别（不可释放的锁住，跳过；已释放的跳过）
var UNSUB_LOCKED_PATTERNS = [
  'NoApplicable', 'NotApplicable', 'ExceedRefundQuota', 'ExistUnPaidOrder', 'ExistRefundingOrder',
  'NoRestValue', 'AmbassadorOrderLimit', 'ActivityForbidden', 'CommodityNotSupported', 'ProductCheckError',
  'MissingRefundAmount', 'InvalidPayMethod', 'CannotDeleteInstance', 'RefundFailed', 'NoFullRefund',
  '非全额退款', '非全额退订', '订单未到期', '订单到期', '尚未结算', 'InstanceHasUnsettledBill',
  'PayMethodNotSupported', '请先退订订单'
];

function unsubIsLocked(msg) {
  for (var i = 0; i < UNSUB_LOCKED_PATTERNS.length; i++) {
    if (msg.indexOf(UNSUB_LOCKED_PATTERNS[i]) !== -1) return true;
  }
  return false;
}

function unsubIsSkipped(msg) {
  return msg.indexOf('NotFound') !== -1 || msg.indexOf('InvalidInstance') !== -1 ||
         msg.indexOf('ResourceNotExists') !== -1 || msg.indexOf('不存在') !== -1;
}

// 释放实例（退订）：先尝试 DeleteInstance；若实例运行中则先 StopInstance，等待 5 秒后重试
// 参考「乾亿益云主机管理平台」的释放逻辑，普通账号即可执行，不依赖 BSS RefundInstance 退款权限
async function releaseInstance(regionId, instanceId, status) {
  var triedStop = false;
  if (status === 'Running' || status === 'Starting') {
    log('  ⏹️ [' + (REGION_INFO[regionId] || regionId) + '] ' + instanceId + ' 运行中，先停止...', 'info');
    try {
      await AliyunClient.stopInstance(regionId, instanceId);
      triedStop = true;
      await new Promise(function(r) { setTimeout(r, 5000); }); // 等待停机完成
    } catch (err) {
      log('  ⚠️ 停止失败（可能已停止）: ' + ((err && err.message) || err), 'info');
    }
  }
  try {
    await AliyunClient.deleteInstance(regionId, instanceId);
    return { ok: true };
  } catch (err) {
    var msg = (err && err.message) || String(err);
    // 若删除失败是因为未停机，且之前没停过，则补一次停止后重试
    if (!triedStop && /IncorrectInstanceStatus|not stopped|is running|must be stopped|Running|实例未停止|运行中|Stop/i.test(msg)) {
      log('  ⏹️ 删除提示需停机，尝试停止后重试...', 'info');
      await AliyunClient.stopInstance(regionId, instanceId);
      await new Promise(function(r) { setTimeout(r, 5000); });
      await AliyunClient.deleteInstance(regionId, instanceId);
      return { ok: true };
    }
    throw err;
  }
}

// 同步"批量退订"按钮：显示所选地域实例总数，无实例或未设凭证时禁用
function updateBatchUnsubBtn() {
  var btn = document.getElementById('batchUnsubBtn');
  if (!btn) return;
  var total = 0;
  Array.from(state.selectedRegions).forEach(function(rid) {
    var rd = state.regionData[rid];
    if (rd && rd.instances) total += rd.instances.length;
  });
  btn.textContent = '🗑️ 批量退订 (' + total + ')';
  btn.disabled = total === 0 || !state.hasCredentials;
}

// ===== 有界并发退订核心（与后端 scheduled_refund.py 同套方法论）=====
// 目标：提升吞吐又不触发阿里云 Throttling 限流。
//   1) 全局令牌桶：平滑到 ~REFUND_QPS 次/秒，杜绝"一批 50 并发"的突发尖峰
//   2) 并发上限：worker 池最多 REFUND_CONCURRENCY 个在途请求（有界并发）
//   3) 幂等：每个实例固定一个 clientToken，限流重试时复用，绝不会重复退款
//   4) 退避重试：Throttling/ServiceUnavailable 等瞬时错误指数退避重试，复用同一 token
var REFUND_CONCURRENCY = 16;  // 同时最多在途请求数（有界并发上限，已从 8 提升到 16 提速）
var REFUND_QPS = 12;          // 目标平稳速率（令牌桶：容量=QPS，refill=QPS/秒，已从 8 提升到 12 提速）

// 限流 / 服务瞬时不可用 错误模式（命中则退避重试）
var REFUND_THROTTLE_PATTERNS = [
  'Throttling', 'Throttling.User', 'ServiceUnavailable', 'InternalError',
  'RequestLimitExceeded', 'SystemBusy', 'TryAgainLater', 'FrequencyLimit',
  'OverFlow', 'Busy', 'Timeout', 'RequestTimeout'
];
function isRefundThrottle(msg) {
  for (var i = 0; i < REFUND_THROTTLE_PATTERNS.length; i++) {
    if (msg.indexOf(REFUND_THROTTLE_PATTERNS[i]) !== -1) return true;
  }
  return false;
}

// BSS RefundInstance 不可退订（锁定）错误模式
var BSS_LOCKED_PATTERNS = [
  'NoApplicable', 'NotApplicable', 'ExceedRefundQuota', 'ExistUnPaidOrder',
  'ExistRefundingOrder', 'NoRestValue', 'AmbassadorOrderLimit', 'ActivityForbidden',
  'CommodityNotSupported', 'ProductCheckError', 'MissingRefundAmount', 'InvalidPayMethod',
  'CannotDeleteInstance', 'RefundFailed', 'NoFullRefund', '非全额退款', '非全额退订',
  '订单未到期', '订单到期', '尚未结算', 'InstanceHasUnsettledBill', 'PayMethodNotSupported',
  '请先退订订单'
];
function classifyRefundErr(msg) {
  for (var i = 0; i < BSS_LOCKED_PATTERNS.length; i++) {
    if (msg.indexOf(BSS_LOCKED_PATTERNS[i]) !== -1) return 'locked';
  }
  if (unsubIsSkipped(msg)) return 'skipped';
  return 'fail';
}

// 按 region:instance 派生的【稳定幂等 Token】：同一实例在任意进程/轮次/定时执行中永远同一 token，
// 使 BSS 服务端视为同一请求（保留期内幂等），彻底杜绝「退完又反复退 / 重试重复退款」。
// 与后端 scheduled_refund.py 的 stable_client_token 派生方式一致（wb- + sha1[:16]）。
function _djb2hex(s) {
  var h = 5381;
  for (var i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
  return ('00000000' + h.toString(16)).slice(-8);
}
async function stableClientToken(rid, iid) {
  var key = rid + ':' + iid;
  if (window.crypto && crypto.subtle && crypto.subtle.digest) {
    try {
      var buf = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(key));
      var arr = new Uint8Array(buf), hex = '';
      for (var i = 0; i < arr.length; i++) hex += ('0' + arr[i].toString(16)).slice(-2);
      return 'wb-' + hex.slice(0, 16);
    } catch (e) { /* 落到兜底哈希 */ }
  }
  // 兜底（非安全上下文）：稳定确定性哈希，同样保证幂等
  return 'wb-' + _djb2hex(key) + _djb2hex(key.split('').reverse().join(''));
}

// 浏览器会话内「已退订实例集合」：对标后端 refund_state.json / 参考站 lastTriggered。
// 同一会话里对已成功/已报退订的实例不再二次发起请求，避免反复退、提速。
var __refundedIds = window.__refundedIds || (window.__refundedIds = new Set());
function markRefundedFrontend(iid) { if (iid) __refundedIds.add(iid); }

// 令牌桶：take() 在令牌不足时等待补足，保证整体速率 ≤ refillPerSec
function makeTokenBucket(capacity, refillPerSec) {
  var tokens = capacity;
  var last = Date.now();
  return {
    take: function (n) {
      n = n || 1;
      return new Promise(function (resolve) {
        function tick() {
          var now = Date.now();
          var dt = (now - last) / 1000;
          tokens = Math.min(capacity, tokens + dt * refillPerSec);
          last = now;
          if (tokens >= n) { tokens -= n; resolve(); }
          else {
            var wait = (n - tokens) / refillPerSec * 1000 + 5;
            setTimeout(tick, wait);
          }
        }
        tick();
      });
    }
  };
}

// 单实例退订：令牌桶限速 + 稳定幂等 token + 限流退避重试
async function refundOneBounded(rid, instanceId, bucket, hooks) {
  await bucket.take(1);
  var clientToken = await stableClientToken(rid, instanceId); // 稳定 token：同一实例永远相同，杜绝反复退
  var maxRetry = 5, attempt = 0;
  var regionName = (REGION_INFO[rid] || rid);
  while (true) {
    try {
      await AliyunClient.refundInstance(rid, instanceId, { clientToken: clientToken });
      return { ok: true, id: instanceId, kind: 'success' };
    } catch (err) {
      var msg = (err && err.message) || String(err);
      var kind = classifyRefundErr(msg);
      // 锁定/已退订：不可重试（幂等也无法改变结果），直接返回
      if (kind !== 'fail') return { ok: false, id: instanceId, kind: kind, err: msg };
      // 非限流失败：直接报失败；限流且未用尽重试次数：退避后复用同一 token 重试
      if (!isRefundThrottle(msg) || attempt >= maxRetry) {
        return { ok: false, id: instanceId, kind: 'fail', err: msg };
      }
      attempt++;
      var backoff = Math.min(3000, 500 * Math.pow(2, attempt)) + Math.floor(Math.random() * 300);
      if (hooks && hooks.onThrottle) hooks.onThrottle(regionName, instanceId, attempt, backoff);
      await new Promise(function (r) { setTimeout(r, backoff); });
    }
  }
}

// 有界并发调度：全局令牌桶 + worker 池（并发上限），跨地域统一限速
async function runBoundedRefund(tasks, opts) {
  opts = opts || {};
  var CONCURRENCY = opts.concurrency || REFUND_CONCURRENCY;
  var QPS = opts.qps || REFUND_QPS;
  var bucket = makeTokenBucket(QPS, QPS);
  var total = { success: 0, skipped: 0, locked: 0, fail: 0 };
  if (!tasks.length) return total;
  var idx = 0, done = 0;
  async function worker() {
    while (idx < tasks.length) {
      var task = tasks[idx++];
      var r = await refundOneBounded(task.rid, task.iid, bucket, {
        onThrottle: function (rn, iid, a, bk) {
          log('   ⏳ [' + rn + '] ' + iid + ' 触发限流，第 ' + a + ' 次退避重试 (' + bk + 'ms)', 'warn');
        }
      });
      var rn2 = REGION_INFO[task.rid] || task.rid;
      if (r.kind === 'skipped') { total.skipped++; markRefundedFrontend(r.id); log('⚪ [' + rn2 + '] ' + r.id + ': 已退订/不存在，跳过', 'info'); }
      else if (r.kind === 'locked') { total.locked++; log('🔒 [' + rn2 + '] ' + r.id + ': ' + r.err + ' (跳过，不再重试)', 'warn'); }
      else if (r.ok) { total.success++; markRefundedFrontend(r.id); log('   ✅ [' + rn2 + '] ' + r.id + ' 退订成功', 'success'); }
      else {
        total.fail++; log('❌ [' + rn2 + '] ' + r.id + ': ' + r.err, 'error');
        if (opts.recordFailures) {
          if (!state._failedIds) state._failedIds = [];
          state._failedIds.push({ regionId: task.rid, instanceId: r.id, error: r.err });
        }
      }
      done++;
      if (done % 10 === 0 || done === tasks.length) {
        log('   📊 进度 ' + done + '/' + tasks.length +
          ' (累计 成功' + total.success + ' 跳过' + total.skipped + ' 锁定' + total.locked + ' 失败' + total.fail + ')', 'info');
      }
    }
  }
  var pool = [];
  var n = Math.min(CONCURRENCY, tasks.length);
  for (var w = 0; w < n; w++) pool.push(worker());
  await Promise.all(pool);
  return total;
}

// 按地域并行退订（有界并发版）：立即退订 / 定时退订（浏览器内）共用此入口
// opts: { recordFailures, concurrency, qps }
async function refundByRegionParallel(byRegion, opts) {
  opts = opts || {};
  var tasks = [];
  Object.keys(byRegion).forEach(function (rid) {
    var arr = byRegion[rid] || [];
    if (!arr.length) { log('   🌏 [' + (REGION_INFO[rid] || rid) + '] 无实例，跳过', 'info'); return; }
    for (var i = 0; i < arr.length; i++) {
      var it = arr[i];
      var id = it.InstanceId || it.instanceId;
      if (__refundedIds.has(id)) continue; // 会话内已退订 → 跳过（对标参考站 lastTriggered 去重）
      tasks.push({ rid: rid, iid: id });
    }
    log('   🌏 [' + (REGION_INFO[rid] || rid) + '] 共 ' + arr.length + ' 台待退订', 'info');
  });
  if (!tasks.length) return { success: 0, skipped: 0, locked: 0, fail: 0 };
  log('🔄 有界并发退订 ' + tasks.length + ' 台（并发≤' + (opts.concurrency || REFUND_CONCURRENCY) +
    '，速率≤' + (opts.qps || REFUND_QPS) + '/秒，限流自动退避重试）...', 'warn');
  return await runBoundedRefund(tasks, opts);
}

// 通用释放执行器（按地域并行、有界并发，复用 runBoundedRefund 同一套限速/幂等/重试逻辑）
async function runRefund(groups) {
  var tasks = [];
  groups.forEach(function (g) {
    tasks.push({ rid: g.regionId, iid: g.instance.InstanceId });
  });
  log('🗑️ 批量退订：' + tasks.length + ' 台（有界并发）', 'warn');
  var total = await runBoundedRefund(tasks, { recordFailures: true });

  log('━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
  log('🏁 退订（退款）完成: 成功 ' + total.success + ' 台, 跳过 ' + total.skipped + ' 台, 失败 ' + total.fail + ' 台',
    total.fail === 0 ? 'success' : 'warn');
  if (total.fail > 0) {
    log('⚠️ 失败常见原因：', 'warn');
    log('   • BSS API 仅支持【直销客户】，分销账号无法调用', 'warn');
    log('   • AK/SK 未勾选 AliyunBSSFullAccess 权限', 'warn');
    log('   • 该实例为活动订单/无剩余金额/已到退款期限', 'warn');
  }
  return total;
}


// 批量退订所选地域的所有云主机（按钮参考乾亿益平台的"批量退订 (N)"）
async function batchUnsubscribeSelectedRegions() {
  var btn = null;
  try {
    if (state.selectedRegions.size === 0) { log('⚠️ 请先在「地域概览」勾选地域', 'warn'); return; }
    if (!state.hasCredentials) { log('⚠️ 请先设置阿里云凭证', 'warn'); return; }

    var groups;
    try { groups = await collectInstancesFromSelectedRegions(); }
    catch (err) { log('⚠️ ' + err.message, 'warn'); return; }
    if (groups.length === 0) { log('⚠️ 所选地域暂无云主机', 'warn'); return; }

    var regionCount = new Set(groups.map(function(g) { return g.regionId; })).size;
    var confirmMsg = '确定要退订 ' + regionCount + ' 个地域、共 ' + groups.length + ' 台云主机吗？\n\n' +
      '• 退订 = 调用阿里云 BSS RefundInstance 真正退款（需直销客户 + AliyunBSSFullAccess）\n' +
      '• 退款将退回账户/原支付渠道，实例会被释放\n' +
      '• 操作不可逆，实例将被释放，数据不可恢复';
    if (!confirm(confirmMsg)) return;

    btn = event && event.target;
    if (btn) { btn.disabled = true; btn.textContent = '⏳ 退订中...'; }

    log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
    log('🗑️ 开始批量退订：' + groups.length + ' 台（' + regionCount + ' 个地域）', 'warn');

    await runRefund(groups);

    await refreshAllRegions();
    deselectAllRegions();
    updateBatchUnsubBtn();
  } catch (err) {
    log('❌ 批量退订出错: ' + err.message, 'error');
  } finally {
    if (btn) { btn.disabled = false; updateBatchUnsubBtn(); }
  }
}

// 单实例退订（按钮参考乾亿益平台实例行的"退订"）
async function unsubscribeSingleInstance(regionId, instanceId) {
  if (!state.hasCredentials) { log('⚠️ 请先设置阿里云凭证', 'warn'); return; }
  // 运行时从已加载实例中查名称，避免把用户数据直接拼进 onclick 属性
  var name = instanceId;
  try {
    var rd = state.regionData[regionId];
    if (rd && rd.instances) {
      for (var k = 0; k < rd.instances.length; k++) {
        if (rd.instances[k].InstanceId === instanceId) { name = rd.instances[k].InstanceName || instanceId; break; }
      }
    }
  } catch (e) {}
  if (!confirm('确定要退订实例「' + name + '」(' + instanceId + ') 吗？\n\n' +
      '退订 = 调用阿里云 BSS RefundInstance 真正退款（需直销客户 + AliyunBSSFullAccess）。\n操作不可逆，实例将被释放，数据不可恢复！')) return;

  log('🗑️ 退订实例 ' + name + ' (' + instanceId + ')...', 'warn');
  try {
    await AliyunClient.refundInstance(regionId, instanceId, { clientToken: await stableClientToken(regionId, instanceId) });
    log('   ✅ ' + name + ' (' + instanceId + ') 退订成功', 'success');
  } catch (err) {
    var msg = (err && err.message) || String(err);
    if (unsubIsSkipped(msg)) log('⚪ ' + name + ': 已退订/不存在，跳过', 'info');
    else log('❌ ' + name + ' 退订失败: ' + msg, 'error');
  }
  await refreshAllRegions();
  updateBatchUnsubBtn();
}

// =====================================================================
// 批量重置系统为 CentOS-7.9（按所选地域的所有云主机）
// =====================================================================

var RESET_SYSTEM_IMAGE_ID = 'bdde0344f65942f3adce35d421732c87';  // CentOS-7.9 hash
var RESET_SYSTEM_IMAGE_NAME = 'CentOS-7.9';

function openResetSystemModal() {
  if (state.selectedRegions.size === 0) {
    log('⚠️ 请先在「地域概览」勾选地域', 'warn');
    return;
  }
  if (!state.hasCredentials) { log('⚠️ 请先设置凭证', 'warn'); return; }
  var html =
    '<div class="modal-mask" id="resetSystemMask" onclick="if(event.target===this)closeResetSystemModal()">' +
      '<div class="modal-dialog" style="max-width:560px;">' +
        '<div class="modal-header"><h3>♻️ 批量重置系统为 ' + RESET_SYSTEM_IMAGE_NAME + '</h3><button class="modal-close" onclick="closeResetSystemModal()">×</button></div>' +
        '<div class="modal-body" style="max-height:60vh;overflow-y:auto;">' +
          '<div style="background:#fff3cd;border-left:4px solid #ffc107;padding:10px 14px;margin-bottom:14px;border-radius:4px;font-size:13px;color:#856404;">' +
            '<strong>⚠️ 重置系统会清除服务器磁盘数据！</strong><br>' +
            '1. 操作系统会被重装，所有系统盘数据会丢失<br>' +
            '2. 数据盘数据保留但需要重新初始化后才能使用<br>' +
            '3. 如果实例正在运行，系统会自动停机后重置<br>' +
            '4. 完成后需要重新设置密码/SSH 密钥' +
          '</div>' +
          '<div style="background:#f0f8ff;padding:10px 14px;border-radius:4px;font-size:13px;">' +
            '<strong>目标镜像：</strong> ' + RESET_SYSTEM_IMAGE_NAME + ' （ImageId: <code>' + RESET_SYSTEM_IMAGE_ID + '</code>）<br>' +
            '<strong>操作地域：</strong> <span id="resetSystemRegions"></span>' +
          '</div>' +
          '<div style="margin-top:14px;display:flex;gap:8px;justify-content:flex-end;">' +
            '<button class="btn btn-default" onclick="closeResetSystemModal()">取消</button>' +
            '<button class="btn" style="background:#e91e63;color:#fff;border:none;" id="resetSystemConfirmBtn" onclick="confirmResetSystem()">确认重置</button>' +
          '</div>' +
        '</div>' +
      '</div>' +
    '</div>';
  var old = document.getElementById('resetSystemMask');
  if (old) old.remove();
  var wrap = document.createElement('div');
  wrap.innerHTML = html;
  document.body.appendChild(wrap.firstChild);
  // 展示所选地域
  var sel = Array.from(state.selectedRegions).map(function(rid) { return REGION_INFO[rid] || rid; });
  document.getElementById('resetSystemRegions').textContent = sel.join('、');
  // 异步加载每个地域的实例数
  (async function() {
    var groups;
    try { groups = await collectInstancesFromSelectedRegions(); }
    catch (err) { log('⚠️ ' + err.message, 'warn'); return; }
    document.getElementById('resetSystemRegions').textContent = sel.join('、') + '（共 ' + groups.length + ' 台）';
  })();
}

function closeResetSystemModal() {
  var m = document.getElementById('resetSystemMask');
  if (m) m.remove();
}

async function confirmResetSystem() {
  var btn = document.getElementById('resetSystemConfirmBtn');
  if (!btn) return;
  btn.disabled = true; btn.textContent = '⏳ 重置中...';

  try {
    var groups;
    try { groups = await collectInstancesFromSelectedRegions(); }
    catch (err) { log('⚠️ ' + err.message, 'warn'); btn.disabled = false; btn.textContent = '确认重置'; return; }
    if (groups.length === 0) { log('⚠️ 所选地域暂无云主机', 'warn'); btn.disabled = false; btn.textContent = '确认重置'; return; }

    log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
    log('♻️ 开始批量重置系统为 ' + RESET_SYSTEM_IMAGE_NAME + '：' + groups.length + ' 台', 'info');

    var CONCURRENCY = 50;
    var totalSuccess = 0, totalFail = 0, totalStoppedFirst = 0;
    var byRegion = {};
    groups.forEach(function(g) { (byRegion[g.regionId] = byRegion[g.regionId] || []).push(g); });

    var regionPromises = Object.keys(byRegion).map(function(rid) {
      var arr = byRegion[rid];
      return (async function() {
        log('  ▶ [' + REGION_INFO[rid] + '] 重置 ' + arr.length + ' 台...', 'info');
        for (var i = 0; i < arr.length; i += CONCURRENCY) {
          var slice = arr.slice(i, i + CONCURRENCY);
          var rs = await Promise.all(slice.map(function(g) {
            return AliyunClient.resetSystem(g.regionId, g.instance.InstanceId, RESET_SYSTEM_IMAGE_ID).then(function(data) {
              return { ok: true, id: g.instance.InstanceId, stoppedFirst: !!data.stoppedFirst };
            }).catch(function(err) {
              return { ok: false, id: g.instance.InstanceId, err: (err && err.message) || String(err) };
            });
          }));
          rs.forEach(function(r) {
            if (r.ok) { totalSuccess++; if (r.stoppedFirst) totalStoppedFirst++; }
            else { totalFail++; log('    ❌ ' + r.id + ' 失败: ' + r.err, 'error'); }
          });
          if (i + CONCURRENCY < arr.length) await new Promise(function(r) { setTimeout(r, 200); });
        }
        log('  ✅ [' + REGION_INFO[rid] + '] 完成', 'success');
      })();
    });
    await Promise.all(regionPromises);

    log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
    log('📊 批量重置完成：成功 ' + totalSuccess + ' 台，失败 ' + totalFail + ' 台', totalFail === 0 ? 'success' : 'warn');
    if (totalStoppedFirst > 0) log('  其中 ' + totalStoppedFirst + ' 台是运行中自动停机后再重置的', 'info');
    log('💡 提示：重置后实例会自动启动，可在控制台「服务器运维 → 实例」查看', 'info');
  } catch (err) {
    log('❌ 批量重置出错: ' + err.message, 'error');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = '确认重置'; }
    closeResetSystemModal();
  }
}

/* ============================================================
 * 非锁定辅助：节点抓取诊断 + token 缓存清理
 * （node-extract.js 为锁定文件不可改，这里只加新函数，不触碰锁定逻辑）
 * ============================================================ */

/* 直接打转发器，分别测试多种 token/header 传法，看哪一种能让 admin 正常返回 */
async function zyDiagProxy() {
  var ta = document.getElementById('zyToken');
  var token = (ta && ta.value || '').trim();
  if (!token) { try { token = localStorage.getItem('zy_admin_token') || ''; } catch (e) {} }
  if (!token) {
    var st0 = document.getElementById('zySearchStatus');
    if (st0) st0.innerHTML = '⚠️ 请先在上方输入框填入 admin.zhouyi.top 的 token（不必保存），再点诊断';
    return;
  }
  var ownerEl = document.getElementById('zyOwnerId');
  var ownerId = ((ownerEl && ownerEl.value || '').trim()) || '7695';
  var adv = (typeof readAdvancedFromInputs === 'function') ? readAdvancedFromInputs()
    : { method: 'GET', path: '/api/edgeNode/getEdgeNodeList', query: 'ownerId={ownerId}&isOnline=1' };
  var query = (adv.query || 'ownerId={ownerId}&isOnline=1').replace(/\{ownerId\}/g, encodeURIComponent(ownerId));
  var st = document.getElementById('zySearchStatus');
  if (st) st.innerHTML = '🔬 诊断中：分别测试 header / cookie / header+cookie 三种 token 传法…<br><small>path: ' + (adv.method || 'GET') + ' ' + (adv.path || '/api/edgeNode/getEdgeNodeList') + '?' + query + '</small>';

  function esc(s) { return String(s).replace(/[&<>]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]; }); }
  function truncate(s) { var t = String(s || ''); return t.length > 400 ? t.slice(0, 400) + '…（共' + t.length + '字符）' : t; }

  async function tryMode(name, headers) {
    try {
      var resp = await fetch(OCD_SUPABASE_FN, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + OCD_ANON_KEY },
        body: JSON.stringify({
          token: token,
          headers: headers,
          method: adv.method || 'GET',
          path: adv.path || '/api/edgeNode/getEdgeNodeList',
          query: query,
          body: null
        })
      });
      var raw = await resp.text();
      return { name: name, status: resp.status, ok: resp.ok, raw: raw };
    } catch (e) {
      return { name: name, status: 0, ok: false, raw: '前端异常：' + (e.message || e) };
    }
  }

  var results = await Promise.all([
    tryMode('A. 多 header（Authorization/X-Token/x-token/Token）', { 'Authorization': token, 'X-Token': token, 'x-token': token, 'Token': token }),
    tryMode('B. 仅 Cookie（token=你的token）', { 'Cookie': 'token=' + token }),
    tryMode('C. 多 header + Cookie', { 'Authorization': token, 'X-Token': token, 'x-token': token, 'Token': token, 'Cookie': 'token=' + token })
  ]);

  function parseAdmin(r) {
    // 把 admin.zhouyi.top 的真实回包拆出来：wrapper.ok / wrapper.status / 内层 data.code / data.msg
    var out = { ok: r.ok, status: r.status, aok: null, acode: null, amsg: null, araw: r.raw };
    try {
      var o = JSON.parse(r.raw);
      out.aok = (o && o.ok);
      out.status = (o && o.status != null) ? o.status : r.status;
      var inner = (o && o.data != null) ? o.data : null;
      if (inner != null) {
        if (typeof inner === 'string') { try { inner = JSON.parse(inner); } catch (e) {} }
        if (inner && typeof inner === 'object') {
          out.acode = (inner.code != null) ? inner.code : (inner.Code != null ? inner.Code : null);
          out.amsg = (inner.msg != null) ? inner.msg : (inner.message != null ? inner.message : (inner.Msg != null ? inner.Msg : null));
        }
      }
      if (out.acode == null && out.amsg == null && o && typeof o === 'object') {
        if (o.error) out.amsg = String(o.error);
        if (o.msg) out.amsg = o.msg;
        if (o.code != null) out.acode = o.code;
      }
    } catch (e) {}
    return out;
  }
  function interpret(a) {
    if (a.aok === true) return { c: '#52c41a', t: '✅ 此传法 admin 接受（ok:true）' };
    var m = (a.amsg || '') + ' ' + (a.acode != null ? String(a.acode) : '');
    if (/时间|非工作|休息|维护|下班|off[\s_-]?hours|22[:：]|23[:：]|0[0-9][:：]|凌晨|夜间|节假日/i.test(m))
      return { c: '#fa8c16', t: '⏰ 疑似「工作时间门禁」—— admin 在非工作时间拒绝此接口（与“5点后报错”高度吻合）' };
    if (/登录|未授权|未登录|token|expire|过期|失效|auth|unauthor|forbidden|无权限|denied/i.test(m))
      return { c: '#ff4d4f', t: '🔑 疑似「鉴权失效」—— token 无效/过期/无权限' };
    if (a.status >= 500)
      return { c: '#ff4d4f', t: '🔧 上游 5xx —— 接口路径可能不对，或后端该时段异常' };
    if (a.status >= 400)
      return { c: '#fa8c16', t: '⚠️ 上游 ' + a.status + ' —— admin 明确拒绝' };
    return { c: '#666', t: '❓ 未识别，请看原始包' };
  }

  var html = '🔬 <b>诊断结果（三种 token 传法对比 + admin 真实反馈）</b><br><small style="color:#666;">出现 <b>ok:true</b> 或「admin 真实反馈」不是报错，就说明该传法可用。</small><br>';
  results.forEach(function (r) {
    var a = parseAdmin(r);
    var inter = interpret(a);
    var color = (a.aok === true) ? '#52c41a' : (a.status >= 400 ? '#ff4d4f' : '#fa8c16');
    var adminLine = '';
    if (a.acode != null || a.amsg) {
      adminLine = '<div style="padding:6px 10px;background:#fffbe6;border-top:1px solid #ffe58f;font-size:12px;">' +
        '📨 <b>admin 真实反馈</b>：code=<b>' + esc(a.acode) + '</b> · msg=<b>' + esc(a.amsg) + '</b></div>';
    }
    html += '<div style="margin:10px 0;border:1px solid #eee;border-radius:6px;overflow:hidden;">' +
      '<div style="background:#f6f8fa;padding:8px 10px;font-weight:600;color:' + color + ';">' + esc(r.name) + ' → HTTP ' + r.status + (a.status !== r.status ? ' (上游 ' + a.status + ')' : '') + '</div>' +
      adminLine +
      '<div style="padding:6px 10px;font-size:12px;color:' + inter.c + ';">' + inter.t + '</div>' +
      '<pre style="white-space:pre-wrap;word-break:break-all;font-size:11px;background:#fff;padding:8px 10px;margin:0;color:#444;">' + esc(truncate(r.raw)) + '</pre>' +
      '</div>';
  });
  html += '<small style="color:#666;">📌 使用建议：<br>' +
    '· <b>现在（5点前）跑一次、5点后再跑一次</b>，对比「admin 真实反馈」是否从正常变成限时错误，即可确认是不是网页的<b>工作时间限制</b>。<br>' +
    '· 若是工作时间门禁：只能在 9:00–17:00 之间抓；可先把节点ID抓出来存好，过 5 点后用已抓的列表，无需再调接口。</small>';
  if (st) st.innerHTML = html;
}

/* 清掉本机缓存的旧 token，强制下次抓取用输入框里的新 token */
function zyClearTokenCache() {
  try { localStorage.removeItem('zy_admin_token'); } catch (e) {}
  var st = document.getElementById('zyTokenStatus');
  if (st) st.innerHTML = '🧹 已清除本机缓存 token（下次抓取优先用输入框中的新 token，或先点「💾 保存凭证」）';
  var ta = document.getElementById('zyToken');
  if (ta) { ta.focus(); ta.style.borderColor = '#1890ff'; }
}


/* ---------- 根据节点ID导出公网IP（优先后台节点详情接口，fallback 阿里云） ---------- */

// 从 admin.zhouyi.top 节点详情接口查公网IP（自动探测常见路径）
async function queryAdminNodeDetail(nodeId) {
  var token = '';
  try { token = localStorage.getItem('zy_admin_token') || ''; } catch (e) {}
  if (!token) return { ok: false, error: '未填写 admin.zhouyi.top 登录凭证（token）' };

  // 真实后台是统一网关：POST 到根路径，body 区分业务
  var OCD_SUPABASE_FN = 'https://vgddxxgjcogxcpiycsej.supabase.co/functions/v1/one-click-deploy';
  var upstreamHeaders = { Authorization: token, 'X-Token': token, 'x-token': token, Token: token };
  var userId = ((document.getElementById('zyUserId') || {}).value || '').trim();
  if (userId) upstreamHeaders['X-User-Id'] = userId;

  // 待尝试的 payload：优先用用户高级框填的真实 payload（含 {nodeId} 占位）
  var payloads = [];
  var advRaw = ((document.getElementById('zyDetailPayload') || {}).value || '').trim();
  if (advRaw) {
    var filled = advRaw.replace(/\{nodeId\}/g, nodeId);
    try { payloads.push(JSON.parse(filled)); } catch (e2) { payloads.push(filled); }
  }
  // 默认猜测（统一网关业务名）
  var guesses = [
    { type: 'getEdgeNodeDetail', nodeId: nodeId },
    { type: 'getNodeDetail', nodeId: nodeId },
    { type: 'getNodeInfo', nodeId: nodeId },
    { action: 'getEdgeNodeDetail', nodeId: nodeId },
    { type: 'getEdgeNodeDetail', id: nodeId },
    { type: 'getNodeDetail', id: nodeId }
  ];
  guesses.forEach(function (g) { payloads.push(g); });

  function tryOne(payload) {
    var bodyStr = (typeof payload === 'string') ? payload : JSON.stringify(payload);
    return fetch(OCD_SUPABASE_FN, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: token, headers: upstreamHeaders, method: 'POST', path: '/', query: '', body: bodyStr })
    }).then(function (r) { return r.json().catch(function () { return null; }).then(function (j) { return { status: r.status, json: j }; }); });
  }

  var lastProbe = null;
  for (var i = 0; i < payloads.length; i++) {
    var sig = (typeof payloads[i] === 'string') ? payloads[i].slice(0, 80) : JSON.stringify(payloads[i]).slice(0, 80);
    var resp = await tryOne(payloads[i]);
    lastProbe = { method: 'POST', path: '/', status: resp.status, json: resp.json, payload: sig };
    if (resp.status >= 200 && resp.status < 300 && resp.json) {
      var ipInfo = extractIpFromAdminDetail(resp.json);
      if (ipInfo.publicIp || ipInfo.innerIp) return { ok: true, path: '/ (POST ' + sig + ')', info: ipInfo, probe: lastProbe };
    }
  }
  var summary = lastProbe && lastProbe.json ? JSON.stringify(lastProbe.json).slice(0, 300) : '无响应';
  return { ok: false, error: '自动探测了 ' + payloads.length + ' 种网关业务 payload，均未返回该节点IP。最后尝试 ' + (lastProbe ? lastProbe.payload + ' -> HTTP ' + lastProbe.status : '无') + '。请在节点详情页 F12 抓取返回 IP 的请求的负载，填到上方输入框（把 nodeId 换成 {nodeId}）。', probe: lastProbe };
}


// 递归从 admin 响应中提取 IP 字段（更激进：收集所有 IP 后按上下文分类）
function extractIpFromAdminDetail(data) {
  if (!data || typeof data !== 'object') return {};
  var publicHints = ['public','公网','wan','external','eip','elastic','公网ip','公网ip','ip'];
  var innerHints = ['inner','private','lan','内网','intranet','vpc'];

  var regionKeys = ['region','regionname','noderegion','area','zone','regionid','dc','datacenter'];
  var statusKeys = ['status','nodestatus','networkstatus','state','devicestatus','onlinestatus'];

  var publicIps = [], innerIps = [], unknownIps = [];
  var found = {};

  function isPublicIpKey(k) {
    var kl = k.toLowerCase();
    return publicHints.some(function(h){ return kl.indexOf(h) !== -1; });
  }
  function isInnerIpKey(k) {
    var kl = k.toLowerCase();
    return innerHints.some(function(h){ return kl.indexOf(h) !== -1; });
  }

  function walk(o) {
    if (!o || typeof o !== 'object') return;
    if (Array.isArray(o)) { o.forEach(walk); return; }
    for (var k in o) {
      if (!Object.prototype.hasOwnProperty.call(o, k)) continue;
      var v = o[k];
      if (typeof v === 'string' && /^\d{1,3}(\.\d{1,3}){3}$/.test(v)) {
        if (isPublicIpKey(k)) publicIps.push(v);
        else if (isInnerIpKey(k)) innerIps.push(v);
        else unknownIps.push({ key: k, ip: v });
      }
      if (typeof v === 'string') {
        var kl = k.toLowerCase();
        if (!found.region && regionKeys.some(function(pk){ return kl === pk.toLowerCase(); })) found.region = v;
        if (!found.status && statusKeys.some(function(pk){ return kl === pk.toLowerCase(); })) found.status = v;
      }
      if (typeof v === 'object') walk(v);
    }
  }
  walk(data);

  if (publicIps.length) found.publicIp = publicIps[0];
  if (innerIps.length) found.innerIp = innerIps[0];
  if (!found.publicIp && !found.innerIp && unknownIps.length) {
    // 未知字段名的 IP：通常第一个是公网（后台详情页优先展示公网）
    found.publicIp = unknownIps[0].ip;
    found._ipSource = unknownIps[0].key;
  }
  return found;
}

async function exportPublicIpsFromPaste() {
  var ta = document.getElementById('zyPaste');
  var st = document.getElementById('zyIpExportResult');
  if (!ta || !st) return;
  var ids = (typeof parseNodeIds === 'function' ? parseNodeIds(ta.value) : []);
  if (!ids.length) {
    st.innerHTML = '<span style="color:#cf1322;">⚠️ 请先粘贴节点ID</span>';
    return;
  }

  st.innerHTML = '<span style="color:#1677ff;">🔄 正在查询 ' + ids.length + ' 个节点的公网IP...</span>';

  // 1) 先从页面已加载的实例缓存匹配（阿里云 InstanceId）
  var map = {}; // id -> {region, publicIp, innerIp, status, from}
  function recordAliyun(inst, rid) {
    if (!inst || !inst.InstanceId) return;
    var iid = inst.InstanceId;
    if (!map[iid]) {
      map[iid] = {
        region: REGION_INFO[rid] || rid,
        publicIp: inst.PublicIpAddress || '',
        innerIp: inst.InnerIpAddress || '',
        status: inst.Status || '',
        from: 'aliyun-cache'
      };
    }
  }
  Object.keys(state.regionData || {}).forEach(function(rid) {
    var arr = (state.regionData[rid] && state.regionData[rid].instances) || [];
    arr.forEach(function(inst) { recordAliyun(inst, rid); });
  });

  var missing = ids.filter(function(id) { return !map[id]; });
  var adminErrors = [];

  // 2) 未命中则优先调 admin.zhouyi.top 节点详情接口查 IP
  if (missing.length) {
    var concurrency = 3;
    var queue = missing.slice();
    var running = [];
    await new Promise(function(resolve) {
      function next() {
        if (queue.length === 0 && running.length === 0) { resolve(); return; }
        while (queue.length > 0 && running.length < concurrency) {
          var id = queue.shift();
          var p = queryAdminNodeDetail(id).then(function(res) {
            if (res.ok) {
              map[id] = {
                region: res.info.region || '-',
                publicIp: res.info.publicIp || '',
                innerIp: res.info.innerIp || '',
                status: res.info.status || '-',
                from: 'admin:' + res.path,
                probe: res.probe || null,
                _ipSource: res.info._ipSource || ''
              };
            } else {
              adminErrors.push(id + ': ' + res.error);
            }
          }).catch(function(err) {
            adminErrors.push(id + ': ' + (err.message || String(err)));
          });
          p.then(function() { running.splice(running.indexOf(p), 1); next(); });
          running.push(p);
        }
      }
      next();
    });
  }

  // 3) 仍未命中的 fallback 到阿里云 ListInstances（6地域，3并发）
  var stillMissing = ids.filter(function(id) { return !map[id]; });
  if (stillMissing.length) {
    var regionIds = Object.keys(REGION_INFO);
    var concurrency = 3;
    var queue = regionIds.slice();
    var running = [];
    await new Promise(function(resolve) {
      function next() {
        if (queue.length === 0 && running.length === 0) { resolve(); return; }
        while (queue.length > 0 && running.length < concurrency) {
          var rid = queue.shift();
          var p = AliyunClient.listInstances(rid, { pageSize: 100 }).then(function(data) {
            var insts = data.Instances || [];
            insts.forEach(function(inst) { recordAliyun(inst, rid); });
          }).catch(function(err) {
            console.warn('[' + (REGION_INFO[rid] || rid) + '] listInstances failed:', err.message);
          });
          p.then(function() { running.splice(running.indexOf(p), 1); next(); });
          running.push(p);
        }
      }
      next();
    });
  }

  // 4) 汇总结果
  var rows = ids.map(function(id) {
    var m = map[id];
    return {
      id: id,
      region: m ? (m.region || '-') : '-',
      publicIp: m ? (m.publicIp || (m._ipSource ? '(字段:' + m._ipSource + ')' : '无')) : '未查询到',
      innerIp: m ? (m.innerIp || '无') : '未查询到',
      status: m ? (m.status || '-') : '-',
      from: m ? (m.from || '') : '',
      probe: m ? (m.probe || null) : null
    };
  });

  var csvHeader = '节点ID,地域,公网IP,内网IP,状态\n';
  var csvBody = rows.map(function(r) {
    return [r.id, r.region, r.publicIp.replace(/\(字段:[^\)]+\)/g, ''), r.innerIp, r.status].map(escapeCsv).join(',');
  }).join('\n');
  var csv = csvHeader + csvBody;
  var textPairs = rows.map(function(r) { return r.id + ' -> ' + r.publicIp; }).join('\n');
  var ipOnly = rows.map(function(r) { return r.publicIp; }).join('\n');

  var hitCount = ids.length - stillMissing.length;
  var errorTip = '';
  if (adminErrors.length) {
    errorTip = '<div style="margin-top:8px;color:#cf1322;font-size:12px;">⚠️ 后台接口探测失败 ' + adminErrors.length + ' 个。如果全部未命中，请在节点详情页按 F12 抓取真实接口 URL（Method + Path + 参数）后发给我。</div>';
  }

  // 收集探测摘要（调试用，默认折叠）
  var probeDetails = rows.filter(function(r){ return r.probe; }).map(function(r) {
    var pj = r.probe.json ? JSON.stringify(r.probe.json).slice(0, 180) : '空';
    return '<li style="margin:2px 0;font-family:monospace;font-size:11px;">' + escapeHtml(r.id) + ': ' + escapeHtml(r.probe.method + ' ' + r.probe.path) + ' -> HTTP ' + r.probe.status + ' | ' + escapeHtml(pj) + '</li>';
  }).join('');
  var probeHtml = probeDetails ? '<details style="margin-top:8px;font-size:12px;"><summary style="cursor:pointer;color:#666;">查看后台接口探测详情</summary><ul style="margin:4px 0;padding-left:18px;">' + probeDetails + '</ul></details>' : '';

  // 用隐藏 textarea 保存文本；按钮使用 data-action 事件委托，避免 onclick 引号注入
  var html = '<div style="background:#f6ffed;border:1px solid #b7eb8f;padding:12px;border-radius:6px;margin-top:10px;">' +
    '<div style="font-weight:600;margin-bottom:8px;">🌐 查询完成：' + ids.length + ' 个节点，命中 ' + hitCount + ' 个</div>' +
    '<div style="margin-bottom:10px;">' +
    '<button class="btn btn-sm btn-primary zy-export-btn" data-action="copy-ip">📋 复制IP列表</button>' +
    '<button class="btn btn-sm btn-primary zy-export-btn" data-action="copy-pair" style="margin-left:8px;">📋 复制节点ID→IP</button>' +
    '<button class="btn btn-sm btn-primary zy-export-btn" data-action="download-csv" style="margin-left:8px;">⬇️ 下载CSV</button>' +
    '</div>' +
    '<textarea id="zyExportIpOnly" style="display:none;">' + escapeHtml(ipOnly) + '</textarea>' +
    '<textarea id="zyExportIpPairs" style="display:none;">' + escapeHtml(textPairs) + '</textarea>' +
    '<textarea id="zyExportCsv" style="display:none;">' + escapeHtml(csv) + '</textarea>' +
    '<div style="max-height:300px;overflow-y:auto;border:1px solid #eee;background:#fff;">' +
    '<table style="width:100%;border-collapse:collapse;font-size:12px;"><thead><tr style="background:#f0f0f0;">' +
    '<th style="padding:6px;border:1px solid #ddd;text-align:left;">节点ID</th>' +
    '<th style="padding:6px;border:1px solid #ddd;text-align:left;">地域</th>' +
    '<th style="padding:6px;border:1px solid #ddd;text-align:left;">公网IP</th>' +
    '<th style="padding:6px;border:1px solid #ddd;text-align:left;">内网IP</th>' +
    '<th style="padding:6px;border:1px solid #ddd;text-align:left;">状态</th>' +
    '</tr></thead><tbody>' +
    rows.map(function(r) {
      return '<tr>' +
        '<td style="padding:6px;border:1px solid #eee;font-family:monospace;">' + escapeHtml(r.id) + '</td>' +
        '<td style="padding:6px;border:1px solid #eee;">' + escapeHtml(r.region) + '</td>' +
        '<td style="padding:6px;border:1px solid #eee;color:#1677ff;font-weight:500;">' + escapeHtml(r.publicIp) + '</td>' +
        '<td style="padding:6px;border:1px solid #eee;color:#666;">' + escapeHtml(r.innerIp) + '</td>' +
        '<td style="padding:6px;border:1px solid #eee;">' + escapeHtml(r.status) + '</td>' +
        '</tr>';
    }).join('') +
    '</tbody></table></div>' +
    '<div style="margin-top:8px;color:#666;font-size:12px;">查询顺序：① 页面实例缓存；② admin.zhouyi.top 节点详情接口（自动探测常见路径）；③ 阿里云 ListInstances 兜底。</div>' +
    probeHtml +
    errorTip +
    '</div>';

  st.innerHTML = html;
}
window.exportPublicIpsFromPaste = exportPublicIpsFromPaste;

function copyExportIp(kind) {
  var id = kind === 'ip' ? 'zyExportIpOnly' : 'zyExportIpPairs';
  var ta = document.getElementById(id);
  if (!ta) return;
  copyTextToClipboardImpl(ta.value);
}
window.copyExportIp = copyExportIp;

function downloadExportCsv() {
  var ta = document.getElementById('zyExportCsv');
  if (!ta) return;
  downloadCsvImpl('node-ips.csv', ta.value);
}
window.downloadExportCsv = downloadExportCsv;

// 导出公网IP结果区按钮事件委托（避免 innerHTML 中内联 onclick 引号问题）
document.addEventListener('click', function(e) {
  var btn = e.target.closest('.zy-export-btn');
  if (!btn) return;
  var action = btn.getAttribute('data-action');
  if (action === 'copy-ip') copyExportIp('ip');
  else if (action === 'copy-pair') copyExportIp('pair');
  else if (action === 'download-csv') downloadExportCsv();
});

function escapeCsv(v) {
  v = String(v == null ? '' : v);
  if (/[",\n\r]/.test(v)) return '"' + v.replace(/"/g, '""') + '"';
  return v;
}

function copyTextToClipboardImpl(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    return navigator.clipboard.writeText(text);
  }
  return new Promise(function(resolve, reject) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); resolve(); }
    catch (e) { reject(e); }
    finally { document.body.removeChild(ta); }
  });
}

function downloadCsvImpl(filename, content) {
  var blob = new Blob(['\ufeff' + content], { type: 'text/csv;charset=utf-8;' });
  var a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  setTimeout(function() { document.body.removeChild(a); URL.revokeObjectURL(a.href); }, 100);
}

// 保留旧的全局函数名，供其他地方可能用到
function copyTextToClipboard(btn, text) {
  copyTextToClipboardImpl(text).then(function() {
    var orig = btn.textContent;
    btn.textContent = '✅ 已复制';
    setTimeout(function() { btn.textContent = orig; }, 1500);
  }).catch(function(e) {
    alert('复制失败：' + e.message);
  });
}
window.copyTextToClipboard = copyTextToClipboard;

function downloadCsv(filename, content) {
  downloadCsvImpl(filename, content);
}
window.downloadCsv = downloadCsv;

/**
 * 云端数据层 v1.0
 * 基于 Supabase REST API，实现用户数据云端存储
 * 所有账号可在任意网络/任意设备登录
 * localStorage 作为本地缓存（离线降级）
 */
(function() {
  'use strict';

  // ====== Supabase 配置 ======
  var SUPABASE_URL = 'https://opauwtkivhjxlijfqaix.supabase.co';
  var SUPABASE_ANON_KEY = 'sb_publishable_SM9yvpcOBqvVPH2oGwTmFg_BZ1Lz9Xd';
  var REST_BASE = SUPABASE_URL + '/rest/v1';

  // ====== 内存缓存 ======
  var usersCache = null;       // 用户列表缓存
  var userDataCache = {};      // 按用户名隔离的数据缓存

  // ====== REST API 封装 ======
  function restRequest(method, table, query, body) {
    var url = REST_BASE + '/' + table;
    if (query) url += query;

    var headers = {
      'apikey': SUPABASE_ANON_KEY,
      'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
      'Content-Type': 'application/json'
    };
    if (body) headers['Prefer'] = 'return=representation';

    return fetch(url, {
      method: method,
      headers: headers,
      body: body ? JSON.stringify(body) : undefined
    }).then(function(resp) {
      if (!resp.ok) {
        return resp.text().then(function(txt) {
          throw new Error('Supabase ' + resp.status + ': ' + txt.substring(0, 200));
        });
      }
      return resp.json();
    });
  }

  // ====== 用户表操作 ======

  /**
   * 获取所有用户（兼容旧格式 {admin, users} ）
   */
  function getAllUsers() {
    if (usersCache) return Promise.resolve(usersCache);
    return restRequest('GET', 'app_users', '?select=username,password,role,created_by,created_at&order=username.asc')
      .then(function(rows) {
        var result = { admin: 'zhangruiyao', users: {} };
        for (var i = 0; i < rows.length; i++) {
          var r = rows[i];
          if (r.role === 'admin') {
            result.admin = r.username;
          } else {
            result.users[r.username] = {
              password: r.password,
              createdBy: r.created_by,
              createdAt: r.created_at
            };
          }
        }
        // 写入 localStorage 缓存
        try { localStorage.setItem('wb_users_cache', JSON.stringify(result)); } catch(e) {}
        usersCache = result;
        return result;
      })
      .catch(function(err) {
        // 云端失败，尝试 localStorage 缓存
        try {
          var cached = localStorage.getItem('wb_users_cache');
          if (cached) {
            usersCache = JSON.parse(cached);
            return usersCache;
          }
        } catch(e) {}
        throw err;
      });
  }

  /**
   * 添加用户
   */
  function addUser(username, password, createdBy) {
    return restRequest('POST', 'app_users', null, {
      username: username,
      password: password,
      role: 'user',
      created_by: createdBy,
      created_at: Date.now()
    }).then(function() {
      // 更新缓存
      if (usersCache) {
        usersCache.users[username] = {
          password: password,
          createdBy: createdBy,
          createdAt: Date.now()
        };
        try { localStorage.setItem('wb_users_cache', JSON.stringify(usersCache)); } catch(e) {}
      }
    });
  }

  /**
   * 删除用户
   */
  function deleteUser(username) {
    return restRequest('DELETE', 'app_users', '?username=eq.' + encodeURIComponent(username))
      .then(function() {
        if (usersCache && usersCache.users) {
          delete usersCache.users[username];
          try { localStorage.setItem('wb_users_cache', JSON.stringify(usersCache)); } catch(e) {}
        }
      });
  }

  /**
   * 验证用户（返回角色或 null）
   */
  function verifyUser(username, password) {
    return getAllUsers().then(function(db) {
      if (username === db.admin) {
        // 管理员密码硬编码验证（安全后门）
        if (password === '86966azr') return 'admin';
        return null;
      }
      if (db.users && db.users[username] && db.users[username].password === password) {
        return 'user';
      }
      return null;
    });
  }

  /**
   * 获取用户角色
   */
  function getUserRole(username) {
    return getAllUsers().then(function(db) {
      if (username === db.admin) return 'admin';
      if (db.users && db.users[username]) return 'user';
      return null;
    });
  }

  // ====== 用户数据表操作（凭证、AI 设置等） ======

  /**
   * 强制从云端重新加载用户数据（跳过缓存）
   * 用于换电脑时确保凭证从云端加载
   */
  function forceReloadUserData(username) {
    delete userDataCache[username];
    return getUserData(username, true);
  }

  /**
   * 获取用户数据（从云端，带缓存）
   * 返回 JSON 对象，如 { ak_id, ak_secret, ai_settings, ai_tokens }
   * @param forceRemote - true 时跳过缓存直接从云端拉取
   */
  function getUserData(username, forceRemote) {
    if (!forceRemote && userDataCache[username]) return Promise.resolve(userDataCache[username]);
    // 带重试的 REST 请求（换电脑时网络可能不稳定）
    function fetchWithRetry(attempt) {
      return restRequest('GET', 'user_data', '?username=eq.' + encodeURIComponent(username) + '&select=data')
        .then(function(rows) {
          var data = (rows && rows.length > 0 && rows[0].data) ? rows[0].data : {};
          userDataCache[username] = data;
          // 同步写入 localStorage 缓存
          try { localStorage.setItem('wb_ud_cache_' + username, JSON.stringify(data)); } catch(e) {}
          console.log('[cloud-store] getUserData(' + username + ') 成功, has_ak=' + !!data.ak_id + ' attempt=' + attempt);
          return data;
        })
        .catch(function(err) {
          console.warn('[cloud-store] getUserData(' + username + ') attempt=' + attempt + ' 失败:', err.message);
          if (attempt < 3) {
            // 重试：500ms → 1000ms 间隔
            return new Promise(function(r) { setTimeout(r, 500 * attempt); })
              .then(function() { return fetchWithRetry(attempt + 1); });
          }
          // 所有重试都失败，尝试 localStorage 缓存
          try {
            var cached = localStorage.getItem('wb_ud_cache_' + username);
            if (cached) {
              var d = JSON.parse(cached);
              userDataCache[username] = d;
              console.log('[cloud-store] getUserData(' + username + ') 回退到 localStorage 缓存, has_ak=' + !!d.ak_id);
              return d;
            }
          } catch(e) {}
          console.error('[cloud-store] getUserData(' + username + ') 所有重试失败，返回空对象');
          return {};
        });
    }
    return fetchWithRetry(1);
  }

  /**
   * 同步获取用户数据（从内存缓存 / localStorage 缓存）
   * 用于 API 调用时快速读取凭证
   * 注意：不会从云端拉取，如果缓存为空返回 {}
   */
  function getUserDataSync(username) {
    // 1. 内存缓存
    if (userDataCache[username]) return userDataCache[username];
    // 2. localStorage 缓存（wb_ud_cache_{username}）
    try {
      var cached = localStorage.getItem('wb_ud_cache_' + username);
      if (cached) {
        var d = JSON.parse(cached);
        userDataCache[username] = d;
        return d;
      }
    } catch(e) {}
    // 3. 兼容旧格式：直接读 wb_{username}_ak_id / wb_{username}_ak_secret
    try {
      var pfx = 'wb_' + username + '_';
      var akId = localStorage.getItem(pfx + 'ak_id');
      var akSecret = localStorage.getItem(pfx + 'ak_secret');
      if (akId && akSecret) {
        var d2 = { ak_id: akId, ak_secret: akSecret };
        userDataCache[username] = d2;
        return d2;
      }
    } catch(e) {}
    return {};
  }

  /**
   * 保存用户数据（写入云端 + 缓存）
   * 先尝试 PATCH（更新已有行）；若 PATCH 命中 0 行（行不存在，Supabase 返回空数组 200），
   * 则自动 POST 新建行。这样首次保存也能正确落库（修复「云端未确认到完整配置」）。
   */
  function setUserData(username, data) {
    // 先更新缓存
    userDataCache[username] = data;
    try { localStorage.setItem('wb_ud_cache_' + username, JSON.stringify(data)); } catch(e) {}

    var url = REST_BASE + '/user_data';
    var body = JSON.stringify({
      username: username,
      data: data,
      updated_at: Date.now()
    });

    function doPost() {
      return fetch(url, {
        method: 'POST',
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
          'Content-Type': 'application/json',
          'Prefer': 'return=representation'
        },
        body: body
      }).then(function(resp2) {
        if (!resp2.ok) {
          return resp2.text().then(function(txt) {
            throw new Error('Supabase setUserData POST ' + resp2.status + ': ' + txt.substring(0, 200));
          });
        }
        return resp2.json();
      });
    }

    // 先尝试 PATCH（行已存在的情况）
    return fetch(url + '?username=eq.' + encodeURIComponent(username), {
      method: 'PATCH',
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
        'Content-Type': 'application/json',
        'Prefer': 'return=representation'
      },
      body: body
    }).then(function(resp) {
      if (!resp.ok) {
        // PATCH 非 2xx，直接 POST 新建
        return doPost();
      }
      return resp.json().then(function(rows) {
        // ⚠️ 关键修复：PATCH 命中 0 行时返回空数组（200），需改 POST 新建
        if (rows && rows.length > 0) return rows;
        return doPost();
      });
    });
  }

  /**
   * 更新用户数据的某个字段（合并写入）
   */
  function updateUserData(username, patch) {
    return getUserData(username).then(function(existing) {
      var merged = Object.assign({}, existing, patch);
      return setUserData(username, merged);
    });
  }

  // ====== 公开 API ======
  window.CloudStore = {
    getAllUsers: getAllUsers,
    addUser: addUser,
    deleteUser: deleteUser,
    verifyUser: verifyUser,
    getUserRole: getUserRole,
    getUserData: getUserData,
    getUserDataSync: getUserDataSync,
    forceReloadUserData: forceReloadUserData,
    setUserData: setUserData,
    updateUserData: updateUserData,

    // 清除缓存（登出时调用）
    clearCache: function() {
      usersCache = null;
      userDataCache = {};
    },

    // 预加载用户数据（登录后调用，强制从云端拉取确保凭证同步）
    preload: function(username) {
      // forceRemote=true → 跳过内存缓存，确保从云端拉最新数据
      return getUserData(username, true).then(function(data) {
        // 同步到旧版 localStorage key（兼容 aliyun-client.js 和 app.js 的直接读取）
        try {
          var pfx = 'wb_' + username + '_';
          if (data.ak_id) localStorage.setItem(pfx + 'ak_id', data.ak_id);
          if (data.ak_secret) localStorage.setItem(pfx + 'ak_secret', data.ak_secret);
          if (data.ai_settings) localStorage.setItem(pfx + 'ai_settings', JSON.stringify(data.ai_settings));
          if (data.ai_tokens) localStorage.setItem(pfx + 'ai_tokens', data.ai_tokens);
        } catch(e) {}
        console.log('[cloud-store] preload(' + username + ') 完成: has_ak=' + !!data.ak_id + ' has_sk=' + !!data.ak_secret);
        return data;
      });
    }
  };

  console.log('[cloud-store] 云端数据层已就绪');
})();

/**
 * 云端数据层 v2.0（2026-11-16 安全加固）
 *
 * 改动要点：
 *   1. **不再持有能读全表的 Supabase 公开 key**（原 sb_publishable_… 明文写在这里，
 *      任何人都能拖库拿全部账号密码 + 每个账号的阿里云 AK/SK）。
 *      所有读写改走服务端鉴权网关 wb-auth（Edge Function），前端只拿到
 *      服务端签发的、绑定账号的 HMAC 短时票据。
 *   2. **删除管理员密码硬编码**（原 verifyUser 里明文比较 '86966azr'）。
 *      登录一律由 wb-auth 在服务端校验，前端拿不到任何口令。
 *   3. **不再把全账号口令缓存进 localStorage**（原 wb_users_cache 里存着所有
 *      用户的明文密码）。旧缓存会被自动清理。
 *   4. 越权防护下沉到服务端：普通用户的票据只能读写自己的数据；
 *      用户增删改查仅管理员可用。
 *
 * 离线降级策略保留：网络异常时回退本地缓存 wb_ud_cache_<username>。
 */
(function() {
  'use strict';

  // ====== 服务端鉴权网关（多入口，主入口不通时自动降级）======
  // ① 主：Supabase Edge Function（Cloudflare 国际 IP，部分国内线路不通）
  // ② 备：阿里云 FC 境内镜像（cn-hangzhou.fcapp.run，境内可达）
  // 两端共用同一个 WB_AUTH_SECRET → 票据互通，走哪条路都无感。
  var AUTH_URLS = [
    'https://opauwtkivhjxlijfqaix.supabase.co/functions/v1/wb-auth',
    'https://auth-schedulfund-svc-tzsnybzlnd.cn-hangzhou.fcapp.run'
  ];
  var TICKET_PREFIX = 'wb_auth_ticket_';   // 按账号分桶，避免同一台机器切号串票
  var STALE_USERS_CACHE = 'wb_users_cache'; // 旧版全账号明文口令缓存，启动即清

  // ====== 内存缓存 ======
  var userDataCache = {};      // 按用户名隔离的数据缓存
  var sessionCache = null;     // {username, role, expiresAt}

  // ====== 票据存取 ======
  function ticketKey(username) { return TICKET_PREFIX + username; }

  function readTicket(username) {
    if (!username) return null;
    var v = null;
    try { v = sessionStorage.getItem(ticketKey(username)); } catch(e) {}
    if (!v) { try { v = localStorage.getItem(ticketKey(username)); } catch(e) {} }
    if (!v) return null;
    try {
      var t = JSON.parse(v);
      if (!t || !t.ticket) return null;
      if (t.expiresAt && Date.now() > t.expiresAt) { clearTicket(username); return null; }
      return t;
    } catch(e) { return null; }
  }

  function saveTicket(username, ticket, role, expiresAt) {
    var payload = JSON.stringify({ ticket: ticket, role: role, expiresAt: expiresAt || 0 });
    try { sessionStorage.setItem(ticketKey(username), payload); } catch(e) {}
    try { localStorage.setItem(ticketKey(username), payload); } catch(e) {}
    sessionCache = { username: username, role: role, expiresAt: expiresAt || 0 };
  }

  function clearTicket(username) {
    if (!username) return;
    try { sessionStorage.removeItem(ticketKey(username)); } catch(e) {}
    try { localStorage.removeItem(ticketKey(username)); } catch(e) {}
  }

  /** 当前登录账号名：取工作台登录态（wb_logged_in_v2），保证切号后用对应账号的票 */
  function loggedInUsername() {
    try {
      var raw = null;
      try { raw = sessionStorage.getItem('wb_logged_in_v2'); } catch(e) {}
      if (!raw) { try { raw = localStorage.getItem('wb_logged_in_v2'); } catch(e) {} }
      if (!raw) return null;
      var o = JSON.parse(raw);
      return (o && o.user) ? o.user : null;
    } catch(e) { return null; }
  }

  /**
   * 当前登录账号的票据。
   * ⚠️ 必须按「当前登录账号」取票，不能随便扫一个桶：同一台电脑可能登录过多个
   *    账号，用错票会被服务端按 payload.u 判成越权（403）。
   * ⚠️ 页面刷新后 sessionCache 是空的，靠 wb_logged_in_v2 + 按账号分桶的票据恢复。
   */
  function currentTicket() {
    var u = loggedInUsername() || (sessionCache && sessionCache.username) || null;
    if (!u) return null;
    var t = readTicket(u);
    if (!t) {
      if (sessionCache && sessionCache.username === u) sessionCache = null;
      return null;
    }
    sessionCache = { username: u, ticket: t.ticket, role: t.role, expiresAt: t.expiresAt };
    return sessionCache;
  }

  // ====== 网关调用 ======
  /**
   * 调用鉴权网关（**多入口自动降级**）。
   *
   * ⚠️ 2026-11-17 为什么要有两个入口：
   *    主入口 Supabase Edge Function 的域名解析到 Cloudflare 国际 IP
   *    （104.18.38.10 / 172.64.149.246），部分中国大陆运营商线路不通，
   *    浏览器直接抛 "Failed to fetch"，与账号无关。
   *    备入口是同一套鉴权网关的**阿里云 FC 境内镜像**
   *    （cn-hangzhou.fcapp.run），境内可达。
   *    两端共用同一个 WB_AUTH_SECRET → 签发的票据互相通用，
   *    用户走哪条路登录都无感，后续换 tool 票、读数据都不受影响。
   *
   * 降级规则：
   *    · 仅当**网络层失败**（连不上）才换入口；
   *    · 服务端明确拒绝（401 / ok:false）是业务响应，各入口一致，不换。
   */
  function authCall(action, extra) {
    var body = Object.assign({ action: action }, extra || {});
    var lastErr = null;

    function attempt(idx) {
      if (idx >= AUTH_URLS.length) {
        var e0 = new Error('无法连接鉴权服务（' +
          (lastErr ? lastErr.netDetail : '所有入口均不可达') + '）');
        e0.netError = true;
        e0.netDetail = lastErr ? lastErr.netDetail : '所有入口均不可达';
        e0.cause = lastErr ? lastErr.cause : null;
        return Promise.reject(e0);
      }
      return fetch(AUTH_URLS[idx], {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
      }).then(function(resp) {
        return resp.text().then(function(txt) {
          var r = {};
          if (txt && txt.trim()) {
            try { r = JSON.parse(txt); }
            catch (e) { throw new Error('网关返回非 JSON 内容：' + txt.substring(0, 120)); }
          }
          if (resp.status === 401 || r.ok === false) {
            var err = new Error(r.error || ('网关 HTTP ' + resp.status));
            err.status = resp.status;
            err.authFailed = (resp.status === 401);
            throw err;
          }
          return r;
        });
      }, function(cause) {
        // 网络层失败：连接不上 / DNS 解析失败 / TLS 被拦 / CORS 预检被拦
        var err = new Error('无法连接鉴权服务（' + netReason(cause) + '）');
        err.netError = true;
        err.netDetail = netReason(cause);
        err.cause = cause;
        lastErr = err;
        if (idx + 1 < AUTH_URLS.length) {
          console.warn('[cloud-store] 入口 ' + idx + ' 不可达，自动切换到备入口 ' + (idx + 1));
          return attempt(idx + 1);
        }
        throw err;
      });
    }
    return attempt(0);
  }

  /** 把浏览器的原始网络异常翻译成人能看懂的原因 */
  function netReason(cause) {
    var msg = (cause && cause.message) ? String(cause.message) : '';
    if (/Failed to fetch/i.test(msg)) {
      return '网络请求被拦截或超时（DNS/代理/CORS 预检），请检查网络后重试';
    }
    if (/NetworkError|ERR_INTERNET_DISCONNECTED/i.test(msg)) {
      return '网络已断开，请检查本机网络连接';
    }
    if (/timeout|ETIMEDOUT/i.test(msg)) {
      return '连接鉴权服务超时，请稍后重试';
    }
    return msg || '未知网络错误';
  }

  /** 需要票据的调用：自动附带当前票据；401 时清票并抛出（前端可跳登录） */
  function authCallAuthed(action, extra) {
    var t = currentTicket();
    if (!t) {
      var e = new Error('登录已失效，请重新登录');
      e.authFailed = true;
      return Promise.reject(e);
    }
    return authCall(action, Object.assign({ ticket: t.ticket }, extra || {}))
      .catch(function(err) {
        if (err.authFailed) {
          try { clearTicket(t.username); } catch(e2) {}
          sessionCache = null;
        }
        throw err;
      });
  }

  // ====== 启动清理：干掉旧版含明文口令的缓存 =====
  (function purgeLegacyCaches() {
    try {
      if (localStorage.getItem(STALE_USERS_CACHE)) {
        localStorage.removeItem(STALE_USERS_CACHE);
        console.log('[cloud-store] 已清理旧版用户库缓存（含明文口令）');
      }
    } catch(e) {}
  })();

  // ====== 登录 / 用户表操作 ======

  /**
   * 验证用户（返回角色或 null）。口令由服务端校验，前端不接触任何口令。
   *
   * ⚠️ 2026-11-17 修复误报：
   *   - 服务端明确拒绝（账号或密码错误）→ 返回 null（登录页显示「账号或密码错误」）
   *   - 网络层失败（连不上鉴权服务）→ 抛出 netError（登录页显示「网络不通」）
   *   原实现把两者都 catch 成 null，导致用户明明网络不通，却一直被提示「密码错误」。
   */
  function verifyUser(username, password) {
    return authCall('login', { username: username, password: password })
      .then(function(r) {
        saveTicket(r.username || username, r.ticket, r.role, r.expiresAt);
        console.log('[cloud-store] 登录成功:', r.username, '(' + r.role + ')');
        return r.role;
      })
      .catch(function(err) {
        if (err && err.netError) {
          // 网络故障：必须向上抛，不能伪装成「密码错误」
          console.warn('[cloud-store] 登录失败（网络不可达）:', err.netDetail);
          throw err;
        }
        console.warn('[cloud-store] 登录失败:', err.message);
        return null;
      });
  }

  /**
   * 获取所有用户（仅管理员）。返回值不含任何口令。
   */
  function getAllUsers() {
    return authCallAuthed('list_users').then(function(r) {
      return { admin: r.admin || 'zhangruiyao', users: r.users || {} };
    });
  }

  /**
   * 添加用户（仅管理员）
   */
  function addUser(username, password, createdBy) {
    return authCallAuthed('add_user', {
      username: username, password: password, createdBy: createdBy
    }).then(function() { return getAllUsers(); });
  }

  /**
   * 删除用户（仅管理员）
   */
  function deleteUser(username) {
    return authCallAuthed('delete_user', { username: username }).then(function() {
      return getAllUsers();
    }).then(function(db) {
      if (db.users && db.users[username]) {
        throw new Error('云端仍未删除【' + username + '】');
      }
      return db;
    });
  }

  /**
   * 获取用户角色（本地票据即可，不再读全表）
   */
  function getUserRole(username) {
    var t = readTicket(username);
    if (t && t.role) return Promise.resolve(t.role);
    return Promise.resolve(null);
  }

  // ====== 用户数据表操作（凭证、AI 设置等） ======

  /**
   * 强制从云端重新加载用户数据（跳过缓存）
   */
  function forceReloadUserData(username) {
    delete userDataCache[username];
    return getUserData(username, true);
  }

  /**
   * 获取用户数据（经服务端网关，带缓存）
   * ⚠️ 服务端会校验票据归属：普通用户读别人 → 403
   */
  function getUserData(username, forceRemote) {
    if (!forceRemote && userDataCache[username]) return Promise.resolve(userDataCache[username]);
    function fetchWithRetry(attempt) {
      return authCallAuthed('get_user_data', { username: username })
        .then(function(r) {
          var data = r.data || {};
          userDataCache[username] = data;
          try { localStorage.setItem('wb_ud_cache_' + username, JSON.stringify(data)); } catch(e) {}
          console.log('[cloud-store] getUserData(' + username + ') 成功, has_ak=' + !!data.ak_id + ' attempt=' + attempt);
          return data;
        })
        .catch(function(err) {
          if (err.authFailed) throw err;   // 票据失效 → 不再重试，直接跳登录
          console.warn('[cloud-store] getUserData(' + username + ') attempt=' + attempt + ' 失败:', err.message);
          if (attempt < 3) {
            return new Promise(function(res) { setTimeout(res, 500 * attempt); })
              .then(function() { return fetchWithRetry(attempt + 1); });
          }
          // 回退本地缓存（离线降级）
          try {
            var cached = localStorage.getItem('wb_ud_cache_' + username);
            if (cached) {
              var d = JSON.parse(cached);
              userDataCache[username] = d;
              console.log('[cloud-store] getUserData(' + username + ') 回退到 localStorage 缓存');
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
   */
  function getUserDataSync(username) {
    if (userDataCache[username]) return userDataCache[username];
    try {
      var cached = localStorage.getItem('wb_ud_cache_' + username);
      if (cached) {
        var d = JSON.parse(cached);
        userDataCache[username] = d;
        return d;
      }
    } catch(e) {}
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
   * ⚠️ 服务端会校验归属：普通用户写别人 → 403
   */
  function setUserData(username, data) {
    userDataCache[username] = data;
    try { localStorage.setItem('wb_ud_cache_' + username, JSON.stringify(data)); } catch(e) {}
    return authCallAuthed('set_user_data', { username: username, data: data })
      .then(function(r) { return r; });
  }

  /**
   * 更新用户数据的某些字段（合并写入）
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

    // ====== 新增：工具页（批量命令）与诊断用 ======

    /** 网关健康探针（无需登录） */
    ping: function() {
      return authCall('ping', {});
    },

    /** 换一张短时工具票（10 分钟），供独立域名的批量命令页使用 */
    getToolTicket: function() {
      return authCallAuthed('tool_ticket').then(function(r) {
        return { ticket: r.ticket, username: r.username, role: r.role, expiresAt: r.expiresAt };
      });
    },

    /** 工具票读指定账号数据（仅限票据所属账号） */
    getToolUserData: function(username) {
      var t = currentTicket();
      if (!t) {
        var e = new Error('登录已失效，请重新登录');
        e.authFailed = true;
        return Promise.reject(e);
      }
      return authCall('tool_user_data', { ticket: t.ticket, username: username })
        .then(function(r) { return r.data || {}; });
    },

    /** 当前登录账号名（票据里带的，登录后才有） */
    currentUser: function() {
      var t = currentTicket();
      return t ? t.username : (sessionCache ? sessionCache.username : null);
    },

    /** 当前登录角色 */
    currentRole: function() {
      var t = currentTicket();
      return t ? t.role : (sessionCache ? sessionCache.role : null);
    },

    // 清除缓存（登出时调用）
    clearCache: function() {
      userDataCache = {};
      var u = sessionCache ? sessionCache.username : null;
      if (u) clearTicket(u);
      sessionCache = null;
    },

    // 预加载用户数据（登录后调用，强制从云端拉取确保凭证同步）
    preload: function(username) {
      return getUserData(username, true).then(function(data) {
        // 同步到旧版 localStorage key（兼容 aliyun-client.js 和 app.js 的直接读取）
        try {
          var pfx = 'wb_' + username + '_';
          if (data.ak_id) localStorage.setItem(pfx + 'ak_id', data.ak_id);
          if (data.ak_secret) localStorage.setItem(pfx + 'ak_secret', data.ak_secret);
          if (data.ai_settings) localStorage.setItem(pfx + 'ai_settings', JSON.stringify(data.ai_settings));
          if (data.ai_tokens) localStorage.setItem(pfx + 'ai_tokens', data.ai_tokens);
        } catch(e) {}
        console.log('[cloud-store] preload(' + username + ') 完成: has_ak=' + !!data.ak_id);
        return data;
      });
    }
  };

  console.log('[cloud-store] 云端数据层 v2.0 已就绪（服务端鉴权网关）');
})();

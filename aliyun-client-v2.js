/**
 * 阿里云 SWAS-OPEN API 浏览器端客户端 v2.0
 * 使用 Web Crypto API 实现 RPC (AK) 签名，无需后端服务器
 * 支持多账号数据隔离：凭证按用户名独立存储
 * 交易类 API（CreateOrder/ListPlans/ListImages）全部走 Supabase Edge Function 代理，
 * 避开浏览器 → swas-open.aliyuncs.com 的 CORS 黑名单
 */
(function() {
  'use strict';

  // 🔥 启动标记：如果看不到这一行，说明 v2 文件没被加载
  console.log('%c[aliyun-client-v2] v2.4 - 凭证云端同步(重试)+多ProductCode自动探测', 'background:#ff5722;color:white;padding:4px 8px;font-weight:bold;border-radius:4px;');
  console.log('[aliyun-client-v2] 加载时间:', new Date().toISOString());

  // ====== 强制拦截：所有打到 swas-open.aliyuncs.com 的请求改走 Edge Function 代理 ======
  // 防御性：万一还有遗留代码或缓存 JS 直接 fetch 这个域名
  (function() {
    var _origFetch = window.fetch;
    window.fetch = function(input, init) {
      var url = (typeof input === 'string') ? input : (input && input.url) || '';
      if (url.indexOf('swas-open.aliyuncs.com') >= 0) {
        console.warn('[aliyun-client-v2] 拦截到对 swas-open.aliyuncs.com 的直连请求，强制改走 Edge Function 代理');
        try {
          var body = (init && init.body) || '';
          // 把 form body 解析成 params
          var params = {};
          if (body && body.indexOf('=') >= 0) {
            body.split('&').forEach(function(kv) {
              var idx = kv.indexOf('=');
              if (idx > 0) {
                var k = decodeURIComponent(kv.substring(0, idx).replace(/\+/g, ' '));
                var v = decodeURIComponent(kv.substring(idx + 1).replace(/\+/g, ' '));
                params[k] = v;
              }
            });
          }
          var action = params.Action || 'unknown';
          // 提取除公共参数外的业务参数
          var bizParams = {};
          Object.keys(params).forEach(function(k) {
            if (['AccessKeyId','Action','Format','SignatureMethod','SignatureNonce','SignatureVersion','Timestamp','Version','Signature'].indexOf(k) < 0) {
              bizParams[k] = params[k];
            }
          });
          return _origFetch.call(this, window.WB_SUPABASE_FUNCTIONS + '/aliyun-proxy', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              action: action,
              ak_id: getAccessKeyId ? getAccessKeyId() : '',
              ak_secret: getAccessKeySecret ? getAccessKeySecret() : '',
              params: bizParams
            })
          });
        } catch (e) {
          console.error('[aliyun-client-v2] 拦截改写失败：', e);
          return _origFetch.apply(this, arguments);
        }
      }
      return _origFetch.apply(this, arguments);
    };
  })();

  const API_VERSION = '2020-06-01';

  // ====== 用户命名空间（多账号数据隔离） ======
  function getCurrentUser() {
    try {
      var key = 'wb_logged_in_v2';
      var raw = sessionStorage.getItem(key) || localStorage.getItem(key);
      if (raw) {
        var u = JSON.parse(raw).user;
        if (u) return u;
      }
    } catch(e) {}
    return 'default';
  }

  function getUserPrefix() {
    var u = getCurrentUser();
    return u !== 'default' ? 'wb_' + u + '_' : 'wb_default_';
  }

  function akKey() { return getUserPrefix() + 'ak_id'; }
  function skKey() { return getUserPrefix() + 'ak_secret'; }
  // ====== v6: 多凭证 profile 管理 ======
  // 凭证列表 存储结构：[{name, ak_id, ak_secret, note, created_at, updated_at}, ...]
  // 活跃凭证名 单独存一个 key，存的是某个 profile 的 name
  function profilesKey() { return getUserPrefix() + 'ak_profiles'; }
  function activeProfileKey() { return getUserPrefix() + 'ak_active'; }
  // ====== v6: 兼容旧的单组 AK/SK（一次性迁移到名为"默认"的 profile） ======
  (function migrateLegacyIfNeeded() {
    try {
      var flagKey = getUserPrefix() + 'ak_migrated_v6';
      if (localStorage.getItem(flagKey) === '1') return;
      var profiles = listProfilesLocal();
      var legacyAk = localStorage.getItem(akKey());
      var legacySk = localStorage.getItem(skKey());
      if (legacyAk && legacySk && (!profiles || !profiles.length)) {
        profiles = profiles || [];
        profiles.push({
          name: '默认',
          ak_id: legacyAk,
          ak_secret: legacySk,
          note: '从旧凭证自动迁移',
          created_at: Date.now(),
          updated_at: Date.now()
        });
        localStorage.setItem(profilesKey(), JSON.stringify(profiles));
        localStorage.setItem(activeProfileKey(), '默认');
      }
      localStorage.setItem(flagKey, '1');
    } catch(e) { console.warn('[aliyun-client] 旧凭证迁移失败', e); }
  })();

  function listProfilesLocal() {
    try {
      var raw = localStorage.getItem(profilesKey());
      var arr = raw ? JSON.parse(raw) : [];
      return Array.isArray(arr) ? arr : [];
    } catch(e) { return []; }
  }

  function saveProfilesLocal(arr) {
    localStorage.setItem(profilesKey(), JSON.stringify(arr || []));
  }

  function getAccessKeyId() {
    // 优先读 active profile
    var profiles = listProfilesLocal();
    var active = localStorage.getItem(activeProfileKey());
    var hasProfileFlag = !!localStorage.getItem(getUserPrefix() + 'ak_profiles') || profiles.length > 0;
    if (profiles.length && active) {
      var p = profiles.find(function(x) { return x.name === active; });
      if (p && p.ak_id) return p.ak_id;
      if (profiles[0].ak_id) {
        localStorage.setItem(activeProfileKey(), profiles[0].name);
        return profiles[0].ak_id;
      }
    }
    if (hasProfileFlag) {
      // 用户进入过 profile 系统（哪怕现在列表为空、active 也被清），不回退到旧 key
      if (profiles.length && !active && profiles[0].ak_id) {
        localStorage.setItem(activeProfileKey(), profiles[0].name);
        return profiles[0].ak_id;
      }
      return '';
    }
    // 还没启用过 profile 系统：回退到旧的单组 key（支持首次启动自动迁移）
    var leg = localStorage.getItem(akKey()) || (window.CloudStore && CloudStore.getUserDataSync(getCurrentUser()) ? CloudStore.getUserDataSync(getCurrentUser()).ak_id : '') || '';
    return leg || '';
  }

  function getAccessKeySecret() {
    var profiles = listProfilesLocal();
    var active = localStorage.getItem(activeProfileKey());
    var hasProfileFlag = !!localStorage.getItem(getUserPrefix() + 'ak_profiles') || profiles.length > 0;
    if (profiles.length && active) {
      var p = profiles.find(function(x) { return x.name === active; });
      if (p && p.ak_secret) return p.ak_secret;
      if (profiles[0].ak_secret) return profiles[0].ak_secret;
    }
    if (hasProfileFlag) {
      return '';
    }
    var leg = localStorage.getItem(skKey()) || (window.CloudStore && CloudStore.getUserDataSync(getCurrentUser()) ? CloudStore.getUserDataSync(getCurrentUser()).ak_secret : '') || '';
    return leg || '';
  }

  // ====== HMAC-SHA1 实现 (Web Crypto API) ======
  const encoder = new TextEncoder();

  async function hmacSha1(key, data) {
    const cryptoKey = await crypto.subtle.importKey(
      'raw',
      typeof key === 'string' ? encoder.encode(key) : key,
      { name: 'HMAC', hash: 'SHA-1' },
      false,
      ['sign']
    );
    const signature = await crypto.subtle.sign('HMAC', cryptoKey, typeof data === 'string' ? encoder.encode(data) : data);
    return new Uint8Array(signature);
  }

  async function sha1(data) {
    const hash = await crypto.subtle.digest('SHA-1', typeof data === 'string' ? encoder.encode(data) : data);
    return new Uint8Array(hash);
  }

  function toHex(buffer) {
    return Array.from(new Uint8Array(buffer)).map(b => b.toString(16).padStart(2, '0')).join('');
  }

  function base64Encode(buffer) {
    let binary = '';
    const bytes = new Uint8Array(buffer);
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
  }

  function uuid4() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
      const r = Math.random() * 16 | 0;
      return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
    });
  }

  function percentEncode(str) {
    return encodeURIComponent(str)
      .replace(/!/g, '%21')
      .replace(/'/g, '%27')
      .replace(/\(/g, '%28')
      .replace(/\)/g, '%29')
      .replace(/\*/g, '%2A')
      .replace(/\+/g, '%20')
      .replace(/%7E/g, '~');
  }

  // ====== 核心：阿里云 RPC AK 签名 + API 调用 ======
  async function callAliyunApi(regionId, action, params) {
    const accessKeyId = getAccessKeyId();
    const accessKeySecret = getAccessKeySecret();

    if (!accessKeyId || !accessKeySecret) {
      throw new Error('请先设置阿里云 AK/SK 凭证');
    }

    // 公共参数
    const commonParams = {
      AccessKeyId: accessKeyId,
      Action: action,
      Format: 'JSON',
      SignatureMethod: 'HMAC-SHA1',
      SignatureNonce: uuid4(),
      SignatureVersion: '1.0',
      Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
      Version: API_VERSION,
    };

    // 合并所有参数
    const allParams = { ...commonParams, ...params };

    // 排序并构建规范化查询字符串
    const sortedKeys = Object.keys(allParams).sort();
    const canonicalParts = [];
    for (const key of sortedKeys) {
      const value = allParams[key];
      if (value === undefined || value === null) continue;
      // 处理嵌套对象（转为 JSON 字符串）
      let valueStr;
      if (typeof value === 'object') {
        valueStr = JSON.stringify(value);
      } else {
        valueStr = String(value);
      }
      canonicalParts.push(percentEncode(key) + '=' + percentEncode(valueStr));
    }
    const canonicalQuery = canonicalParts.join('&');

    // 构建待签名字符串
    const stringToSign = 'POST&' + percentEncode('/') + '&' + percentEncode(canonicalQuery);

    // 签名
    const signKey = accessKeySecret + '&';
    const signatureBytes = await hmacSha1(signKey, stringToSign);
    const signature = base64Encode(signatureBytes);

    // 添加签名参数
    const finalQuery = canonicalQuery + '&' + percentEncode('Signature') + '=' + percentEncode(signature);

    // 发送请求
    const endpoint = `https://swas.${regionId}.aliyuncs.com/`;
    console.log('[aliyun-client]', action, regionId);

    const response = await fetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: finalQuery,
    });

    if (!response.ok) {
      const text = await response.text();
      let errMsg = `HTTP ${response.status}`;
      try {
        const errJson = JSON.parse(text);
        errMsg = errJson.Message || errJson.Code || errMsg;
      } catch (e) {}
      throw new Error(errMsg);
    }

    const data = await response.json();
    return data;
  }

  // ====== 公开 API ======
  function setCredentials(accessKeyId, accessKeySecret) {
    // v6 兼容旧 API——自动归到「默认」 profile 并设为活跃
    return saveProfile({ name: '默认', ak_id: accessKeyId, ak_secret: accessKeySecret, setActive: true });
  }

  function hasCredentials() {
    return !!(getAccessKeyId() && getAccessKeySecret());
  }

  function getCredentialsInfo() {
    var p = getActiveProfile();
    return {
      accessKeyId: p ? p.ak_id : getAccessKeyId(),
      profileName: p ? p.name : '',
      profileCount: listProfiles().length
    };
  }

  function getAccessKeyIdPublic() { return getAccessKeyId(); }
  function getAccessKeySecretPublic() { return getAccessKeySecret(); }

  function clearCredentials() {
    localStorage.removeItem(profilesKey());
    localStorage.removeItem(activeProfileKey());
    localStorage.removeItem(akKey());
    localStorage.removeItem(skKey());
    if (window.CloudStore) {
      var u = getCurrentUser();
      if (u !== 'default') CloudStore.updateUserData(u, { ak_id: '', ak_secret: '', ak_profiles: [], ak_active: '' });
    }
  }

  function listProfiles() {
    return listProfilesLocal().map(function(p) {
      var hint = '';
      if (p.ak_id) hint = p.ak_id.substring(0, 6) + '...' + p.ak_id.substring(Math.max(p.ak_id.length - 4, 6));
      return {
        name: p.name,
        ak_id: p.ak_id,
        ak_id_hint: hint,
        note: p.note || '',
        created_at: p.created_at || 0,
        updated_at: p.updated_at || 0,
        active: p.name === (localStorage.getItem(activeProfileKey()) || '')
      };
    });
  }

  function getActiveProfile() {
    var profiles = listProfilesLocal();
    var active = localStorage.getItem(activeProfileKey());
    if (!profiles.length) return null;
    var p = profiles.find(function(x) { return x.name === active; }) || profiles[0];
    var hint = '';
    if (p.ak_id) hint = p.ak_id.substring(0, 6) + '...' + p.ak_id.substring(Math.max(p.ak_id.length - 4, 6));
    return { name: p.name, ak_id: p.ak_id, ak_id_hint: hint, note: p.note || '' };
  }

  function useProfile(name) {
    var profiles = listProfilesLocal();
    var p = profiles.find(function(x) { return x.name === name; });
    if (!p) return Promise.reject(new Error('凭证「' + name + '」不存在'));
    localStorage.setItem(activeProfileKey(), name);
    return syncProfilesToCloud();
  }

  function saveProfile(params) {
    params = params || {};
    var name = (params.name || '').trim();
    var akId = (params.ak_id || '').trim();
    var akSecret = (params.ak_secret || '').trim();
    if (!name) return Promise.reject(new Error('请填写凭证名称'));
    if (!akId || !akSecret) return Promise.reject(new Error('请填写完整的 AccessKey ID 和 Secret'));
    var profiles = listProfilesLocal();
    var existing = profiles.find(function(x) { return x.name === name; });
    if (existing && !params.overwrite) {
      return Promise.reject(new Error('已存在同名凭证「' + name + '」，如需覆盖请使用 overwrite=true'));
    }
    if (existing) {
      existing.ak_id = akId;
      existing.ak_secret = akSecret;
      existing.note = params.note || existing.note || '';
      existing.updated_at = Date.now();
    } else {
      profiles.push({
        name: name,
        ak_id: akId,
        ak_secret: akSecret,
        note: params.note || '',
        created_at: Date.now(),
        updated_at: Date.now()
      });
    }
    saveProfilesLocal(profiles);
    if (params.setActive !== false) {
      localStorage.setItem(activeProfileKey(), name);
    }
    return syncProfilesToCloud();
  }

  function deleteProfile(name) {
    var profiles = listProfilesLocal();
    var idx = profiles.findIndex(function(x) { return x.name === name; });
    if (idx < 0) return Promise.reject(new Error('凭证「' + name + '」不存在'));
    profiles.splice(idx, 1);
    saveProfilesLocal(profiles);
    if (localStorage.getItem(activeProfileKey()) === name) {
      if (profiles.length) {
        localStorage.setItem(activeProfileKey(), profiles[0].name);
      } else {
        localStorage.removeItem(activeProfileKey());
      }
    }
    return syncProfilesToCloud();
  }

  function syncProfilesToCloud() {
    return new Promise(function(resolve) {
      var p = getActiveProfileSecret();
      if (p) {
        localStorage.setItem(akKey(), p.ak_id);
        localStorage.setItem(skKey(), p.ak_secret);
      }
      if (window.CloudStore) {
        var u = getCurrentUser();
        if (u !== 'default') {
          var patch = {
            ak_profiles: listProfilesLocal(),
            ak_active: localStorage.getItem(activeProfileKey()) || ''
          };
          if (p) { patch.ak_id = p.ak_id; patch.ak_secret = p.ak_secret; }
          CloudStore.updateUserData(u, patch)
            .then(function() { console.log('[aliyun-client] 凭证已同步到云端: ' + u); resolve({ ok: true }); })
            .catch(function(err) {
              console.error('[aliyun-client] 凭证云端同步失败: ' + err.message + '，3秒后重试');
              setTimeout(function() {
                CloudStore.updateUserData(u, patch)
                  .then(function() { console.log('[aliyun-client] 凭证重试同步成功'); resolve({ ok: true }); })
                  .catch(function(e) { console.error('[aliyun-client] 凭证重试仍失败: ' + e.message); resolve({ ok: false, error: e.message }); });
              }, 3000);
            });
          return;
        }
      }
      resolve({ ok: true, cloud: false });
    });
  }

  function pullProfilesFromCloud() {
    if (!window.CloudStore) return Promise.resolve({ ok: false });
    var u = getCurrentUser();
    return CloudStore.getUserData(u).then(function(data) {
      if (!data) return { ok: false };
      var local = listProfilesLocal();
      if (data.ak_profiles && Array.isArray(data.ak_profiles) && data.ak_profiles.length) {
        var merged = data.ak_profiles.map(function(cp) {
          var lp = local.find(function(x) { return x.name === cp.name; });
          if (lp && lp.ak_secret && !cp.ak_secret) cp.ak_secret = lp.ak_secret;
          return cp;
        });
        saveProfilesLocal(merged);
        if (data.ak_active && merged.find(function(p) { return p.name === data.ak_active; })) {
          localStorage.setItem(activeProfileKey(), data.ak_active);
        } else if (merged.length) {
          localStorage.setItem(activeProfileKey(), merged[0].name);
        }
      } else if (data.ak_id && data.ak_secret) {
        if (!local.find(function(x) { return x.name === '默认'; })) {
          local.push({
            name: '默认', ak_id: data.ak_id, ak_secret: data.ak_secret,
            note: '从云端旧数据迁移', created_at: Date.now(), updated_at: Date.now()
          });
          saveProfilesLocal(local);
          localStorage.setItem(activeProfileKey(), '默认');
        }
      }
      return { ok: true };
    }).catch(function(e) { return { ok: false, error: e.message }; });
  }

  function getActiveProfileSecret() {
    var profiles = listProfilesLocal();
    if (!profiles.length) return null;
    var active = localStorage.getItem(activeProfileKey());
    var p = profiles.find(function(x) { return x.name === active; }) || profiles[0];
    return { ak_id: p.ak_id, ak_secret: p.ak_secret, name: p.name };
  }

  window.AliyunClient = {
    setCredentials: setCredentials,
    hasCredentials: hasCredentials,
    getCredentialsInfo: getCredentialsInfo,
    getAccessKeyId: getAccessKeyIdPublic,
    getAccessKeySecret: getAccessKeySecretPublic,
    listProfiles: listProfiles,
    getActiveProfile: getActiveProfile,
    useProfile: useProfile,
    saveProfile: saveProfile,
    deleteProfile: deleteProfile,
    pullProfilesFromCloud: pullProfilesFromCloud,
    clearCredentials: clearCredentials,

    /** 获取实例列表 */
    async listInstances(regionId, options = {}) {
      const params = {};
      if (options.pageNumber) params.PageNumber = options.pageNumber;
      if (options.pageSize) params.PageSize = options.pageSize || 50;
      if (options.status) params.Status = options.status;
      if (options.instanceName) params.InstanceName = options.instanceName;
      if (options.instanceIds && options.instanceIds.length) {
        // SWAS ListInstances 支持 InstanceIds 过滤（JSON 数组字符串）
        params.InstanceIds = JSON.stringify(options.instanceIds.slice(0, 100));
      }
      return callAliyunApi(regionId, 'ListInstances', params);
    },

    /** 根据实例 ID 列表批量查询（跨地域需调用方自行循环） */
    async listInstancesByIds(regionId, instanceIds) {
      if (!instanceIds || !instanceIds.length) return { Instances: [], TotalCount: 0 };
      const all = [];
      for (let i = 0; i < instanceIds.length; i += 100) {
        const batch = instanceIds.slice(i, i + 100);
        const res = await this.listInstances(regionId, { pageSize: 100, instanceIds: batch });
        all.push(...(res.Instances || []));
      }
      return { Instances: all, TotalCount: all.length };
    },

    /** 获取防火墙模板列表 */
    async listFirewallTemplates(regionId) {
      return callAliyunApi(regionId, 'DescribeFirewallTemplates', {});
    },

    /** 批量应用防火墙模板 */
    async applyFirewallTemplate(regionId, templateId, instanceIds) {
      const params = { FirewallTemplateId: templateId };
      for (let i = 0; i < instanceIds.length; i++) {
        params['InstanceIds.' + (i + 1)] = instanceIds[i];
      }
      return callAliyunApi(regionId, 'ApplyFirewallTemplate', params);
    },

    /** 获取命令列表 */
    async listCommands(regionId) {
      const pageSize = 50;
      const allCommands = [];
      let pageNum = 1;

      while (true) {
        const result = await callAliyunApi(regionId, 'DescribeCommands', {
          Provider: 'User',
          PageSize: pageSize,
          PageNumber: pageNum,
        });
        const commands = result.Commands || [];
        allCommands.push(...commands);
        const total = result.TotalCount || 0;
        if (pageNum * pageSize >= total || commands.length === 0) break;
        pageNum++;
      }

      return { Commands: allCommands, TotalCount: allCommands.length };
    },

    /** 调用命令 */
    async invokeCommand(regionId, commandId, instanceIds) {
      const params = { CommandId: commandId };
      params.InstanceIds = JSON.stringify(instanceIds);
      return callAliyunApi(regionId, 'InvokeCommand', params);
    },

    /** 批量在多台实例上执行自定义命令（SWAS：先 CreateCommand 创建模板拿到 CommandId，再 InvokeCommand 执行；单次最多 100 台，走 callAliyunApi 绕开 aliyun-proxy 的 action 白名单）。instanceIds 可为数组或单个字符串。 */
    async runCommandOnInstance(regionId, instanceIds, opts) {
      var ak = getAccessKeyId(), sk = getAccessKeySecret();
      if (!ak || !sk) throw new Error('请先设置阿里云 AK/SK 凭证');
      var ids = Array.isArray(instanceIds) ? instanceIds : [instanceIds];
      if (ids.length === 0) throw new Error('实例列表为空');
      if (ids.length > 100) throw new Error('SWAS InvokeCommand 单次最多 100 台，请分批调用');
      function doLog(msg, level) {
        if (typeof log === 'function') log(msg, level);
        else console.log('[runCommand] ' + msg);
      }

      // SWAS InvokeCommand 必须传 CommandId，不能直接用 CommandContent。先创建命令模板。
      var createParams = {
        name: opts.name || ('custom-' + Date.now()),
        type: opts.type || 'RunShellScript',
        content: opts.content,
        workingDir: opts.workingDir || '/root',
        timeout: opts.timeout || 60,
      };
      if (opts.description) createParams.description = opts.description;
      var cmdRes = await this.createCommand(regionId, createParams);
      var commandId = cmdRes && cmdRes.CommandId;
      if (!commandId) throw new Error('CreateCommand 未返回 CommandId');
      doLog('📝 创建临时命令模板 CommandId=' + commandId, 'info');

      try {
        var invokeRes = await this.invokeCommand(regionId, commandId, ids);
        // 稍等再删，确保 InvokeCommand 已落盘
        await new Promise(function(r) { setTimeout(r, 1000); });
        await this.deleteCommandWithRetry(regionId, commandId);
        return invokeRes;
      } catch (invokeErr) {
        // 即使 invoke 失败也尝试清理模板（带重试兜底）
        await new Promise(function(r) { setTimeout(r, 200); });
        await this.deleteCommandWithRetry(regionId, commandId);
        throw invokeErr;
      }
    },

    /** 重启单台实例（走 Edge Function 代理） */
    async rebootInstance(regionId, instanceId) {
      var ak = getAccessKeyId(), sk = getAccessKeySecret();
      if (!ak || !sk) throw new Error('请先设置阿里云 AK/SK 凭证');
      var resp = await fetch(window.WB_SUPABASE_FUNCTIONS + '/aliyun-proxy', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'rebootInstance',
          ak_id: ak,
          ak_secret: sk,
          params: { RegionId: regionId, InstanceId: instanceId }
        })
      });
      var j = await resp.json();
      if (!j.success) throw new Error(j.error || ('HTTP ' + resp.status));
      return j.data;
    },

    /** 重置实例系统（重装系统为指定镜像；Edge Function 内部会自动先停机） */
    async resetSystem(regionId, instanceId, imageId) {
      var ak = getAccessKeyId(), sk = getAccessKeySecret();
      if (!ak || !sk) throw new Error('请先设置阿里云 AK/SK 凭证');
      var resp = await fetch(window.WB_SUPABASE_FUNCTIONS + '/aliyun-proxy', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'replaceSystemDisk',
          ak_id: ak,
          ak_secret: sk,
          params: { RegionId: regionId, InstanceId: instanceId, ImageId: imageId }
        })
      });
      var j = await resp.json();
      if (!j.success) throw new Error(j.error || ('HTTP ' + resp.status));
      return j.data;
    },

    /** 创建防火墙模板 */
    async createFirewallTemplate(regionId, name, description, rules) {
      const params = { Name: name };
      if (description) params.Description = description;
      if (rules && rules.length > 0) {
        for (let i = 0; i < rules.length; i++) {
          const r = rules[i];
          params['FirewallRule.' + (i + 1) + '.RuleProtocol'] = r.RuleProtocol;
          params['FirewallRule.' + (i + 1) + '.Port'] = r.Port;
          if (r.SourceCidrIp) params['FirewallRule.' + (i + 1) + '.SourceCidrIp'] = r.SourceCidrIp;
          if (r.Remark) params['FirewallRule.' + (i + 1) + '.Remark'] = r.Remark;
        }
      }
      return callAliyunApi(regionId, 'CreateFirewallTemplate', params);
    },

    /** 批量删除防火墙模板 */
    async deleteFirewallTemplates(regionId, templateIds) {
      var params = {};
      for (var i = 0; i < templateIds.length; i++) {
        params['FirewallTemplateId.' + (i + 1)] = templateIds[i];
      }
      return callAliyunApi(regionId, 'DeleteFirewallTemplates', params);
    },

    /** 创建命令模板 */
    async createCommand(regionId, params) {
      var apiParams = {
        Name: params.name,
        Type: params.type || 'RunShellScript',
        CommandContent: params.content,
        WorkingDir: params.workingDir || '/root',
        Timeout: params.timeout || 60,
      };
      if (params.description) apiParams.Description = params.description;
      return callAliyunApi(regionId, 'CreateCommand', apiParams);
    },

    /** 删除命令模板 */
    async deleteCommand(regionId, commandId) {
      return callAliyunApi(regionId, 'DeleteCommand', { CommandId: commandId });
    },

    /** 删除临时命令模板（带重试兜底）：自定义命令执行完必须清掉，避免残留到命令助手。
     *  最多重试 3 次，每次退避 800ms；全部失败才放弃（仅打 warning，不影响主流程）。 */
    async deleteCommandWithRetry(regionId, commandId, maxRetry) {
      var retries = (typeof maxRetry === 'number' && maxRetry > 0) ? maxRetry : 3;
      var lastErr = null;
      for (var attempt = 1; attempt <= retries; attempt++) {
        try {
          await this.deleteCommand(regionId, commandId);
          doLog('🗑️ 已删除临时命令模板 ' + commandId + '（第 ' + attempt + ' 次成功）', 'info');
          return true;
        } catch (delErr) {
          lastErr = delErr;
          doLog('⚠️ 删除临时命令模板 ' + commandId + ' 失败（第 ' + attempt + '/' + retries + ' 次）: ' + (delErr.message || delErr), 'warn');
          if (attempt < retries) {
            await new Promise(function(r) { setTimeout(r, 800 * attempt); });
          }
        }
      }
      doLog('❌ 删除临时命令模板 ' + commandId + ' 经过 ' + retries + ' 次重试仍失败，模板可能残留于命令助手，请手动清理', 'error');
      return false;
    },

    /** 停止实例 */
    async stopInstance(regionId, instanceId) {
      return callAliyunApi(regionId, 'StopInstance', {
        InstanceId: instanceId,
        ClientToken: generateClientToken(),
      });
    },

    /** 删除实例（退订） */
    async deleteInstance(regionId, instanceId) {
      return callAliyunApi(regionId, 'DeleteInstance', {
        InstanceId: instanceId,
        ClientToken: generateClientToken(),
      });
    },

    /** 获取地域列表 */
    async listRegions() {
      return callAliyunApi('cn-hangzhou', 'ListRegions', {});
    },

    /** 查询套餐列表（按地域）——走 Edge Function 代理，避开 CORS */
    async listPlans(regionId) {
      var ak = getAccessKeyId(), sk = getAccessKeySecret();
      if (!ak || !sk) throw new Error('请先设置阿里云 AK/SK 凭证');
      var resp = await fetch(window.WB_SUPABASE_FUNCTIONS + '/aliyun-proxy', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'listPlans', ak_id: ak, ak_secret: sk, regionId: regionId })
      });
      var j = await resp.json();
      if (!j.success) throw new Error(j.error || 'listPlans 失败');
      return j.data;
    },

    /** 查询镜像列表（按地域）——走 Edge Function 代理，避开 CORS */
    async listImages(regionId) {
      var ak = getAccessKeyId(), sk = getAccessKeySecret();
      if (!ak || !sk) throw new Error('请先设置阿里云 AK/SK 凭证');
      var resp = await fetch(window.WB_SUPABASE_FUNCTIONS + '/aliyun-proxy', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'listImages', ak_id: ak, ak_secret: sk, regionId: regionId })
      });
      var j = await resp.json();
      if (!j.success) throw new Error(j.error || 'listImages 失败');
      return j.data;
    },

    /**
     * 调用中心化交易类 API（CreateOrder 等）
     * —— CORS 黑洞，所有走代理
     */
    async callCentralApi(action, params) {
      var ak = getAccessKeyId(), sk = getAccessKeySecret();
      if (!ak || !sk) throw new Error('请先设置阿里云 AK/SK 凭证');
      var resp = await fetch(window.WB_SUPABASE_FUNCTIONS + '/aliyun-proxy', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: action, ak_id: ak, ak_secret: sk, params: params })
      });
      var j = await resp.json();
      if (!j.success) {
        var e = new Error(j.error || (action + ' 失败'));
        e.response = j;
        throw e;
      }
      return j.data;
    },

    /** 创建订单（生成待支付订单） */
    async createOrder(orderParams) {
      // Commodity 是嵌套对象，传入 callCentralApi 时会自动 JSON 序列化
      const commodity = {
        PlanId: orderParams.PlanId,
        ImageId: orderParams.ImageId || orderParams.ImageName,
        Amount: orderParams.Quantity || 1,
        Period: orderParams.Period || 1,
        PeriodUnit: 'Month',
        PayType: 'Prepaid',
        CommodityType: 'Server',
        AutoPay: false,
        AutoRenew: false,
        DataDiskSize: 0,
      };

      return this.callCentralApi('createOrder', {
        RegionId: orderParams.RegionId,
        OrderType: 'Buy',
        Commodity: commodity,
      });
    },

    /**
     * 真正退订（走 BSS OpenAPI RefundInstance，能退款到原账户，不只是删除）
     * ⚠️ 直连 business.aliyuncs.com（CORS 允许），不经过 Edge Function
     * ProductCode 使用 ace_eweb（轻量应用服务器在 BSS 中的产品码）
     */
    async refundInstance(regionId, instanceId, opts) {
      opts = opts || {};
      // opts.clientToken 可传入以复用（限流退避重试时保持幂等，避免重复退款）
      return callBssApi('RefundInstance', {
        InstanceId: instanceId,
        ProductCode: 'ace_eweb',
        ProductType: '',
        ImmediatelyRelease: opts.immediatelyRelease !== false ? '1' : '0',
        ClientToken: opts.clientToken || generateClientToken(),
      });
    },

    /**
     * 探测 BSS 可退订实例（用 ace_eweb ProductCode 直接询价）
     * 返回 { refundable, amount, error }
     */
    async probeRefundable(instanceId) {
      return callBssApi('InquiryPriceRefundInstance', {
        InstanceId: instanceId,
        ProductCode: 'ace_eweb',
        ProductType: '',
        ClientToken: generateClientToken(),
      });
    },

    /**
     * 创建配额提升申请（Quota Center）
     * 轻量应用服务器实例数量上限配额 ID: q_z3sbl5
     */
    async createQuotaApplication(regionId, desireValue, reason) {
      return this.callCentralApi('CreateQuotaApplication', {
        ProductCode: 'swas',
        QuotaActionCode: 'q_z3sbl5',
        DesireValue: desireValue,
        Reason: reason || '业务扩展，需批量创建轻量应用服务器实例',
        QuotaCategory: 'CommonQuota',
        NoticeType: 0,
        Dimensions: [{ Key: 'regionId', Value: regionId }],
      });
    },

    /**
     * 查询配额提升申请列表（Quota Center）
     */
    async listQuotaApplications(productCode, quotaActionCode) {
      return this.callCentralApi('ListQuotaApplications', {
        ProductCode: productCode || 'swas',
        QuotaActionCode: quotaActionCode || 'q_z3sbl5',
      });
    },
  };

  // ====== 浏览器端直连 BSS API（business.aliyuncs.com 允许 CORS） ======
  async function callBssApi(action, params) {
    var ak = getAccessKeyId(), sk = getAccessKeySecret();
    if (!ak || !sk) throw new Error('请先设置阿里云 AK/SK 凭证');

    var commonParams = {
      AccessKeyId: ak,
      Action: action,
      Format: 'JSON',
      SignatureMethod: 'HMAC-SHA1',
      SignatureNonce: uuid4(),
      SignatureVersion: '1.0',
      Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
      Version: '2017-12-14',
    };

    var allParams = {};
    Object.keys(commonParams).forEach(function(k) { allParams[k] = commonParams[k]; });
    Object.keys(params).forEach(function(k) { allParams[k] = params[k]; });

    var sortedKeys = Object.keys(allParams).sort();
    var canonicalParts = [];
    for (var i = 0; i < sortedKeys.length; i++) {
      var key = sortedKeys[i];
      var value = allParams[key];
      if (value === undefined || value === null) continue;
      canonicalParts.push(percentEncode(key) + '=' + percentEncode(String(value)));
    }
    var canonicalQuery = canonicalParts.join('&');
    var stringToSign = 'POST&' + percentEncode('/') + '&' + percentEncode(canonicalQuery);

    var signKey = sk + '&';
    var signatureBytes = await hmacSha1(signKey, stringToSign);
    var signature = base64Encode(signatureBytes);
    var finalQuery = canonicalQuery + '&' + percentEncode('Signature') + '=' + percentEncode(signature);

    console.log('[bss-api]', action, JSON.stringify(params));

    var response = await fetch('https://business.aliyuncs.com/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: finalQuery,
    });

    var data = await response.json();
    if (!data.Success && data.Code !== 'ResourceNotExists') {
      var e = new Error(data.Message || data.Code || (action + ' 失败'));
      e.code = data.Code;
      e.response = data;
      throw e;
    }
    return { success: true, code: data.Code, message: data.Message, data: data };
  }

  function generateClientToken() {
    return 'wb-' + Date.now() + '-' + Math.random().toString(36).substring(2, 9);
  }

  // ====== 权限检测：检查 AK 是否有 AliyunBSSFullAccess ======
  async function checkBssPermission() {
    var ak = getAccessKeyId(), sk = getAccessKeySecret();
    if (!ak || !sk) return { ok: false, error: '无凭证' };

    // 调用 RAM ListPoliciesForUser 检查当前 AK 对应的用户策略
    // 但 RAM 通常不支持浏览器 CORS，改用试探法：调 BSS QueryAccountBalance
    // 如果能成功调通 QueryAccountBalance 说明有基本 BSS 权限
    try {
      var result = await callBssApi('QueryAccountBalance', {});
      if (result.success) {
        return { ok: true, hasBssAccess: true, balance: (result.data && result.data.Data) ? result.data.Data : null };
      }
      return { ok: false, hasBssAccess: false, error: result.code || '未知' };
    } catch (err) {
      return { ok: false, hasBssAccess: false, error: (err && err.code) || (err && err.message) || String(err) };
    }
  }

  // 暴露权限检测到 AliyunClient
  window.AliyunClient.checkBssPermission = checkBssPermission;

  // 暴露通用 SWAS 直连入口（镜像克隆等功能复用，与 ListInstances 同源）
  window.AliyunClient.callSwasApi = callAliyunApi;

  console.log('[aliyun-client] 浏览器端阿里云客户端已就绪');
})();

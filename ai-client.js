/**
 * AI 中转站客户端 v1.2
 * 使用 OpenAI 兼容接口调用 Claude 模型
 * 中转站: api.zhouyitoken.com
 * 支持多账号数据隔离
 */
(function() {
  'use strict';

  var _apiBase = 'https://api.zhouyitoken.com/v1';
  var _apiKey = 'sk-oYx7JC9whjoGXe6woTFu4npX9yxDiMRl04BjFOIZuszOuzF5';
  var DEFAULT_MODEL = 'claude-sonnet-4-5-20250929';
  var FAST_MODEL = 'claude-haiku-4-5-20251001';

  // ====== 用户命名空间 ======
  function getUserPrefix() {
    try {
      var key = 'wb_logged_in_v2';
      var raw = sessionStorage.getItem(key) || localStorage.getItem(key);
      if (raw) {
        var u = JSON.parse(raw).user;
        if (u) return 'wb_' + u + '_';
      }
    } catch(e) {}
    return 'wb_default_';
  }

  function aiKeyStore() { return getUserPrefix() + 'ai_key'; }
  function aiSettingsKey() { return getUserPrefix() + 'ai_settings'; }

  window.AIClient = {
    // ====== 获取/设置 API 端点 ======
    getBase: function() {
      return _apiBase;
    },

    setBase: function(base) {
      if (base) _apiBase = base;
    },

    // ====== 获取/设置 API Key ======
    getKey: function() {
      try {
        var saved = localStorage.getItem(aiKeyStore());
        if (saved) return saved;
      } catch(e) {}
      return _apiKey;
    },

    setKey: function(key) {
      if (key) _apiKey = key;
      try { localStorage.setItem(aiKeyStore(), key); } catch(e) {}
    },

    hasKey: function() {
      return !!_apiKey;
    },

    // ====== 核心调用 ======
    chat: function(messages, options) {
      options = options || {};
      var model = options.fast ? FAST_MODEL : (options.model || DEFAULT_MODEL);
      var maxTokens = options.maxTokens || 2048;
      var temperature = options.temperature !== undefined ? options.temperature : 0.7;

      return fetch(_apiBase + '/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + _apiKey
        },
        body: JSON.stringify({
          model: model,
          messages: messages,
          max_tokens: maxTokens,
          temperature: temperature
        }),
        signal: options.signal || undefined
      }).then(function(res) {
        if (!res.ok) {
          return res.json().then(function(err) {
            throw new Error(err.error ? err.error.message : ('HTTP ' + res.status));
          });
        }
        return res.json();
      }).then(function(data) {
        return {
          content: data.choices[0].message.content,
          model: data.model,
          usage: data.usage,
          finishReason: data.choices[0].finish_reason
        };
      });
    },

    // ====== 流式调用 ======
    chatStream: function(messages, onChunk, options) {
      options = options || {};
      var model = options.fast ? FAST_MODEL : (options.model || DEFAULT_MODEL);
      var maxTokens = options.maxTokens || 2048;

      var self = this;
      return fetch(_apiBase + '/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + _apiKey
        },
        body: JSON.stringify({
          model: model,
          messages: messages,
          max_tokens: maxTokens,
          temperature: options.temperature !== undefined ? options.temperature : 0.7,
          stream: true
        }),
        signal: options.signal || undefined
      }).then(function(res) {
        if (!res.ok) {
          return res.json().then(function(err) {
            throw new Error(err.error ? err.error.message : ('HTTP ' + res.status));
          });
        }
        return self._readStream(res, onChunk);
      });
    },

    _readStream: function(response, onChunk) {
      var reader = response.body.getReader();
      var decoder = new TextDecoder();
      var buffer = '';
      var fullContent = '';

      function process() {
        return reader.read().then(function(result) {
          if (result.done) {
            if (onChunk) onChunk({ done: true, content: fullContent });
            return fullContent;
          }
          buffer += decoder.decode(result.value, { stream: true });
          var lines = buffer.split('\n');
          buffer = lines.pop() || '';

          for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (!line || !line.startsWith('data: ')) continue;
            var data = line.slice(6);
            if (data === '[DONE]') {
              if (onChunk) onChunk({ done: true, content: fullContent });
              return fullContent;
            }
            try {
              var json = JSON.parse(data);
              var delta = json.choices[0].delta;
              if (delta && delta.content) {
                fullContent += delta.content;
                if (onChunk) onChunk({ content: delta.content, full: fullContent, done: false });
              }
            } catch(e) {}
          }
          return process();
        });
      }
      return process();
    },

    // ====== 快捷方法 ======
    ask: function(prompt, options) {
      return this.chat([{ role: 'user', content: prompt }], options);
    },

    // ====== 系统提示词辅助 ======
    askWithSystem: function(systemPrompt, userPrompt, options) {
      return this.chat([
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userPrompt }
      ], options);
    },

    // ====== 健康检查 ======
    checkHealth: function() {
      return fetch(_apiBase + '/models', {
        headers: { 'Authorization': 'Bearer ' + _apiKey }
      }).then(function(res) {
        return res.json();
      }).then(function(data) {
        return { ok: data.success === true, models: (data.data || []).map(function(m) { return m.id; }) };
      }).catch(function() {
        return { ok: false, models: [] };
      });
    }
  };
})();

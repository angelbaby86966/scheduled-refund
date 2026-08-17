/* ============================================================
 * batch-quota.js  v3  —  「批量提额」（阿里云配额中心）
 *
 * 功能：对 6 个默认地域批量申请提升「轻量应用服务器 - 实例数量上限」配额。
 * 默认目标：每个地域 500 台。
 *
 * 依赖：AliyunClient.createQuotaApplication（aliyun-client-v2.js）
 * ============================================================ */

(function() {
  'use strict';

  var BQU_REGIONS = [
    { id: 'cn-hangzhou', name: '杭州' },
    { id: 'cn-beijing',   name: '北京' },
    { id: 'cn-shanghai',  name: '上海' },
    { id: 'cn-shenzhen',  name: '深圳' },
    { id: 'cn-chengdu',   name: '成都' },
    { id: 'cn-guangzhou', name: '广州' }
  ];

  var BQU_LS_KEY = 'bqu_quota_settings';
  var BQU_RUNNING = false;

  function bquLs(defaults) {
    try {
      var raw = localStorage.getItem(BQU_LS_KEY);
      if (raw) return Object.assign({}, defaults, JSON.parse(raw));
    } catch (e) {}
    return defaults;
  }
  function bquLsSave(obj) {
    try { localStorage.setItem(BQU_LS_KEY, JSON.stringify(obj)); } catch (e) {}
  }

  function bquGetSettings() {
    return bquLs({
      productCode: 'swas',
      quotaActionCode: 'q_z3sbl5',
      desireValue: 500,
      reason: '业务扩展，需提升实例数量上限',
      noticeType: 0,
      quotaCategory: 'CommonQuota'
    });
  }

  function bquEl(id) { return document.getElementById(id); }

  function bquAddLog(icon, msg, color) {
    var el = bquEl('bquLogArea');
    if (!el) return;
    var time = new Date().toLocaleTimeString('zh-CN', { hour12: false });
    var div = document.createElement('div');
    div.style.cssText = 'padding:5px 10px;border-bottom:1px solid #2a2a2a;font-size:13px;font-family:monospace;';
    div.innerHTML = '<span style="color:#888;margin-right:8px;">[' + time + ']</span>' +
      '<span style="margin-right:6px;">' + icon + '</span>' +
      '<span style="color:' + (color || '#d4d4d4') + ';">' + msg + '</span>';
    el.appendChild(div);
    el.scrollTop = el.scrollHeight;
  }
  window.bquClearLog = function() {
    var el = bquEl('bquLogArea');
    if (el) el.innerHTML = '';
  };

  function bquSetProgress(html) {
    var el = bquEl('bquProgress');
    if (el) el.innerHTML = html;
  }
  function bquSetStatus(html, type) {
    var el = bquEl('bquStatus');
    if (!el) return;
    var color = type === 'ok' ? '#52c41a' : type === 'error' ? '#ff4d4f' : type === 'warn' ? '#faad14' : '#1890ff';
    el.innerHTML = '<div style="padding:10px 12px;border-radius:4px;background:' + color + '10;border:1px solid ' + color + '40;color:' + color + ';">' + html + '</div>';
  }

  function bquRenderGrid() {
    var container = bquEl('bquRegionGrid');
    if (!container) return;
    var settings = bquGetSettings();
    var items = BQU_REGIONS.map(function(r) {
      return '<div class="bqu-region-item" style="display:flex;align-items:center;gap:12px;padding:10px 12px;border:1px solid #e8e8e8;border-radius:6px;background:#fafafa;">' +
        '<label style="display:flex;align-items:center;gap:6px;min-width:90px;">' +
          '<input type="checkbox" class="bqu-region-check" data-region="' + r.id + '" checked style="width:16px;height:16px;">' +
          '<span style="font-weight:600;">' + r.name + '</span>' +
        '</label>' +
        '<span style="color:#999;font-size:12px;">(' + r.id + ')</span>' +
        '<div style="flex:1;text-align:right;">' +
          '<label style="font-size:12px;color:#666;margin-right:6px;">目标配额</label>' +
          '<input type="number" class="bqu-region-value input input-sm" data-region="' + r.id + '" value="' + settings.desireValue + '" min="1" style="width:90px;padding:5px 8px;border:1px solid #ccc;border-radius:4px;"> 台' +
        '</div>' +
      '</div>';
    }).join('');
    container.innerHTML = items;
  }

  function bquLoadSettingsToInputs() {
    var s = bquGetSettings();
    var fields = {
      'bquProductCode': s.productCode,
      'bquQuotaActionCode': s.quotaActionCode,
      'bquDesireValue': s.desireValue,
      'bquReason': s.reason,
      'bquNoticeType': s.noticeType,
      'bquQuotaCategory': s.quotaCategory
    };
    Object.keys(fields).forEach(function(id) {
      var el = bquEl(id);
      if (el) el.value = fields[id];
    });
  }

  function bquReadSettingsFromInputs() {
    return {
      productCode: (bquEl('bquProductCode') && bquEl('bquProductCode').value || 'swas').trim(),
      quotaActionCode: (bquEl('bquQuotaActionCode') && bquEl('bquQuotaActionCode').value || 'q_z3sbl5').trim(),
      desireValue: parseInt(bquEl('bquDesireValue') && bquEl('bquDesireValue').value || '500', 10) || 500,
      reason: (bquEl('bquReason') && bquEl('bquReason').value || '业务扩展，需提升实例数量上限').trim(),
      noticeType: parseInt(bquEl('bquNoticeType') && bquEl('bquNoticeType').value || '0', 10) || 0,
      quotaCategory: (bquEl('bquQuotaCategory') && bquEl('bquQuotaCategory').value || 'CommonQuota').trim()
    };
  }

  window.bquSaveSettings = function() {
    var s = bquReadSettingsFromInputs();
    bquLsSave(s);
    // 同步更新 grid 里的默认值
    var inputs = document.querySelectorAll('.bqu-region-value');
    inputs.forEach(function(inp) { if (!inp.value) inp.value = s.desireValue; });
    bquSetStatus('💾 高级配置已记忆', 'ok');
  };

  window.bquResetSettings = function() {
    var defaults = { productCode: 'swas', quotaActionCode: 'q_z3sbl5', desireValue: 500, reason: '业务扩展，需提升实例数量上限', noticeType: 0, quotaCategory: 'CommonQuota' };
    bquLsSave(defaults);
    bquLoadSettingsToInputs();
    var inputs = document.querySelectorAll('.bqu-region-value');
    inputs.forEach(function(inp) { inp.value = defaults.desireValue; });
    bquSetStatus('↩️ 已还原默认配置', 'warn');
  };

  window.bquSelectAll = function(checked) {
    var checks = document.querySelectorAll('.bqu-region-check');
    checks.forEach(function(cb) { cb.checked = checked; });
  };

  window.bquSetAllValues = function() {
    var val = parseInt(bquEl('bquDesireValue').value || '500', 10) || 500;
    var inputs = document.querySelectorAll('.bqu-region-value');
    inputs.forEach(function(inp) { inp.value = val; });
  };

  function bquSleep(ms) {
    return new Promise(function(resolve) { setTimeout(resolve, ms); });
  }

  function bquRegionName(rid) {
    var r = BQU_REGIONS.find(function(x) { return x.id === rid; });
    return r ? r.name : rid;
  }

  window.bquStartQuota = async function() {
    if (BQU_RUNNING) {
      bquSetStatus('⚠️ 正在运行中，请勿重复点击', 'warn');
      return;
    }

    if (!window.AliyunClient || !AliyunClient.createQuotaApplication) {
      bquSetStatus('❌ 阿里云客户端未加载或版本过旧，请刷新页面', 'error');
      return;
    }
    if (!AliyunClient.hasCredentials || !AliyunClient.hasCredentials()) {
      bquSetStatus('❌ 请先设置阿里云 AK/SK 凭证（在「节点ID提取」页或「批量下单」页保存）', 'error');
      return;
    }

    // 读取配置
    var settings = bquReadSettingsFromInputs();
    bquLsSave(settings);

    var checks = Array.from(document.querySelectorAll('.bqu-region-check:checked'));
    if (checks.length === 0) {
      bquSetStatus('⚠️ 请至少选择一个地域', 'warn');
      return;
    }

    var regions = checks.map(function(cb) {
      var rid = cb.dataset.region;
      var inp = document.querySelector('.bqu-region-value[data-region="' + rid + '"]');
      return { id: rid, value: parseInt(inp && inp.value || '500', 10) || 500 };
    });

    BQU_RUNNING = true;
    var btn = bquEl('bquBtn');
    if (btn) { btn.disabled = true; btn.textContent = '⏳ 申请中...'; }
    bquClearLog();
    bquSetStatus('🚀 开始为 ' + regions.length + ' 个地域申请配额，目标 ' + settings.desireValue + ' 台', 'info');

    var ok = 0, fail = 0;
    for (var i = 0; i < regions.length; i++) {
      var r = regions[i];
      bquSetProgress('(' + (i + 1) + '/' + regions.length + ') ' + bquRegionName(r.id) + ' → ' + r.value + ' 台');
      bquAddLog('⏳', '开始 ' + bquRegionName(r.id) + ' (' + r.id + ') 目标 ' + r.value + ' 台...', '#1890ff');
      try {
        var data = await AliyunClient.createQuotaApplication(r.id, r.value, {
          productCode: settings.productCode,
          quotaActionCode: settings.quotaActionCode,
          reason: settings.reason,
          noticeType: settings.noticeType,
          quotaCategory: settings.quotaCategory
        });
        var appId = data && (data.ApplicationId || data.applicationId || data.ApplyId || data.applyId) || '未知';
        bquAddLog('✅', bquRegionName(r.id) + ' 申请成功，申请单号: ' + appId, '#52c41a');
        ok++;
      } catch (e) {
        var msg = e && (e.message || '未知错误');
        bquAddLog('❌', bquRegionName(r.id) + ' 申请失败: ' + msg, '#ff4d4f');
        fail++;
      }
      // 配额中心流控约 4/s，保守间隔 350ms
      if (i < regions.length - 1) await bquSleep(350);
    }

    BQU_RUNNING = false;
    if (btn) { btn.disabled = false; btn.textContent = '📈 开始批量提额'; }
    bquSetProgress('');
    if (fail === 0) {
      bquSetStatus('✅ 全部 ' + ok + ' 个地域申请已提交，请在阿里云控制台「配额中心→申请历史」查看审批结果', 'ok');
    } else {
      bquSetStatus('⚠️ 完成：成功 ' + ok + ' 个，失败 ' + fail + ' 个。请查看下方日志。', 'warn');
    }
  };

  // 标签页激活时初始化
  document.addEventListener('DOMContentLoaded', function() {
    bquRenderGrid();
    bquLoadSettingsToInputs();
  });
})();

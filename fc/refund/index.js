/**
 * ⚠️ 已废弃 / DEPRECATED（2026-11-09）—— 请勿部署本文件！
 *
 * 本文件是上午误判 FC runtime 时生成的 Node 版历史产物。直连 FC API 实测确认：
 * 线上函数 runtime=python3.10、handler=fc_main.handler、代码是 46KB 的 fc_main.py。
 * 把本文件推上去会让函数直接跑不起来。
 *
 * 现行源码：fc/refund/fc_main.py
 * 部署脚本：ops/deploy_fc_refund.py（.github/workflows/deploy-fc-refund.yml）
 * 详见：FC定时退订配置.md
 *
 * ---------------------------------------------------------------------------
 * 阿里云函数计算（FC）· 定时退订 refund 函数（历史存档）
 *
 * 2026-11-09 根治版：
 *   ① 与 Actions / Edge Function 共用同一份 Supabase 保护名单
 *      `user_data.data.schedule_exclude_instance_ids`（全局合并所有用户）。
 *   ② 三层拦截：列举时剔除 → 退订前过滤 → refundOne() 最底层硬拦截。
 *   ③ fail-closed：保护名单读取失败（网络/Supabase 异常/脏数据）时
 *      本次**一台都不退**，绝不「当名单为空继续退」。
 *   ④ 零第三方依赖：只用 Node 20 内置 crypto + 全局 fetch，
 *      避免 FC 代码包缺 node_modules 导致函数启动失败。
 *
 * 与 scheduled_refund.py 语义一致：北京时间 23:35–23:59 窗口、按凭证 + 按地区勾选、
 * 黄金机 / 豁免实例硬保护、稳定 ClientToken 幂等退订。
 */

'use strict';

const { createHmac, randomUUID, createHash } = require('crypto');

// ====== 配置 ======
const SUPABASE_URL = (process.env.SUPABASE_URL || 'https://opauwtkivhjxlijfqaix.supabase.co').replace(/\/$/, '');
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'sb_publishable_SM9yvpcOBqvVPH2oGwTmFg_BZ1Lz9Xd';
const REST_BASE = SUPABASE_URL + '/rest/v1';

const BSS_ENDPOINT = 'https://business.aliyuncs.com/';
const BSS_VERSION = '2017-12-14';
const SWAS_VERSION = '2020-06-01';

const REGION_INFO = {
  'cn-hangzhou': '杭州', 'cn-beijing': '北京', 'cn-shanghai': '上海', 'cn-shenzhen': '深圳',
  'cn-chengdu': '成都', 'cn-guangzhou': '广州', 'cn-heyuan': '河源', 'cn-wuhan-lr': '武汉',
  'cn-wulanchabu': '乌兰察布',
};
const DISABLED_REGIONS_DEFAULT = ['cn-heyuan', 'cn-wuhan-lr', 'cn-wulanchabu'];

function computeActiveRegions() {
  const white = (process.env.REGIONS || '').split(',').map(s => s.trim()).filter(Boolean);
  if (white.length) return white.filter(r => REGION_INFO[r]);
  const black = process.env.DISABLED_REGIONS !== undefined
    ? process.env.DISABLED_REGIONS.split(',').map(s => s.trim()).filter(Boolean)
    : DISABLED_REGIONS_DEFAULT;
  return Object.keys(REGION_INFO).filter(r => !black.includes(r));
}
const ACTIVE_REGIONS = computeActiveRegions();

// ====== 黄金机 / 退订豁免 硬保护（与 scheduled_refund.py 同源常量）======
const GOLDEN_INSTANCE_IDS = new Set([
  '1341164c82ed49a6ae0ab8c89b7eed37',
  'f05cf2489e41413382dfc944773386b8',
]);
const GOLDEN_PUBLIC_IPS = new Set(['47.116.51.223', '47.101.145.6']);
const REFUND_EXEMPT_INSTANCE_IDS = new Set([
  '09ec95ba247642418bfc73da1b6ce8e4',
  '36a5f79c209c49c4933a799df5aa27d0',
]);
const REFUND_EXEMPT_PUBLIC_IPS = new Set(['106.15.92.45', '47.111.123.188']);

// ====== 排除名单（唯一事实来源）======
let EXCLUDE_IDS = null;   // null = 未加载 / 加载失败 → fail-closed

function normalizeExclude(raw) {
  const out = new Set();
  if (Array.isArray(raw)) {
    for (const x of raw) if (typeof x === 'string' && x.trim()) out.add(x.trim());
  } else if (typeof raw === 'string') {
    for (const x of raw.split(/[\s,;，；]+/)) if (x.trim()) out.add(x.trim());
  } else if (raw && typeof raw === 'object') {
    for (const k of Object.keys(raw)) if (raw[k] && k.trim()) out.add(k.trim());
  }
  return out;
}

function loadExcludeIds(rows) {
  const merged = new Set();
  for (const row of rows) {
    const raw = row && row.data && row.data.schedule_exclude_instance_ids;
    if (raw === undefined || raw === null) continue;
    if (!Array.isArray(raw) && typeof raw !== 'string' && typeof raw !== 'object') {
      throw new Error('排除名单字段类型异常，拒绝执行任何退订（fail-closed）');
    }
    for (const id of normalizeExclude(raw)) merged.add(id);
  }
  EXCLUDE_IDS = merged;
  return merged;
}

function isExcluded(iid) {
  // 名单未加载成功 → 视为受保护，任何退订都拒绝
  return EXCLUDE_IDS === null || EXCLUDE_IDS.has(iid);
}

// ====== 日志 / 时间 ======
function log(msg, level) {
  const tag = level ? '[' + level + ']' : '[info]';
  console.log(new Date().toISOString(), tag, msg);
}
function beijingParts() {
  const fmt = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Shanghai', hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
  const m = {};
  fmt.formatToParts(new Date()).forEach(p => { m[p.type] = p.value; });
  return { h: parseInt(m.hour, 10), mi: parseInt(m.minute, 10) };
}
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ====== 阿里云 RPC（HMAC-SHA1，与 scheduled_refund.py / 前端一致）======
function pct(s) {
  return encodeURIComponent(String(s)).replace(/[!'()*]/g,
    c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
}
function isoNow() { return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'); }

async function rpc(ak, sk, endpoint, action, version, params) {
  const common = {
    AccessKeyId: ak,
    Format: 'JSON',
    SignatureMethod: 'HMAC-SHA1',
    SignatureNonce: randomUUID(),
    SignatureVersion: '1.0',
    Timestamp: isoNow(),
    Version: version,
    Action: action,
  };
  const all = Object.assign({}, common, params);
  const canonical = Object.keys(all)
    .filter(k => all[k] !== undefined && all[k] !== null)
    .sort()
    .map(k => pct(k) + '=' + pct(all[k]))
    .join('&');
  const stringToSign = 'POST&' + pct('/') + '&' + pct(canonical);
  const signature = createHmac('sha1', sk + '&').update(stringToSign).digest('base64');
  const body = canonical + '&Signature=' + pct(signature);

  const resp = await fetch(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  const raw = await resp.text();
  let data;
  try { data = JSON.parse(raw); } catch (_) { data = { Code: 'ParseError', Message: raw.slice(0, 300) }; }
  if (!resp.ok || (data.Code && !['200', 'Success'].includes(String(data.Code)))) {
    const e = new Error(data.Message || data.Code || ('HTTP ' + resp.status));
    e.code = data.Code;
    throw e;
  }
  return data;
}

function swasEndpoint(regionId) { return 'https://swas.' + regionId + '.aliyuncs.com/'; }
function publicIpOf(it) {
  const v = it && (it.PublicIpAddress || it.PublicIpAddresses);
  return Array.isArray(v) ? (v.find(Boolean) || '') : (v || '');
}
function isGolden(it) {
  return (it.InstanceId && GOLDEN_INSTANCE_IDS.has(it.InstanceId)) ||
         (publicIpOf(it) && GOLDEN_PUBLIC_IPS.has(publicIpOf(it)));
}
function isRefundExempt(it) {
  return (it.InstanceId && REFUND_EXEMPT_INSTANCE_IDS.has(it.InstanceId)) ||
         (publicIpOf(it) && REFUND_EXEMPT_PUBLIC_IPS.has(publicIpOf(it)));
}

// ====== 列举实例 ======
async function listInstances(ak, sk, regionId) {
  const out = [];
  for (let page = 1; page <= 20; page++) {
    const data = await rpc(ak, sk, swasEndpoint(regionId), 'ListInstances', SWAS_VERSION,
      { PageNumber: page, PageSize: 100 });
    const insts = Array.isArray(data.Instances) ? data.Instances : [];
    out.push(...insts);
    const total = Number(data.TotalCount || 0);
    if (!insts.length || out.length >= total) break;
  }
  return out;
}

// ====== 退订单实例（最底层硬拦截）======
const THROTTLE_HINTS = ['Throttling', 'ServiceUnavailable', 'InternalError', 'SystemBusy', 'RequestTimeout'];
const LOCKED_HINTS = ['NoApplicable', 'NotApplicable', 'ExceedRefundQuota', 'NoFullRefund',
  'CannotDeleteInstance', 'RefundFailed', '非全额退款', '尚未结算', '请先退订订单'];

async function refundOne(ak, sk, regionId, iid) {
  // 🛡 最后一道闸门：排除名单未加载 / 命中排除 → 绝不发 RefundInstance
  if (isExcluded(iid)) {
    log('🛡 ' + iid + ' 命中排除名单（或名单未加载，fail-closed），跳过退订', 'WARN');
    return 'protected';
  }
  if (GOLDEN_INSTANCE_IDS.has(iid) || REFUND_EXEMPT_INSTANCE_IDS.has(iid)) {
    log('🛡 ' + iid + ' 是黄金机/豁免实例，跳过退订', 'WARN');
    return 'protected';
  }
  const token = 'wb-' + createHash('sha1').update(regionId + ':' + iid).digest('hex').slice(0, 16);
  for (let attempt = 1; attempt <= 6; attempt++) {
    try {
      const data = await rpc(ak, sk, BSS_ENDPOINT, 'RefundInstance', BSS_VERSION, {
        InstanceId: iid,
        ProductCode: 'ace_eweb',
        ProductType: '',
        ImmediatelyRelease: '1',
        ClientToken: token,
      });
      if (data.Success || data.Code === 'ResourceNotExists') {
        log('✅ [' + (REGION_INFO[regionId] || regionId) + '] ' + iid + ' 退订成功/已不存在');
        return 'ok';
      }
      const msg = String(data.Message || data.Code || 'unknown');
      if (LOCKED_HINTS.some(p => msg.includes(p))) {
        log('🔒 ' + iid + ' 不可退订，跳过：' + msg, 'WARN');
        return 'locked';
      }
      throw new Error(msg);
    } catch (e) {
      const msg = String(e && e.message || e);
      if (THROTTLE_HINTS.some(p => msg.includes(p)) && attempt < 6) {
        await sleep(Math.min(5000, 400 * Math.pow(2, attempt)));
        continue;
      }
      if (msg.includes('ResourceNotExists') || msg.includes('不存在') || msg.includes('NotFound')) {
        return 'skipped';
      }
      log('❌ ' + iid + ' 退订失败：' + msg, 'ERROR');
      return 'fail';
    }
  }
  return 'fail';
}

// ====== Supabase ======
async function supabaseGetAllUserData() {
  const resp = await fetch(REST_BASE + '/user_data?select=username,data', {
    headers: { 'apikey': SUPABASE_ANON_KEY, 'Authorization': 'Bearer ' + SUPABASE_ANON_KEY },
  });
  if (!resp.ok) throw new Error('Supabase 读取失败: HTTP ' + resp.status);
  const rows = await resp.json();
  if (!Array.isArray(rows)) throw new Error('Supabase 返回格式异常');
  return rows;
}

// ====== 配置解析（对齐 scheduled_refund.py）======
function asIdSet(raw) {
  return new Set(Array.isArray(raw) ? raw.filter(x => typeof x === 'string' && x.trim()).map(x => x.trim()) : []);
}
function buildRegions(data) {
  const wanted = asIdSet(data.schedule_region_ids);
  if (!wanted.size) return ACTIVE_REGIONS.slice();
  const sel = ACTIVE_REGIONS.filter(r => wanted.has(r));
  if (!sel.length) { log('⛔ 勾选地区与启用地区无交集，本次不执行任何退订', 'ERROR'); return []; }
  return sel;
}
function buildCredRegions(data, label) {
  const map = data.schedule_cred_regions;
  if (map && typeof map === 'object' && Object.prototype.hasOwnProperty.call(map, label)) {
    const wanted = asIdSet(map[label]);
    if (!wanted.size) return [];
    return ACTIVE_REGIONS.filter(r => wanted.has(r));
  }
  if (asIdSet(data.schedule_ak_ids).size) {
    log('⏭️ 凭证「' + label + '」未配置地区，跳过（避免误退全部地区）', 'WARN');
    return [];
  }
  return buildRegions(data);
}
function buildCredentials(data) {
  const profiles = Array.isArray(data.ak_profiles) ? data.ak_profiles : [];
  const wanted = asIdSet(data.schedule_ak_ids);
  const pick = wanted.size
    ? profiles.filter(p => {
        const id = String(p.id == null ? '' : p.id).trim();
        const nm = String(p.name == null ? '' : p.name).trim();
        return (id && wanted.has(id)) || (nm && wanted.has(nm));
      })
    : profiles;
  const creds = [], seen = new Set();
  for (const p of pick) {
    const ak = String(p.ak_id || '').trim(), sk = String(p.ak_secret || '').trim();
    if (!ak || !sk || seen.has(ak)) continue;
    seen.add(ak);
    creds.push({ label: String(p.name || '?'), ak, sk });
  }
  if (!creds.length && !wanted.size) {
    const ak = String(data.ak_id || '').trim(), sk = String(data.ak_secret || '').trim();
    if (ak && sk) creds.push({ label: 'legacy', ak, sk });
  }
  return creds;
}

// ====== 主流程 ======
async function processUser(row) {
  const username = row.username, data = row.data || {};
  if (!data.schedule_enabled) return;
  const hour = parseInt(data.schedule_hour, 10), minute = parseInt(data.schedule_minute, 10);
  if (Number.isNaN(hour) || Number.isNaN(minute)) return;
  if (!(hour === 23 && minute >= 35 && minute <= 59)) return;

  const bj = beijingParts();
  if (!(bj.h === 23 && bj.mi >= 35) || bj.mi < minute) return;

  const creds = buildCredentials(data);
  if (!creds.length) { log('用户 ' + username + ' 无可用凭证，跳过', 'WARN'); return; }
  log('▶ 用户 ' + username + ' 北京时间 ' + bj.h + ':' + bj.mi + ' 触发定时退订，共 ' + creds.length + ' 个凭证', 'WARN');

  for (const c of creds) {
    const regions = buildCredRegions(data, c.label);
    if (!regions.length) { log('⏭️ 凭证「' + c.label + '」无可执行地区，跳过', 'WARN'); continue; }
    for (const rid of regions) {
      let list;
      try { list = await listInstances(c.ak, c.sk, rid); }
      catch (e) { log('[' + (REGION_INFO[rid] || rid) + '] 列举失败：' + (e.message || e), 'ERROR'); continue; }
      const targets = [];
      for (const it of list) {
        const iid = it && it.InstanceId;
        if (!iid) continue;
        if (isGolden(it)) { log('🛡 跳过黄金机 ' + iid, 'WARN'); continue; }
        if (isRefundExempt(it)) { log('🛡 跳过豁免实例 ' + iid, 'WARN'); continue; }
        if (isExcluded(iid)) { log('🛡 跳过排除实例 ' + iid, 'WARN'); continue; }
        targets.push(iid);
      }
      for (const iid of targets) await refundOne(c.ak, c.sk, rid, iid);
    }
  }
}

async function main() {
  log('启动定时退订（排除实例保护 v2026-11-09）；启用地域：' + ACTIVE_REGIONS.join(','));
  let rows;
  try {
    rows = await supabaseGetAllUserData();
  } catch (e) {
    // fail-closed：读不到配置就绝不退订
    log('⛔ 读取 Supabase 失败，本次拒绝执行任何退订：' + (e.message || e), 'ERROR');
    throw e;
  }
  let ids;
  try {
    ids = loadExcludeIds(rows);
  } catch (e) {
    log('⛔ ' + (e.message || e), 'ERROR');
    throw e;
  }
  log('🛡️ 排除实例保护名单已加载：' + ids.size + ' 个');
  for (const row of rows) {
    try { await processUser(row); }
    catch (e) { log('用户 ' + row.username + ' 处理异常：' + (e.stack || e), 'ERROR'); }
  }
  log('本次定时退订结束');
}

// FC 标准入口；同时保留本地/CI 直接执行能力
exports.handler = async function (event, context) {
  await main();
  return { statusCode: 200, body: 'ok' };
};

if (require.main === module) {
  main().catch(e => { log('脚本异常退出：' + (e.stack || e), 'ERROR'); process.exitCode = 1; });
}

/**
 * 阿里云轻量云服务器定时自动退订脚本（服务端版，与 scheduled_refund.py 语义一致）
 *
 * 部署：阿里云函数计算（FC）refund 函数；GitHub Actions 也跑 scheduled_refund.py，
 *      两者读同一份 Supabase `user_data`、幂等，不冲突。
 *
 * 关键修复（2026-11-01）：
 *   旧版 index.js 写死 9 个地域 + 单一全局 AK/SK，完全无视前端「按凭证 + 按地区」勾选，
 *   每天 23:35 无脑退全部地域 → 用户取消勾选的地域照样被退（54 的北京、56 的杭州被误退）。
 *   新版改为读取 Supabase `user_data`，严格按 schedule_ak_ids + schedule_cred_regions
 *   只退「勾选的凭证 ∩ 勾选的地区」，未勾选地区一律不碰。
 *
 * 退订策略（对齐 scheduled_refund.py / 前端 app.js 有界并发模式）：
 *   1) 全局令牌桶：平滑到 REFUND_QPS 次/秒，避免突发尖峰触发限流
 *   2) 并发上限：worker 池最多 REFUND_CONCURRENCY 个在途请求
 *   3) 幂等：每个实例固定一个 clientToken，限流重试时复用，避免重复退款
 *   4) 单实例退避：Throttling/ServiceUnavailable 等瞬时错误指数退避重试，不阻塞其他 worker
 */

// ====== 配置 ======
const SUPABASE_URL = process.env.SUPABASE_URL || 'https://opauwtkivhjxlijfqaix.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'sb_publishable_SM9yvpcOBqvVPH2oGwTmFg_BZ1Lz9Xd';
const REST_BASE = SUPABASE_URL.replace(/\/$/, '') + '/rest/v1';

// 旧版单一全局 AK/SK：仅在用户 data 里完全没有 ak_profiles（纯老数据）时作为兜底
const LEGACY_AK = process.env.ALIYUN_AK || '';
const LEGACY_SK = process.env.ALIYUN_SK || '';

const REFUND_CONCURRENCY = 8;     // 同时最多在途请求数（有界并发上限）
const REFUND_QPS = 8;             // 目标平稳速率（令牌桶：容量=QPS，refill=QPS/秒）
const REFUND_MAX_RETRY = 5;       // 单实例限流最大重试次数
const REFUND_BACKOFF_MAX_MS = 5000;
const REFUND_PER_INSTANCE_TIMEOUT = 60000;

// 地域表（与前端 REGION_INFO / scheduled_refund.py 一致）
const REGION_INFO = {
  'cn-hangzhou': '杭州', 'cn-beijing': '北京', 'cn-shanghai': '上海', 'cn-shenzhen': '深圳',
  'cn-chengdu': '成都', 'cn-guangzhou': '广州', 'cn-heyuan': '河源', 'cn-wuhan-lr': '武汉',
  'cn-wulanchabu': '乌兰察布',
};
// 默认禁用地区（与 scheduled_refund.py DISABLED_REGIONS_DEFAULT 一致）
const DISABLED_REGIONS_DEFAULT = ['cn-heyuan', 'cn-wuhan-lr', 'cn-wulanchabu'];

function computeActiveRegions() {
  const envWhite = (process.env.REGIONS || '').split(',').map(s => s.trim()).filter(Boolean);
  if (envWhite.length) return envWhite.filter(r => REGION_INFO[r]);
  const envBlack = process.env.DISABLED_REGIONS;
  const disabled = (envBlack !== undefined && envBlack !== null)
    ? envBlack.split(',').map(s => s.trim()).filter(Boolean)
    : DISABLED_REGIONS_DEFAULT;
  return Object.keys(REGION_INFO).filter(r => !disabled.includes(r));
}
const ACTIVE_REGIONS = computeActiveRegions();

// ====== 黄金机 / 退订豁免 硬保护（与 scheduled_refund.py 同源常量）======
// 现役 2 台黄金机（cn-shanghai），任何情况下都不得退订 / 释放 / 重置
const GOLDEN_INSTANCE_IDS = new Set([
  '1341164c82ed49a6ae0ab8c89b7eed37',  // ← 现役黄金机 ①（cn-shanghai，IP 47.116.51.223）
  'f05cf2489e41413382dfc944773386b8',  // ← 现役黄金机 ②（cn-shanghai，IP 47.101.145.6）
]);
const GOLDEN_PUBLIC_IPS = new Set([
  '47.116.51.223',   // ← 现役黄金机 ① 公网 IP
  '47.101.145.6',    // ← 现役黄金机 ② 公网 IP
]);
const REFUND_EXEMPT_INSTANCE_IDS = new Set([
  '09ec95ba247642418bfc73da1b6ce8e4',  // 上海 · 张瑞瑶30 · 106.15.92.45（保活不误退）
]);
const REFUND_EXEMPT_PUBLIC_IPS = new Set([
  '106.15.92.45',
]);

// ====== 工具 ======
function nowStr() { return new Date().toLocaleString('zh-CN', { hour12: false }); }
function log(msg, level = 'info') {
  const prefix = `[${nowStr()}]`;
  if (level === 'error') console.error(prefix, '❌', msg);
  else if (level === 'warn') console.warn(prefix, '⚠️', msg);
  else if (level === 'success') console.log(prefix, '✅', msg);
  else console.log(prefix, 'ℹ️', msg);
}
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function makeTokenBucket(capacity, refillPerSec) {
  let tokens = capacity;
  let last = Date.now();
  return {
    take: function (n = 1) {
      return new Promise(function (resolve) {
        function tick() {
          const now = Date.now();
          tokens = Math.min(capacity, tokens + (now - last) / 1000 * refillPerSec);
          last = now;
          if (tokens >= n) { tokens -= n; resolve(); }
          else setTimeout(tick, Math.max(10, (n - tokens) / refillPerSec * 1000));
        }
        tick();
      });
    }
  };
}

// ====== 客户端 ======
const RPCClient = require('@alicloud/pop-core');
function makeClients(ak, sk) {
  return {
    swas: new RPCClient({
      endpoint: 'https://swas-open.aliyuncs.com', apiVersion: '2020-06-01',
      accessKeyId: ak, accessKeySecret: sk,
    }),
    bss: new RPCClient({
      endpoint: 'https://business.aliyuncs.com', apiVersion: '2017-12-14',
      accessKeyId: ak, accessKeySecret: sk,
    }),
  };
}

// ====== 错误分类 ======
const THROTTLE_PATTERNS = [
  'Throttling', 'Throttling.User', 'ServiceUnavailable', 'InternalError',
  'RequestLimitExceeded', 'SystemBusy', 'TryAgainLater', 'FrequencyLimit',
  'OverFlow', 'Busy', 'Timeout', 'RequestTimeout',
  'flow control', 'FlowControl', 'Too Many Requests', 'too many requests'
];
const LOCKED_PATTERNS = [
  'NoApplicable', 'NotApplicable', 'ExceedRefundQuota', 'ExistUnPaidOrder',
  'ExistRefundingOrder', 'NoRestValue', 'AmbassadorOrderLimit', 'ActivityForbidden',
  'CommodityNotSupported', 'ProductCheckError', 'MissingRefundAmount', 'InvalidPayMethod',
  'CannotDeleteInstance', 'RefundFailed', 'NoFullRefund', '非全额退款', '非全额退订',
  '订单未到期', '订单到期', '尚未结算', 'InstanceHasUnsettledBill', 'PayMethodNotSupported', '请先退订订单'
];
function isThrottle(msg) { return THROTTLE_PATTERNS.some(p => msg.includes(p)); }
function isLocked(msg) { return LOCKED_PATTERNS.some(p => msg.includes(p)); }

function publicIpOf(it) {
  const v = it && (it.PublicIpAddress || it.PublicIpAddresses);
  if (Array.isArray(v)) return (v.find(Boolean) || '');
  return (v || '');
}
function isGolden(it) {
  const id = it && it.InstanceId;
  if (id && GOLDEN_INSTANCE_IDS.has(id)) return true;
  const ip = publicIpOf(it);
  return !!(ip && GOLDEN_PUBLIC_IPS.has(ip));
}
function isRefundExempt(it) {
  const id = it && it.InstanceId;
  if (id && REFUND_EXEMPT_INSTANCE_IDS.has(id)) return true;
  const ip = publicIpOf(it);
  return !!(ip && REFUND_EXEMPT_PUBLIC_IPS.has(ip));
}

// ====== 退订单实例 ======
async function refundOne(clients, regionId, instanceId, bucket) {
  if (GOLDEN_INSTANCE_IDS.has(instanceId) || REFUND_EXEMPT_INSTANCE_IDS.has(instanceId)) {
    log(`🔒 [${REGION_INFO[regionId] || regionId}] ${instanceId} 是黄金机/豁免实例，绝不退订`, 'warn');
    return { ok: false, id: instanceId, skipped: true };
  }
  await bucket.take(1);
  const clientToken = `scheduled-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
  const regionName = REGION_INFO[regionId] || regionId;
  let attempt = 0;
  while (true) {
    try {
      await clients.bss.request('RefundInstance', {
        InstanceId: instanceId,
        ProductCode: 'ace_eweb',
        ProductType: '',
        ImmediatelyRelease: '1',
        ClientToken: clientToken,
      }, { method: 'POST', timeout: REFUND_PER_INSTANCE_TIMEOUT });
      log(`[${regionName}] ${instanceId} 退订成功`, 'success');
      return { ok: true, id: instanceId };
    } catch (e) {
      const msg = (e && e.message) || String(e);
      if (isLocked(msg)) {
        log(`[${regionName}] ${instanceId} 不可退订: ${msg} (跳过)`, 'warn');
        return { ok: false, id: instanceId, skipped: true, locked: true, err: msg };
      }
      if (msg.includes('ResourceNotExists') || msg.includes('Instance.NotFound') || msg.includes('not exist')) {
        log(`[${regionName}] ${instanceId} 已不存在/已退订，跳过`);
        return { ok: false, id: instanceId, skipped: true, err: msg };
      }
      if (!isThrottle(msg) || attempt >= REFUND_MAX_RETRY) {
        log(`[${regionName}] ${instanceId} 退订失败: ${msg}`, 'error');
        return { ok: false, id: instanceId, err: msg };
      }
      attempt++;
      const backoff = Math.min(REFUND_BACKOFF_MAX_MS, 400 * Math.pow(2, attempt)) + Math.floor(Math.random() * 300);
      if (attempt <= 2) log(`[${regionName}] ${instanceId} 触发限流，第 ${attempt} 次退避重试 (${backoff}ms)`, 'warn');
      await sleep(backoff);
    }
  }
}

async function runBoundedRefund(clients, tasks) {
  const bucket = makeTokenBucket(REFUND_QPS, REFUND_QPS);
  const total = { success: 0, skipped: 0, locked: 0, fail: 0 };
  if (!tasks.length) return total;
  let idx = 0, done = 0;
  async function worker() {
    while (idx < tasks.length) {
      const task = tasks[idx++];
      const r = await refundOne(clients, task.rid, task.iid, bucket);
      const rn2 = REGION_INFO[task.rid] || task.rid;
      if (r.skipped && r.locked) { total.locked++; log(`🔒 [${rn2}] ${r.id}: ${r.err} (跳过)`, 'warn'); }
      else if (r.skipped) { total.skipped++; log(`⚪ [${rn2}] ${r.id}: 已不存在/已退订，跳过`); }
      else if (r.ok) { total.success++; }
      else { total.fail++; log(`❌ [${rn2}] ${r.id}: ${r.err}`, 'error'); }
      done++;
      if (done % 10 === 0 || done === tasks.length) {
        log(`📊 进度 ${done}/${tasks.length} (成功${total.success} 跳过${total.skipped} 锁定${total.locked} 失败${total.fail})`);
      }
    }
  }
  const pool = [];
  const n = Math.min(REFUND_CONCURRENCY, tasks.length);
  for (let w = 0; w < n; w++) pool.push(worker());
  await Promise.all(pool);
  return total;
}

// ====== 列出某凭证【指定地区】实例 ======
async function listInstancesInRegion(clients, regionId) {
  const instances = [];
  let page = 1;
  while (true) {
    try {
      const res = await clients.swas.request('DescribeInstances', {
        RegionId: regionId, PageNumber: page, PageSize: 100,
      }, { method: 'POST' });
      const list = (res && res.Instances) || [];
      instances.push(...list);
      const total = (res && res.TotalCount) || list.length;
      if (instances.length >= total) break;
      page++;
    } catch (e) {
      log(`[${REGION_INFO[regionId] || regionId}] 查询实例列表失败: ${e.message || e}`, 'error');
      break;
    }
  }
  return instances;
}

// ====== Supabase ======
async function supabaseGetAllUserData() {
  const url = REST_BASE + '/user_data?select=username,data';
  const res = await fetch(url, {
    headers: { 'apikey': SUPABASE_ANON_KEY, 'Authorization': 'Bearer ' + SUPABASE_ANON_KEY }
  });
  if (!res.ok) throw new Error('Supabase 读取失败: HTTP ' + res.status);
  return res.json();
}

// ====== 选择逻辑（对齐 scheduled_refund.py）======
function asIdSet(raw) {
  if (!Array.isArray(raw)) return new Set();
  return new Set(raw.filter(x => typeof x === 'string' && x.trim()).map(x => x.trim()));
}
function buildRegions(data) {
  const wanted = asIdSet(data.schedule_region_ids);
  if (!wanted.size) return new Set(ACTIVE_REGIONS);
  const sel = ACTIVE_REGIONS.filter(r => wanted.has(r));
  if (!sel.length) {
    log('  ⛔ 勾选地区与当前启用地区无交集，本次不执行任何退订', 'ERROR');
    return new Set();
  }
  return new Set(sel);
}
function buildCredRegions(data, label) {
  const map = data.schedule_cred_regions;
  if (map && typeof map === 'object' && Object.prototype.hasOwnProperty.call(map, label)) {
    const wanted = asIdSet(map[label]);
    if (!wanted.size) return new Set(); // 显式空数组 → 跳过该凭证
    const sel = ACTIVE_REGIONS.filter(r => wanted.has(r));
    if (!sel.length) {
      log(`  ⛔ 凭证「${label}」勾选地区与启用地区无交集，跳过该凭证`, 'ERROR');
      return new Set();
    }
    return new Set(sel);
  }
  // 显式选择模式（schedule_ak_ids 非空）：缺 schedule_cred_regions → 跳过，绝不回退并集
  if (asIdSet(data.schedule_ak_ids).size) {
    log(`  ⏭️ 凭证「${label}」在显式选择模式下未配置地区，跳过（避免误退全部地区）`, 'WARN');
    return new Set();
  }
  return buildRegions(data); // 老数据全量
}
function buildCredentials(data) {
  const profiles = Array.isArray(data.ak_profiles) ? data.ak_profiles : [];
  const wanted = asIdSet(data.schedule_ak_ids);
  const pick = wanted.size
    ? profiles.filter(p => {
        const id = String(p.id != null ? p.id : '').trim();
        const nm = String(p.name != null ? p.name : '').trim();
        return (id && wanted.has(id)) || (nm && wanted.has(nm));
      })
    : profiles;
  const creds = [];
  const seen = new Set();
  for (const p of pick) {
    const ak = String(p.ak_id || '').trim();
    const sk = String(p.ak_secret || '').trim();
    if (!ak || !sk) continue;
    if (seen.has(ak)) continue;
    seen.add(ak);
    creds.push({ label: p.name || '?', ak, sk });
  }
  if (!creds.length && wanted.size) {
    log('  ⛔ 已勾选凭证但在 ak_profiles 里没找到可用 AK/SK，本次不执行任何退订', 'ERROR');
    return [];
  }
  return creds;
}

// ====== 北京时间 ======
function beijingParts() {
  const fmt = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Shanghai', hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit'
  });
  const m = {};
  fmt.formatToParts(new Date()).forEach(p => { m[p.type] = p.value; });
  return {
    y: m.year, mo: m.month, d: m.day,
    h: parseInt(m.hour, 10), mi: parseInt(m.minute, 10), s: parseInt(m.second, 10)
  };
}

// ====== 处理单个用户 ======
async function processUser(row) {
  const username = row.username;
  const data = row.data || {};
  if (!data.schedule_enabled) return;
  const hour = data.schedule_hour, minute = data.schedule_minute;
  if (hour == null || minute == null) {
    log(`用户 ${username}: 未配置定时时间，跳过`, 'WARN');
    return;
  }
  if (!(parseInt(hour, 10) === 23 && 35 <= parseInt(minute, 10) && parseInt(minute, 10) <= 59)) {
    log(`用户 ${username}: 定时时间不在允许范围(23:35–23:59)，跳过`, 'WARN');
    return;
  }
  const bj = beijingParts();
  if (!(bj.h === 23 && bj.mi >= 35)) return;          // 仅在 23:35–23:59 窗口内执行
  if (bj.mi < parseInt(minute, 10)) return;            // 窗口内但还没到设定分钟

  const creds = buildCredentials(data);
  if (!creds.length) { log(`用户 ${username}: 缺少可用凭证，跳过`, 'WARN'); return; }

  log(`▶ 用户 ${username} 北京时间 ${String(bj.h).padStart(2,'0')}:${String(bj.mi).padStart(2,'0')} 触发定时退订（设定 ${String(hour).padStart(2,'0')}:${String(minute).padStart(2,'0')}），共 ${creds.length} 个凭证`, 'WARN');

  let grand = { success: 0, skipped: 0, locked: 0, fail: 0 };
  for (const c of creds) {
    const regions = buildCredRegions(data, c.label);
    if (!regions.size) {
      log(`  ⏭️ 凭证「${c.label}」无可执行地区（未勾选地区或与启用地区无交集），跳过`, 'WARN');
      continue;
    }
    log(`  📍 凭证「${c.label}」本次退订地区（${regions.size} 个）：${[...regions].map(r => (REGION_INFO[r]||r)+'('+r+')').join('、')}`, 'INFO');
    const clients = makeClients(c.ak, c.sk);
    const tasks = [];
    for (const rid of regions) {
      const list = await listInstancesInRegion(clients, rid);
      log(`[${REGION_INFO[rid] || rid}] 查到 ${list.length} 台实例`);
      for (const it of list) {
        if (isGolden(it)) { log(`🔒 [${REGION_INFO[rid] || rid}] 跳过黄金机 ${it.InstanceId}，绝不退订`, 'warn'); continue; }
        if (isRefundExempt(it)) { log(`🛡️ [${REGION_INFO[rid] || rid}] 跳过豁免实例 ${it.InstanceId}`, 'warn'); continue; }
        tasks.push({ rid, iid: it.InstanceId });
      }
    }
    if (!tasks.length) { log(`  ✅ 凭证「${c.label}」无待退订实例`, 'SUCCESS'); continue; }
    log(`🔄 凭证「${c.label}」有界并发退订 ${tasks.length} 台（并发≤${REFUND_CONCURRENCY}，速率≤${REFUND_QPS}/秒）...`, 'warn');
    const t = await runBoundedRefund(clients, tasks);
    for (const k of Object.keys(grand)) grand[k] += t[k];
  }
  const fail = grand.fail;
  log(`🏁 用户 ${username} 全部凭证退订完成：成功 ${grand.success} 跳过 ${grand.skipped} 锁定 ${grand.locked} 失败 ${grand.fail}`, fail === 0 ? 'success' : 'warn');
  if (fail > 0) process.exitCode = 1;
}

// ====== 主流程 ======
async function main() {
  log(`启动定时退订（读取 Supabase 配置，按「凭证 + 地区」勾选执行）；启用地域：${ACTIVE_REGIONS.map(r => REGION_INFO[r] || r).join(' / ')}`);
  let rows;
  try {
    rows = await supabaseGetAllUserData();
  } catch (e) {
    log('读取 Supabase 失败，无法执行任何退订：' + (e.message || e), 'error');
    process.exit(1);
  }
  if (!Array.isArray(rows) || !rows.length) {
    log('未发现任何用户数据，无需退订', 'success');
    return;
  }
  for (const row of rows) {
    try { await processUser(row); }
    catch (e) { log(`用户 ${row.username} 处理异常: ${e.stack || e}`, 'error'); }
  }
}

main().catch(e => {
  log(`脚本异常退出: ${e.stack || e}`, 'error');
  process.exit(1);
});

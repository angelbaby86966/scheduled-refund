/**
 * 阿里云轻量云服务器定时自动退订脚本
 * 服务端运行（GitHub Actions），关闭浏览器也能到点执行
 * 依赖：@alicloud/pop-core
 */
const RPCClient = require('@alicloud/pop-core');

// ====== 配置 ======
const AK = process.env.ALIYUN_AK || '';
const SK = process.env.ALIYUN_SK || '';
const REGION_LIST = (process.env.REGIONS || 'cn-hangzhou,cn-beijing,cn-shanghai,cn-shenzhen,cn-chengdu,cn-guangzhou')
  .split(',').map(s => s.trim()).filter(Boolean);

const REFUND_BATCH_SIZE = 10;
const REFUND_GLOBAL_QPS = 4;
const REFUND_QPS_BURST = 4;
const REFUND_INTER_BATCH_MS = 800;
const REFUND_MAX_RETRY = 6;
const REFUND_BACKOFF_MAX_MS = 20000;
const REFUND_TOTAL_CONCURRENCY = 6;
const REFUND_PER_INSTANCE_TIMEOUT = 180000;

const REGION_NAMES = {
  'cn-hangzhou': '杭州',
  'cn-beijing': '北京',
  'cn-shanghai': '上海',
  'cn-shenzhen': '深圳',
  'cn-chengdu': '成都',
  'cn-guangzhou': '广州',
};

// ====== 工具 ======
function now() { return new Date().toLocaleString('zh-CN', { hour12: false }); }
function log(msg, level = 'info') {
  const prefix = `[${now()}]`;
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

function makeSemaphore(max) {
  let count = 0;
  const waiting = [];
  return {
    acquire: () => new Promise(resolve => {
      if (count < max) { count++; resolve(); }
      else waiting.push(resolve);
    }),
    release: () => {
      count = Math.max(0, count - 1);
      if (waiting.length) { count++; const next = waiting.shift(); next(); }
    }
  };
}

// 全局限流冷却：任一实例被限流，所有 worker 统一暂停
const gThrottleState = { until: 0, count: 0, baseMs: 8000, maxMs: 60000 };
function resetGlobalThrottle() { gThrottleState.count = 0; gThrottleState.until = 0; }
function triggerGlobalThrottle(regionName, instanceId) {
  gThrottleState.count++;
  const delay = Math.min(gThrottleState.maxMs, gThrottleState.baseMs * Math.pow(2, gThrottleState.count - 1))
    + Math.floor(Math.random() * 2000);
  gThrottleState.until = Date.now() + delay;
  log(`🌐 命中账号级限流 [${regionName}] ${instanceId}，全局冷却 ${(delay / 1000).toFixed(1)} 秒`, 'warn');
}
async function waitGlobalThrottle() {
  const wait = gThrottleState.until - Date.now();
  if (wait > 0) {
    log(`⏸️ 全局冷却中，等待 ${(wait / 1000).toFixed(1)} 秒...`);
    await sleep(wait);
  }
}

// ====== 客户端 ======
if (!AK || !SK) {
  log('缺少阿里云凭证：请设置 ALIYUN_AK 和 ALIYUN_SK 环境变量', 'error');
  process.exit(1);
}

const swasClient = new RPCClient({
  endpoint: 'https://swas-open.aliyuncs.com',
  apiVersion: '2020-06-01',
  accessKeyId: AK,
  accessKeySecret: SK,
});

const bssClient = new RPCClient({
  endpoint: 'https://business.aliyuncs.com',
  apiVersion: '2017-12-14',
  accessKeyId: AK,
  accessKeySecret: SK,
});

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

// ====== API 调用 ======
async function listInstancesInRegion(regionId) {
  const instances = [];
  let page = 1;
  while (true) {
    try {
      const res = await swasClient.request('DescribeInstances', {
        RegionId: regionId,
        PageNumber: page,
        PageSize: 100,
      }, { method: 'POST' });
      const list = (res && res.Instances) || [];
      instances.push(...list);
      const total = (res && res.TotalCount) || list.length;
      if (instances.length >= total) break;
      page++;
    } catch (e) {
      log(`[${REGION_NAMES[regionId] || regionId}] 查询实例列表失败: ${e.message || e}`, 'error');
      break;
    }
  }
  return instances;
}

async function refundOne(regionId, instanceId, bucket) {
  if (bucket) await bucket.take(1);
  const clientToken = `scheduled-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
  const regionName = REGION_NAMES[regionId] || regionId;
  let attempt = 0;
  while (true) {
    try {
      const res = await bssClient.request('RefundInstance', {
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
        return { ok: false, id: instanceId, skipped: true, err: msg };
      }
      if (msg.includes('ResourceNotExists')) {
        log(`[${regionName}] ${instanceId} 已不存在/已退订，跳过`);
        return { ok: false, id: instanceId, skipped: true, err: msg };
      }
      if (attempt >= REFUND_MAX_RETRY) {
        log(`[${regionName}] ${instanceId} 退订失败: ${msg}`, 'error');
        return { ok: false, id: instanceId, err: msg };
      }
      attempt++;
      if (attempt === 1 && isThrottle(msg)) triggerGlobalThrottle(regionName, instanceId);
      const backoff = Math.min(REFUND_BACKOFF_MAX_MS, 1000 * Math.pow(2, attempt)) + Math.floor(Math.random() * 1000);
      if (attempt <= 1) log(`[${regionName}] ${instanceId} 触发限流，第 ${attempt} 次退避重试 (${backoff}ms)`, 'warn');
      await sleep(backoff);
    }
  }
}

async function safeRefund(regionId, instanceId, bucket, sem) {
  await waitGlobalThrottle();
  await sem.acquire();
  try {
    return await refundOne(regionId, instanceId, bucket);
  } finally {
    sem.release();
  }
}

// ====== 主流程 ======
async function main() {
  log(`启动定时退订：目标地域 ${REGION_LIST.map(r => REGION_NAMES[r] || r).join(' / ')}`);
  resetGlobalThrottle();

  // 1. 查询所有实例
  const byRegion = {};
  for (const rid of REGION_LIST) {
    const list = await listInstancesInRegion(rid);
    byRegion[rid] = list;
    log(`[${REGION_NAMES[rid] || rid}] 查到 ${list.length} 台实例`);
  }
  const total = Object.values(byRegion).reduce((a, b) => a + b.length, 0);
  if (total === 0) {
    log('未发现任何实例，无需退订', 'success');
    return;
  }
  log(`共 ${total} 台待退订`);

  // 2. 按地区分批并行退订
  const bucket = makeTokenBucket(REFUND_QPS_BURST, REFUND_GLOBAL_QPS);
  const sem = makeSemaphore(REFUND_TOTAL_CONCURRENCY);
  const stats = { success: 0, skipped: 0, fail: 0 };

  async function regionWorker(rid) {
    const list = byRegion[rid] || [];
    if (!list.length) return;
    const regionName = REGION_NAMES[rid] || rid;
    let batchNo = 0;
    const arr = list.slice();
    while (arr.length) {
      batchNo++;
      const batch = arr.splice(0, REFUND_BATCH_SIZE);
      log(`[${regionName}] 第 ${batchNo} 批：退订 ${batch.length} 台`);
      const results = await Promise.all(batch.map(it => safeRefund(rid, it.InstanceId, bucket, sem)));
      results.forEach(r => {
        if (r.ok) stats.success++;
        else if (r.skipped) stats.skipped++;
        else stats.fail++;
      });
      if (arr.length) {
        log(`[${regionName}] 本批完成，${REFUND_INTER_BATCH_MS / 1000} 秒后继续（剩余 ${arr.length} 台）`);
        await sleep(REFUND_INTER_BATCH_MS);
      }
    }
    log(`[${regionName}] 该地区退订完成`, 'success');
  }

  await Promise.all(REGION_LIST.map(rid => regionWorker(rid)));

  log(`━━━━━━━━━━━━━━━━━━━━━━`);
  log(`退订完成：成功 ${stats.success} 台，跳过 ${stats.skipped} 台，失败 ${stats.fail} 台`, stats.fail === 0 ? 'success' : 'warn');
  if (stats.fail > 0) process.exit(1);
}

main().catch(e => {
  log(`脚本异常退出: ${e.stack || e}`, 'error');
  process.exit(1);
});

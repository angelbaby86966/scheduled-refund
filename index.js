/**
 * 阿里云轻量云服务器定时自动退订脚本
 * 服务端运行（GitHub Actions），关闭浏览器也能到点执行
 * 依赖：@alicloud/pop-core
 *
 * 退订策略（对齐前端 app.js?v=73 有界并发模式）：
 *   1) 全局令牌桶：平滑到 REFUND_QPS 次/秒，避免突发尖峰触发限流
 *   2) 并发上限：worker 池最多 REFUND_CONCURRENCY 个在途请求
 *   3) 幂等：每个实例固定一个 clientToken，限流重试时复用，避免重复退款
 *   4) 单实例退避：Throttling/ServiceUnavailable 等瞬时错误指数退避重试，不阻塞其他 worker
 */
const RPCClient = require('@alicloud/pop-core');

// ====== 配置 ======
const AK = process.env.ALIYUN_AK || '';
const SK = process.env.ALIYUN_SK || '';
const REGION_LIST = (process.env.REGIONS || 'cn-hangzhou,cn-beijing,cn-shanghai,cn-shenzhen,cn-chengdu,cn-guangzhou')
  .split(',').map(s => s.trim()).filter(Boolean);

const REFUND_CONCURRENCY = 8;     // 同时最多在途请求数（有界并发上限）
const REFUND_QPS = 8;             // 目标平稳速率（令牌桶：容量=QPS，refill=QPS/秒）
const REFUND_MAX_RETRY = 5;       // 单实例限流最大重试次数
const REFUND_BACKOFF_MAX_MS = 8000; // 单实例退避最大等待毫秒
const REFUND_PER_INSTANCE_TIMEOUT = 60000; // 单实例请求超时

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
  await bucket.take(1);
  const clientToken = `scheduled-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
  const regionName = REGION_NAMES[regionId] || regionId;
  let attempt = 0;
  while (true) {
    try {
      await bssClient.request('RefundInstance', {
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

async function runBoundedRefund(tasks) {
  const bucket = makeTokenBucket(REFUND_QPS, REFUND_QPS);
  const total = { success: 0, skipped: 0, locked: 0, fail: 0 };
  if (!tasks.length) return total;
  let idx = 0, done = 0;
  async function worker() {
    while (idx < tasks.length) {
      const task = tasks[idx++];
      const r = await refundOne(task.rid, task.iid, bucket);
      const rn2 = REGION_NAMES[task.rid] || task.rid;
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

// ====== 主流程 ======
async function main() {
  log(`启动定时退订：目标地域 ${REGION_LIST.map(r => REGION_NAMES[r] || r).join(' / ')}`);

  // 1. 查询所有实例
  const byRegion = {};
  for (const rid of REGION_LIST) {
    const list = await listInstancesInRegion(rid);
    byRegion[rid] = list;
    log(`[${REGION_NAMES[rid] || rid}] 查到 ${list.length} 台实例`);
  }

  // 2. 构建任务队列
  const tasks = [];
  Object.keys(byRegion).forEach(rid => {
    const arr = byRegion[rid] || [];
    if (!arr.length) { log(`[${REGION_NAMES[rid] || rid}] 无实例，跳过`, 'info'); return; }
    arr.forEach(it => tasks.push({ rid, iid: it.InstanceId }));
    log(`[${REGION_NAMES[rid] || rid}] 共 ${arr.length} 台待退订`, 'info');
  });

  if (!tasks.length) {
    log('未发现任何实例，无需退订', 'success');
    return;
  }
  log(`🔄 有界并发退订 ${tasks.length} 台（并发≤${REFUND_CONCURRENCY}，速率≤${REFUND_QPS}/秒，限流自动退避重试）...`, 'warn');

  // 3. 执行退订
  const total = await runBoundedRefund(tasks);

  log(`━━━━━━━━━━━━━━━━━━━━━━`);
  log(`退订完成：成功 ${total.success} 台，跳过 ${total.skipped} 台，锁定 ${total.locked} 台，失败 ${total.fail} 台`, total.fail === 0 ? 'success' : 'warn');
  if (total.fail > 0) process.exit(1);
}

main().catch(e => {
  log(`脚本异常退出: ${e.stack || e}`, 'error');
  process.exit(1);
});

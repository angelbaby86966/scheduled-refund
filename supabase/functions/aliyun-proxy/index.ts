// 阿里云 SWAS API 代理 + 定时退订（零依赖版，避免 esm.sh BOOT_ERROR）

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

// 阿里云 SWAS-OPEN 所有 API（包括 CreateOrder）都用地域 endpoint（swas.${regionId}.aliyuncs.com）
// 没有 swas-open.aliyuncs.com 这个中心 endpoint（NXDOMAIN）
function regionEndpoint(r: string) { return `https://swas.${r}.aliyuncs.com/`; }

// 阿里云 BSS（计费）中心 endpoint —— 用于真正的退订（RefundInstance），能退款到原账户
// 走 ProductCode 区分产品，SWAS 试 "swas"；不在地域里，是全局 endpoint
const BSS_ENDPOINT = "https://business.aliyuncs.com/";
const BSS_VERSION = "2017-12-14";
const SWAS_PRODUCT_CODE = "swas";   // SWAS（轻量应用服务器）的 product code
// 如果上面错了就改回来。备选："swas-open"、"simpleappserver"

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

const REGION_INFO: Record<string, string> = {
  "cn-hangzhou": "杭州","cn-shanghai": "上海","cn-beijing": "北京",
  "cn-shenzhen": "深圳","cn-guangzhou": "广州","cn-nanjing": "南京",
  "cn-fuzhou": "福州","cn-wuhan": "武汉","cn-chengdu": "成都",
  "cn-heyuan": "河源","cn-huhehaote": "呼和浩特","cn-wulanchabu": "乌兰察布",
  "cn-zhangjiakou": "张家口","cn-hongkong": "中国香港",
  "ap-northeast-1": "东京","ap-northeast-2": "首尔",
  "ap-southeast-1": "新加坡","ap-southeast-2": "悉尼",
  "ap-southeast-3": "吉隆坡","ap-southeast-5": "雅加达",
  "ap-southeast-7": "曼谷","ap-south-1": "孟买",
  "us-west-1": "硅谷","us-east-1": "弗吉尼亚",
  "eu-west-1": "伦敦","eu-central-1": "法兰克福","me-east-1": "迪拜",
};

// ====== 签名 ======
function pe(s: string): string {
  return encodeURIComponent(s)
    .replace(/!/g,"%21").replace(/'/g,"%27")
    .replace(/\(/g,"%28").replace(/\)/g,"%29")
    .replace(/\*/g,"%2A").replace(/\+/g,"%20")
    .replace(/%7E/g,"~");
}
async function hmac(key: string, data: string): Promise<string> {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey("raw", enc.encode(key), {name:"HMAC",hash:"SHA-1"}, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, enc.encode(data));
  return btoa(String.fromCharCode(...new Uint8Array(sig)));
}

// V3 签名（OpenAPI 3.0）专用 - 用于必须使用 V3 的 API（如 CreateOrder）
// 阿里云 SWAS-OPEN CreateOrder 同时要求：(1) ACS3-HMAC-SHA256 签名 (2) Commodity 用 flat 格式 (3) form-urlencoded body
async function callAliyunV3(endpoint: string, action: string, params: Record<string, unknown>, ak: string, sk: string): Promise<any> {
  // 把 params 拍平成 form-urlencoded (OpenAPI 3.0 map format: Parent.Field=value)
  const flat: string[] = [];
  function flatObj(prefix: string, obj: any) {
    for (const k of Object.keys(obj||{})) {
      const v = obj[k];
      if (v === undefined || v === null) continue;
      if (typeof v === "object" && !Array.isArray(v)) {
        flatObj(prefix + k + ".", v);
      } else if (Array.isArray(v)) {
        v.forEach((it,i) => flatObj(prefix + k + "." + (i+1) + ".", it));
      } else {
        flat.push(prefix + k + "=" + encodeURIComponent(String(v)));
      }
    }
  }
  flatObj("", params);
  const form = flat.join("&");
  const formHash = await sha256Hex(form);

  const url = new URL(endpoint);
  const host = url.host;

  const headers: Record<string, string> = {
    "host": host,
    "x-acs-action": action,
    "x-acs-content-sha256": formHash,
    "x-acs-date": new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    "x-acs-version": "2020-06-01",
  };

  const sortedKeys = Object.keys(headers).sort();
  const canonicalHeaders = sortedKeys.map(k => `${k}:${headers[k].trim()}\n`).join("");
  const canonicalRequest = `POST\n${url.pathname}\n\n${canonicalHeaders}\n${sortedKeys.join(";")}\n${formHash}`;
  const crHash = await sha256Hex(canonicalRequest);
  const sts = `ACS3-HMAC-SHA256\n${crHash}`;

  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey("raw", enc.encode(sk), {name:"HMAC",hash:"SHA-256"}, false, ["sign"]);
  const sigBytes = await crypto.subtle.sign("HMAC", k, enc.encode(sts));
  const signature = Array.from(new Uint8Array(sigBytes)).map(b => b.toString(16).padStart(2,"0")).join("");

  const reqHeaders: Record<string, string> = {
    "host": host,
    "x-acs-action": action,
    "x-acs-content-sha256": formHash,
    "x-acs-date": headers["x-acs-date"],
    "x-acs-version": "2020-06-01",
    "content-type": "application/x-www-form-urlencoded",
    "Authorization": `ACS3-HMAC-SHA256 Credential=${ak},SignedHeaders=${sortedKeys.join(";")},Signature=${signature}`,
  };

  const resp = await fetch(endpoint, {
    method: "POST",
    headers: reqHeaders,
    body: form,
  });
  const text = await resp.text();
  let data: any;
  try { data = JSON.parse(text); } catch { throw new Error(`HTTP ${resp.status}: ${text.slice(0,300)}`); }
  if (data?.Code || data?.Message || data?.code || data?.message) {
    throw new Error(data.Message || data.message || data.Code || data.code || `HTTP ${resp.status}`);
  }
  return data;
}

async function sha256Hex(text: string): Promise<string> {
  const enc = new TextEncoder();
  const bytes = await crypto.subtle.digest("SHA-256", enc.encode(text));
  return Array.from(new Uint8Array(bytes)).map(b => b.toString(16).padStart(2,"0")).join("");
}

async function callAliyun(endpoint: string, action: string, params: Record<string, unknown>, ak: string, sk: string, version: string = "2020-06-01"): Promise<any> {
  const common: Record<string,string> = {
    AccessKeyId: ak, Action: action, Format: "JSON",
    SignatureMethod: "HMAC-SHA1", SignatureNonce: crypto.randomUUID(),
    SignatureVersion: "1.0",
    Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/,"Z"),
    Version: version,
  };
  const all: Record<string,string> = { ...common };
  for (const k of Object.keys(params||{})) {
    const v = (params as any)[k];
    if (v === undefined || v === null) continue;
    // V1 签名风格：嵌套对象直接 JSON 字符串（listInstances/listPlans/listImages/deleteInstance 这类 API 工作正常）
    all[k] = typeof v === "string" ? v : JSON.stringify(v);
  }
  const keys = Object.keys(all).sort();
  const parts = keys.map(k => pe(k)+"="+pe(all[k]));
  const cq = parts.join("&");
  const sts = "POST&"+pe("/")+"&"+pe(cq);
  const sig = await hmac(sk+"&", sts);
  const fq = cq+"&"+pe("Signature")+"="+pe(sig);

  // DEBUG: 打印发到 aliyun 的参数键
  console.log("[aliyun-proxy] action=", action, " keys=", keys.filter(k=>k.startsWith("Commodity")||k.startsWith("Region")).join(","), " hasCommodity=", !!keys.find(k=>k.startsWith("Commodity.")));

  const resp = await fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: fq,
  });
  let data: any;
  try { data = await resp.json(); } catch { data = {}; }
  if (data?.Code || data?.Message) {
    throw new Error(data.Message || data.Code || `HTTP ${resp.status}`);
  }
  return data;
}

// ====== 退订 ======
const LOCKED = [
  // BSS API 错误码
  "MissingRefundAmount","InvalidPayMethod","CannotDeleteInstance","RefundFailed","NoFullRefund",
  "NoApplicable","NotApplicable","ExceedRefundQuota","ExistUnPaidOrder","ExistRefundingOrder",
  "NoRestValue","AmbassadorOrderLimit","ActivityForbidden","CommodityNotSupported",
  "ProductCheckError","ResourceStatusError","NotAuthorized",
  // 中文关键词
  "非全额退款","非全额退订","订单未到期","订单到期","尚未结算",
  "InstanceHasUnsettledBill","PayMethodNotSupported","请先退订订单",
];
const isLock = (m:string)=>LOCKED.some(p=>m.includes(p));
const isNF = (m:string)=>m.includes("NotFound")||m.includes("InvalidInstance")||m.includes("ResourceNotExists")||m.includes("不存在");

async function listAll(ak:string,sk:string) {
  const all: Array<{regionId:string;instanceId:string}> = [];
  for (const rid of Object.keys(REGION_INFO)) {
    try {
      const p = await callAliyun(regionEndpoint(rid),"ListInstances",{PageSize:"100",PageNumber:"1"},ak,sk);
      let ins = p.Instances||[];
      const total = p.TotalCount||0;
      if (total>100) {
        for (let pg=2; pg<=Math.ceil(total/100); pg++) {
          const np = await callAliyun(regionEndpoint(rid),"ListInstances",{PageSize:"100",PageNumber:String(pg)},ak,sk);
          ins = ins.concat(np.Instances||[]);
        }
      }
      for (const i of ins) all.push({regionId:rid,instanceId:i.InstanceId});
    } catch(_) {}
  }
  return all;
}

async function cancelOne(rid:string,iid:string,ak:string,sk:string) {
  // 用 BSS RefundInstance 真正退订（能退款到原账户，不只是删除）
  // RefundInstance 是中心 endpoint，不分地域；地域信息仅用于日志
  // 自动尝试多个 ProductCode（swas / simpleappserver / swas-open）
  const TRIED_CODES = ["swas", "simpleappserver", "swas-open", "simpleAppserver"];
  let lastErr: any = null;
  for (const code of TRIED_CODES) {
    try {
      await callAliyun(BSS_ENDPOINT,"RefundInstance",{
        InstanceId: iid,
        ProductCode: code,
        ProductType: "",
        ImmediatelyRelease: "1",  // 1=立即释放；0=先停机按停机策略停
        ClientToken: crypto.randomUUID(),
      },ak,sk,BSS_VERSION);
      return;  // 成功！
    } catch(e: any) {
      lastErr = e;
      const m = e?.message || String(e);
      if (m.includes("CommodityNotSupported") || m.includes("ProductCheckError")) {
        continue;  // 试下一个 code
      }
      throw e;  // 其他错误直接抛
    }
  }
  throw lastErr || new Error("所有 ProductCode 都不支持");
}

async function batchCancel(insts:Array<{regionId:string;instanceId:string}>,ak:string,sk:string) {
  const C = 50;
  let s=0,sk2=0,l=0,f=0;
  for (let i=0;i<insts.length;i+=C) {
    const slice = insts.slice(i,i+C);
    const rs = await Promise.all(slice.map(async x=>{
      try { await cancelOne(x.regionId,x.instanceId,ak,sk); return "s"; }
      catch(e:any){
        const m=e?.message||"";
        console.log(`[refund] ${x.regionId}/${x.instanceId} 失败: ${m}`);
        if(isLock(m)) return "l"; if(isNF(m)) return "k"; return "f";
      }
    }));
    for (const r of rs) { if(r==="s")s++; else if(r==="k")sk2++; else if(r==="l")l++; else f++; }
    // BSS 限流 20/1s，保守间隔避免触发
    if (i+C<insts.length) await new Promise(r=>setTimeout(r,300));
  }
  return {success:s,skipped:sk2,locked:l,failed:f};
}

async function runFullCancel(ak:string,sk:string) {
  const all = await listAll(ak,sk);
  if (all.length===0) return {success:0,skipped:0,locked:0,failed:0,message:"无实例"};
  const r1 = await batchCancel(all,ak,sk);
  let res:any = {...r1, firstRoundInstances: all.length};
  if (r1.failed>0) {
    await new Promise(r=>setTimeout(r,10*60*1000));
    const rem = await listAll(ak,sk);
    if (rem.length>0) {
      const r2 = await batchCancel(rem,ak,sk);
      res = {success:r1.success+r2.success,skipped:r1.skipped+r2.skipped,locked:r1.locked+r2.locked,failed:r2.failed,firstRound:r1,secondRound:r2};
    }
  }
  return res;
}

// 用 fetch 直接读 user_data 表（无需 supabase-js）
async function loadCredsForUsers(akHint?:string, skHint?:string) {
  if (akHint && skHint) return [{username:"(caller)",ak:akHint,sk:skHint}];
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/user_data?select=username,data`, {
    headers: {
      "apikey": SUPABASE_ANON_KEY,
      "Authorization": `Bearer ${SUPABASE_ANON_KEY}`,
    },
  });
  if (!resp.ok) throw new Error("读取用户凭证失败: HTTP "+resp.status);
  const rows: any[] = await resp.json();
  return rows
    .filter(r => r.data?.ak_id && r.data?.ak_secret)
    .map(r => ({username:r.username, ak:r.data.ak_id, sk:r.data.ak_secret}));
}

function json(body:unknown, status=200) {
  return new Response(JSON.stringify(body), {status, headers:{...CORS,"Content-Type":"application/json"}});
}

Deno.serve(async (req:Request)=>{
  if (req.method==="OPTIONS") return new Response("ok",{headers:CORS});
  let p:any = {};
  try { p = await req.json(); } catch {}
  const action = p?.action;
  console.log("[aliyun-proxy] method=", req.method, " action=", JSON.stringify(action), " keys=", Object.keys(p||{}).join(","));
  try {
    switch (action) {
      case "createOrder": {
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params) return json({error:"缺少 params"},400);
        const regionId = params.RegionId || "cn-hangzhou";
        // 阿里云 SWAS-OPEN CreateOrder 要求 OpenAPI V3 签名 + JSON body（嵌套 Commodity 结构）
        const data = await callAliyunV3(regionEndpoint(regionId), "CreateOrder", params, ak_id, ak_secret);
        return json({success:true,data});
      }
      case "listPlans": {
        const {ak_id,ak_secret,regionId} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        const data = await callAliyun(regionEndpoint(regionId||"cn-hangzhou"),"ListPlans",{RegionId:regionId||"cn-hangzhou"},ak_id,ak_secret);
        return json({success:true,data});
      }
      case "listImages":
      case "ListImages": {
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        const regionId = params?.RegionId || p.regionId || "cn-hangzhou";
        const queryParams: any = {RegionId: regionId};
        if (params?.PageSize) queryParams.PageSize = params.PageSize;
        if (params?.PageNumber) queryParams.PageNumber = params.PageNumber;
        const data = await callAliyun(regionEndpoint(regionId),"ListImages",queryParams,ak_id,ak_secret);
        return json({success:true,data});
      }
      case "CreateCustomImage": {
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params?.RegionId || !params?.InstanceId || !params?.ImageName) {
          return json({error:"缺少 params.RegionId/InstanceId/ImageName"},400);
        }
        const data = await callAliyun(regionEndpoint(params.RegionId),"CreateCustomImage",{
          RegionId: params.RegionId,
          InstanceId: params.InstanceId,
          ImageName: params.ImageName,
        },ak_id,ak_secret);
        return json({success:true,data});
      }
      case "CreateInstances": {
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params?.RegionId || !params?.ImageId || !params?.PlanId) {
          return json({error:"缺少 params.RegionId/ImageId/PlanId"},400);
        }
        const apiParams: any = {
          RegionId: params.RegionId,
          ImageId: params.ImageId,
          PlanId: params.PlanId,
          Amount: params.Amount ?? 1,
          Period: params.Period ?? 1,
          PeriodUnit: params.PeriodUnit || "Month",
        };
        // SWAS CreateInstances 没有 AutoPay 参数，文档明确：调用前需确保账户余额充足，否则创建失败
        if (params.ClientToken) apiParams.ClientToken = params.ClientToken;
        const data = await callAliyun(regionEndpoint(params.RegionId),"CreateInstances",apiParams,ak_id,ak_secret);
        return json({success:true,data});
      }
      case "CreateOrder": {
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params?.RegionId || !params?.ImageId || !params?.PlanId) {
          return json({error:"缺少 params.RegionId/ImageId/PlanId"},400);
        }
        // SWAS CreateOrder 只下单、不扣费（AutoPay=false），余额不足也能生成待支付订单
        const commodity: any = {
          Period: params.Period ?? 1,
          PeriodUnit: params.PeriodUnit || "Month",
          PayType: "Prepaid",
          CommodityType: "Server",
          PlanId: params.PlanId,
          ImageId: params.ImageId,
          Amount: params.Amount ?? 1,
          DataDiskSize: params.DataDiskSize ?? 0,
          AutoPay: false,
          AutoRenew: false,
        };
        const apiParams: any = {
          RegionId: params.RegionId,
          OrderType: "Buy",
          Commodity: commodity,
        };
        if (params.ClientToken) apiParams.ClientToken = params.ClientToken;

        // CreateOrder 要求 V3 签名 + flat 参数格式，优先走 V3；失败回退 V1（Commodity 用 JSON 串）
        const ep = regionEndpoint(params.RegionId);
        let data: any, lastErr = "";
        try {
          data = await callAliyunV3(ep,"CreateOrder",apiParams,ak_id,ak_secret);
        } catch (e1) {
          lastErr = String((e1 as Error)?.message || e1);
          console.log("[aliyun-proxy] CreateOrder V3 failed:", lastErr, "-> fallback V1");
          const v1Params: any = { ...apiParams, Commodity: JSON.stringify(commodity) };
          data = await callAliyun(ep,"CreateOrder",v1Params,ak_id,ak_secret);
        }
        return json({success:true,data});
      }
      case "DeleteCustomImage": {
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params?.RegionId || !params?.ImageId) {
          return json({error:"缺少 params.RegionId/ImageId"},400);
        }
        const data = await callAliyun(regionEndpoint(params.RegionId),"DeleteCustomImage",{
          RegionId: params.RegionId,
          ImageId: params.ImageId,
        },ak_id,ak_secret);
        return json({success:true,data});
      }
      case "ListInstances": case "listInstances": {
        // 通用 ListInstances 转发（带分页参数透传）
        const {ak_id,ak_secret,regionId,params:bp} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        const rid = regionId || bp?.RegionId || "cn-hangzhou";
        const queryParams:any = {RegionId:rid};
        if (bp?.PageSize) queryParams.PageSize = bp.PageSize;
        if (bp?.PageNumber) queryParams.PageNumber = bp.PageNumber;
        if (bp?.InstanceId) queryParams.InstanceId = bp.InstanceId;
        if (bp?.Status) queryParams.Status = bp.Status;
        if (bp?.Tags && Array.isArray(bp.Tags)) {
          bp.Tags.forEach((t:any,i:number) => {
            if (t.Key) queryParams[`Tag.${i+1}.Key`] = t.Key;
            if (t.Value) queryParams[`Tag.${i+1}.Value`] = t.Value;
          });
        }
        const data = await callAliyun(regionEndpoint(rid),"ListInstances",queryParams,ak_id,ak_secret);
        return json({success:true,data});
      }
      case "runCommand": {
        // 在指定地域的某一台实例上执行一条命令
        // params: { RegionId, InstanceId, CommandContent, Type, WorkingDir?, Timeout?, Name?, EnableParameter?, Parameters? }
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params) return json({error:"缺少 params"},400);
        const regionId = params.RegionId;
        if (!regionId) return json({error:"缺少 params.RegionId"},400);
        if (!params.InstanceId) return json({error:"缺少 params.InstanceId"},400);
        if (!params.CommandContent) return json({error:"缺少 params.CommandContent"},400);
        if (!params.Type) return json({error:"缺少 params.Type（RunShellScript/RunPowerShellScript/RunBatScript）"},400);
        const data = await callAliyun(regionEndpoint(regionId),"RunCommand",params,ak_id,ak_secret);
        return json({success:true,data});
      }
      case "rebootInstance": {
        // 重启单台实例
        // params: { RegionId, InstanceId }
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params) return json({error:"缺少 params"},400);
        const regionId = params.RegionId;
        const instanceId = params.InstanceId;
        if (!regionId) return json({error:"缺少 params.RegionId"},400);
        if (!instanceId) return json({error:"缺少 params.InstanceId"},400);
        const data = await callAliyun(regionEndpoint(regionId),"RebootInstance",{
          RegionId: regionId,
          InstanceId: instanceId,
          ClientToken: crypto.randomUUID(),
          Force: false,  // false=优雅重启；true=强制重启
        },ak_id,ak_secret);
        return json({success:true,data});
      }
      case "refundInstance": {
        // BSS 真正的退订（能退款），不是 SWAS 的 DeleteInstance
        // ProductCode 尝试顺序（按 SWAS 历史命名规范）：swas -> simpleappserver -> swas-open -> simpleAppserver
        // 第一个不报 CommodityNotSupported/ProductCheckError 的就是正确的
        // params: { InstanceId, ProductCode?, ProductType?, ImmediatelyRelease? }
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params) return json({error:"缺少 params"},400);
        if (!params.InstanceId) return json({error:"缺少 params.InstanceId"},400);

        const TRIED_CODES = params.ProductCode
          ? [params.ProductCode]   // 用户指定就只试这个
          : ["swas", "simpleappserver", "swas-open", "simpleAppserver"];

        let lastErr: any = null;
        for (const code of TRIED_CODES) {
          try {
            const data = await callAliyun(BSS_ENDPOINT,"RefundInstance",{
              InstanceId: params.InstanceId,
              ProductCode: code,
              ProductType: params.ProductType || "",
              ImmediatelyRelease: params.ImmediatelyRelease || "1",
              ClientToken: crypto.randomUUID(),
            },ak_id,ak_secret,BSS_VERSION);
            // 成功！记录这个 productCode 后面默认用
            console.log(`[refundInstance] ✅ ${params.InstanceId} ProductCode="${code}" 成功`);
            return json({success:true, data, productCode: code});
          } catch(e: any) {
            lastErr = e;
            const m = e?.message || String(e);
            console.log(`[refundInstance] ❌ ${params.InstanceId} ProductCode="${code}" 失败: ${m.slice(0, 200)}`);
            // 商品不支持 / 产品预校验失败：试下一个 code
            if (m.includes("CommodityNotSupported") || m.includes("ProductCheckError")) {
              continue;
            }
            // 其他错误（NotAuthorized, NotApplicable 等）直接抛
            throw e;
          }
        }
        // 所有 code 都试过还不支持，抛最后一个错误
        throw lastErr;
      }
      case "probeProductCode": {
        // 诊断：试多个 ProductCode 看哪个不返回 CommodityNotSupported
        // params: { InstanceId: string }
        const {ak_id, ak_secret, params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params?.InstanceId) return json({error:"缺少 params.InstanceId"},400);
        const CODES = ["swas", "simpleappserver", "swas-open", "simpleAppserver", "SimpleApplicationServer", "simpleappserverpre"];
        const trials: any[] = [];
        for (const code of CODES) {
          try {
            const data = await callAliyun(BSS_ENDPOINT,"RefundInstance",{
              InstanceId: params.InstanceId,
              ProductCode: code,
              ProductType: "",
              ImmediatelyRelease: "0",  // 探测用 0（按停机策略停），避免误删实例
              ClientToken: crypto.randomUUID(),
            },ak_id,ak_secret,BSS_VERSION);
            trials.push({code, ok: true, data});
            // 找到第一个可用的
            break;
          } catch(e: any) {
            const m = e?.message || String(e);
            const isCommodityError = m.includes("CommodityNotSupported") || m.includes("ProductCheckError");
            trials.push({
              code,
              ok: false,
              error: m.length > 300 ? m.slice(0, 300) + '...' : m,
              commodityError: isCommodityError,  // 这个错意味着不是真正的 code 错误，可以试下一个
            });
            if (!isCommodityError) break;  // 其他错就别继续试了
          }
          await new Promise(r => setTimeout(r, 200));  // 限流
        }
        return json({success: true, trials});
      }
      case "replaceSystemDisk": {
        // SWAS 重置系统（实际 API 名是 ResetSystem，不是 ReplaceSystemDisk 那是 ECS 的）
        // 注意：实例必须处于 Stopped 状态。如果 Status=Running 自动先停机再重置
        // params: { RegionId, InstanceId, ImageId, autoStopIfRunning?: bool }
        const {ak_id,ak_secret,params} = p;
        if (!ak_id||!ak_secret) return json({error:"缺少凭证"},400);
        if (!params) return json({error:"缺少 params"},400);
        const regionId = params.RegionId;
        const instanceId = params.InstanceId;
        const imageId = params.ImageId;
        const autoStop = params.autoStopIfRunning !== false;  // 默认 true
        if (!regionId) return json({error:"缺少 params.RegionId"},400);
        if (!instanceId) return json({error:"缺少 params.InstanceId"},400);
        if (!imageId) return json({error:"缺少 params.ImageId"},400);
        const endpoint = regionEndpoint(regionId);

        // 1. 查询实例状态
        let stoppedFirst = false;
        if (autoStop) {
          try {
            const desc = await callAliyun(endpoint,"ListInstances",{
              RegionId: regionId,
              InstanceId: instanceId,
            },ak_id,ak_secret);
            const inst = (desc.Instances || [])[0];
            if (inst && inst.Status !== "Stopped") {
              console.log("[resetSystem] 实例未停止:", inst.Status, "→ 先停机");
              await callAliyun(endpoint,"StopInstance",{
                RegionId: regionId,
                InstanceId: instanceId,
                Force: false,
                ClientToken: crypto.randomUUID(),
              },ak_id,ak_secret);
              stoppedFirst = true;
              // 停机是异步，最多重试 3 次等停机完成（每次等 5 秒）
              for (let i = 0; i < 3; i++) {
                await new Promise(r => setTimeout(r, 5000));
                const desc2 = await callAliyun(endpoint,"ListInstances",{
                  RegionId: regionId,
                  InstanceId: instanceId,
                },ak_id,ak_secret);
                if ((desc2.Instances || [])[0]?.Status === "Stopped") break;
              }
            }
          } catch (e:any) {
            console.log("[resetSystem] 检查/停机实例状态失败，继续尝试重置:", e.message);
          }
        }

        // 2. 重置系统
        const data = await callAliyun(endpoint,"ResetSystem",{
          RegionId: regionId,
          InstanceId: instanceId,
          ImageId: imageId,
          ClientToken: crypto.randomUUID(),
        },ak_id,ak_secret);
        return json({success:true, data, stoppedFirst});
      }
      case "createQuotaApplication": {
        // 阿里云配额中心：创建配额提升申请
        // params: {
        //   ProductCode?: "swas",
        //   QuotaActionCode?: "q_z3sbl5",
        //   DesireValue?: 500,
        //   RegionId?: "cn-hangzhou",
        //   Reason?: "业务扩展",
        //   NoticeType?: 0,
        //   QuotaCategory?: "CommonQuota"
        // }
        const {ak_id, ak_secret, params} = p;
        if (!ak_id || !ak_secret) return json({error: "缺少凭证"}, 400);
        if (!params) return json({error: "缺少 params"}, 400);
        const regionId = params.RegionId || "cn-hangzhou";
        const productCode = params.ProductCode || "swas";
        const quotaActionCode = params.QuotaActionCode || "q_z3sbl5";
        const desireValue = params.DesireValue ?? 500;
        const reason = params.Reason || "业务扩展，需提升实例数量上限";
        const noticeType = params.NoticeType ?? 0;
        const quotaCategory = params.QuotaCategory || "CommonQuota";

        const qParams: Record<string, string> = {
          ProductCode: productCode,
          QuotaActionCode: quotaActionCode,
          DesireValue: String(desireValue),
          Reason: reason,
          NoticeType: String(noticeType),
          QuotaCategory: quotaCategory,
          "Dimensions.1.Key": "regionId",
          "Dimensions.1.Value": regionId,
        };
        // 如果用户传了自定义维度，覆盖默认
        if (params.Dimensions && Array.isArray(params.Dimensions) && params.Dimensions.length > 0) {
          for (let i = 0; i < params.Dimensions.length; i++) {
            const dim = params.Dimensions[i];
            if (dim.Key !== undefined) qParams[`Dimensions.${i + 1}.Key`] = String(dim.Key);
            if (dim.Value !== undefined) qParams[`Dimensions.${i + 1}.Value`] = String(dim.Value);
          }
        }

        const QUOTA_ENDPOINT = "https://quotacenter.aliyuncs.com/";
        const QUOTA_VERSION = "2020-05-10";
        const data = await callAliyun(QUOTA_ENDPOINT, "CreateQuotaApplication", qParams, ak_id, ak_secret, QUOTA_VERSION);
        return json({success: true, data});
      }
      case "runCancelNow": {
        const users = await loadCredsForUsers(p.ak_id,p.ak_secret);
        const results:Record<string,any> = {};
        for (const u of users) {
          try { results[u.username] = await runFullCancel(u.ak,u.sk); }
          catch(e:any){ results[u.username] = {error:e.message}; }
        }
        return json({success:true,results,time:new Date().toISOString()});
      }
      case "runScheduledCancel": {
        // 🕐 自检时间模式（由 cron-job.org 每分钟调用一次）
        // 只对当前北京时间匹配 schedule_hour:schedule_minute 的用户执行退订
        // 用 ±2 分钟窗口避免 cron 延迟导致漏触发
        // 同一天内只执行一次（通过 schedule_last_executed_date 去重）
        const now = new Date();
        // 北京时间 = UTC+8
        const beijingMs = now.getTime() + 8 * 60 * 60 * 1000;
        const beijingTime = new Date(beijingMs);
        const curHour = beijingTime.getUTCHours();
        const curMinute = beijingTime.getUTCMinutes();
        const curTotalMin = curHour * 60 + curMinute;
        const todayStr = beijingTime.toISOString().slice(0, 10); // YYYY-MM-DD

        // 读取所有 user_data
        const resp = await fetch(`${SUPABASE_URL}/rest/v1/user_data?select=username,data`, {
          headers: {
            "apikey": SUPABASE_ANON_KEY,
            "Authorization": `Bearer ${SUPABASE_ANON_KEY}`,
          },
        });
        if (!resp.ok) throw new Error("读取用户凭证失败: HTTP " + resp.status);
        const rows: any[] = await resp.json();

        const results: Record<string, any> = {};
        let triggered = 0, skipped = 0;
        for (const r of rows) {
          const d = r.data || {};
          if (!d.ak_id || !d.ak_secret) continue;
          if (!d.schedule_enabled) {
            results[r.username] = {skipped: true, reason: "schedule_disabled"};
            skipped++;
            continue;
          }
          const sh = d.schedule_hour;
          const sm = d.schedule_minute;
          if (sh === undefined || sm === undefined || sh === null || sm === null) {
            results[r.username] = {skipped: true, reason: "no_schedule_set"};
            skipped++;
            continue;
          }
          // 同一天去重
          if (d.schedule_last_executed_date === todayStr) {
            results[r.username] = {skipped: true, reason: "already_executed_today", last_executed: d.schedule_last_executed_date};
            skipped++;
            continue;
          }
          const targetTotalMin = sh * 60 + sm;
          const diff = Math.abs(curTotalMin - targetTotalMin);
          // ±2 分钟窗口（允许 cron 延迟最多 2 分钟）
          if (diff <= 2) {
            // 时间匹配 → 执行退订
            triggered++;
            console.log(`[runScheduledCancel] ⏰ ${r.username} 时间匹配 (now=${curHour}:${curMinute}, target=${sh}:${sm}) → 执行退订`);
            try {
              const cancelRes = await runFullCancel(d.ak_id, d.ak_secret);
              // 成功后写入今天日期（防同天重复）
              await fetch(`${SUPABASE_URL}/rest/v1/user_data?username=eq.${r.username}`, {
                method: "PATCH",
                headers: {
                  "apikey": SUPABASE_ANON_KEY,
                  "Authorization": `Bearer ${SUPABASE_ANON_KEY}`,
                  "Content-Type": "application/json",
                },
                body: JSON.stringify({ data: { ...d, schedule_last_executed_date: todayStr } }),
              }).catch(() => {}); // 写日期失败不影响退订结果
              results[r.username] = { ...cancelRes, executed_at: todayStr + " " + String(curHour).padStart(2,'0') + ":" + String(curMinute).padStart(2,'0') };
            } catch(e:any) {
              results[r.username] = {error: e.message};
            }
          } else {
            skipped++;
            results[r.username] = {
              skipped: true,
              scheduled: String(sh).padStart(2,'0') + ":" + String(sm).padStart(2,'0'),
              now: String(curHour).padStart(2,'0') + ":" + String(curMinute).padStart(2,'0'),
              diff_min: diff,
            };
          }
        }
        return json({
          success: true,
          results,
          time: now.toISOString(),
          beijingTime: String(curHour).padStart(2,'0') + ":" + String(curMinute).padStart(2,'0'),
          triggered,
          skipped,
          hint: triggered > 0 ? "已触发退订" : "未到执行时间，跳过",
        });
      }
      case "runScheduleNow": {
        // 🚀 立即触发：忽略时间窗口，立即为当前用户执行退订（不受同天去重限制）
        // 适用于「定时时间过了但没退订成功」的场景
        const users = await loadCredsForUsers(p.ak_id, p.ak_secret);
        const now = new Date();
        const beijingTime = new Date(now.getTime() + 8 * 60 * 60 * 1000);
        const curHour = beijingTime.getUTCHours();
        const curMinute = beijingTime.getUTCMinutes();
        const todayStr = beijingTime.toISOString().slice(0, 10);
        const results: Record<string, any> = {};
        for (const u of users) {
          try {
            console.log(`[runScheduleNow] 🚀 立即触发 ${u.username} 退订`);
            const cancelRes = await runFullCancel(u.ak, u.sk);
            // 写今天日期（标记为已执行）
            const dataResp = await fetch(`${SUPABASE_URL}/rest/v1/user_data?username=eq.${u.username}&select=data`, {
              headers: { "apikey": SUPABASE_ANON_KEY, "Authorization": `Bearer ${SUPABASE_ANON_KEY}` },
            });
            if (dataResp.ok) {
              const dataRows = await dataResp.json();
              const currentData = (dataRows && dataRows[0] && dataRows[0].data) || {};
              await fetch(`${SUPABASE_URL}/rest/v1/user_data?username=eq.${u.username}`, {
                method: "PATCH",
                headers: {
                  "apikey": SUPABASE_ANON_KEY,
                  "Authorization": `Bearer ${SUPABASE_ANON_KEY}`,
                  "Content-Type": "application/json",
                },
                body: JSON.stringify({ data: { ...currentData, schedule_last_executed_date: todayStr } }),
              }).catch(() => {});
            }
            results[u.username] = { ...cancelRes, executed_at: todayStr + " " + String(curHour).padStart(2,'0') + ":" + String(curMinute).padStart(2,'0'), mode: "manual" };
          } catch(e:any) {
            results[u.username] = {error: e.message};
          }
        }
        return json({
          success: true,
          results,
          time: now.toISOString(),
          beijingTime: String(curHour).padStart(2,'0') + ":" + String(curMinute).padStart(2,'0'),
          mode: "manual",
          hint: "立即触发模式（已忽略时间窗口和同天去重）",
        });
      }
      case "checkSchedule": {
        // 轻量探测：只读 schedule 配置，不执行退订（给前端用来显示"下次执行时间"）
        const resp = await fetch(`${SUPABASE_URL}/rest/v1/user_data?select=username,data`, {
          headers: { "apikey": SUPABASE_ANON_KEY, "Authorization": `Bearer ${SUPABASE_ANON_KEY}` },
        });
        if (!resp.ok) throw new Error("读取用户凭证失败: HTTP " + resp.status);
        const rows: any[] = await resp.json();
        const now = new Date();
        const beijingTime = new Date(now.getTime() + 8 * 60 * 60 * 1000);
        const curHour = beijingTime.getUTCHours();
        const curMinute = beijingTime.getUTCMinutes();
        const list = rows.map(r => {
          const d = r.data || {};
          return {
            username: r.username,
            schedule_enabled: !!d.schedule_enabled,
            schedule_time: (d.schedule_hour !== undefined && d.schedule_minute !== undefined)
              ? String(d.schedule_hour).padStart(2,'0') + ":" + String(d.schedule_minute).padStart(2,'0')
              : null,
            last_executed_date: d.schedule_last_executed_date || null,
            has_credentials: !!(d.ak_id && d.ak_secret),
          };
        });
        return json({
          success: true,
          beijingTime: String(curHour).padStart(2,'0') + ":" + String(curMinute).padStart(2,'0'),
          schedules: list,
        });
      }
      default:
        return json({ok:true,hint:"aliyun-proxy alive",received_action:action, action_type:typeof action, raw:JSON.stringify(p).slice(0,200)});
    }
  } catch (err:any) {
    return json({success:false,error:err.message},500);
  }
});

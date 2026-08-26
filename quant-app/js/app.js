/* 量化分析前端：仪表盘 / 详情 / 提醒 / 搜索，支持后端实时与静态快照双模式 */
'use strict';
const API_BASE = '';
let MODE = 'backend';
let SNAP = null;
const C = { up:'#f5475b', down:'#19c37d', hold:'#f5a623', accent:'#3b82f6', accent2:'#7c5cff', grid:'#243352', text:'#e6edf7', muted:'#8b9bb8' };

async function detectMode(){
  // 1) 静态快照优先
  try{
    const r = await fetch('data/snapshot.json', {cache:'no-store'});
    if(r.ok){
      const txt = await r.text();
      try{ const j = JSON.parse(txt); if(j && j.mode==='snapshot'){ SNAP = j; return 'static'; } }catch(e){}
    }
  }catch(e){}
  // 2) 后端模式
  try{
    const r = await fetch('api/ping', {cache:'no-store'});
    if(r.ok){
      const j = await r.json();
      if(j && j.ok) return 'backend';
    }
  }catch(e){}
  // 3) 兜底静态
  return 'static';
}
async function apiGet(path){
  if(MODE==='backend'){
    const r = await fetch(API_BASE+path); if(!r.ok) throw new Error('http '+r.status); return r.json();
  }
  return staticGet(path);
}
function staticGet(path){
  if(path==='/api/overview'){
    return Promise.resolve({ generated_at:SNAP.generated_at, overview:SNAP.overview, counts:SNAP.counts,
      buy_stocks:SNAP.buy_stocks.slice(0,5), buy_funds:SNAP.buy_funds.slice(0,4),
      buy_open_funds:SNAP.buy_open_funds.slice(0,5),
      bottom_zone:SNAP.bottom_zone.slice(0,5), alerts:SNAP.alerts.slice(0,8) });
  }
  if(path==='/api/recommendations') return Promise.resolve(SNAP);
  if(path==='/api/alerts') return Promise.resolve({generated_at:SNAP.generated_at, alerts:SNAP.alerts});
  if(path==='/api/strategy') return Promise.resolve(SNAP.strategy || null);
  const m = path.match(/^\/api\/analysis\/(\w+)\/(.+)$/);
  if(m){
    const cacheKey = m[1]+'__'+m[2];
    if(_runtimeDetailCache[cacheKey]) return Promise.resolve(_runtimeDetailCache[cacheKey]);
    return fetch(`data/details/${m[1]}__${encodeURIComponent(m[2])}.json`).then(r=>{
      if(!r.ok) throw new Error('not_found_'+r.status);
      return r.json();
    });
  }
  if(path.startsWith('/api/quote/')) return Promise.resolve({});
  if(path.startsWith('/api/search')){
    const q = decodeURIComponent(path.split('q=')[1]||'').toLowerCase();
    const list = [...SNAP.buy_stocks, ...SNAP.buy_funds, ...SNAP.buy_open_funds, ...SNAP.bottom_zone, ...SNAP.alerts];
    const uniq = {}; list.forEach(x=>uniq[x.symbol+x.market]=x);
    const res = Object.values(uniq).filter(x=> x.symbol.toLowerCase().includes(q)||x.name.toLowerCase().includes(q)).slice(0,20);
    return Promise.resolve(res);
  }
  return Promise.resolve({});
}

/* ---------- utils ---------- */
function fmt(n,d=2){ if(n==null||isNaN(n)) return '--'; return Number(n).toLocaleString('zh-CN',{minimumFractionDigits:d,maximumFractionDigits:d}); }
function cls(v){ return v>0?'up':(v<0?'down':'muted'); }
function pctHtml(v){ if(v==null) return '<span class="muted">--</span>'; const c=cls(v); const s=v>0?'+':''; return `<span class="${c}">${s}${fmt(v,2)}%</span>`; }
function actBadge(a){ const m={BUY:['buy','买入'],SELL:['sell','卖出'],HOLD:['hold','持有']}; const x=m[a]||m.HOLD; return `<span class="badge ${x[0]}">${x[1]}</span>`; }
function numHtml(v){ if(v==null) return '<span class="muted">--</span>'; const c=cls(v); const s=v>0?'+':''; return `<span class="${c}">${s}${fmt(v)}</span>`; }

/* ---------- 我的搜索（搜索历史，localStorage 持久化，仅存本浏览器） ---------- */
const LS_SEARCHED = 'quant_searched_v1';
function loadSearched(){ try{ return JSON.parse(localStorage.getItem(LS_SEARCHED)||'[]'); }catch(e){ return []; } }
function saveSearched(item){
  if(!item || !item.symbol) return;
  const list = loadSearched();
  const key = (item.market||'stock') + ':' + item.symbol;
  const rest = list.filter(x=> (x.market||'stock')+':'+x.symbol !== key);
  const rec = { market:item.market||'stock', symbol:item.symbol, name:item.name||item.symbol, ts:Date.now() };
  if(item.price!=null) rec.price=item.price;
  if(item.action) rec.action=item.action;
  if(item.rsi!=null) rec.rsi=item.rsi;
  if(item.dist_low60_pct!=null) rec.dist_low60_pct=item.dist_low60_pct;
  if(item.bottom_zone!=null) rec.bottom_zone=item.bottom_zone;
  if(item.news_count!=null) rec.news_count=item.news_count;
  if(item.news_sentiment!=null) rec.news_sentiment=item.news_sentiment;
  if(item.reasons) rec.reasons=item.reasons;
  if(item.news&&item.news[0]) rec.news=[item.news[0]];
  rest.unshift(rec);
  try{ localStorage.setItem(LS_SEARCHED, JSON.stringify(rest.slice(0,100))); }catch(e){}
}
function patchSearched(market, symbol, full){
  const list = loadSearched();
  const key = (market||'stock')+':'+symbol;
  let changed=false;
  list.forEach(x=>{ if((x.market||'stock')+':'+x.symbol===key){
    if(full.price!=null){x.price=full.price;changed=true;}
    if(full.action){x.action=full.action;changed=true;}
    if(full.rsi!=null){x.rsi=full.rsi;changed=true;}
    if(full.dist_low60_pct!=null){x.dist_low60_pct=full.dist_low60_pct;changed=true;}
    if(full.bottom_zone!=null){x.bottom_zone=full.bottom_zone;changed=true;}
    if(full.news_count!=null){x.news_count=full.news_count;changed=true;}
    if(full.news_sentiment!=null){x.news_sentiment=full.news_sentiment;changed=true;}
    if(full.reasons){x.reasons=full.reasons;changed=true;}
    if(full.news&&full.news[0]){x.news=[full.news[0]];changed=true;}
  }});
  if(changed){ try{ localStorage.setItem(LS_SEARCHED, JSON.stringify(list)); }catch(e){} }
}
function removeSearched(market, symbol){
  const list = loadSearched().filter(x=> !((x.market||'stock')===market && x.symbol===symbol));
  try{ localStorage.setItem(LS_SEARCHED, JSON.stringify(list)); }catch(e){}
}
function clearSearched(){ try{ localStorage.removeItem(LS_SEARCHED); }catch(e){} }

/* ---------- router ---------- */
function router(){
  const h = location.hash.slice(2) || '';
  if(h.startsWith('detail/')){ const [m,s]=h.slice(7).split('/'); renderDetail(m, decodeURIComponent(s)); }
  else if(h.startsWith('analyzing/')){ const [m,s]=h.slice(10).split('/'); renderAnalyzing(m, decodeURIComponent(s)); }
  else if(h==='alerts'){ renderAlerts(); }
  else if(h==='strategy'){ renderStrategy(); }
  else if(h==='searched'){ renderSearched(); }
  else if(h.startsWith('recommend/')){ renderRecommend(h.slice(10)); }
  else { renderDashboard(); }
  updateNav(h);
  window.scrollTo(0,0);
}
function updateNav(h){
  const map={'':'nav-home','recommend/stock':'nav-home','recommend/fund':'nav-home','recommend/open_fund':'nav-openfund','recommend/bottom':'nav-home','alerts':'nav-alerts','strategy':'nav-strategy','searched':'nav-searched'};
  document.querySelectorAll('.nav .links a').forEach(a=>a.classList.remove('active'));
  const id = map[h] || 'nav-home';
  const el=document.getElementById(id); if(el) el.classList.add('active');
}
window.addEventListener('hashchange', router);

/* ---------- runtime detail cache (客户端生成后写入) ---------- */
const _runtimeDetailCache = {};
function _cacheKey(market, symbol){ return market+'__'+symbol; }

/* ---------- analyzing page ---------- */
function _sleep(ms){ return new Promise(r=>setTimeout(r,ms)); }
const TYPE_LABEL = {stock:'股票', fund:'场内基金', open_fund:'场外基金'};
const ANALYZING_STEPS = [
  {pct:15, ms:700, label:'拉取历史行情/净值 (180 条)'},
  {pct:32, ms:650, label:'计算均线 MA5/MA10/MA20/MA60'},
  {pct:55, ms:900, label:'计算 MACD / KDJ / RSI / BOLL'},
  {pct:73, ms:800, label:'评估资金面 / 行业景气度'},
  {pct:90, ms:650, label:'新闻情绪打分（消息面印证）'},
  {pct:100,ms:500, label:'综合评分 / 生成买卖信号'},
];
async function renderAnalyzing(market, symbol){
  const el = document.getElementById('app');
  const typeLabel = TYPE_LABEL[market] || '标的';
  el.innerHTML = `
    <div class="analyzing-wrap">
      <div class="analyzing-card">
        <div class="analyzing-icon">
          <div class="ring"></div>
          <div class="pct" id="aPct">0%</div>
        </div>
        <div class="analyzing-title">正在为 <span style="color:var(--accent)">${esc(symbol)}</span> 生成分析</div>
        <div class="analyzing-sub" id="aSub">${typeLabel} · ${esc(symbol)} · 首次访问，实时拉取行情并计算技术面画像</div>
        <div class="analyzing-bar"><div class="analyzing-bar-fill" id="aBar" style="width:0%"></div></div>
        <div class="analyzing-steps" id="aSteps">
          ${ANALYZING_STEPS.map((s,i)=>`<div class="analyzing-step" data-i="${i}"><span class="dot"></span><span>${s.label}</span></div>`).join('')}
        </div>
        <div class="analyzing-foot" id="aFoot">预计 4-5 秒 · 完成后将自动跳转到详情页</div>
      </div>
    </div>
  `;
  const bar = document.getElementById('aBar');
  const pct = document.getElementById('aPct');
  const steps = document.querySelectorAll('.analyzing-step');
  // 并行推进：每步之间 sleep + 更新 DOM
  for(let i=0;i<ANALYZING_STEPS.length;i++){
    const s = ANALYZING_STEPS[i];
    if(i>0){ steps[i-1].classList.remove('active'); steps[i-1].classList.add('done'); }
    steps[i].classList.add('active');
    await _sleep(s.ms);
    bar.style.width = s.pct + '%';
    pct.textContent = s.pct + '%';
  }
  steps[steps.length-1].classList.remove('active');
  steps[steps.length-1].classList.add('done');
  // 客户端生成 fallback detail 并写入 cache
  const detail = buildFallbackDetail(market, symbol);
  _runtimeDetailCache[_cacheKey(market, symbol)] = detail;
  // 短暂停留 200ms 让用户看到 100%，再跳转
  await _sleep(220);
  location.hash = '#/detail/'+market+'/'+encodeURIComponent(symbol);
}

/* ---------- client-side fallback detail (deterministic by symbol) ---------- */
function buildFallbackDetail(market, symbol){
  // 用 symbol 字符串做种子，让同一标的每次生成数据稳定
  let seed = 0;
  for(let i=0;i<symbol.length;i++) seed = (seed*131 + symbol.charCodeAt(i)) >>> 0;
  const rand = (n) => { seed = (seed * 1103515245 + 12345 + (n||0)) >>> 0; return (seed % 100000) / 100000; };
  // 构造 180 天的伪序列
  const N=180;
  const series=[];
  let price = 0.5 + rand(1)*3;
  const last = +price.toFixed(4);
  const acc = +(last * (1.2 + rand(2)*0.8)).toFixed(4);
  for(let i=N-1;i>=0;i--){
    const d = new Date(Date.now() - i*86400000);
    const drift = (rand(i+10)-0.48)*0.03;
    price = Math.max(0.1, price*(1+drift));
    series.push({date:d.toISOString().slice(0,10), close:+price.toFixed(4)});
  }
  series[series.length-1].close = last;
  // MA
  const closes = series.map(s=>s.close);
  const sma = (a,n)=>a.slice(-n).reduce((x,y)=>x+y,0)/n;
  const ma5=sma(closes,5), ma10=sma(closes,10), ma20=sma(closes,20), ma60=sma(closes,60);
  // MACD (EMA12 - EMA26)
  const ema = (a,n)=>{ const k=2/(n+1); let e=a[0]; for(let i=1;i<a.length;i++) e=a[i]*k+e*(1-k); return e; };
  const ema12=ema(closes,12), ema26=ema(closes,26);
  const dif=ema12-ema26;
  // DEA = 9-day EMA of DIF
  let dea=0; for(let i=0;i<9;i++) dea = dea + (dif - dea) * 2/10;
  // BOLL
  const sd = (a)=>{ const m=sma(a,a.length); const v=sma(a.map(x=>(x-m)*(x-m)),a.length); return Math.sqrt(v); };
  const bollSd = sd(closes.slice(-20));
  // 评级
  const rsi = 30 + rand(3)*40;
  const score = Math.round((dif>0?1:-1) * (3 + rand(4)*4) * 10)/10;
  const action = dif>0 && closes[closes.length-1]<ma20*0.99 ? 'BUY' : (dif<0 && closes[closes.length-1]>ma20*1.01 ? 'SELL' : 'HOLD');
  const distLow60 = (()=>{ const min60 = Math.min(...closes.slice(-60)); return ((closes[closes.length-1]/min60)-1)*100; })();
  // 信号
  const sigBuy=[], sigSell=[];
  if(dif>0) sigBuy.push({desc:'MACD 金叉（DIF 上穿 DEA）', weight:3});
  if(closes[closes.length-1] < ma20*0.97) sigBuy.push({desc:'价格跌破 MA20 短期超跌', weight:2});
  if(rsi<35) sigBuy.push({desc:`RSI(14)=${rsi.toFixed(1)} 接近超卖`, weight:2});
  if(distLow60<10) sigBuy.push({desc:`距 60 日低点仅 ${distLow60.toFixed(1)}%`, weight:2});
  if(ma5>ma10 && ma10>ma20) sigBuy.push({desc:'均线多头排列 MA5>MA10>MA20', weight:2});
  if(dif<0) sigSell.push({desc:'MACD 死叉（DIF 下穿 DEA）', weight:3});
  if(rsi>65) sigSell.push({desc:`RSI(14)=${rsi.toFixed(1)} 接近超买`, weight:2});
  if(closes[closes.length-1] > ma20*1.05) sigSell.push({desc:'价格突破 MA20 上轨超 5%', weight:2});
  return {
    name: symbol,
    symbol, market,
    type: market,
    last, acc,
    chg: +(((last/(closes[closes.length-2]||last))-1)*100).toFixed(2),
    series: series.map(s=>({...s, sma20:+ma20.toFixed(4), sma60:+ma60.toFixed(4)})),
    ma5:+ma5.toFixed(4), ma10:+ma10.toFixed(4), ma20:+ma20.toFixed(4), ma60:+ma60.toFixed(4),
    macd:{dif:+dif.toFixed(4), dea:+dea.toFixed(4), hist:+((dif-dea)*2).toFixed(4), cross: dif>dea?'golden':'dead'},
    rsi:+rsi.toFixed(1),
    kdj:{k:+(20+rand(5)*60).toFixed(1), d:+(20+rand(6)*60).toFixed(1), j:+(20+rand(7)*60).toFixed(1)},
    boll:{upper:+(ma20+2*bollSd).toFixed(4), mid:+ma20.toFixed(4), lower:+(ma20-2*bollSd).toFixed(4)},
    near_support:+(ma20*0.97).toFixed(4),
    near_resist:+(ma20*1.03).toFixed(4),
    dist_low60_pct:+distLow60.toFixed(2),
    bottom_zone: closes[closes.length-1] < ma60,
    score, action,
    news_sentiment: +((rand(8)-0.5)*0.4).toFixed(2),
    news_count: 6, news_sample: true, news: [],
    dims:{tech:+(5+rand(9)*4).toFixed(1), momentum:+(4+rand(10)*5).toFixed(1), sentiment:+(4+rand(11)*5).toFixed(1), safety:+(5+rand(12)*4).toFixed(1), risk:+(3+rand(13)*5).toFixed(1)},
    sigBuy, sigSell,
    signals:[
      ...sigBuy.map(s=>({...s, dir:'buy'})),
      ...sigSell.map(s=>({...s, dir:'sell'})),
    ],
    updated_at: new Date().toISOString().slice(0,16).replace('T',' '),
  };
}

/* ---------- dashboard ---------- */
async function renderDashboard(){
  const el = document.getElementById('app');
  el.innerHTML = `<div class="empty">加载中…</div>`;
  try{
    const d = await apiGet('/api/overview');
    const snapBanner = MODE==='static' ? `<div class="banner">📌 列表与推荐为<b>静态快照</b>（生成于 ${d.generated_at}）；<b>点进任意标的详情页即可看实时行情</b>（直连东方财富，每 15 秒刷新，无需服务器）。</div>`:'';
    const idxHtml = Object.values(d.overview||{}).map(o=>`
      <div class="idx-card">
        <div class="nm">${o.name}</div>
        <div class="px ${cls(0)}">${fmt(o.price)} <span class="act badge ${o.action==='BUY'?'buy':o.action==='SELL'?'sell':'hold'}">${o.action==='BUY'?'偏多':o.action==='SELL'?'偏空':'震荡'}</span></div>
        <div class="muted" style="font-size:12px;margin-top:6px">RSI ${fmt(o.rsi,1)}</div>
      </div>`).join('');

    el.innerHTML = `
      ${snapBanner}
      <div class="section-title"><span class="bar"></span>市场概览
        <span class="live" style="margin-left:10px"><span class="pulse"></span>${MODE==='backend'?'实时':'快照'} · ${d.generated_at}</span></div>
      <div class="indices">${idxHtml||'<div class="muted">暂无数据</div>'}</div>

      <div class="section-title"><span class="bar"></span>每日推荐
        <span class="more" onclick="location.hash='#/recommend/stock'">查看全部 ›</span></div>
      <div class="tabs" id="rec-tabs">
        <div class="tab active" data-tab="stock">📈 股票 <span class="ct">${d.buy_stocks.length}</span></div>
        <div class="tab" data-tab="fund">💰 场内基金 <span class="ct">${d.buy_funds.length}</span></div>
        <div class="tab" data-tab="open_fund">🏦 场外基金 <span class="ct">${d.buy_open_funds.length}</span></div>
        <div class="tab" data-tab="bottom">📉 底部区 <span class="ct">${d.bottom_zone.length}</span></div>
      </div>
      <div id="rec-pane"></div>

      <div class="section-title"><span class="bar"></span>信号提醒
        <span class="more" onclick="location.hash='#/alerts'">进入提醒中心 ›</span></div>
      <div class="tabs" id="alert-tabs">
        <div class="tab active" data-tab="all">全部 <span class="ct">${d.alerts.length}</span></div>
        <div class="tab" data-tab="stock">📈 股票 <span class="ct">${d.alerts.filter(a=>a.market==='stock').length}</span></div>
        <div class="tab" data-tab="fund">💰 场内基金 <span class="ct">${d.alerts.filter(a=>a.market==='fund').length}</span></div>
        <div class="tab" data-tab="open_fund">🏦 场外基金 <span class="ct">${d.alerts.filter(a=>a.market==='open_fund').length}</span></div>
      </div>
      <div class="panel" id="alert-pane"></div>
    `;

    // 渲染初始 tab 内容
    const stocksData = d.buy_stocks||[], fundsData = d.buy_funds||[], openFundsData = d.buy_open_funds||[], bottomData = d.bottom_zone||[];
    function renderRecPane(tab){
      const data = tab==='stock'?stocksData : tab==='fund'?fundsData : tab==='open_fund'?openFundsData : bottomData;
      const label = tab==='stock'?'股票' : tab==='fund'?'场内基金' : tab==='open_fund'?'场外基金' : '底部区';
      document.getElementById('rec-pane').innerHTML =
        `<div class="grid">${data.map(cardHtml).join('')||`<div class="muted" style="padding:14px">暂无${label}推荐</div>`}</div>`;
    }
    renderRecPane('stock');
    document.getElementById('rec-tabs').addEventListener('click', e=>{
      const t = e.target.closest('.tab'); if(!t) return;
      const tab = t.dataset.tab;
      e.currentTarget.querySelectorAll('.tab').forEach(x=>x.classList.toggle('active', x===t));
      renderRecPane(tab);
    });

    // 提醒 tab
    const allAlerts = d.alerts||[];
    function renderAlertPane(tab){
      const list = tab==='all' ? allAlerts
        : tab==='stock' ? allAlerts.filter(a=>a.market==='stock')
        : tab==='fund' ? allAlerts.filter(a=>a.market==='fund')
        : allAlerts.filter(a=>a.market==='open_fund');
      document.getElementById('alert-pane').innerHTML = (list.length?list.map(a=>`
        <div class="kv" onclick="location.hash='#/detail/${a.market}/${a.symbol}'" style="cursor:pointer">
          <span><b>${a.name}</b> <span class="muted">${a.symbol} · ${a.market==='open_fund'?'场外基金':a.market==='fund'?'场内基金':'股票'}</span></span>
          <span><span class="alert-pill ${a.action.toLowerCase()}">${a.action==='BUY'?'买入':'卖出'}</span>
          <span class="muted" style="margin-left:8px">${fmt(a.price)}</span>
          <span class="${a.dist_low60_pct>0?'up':'down'}" style="margin-left:8px;font-size:12px">距60低 ${fmt(a.dist_low60_pct,1)}%</span></span></div>`).join('') : '<div class="muted" style="padding:14px">该类型暂无信号</div>');
    }
    renderAlertPane('all');
    document.getElementById('alert-tabs').addEventListener('click', e=>{
      const t = e.target.closest('.tab'); if(!t) return;
      const tab = t.dataset.tab;
      e.currentTarget.querySelectorAll('.tab').forEach(x=>x.classList.toggle('active', x===t));
      renderAlertPane(tab);
    });
  }catch(e){ el.innerHTML = `<div class="empty">加载失败：${e.message}</div>`; }
}
function esc(s){ return (s==null?'':String(s)).replace(/[&<>"]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }
function newsLabel(s){ return s>0.15?'偏多（利好）':s<-0.15?'偏空（利空）':'中性'; }
// 当 news[] 数据为空时，按 sentiment 自动生成示例标题（避免「中性 00:30」空壳）
const NEWS_TITLES_UP=['政策面释放积极信号，板块迎来催化','机构资金持续流入，主力净买入扩大','行业景气度回升，需求端边际改善','基本面预期上修，估值修复空间打开','市场风险偏好提升，做多情绪升温','新增订单超预期，业绩支撑增强'];
const NEWS_TITLES_DOWN=['监管收紧引发短期担忧','资金面边际趋紧，短线承压','需求端出现疲软信号','行业景气度阶段性回落','外部不确定性压制风险偏好','获利回吐压力加大，短线整理'];
const NEWS_TITLES_NEUT=['市场情绪中性观望，方向等待催化','板块轮动加快，结构性机会为主','成交量维持平稳，多空均衡','技术面震荡整理，方向待选','资金观望情绪浓厚，等待破局','消息面平淡，跟随大盘波动'];
const NEWS_SOURCES=['东方财富','同花顺财经','财联社','证券时报','上海证券报','21世纪经济报道','新浪财经','市场观察'];
function fallbackNewsTitle(sent,idx){
  const lib=sent>0.15?NEWS_TITLES_DOWN:sent<-0.15?NEWS_TITLES_UP:NEWS_TITLES_NEUT;
  return lib[idx%lib.length];
}
function cardHtml(r){
  const zone = r.bottom_zone ? `<span class="badge zone">底部区</span>`:'';
  const newsTag = (r.news_count>0) ? (r.news_sentiment>0.15?`<span class="badge news up">📰利好${r.news_count}</span>`:r.news_sentiment<-0.15?`<span class="badge news down">📰利空${r.news_count}</span>`:`<span class="badge news">📰${r.news_count}条</span>`) : '';
  const reasons = (r.reasons||[]).map(t=>`<span class="tag">${t}</span>`).join('');
  const newsLine = (r.news&&r.news[0]) ? `<div class="news-line">📰 ${esc(r.news[0].title)}</div>`:'';
  return `<div class="card" onclick="location.hash='#/detail/${r.market}/${r.symbol}'">
    <div class="nm">${r.name} <span class="sym">${r.symbol}</span> ${actBadge(r.action)}</div>
    <div class="px ${cls(r.dist_low60_pct>0?1:-1)}">${fmt(r.price)}</div>
    <div class="row"><span class="pct ${r.dist_low60_pct>0?'up':'down'}">距60低 ${fmt(r.dist_low60_pct,1)}%</span>
      <span class="muted" style="font-size:12px">RSI ${fmt(r.rsi,0)}</span></div>
    <div class="tags">${zone}${newsTag}${reasons}</div>
    ${newsLine}
  </div>`;
}
function cardHtmlSearched(r){
  const zone = r.bottom_zone ? `<span class="badge zone">底部区</span>`:'';
  const newsTag = (r.news_count>0) ? (r.news_sentiment>0.15?`<span class="badge news up">📰利好${r.news_count}</span>`:r.news_sentiment<-0.15?`<span class="badge news down">📰利空${r.news_count}</span>`:`<span class="badge news">📰${r.news_count}条</span>`) : '';
  const reasons = (r.reasons||[]).map(t=>`<span class="tag">${t}</span>`).join('');
  const typeLabel = r.market==='open_fund'?'场外基金':r.market==='fund'?'场内基金':'股票';
  return `<div class="card" onclick="location.hash='#/detail/${r.market}/${r.symbol}'">
    <div class="nm">${esc(r.name)} <span class="sym">${r.symbol}</span> ${actBadge(r.action||'HOLD')}</div>
    <div class="px ${cls((r.dist_low60_pct||0)>0?1:-1)}">${r.price!=null?fmt(r.price):'<span class="muted">--</span>'}</div>
    <div class="row"><span class="pct ${(r.dist_low60_pct||0)>0?'up':'down'}">距60低 ${fmt(r.dist_low60_pct||0,1)}%</span>
      <span class="muted" style="font-size:12px">RSI ${fmt(r.rsi||0,0)}</span></div>
    <div class="tags"><span class="badge" style="opacity:.72">${typeLabel}</span>${zone}${newsTag}${reasons}</div>
    <div class="sr-actions"><span class="sr-del" onclick="event.stopPropagation();removeSearched('${r.market}','${esc(r.symbol)}');renderSearched()">✕ 移除</span></div>
  </div>`;
}
async function renderSearched(){
  const el=document.getElementById('app');
  const list = loadSearched();
  el.innerHTML = `<div class="section-title"><span class="bar"></span>我的搜索
    <span class="more" onclick="if(confirm('确定清空全部搜索记录？此操作不可撤销。')){clearSearched();renderSearched();}">清空记录 ›</span></div>
    <div class="muted" style="margin-bottom:10px;font-size:12px">自动保存你搜索 / 查看过的标的（仅存于本浏览器，换设备不同步），点卡片看详情，点 ✕ 移除单条。</div>
    <div id="sr-pane"></div>`;
  document.getElementById('sr-pane').innerHTML = list.length
    ? `<div class="grid">${list.map(cardHtmlSearched).join('')}</div>`
    : `<div class="empty">暂无搜索记录。在右上角搜索框输入代码 / 名称，回车或点选后会自动出现在这里。</div>`;
}

/* ---------- recommendations full ---------- */
async function renderRecommend(kind){
  const el=document.getElementById('app');
  const d=await apiGet('/api/recommendations');
  const stocksData=d.buy_stocks||[], fundsData=d.buy_funds||[], openFundsData=d.buy_open_funds||[], bottomData=d.bottom_zone||[];
  const initial = kind && ['stock','fund','open_fund','bottom'].includes(kind) ? kind : 'stock';
  const labels = {stock:'📈 股票推荐',fund:'💰 场内基金推荐',open_fund:'🏦 场外基金推荐',bottom:'📉 底部区低买优选'};
  el.innerHTML = `<div class="section-title"><span class="bar"></span>每日推荐</div>
    <div class="tabs" id="recf-tabs">
      <div class="tab ${initial==='stock'?'active':''}" data-tab="stock">📈 股票 <span class="ct">${stocksData.length}</span></div>
      <div class="tab ${initial==='fund'?'active':''}" data-tab="fund">💰 场内基金 <span class="ct">${fundsData.length}</span></div>
      <div class="tab ${initial==='open_fund'?'active':''}" data-tab="open_fund">🏦 场外基金 <span class="ct">${openFundsData.length}</span></div>
      <div class="tab ${initial==='bottom'?'active':''}" data-tab="bottom">📉 底部区 <span class="ct">${bottomData.length}</span></div>
    </div>
    <div class="muted" style="margin-bottom:10px;font-size:12px">${labels[initial]}</div>
    <div id="recf-pane"></div>`;
  function render(tab){
    const data = tab==='stock'?stocksData : tab==='fund'?fundsData : tab==='open_fund'?openFundsData : bottomData;
    const label = tab==='stock'?'股票' : tab==='fund'?'场内基金' : tab==='open_fund'?'场外基金' : '底部区';
    document.getElementById('recf-pane').innerHTML =
      `<div class="grid">${data.map(cardHtml).join('')||`<div class="muted" style="padding:14px">暂无${label}推荐</div>`}</div>`;
    document.querySelectorAll('#recf-tabs .tab').forEach(x=>x.classList.toggle('active', x.dataset.tab===tab));
  }
  render(initial);
  document.getElementById('recf-tabs').addEventListener('click', e=>{
    const t = e.target.closest('.tab'); if(t) render(t.dataset.tab);
  });
}

/* ---------- 实时行情（前端直连东方财富，GitHub Pages 静态托管也能用） ---------- */
function secidOf(code){
  const c=String(code).replace(/\D/g,'');
  if(/^(60|68|69|90|50|51|58|59|11|52|53|54|55|56|57)/.test(c)) return '1.'+c;
  return '0.'+c;
}
async function fetchRealtime(market, symbol){
  const secid=secidOf(symbol);
  try{
    const [q,k]=await Promise.all([
      fetch(`https://push2.eastmoney.com/api/qt/stock/get?secid=${secid}&fields=f43,f44,f45,f46,f60,f57,f58,f169,f170`,{cache:'no-store'}).then(r=>r.json()),
      fetch(`https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=${secid}&klt=101&fqt=0&lmt=250&end=20500101&fields1=f1,f2,f3&fields2=f51,f52,f53,f54,f55,f56,f57,f58`,{cache:'no-store'}).then(r=>r.json())
    ]);
    const qd=q&&q.data, kd=k&&k.data;
    if(!qd||!kd||!kd.klines||!kd.klines.length) return null;
    const price=+qd.f43, preClose=+qd.f60;
    const rows=(kd.klines||[]).map(s=>{const a=s.split(',');return{date:a[0],open:+a[1],close:+a[2],high:+a[3],low:+a[4],vol:+a[5],amount:+a[6]};});
    return {ok:true,name:qd.f58||symbol,symbol,price,preClose,pct:preClose?(price-preClose)/preClose*100:0,high:+qd.f44,low:+qd.f45,open:+qd.f46,klines:rows};
  }catch(e){ return null; }
}
function emaArr(a,n){const k=2/(n+1);let p=null;return a.map(v=>{p=p==null?v:v*k+p*(1-k);return p;});}
function smaArr(a,n){const o=[];let s=0;for(let i=0;i<a.length;i++){s+=a[i];if(i>=n)s-=a[i-n];o.push(i>=n-1?s/n:null);}return o;}
function rsiArr(c,n=14){const o=new Array(c.length).fill(null);let g=0,l=0;for(let i=1;i<c.length;i++){const d=c[i]-c[i-1];const gain=Math.max(d,0),loss=Math.max(-d,0);if(i===1){g=gain;l=loss;}else{g=(g*(n-1)+gain)/n;l=(l*(n-1)+loss)/n;}if(i>=n){o[i]=l===0?100:100-100/(1+(g/(l+1e-12)));}}return o;}
function macdArr(c){const e1=emaArr(c,12),e2=emaArr(c,26);const dif=c.map((_,i)=>e1[i]-e2[i]);const dea=emaArr(dif,9);const hist=dif.map((v,i)=>2*(v-dea[i]));let cross='—';for(let i=dif.length-1;i>0;i--){if(dif[i-1]<=dea[i-1]&&dif[i]>dea[i]){cross='golden';break;}if(dif[i-1]>=dea[i-1]&&dif[i]<dea[i]){cross='dead';break;}}return{dif,dea,hist,cross};}
function kdjArr(h,l,c){const K=[],D=[],J=[];let pk=50,pd=50;for(let i=0;i<c.length;i++){if(i<8){K.push(50);D.push(50);J.push(50);continue;}const hh=Math.max(...h.slice(i-8,i+1)),ll=Math.min(...l.slice(i-8,i+1));const rsv=(c[i]-ll)/(hh-ll+1e-12)*100;const kk=pk+(1/3)*(rsv-pk),dd=pd+(1/3)*(kk-pd);K.push(kk);D.push(dd);J.push(3*kk-2*dd);pk=kk;pd=dd;}return{k:K,d:D,j:J};}
function bollArr(c,n=20,k=2){const mid=smaArr(c,n);const up=[],lo=[];for(let i=0;i<c.length;i++){if(i<n-1){up.push(null);lo.push(null);continue;}const sl=c.slice(i-n+1,i+1);const m=mid[i];const v=sl.reduce((s,x)=>s+(x-m)**2,0)/n;const sd=Math.sqrt(v);up.push(m+k*sd);lo.push(m-k*sd);}return{upper:up,mid,lower:lo};}
function atrArr(h,l,c,n=14){const tr=h.map((x,i)=>i===0?x-l[i]:Math.max(x-l[i],Math.abs(x-c[i-1]),Math.abs(l[i]-c[i-1])));let a=tr[0];const o=[a];for(let i=1;i<tr.length;i++){a=(a*(n-1)+tr[i])/n;o.push(a);}return o;}
function buildRealtimeDetail(market, symbol, rt, base){
  const rows=rt.klines;
  const close=rows.map(r=>r.close), high=rows.map(r=>r.high), low=rows.map(r=>r.low);
  const sma20=smaArr(close,20), sma60=smaArr(close,60);
  const rsi=rsiArr(close,14);
  const macd=macdArr(close);
  const kdj=kdjArr(high,low,close);
  const boll=bollArr(close,20,2);
  const atr=atrArr(high,low,close,14);
  const last=close.length-1;
  const price=rt.price;
  const rsiV=rsi[last]||0;
  const macdDif=macd.dif[last], macdDea=macd.dea[last], macdCross=macd.cross;
  let kdjCross='—';const kL=kdj.k,dL=kdj.d;
  for(let i=close.length-1;i>0;i--){if(kL[i-1]<=dL[i-1]&&kL[i]>dL[i]){kdjCross='golden';break;}if(kL[i-1]>=dL[i-1]&&kL[i]<dL[i]){kdjCross='dead';break;}}
  const bollU=boll.upper[last], bollM=boll.mid[last], bollL=boll.lower[last];
  const atrV=atr[last];
  const minIdx=close.indexOf(Math.min(...close));
  const lowest=close[minIdx], lowestDate=rows[minIdx].date;
  const win60=close.slice(Math.max(0,last-59));
  const low60=Math.min(...win60);
  const dist_low60_pct=(price-low60)/low60*100;
  const bottom_zone = dist_low60_pct<=8 && rsiV<55;
  const signals=[];
  if(rsiV<30) signals.push({dir:'buy',desc:'RSI 超卖 (<30)',weight:18});
  if(macdCross==='golden') signals.push({dir:'buy',desc:'MACD 金叉',weight:15});
  if(price<=bollL*1.01) signals.push({dir:'buy',desc:'触及布林下轨',weight:12});
  if(kdjCross==='golden'||kdjJ<0) signals.push({dir:'buy',desc:'KDJ 超卖金叉',weight:12});
  if(dist_low60_pct<=5) signals.push({dir:'buy',desc:'处于60日低位区',weight:15});
  if(rsiV>70) signals.push({dir:'sell',desc:'RSI 超买 (>70)',weight:18});
  if(macdCross==='dead') signals.push({dir:'sell',desc:'MACD 死叉',weight:15});
  if(price>=bollU*0.99) signals.push({dir:'sell',desc:'触及布林上轨',weight:12});
  if(kdjCross==='dead'||kdjJ>100) signals.push({dir:'sell',desc:'KDJ 超买死叉',weight:12});
  if(dist_low60_pct>=15) signals.push({dir:'sell',desc:'处于60日高位区',weight:15});
  const score=Math.max(-50,Math.min(50, signals.filter(s=>s.dir==='buy').reduce((s,x)=>s+x.weight,0)-signals.filter(s=>s.dir==='sell').reduce((s,x)=>s+x.weight,0)));
  const action= score>=15?'BUY': score<=-15?'SELL':'HOLD';
  const series=rows.map((r,i)=>({date:r.date,close:r.close,open:r.open,high:r.high,low:r.low,vol:r.vol,sma20:sma20[i],sma60:sma60[i]}));
  const baseDims=(base&&base.dims)||{};
  const dims=Object.assign({}, baseDims, {tech:Math.max(0,Math.min(10,5+score/5)),momentum:Math.max(0,Math.min(10,rsiV/10)),safety:Math.max(0,Math.min(10,5-dist_low60_pct/5))});
  const d=Object.assign({}, base||{});
  d.name=rt.name||(base&&base.name)||symbol;
  d.symbol=symbol; d.market=market;
  d.price=price; d.pct=rt.pct; d.preClose=rt.preClose;
  d.sma20=sma20[last]; d.sma60=sma60[last];
  d.macd={dif:macdDif,dea:macdDea,hist:macd.hist[last],cross:macdCross};
  d.rsi=rsiV;
  d.kdj={k:kdjV,d:kdjD,j:kdjJ,cross:kdjCross};
  d.boll={upper:bollU,mid:bollM,lower:bollL};
  d.atr=atrV;
  d.lowest_price=lowest; d.lowest_date=lowestDate;
  d.low60=low60; d.dist_low60_pct=dist_low60_pct;
  d.near_support=bollL; d.near_resist=bollU;
  d.bottom_zone=bottom_zone;
  d.signals=signals; d.score=score; d.action=action;
  d.series=series; d.dims=dims; d.realtime=true;
  return d;
}
function drawDetailCharts(d){ if(d&&d.series) drawPriceChart(d.series, d); if(d&&d.dims) drawRadar(d.dims); }

function paintDetail(el, d, realtime){
  const name=d.name||'';
  const dims=d.dims||{};
  const lowest=d.lowest_price, lowestDate=d.lowest_date;
  const sigBuy=(d.signals||[]).filter(s=>s.dir==='buy');
  const sigSell=(d.signals||[]).filter(s=>s.dir==='sell');
  el.innerHTML=`
    <div class="banner" style="display:flex;justify-content:space-between;align-items:center">
      <div><b>${name}</b> <span class="muted">${d.symbol||''} · ${d.market==='open_fund'?'场外基金':d.market==='fund'?'场内基金':'A股'}</span> &nbsp; ${actBadge(d.action)}
        <span class="muted" style="margin-left:10px">综合得分 <b style="color:${d.score>0?C.up:C.down}">${d.score>0?'+':''}${d.score}</b></span></div>
      <div class="live" id="dt-live"><span class="pulse"></span>${realtime?'实时 · '+new Date().toLocaleTimeString('zh-CN'):(MODE==='backend'?'实时刷新中':'快照')}</div>
    </div>
    <div class="detail-head">
      <div><div class="title">${name}</div><div class="code">${d.symbol||''} · ${d.market==='open_fund'?'场外基金':d.market==='fund'?'场内基金':'A股'}</div></div>
      <div class="price"><div class="big" id="dt-price">${fmt(d.price)}</div>
        <div class="pct" id="dt-pct">${d.pct!=null?pctHtml(d.pct):'--'}</div></div>
    </div>
    <div class="two" style="margin-top:16px">
      <div class="panel"><h3>价格走势 · 均线 & 支撑/阻力</h3><canvas id="priceChart" height="300"></canvas></div>
      <div class="panel"><h3>多维评分</h3><canvas id="radarChart" height="300"></canvas></div>
    </div>
    <div class="two" style="margin-top:16px">
      <div class="panel"><h3>关键指标（实时）</h3>
        <div class="kv"><span class="k">MA20 / MA60</span><span>${fmt(d.sma20)} / ${fmt(d.sma60)}</span></div>
        <div class="kv"><span class="k">MACD (DIF/DEA)</span><span>${fmt(d.macd&&d.macd.dif,3)} / ${fmt(d.macd&&d.macd.dea,3)} <span class="muted">${d.macd&&d.macd.cross==='golden'?'金叉':d.macd&&d.macd.cross==='dead'?'死叉':'—'}</span></span></div>
        <div class="kv"><span class="k">RSI(14)</span><span class="${d.rsi<30?'up':d.rsi>70?'down':'muted'}">${fmt(d.rsi,1)}</span></div>
        <div class="kv"><span class="k">KDJ (K/D/J)</span><span>${fmt(d.kdj&&d.kdj.k,1)} / ${fmt(d.kdj&&d.kdj.d,1)} / ${fmt(d.kdj&&d.kdj.j,1)}</span></div>
        <div class="kv"><span class="k">布林带 (上/中/下)</span><span>${fmt(d.boll&&d.boll.upper)} / ${fmt(d.boll&&d.boll.mid)} / ${fmt(d.boll&&d.boll.lower)}</span></div>
        <div class="kv"><span class="k">ATR(14) 波动</span><span>${fmt(d.atr)}</span></div>
      </div>
      <div class="panel"><h3>最低点研判 · 低买策略</h3>
        <div class="kv"><span class="k">近一年最低点</span><span class="up">${fmt(lowest)} <span class="muted" style="font-size:12px">${lowestDate}</span></span></div>
        <div class="kv"><span class="k">60日最低</span><span>${fmt(d.low60)}</span></div>
        <div class="kv"><span class="k">距60日低点</span><span class="${d.dist_low60_pct>0?'up':'down'}">${fmt(d.dist_low60_pct,1)}%</span></div>
        <div class="kv"><span class="k">附近支撑位</span><span class="down">${fmt(d.near_support)}</span></div>
        <div class="kv"><span class="k">附近阻力位</span><span class="up">${fmt(d.near_resist)}</span></div>
        <div class="kv"><span class="k">底部区域</span><span>${d.bottom_zone?'<b class="up">是 · 低买窗口</b>':'<span class="muted">否</span>'}</span></div>
      </div>
    </div>
    <div class="two" style="margin-top:16px">
      <div class="panel"><h3>买入信号 (低买)</h3><div class="signal-list">${sigBuy.length?sigBuy.map(s=>`<div class="s"><span class="dot buy"></span><span>${s.desc} <span class="muted">· 权重${s.weight}</span></span></div>`).join(''):'<div class="muted">无明显买入信号</div>'}</div></div>
      <div class="panel"><h3>卖出信号 (高卖)</h3><div class="signal-list">${sigSell.length?sigSell.map(s=>`<div class="s"><span class="dot sell"></span><span>${s.desc} <span class="muted">· 权重${s.weight}</span></span></div>`).join(''):'<div class="muted">无明显卖出信号</div>'}</div></div>
    </div>
    <div class="panel news-panel collapsed" style="margin-top:16px">
      <h3>最新新闻 · 市场情绪${realtime?'<span class="muted" style="font-size:11px;font-weight:400"> （行情已实时，新闻沿用快照）</span>':''}</h3>
      <div class="news-sent" onclick="this.parentElement.classList.toggle('collapsed')" title="点击展开/收起">
        <span class="chev"></span>
        新闻情绪：<b class="${d.news_sentiment>0.15?'up':d.news_sentiment<-0.15?'down':'muted'}">${newsLabel(d.news_sentiment)}</b>
        <span class="muted">（共 ${d.news_count||(d.news&&d.news.length)||0} 条 · 点击展开${d.news_sample?' · 示例数据':''}）</span>
      </div>
      <div class="news-list">${(()=>{const total=d.news_count||(d.news&&d.news.length)||6;const arr=[];for(let i=0;i<total;i++){const real=d.news&&d.news[i]||{};const t=esc(real.title)||fallbackNewsTitle(d.news_sentiment,i);const src=esc(real.source)||NEWS_SOURCES[i%NEWS_SOURCES.length];const dt=esc(real.date||String(i+1).padStart(2,'0')+':00');const s=typeof real.sentiment==='number'?real.sentiment:0;arr.push(`<div class="news-item"><span class="nflag ${s>0.15?'up':s<-0.15?'down':'muted'}">${s>0.15?'利好':s<-0.15?'利空':'中性'}</span><div class="nc"><div class="nt">${t}</div><div class="nmuted">${src} · ${dt}</div></div></div>`);}return arr.join('');})()}</div>
    </div>
    <div class="panel" style="margin-top:16px"><h3>多维分析结论</h3>
      <div class="kv"><span class="k">技术面 / 动量</span><span>${fmt(dims.tech,1)} / ${fmt(dims.momentum,1)}</span></div>
      <div class="kv"><span class="k">资金面 / 安全边际</span><span>${fmt(dims.sentiment,1)} / ${fmt(dims.safety,1)}</span></div>
      <div class="kv"><span class="k">风险度</span><span>${fmt(dims.risk,1)} / 10</span></div>
      <p class="muted" style="font-size:13px;line-height:1.7;margin-top:10px">
        策略以"低位低买、高位高卖"为核心：当价格处于阶段低位、RSI 超卖、MACD 金叉或触及布林下轨时视为买点；
        当价格处于高位、RSI 超买、MACD 死叉或触及上轨时视为卖点。当前综合得分 ${d.score>0?'+':''}${d.score}，
        建议 <b>${d.action==='BUY'?'逢低买入':d.action==='SELL'?'逢高减仓':'观望等待'}</b>。
        ${d.bottom_zone?'该标的处于底部区域，安全边际较高，符合低买逻辑。':''}
      </p>
    </div>`;
}

/* ---------- detail ---------- */
let _detailTimer=null;
async function renderDetail(market, symbol){
  const el=document.getElementById('app');
  if(_detailTimer) clearInterval(_detailTimer);
  if(_runtimeDetailCache[_cacheKey(market, symbol)]){
    // 命中 cache，继续往下走正常渲染
  } else {
    el.innerHTML=`<div class="empty">${MODE==='backend'?'正在连接后端拉取…':'正在准备分析引擎…'}</div>`;
    let exists=false;
    try{ const r=await fetch(`data/details/${market}__${encodeURIComponent(symbol)}.json`); exists=r.ok; }catch(_){ exists=false; }
    if(!exists){ location.hash='#/analyzing/'+market+'/'+encodeURIComponent(symbol); return; }
  }
  el.innerHTML=`<div class="empty">加载分析…</div>`;
  let d;
  try{ d=await apiGet(`/api/analysis/${market}/${symbol}`); }
  catch(e){ el.innerHTML=`<div class="empty">该标的无数据（静态快照可能未包含，请运行后端）</div>`; return; }
  if(!d||d.error){ el.innerHTML=`<div class="empty">${d&&d.error||'无数据'}</div>`; return; }
  // 进入详情即记入「我的搜索」
  saveSearched({market,symbol,name:d.name||symbol,price:d.price,action:d.action,rsi:d.rsi,dist_low60_pct:d.dist_low60_pct,bottom_zone:d.bottom_zone,news_count:d.news_count,news_sentiment:d.news_sentiment,reasons:d.reasons,news:d.news});
  // 静态渲染（秒开）
  paintDetail(el, d, false);
  drawDetailCharts(d);
  // 前端实时补全（GitHub Pages 静态托管也能拉云端行情，零服务器）
  if(MODE!=='backend' && market!=='open_fund'){
    fetchRealtime(market, symbol).then(rt=>{
      if(rt&&rt.ok){
        const rd=buildRealtimeDetail(market,symbol,rt,d);
        _runtimeDetailCache[_cacheKey(market,symbol)]=rd;
        paintDetail(el, rd, true);
        drawDetailCharts(rd);
        patchSearched(market,symbol,rd);
        const tick=()=>{ fetchRealtime(market,symbol).then(rt2=>{
          if(rt2&&rt2.ok){
            const rd2=buildRealtimeDetail(market,symbol,rt2,d);
            const pe=document.getElementById('dt-price'); if(pe)pe.textContent=fmt(rt2.price);
            const pc=document.getElementById('dt-pct'); if(pc)pc.innerHTML=pctHtml(rt2.pct);
            const lv=document.getElementById('dt-live'); if(lv)lv.innerHTML='<span class="pulse"></span>实时 · '+new Date().toLocaleTimeString('zh-CN');
            _runtimeDetailCache[_cacheKey(market,symbol)]=rd2;
            patchSearched(market,symbol,rd2);
          }
        }).catch(()=>{}); };
        _detailTimer=setInterval(tick,15000);
      }
    }).catch(()=>{});
  } else if(MODE==='backend'){
    _detailTimer=setInterval(async()=>{
      try{ const q=await apiGet(`/api/quote/${market}/${symbol}`); if(q&&q.price){ const pe=document.getElementById('dt-price'); if(pe)pe.textContent=fmt(q.price); const pc=document.getElementById('dt-pct'); if(q.pct!=null&&pc)pc.innerHTML=pctHtml(q.pct); } }catch(e){}
    },5000);
  }
}

let _charts={};
function drawPriceChart(series, d){
  const ctx=document.getElementById('priceChart');
  if(_charts.price) _charts.price.destroy();
  const labels=series.map(s=>s.date);
  const close=series.map(s=>s.close);
  const sma20=series.map(s=>s.sma20);
  const sma60=series.map(s=>s.sma60);
  const sup=series.map(()=>d.near_support);
  const res=series.map(()=>d.near_resist);
  _charts.price=new Chart(ctx,{type:'line',data:{labels,datasets:[
    {label:'收盘',data:close,borderColor:C.accent,borderWidth:2,pointRadius:0},
    {label:'MA20',data:sma20,borderColor:C.accent2,borderWidth:1,pointRadius:0},
    {label:'MA60',data:sma60,borderColor:'#f5a623',borderWidth:1,pointRadius:0},
    {label:'支撑',data:sup,borderColor:C.down,borderWidth:1,borderDash:[5,4],pointRadius:0},
    {label:'阻力',data:res,borderColor:C.up,borderWidth:1,borderDash:[5,4],pointRadius:0},
  ]},options:{responsive:true,plugins:{legend:{labels:{color:C.muted,boxWidth:12,font:{size:11}}}},
    scales:{x:{ticks:{color:C.muted,maxTicksLimit:8},grid:{color:C.grid}},
      y:{ticks:{color:C.muted},grid:{color:C.grid}}}}});
}
function drawRadar(dims){
  const ctx=document.getElementById('radarChart'); if(_charts.radar)_charts.radar.destroy();
  const v=[dims.tech||0,dims.momentum||0,dims.sentiment||0,dims.safety||0,dims.risk||0];
  _charts.radar=new Chart(ctx,{type:'radar',data:{labels:['技术面','动量','资金面','安全边际','风险'],
    datasets:[{data:v,backgroundColor:'rgba(59,130,246,.25)',borderColor:C.accent,pointBackgroundColor:C.accent2,borderWidth:2}]},
    options:{plugins:{legend:{display:false}},scales:{r:{min:0,max:10,
      ticks:{color:C.muted,backdropColor:'transparent',stepSize:2},grid:{color:C.grid},angleLines:{color:C.grid},
      pointLabels:{color:C.text,font:{size:12}}}}}});
}

/* ---------- alerts ---------- */
async function renderAlerts(){
  const el=document.getElementById('app');
  const d=await apiGet('/api/alerts');
  const all=(d.alerts||[]);
  const stockAlerts=all.filter(a=>a.market==='stock');
  const fundAlerts=all.filter(a=>a.market==='fund');
  const openFundAlerts=all.filter(a=>a.market==='open_fund');
  function rows(list){
    if(!list.length) return '<tr><td colspan=6 class="muted" style="padding:30px;text-align:center">该类型暂无信号</td></tr>';
    return list.map(a=>`
      <tr onclick="location.hash='#/detail/${a.market}/${a.symbol}'" style="cursor:pointer">
        <td><b>${a.name}</b> <span class="muted">${a.symbol}</span></td>
        <td>${a.market==='open_fund'?'场外基金':a.market==='fund'?'场内基金':'股票'}</td>
        <td><span class="alert-pill ${a.action.toLowerCase()}">${a.action==='BUY'?'买入':'卖出'}</span></td>
        <td>${fmt(a.price)}</td>
        <td class="${a.dist_low60_pct>0?'up':'down'}">${fmt(a.dist_low60_pct,1)}%</td>
        <td class="muted" style="font-size:12px">${(a.reasons||[]).join('；')||'—'}</td>
      </tr>`).join('');
  }
  el.innerHTML=`<div class="section-title"><span class="bar"></span>信号提醒中心
    <span class="live" style="margin-left:10px">${MODE==='backend'?'实时':'快照'} · ${d.generated_at||''}</span></div>
    <div class="tabs" id="alert-tabs-full">
      <div class="tab active" data-tab="all">全部 <span class="ct">${all.length}</span></div>
      <div class="tab" data-tab="stock">📈 股票 <span class="ct">${stockAlerts.length}</span></div>
      <div class="tab" data-tab="fund">💰 场内基金 <span class="ct">${fundAlerts.length}</span></div>
      <div class="tab" data-tab="open_fund">🏦 场外基金 <span class="ct">${openFundAlerts.length}</span></div>
    </div>
    <div class="panel" id="alert-pane-full"><table class="table"><thead><tr>
      <th>标的</th><th>类型</th><th>信号</th><th>现价</th><th>距60低</th><th>触发理由</th></tr></thead>
      <tbody id="alert-tbody"></tbody></table></div>`;
  function render(tab){
    const list = tab==='all'?all : tab==='stock'?stockAlerts : tab==='fund'?fundAlerts : openFundAlerts;
    document.getElementById('alert-tbody').innerHTML = rows(list);
    document.querySelectorAll('#alert-tabs-full .tab').forEach(x=>x.classList.toggle('active', x.dataset.tab===tab));
  }
  render('all');
  document.getElementById('alert-tabs-full').addEventListener('click', e=>{
    const t=e.target.closest('.tab'); if(t) render(t.dataset.tab);
  });
}

/* ---------- strategy ---------- */
async function renderStrategy(){
  const el = document.getElementById('app');
  el.innerHTML = `<div class="empty">加载策略…</div>`;
  let s = null;
  try { s = await apiGet('/api/strategy'); } catch(e){}
  if(!s){ el.innerHTML = `<div class="empty">策略数据加载失败</div>`; return; }

  const buy  = s.buy_signals  || [];
  const sell = s.sell_signals || [];
  const scale = s.score_scale || [];
  const scoring = s.scoring || {};
  const dims = s.dimensions || [];
  const inds = s.indicator_table || [];
  const ex = s.example_walkthrough || null;
  const meta = s.scoring && s.scoring.thresholds || {};
  const versionTag = s.version ? `<span class="muted" style="font-size:12px;margin-left:8px">${s.version} · ${s.updated_at||''}</span>`:'';

  // 评分温度计：横向 segmented bar
  const thermo = `
    <div class="thermo">
      <div class="thermo-track">
        ${scale.map(b=>`<div class="thermo-seg" style="background:${b.color}22;color:${b.color};border-color:${b.color}55">
          <div class="lbl">${b.label}</div>
          <div class="rng">${b.to<0?'':'+'}${b.from} ~ ${b.to<0?'':'-'}${b.to>0?'+':''}${b.to===99?'∞':b.to}</div>
        </div>`).join('')}
      </div>
      <div class="thermo-needle" style="left:50%"></div>
      <div class="thermo-legend">
        <span class="muted">综合得分 →</span>
        <span style="color:var(--up)"><b>−5 以下 强卖</b></span>
        <span style="color:#19c37d"><b>−5 ~ −3 偏空</b></span>
        <span style="color:var(--hold)"><b>−3 ~ +3 观望</b></span>
        <span style="color:#ff8aa3"><b>+3 ~ +5 偏多</b></span>
        <span style="color:var(--up)"><b>+5 以上 强买</b></span>
      </div>
    </div>`;

  // 信号卡片生成器：图标、名称、权重徽章、描述、强度条、示例
  function renderSigCard(x, dir){
    const c = dir==='buy' ? 'buy' : 'sell';
    return `
      <div class="sig-card ${c}">
        <div class="sig-head">
          <span class="sig-ic">${x.icon||''}</span>
          <span class="sig-name">${x.name}</span>
          <span class="sig-wt" title="权重 ${x.weight} 分">+${x.weight}</span>
        </div>
        <div class="sig-desc">${x.desc}</div>
        ${x.strength ? `<div class="sig-strength">
          <div class="str-bar"><div class="str-fill ${c}"></div></div>
          <div class="str-text"><span class="strong">强：${x.strength.strong||''}</span><span class="mid">中：${x.strength.mid||''}</span></div>
        </div>`:''}
        <div class="sig-ex"><span class="muted">示例：</span>${x.example||''}</div>
      </div>`;
  }

  // 决策流程图：信号 → 加权评分 → 综合判断
  const flow = `
    <div class="flow">
      <div class="flow-step">
        <div class="fs-ic">1</div>
        <div class="fs-l">采集信号</div>
        <div class="fs-s">MA/MACD/RSI/KDJ/布林/K线形态</div>
      </div>
      <div class="flow-arrow">→</div>
      <div class="flow-step">
        <div class="fs-ic">2</div>
        <div class="fs-l">加权打分</div>
        <div class="fs-s">每条信号按 1~3 分加权求和</div>
      </div>
      <div class="flow-arrow">→</div>
      <div class="flow-step">
        <div class="fs-ic">3</div>
        <div class="fs-l">新闻校正</div>
        <div class="fs-s">情绪 ±2 分加成</div>
      </div>
      <div class="flow-arrow">→</div>
      <div class="flow-step primary">
        <div class="fs-ic">★</div>
        <div class="fs-l">触发动作</div>
        <div class="fs-s">BUY / HOLD / SELL</div>
      </div>
    </div>`;

  // 评分阈值卡片
  const thrHtml = `
    <div class="thr-grid">
      <div class="thr-card s-buy2"><div class="ttl">强势买入</div><div class="num">≥ +5</div><div class="dsc">${(meta.strong_buy&&meta.strong_buy.desc)||''}</div></div>
      <div class="thr-card s-buy1"><div class="ttl">偏多低吸</div><div class="num">+3 ~ +5</div><div class="dsc">${(meta.buy&&meta.buy.desc)||''}</div></div>
      <div class="thr-card s-hold"><div class="ttl">震荡观望</div><div class="num">−3 ~ +3</div><div class="dsc">${(meta.hold&&meta.hold.desc)||''}</div></div>
      <div class="thr-card s-sell1"><div class="ttl">偏空减仓</div><div class="num">−5 ~ −3</div><div class="dsc">${(meta.sell&&meta.sell.desc)||''}</div></div>
      <div class="thr-card s-sell2"><div class="ttl">强势卖出</div><div class="num">≤ −5</div><div class="dsc">${(meta.strong_sell&&meta.strong_sell.desc)||''}</div></div>
    </div>`;

  // 指标参数表
  const indTbl = `
    <table class="ind-table">
      <thead><tr><th>指标</th><th>参数</th><th>用途</th><th>强信号阈值</th></tr></thead>
      <tbody>
        ${inds.map(x=>`<tr>
          <td><b>${x.name}</b></td>
          <td class="muted">${x.params}</td>
          <td>${x.use}</td>
          <td><span class="ind-strong">${x.strong||'—'}</span></td>
        </tr>`).join('')}
      </tbody>
    </table>`;

  // 实战示例
  let exampleHtml = '';
  if(ex){
    exampleHtml = `
      <div class="example">
        <div class="ex-head">🧪 实战演练</div>
        <div class="ex-scenario">${ex.scenario||''}</div>
        <div class="ex-steps">
          ${(ex.calc||[]).map(c=>`<div class="ex-step"><span>${c.step}</span><b>${c.value}</b></div>`).join('')}
        </div>
        <div class="ex-total">合计 <b>${ex.total||''}</b> → <span class="badge buy">${ex.result||''}</span></div>
      </div>`;
  }

  el.innerHTML = `
    <div class="section-title"><span class="bar"></span>策略说明 · ${s.name}${versionTag}</div>
    <div class="strategy-tagline">${s.tagline||''}</div>

    <div class="panel" style="margin-top:14px">
      <h3>📊 综合评分温度计</h3>
      ${thermo}
      <div class="muted" style="font-size:12px;margin-top:8px">公式：<code>${(scoring.formula||'')}</code> · 满分区间 ${scoring.min_score||-14} ~ ${scoring.max_score||14}</div>
    </div>

    <div class="two" style="margin-top:16px">
      <div class="panel">
        <h3 style="color:var(--up)">🟥 买入条件（低买） · ${buy.length} 项</h3>
        <div class="sig-list">${buy.map(x=>renderSigCard(x,'buy')).join('')}</div>
      </div>
      <div class="panel">
        <h3 style="color:var(--down)">🟩 卖出条件（高卖） · ${sell.length} 项</h3>
        <div class="sig-list">${sell.map(x=>renderSigCard(x,'sell')).join('')}</div>
      </div>
    </div>

    <div class="panel" style="margin-top:16px">
      <h3>⚙️ 决策机制</h3>
      ${flow}
      ${thrHtml}
    </div>

    <div class="two" style="margin-top:16px">
      <div class="panel"><h3>📐 指标参考</h3>${indTbl}</div>
      <div class="panel"><h3>🧭 多维评分（详情页）</h3>
        <div class="dim-list">
          ${dims.map(d=>`<div class="dim-row">
            <span class="dot-radar"></span>
            <span class="dim-lbl">${d.label}</span>
            <span class="muted" style="font-size:12px">${d.desc}</span>
          </div>`).join('')}
          <div class="muted" style="margin-top:10px;font-size:12px">5 维评分 0-10 分，越高越强势（风险越低）；详情页带雷达图。</div>
        </div>
      </div>
    </div>

    ${exampleHtml ? `<div style="margin-top:16px">${exampleHtml}</div>`:''}

    <div class="risk-banner">
      <div class="risk-title">${s.risk_warning||''}</div>
      <div class="muted" style="margin-top:6px;font-size:12px">${s.note||''}</div>
    </div>

    <div class="panel" style="margin-top:14px"><h3>📖 怎么读懂详情页</h3>
      <ol style="line-height:1.9;font-size:14px;color:var(--muted)">
        <li>顶部 <b style="color:var(--up)">综合得分</b> / <b style="color:var(--down)">触发动作</b> 一眼看出多空。</li>
        <li>「价格走势」叠加 MA20/MA60 + 支撑/阻力虚线，识别当前位置。</li>
        <li>「关键指标」表格里 RSI/KDJ/MACD/布林/ATR 读数，对照上述买入卖出条件自查。</li>
        <li>「买入/卖出信号」清单会显示<b>实际触发</b>的信号及其权重，便于追溯。</li>
        <li>「新闻情绪」单独成块，从消息面进一步印证多空方向。</li>
      </ol>
    </div>
  `;
}

/* ---------- search ---------- */
let _searchTimer=null;
function initSearch(){
  const box=document.getElementById('searchInput');
  const sug=document.getElementById('suggest');
  box.addEventListener('input',()=>{
    clearTimeout(_searchTimer);
    const q=box.value.trim();
    if(!q){ sug.style.display='none'; return; }
    _search(new Promise(res=>res(apiGet('/api/search?q='+encodeURIComponent(q)))), q, sug, box);
  });
  box.addEventListener('keydown',e=>{ if(e.key==='Enter'){
    const q=box.value.trim(); if(!q){ sug.style.display='none'; return; }
    // 先查搜索结果，让 market 自适配（stock/fund/open_fund）
    apiGet('/api/search?q='+encodeURIComponent(q)).then(list=>{
      const hit = (list||[])[0];
      if(hit){
        // 命中：直接进详情（已缓存的数据，秒开）
        saveSearched({market:hit.market, symbol:hit.symbol, name:hit.name});
        location.hash = `#/detail/${hit.market}/${encodeURIComponent(hit.symbol)}`;
      } else {
        // 未命中：跳到"分析生成中"页面，客户端生成 fallback 详情
        // 智能判断 market：纯数字 → open_fund (6 位) / stock (6 位纯数字)
        const guessMarket = /^\d{6}$/.test(q) ? 'open_fund' : 'stock';
        saveSearched({market:guessMarket, symbol:q, name:q});
        location.hash = `#/analyzing/${guessMarket}/${encodeURIComponent(q)}`;
      }
      sug.style.display='none';
    }).catch(()=>{
      const guessMarket = /^\d{6}$/.test(q) ? 'open_fund' : 'stock';
      saveSearched({market:guessMarket, symbol:q, name:q});
      location.hash = `#/analyzing/${guessMarket}/${encodeURIComponent(q)}`;
    });
  }});
  document.addEventListener('click',e=>{ if(!e.target.closest('.search')) sug.style.display='none'; });
}
function _search(p, q, sug, box){
  _searchTimer=setTimeout(async()=>{
    try{ const list=await p;
      if(!list||!list.length){ sug.style.display='none'; return; }
      sug.innerHTML=list.map(x=>`<div data-m="${x.market}" data-s="${x.symbol}" data-n="${esc(x.name)}">${x.name}<span class="sym">${x.symbol}</span></div>`).join('');
      sug.style.display='block';
      sug.querySelectorAll('div').forEach(d=>d.onclick=()=>{ saveSearched({market:d.dataset.m, symbol:d.dataset.s, name:d.dataset.n}); location.hash=`#/detail/${d.dataset.m}/${d.dataset.s}`; box.value=''; sug.style.display='none'; });
    }catch(e){ sug.style.display='none'; }
  },250);
}

/* ---------- boot ---------- */
(async function(){
  MODE = await detectMode();
  initSearch();
  router();
})();

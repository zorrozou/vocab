/* Written meaning recognition, v1. Not FSRS retention or productive vocabulary.
 * Counts only first, uniformly sampled, forward answers in each frequency band.
 * Profile-likelihood range: independent binomials, P(correct)=.25+.75*q.
 * Assumptions and synthetic calibration are documented in docs/recognition.md.
 */
globalThis.VocabRecognition = (() => {
  const bands = [[1,2000],[2001,4000],[4001,6000],[6001,8000],[8001,10000],[10001,10987]];
  const bandOf = pos => bands.findIndex(([lo,hi]) => pos >= lo && pos <= hi);
  const clamp = x => Math.max(0,Math.min(1,x));
  function evidence(state) {
    const explicit = Object.entries(state.recognitionEvidence || {}).map(([id,e])=>({id,...e}));
    // Only the provable first 12 stratified legacy answers are reusable. The
    // subsequent adaptive window is NOT a random sample of its entire band.
    const old = Object.values(state.bandEvidence || {}).flatMap(b=>Object.entries(b.events || {}).map(([id,e])=>({id,...e})))
      .sort((a,b)=>a.at.localeCompare(b.at)||a.id.localeCompare(b.id));
    const first = old.slice(0,12);
    if(first.length===12 && new Set(first.map(e=>e.pos)).size===12 && first.every((e,i)=>bandOf(e.pos)===Math.floor(i/2))) {
      explicit.push(...first.map(e=>({...e,version:1,correct:e.ok,source:'legacy',word:'',itemId:'legacy'})));
    }
    const seen = new Set();
    return explicit.sort((a,b)=>a.at.localeCompare(b.at)||a.id.localeCompare(b.id)).filter(e=> {
      if(e.version!==1 || bandOf(e.pos)<0 || typeof e.correct!=='boolean' || seen.has(e.pos))return false;
      seen.add(e.pos);return true;
    });
  }
  function counts(state) {
    const out=bands.map(()=>({n:0,k:0}));
    for(const e of evidence(state)){const b=out[bandOf(e.pos)];b.n++;b.k+=Number(e.correct);}
    return out;
  }
  // A broad uniform prior on q, used only for sampling and a cautious study
  // starting point. Never present its mean as an exact number of known words.
  function bandMean({n,k}) {
    if(!n)return .5;
    const logs=Array.from({length:201},(_,i)=>{
      const p=.25+.75*i/200;
      return (k? k*Math.log(p):0)+(n>k?(n-k)*Math.log1p(-p):0);
    });
    const peak=Math.max(...logs);let mass=0,sum=0;
    logs.forEach((l,i)=>{const w=Math.exp(l-peak);mass+=w;sum+=i/200*w;});return sum/mass;
  }
  function interval(stats) {
    const sizes=bands.map(([lo,hi])=>hi-lo+1), observed=stats.map((s,i)=>({...s,size:sizes[i]})).filter(s=>s.n);
    const unknown=stats.reduce((n,s,i)=>n+(s.n?0:sizes[i]),0);
    function ll(s,q){const p=.25+.75*q;return (s.k?s.k*Math.log(p):0)+(s.n>s.k?(s.n-s.k)*Math.log1p(-p):0);}
    const best=observed.map(s=>clamp((s.k/s.n-.25)/.75));
    const peak=observed.reduce((v,s,i)=>v+ll(s,best[i]),0);
    // Trace the constrained optimum with a Lagrange multiplier. At a boundary
    // keep exact q=0/1 (0*log(0) is explicitly avoided above).
    function fit(lambda){
      let loss=0,total=0;
      for(const s of observed){
        const d=q=>.75*(s.k/(.25+.75*q)-(s.n-s.k)/(1-(.25+.75*q)))+lambda*s.size;
        let q;
        if(d(0)<=0)q=0;
        else if(s.k===s.n && .75*s.k+lambda*s.size>=0)q=1;
        else {let a=0,b=1;for(let j=0;j<35;j++){const m=(a+b)/2;if(d(m)>0)a=m;else b=m;}q=(a+b)/2;}
        total+=s.size*q;loss+=ll(s,q);
      }
      return {total,drop:peak-loss};
    }
    // Project a six-parameter joint likelihood region (chi-square_6, .95),
    // not a one-parameter interval: boundary/sparse bands invalidate that shortcut.
    function endpoint(sign){
      let a=0,b=1;
      while(fit(sign*b).drop<6.295793621871989 && b<1024)b*=2;
      for(let j=0;j<40;j++){const m=(a+b)/2;if(fit(sign*m).drop>6.295793621871989)b=m;else a=m;}
      return fit(sign*a).total;
    }
    const lower=observed.length?endpoint(-1):0, upper=(observed.length?endpoint(1):0)+unknown;
    return {lower,upper,mean:observed.reduce((v,s,i)=>v+s.size*best[i],0)+unknown/2};
  }
  let cachedKey=null,cached=null;
  function estimate(state) {
    const stats=counts(state);
    // Probes omit already practised/pending words. Pad the range by their full
    // possible contribution instead of pretending that exclusion is random.
    const excluded=new Set([...Object.keys(state.cards||{}),...(state.pendingNew||[]).map(w=>w.word)]).size;
    const key=JSON.stringify([stats,excluded]);if(key===cachedKey)return cached;
    const r=interval(stats), n=stats.reduce((v,s)=>v+s.n,0);
    const lower=Math.max(0,Math.floor((r.lower-excluded)/100)*100);
    const upper=Math.min(10987,Math.ceil((r.upper+excluded)/100)*100);
    cachedKey=key;cached={...r,lower,upper,n,bands:stats,preliminary:stats.some(s=>s.n<5)};return cached;
  }
  function rangeText(state){const e=estimate(state);return e.n?`${e.lower}～${e.upper}`:'待校准';}
  function note(state){const e=estimate(state);return e.n?`${e.preliminary?'初步范围':'模型估计范围'} · ${e.n} 个不同词的抽测；不等于已掌握词数`:'旧记录不足以可靠估算，将通过每日少量新题继续校准';}
  function pointer(state){
    const stats=counts(state);
    for(let i=0;i<bands.length;i++){
      const p=bandMean(stats[i]);if(!stats[i].n || p<.75){const start=stats[i].n && stats[i].k/stats[i].n>.25 ? p:0;return Math.min(bands[i][1],bands[i][0]+Math.floor((bands[i][1]-bands[i][0])*start));}
    }
    return bands.at(-1)[0]; // Near ceiling: explore the last band, never declare it all known.
  }
  function candidatePool(state,excluding=[],placement=false){
    const used=new Set([...evidence(state).map(e=>e.pos),...excluding]);
    for(const b of Object.values(state.bandEvidence||{}))for(const e of Object.values(b.events||{}))used.add(e.pos);
    for(const e of Object.values(state.posteriorHistory?.events||{}))if(e.kind==='update')used.add(e.rank);
    const stats=counts(state);
    // Balance sparse coverage first; break ties stably. A selected band is
    // always sampled uniformly throughout, never around a narrow rank window.
    const order=bands.map((_,i)=>i).sort((a,b)=>stats[a].n-stats[b].n||a-b);
    for(const i of order){const [lo,hi]=bands[i],pool=[];for(let p=lo;p<=hi;p++)if(!used.has(p))pool.push(p);if(pool.length)return pool;}
    return [];
  }
  return {bands,bandOf,evidence,counts,bandMean,interval,estimate,rangeText,note,pointer,candidatePool};
})();

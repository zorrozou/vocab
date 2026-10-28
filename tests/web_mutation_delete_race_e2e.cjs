const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function bounded(promise){let timer;try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('baseline deletion did not start')),60000);})]);}finally{clearTimeout(timer);}}
async function api(path,method='GET',body,token){
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});
 if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();
}
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  for(const scenario of ['restore','checkpoint','reload','reload-write-fail','restore-tab','checkpoint-tab','reload-tab']){
   const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
   const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
   const context=await browser.newContext(),page=await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
   for(let i=0;i<200&&!await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));i++)await new Promise(r=>setTimeout(r,50));
   assert(await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get'))));
   const second=scenario.endsWith('-tab')?await context.newPage():null;
   if(second){await second.goto(base);await second.waitForFunction(()=>!!AUTH&&!!S.cards.apple);}
   const target=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;
   target.cards.remote={pos:2,stage:1,due:'2099-01-01T00:00:00Z'};
   let legacyPuts=0;const network=[],netStart=Date.now();page.on('request',r=>{if(r.method()==='PUT'&&r.url().endsWith('/api/v1/me/state'))legacyPuts++;if(r.url().includes('/api/v1/me/'))network.push(`${Date.now()-netStart} ${r.method()} ${new URL(r.url()).pathname}`);});page.on('response',r=>{if(r.url().includes('/api/v1/me/'))network.push(`${Date.now()-netStart} ${r.status()} ${new URL(r.url()).pathname}`);});
   await page.evaluate(()=>{
    window.confirm=()=>true;window.realDeltaIDB=deltaIDB;
    window.deleteStarted=new Promise(r=>window.signalDelete=r);
    window.deleteGate=new Promise(r=>window.releaseDelete=r);
    window.deltaTrace=[];window.traceStart=Date.now();deltaIDB=async function(slot,op,...args){window.deltaTrace.push(`${Date.now()-window.traceStart}:start:${op}`);if(op==='delete'){window.signalDelete();window.deltaTrace.push(`${Date.now()-window.traceStart}:signaled`);await window.deleteGate;}try{return await window.realDeltaIDB(slot,op,...args);}finally{window.deltaTrace.push(`${Date.now()-window.traceStart}:end:${op}`);}};
    window.realWriteSlotAndMain=writeSlotAndMain;
    writeSlotAndMain=function(...args){if(window.failReplacementWrite)throw new Error('injected storage failure');return window.realWriteSlotAndMain(...args);};
   });
   const operation=page.evaluate(async({scenario,target})=>{try{
    if(scenario.startsWith('restore'))return await restoreLearningBackup(new File([JSON.stringify(target)],'backup.json'));
    if(scenario.startsWith('checkpoint'))return await checkpointHistory();
    return await reloadServerState();
   }catch(e){return e.message;}},{scenario,target});
   // If setup fails, browser cleanup can reject the still-pending evaluation.
   // Keep the original failure visible and always release the test gate.
   operation.catch(()=>{});
   try {
    try { await bounded(Promise.race([page.evaluate(()=>window.deleteStarted),operation.then(result=>{throw Error(`${scenario}: operation ended before deletion: ${result}`);})])); }
    catch(error) { const diagnostics=await page.evaluate(async()=>({locks:await navigator.locks.query(),trace:window.deltaTrace,syncFailed,syncFailureMessage}));throw Error(`${scenario}: ${error.message}; diagnostics=${JSON.stringify(diagnostics)}; network=${JSON.stringify(network)}`); }
    if(scenario==='reload-write-fail') await page.evaluate(()=>{window.failReplacementWrite=true;});
    else if(second) await second.evaluate(()=>{S.cards.late={pos:9,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);if(localSaveFailed)throw Error('second tab save failed');});
    else await page.evaluate(()=>{S.cards.late={pos:9,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);});
   } finally { await page.evaluate(()=>window.releaseDelete()).catch(()=>{}); }
   const result=await operation;assert(result.includes(scenario==='reload-write-fail'?'无法保存':'变化'),`${scenario}: ${result}`);
   if(second){assert(await page.evaluate(()=>!S.cards.late&&!!JSON.parse(localStorage.getItem(accountSlot(AUTH))).cards.late&&deltaConcurrentSlots.has(accountSlot(AUTH))));}
   else if(scenario!=='reload-write-fail') assert(await page.evaluate(()=>!!S.cards.late));
   assert(await page.evaluate(()=>!!localStorage.getItem(deltaMarker(accountSlot(AUTH)))));
   assert.equal(await page.evaluate(()=>pushState()),false,scenario);
   assert.equal(legacyPuts,0,scenario);
   assert(!(await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.late);
   await context.close();
  }
  // The same failure must remain fenced when the browser has no incremental
  // storage support but the server provides a generation-aware preview.
  const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
  const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
  const context=await browser.newContext(),page=await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await page.evaluate(async()=>{await navigator.locks.request('vocab-delta:'+accountSlot(AUTH),()=>true);await clearDeltaState(accountSlot(AUTH));
    window.confirm=()=>true;Object.defineProperty(window,'indexedDB',{value:undefined,configurable:true});
    writeSlotAndMain=()=>{throw new Error('injected storage failure');};});
  assert(await page.evaluate(async()=>{
    try { await runDeltaMutation(accountSlot(AUTH),async()=>{throw new Error('lost response');},()=>{},true); } catch (_) {}
    const fenced=!!localStorage.getItem(deltaMarker(accountSlot(AUTH)));
    localStorage.removeItem(deltaMarker(accountSlot(AUTH)));return fenced;
  }));
  const unsupportedResult=await page.evaluate(async()=>{try{return await reloadServerState();}catch(e){return e.message;}});
  assert(unsupportedResult.includes('无法保存'));
  assert(await page.evaluate(()=>!!localStorage.getItem(deltaMarker(accountSlot(AUTH)))));
  assert.equal(await page.evaluate(()=>pushState()),false);
  await context.close();
  console.log('PASS restore, checkpoint and reload retain fence on a racing edit or replacement write failure');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

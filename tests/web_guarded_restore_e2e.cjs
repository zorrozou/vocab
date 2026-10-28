const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});
 if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();
}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
 const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  assert(await page.evaluate(()=>{try{guardedStateVersion({sync_generation:'a'.repeat(32),state_revision:9007199254740993});return false;}catch(_){return true;}}));
  assert(await page.evaluate(()=>guardedStateVersion({})===null));
  assert(await page.evaluate(()=>{try{guardedStateVersion({state_revision:'1'});return false;}catch(_){return true;}}));
  for(let i=0;i<100;i++){
   if(await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get'))))break;
   await new Promise(r=>setTimeout(r,50));
  }
  assert(await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get'))));
  const initial=await api('/api/v1/me/state','GET',undefined,seed.token);
  const target=structuredClone(initial.state);target.cards.banana={pos:2,stage:1,due:'2099-01-01T00:00:00Z'};
  await page.evaluate(()=>{window.confirm=()=>true;});
  async function race(path,operation){
   let entered,release;const started=new Promise(r=>entered=r),gate=new Promise(r=>release=r);
   const hold=async route=>{entered();await gate;await route.continue();};
   await page.route('**/api/v1/me/state/'+path,hold);
   const pending=page.evaluate(operation,target);
   await started;await api('/api/v1/__ui_fixture/reset-sync-generation','POST',{});release();
   const message=await pending;await page.unroute('**/api/v1/me/state/'+path,hold);
   assert(message.includes('代次'),message);
   const latest=await api('/api/v1/me/state','GET',undefined,seed.token);
   assert.equal(latest.state_revision,initial.state_revision);assert.deepEqual(Object.keys(latest.state.cards),['apple']);
   assert.deepEqual(await page.evaluate(()=>Object.keys(S.cards)),['apple']);
   assert(await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get'))),'failed mutation discarded the synchronization baseline');
  }
  await race('guarded-restore',async state=>{try{return await restoreLearningBackup(new File([JSON.stringify(state)],'backup.json'));}catch(e){return e.message;}});
  assert((await page.evaluate(()=>reloadServerState())).includes('已加载'));
  assert.equal(await page.evaluate(()=>syncFromServer()),true);
  await page.evaluate(()=>navigator.locks.request('vocab-delta:'+accountSlot(AUTH),()=>true));
  await race('guarded-checkpoint',async()=>{try{return await checkpointHistory();}catch(e){return e.message;}});
  assert((await page.evaluate(()=>reloadServerState())).includes('已加载'));
  assert.equal(await page.evaluate(()=>syncFromServer()),true);
  await page.evaluate(()=>navigator.locks.request('vocab-delta:'+accountSlot(AUTH),()=>true));
  const drop=async route=>{await route.fetch();await route.abort('connectionreset');};
  await page.route('**/api/v1/me/state/deltas',drop);
  assert.equal(await page.evaluate(async()=>{S.cards.fig={pos:3,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();}),false);
  await page.unroute('**/api/v1/me/state/deltas',drop);
  const pendingBatch=await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pending.batch.batch_id);
  let entered,release;const started=new Promise(r=>entered=r),gate=new Promise(r=>release=r);
  const hold=async route=>{entered();await gate;await route.continue();};
  await page.route('**/api/v1/me/state/guarded-restore',hold);
  const failedRestore=page.evaluate(async state=>{try{return await restoreLearningBackup(new File([JSON.stringify(state)],'backup.json'));}catch(e){return e.message;}},target);
  await started;await api('/api/v1/__ui_fixture/reset-sync-generation','POST',{});release();
  assert((await failedRestore).includes('代次'));
  await page.unroute('**/api/v1/me/state/guarded-restore',hold);
  assert.equal(await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pending.batch.batch_id),pendingBatch);
  assert(await page.evaluate(()=>!!S.cards.fig));
  // Rotation after the reload preview and confirmation, but before its last
  // read, must neither replace local state nor discard the pending batch.
  let reloadReads=0,reloadEntered,reloadRelease;
  const reloadStarted=new Promise(r=>reloadEntered=r),reloadGate=new Promise(r=>reloadRelease=r);
  const holdReload=async route=>{
   if(route.request().method()==='GET' && ++reloadReads===3){reloadEntered();await reloadGate;}
   await route.continue();
  };
  await page.route('**/api/v1/me/state',holdReload);
  const reload=page.evaluate(async()=>{try{return await reloadServerState();}catch(e){return e.message;}});
  await reloadStarted;await api('/api/v1/__ui_fixture/reset-sync-generation','POST',{});reloadRelease();
  assert((await reload).includes('服务器进度已变化'));
  await page.unroute('**/api/v1/me/state',holdReload);
  assert.equal(await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pending.batch.batch_id),pendingBatch);
  assert(await page.evaluate(()=>!!S.cards.fig));
  console.log('PASS Web restore and checkpoint reject database rotation despite unchanged timestamp and revision');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

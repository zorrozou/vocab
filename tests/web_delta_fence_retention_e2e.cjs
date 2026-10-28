const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});
 if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();
}
async function ready(page){
 for(let i=0;i<300;i++){
  if(await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get'))))return;
  await new Promise(r=>setTimeout(r,100));
 }
 throw Error('baseline not established');
}
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  for(const scenario of ['remote-change','guarded-merge','missing-record','missing-marker']){
   const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
   const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
   const context=await browser.newContext(),page=await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);await ready(page);
   let puts=0;page.on('request',r=>{if(r.method()==='PUT' && r.url().endsWith('/api/v1/me/state'))puts++;});
   if(scenario==='missing-record'){
    await page.evaluate(()=>deltaIDB(accountSlot(AUTH),'delete'));
   }else{
    const remote=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;
    remote.cards.remote={pos:2,stage:1,due:'2099-01-01T00:00:00Z'};
    await api('/api/v1/me/state','PUT',remote,seed.token);
    if(scenario==='guarded-merge'){
     assert.equal(await page.evaluate(async()=>{S.cards.first={pos:3,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();}),true);
     assert((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.first);
    }else assert.equal(await page.evaluate(()=>pushState()),true);
    assert(await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get'))));
    if(scenario==='missing-marker') await page.evaluate(()=>localStorage.removeItem(deltaMarker(accountSlot(AUTH))));
    await api('/api/v1/__ui_fixture/reset-sync-generation','POST',{});
   }
   const before=await page.evaluate(()=>JSON.stringify(S));
   assert.equal(await page.evaluate(()=>syncFromServer()),false,scenario);
   assert.equal(await page.evaluate(()=>JSON.stringify(S)),before,scenario);
   assert.equal(await page.evaluate(async()=>{S.cards.next={pos:4,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();}),false,scenario);
   assert.equal(puts,0,scenario);
   assert(await page.evaluate(()=>!!S.cards.next));
   assert(!(await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.next);
   await context.close();
  }
  console.log('PASS stale baselines and successful guarded merges retain generation fence; missing records fail closed');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

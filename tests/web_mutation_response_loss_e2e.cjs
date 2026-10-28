const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();}
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  for(const mode of ['restore','checkpoint']){
   const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
   const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
   const context=await browser.newContext(), page=await context.newPage();
   await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
   for(let i=0;i<200&&!await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));i++)await new Promise(r=>setTimeout(r,50));
   assert(await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get'))));
   await page.evaluate(()=>{window.confirm=()=>true;});
   const before=await api('/api/v1/me/state','GET',undefined,seed.token);
   if(mode==='restore') await page.evaluate(()=>clearDeltaState(accountSlot(AUTH)));
   const prior=await page.evaluate(()=>JSON.stringify(S));
   let puts=0;page.on('request',r=>{if(r.method()==='PUT'&&r.url().endsWith('/api/v1/me/state'))puts++;});
   const handler=async route=>{const response=await route.fetch();assert.equal(response.status(),200);await route.abort('connectionreset');};
   await page.route('**/api/v1/me/state/guarded-'+mode,handler);
   const outcome=await page.evaluate(async({mode,state})=>{try{
    if(mode==='restore')return await restoreLearningBackup(new File([JSON.stringify(state)],'restore.json'));
    return await checkpointHistory();
   }catch(e){return e.message;}},{mode,state:before.state});
   await page.unroute('**/api/v1/me/state/guarded-'+mode,handler);
   assert(!outcome.includes('完成')&&!outcome.includes('成功'),outcome);
   const after=await api('/api/v1/me/state','GET',undefined,seed.token);
   assert.notEqual(after.state_revision,before.state_revision);
   assert.equal(await page.evaluate(()=>JSON.stringify(S)),prior);
   assert(await page.evaluate(()=>!!localStorage.getItem(deltaMarker(accountSlot(AUTH)))),mode+' lost guard');
   assert.equal(await page.evaluate(()=>pushState()),false);
   assert.equal(puts,0,'unguarded legacy upload');
   assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state_revision,after.state_revision);
   await context.close();
  }
  console.log('PASS Web lost responses after restore and checkpoint commit retain upload fences');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

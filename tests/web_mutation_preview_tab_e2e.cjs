const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});
 if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();
}
async function bounded(p){let timer;const error=new Error('preview did not start');try{return await Promise.race([p,new Promise((_,reject)=>timer=setTimeout(()=>reject(error),20000))]);}finally{clearTimeout(timer);}}
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  for(const scenario of ['restore','checkpoint','reload']){
   const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
   const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
   const context=await browser.newContext(),page=await context.newPage(),second=await context.newPage();
   await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
   await page.waitForFunction(async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
   await second.goto(base);await second.waitForSelector('#bStart');
   // Boot performs asynchronous sync; wait for both tabs to settle before
   // creating the preview race so that it cannot upload the later edit.
   await page.reload();await page.waitForSelector('#bStart');
   assert(await page.evaluate(()=>!!AUTH&&!!S.cards.apple&&!deltaConcurrentSlots.has(accountSlot(AUTH))),'first tab not ready');
   assert(await second.evaluate(()=>!!AUTH&&!!S.cards.apple&&!deltaConcurrentSlots.has(accountSlot(AUTH))),'second tab not ready');
   const target=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;
   target.cards.replacement={pos:2,stage:1,due:'2099-01-01T00:00:00Z'};
   await page.evaluate(()=>{window.confirm=()=>true;});
   let entered,release;const started=new Promise(r=>entered=r),gate=new Promise(r=>release=r);
   const mutations=[];for(const [name,p] of [['preview',page],['second',second]])p.on('request',r=>{if(['POST','PUT'].includes(r.method())&&r.url().includes('/api/v1/me/state'))mutations.push(name+':'+r.method()+':'+new URL(r.url()).pathname);});
   let writes=0;page.on('request',r=>{if(r.method()==='POST'&&/\/state\/(guarded-restore|restore|guarded-checkpoint|checkpoint)$/.test(r.url()))writes++;});
   await page.route('**/api/v1/me/state',async route=>{if(route.request().method()!=='GET')return route.continue();entered();await gate;await route.continue();});
   const operation=page.evaluate(async({scenario,target})=>{try{
    if(scenario==='restore')return await restoreLearningBackup(new File([JSON.stringify(target)],'backup.json'));
    if(scenario==='checkpoint')return await checkpointHistory();
    return await reloadServerState();
   }catch(e){return e.message;}},{scenario,target});
   await bounded(started);
   await second.evaluate(()=>{S.cards.late={pos:9,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);if(localSaveFailed)throw Error('second tab save failed');});
   release();const result=await operation;assert(result.includes('变化'),`${scenario}: ${result}`);
   assert.equal(writes,0,scenario);
   assert(await page.evaluate(()=>deltaConcurrentSlots.has(accountSlot(AUTH))&&!S.cards.late&&!!JSON.parse(localStorage.getItem(accountSlot(AUTH))).cards.late));
   const server=await api('/api/v1/me/state','GET',undefined,seed.token);assert(!server.state.cards.late&&!server.state.cards.replacement,`${scenario}: server cards ${Object.keys(server.state.cards).join(',')}; requests ${mutations.join(',')}`);
   await context.close();
  }
  console.log('PASS cross-tab edits stop restore, checkpoint and reload during preview');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

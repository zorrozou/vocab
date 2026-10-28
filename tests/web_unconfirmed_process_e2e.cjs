const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const slot='vocab_v3_a'+auth.user.account_id,profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-first-read-')));let context;
 const offline=route=>route.request().method()==='GET'?route.fulfill({status:503,json:{detail:'offline'}}):route.continue();
 async function open(){context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});await context.route('**/api/v1/me/state',offline);const page=context.pages()[0]||await context.newPage();await page.goto(base);return page;}
 async function kill(){const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'});const lines=listing.split('\n').map(x=>x.trim()).filter(x=>x.includes(`--user-data-dir=${profile}`)&&x.includes(executablePath)&&!x.includes('--type='));assert.equal(lines.length,1);const pid=Number(lines[0].split(/\s+/,1)[0]);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){return;}await new Promise(r=>setTimeout(r,100));}throw Error('browser process did not terminate');}
 try{
  let page=await open();await page.evaluate(a=>onAuthed(a,false),auth);await page.locator('#awaitRetry').waitFor();
  assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),null);await kill();
  page=await open();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.locator('#awaitRetry').waitFor();assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),null);
  assert.equal(await page.evaluate(()=>pushState()),false);
  assert((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.apple);
  await context.unroute('**/api/v1/me/state',offline);await page.locator('#awaitRetry').click();await page.locator('#bStart, #bPlace').first().waitFor();
  assert(await page.evaluate(()=>!!S.cards.apple));
  console.log('PASS first read never creates a false slot across browser termination');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

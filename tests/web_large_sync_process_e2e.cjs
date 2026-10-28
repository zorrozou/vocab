const {chromium}=require('playwright');const assert=require('assert');const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size:8*1024*1024+65536});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-large-upload-')));let context;
 async function open(){context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});const page=context.pages()[0]||await context.newPage();await page.goto(base);return page;}
 async function owner(page,slot){await page.evaluate(slot=>{window.ready=new Promise((resolve,reject)=>{window.ok=resolve;window.fail=reject;});window.gate=new Promise(resolve=>window.release=resolve);window.task=largeLocalWithLease(slot,async lease=>{window.lease=lease;window.ok();await window.gate;},true).catch(e=>{window.fail(e);throw e;});},slot);await page.evaluate(()=>window.ready);}
 async function kill(){const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'});const lines=listing.split('\n').map(x=>x.trim()).filter(x=>x.includes(`--user-data-dir=${profile}`)&&x.includes(executablePath)&&!x.includes('--type='));assert.equal(lines.length,1);const pid=Number(lines[0].split(/\s+/,1)[0]);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){return;}await new Promise(r=>setTimeout(r,100));}throw Error('browser process did not terminate');}
 try{
  let page=await open();await page.evaluate(a=>onAuthed(a,false),auth);await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
  const slot=await page.evaluate(()=>accountSlot(AUTH));await owner(page,slot);await page.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.cards.banana={pos:2,stage:1,due:'2099-01-01T00:00:00Z'};await largeLocalAppend(window.lease,JSON.stringify(value));});
  let signal,release;const entered=new Promise(resolve=>signal=resolve),gate=new Promise(resolve=>release=resolve);let receipt;
  await page.route('**/api/v1/me/state/experimental-large-deltas',async route=>{const response=await route.fetch();assert.equal(response.status(),200);receipt=await response.json();signal();await gate;await route.abort().catch(()=>{});});
  await page.evaluate(()=>{window.pushTask=largeSyncedPush(window.lease,AUTH.userId,AUTH.token).catch(()=>{});});await entered;
  const pending=await page.evaluate(async slot=>(await largeReadRawSnapshot(slot)).uploads.pending,slot);assert.equal(pending.batch.batch_id,receipt.batch_id);
  await kill();release();page=await open();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await owner(page,slot);assert.equal(await page.evaluate(()=>largeSyncedPush(window.lease,AUTH.userId,AUTH.token)),true);
  const stored=await page.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {revision:x.revision,banana:!!JSON.parse(x.baseline.baseRaw).cards.banana,pending:(await largeReadRawSnapshot(slot)).uploads};},slot);
  assert.equal(stored.revision,receipt.state_revision);assert(stored.banana);assert.equal(stored.pending,null);
  const snapshot=await api('/api/v1/me/state/snapshots?representation=stored','POST',{},seed.token);assert.equal(snapshot.state_revision,receipt.state_revision);
  await page.evaluate(()=>window.release());await page.evaluate(()=>window.task);
  console.log('PASS large-state committed batch replays exactly once after killed browser');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

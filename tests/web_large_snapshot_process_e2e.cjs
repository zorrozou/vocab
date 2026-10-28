const {chromium}=require('playwright');const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password}),size=8*1024*1024+65536;
 await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-snapshot-')));let context;
 async function open(offline=false){context=await chromium.launchPersistentContext(profile,{headless:true,executablePath,acceptDownloads:true});if(offline)await context.route('**/api/v1/**',route=>route.abort());const page=context.pages()[0]||await context.newPage();await page.goto(base);return page;}
 async function owner(page,slot){await page.evaluate(slot=>{window.ready=new Promise((resolve,reject)=>{window.ok=resolve;window.fail=reject;});window.gate=new Promise(resolve=>window.release=resolve);window.task=largeLocalWithLease(slot,async lease=>{window.lease=lease;window.ok();await window.gate;},true).catch(e=>{window.fail(e);throw e;});},slot);await page.evaluate(()=>window.ready);}
 async function kill(){const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'});const lines=listing.split('\n').map(x=>x.trim()).filter(x=>x.includes(`--user-data-dir=${profile}`)&&x.includes(executablePath)&&!x.includes('--type='));assert.equal(lines.length,1);const pid=Number(lines[0].split(/\s+/,1)[0]);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){return;}await new Promise(r=>setTimeout(r,100));}throw Error('browser process did not terminate');}
 try{
  let page=await open();await page.evaluate(a=>onAuthed(a,false),auth);await page.locator('#awaitSaveSnapshot').waitFor();
  // Keep the IndexedDB transaction alive after both puts; killing the browser
  // here must roll back both stores, not leave a half-installed baseline.
  await page.evaluate(()=>{const original=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){const result=original.apply(this,args);if(this.name==='sync'){const store=this;const keep=()=>{const request=store.get('__hold_test__');request.onsuccess=keep;};keep();window.midTransaction=true;}return result;};});
  await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>window.midTransaction===true,{timeout:30000});
  const initialSlot=await page.evaluate(()=>accountSlot(AUTH));await kill();page=await open();
  if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.locator('#awaitSaveSnapshot').waitFor();assert.equal(await page.evaluate(slot=>largeReadVerifiedSnapshot(slot),initialSlot),null);
  await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
  const slot=await page.evaluate(()=>accountSlot(AUTH));await kill();page=await open(true);
  if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.locator('#awaitExportSaved').waitFor();
  assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),null);
  const download=page.waitForEvent('download');await page.locator('#awaitExportSaved').click();
  assert.equal(JSON.parse(fs.readFileSync(await (await download).path(),'utf8')).fixtureLarge.length,size);
  // A different account cannot read the first account's saved record.
  assert.equal(await page.evaluate(()=>largeReadVerifiedSnapshot('vocab_v3_a'+'f'.repeat(32))),null);
  const original=await page.evaluate(async slot=>(await largeReadVerifiedSnapshot(slot)).raw,slot);
  await owner(page,slot);await page.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.streak=41;await largeLocalAppend(window.lease,JSON.stringify(value));});
  await kill();page=await open(true);await owner(page,slot);assert.equal(await page.evaluate(()=>JSON.parse(window.lease.raw).streak),41);
  assert(await page.evaluate(async()=>{const orig=IDBObjectStore.prototype.delete;IDBObjectStore.prototype.delete=function(...args){if(this.name==='journals')throw Error('stop after commit');return orig.apply(this,args);};try{await largeLocalFlush(window.lease);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.delete=orig;}}));
  const committed=await page.evaluate(async slot=>(await largeLocalRead(slot)).version,slot);
  await kill();page=await open(true);await owner(page,slot);assert.equal(await page.evaluate(()=>JSON.parse(window.lease.raw).streak),41);
  await page.evaluate(()=>largeLocalFlush(window.lease));
  const result=await page.evaluate(async slot=>{const value=await largeReadVerifiedSnapshot(slot);return {version:value.baseline.version,local:value.baseline.localRaw,streak:JSON.parse(value.raw).streak};},slot);
  assert.equal(result.version,committed);assert.equal(result.local,original);assert.equal(result.streak,41);
  await page.evaluate(()=>window.release());await page.evaluate(()=>window.task);
  console.log('PASS verified large snapshot and synchronized journal survive browser termination with account isolation');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

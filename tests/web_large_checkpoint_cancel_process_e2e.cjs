const {chromium}=require('playwright');const assert=require('assert');const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok){const e=Error(`${path}: ${r.status}`);e.status=r.status;throw e}return r.json()}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size:8*1024*1024+65536});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-checkpoint-cancel-')));let context;
 async function open(){context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});const page=context.pages()[0]||await context.newPage();await page.goto(base);return page}
 async function kill(){const lines=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'}).split('\n').map(x=>x.trim()).filter(x=>x.includes(`--user-data-dir=${profile}`)&&x.includes(executablePath)&&!x.includes('--type='));assert.equal(lines.length,1);const pid=Number(lines[0].split(/\s+/,1)[0]);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;for(let i=0;i<100;i++){try{process.kill(pid,0)}catch{return}await new Promise(r=>setTimeout(r,100))}throw Error('browser did not terminate')}
 try{
  let page=await open();await page.evaluate(a=>onAuthed(a,false),auth);await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
  const slot=await page.evaluate(()=>accountSlot(AUTH));
  await page.locator('#awaitUseSnapshot').click();await page.waitForFunction(()=>!!largeActive&&!largeActive.syncing&&!largeActive.pending);await page.locator('#btnSettings').click();
  await page.route('**/api/v1/me/state/experimental-large-checkpoint',route=>route.fulfill({status:503,json:{detail:'injected checkpoint failure'}}));
  page.once('dialog',d=>d.accept());await page.locator('#bCheckpoint').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('injected checkpoint failure'),null,{timeout:90000});
  const record=await page.evaluate(slot=>largeReadVerifiedRestoreIntent(slot),slot);assert.equal(record.intent.kind,'checkpoint');
  await page.unroute('**/api/v1/me/state/experimental-large-checkpoint');
  await page.evaluate(()=>{window.originalDelete=IDBObjectStore.prototype.delete;IDBObjectStore.prototype.delete=function(...args){if(this.name==='restores')throw Error('injected cancel delete');return window.originalDelete.apply(this,args)}});
  page.once('dialog',d=>d.accept());await page.locator('#awaitCancelCheckpoint').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('injected cancel delete'),null,{timeout:60000});
  assert.equal((await page.evaluate(slot=>largeReadVerifiedRestoreIntent(slot),slot)).intent.batch_id,record.intent.batch_id);
  await page.evaluate(()=>{IDBObjectStore.prototype.delete=window.originalDelete});
  await api('/api/v1/__ui_fixture/delta-hold-response','POST',{});page.once('dialog',d=>d.accept());await page.locator('#awaitCancelCheckpoint').click();
  let held=false;for(let i=0;i<1200;i++){if((await api('/api/v1/__ui_fixture/delta-hold-status')).started){held=true;break}await new Promise(r=>setTimeout(r,100))}assert(held,'cancel response did not reach server');
  await kill();await api('/api/v1/__ui_fixture/delta-release-response','POST',{});page=await open();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);await page.waitForSelector('#awaitCancelCheckpoint');
  page.once('dialog',d=>d.accept());await page.locator('#awaitCancelCheckpoint').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('整理已取消'),null,{timeout:60000});
  assert.equal(await page.evaluate(slot=>largeHasRestoreIntent(slot),slot),false);const after=await page.evaluate(slot=>largeReadVerifiedSnapshot(slot),slot);assert.equal(after.raw,record.previousRaw);assert.equal(after.baseline.revision,record.baseline.revision);
  const intent=record.intent,body={batch_id:intent.batch_id,generation:intent.generation,base_revision:intent.base_revision,restore_epoch:intent.restore_epoch};
  try{await api('/api/v1/me/state/experimental-large-checkpoint','POST',body,seed.token);assert.fail('late checkpoint committed')}catch(e){assert.equal(e.status,409)}
  await page.locator('#awaitUseSnapshot').click();await page.waitForFunction(()=>!!largeActive&&!largeActive.syncing&&!largeActive.pending);
  const synced=await page.evaluate(()=>largeSyncActive(largeActive,true));assert(synced);const latest=await page.evaluate(slot=>largeReadVerifiedSnapshot(slot),slot);
  assert.equal(latest.baseline.revision,String(BigInt(intent.base_revision)+1n));assert.equal(latest.baseline.epoch,intent.restore_epoch);assert.equal(JSON.parse(latest.raw).fixtureLarge.length,8*1024*1024+65536);
  if(process.env.VOCAB_IOS_STAGED_CHECK){const run=require('util').promisify(cp.execFile);const r=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--verify-web-checkpoint-cancel',latest.revision,latest.generation],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000});assert(r.stdout.includes('PASS Swift verifies preserved Web checkpoint cancellation state'))}
  console.log('PASS Web checkpoint cancellation survives storage failure and lost response without discarding progress'+(process.env.VOCAB_IOS_STAGED_CHECK?' with Swift read':''));
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true})}
})().catch(e=>{console.error(e);process.exit(1)});

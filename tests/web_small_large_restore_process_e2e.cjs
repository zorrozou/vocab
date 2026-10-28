const {chromium}=require('playwright');const assert=require('assert');const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json()}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-small-restore-')));let context;
 async function open(){context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});const page=context.pages()[0]||await context.newPage();await page.goto(base);return page}
 async function kill(){const lines=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'}).split('\n').map(x=>x.trim()).filter(x=>x.includes(`--user-data-dir=${profile}`)&&x.includes(executablePath)&&!x.includes('--type='));assert.equal(lines.length,1);const pid=Number(lines[0].split(/\s+/,1)[0]);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;for(let i=0;i<100;i++){try{process.kill(pid,0)}catch{return}await new Promise(r=>setTimeout(r,100))}throw Error('browser did not terminate')}
 try{
  let page=await open();await page.evaluate(a=>onAuthed(a,false),auth);
  await page.waitForFunction(async()=>{if(!AUTH)return false;const slot=accountSlot(AUTH),r=await deltaIDB(slot,'get');return !!r&&!r.pending&&!r.pull&&JSON.stringify(r.local)===localStorage.getItem(slot)},null,{timeout:30000});
  const slot=await page.evaluate(()=>accountSlot(AUTH)),original=await page.evaluate(slot=>localStorage.getItem(slot),slot);
  await page.evaluate(slot=>navigator.locks.request(`vocab-delta:${slot}`,async()=>{}),slot);
  assert(await page.evaluate(async({slot,original})=>{const record=await deltaIDB(slot,'get');await deltaIDB(slot,'put',{...record,pending:false});try{await largeStageSmallRestore(slot,AUTH.userId,AUTH.token,original,original,()=>true);return false}catch(e){return e.message.includes('基线尚未同步')}finally{await deltaIDB(slot,'put',record)}},{slot,original}));
  assert(await page.evaluate(async({slot,original})=>{const old=localStorage.getItem(deltaMarker(slot));localStorage.setItem(deltaMarker(slot),'damaged');try{await largeStageSmallRestore(slot,AUTH.userId,AUTH.token,original,original,()=>true);return false}catch{return true}finally{if(old===null)localStorage.removeItem(deltaMarker(slot));else localStorage.setItem(deltaMarker(slot),old)}},{slot,original}));
  const stageError=await page.evaluate(async({slot,original})=>{const old=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...a){if(this.name==='restores')throw Error('injected intent quota');return old.apply(this,a)};try{await largeStageSmallRestore(slot,AUTH.userId,AUTH.token,original,original,()=>true);return 'unexpected success'}catch(e){return e.message}finally{IDBObjectStore.prototype.put=old}},{slot,original});assert(stageError.includes('injected intent quota'),stageError);
  assert.equal(await page.evaluate(slot=>localStorage.getItem(awaitingServerSlot(slot)),slot),null);assert.equal(await page.evaluate(slot=>largeHasRestoreIntent(slot),slot),false);
  // Kill after the local waiting flag is set but before the strict transaction.
  await page.evaluate(({slot,original})=>{largeLocalOpen=()=>new Promise(()=>{});window.staging=largeStageSmallRestore(slot,AUTH.userId,AUTH.token,original,original,()=>true).catch(()=>{})},{slot,original});
  await page.waitForFunction(slot=>localStorage.getItem(awaitingServerSlot(slot))==='1',slot,{timeout:30000});await kill();
  page=await open();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.waitForFunction(()=>!document.querySelector('#app').inert && document.querySelector('#app .card'),null,{timeout:30000});
  if(await page.evaluate(slot=>!!localStorage.getItem(awaitingServerSlot(slot)),slot)){
    await page.waitForSelector('#awaitReturnLocal');page.once('dialog',d=>d.accept());await page.locator('#awaitReturnLocal').click();await page.waitForFunction(slot=>!localStorage.getItem(awaitingServerSlot(slot)),slot);
  }
  assert.equal(await page.evaluate(slot=>largeHasRestoreIntent(slot),slot),false);
  assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),original);
  const backup=JSON.parse(original);backup.personalizedWeak='w'.repeat(8*1024*1024+65536);backup.cards.web_restore={pos:88,stage:1};
  await page.locator('#btnSettings').click();
  // Failure while deleting the old delta database happens after staging: both
  // copies and the immutable restore intent must remain recoverable.
  await page.evaluate(()=>{window.originalDeltaIDB=deltaIDB;deltaIDB=async(...a)=>{if(a[1]==='delete')throw Error('injected old delta delete');return window.originalDeltaIDB(...a)}});
  page.once('dialog',d=>d.accept());await page.locator('#bImport').setInputFiles({name:'large.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(backup))});
  await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('injected old delta delete'),null,{timeout:90000});
  assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),original);
  assert(await page.evaluate(slot=>largeHasRestoreIntent(slot),slot));assert(await page.evaluate(slot=>largeReadRestoreTransition(slot),slot));
  assert(await page.evaluate(async slot=>(await deltaIDB(slot,'get'))!==undefined,slot));
  await page.evaluate(()=>{deltaIDB=window.originalDeltaIDB});
  // An old page editing the source prevents migration; no old data is deleted.
  await page.evaluate(({slot,original})=>localStorage.setItem(slot,original+' '),{slot,original});
  await page.locator('#awaitRetryRestore').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('旧存档或同步记录已变化'),null,{timeout:30000});
  assert(await page.evaluate(async slot=>(await deltaIDB(slot,'get'))!==undefined,slot));
  await page.evaluate(({slot,original})=>{localStorage.setItem(slot,original);window.originalRemove=Storage.prototype.removeItem;Storage.prototype.removeItem=function(key){if(key===slot)throw Error('injected slot delete');return window.originalRemove.call(this,key)}},{slot,original});
  await page.locator('#awaitRetryRestore').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('injected slot delete'),null,{timeout:30000});
  assert.equal(await page.evaluate(slot=>deltaIDB(slot,'get'),slot),undefined);assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),original);
  await page.evaluate(slot=>{Storage.prototype.removeItem=window.originalRemove;localStorage.removeItem(awaitingServerSlot(slot))},slot);
  await kill();page=await open();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.waitForSelector('#awaitRetryRestore');assert.equal(await page.evaluate(slot=>localStorage.getItem(awaitingServerSlot(slot)),slot),'1');
  await api('/api/v1/__ui_fixture/delta-hold-response','POST',{});await page.locator('#awaitRetryRestore').click();
  let held=false;for(let i=0;i<1200;i++){if((await api('/api/v1/__ui_fixture/delta-hold-status')).started){held=true;break}await new Promise(r=>setTimeout(r,100))}assert(held,'server did not commit restore');
  assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),null);assert.equal(await page.evaluate(slot=>deltaIDB(slot,'get'),slot),undefined);
  await kill();await api('/api/v1/__ui_fixture/delta-release-response','POST',{});page=await open();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.waitForSelector('#awaitRetryRestore');await page.locator('#awaitRetryRestore').click();
  await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('恢复结果及恢复前备份已保存'),null,{timeout:120000});
  assert.equal(await page.evaluate(slot=>largeHasRestoreIntent(slot),slot),false);assert.equal(await page.evaluate(slot=>largeReadRestoreTransition(slot),slot),undefined);
  const result=await page.evaluate(slot=>largeReadVerifiedSnapshot(slot),slot);assert.equal(result.baseline.epoch,1);assert.equal(JSON.parse(result.raw).cards.web_restore.pos,88);
  assert.equal((await page.evaluate(slot=>largeReadLatestRestoreBackup(slot),slot)).raw,original);
  if(process.env.VOCAB_IOS_STAGED_CHECK){const run=require('util').promisify(cp.execFile);const r=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--verify-web-restore',result.revision,result.generation],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000});assert(r.stdout.includes('PASS Swift verifies Web large restore'))}
  // A differing old slot may contain another page's edits and must survive.
  await page.evaluate(({slot,original})=>{localStorage.setItem(slot,original+' ');localStorage.setItem(deltaMarker(slot),'1');},{slot,original});
  await page.reload();await page.waitForSelector('#awaitUseSnapshot');
  assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),original+' ');
  // An exact copy of the durable pre-restore backup is a stale slot after a
  // lost localStorage deletion; reintroduce it deterministically and reload.
  await page.evaluate(({slot,original})=>{localStorage.setItem(slot,original);localStorage.setItem(deltaMarker(slot),'1');},{slot,original});
  await page.reload();await page.waitForSelector('#awaitUseSnapshot');
  assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),null);
  // The installed primary, not a localStorage flag or stale main cache, is
  // authoritative even after the intent has been cleared.
  await page.evaluate(slot=>localStorage.removeItem(awaitingServerSlot(slot)),slot);await kill();page=await open();
  if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.waitForSelector('#awaitUseSnapshot');assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),null);
  assert.equal(await page.evaluate(slot=>localStorage.getItem(awaitingServerSlot(slot)),slot),'1');
  await page.locator('#awaitUseSnapshot').click();await page.waitForFunction(()=>!!largeActive);assert.equal(await page.evaluate(()=>S.cards.web_restore.pos),88);
  console.log('PASS small account migrates and restores after process interruption'+(process.env.VOCAB_IOS_STAGED_CHECK?' with Swift read':''));
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true})}
})().catch(e=>{console.error(e);process.exit(1)});

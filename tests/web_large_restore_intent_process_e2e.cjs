const {chromium}=require('playwright');const assert=require('assert');const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json()}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size:8*1024*1024+65536});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-restore-intent-')));let context;
 async function open(){context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});const page=context.pages()[0]||await context.newPage();await page.goto(base);return page}
 async function kill(){const lines=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'}).split('\n').map(x=>x.trim()).filter(x=>x.includes(`--user-data-dir=${profile}`)&&x.includes(executablePath)&&!x.includes('--type='));assert.equal(lines.length,1);const pid=Number(lines[0].split(/\s+/,1)[0]);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;for(let i=0;i<100;i++){try{process.kill(pid,0)}catch{return}await new Promise(r=>setTimeout(r,100))}throw Error('browser did not terminate')}
 try{
  let page=await open();await page.evaluate(a=>onAuthed(a,false),auth);
  await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
  const slot=await page.evaluate(()=>accountSlot(AUTH));
  await page.evaluate(slot=>{window.ready=new Promise((resolve,reject)=>{window.ok=resolve;window.fail=reject});window.gate=new Promise(resolve=>window.release=resolve);window.task=largeLocalWithLease(slot,async lease=>{window.lease=lease;window.ok();await window.gate},true).catch(e=>{window.fail(e);throw e})},slot);await page.evaluate(()=>window.ready);
  // A failed strict transaction must not leave a fence or poison the lease.
  assert(await page.evaluate(async()=>{const old=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...a){if(this.name==='restores')throw Error('injected quota');return old.apply(this,a)};try{await largeStageRestoreIntent(window.lease,AUTH.userId,AUTH.token,window.lease.raw,()=>true);return false}catch(e){return e.message.includes('injected quota')}finally{IDBObjectStore.prototype.put=old}}));
  assert.equal(await page.evaluate(async slot=>await largeReadRawRestoreIntent(slot),slot),null);assert.equal(await page.evaluate(()=>!!window.lease.restoring),false);
  assert(await page.evaluate(async()=>{try{await largeStageRestoreIntent(window.lease,AUTH.userId,AUTH.token,window.lease.raw,()=>false);return false}catch{return true}}));
  assert(await page.evaluate(async()=>{try{await largeStageRestoreIntent(window.lease,AUTH.userId,AUTH.token,window.lease.raw+' ',()=>true);return false}catch{return true}}));
  assert(await page.evaluate(async slot=>{await deltaIDB(slot,'put',null);try{await largeStageRestoreIntent(window.lease,AUTH.userId,AUTH.token,window.lease.raw,()=>true);return false}catch(e){return e.message.includes('旧版待同步记录')}finally{await deltaIDB(slot,'delete')}},slot));
  assert.equal(await page.evaluate(async slot=>await largeReadRawRestoreIntent(slot),slot),null);
  // If the page changes after asynchronous hashing but before the strict
  // transaction, no recovery record may be committed.
  assert(await page.evaluate(async()=>{let calls=0;try{await largeStageRestoreIntent(window.lease,AUTH.userId,AUTH.token,window.lease.raw,()=>++calls<3);return false}catch{return true}}));
  assert.equal(await page.evaluate(async slot=>await largeReadRawRestoreIntent(slot),slot),null);
  assert.equal(await page.evaluate(()=>!!window.lease.restoring),false);
  const competitor=await context.newPage();await competitor.goto(base);
  assert(await competitor.evaluate(async slot=>{try{await largeLocalWithLease(slot,async()=>{},true);return false}catch{return true}},slot));
  await competitor.evaluate(slot=>{window.lockReady=new Promise(resolve=>window.lockAcquired=resolve);window.lockGate=new Promise(resolve=>window.unlock=resolve);window.lockTask=navigator.locks.request(`vocab-delta:${slot}`,async()=>{window.lockAcquired();await window.lockGate})},slot);
  await competitor.evaluate(()=>window.lockReady);
  assert(await page.evaluate(async()=>{try{await largeStageRestoreIntent(window.lease,AUTH.userId,AUTH.token,window.lease.raw,()=>true);return false}catch(e){return e.message.includes('正在同步')}}));
  assert.equal(await page.evaluate(async slot=>await largeReadRawRestoreIntent(slot),slot),null);
  await competitor.evaluate(()=>window.unlock());await competitor.evaluate(()=>window.lockTask);await competitor.close();
  const staged=await page.evaluate(async()=>{const target=JSON.parse(window.lease.raw);target.cards.web_restore={pos:88,stage:1};const payload=JSON.stringify(target);const record=await largeStageRestoreIntent(window.lease,AUTH.userId,AUTH.token,payload,()=>true);return {batch:record.intent.batch_id,sha:record.intent.sha256,previous:record.previousSha256}});
  assert(await page.evaluate(async()=>{const next=JSON.parse(window.lease.raw);next.settings.newPerDay=25;try{await largeLocalAppend(window.lease,JSON.stringify(next));return false}catch{return true}}));
  assert(await page.evaluate(async slot=>{try{await largeJournalReplace(slot,null,null);return false}catch{return true}},slot));
  assert(await page.evaluate(async slot=>{try{await runDeltaMutation(slot,async()=>{throw Error('action must not run')},()=>{});return false}catch(e){return e.message.includes('未完成的大状态恢复')}},slot));
  assert(await page.evaluate(async slot=>{try{await clearDeltaState(slot);return false}catch(e){return e.message.includes('未完成的大状态恢复')}},slot));
  assert(await page.evaluate(async slot=>{try{const current=await largeLocalRead(slot);await largeLocalWrite(slot,current,current.raw);return false}catch{return true}},slot));
  assert(await page.evaluate(async()=>{try{await largeSyncedPull(window.lease,AUTH.userId,AUTH.token);return false}catch{return true}}));
  assert(await page.evaluate(async slot=>{try{await deltaPull(AUTH.userId,AUTH.token,slot,()=>true,true);return false}catch(e){return e.message.includes('未完成的大状态恢复')}},slot));
  const other='vocab_v3_a'+'f'.repeat(32);assert.equal(await page.evaluate(slot=>largeReadRawRestoreIntent(slot),other),null);
  // Even if the weaker localStorage waiting flag is lost, startup must inspect
  // the durable intent before restoring a normal account session.
  await page.evaluate(slot=>localStorage.removeItem(awaitingServerSlot(slot)),slot);
  await kill();page=await open();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.waitForSelector('#awaitRetryRestore');assert.equal(await page.evaluate(slot=>localStorage.getItem(awaitingServerSlot(slot)),slot),'1');
  const restored=await page.evaluate(async slot=>{const r=await largeReadVerifiedRestoreIntent(slot);return {batch:r.intent.batch_id,sha:r.intent.sha256,previous:r.previousSha256}},slot);assert.deepEqual(restored,staged);
  assert(await page.evaluate(async slot=>{try{await largeLocalWithLease(slot,async()=>{},true);return false}catch(e){return e.message.includes('未完成的大状态恢复')}},slot));
  const raw=await page.evaluate(slot=>largeReadRawSnapshot(slot),slot);assert.equal(raw.restores.intent.batch_id,staged.batch);
  assert(await page.evaluate(slot=>largeHasRestoreIntent(slot),slot),'intent existence lookup failed');
  await page.locator('#awaitRetry').click();try{await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('未完成的大状态恢复'),null,{timeout:10000})}catch(e){throw Error('retry did not report restore fence: '+JSON.stringify(await page.evaluate(()=>({message:document.querySelector('#awaitMsg')?.textContent,auth:!!AUTH,awaiting:localStorage.getItem(awaitingServerSlot(accountSlot(AUTH)))}))))}
  assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),null);
  await api('/api/v1/__ui_fixture/delta-hold-response','POST',{});
  await page.evaluate(async slot=>{const saved=await largeReadVerifiedRestoreIntent(slot);window.restoreAttempt=deltaSubmitLargeRestore(saved.intent,AUTH.userId,AUTH.token,slot).catch(()=>null)},slot);
  let held=false;for(let i=0;i<1200;i++){if((await api('/api/v1/__ui_fixture/delta-hold-status')).started){held=true;break}await new Promise(r=>setTimeout(r,100))}
  assert(held,'server did not commit durable intent');await kill();await api('/api/v1/__ui_fixture/delta-release-response','POST',{});
  page=await open();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  const receipt=await page.evaluate(async slot=>{const saved=await largeReadVerifiedRestoreIntent(slot);return deltaSubmitLargeRestore(saved.intent,AUTH.userId,AUTH.token,slot)},slot);
  assert.equal(receipt.batch_id,staged.batch);assert.equal(receipt.restore_epoch,1);
  const again=await page.evaluate(async slot=>{const saved=await largeReadVerifiedRestoreIntent(slot);return deltaSubmitLargeRestore(saved.intent,AUTH.userId,AUTH.token,slot)},slot);assert.deepEqual(again,receipt);
  if(process.env.VOCAB_IOS_STAGED_CHECK){const run=require('util').promisify(cp.execFile);const result=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--verify-web-restore',receipt.state_revision,receipt.generation],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000});assert(result.stdout.includes('PASS Swift verifies Web large restore'))}
  assert(await page.evaluate(async slot=>{try{await largeLocalWithLease(slot,async()=>{},true);return false}catch{return true}},slot));
  // A corrupt intent remains exportable, but cannot be trusted or reopened.
  await page.evaluate(async slot=>{const db=await largeLocalOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('restores','readwrite',{durability:'strict'}),store=tx.objectStore('restores'),r=store.get(slot);r.onsuccess=()=>store.put({...r.result,intent:{...r.result.intent,sha256:'0'.repeat(64)}},slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error)});db.close()},slot);
  assert(await page.evaluate(async slot=>{try{await largeReadVerifiedRestoreIntent(slot);return false}catch{return true}},slot));
  assert.equal((await page.evaluate(slot=>largeReadRawRestoreIntent(slot),slot)).intent.sha256,'0'.repeat(64));
  assert(await page.evaluate(async slot=>{try{await largeLocalWithLease(slot,async()=>{},true);return false}catch{return true}},slot));
  await page.evaluate(async slot=>{const db=await largeLocalOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('restores','readwrite',{durability:'strict'});tx.objectStore('restores').put(null,slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error)});db.close()},slot);
  assert(await page.evaluate(slot=>largeHasRestoreIntent(slot),slot),'null corruption must retain the fence');
  await page.locator('#awaitRetry').click();try{await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('未完成的大状态恢复'),null,{timeout:10000})}catch(e){throw Error('retry did not report restore fence: '+JSON.stringify(await page.evaluate(()=>({message:document.querySelector('#awaitMsg')?.textContent,auth:!!AUTH,awaiting:localStorage.getItem(awaitingServerSlot(accountSlot(AUTH)))}))))}
  assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),null);
  // Restore the exact saved record, then test the actual locked installation.
  await page.evaluate(async ({slot,record})=>{const db=await largeLocalOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('restores','readwrite',{durability:'strict'});tx.objectStore('restores').put(record,slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error)});db.close()},{slot,record:raw.restores});
  assert(await page.evaluate(async slot=>{const original=deltaRequest;deltaRequest=async(...args)=>{const value=await original(...args);if(args[0]==='/api/v1/me/state/snapshots?representation=stored')return {...value,state_revision:String(BigInt(value.state_revision)+1n)};return value};try{await largeRetryRestore(slot,AUTH.userId,AUTH.token,()=>true);return false}catch(e){return e.message.includes('服务器进度已变化')}finally{deltaRequest=original}},slot));
  assert.equal((await page.evaluate(slot=>largeReadRawRestoreIntent(slot),slot)).intent.batch_id,staged.batch);
  assert(await page.evaluate(async slot=>{const old=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='migrations')throw Error('injected backup quota');return old.apply(this,args)};try{await largeRetryRestore(slot,AUTH.userId,AUTH.token,()=>true);return false}catch(e){return e.message.includes('injected backup quota')}finally{IDBObjectStore.prototype.put=old}},slot));
  assert.equal((await page.evaluate(slot=>largeReadRawRestoreIntent(slot),slot)).intent.batch_id,staged.batch);
  assert.equal((await page.evaluate(slot=>largeReadVerifiedSnapshot(slot),slot)).primary.sha256,staged.previous);
  await page.locator('#awaitRetryRestore').click();
  await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('恢复结果及恢复前备份已保存'),null,{timeout:90000});
  assert.equal(await page.evaluate(slot=>largeHasRestoreIntent(slot),slot),false);
  const verified=await page.evaluate(slot=>largeReadVerifiedSnapshot(slot),slot);
  assert.equal(verified.baseline.revision,receipt.state_revision);assert.equal(verified.baseline.epoch,1);assert.equal(JSON.parse(verified.raw).cards.web_restore.pos,88);
  const backup=await page.evaluate(async({slot,batch})=>{const db=await largeLocalOpen();try{return await new Promise((resolve,reject)=>{const tx=db.transaction('migrations','readonly'),r=tx.objectStore('migrations').get(`restore-backup:${slot}:${batch}`);tx.oncomplete=()=>resolve(r.result);tx.onabort=tx.onerror=()=>reject(tx.error)})}finally{db.close()}},{slot,batch:staged.batch});
  assert.equal(backup.sha256,staged.previous);assert.equal((await page.evaluate(raw=>largeLocalDigest(raw),backup.raw)).sha256,staged.previous);
  assert.equal((await page.evaluate(slot=>largeReadLatestRestoreBackup(slot),slot)).batch,staged.batch);
  await page.locator('#awaitUseSnapshot').click();await page.waitForFunction(()=>!!largeActive);
  await page.locator('#btnSettings').click();
  const downloadPromise=page.waitForEvent('download');await page.locator('#bExportPrevious').click();const download=await downloadPromise;
  const exported=JSON.parse(fs.readFileSync(await download.path(),'utf8'));assert(!exported.cards.web_restore);
  assert(await page.evaluate(()=>{try{rejectDuplicateBackupKeys('{"a":1,"\\u0061":2}');return false}catch(e){return e.message.includes('重复字段')}}));
  assert(await page.evaluate(()=>{try{rejectDuplicateBackupKeys('{"a":{"x":1,"x":2}}');return false}catch(e){return e.message.includes('重复字段')}}));
  assert(await page.evaluate(()=>{rejectDuplicateBackupKeys(' { "a": [ { "x": "\\\"" }, 1, true, null ] } ');return true}));
  await page.waitForFunction(()=>largeActive&&!largeActive.syncing&&!largeActive.pending&&!localSaveFailed);
  await api('/api/v1/__ui_fixture/delta-hold-response','POST',{});
  page.once('dialog',dialog=>dialog.accept());
  await page.locator('#bImport').setInputFiles(await download.path());
  held=false;for(let i=0;i<1200;i++){if((await api('/api/v1/__ui_fixture/delta-hold-status')).started){held=true;break}await new Promise(r=>setTimeout(r,100))}
  assert(held,'user-initiated restore did not reach server commit');await kill();await api('/api/v1/__ui_fixture/delta-release-response','POST',{});
  page=await open();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.locator('#awaitRetryRestore').click();
  await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('恢复结果及恢复前备份已保存'),null,{timeout:120000});
  const second=await page.evaluate(slot=>largeReadVerifiedSnapshot(slot),slot);
  assert.equal(second.baseline.epoch,2);assert(!JSON.parse(second.raw).cards.web_restore);
  const secondBackup=await page.evaluate(slot=>largeReadLatestRestoreBackup(slot),slot);
  assert.equal(JSON.parse(secondBackup.raw).cards.web_restore.pos,88);
  if(process.env.VOCAB_IOS_STAGED_CHECK){const run=require('util').promisify(cp.execFile);const result=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--verify-web-restore-removed',second.revision,second.generation],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000});assert(result.stdout.includes('PASS Swift verifies Web file restore after browser restart'))}
  console.log('PASS durable Web restore intent survives process termination and fences writes');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true})}
})().catch(e=>{console.error(e);process.exit(1)});

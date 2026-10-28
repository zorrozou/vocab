const {chromium}=require('playwright');const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();}
async function owner(page,slot){await page.evaluate(slot=>{window.ready=new Promise((resolve,reject)=>{window.ok=resolve;window.fail=reject;});window.gate=new Promise(resolve=>window.release=resolve);window.task=largeLocalWithLease(slot,async lease=>{window.lease=lease;window.ok();await window.gate;},true).catch(e=>{window.fail(e);throw e;});},slot);await page.evaluate(()=>window.ready);}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size:8*1024*1024+65536});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const context=await browser.newContext(),a=await context.newPage();await a.goto(base);await a.evaluate(x=>onAuthed(x,false),auth);await a.locator('#awaitSaveSnapshot').click();await a.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
  const slot=await a.evaluate(()=>accountSlot(AUTH));await owner(a,slot);
  await a.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.cards.banana={pos:2,stage:1,due:'2099-01-01T00:00:00Z'};await largeLocalAppend(window.lease,JSON.stringify(value));});
  let lost=false;await a.route('**/api/v1/me/state/experimental-large-deltas',async route=>{const response=await route.fetch();assert.equal(response.status(),200);lost=true;await route.abort();});
  const error=await a.evaluate(async()=>{try{await largeSyncedPush(window.lease,AUTH.userId,AUTH.token);return '';}catch(e){return e.message;}});
  assert(lost,'server did not commit: '+error);
  const pending=await a.evaluate(async slot=>(await largeReadRawSnapshot(slot)).uploads,slot);assert.equal(pending.pending.experimentalLarge,true);const batch=pending.pending.batch.batch_id;
  await a.close();const b=await context.newPage();await b.goto(base);await owner(b,slot);assert(await b.evaluate(()=>!!JSON.parse(window.lease.raw).cards.banana));
  await b.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.cards.cherry={pos:3,stage:1,due:'2099-01-01T00:00:00Z'};await largeLocalAppend(window.lease,JSON.stringify(value));});
  assert.equal(await b.evaluate(()=>largeSyncedPush(window.lease,AUTH.userId,AUTH.token)),false,'newer local edit is not yet uploaded');
  const mid=await b.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {local:Object.keys(JSON.parse(x.baseline.localRaw).cards),base:Object.keys(JSON.parse(x.baseline.baseRaw).cards),revision:x.revision,upload:(await largeReadRawSnapshot(slot)).uploads};},slot);
  assert(mid.local.includes('banana')&&!mid.local.includes('cherry'));assert(mid.base.includes('banana')&&!mid.base.includes('cherry'));assert.equal(mid.upload,null);
  assert.equal(await b.evaluate(()=>largeSyncedPush(window.lease,AUTH.userId,AUTH.token)),true);
  const final=await b.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {local:Object.keys(JSON.parse(x.baseline.localRaw).cards),base:Object.keys(JSON.parse(x.baseline.baseRaw).cards),revision:x.revision,upload:(await largeReadRawSnapshot(slot)).uploads};},slot);
  assert(final.local.includes('cherry'));assert(final.base.includes('cherry'));assert.equal(final.upload,null);assert.equal(BigInt(final.revision),BigInt(mid.revision)+1n);assert.equal(batch.length,32);
  const snapshot=await api('/api/v1/me/state/snapshots?representation=stored','POST',{},seed.token);assert.equal(snapshot.state_revision,final.revision);
  // Server commit succeeds but the local acknowledgement transaction fails.
  await b.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.cards.date={pos:4,stage:1,due:'2099-01-01T00:00:00Z'};await largeLocalAppend(window.lease,JSON.stringify(value));await largeLocalFlush(window.lease);});
  assert(await b.evaluate(async()=>{const orig=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='sync')throw Error('ack quota');return orig.apply(this,args);};try{await largeSyncedPush(window.lease,AUTH.userId,AUTH.token);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=orig;}}));
  const unacknowledged=await b.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {revision:x.revision,pending:(await largeReadRawSnapshot(slot)).uploads};},slot);
  assert.equal(unacknowledged.revision,final.revision);assert(unacknowledged.pending?.pending?.batch?.batch_id);
  assert.equal(await b.evaluate(()=>largeSyncedPush(window.lease,AUTH.userId,AUTH.token)),true);
  let afterAck=await b.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {revision:x.revision,generation:x.generation,epoch:x.baseline.epoch};},slot);
  assert.equal(BigInt(afterAck.revision),BigInt(final.revision)+1n);
  // Accumulate bounded edits, then send their combined >2 MiB delta in parts.
  await b.evaluate(async()=>{for(let group=0;group<6;group++){const value=JSON.parse(window.lease.raw);for(let i=0;i<10;i++)value.cards['bulk_'+String(group*10+i).padStart(3,'0')]={pos:100+group*10+i,stage:1,extra:'x'.repeat(40000)};await largeLocalAppend(window.lease,JSON.stringify(value));await largeLocalFlush(window.lease);}});
  let stagedLost=false;
  await b.route('**/api/v1/me/state/delta-stages/*/experimental-large-commit',async route=>{const response=await route.fetch();assert.equal(response.status(),200);stagedLost=true;await route.abort();});
  await b.evaluate(async()=>{try{await largeSyncedPush(window.lease,AUTH.userId,AUTH.token);}catch(_){}});assert(stagedLost);
  const staged=await b.evaluate(async slot=>(await largeReadRawSnapshot(slot)).uploads.pending,slot);assert(staged.staged&&staged.experimentalLarge);
  await b.unroute('**/api/v1/me/state/delta-stages/*/experimental-large-commit');assert.equal(await b.evaluate(()=>largeSyncedPush(window.lease,AUTH.userId,AUTH.token)),true);
  const afterStage=await b.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {revision:x.revision,generation:x.generation,epoch:x.baseline.epoch,found:!!JSON.parse(x.baseline.baseRaw).cards.bulk_059};},slot);
  assert(afterStage.found);assert.equal(BigInt(afterStage.revision),BigInt(afterAck.revision)+1n);afterAck=afterStage;
  // A non-cooperating writer corrupts primary metadata after server commit.
  // The receipt must remain pending until the exact prior record is restored.
  await b.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.cards.grape={pos:5,stage:1,due:'2099-01-01T00:00:00Z'};await largeLocalAppend(window.lease,JSON.stringify(value));await largeLocalFlush(window.lease);});
  let corrupted=false;
  await b.route('**/api/v1/me/state/experimental-large-deltas',async route=>{const response=await route.fetch();assert.equal(response.status(),200);
   await b.evaluate(async slot=>{const db=await largeLocalOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('slots','readwrite'),store=tx.objectStore('slots'),req=store.get(slot);req.onsuccess=()=>{window.goodPrimary=req.result;store.put({...req.result,length:req.result.length+1},slot);};tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},slot);corrupted=true;await route.fulfill({response});});
  assert(await b.evaluate(async()=>{try{await largeSyncedPush(window.lease,AUTH.userId,AUTH.token);return false;}catch(_){return true;}}));assert(corrupted);
  assert((await b.evaluate(async slot=>(await largeReadRawSnapshot(slot)).uploads,slot)).pending);
  await b.unroute('**/api/v1/me/state/experimental-large-deltas');
  await b.evaluate(async slot=>{const db=await largeLocalOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('slots','readwrite');tx.objectStore('slots').put(window.goodPrimary,slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},slot);
  assert.equal(await b.evaluate(()=>largeSyncedPush(window.lease,AUTH.userId,AUTH.token)),true);
  const afterRepair=await b.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {revision:x.revision,generation:x.generation,epoch:x.baseline.epoch};},slot);
  assert.equal(BigInt(afterRepair.revision),BigInt(afterAck.revision)+1n);afterAck=afterRepair;
  if(process.env.VOCAB_IOS_STAGED_CHECK){
   const run=require('util').promisify(require('child_process').execFile);
   const swift=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--large-web-interop',auth.user.account_id],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000,maxBuffer:1024*1024});
   assert(swift.stdout.includes('PASS Swift uploads into Web-origin large state'));
   const downloaded=await b.evaluate(async slot=>{const value=await largeReadVerifiedSnapshot(slot),baseline=value.baseline;
    const result=await deltaReadThrough({base:JSON.parse(baseline.baseRaw),revision:baseline.revision,generation:baseline.generation,epoch:baseline.epoch},AUTH.token);
    return {found:!!result.base.cards.swift_large,size:result.base.fixtureLarge.length};},slot);
   assert(downloaded.found&&downloaded.size>8*1024*1024);
  }else{
   const competing={generation:afterAck.generation,base_revision:afterAck.revision,restore_epoch:afterAck.epoch,
     batch_id:require('crypto').randomUUID().replaceAll('-',''),ops:[{op:'set',path:['cards','elder'],value:{pos:8,stage:1,due:'2099-01-01T00:00:00Z'}}]};
   await api('/api/v1/me/state/experimental-large-deltas','POST',competing,seed.token);
  }
  await b.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.cards.fig={pos:9,stage:1,due:'2099-01-01T00:00:00Z'};await largeLocalAppend(window.lease,JSON.stringify(value));});
  const conflict=await b.evaluate(async()=>{try{await largeSyncedPush(window.lease,AUTH.userId,AUTH.token);return null;}catch(e){return {status:e.status,code:e.code};}});
  assert.equal(conflict.status,409);
  const retained=await b.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {local:!!JSON.parse(x.raw).cards.fig,pending:(await largeReadRawSnapshot(slot)).uploads,revision:x.revision};},slot);
  assert(retained.local);assert(retained.pending.pending.experimentalLarge);assert.equal(retained.revision,afterAck.revision);
  await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:false});
  const disabled=await b.evaluate(async()=>{try{await largeSyncedPush(window.lease,AUTH.userId,AUTH.token);return null;}catch(e){return e.status;}});assert.equal(disabled,404);
  assert.equal(await b.evaluate(async slot=>(await largeReadRawSnapshot(slot)).uploads.pending.batch.batch_id,slot),retained.pending.pending.batch.batch_id);
  await b.evaluate(()=>window.release());await b.evaluate(()=>window.task);
  console.log('PASS large local journal uploads, retries lost receipt and preserves later offline edit');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

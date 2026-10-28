const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(url,method='GET',body){const r=await fetch(base+url,{method,headers:{'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${url}: ${r.status}`);return r.json();}
async function wait(page,condition){for(let i=0;i<400;i++){if(await page.evaluate(condition))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
async function bounded(p){let t;try{return await Promise.race([p,new Promise((_,reject)=>t=setTimeout(()=>reject(Error('migration gate timed out')),20000))]);}finally{clearTimeout(t);}}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-normal-migration-')));let context;
 try{
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});let a=context.pages()[0]||await context.newPage(),b=await context.newPage();await Promise.all([a.goto(base),b.goto(base)]);
  await a.evaluate(value=>onAuthed(value,false),auth);await wait(a,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  const slot=await a.evaluate(()=>accountSlot(AUTH));
  const source=await a.evaluate(()=>{S.cards.pear={pos:3};save();clearTimeout(save._t);if(localSaveFailed)throw Error('local save failed');return localStorage.getItem(accountSlot(AUTH));});
  const legacy=await a.evaluate(()=>deltaIDB(accountSlot(AUTH),'get'));
  // Another page changing the old slot while a candidate is staged must abort.
  await a.evaluate(()=>{window.realNormalOpen=normalDurableOpen;window.migrationStarted=new Promise(r=>window.signalMigration=r);window.migrationGate=new Promise(r=>window.releaseMigration=r);
   normalDurableOpen=async()=>{const db=await window.realNormalOpen();window.signalMigration();await window.migrationGate;return db;};});
  const racing=a.evaluate(()=>normalMigrationStage(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true)).then(()=>false,()=>true);
  await bounded(a.evaluate(()=>window.migrationStarted));await b.evaluate(({slot,source})=>localStorage.setItem(slot,source+' '),{slot,source});
  await a.evaluate(()=>window.releaseMigration());assert(await racing);
  await a.evaluate(({slot,source})=>{normalDurableOpen=window.realNormalOpen;localStorage.setItem(slot,source);},{slot,source});
  assert.equal(await a.evaluate(slot=>normalMigrationReadRaw(slot),slot),undefined);
  // A failed transaction cannot create a candidate or alter the old slot.
  assert(await a.evaluate(async()=>{const original=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(){throw Error('injected failure');};
   try{await normalMigrationStage(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=original;}}));
  assert.equal(await a.evaluate(slot=>normalMigrationReadRaw(slot),slot),undefined);assert.equal(await a.evaluate(slot=>localStorage.getItem(slot),slot),source);
  const staged=await a.evaluate(()=>normalMigrationStage(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));
  const candidate=await a.evaluate(slot=>normalMigrationRead(slot),slot);
  assert.equal(candidate.record.id,staged.id);assert.equal(candidate.value.sourceRaw,source);assert.deepEqual(candidate.value.legacy,legacy);assert.equal(candidate.value.clocks.dirty,'1');
  assert.equal(await a.evaluate(slot=>normalDurableRead(slot),slot),null);assert.equal(await a.evaluate(slot=>localStorage.getItem(slot),slot),source);
  assert(await a.evaluate(async()=>{try{await normalMigrationStage(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true);return false;}catch(_){return true;}}));
  assert(await a.evaluate(async()=>{const original=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='sync')throw Error('injected failure');return original.apply(this,args);};try{await normalMigrationPrepare(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=original;}}));
  assert.equal(await a.evaluate(slot=>normalDurableRead(slot),slot),null);
  const prepared=await a.evaluate(()=>normalMigrationPrepare(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));
  assert.equal(prepared.raw,source);assert.equal(prepared.dirty,true);
  assert.deepEqual(prepared.fence,{generation:legacy.generation,revision:legacy.revision,epoch:legacy.epoch});
  assert.deepEqual(await a.evaluate(()=>normalMigrationPrepare(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true)),prepared);
  const preparedSet=await a.evaluate(slot=>normalMigrationReadPrepared(slot),slot);
  assert.deepEqual(preparedSet.primary,prepared);assert.deepEqual(preparedSet.sync.legacy,legacy);assert.equal(preparedSet.sync.version,prepared.version);
  assert(await a.evaluate(async({slot,prepared})=>{try{await normalDurableWrite(slot,prepared,prepared.raw,prepared.fence,true);return false;}catch(_){return true;}},{slot,prepared}));
  // A pre-upgrade prepared primary without the new sync record is incomplete;
  // only explicit re-preparation from unchanged legacy evidence may repair it.
  await a.evaluate(async slot=>{const db=await normalDurableOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('sync','readwrite');tx.objectStore('sync').delete(slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},slot);
  assert(await a.evaluate(async slot=>{try{await normalMigrationReadPrepared(slot);return false;}catch(_){return true;}},slot));
  assert.deepEqual(await a.evaluate(()=>normalMigrationPrepare(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true)),prepared);
  assert.deepEqual(await a.evaluate(slot=>normalMigrationReadPrepared(slot),slot),preparedSet);
  // A partial write of primary plus bound sync must roll back atomically.
  assert(await a.evaluate(async({slot,preparedSet})=>{const original=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='sync')throw Error('injected failure');return original.apply(this,args);};try{const state=JSON.parse(preparedSet.primary.raw);state.cards.pear.pos=4;await normalMigrationWritePrepared(slot,preparedSet,JSON.stringify(state));return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=original;}},{slot,preparedSet}));
  assert.deepEqual(await a.evaluate(slot=>normalMigrationReadPrepared(slot),slot),preparedSet);
  const attempts=await Promise.all([a,b].map((p,i)=>p.evaluate(async({slot,preparedSet,i})=>{const state=JSON.parse(preparedSet.primary.raw);state.cards.pear.pos=10+i;try{return {value:await normalMigrationWritePrepared(slot,preparedSet,JSON.stringify(state))};}catch(e){return {error:e.message};}},{slot,preparedSet,i})));
  assert.equal(attempts.filter(x=>x.value).length,1);assert.equal(attempts.filter(x=>x.error).length,1);
  const savedSet=attempts.find(x=>x.value).value;
  assert.equal(savedSet.primary.dirty,true);assert.equal(savedSet.primary.version,savedSet.sync.version);
  assert.deepEqual(savedSet.candidate,candidate);assert.deepEqual(savedSet.sync.legacy,legacy);
  assert.equal(await a.evaluate(slot=>localStorage.getItem(slot),slot),source);
  assert.deepEqual(await a.evaluate(slot=>deltaIDB(slot,'get'),slot),legacy);
  const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'}),matches=listing.split('\n').map(line=>line.trim()).filter(line=>line.includes(`--user-data-dir=${profile}`)&&line.includes(executablePath)&&!line.includes('--type='));
  assert.equal(matches.length,1);const pid=Number(matches[0].split(/\s+/,1)[0]);assert(Number.isInteger(pid)&&pid>1);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;
  for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){break;}await new Promise(r=>setTimeout(r,100));}
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});a=context.pages()[0]||await context.newPage();await a.goto(base);
  const recovered=await a.evaluate(slot=>normalMigrationRead(slot),slot);assert.deepEqual(recovered,candidate);assert.deepEqual(await a.evaluate(slot=>normalMigrationReadPrepared(slot),slot),savedSet);
  // A false clean marker is inconsistent even if the state bytes still hash.
  await a.evaluate(async slot=>{const db=await normalDurableOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('accounts','readwrite'),store=tx.objectStore('accounts'),r=store.get(slot);r.onsuccess=()=>{const v=r.result;v.dirty=false;store.put(v,slot);};tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},slot);
  assert(await a.evaluate(async slot=>{try{await normalMigrationReadPrepared(slot);return false;}catch(_){return true;}},slot));
  await a.evaluate(async({slot,prepared})=>{const db=await normalDurableOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('accounts','readwrite');tx.objectStore('accounts').put(prepared,slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},{slot,prepared:savedSet.primary});
  // Corrupted or mismatched baseline must not be accepted as prepared.
  await a.evaluate(async slot=>{const db=await normalDurableOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('sync','readwrite'),store=tx.objectStore('sync'),r=store.get(slot);r.onsuccess=()=>{const v=r.result;v.version='f'.repeat(32);store.put(v,slot);};tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},slot);
  assert(await a.evaluate(async slot=>{try{await normalMigrationReadPrepared(slot);return false;}catch(_){return true;}},slot));
  await a.evaluate(async({slot,sync})=>{const db=await normalDurableOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('sync','readwrite');tx.objectStore('sync').put(sync,slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},{slot,sync:savedSet.sync});
  await a.evaluate(async slot=>{const db=await normalDurableOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('migrations','readwrite'),store=tx.objectStore('migrations'),r=store.get(slot);r.onsuccess=()=>{const v=r.result;v.payload=v.payload.replace('pear','plum');store.put(v,slot);};tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},slot);
  assert(await a.evaluate(async slot=>{try{await normalMigrationRead(slot);return false;}catch(_){return true;}},slot));
  assert((await a.evaluate(slot=>normalMigrationReadRaw(slot),slot)).payload.includes('plum'));
  // A pending legacy upload is archived exactly, but must not be turned into
  // a prepared primary until its outcome is resolved.
  const pendingSeed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),pendingAuth=await api('/api/v1/auth/login','POST',{username:pendingSeed.username,password:pendingSeed.password});
  const otherBrowser=await chromium.launch({headless:true,executablePath});
  try {
   const p=await otherBrowser.newPage();await p.goto(base);await p.evaluate(value=>onAuthed(value,false),pendingAuth);await wait(p,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
   const before=await p.evaluate(async()=>{const slot=accountSlot(AUTH),record=await deltaIDB(slot,'get');record.pending={target:JSON.stringify(S),merge:true};await deltaIDB(slot,'put',record,true);return record;});
   await p.evaluate(()=>normalMigrationStage(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));
   assert.deepEqual((await p.evaluate(()=>normalMigrationRead(accountSlot(AUTH)))).value.legacy,before);
   assert(await p.evaluate(async()=>{try{await normalMigrationPrepare(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true);return false;}catch(_){return true;}}));
   assert.equal(await p.evaluate(()=>normalDurableRead(accountSlot(AUTH))),null);
   assert.deepEqual(await p.evaluate(()=>deltaIDB(accountSlot(AUTH),'get')),before);
  } finally {await otherBrowser.close();}
  console.log('PASS ordinary migration candidate preserves dirty state and delta evidence across immediate process kill');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

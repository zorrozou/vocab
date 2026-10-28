const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
const slot='vocab_v3_a'+'1'.repeat(32),other='vocab_v3_a'+'2'.repeat(32);
(async()=>{
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-normal-profile-')));let context;
 try{
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});let a=context.pages()[0]||await context.newPage(),b=await context.newPage();await Promise.all([a.goto(base),b.goto(base)]);
  // Upgrade from the existing v1 store must preserve account data.
  await a.evaluate(async()=>{await new Promise((resolve,reject)=>{const request=indexedDB.open('vocab_normal_primary_v1',1);request.onupgradeneeded=()=>request.result.createObjectStore('accounts');request.onerror=()=>reject(request.error);request.onsuccess=()=>{const db=request.result,tx=db.transaction('accounts','readwrite');tx.objectStore('accounts').put({sentinel:42},'upgrade-sentinel');tx.oncomplete=()=>{db.close();resolve();};tx.onerror=()=>reject(tx.error);};});});
  assert.equal(await a.evaluate(async()=>{const db=await normalDurableOpen();try{return await new Promise((resolve,reject)=>{const tx=db.transaction('accounts','readonly'),r=tx.objectStore('accounts').get('upgrade-sentinel');tx.oncomplete=()=>resolve(r.result.sentinel);tx.onerror=()=>reject(tx.error);});}finally{db.close();}}),42);
  const initial=await a.evaluate(async slot=>{
   const fence={generation:'a'.repeat(32),revision:'7',epoch:0},raw=JSON.stringify({v:1,cards:{apple:{pos:1}},log:[],pendingNew:[],settings:{}});
   return normalDurableWrite(slot,null,raw,fence,false);
  },slot);
  assert.deepEqual(await b.evaluate(slot=>normalDurableRead(slot),slot),initial);
  const results=await Promise.all([a,b].map((p,i)=>p.evaluate(async({slot,initial,i})=>{
   const next=JSON.parse(initial.raw);next.marker=i;
   try{return {record:await normalDurableWrite(slot,initial,JSON.stringify(next),initial.fence,true)};}catch(e){return {error:e.code||e.message};}
  },{slot,initial,i})));
  assert.equal(results.filter(v=>v.record).length,1);assert.equal(results.filter(v=>v.error==='LOCAL_VERSION_CONFLICT').length,1);
  const committed=results.find(v=>v.record).record;
  assert(await a.evaluate(async({slot,committed})=>{try{await normalDurableWrite(slot,committed,committed.raw,null,true);return false;}catch(_){return true;}},{slot,committed}));
  assert(await a.evaluate(async({slot,committed})=>{try{await normalDurableWrite(slot,committed,committed.raw,committed.fence,false);return false;}catch(_){return true;}},{slot,committed}));
  assert(await a.evaluate(async({slot,committed})=>{const orig=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(){throw Error('injected failure');};try{await normalDurableWrite(slot,committed,committed.raw,committed.fence,true);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=orig;}},{slot,committed}));
  assert.deepEqual(await a.evaluate(slot=>normalDurableRead(slot),slot),committed);
  await a.evaluate(async({other,committed})=>normalDurableWrite(other,null,committed.raw,null,true),{other,committed});
  const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'});
  const matches=listing.split('\n').map(line=>line.trim()).filter(line=>line.includes(`--user-data-dir=${profile}`)&&line.includes(executablePath)&&!line.includes('--type='));
  assert.equal(matches.length,1);const pid=Number(matches[0].split(/\s+/,1)[0]);assert(Number.isInteger(pid)&&pid>1);
  // Kill immediately after strict transaction completion, with no delay.
  process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;
  for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){break;}await new Promise(r=>setTimeout(r,100));}
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});a=context.pages()[0]||await context.newPage();await a.goto(base);
  assert.deepEqual(await a.evaluate(slot=>normalDurableRead(slot),slot),committed);
  assert((await a.evaluate(other=>normalDurableRead(other),other)).dirty);
  await a.evaluate(async slot=>{const db=await normalDurableOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('accounts','readwrite'),store=tx.objectStore('accounts'),r=store.get(slot);r.onsuccess=()=>{const value=r.result;value.raw=value.raw.replace('apple','mango');store.put(value,slot);};tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},slot);
  assert(await a.evaluate(async slot=>{try{await normalDurableRead(slot);return false;}catch(_){return true;}},slot));
  assert.equal(await a.evaluate(async({slot,committed})=>{try{await normalDurableWrite(slot,committed,committed.raw,committed.fence,true);return 'bad';}catch(e){return e.code;}},{slot,committed}),'LOCAL_VERSION_CONFLICT');
  assert((await a.evaluate(slot=>normalDurableReadRaw(slot),slot)).raw.includes('mango'));
  console.log('PASS ordinary strict store: committed state survives immediate process kill, CAS, corruption and account isolation');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

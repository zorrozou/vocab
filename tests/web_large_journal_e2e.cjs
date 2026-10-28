const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const slot='vocab_v3_a'+'a'.repeat(32);
async function owner(page,slot){
 await page.evaluate(slot=>{
  window.ready=new Promise((resolve,reject)=>{window.readyOK=resolve;window.readyError=reject;});
  window.gate=new Promise(resolve=>window.releaseOwner=resolve);
  window.ownerTask=largeLocalWithLease(slot,async lease=>{window.lease=lease;window.readyOK();await window.gate;}).catch(error=>{window.readyError(error);throw error;});
 },slot);
 await page.evaluate(()=>window.ready);
}
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const context=await browser.newContext(),a=await context.newPage(),b=await context.newPage();
  await Promise.all([a.goto(base),b.goto(base)]);
  // Upgrade an existing v1 database without dropping its primary state.
  await a.evaluate(async slot=>{
   const raw=JSON.stringify({v:1,cards:{apple:{pos:1}},log:[],pendingNew:[],settings:{},payload:'x'.repeat(9*1024*1024)});
   const digest=await largeLocalDigest(raw), record={format:1,slot,version:deltaID(),raw,length:digest.length,sha256:digest.sha256};
   await new Promise((resolve,reject)=>{const request=indexedDB.open('vocab_primary_v1',1);request.onupgradeneeded=()=>request.result.createObjectStore('slots');request.onerror=()=>reject(request.error);request.onsuccess=()=>{const db=request.result,tx=db.transaction('slots','readwrite');tx.objectStore('slots').put(record,slot);tx.oncomplete=()=>{db.close();resolve();};tx.onabort=tx.onerror=()=>reject(tx.error);};});
   window.initial=record;
  },slot);
  assert.equal(await a.evaluate(async slot=>(await largeLocalRead(slot)).version===window.initial.version,slot),true);
  await owner(a,slot);
  assert(await b.evaluate(async slot=>{try{await largeLocalWithLease(slot,async()=>{});return false;}catch(_){return true;}},slot));
  await a.evaluate(async()=>{const state=JSON.parse(window.lease.raw);state.marker=1;await largeLocalAppend(window.lease,JSON.stringify(state));});
  assert(await a.evaluate(async slot=>!!(await largeJournalRead(slot)),slot));
  assert(await b.evaluate(async slot=>{const record=await largeLocalRead(slot);try{await largeLocalWrite(slot,record,record.raw);return false;}catch(_){return true;}},slot));
  assert(await b.evaluate(async slot=>{const record=await largeLocalRead(slot),wal=(await largeJournalRead(slot)).value;try{await largeLocalWrite(slot,record,record.raw,{id:wal.id,baseVersion:wal.baseVersion,through:1});return false;}catch(_){return true;}},slot));
  assert(await a.evaluate(async slot=>{const prior=(await largeJournalRead(slot)).raw,orig=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='journals')throw Error('injected quota failure');return orig.apply(this,args);};try{const state=JSON.parse(window.lease.raw);state.marker=99;await largeLocalAppend(window.lease,JSON.stringify(state));return false;}catch(_){return (await largeJournalRead(slot)).raw===prior&&JSON.parse(window.lease.raw).marker===1;}finally{IDBObjectStore.prototype.put=orig;}},slot));
  // A rejected oversized journal must not replace the prior durable edit.
  assert(await a.evaluate(async()=>{const state=JSON.parse(window.lease.raw);state.blob='y'.repeat(600*1024);try{await largeLocalAppend(window.lease,JSON.stringify(state));return false;}catch(_){return true;}}));
  await a.close();
  await owner(b,slot);
  assert.equal(await b.evaluate(()=>JSON.parse(window.lease.raw).marker),1);
  // Commit succeeds but journal cleanup fails: a later owner must not repeat it.
  assert(await b.evaluate(async slot=>{const orig=IDBObjectStore.prototype.delete;IDBObjectStore.prototype.delete=function(...args){if(this.name==='journals')throw Error('injected cleanup failure');return orig.apply(this,args);};try{await largeLocalFlush(window.lease);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.delete=orig;}},slot));
  const committed=await b.evaluate(async slot=>(await largeLocalRead(slot)).version,slot);
  assert(await b.evaluate(async slot=>!!(await largeJournalRead(slot)),slot));
  await b.close();
  const c=await context.newPage();await c.goto(base);
  await c.evaluate(async slot=>{const db=await largeLocalOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('commits','readwrite'),s=tx.objectStore('commits'),r=s.get(slot);r.onsuccess=()=>{window.originalMarker=r.result;s.put({...r.result,id:'0'.repeat(32)},slot);};tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},slot);
  assert(await c.evaluate(async slot=>{try{await largeLocalWithLease(slot,async()=>{});return false;}catch(_){return true;}},slot));
  assert(await c.evaluate(async slot=>!!(await largeJournalRead(slot)),slot));
  await c.evaluate(async slot=>{const db=await largeLocalOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('commits','readwrite');tx.objectStore('commits').put(window.originalMarker,slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},slot);
  await owner(c,slot);
  assert.equal(await c.evaluate(()=>JSON.parse(window.lease.raw).marker),1);
  await c.evaluate(()=>largeLocalFlush(window.lease));
  assert.equal(await c.evaluate(async slot=>(await largeLocalRead(slot)).version,slot),committed);
  assert.equal(await c.evaluate(async slot=>await largeJournalRead(slot),slot),null);
  // A new edit arrives after the prior commit but before its journal cleanup.
  await c.evaluate(async()=>{const state=JSON.parse(window.lease.raw);state.marker=2;await largeLocalAppend(window.lease,JSON.stringify(state));
   window.committedGate=new Promise(resolve=>window.releaseCommitted=resolve);window.committedSignal=new Promise(resolve=>window.signalCommitted=resolve);
   window.originalWrite=largeLocalWrite;largeLocalWrite=async(...args)=>{const value=await window.originalWrite(...args);window.signalCommitted();await window.committedGate;return value;};
   window.flushing=largeLocalFlush(window.lease);});
  await c.evaluate(()=>window.committedSignal);
  await c.evaluate(async()=>{const state=JSON.parse(window.lease.raw);state.marker=3;await largeLocalAppend(window.lease,JSON.stringify(state));window.releaseCommitted();await window.flushing;largeLocalWrite=window.originalWrite;});
  assert(await c.evaluate(async slot=>!!(await largeJournalRead(slot)),slot));
  await c.close();
  const d=await context.newPage();await d.goto(base);await owner(d,slot);
  assert.equal(await d.evaluate(()=>JSON.parse(window.lease.raw).marker),3);
  await d.evaluate(()=>largeLocalFlush(window.lease));
  assert.equal(await d.evaluate(async slot=>JSON.parse((await largeLocalRead(slot)).raw).marker,slot),3);
  const final=await d.evaluate(async slot=>(await largeLocalRead(slot)).version,slot);
  await d.evaluate(()=>largeLocalFlush(window.lease));
  assert.equal(await d.evaluate(async slot=>(await largeLocalRead(slot)).version,slot),final);
  await d.evaluate(()=>window.releaseOwner());await d.evaluate(()=>window.ownerTask);
  await d.evaluate(async slot=>{const db=await largeLocalOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('journals','readwrite',{durability:'strict'});tx.objectStore('journals').put('{"bad":true}',slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},slot);
  assert(await d.evaluate(async slot=>{try{await largeLocalWithLease(slot,async()=>{});return false;}catch(_){return true;}},slot));
  assert.equal(await d.evaluate(async slot=>JSON.parse((await largeLocalRead(slot)).raw).marker,slot),3);
  console.log('PASS large-state journal: exclusive owner, WAL recovery, interrupted commit and concurrent edits');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

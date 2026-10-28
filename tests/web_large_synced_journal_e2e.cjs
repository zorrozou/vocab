const {chromium}=require('playwright');const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
async function owner(page,slot){await page.evaluate(slot=>{window.ready=new Promise((resolve,reject)=>{window.readyOK=resolve;window.readyError=reject;});window.gate=new Promise(resolve=>window.releaseOwner=resolve);window.ownerTask=largeLocalWithLease(slot,async lease=>{window.lease=lease;window.readyOK();await window.gate;},true).catch(error=>{window.readyError(error);throw error;});},slot);await page.evaluate(()=>window.ready);}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size:8*1024*1024+65536});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const context=await browser.newContext(),a=await context.newPage();await a.goto(base);await a.evaluate(x=>onAuthed(x,false),auth);await a.locator('#awaitSaveSnapshot').click();await a.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
  const slot=await a.evaluate(()=>accountSlot(AUTH));const initial=await a.evaluate(async slot=>{const value=await largeReadVerifiedSnapshot(slot);return {raw:value.raw,revision:value.revision,version:value.baseline.version,baseSha:value.baseline.baseSha256};},slot);
  await owner(a,slot);await a.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.streak=31;await largeLocalAppend(window.lease,JSON.stringify(value));});
  assert(await a.evaluate(async slot=>{try{await largeReadVerifiedSnapshot(slot);return false;}catch(_){return true;}},slot));
  await a.close();const b=await context.newPage();await b.goto(base);await owner(b,slot);assert.equal(await b.evaluate(()=>JSON.parse(window.lease.raw).streak),31);
  assert(await b.evaluate(async()=>{const orig=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='sync')throw Error('injected quota');return orig.apply(this,args);};try{await largeLocalFlush(window.lease);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=orig;}}));
  assert.equal(await b.evaluate(async slot=>(await largeLocalRead(slot)).version,slot),initial.version);
  assert(await b.evaluate(async slot=>!!(await largeJournalRead(slot)),slot));
  await b.evaluate(()=>largeLocalFlush(window.lease));
  const committed=await b.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {streak:JSON.parse(x.raw).streak,format:x.baseline.format,local:x.baseline.localRaw,revision:x.revision,version:x.baseline.version,baseSha:x.baseline.baseSha256};},slot);
  assert.equal(committed.streak,31);assert.equal(committed.format,2);assert.equal(committed.local,initial.raw);assert.equal(committed.revision,initial.revision);assert.equal(committed.baseSha,initial.baseSha);assert.notEqual(committed.version,initial.version);
  await b.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.streak=32;await largeLocalAppend(window.lease,JSON.stringify(value));});
  assert(await b.evaluate(async()=>{const orig=IDBObjectStore.prototype.delete;IDBObjectStore.prototype.delete=function(...args){if(this.name==='journals')throw Error('cleanup failure');return orig.apply(this,args);};try{await largeLocalFlush(window.lease);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.delete=orig;}}));
  const version=await b.evaluate(async slot=>(await largeLocalRead(slot)).version,slot);await b.close();
  const c=await context.newPage();await c.goto(base);await owner(c,slot);assert.equal(await c.evaluate(()=>JSON.parse(window.lease.raw).streak),32);await c.evaluate(()=>largeLocalFlush(window.lease));
  const final=await c.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {version:x.baseline.version,local:x.baseline.localRaw,streak:JSON.parse(x.raw).streak,revision:x.revision};},slot);
  assert.equal(final.version,version);assert.equal(final.local,initial.raw);assert.equal(final.streak,32);assert.equal(final.revision,initial.revision);
  await c.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.streak=33;await largeLocalAppend(window.lease,JSON.stringify(value));
   window.commitGate=new Promise(resolve=>window.releaseCommit=resolve);window.commitSignal=new Promise(resolve=>window.signalCommit=resolve);
   window.realLargeWrite=largeLocalWrite;largeLocalWrite=async(...args)=>{const result=await window.realLargeWrite(...args);window.signalCommit();await window.commitGate;return result;};window.flushing=largeLocalFlush(window.lease);});
  await c.evaluate(()=>window.commitSignal);
  await c.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.streak=34;await largeLocalAppend(window.lease,JSON.stringify(value));window.releaseCommit();await window.flushing;largeLocalWrite=window.realLargeWrite;});
  await c.close();const d=await context.newPage();await d.goto(base);await owner(d,slot);assert.equal(await d.evaluate(()=>JSON.parse(window.lease.raw).streak),34);
  await d.evaluate(()=>largeLocalFlush(window.lease));
  const resumed=await d.evaluate(async slot=>{const value=await largeReadVerifiedSnapshot(slot);return {local:value.baseline.localRaw,revision:value.revision,streak:JSON.parse(value.raw).streak};},slot);
  assert.equal(resumed.local,initial.raw);assert.equal(resumed.revision,initial.revision);assert.equal(resumed.streak,34);
  await d.evaluate(()=>window.releaseOwner());await d.evaluate(()=>window.ownerTask);
  await d.evaluate(async slot=>{const db=await largeLocalOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('sync','readwrite'),store=tx.objectStore('sync'),r=store.get(slot);r.onsuccess=()=>store.put({...r.result,localSha256:'0'.repeat(64)},slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},slot);
  assert(await d.evaluate(async slot=>{try{await largeLocalWithLease(slot,async()=>{},true);return false;}catch(_){return true;}},slot));
  console.log('PASS experimental synchronized journal preserves the original baseline through interrupted commits');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const slot='vocab_v3_a'+'1'.repeat(32), other='vocab_v3_a'+'2'.repeat(32);
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const context=await browser.newContext(),a=await context.newPage(),b=await context.newPage();
  await Promise.all([a.goto(base),b.goto(base)]);
  await a.evaluate(async slot=>{const state={v:1,cards:{apple:{pos:1}},log:[],pendingNew:[],settings:{},payload:'x'.repeat(9*1024*1024)};window.initialRaw=JSON.stringify(state);window.baseline=await largeLocalWrite(slot,null,window.initialRaw);},slot);
  assert((await a.evaluate(()=>new TextEncoder().encode(window.initialRaw).length))>8*1024*1024);
  await b.evaluate(async slot=>{window.baseline=await largeLocalRead(slot);},slot);
  const results=await Promise.all([a,b].map((page,i)=>page.evaluate(async ({slot,i})=>{
   let state=JSON.parse(window.baseline.raw);state.marker=i;
   try{window.result=await largeLocalWrite(slot,window.baseline,JSON.stringify(state));return 'ok';}catch(e){return e.code||e.message;}
  },{slot,i})));
  assert.equal(results.filter(x=>x==='ok').length,1);assert.equal(results.filter(x=>x==='LOCAL_VERSION_CONFLICT').length,1);
  const winner=results.indexOf('ok');await a.reload();
  assert.equal(await a.evaluate(async slot=>{window.current=await largeLocalRead(slot);return JSON.parse(window.current.raw).marker;},slot),winner);
  // A failed put must leave the previous committed value readable.
  const rejected=await a.evaluate(async slot=>{
   const orig=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(){throw new Error('injected disk failure');};
   try{let state=JSON.parse(window.current.raw);state.marker=99;await largeLocalWrite(slot,window.current,JSON.stringify(state));return false;}
   catch(_){return true;}finally{IDBObjectStore.prototype.put=orig;}
  },slot);assert(rejected);
  assert.equal(await a.evaluate(async slot=>JSON.parse((await largeLocalRead(slot)).raw).marker,slot),winner);
  assert(await a.evaluate(async ({slot,other})=>{try{await largeLocalWrite(other,window.current,window.current.raw);return false;}catch(_){return true;}},{slot,other}));
  await a.evaluate(async other=>{await largeLocalWrite(other,null,JSON.stringify({v:1,cards:{pear:{pos:2}},log:[],pendingNew:[],settings:{}}));},other);
  assert.equal(await b.evaluate(async other=>Object.keys(JSON.parse((await largeLocalRead(other)).raw).cards).join(','),other),'pear');
  assert(await a.evaluate(async slot=>{let state=JSON.parse(window.current.raw);state.payload='词'.repeat(5*1024*1024);try{await largeLocalWrite(slot,window.current,JSON.stringify(state));return false;}catch(_){return true;}},slot));
  assert.equal(await a.evaluate(async slot=>JSON.parse((await largeLocalRead(slot)).raw).marker,slot),winner);
  // Interrupted writers may leave either complete revision, never a partial state.
  const killer=await context.newPage();await killer.goto(base);
  await killer.evaluate(async slot=>{window.current=await largeLocalRead(slot);},slot);
  await killer.evaluate(slot=>{let state=JSON.parse(window.current.raw);state.marker=42;window.operation=largeLocalWrite(slot,window.current,JSON.stringify(state)).catch(()=>{});},slot);
  await killer.close();
  const result=await a.evaluate(async slot=>{window.current=await largeLocalRead(slot);return JSON.parse(window.current.raw).marker;},slot);
  assert([winner,42].includes(result));
  // Corruption with an unchanged revision must not be silently overwritten.
  await a.evaluate(async slot=>{window.trusted=await largeLocalRead(slot);const db=await largeLocalOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('slots','readwrite'),store=tx.objectStore('slots'),r=store.get(slot);r.onsuccess=()=>{const v=r.result;v.raw=v.raw.replace('xxxxx','zxxxx');store.put(v,slot);};tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();},slot);
  assert(await a.evaluate(async slot=>{try{await largeLocalRead(slot);return false;}catch(_){return true;}},slot));
  assert.equal(await a.evaluate(async slot=>{try{await largeLocalWrite(slot,window.trusted,window.trusted.raw);return 'bad';}catch(e){return e.code;}},slot),'LOCAL_VERSION_CONFLICT');
  await a.evaluate(async slot=>{try{await largeLocalWrite(slot,null,'{"a":1,"a":2}');throw Error('duplicate keys accepted');}catch(e){if(e.message==='duplicate keys accepted')throw e;}},other);
  console.log('PASS experimental large IndexedDB state: 9 MiB durability, atomic CAS, interruption, corruption and isolation');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const slot='vocab_v3_a'+'a'.repeat(32);
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try {
  const context=await browser.newContext(), page=await context.newPage();await page.goto(base);
  await page.evaluate(slot=>{localStorage.setItem(slot,JSON.stringify({v:1,cards:{apple:{pos:1}},log:[],payload:'x'.repeat(1024*1024)}));},slot);
  const original=await page.evaluate(slot=>localStorage.getItem(slot),slot);
  const candidate=await page.evaluate(slot=>largeLocalStageLegacy(slot),slot);
  assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),original);
  assert.equal(await page.evaluate(slot=>largeLocalRead(slot),slot),null);
  assert.equal(candidate.sha256,(await page.evaluate(raw=>largeLocalDigest(raw),original)).sha256);
  const copy=await page.evaluate(async slot=>{const db=await largeLocalOpen();return await new Promise((resolve,reject)=>{const tx=db.transaction('migrations'),req=tx.objectStore('migrations').get(slot);req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);tx.oncomplete=()=>db.close();});},slot);
  assert.equal(copy.raw,original);
  assert(await page.evaluate(async slot=>{const orig=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='migrations')throw Error('quota');return orig.apply(this,args);};try{await largeLocalStageLegacy(slot);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=orig;}},slot));
  assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),original);
  // A legacy page can change the source even while the new migration lock is held.
  assert(await page.evaluate(async slot=>{const orig=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){const result=orig.apply(this,args);if(this.name==='migrations')localStorage.setItem(slot,JSON.stringify({v:1,cards:{pear:{pos:2}},log:[]}));return result;};try{await largeLocalStageLegacy(slot);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=orig;}},slot));
  assert.equal(JSON.parse(await page.evaluate(slot=>localStorage.getItem(slot),slot)).cards.pear.pos,2);
  assert.equal(await page.evaluate(slot=>largeLocalRead(slot),slot),null);
  // Retrying replaces only the inactive candidate and preserves the latest legacy copy.
  await page.evaluate(slot=>largeLocalStageLegacy(slot),slot);
  const latest=await page.evaluate(slot=>localStorage.getItem(slot),slot);
  assert.equal(JSON.parse(latest).cards.pear.pos,2);
  await page.evaluate(async slot=>largeLocalWrite(slot,null,localStorage.getItem(slot)),slot);
  assert(await page.evaluate(async slot=>{try{await largeLocalStageLegacy(slot);return false;}catch(_){return true;}},slot));
  assert.equal((await page.evaluate(slot=>largeLocalRead(slot),slot)).raw,latest);
  console.log('PASS migration candidate preserves legacy state, detects races and refuses existing primary');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

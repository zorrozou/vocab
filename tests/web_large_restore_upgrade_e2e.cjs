const {chromium}=require('playwright');const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try {
  const context=await browser.newContext(),page=await context.newPage();await page.goto(base);
  // Model an old page which does not close its IndexedDB connection on upgrade.
  await page.evaluate(async()=>{await new Promise((resolve,reject)=>{const r=indexedDB.open('vocab_primary_v1',6);r.onupgradeneeded=()=>{for(const name of ['slots','commits','journals','migrations','sync','uploads'])if(!r.result.objectStoreNames.contains(name))r.result.createObjectStore(name)};r.onerror=()=>reject(r.error);r.onsuccess=()=>{window.oldDB=r.result;const tx=window.oldDB.transaction('slots','readwrite');tx.objectStore('slots').put({marker:'preserve'},'vocab_v3_a'+'a'.repeat(32));tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error)}})});
  assert(await page.evaluate(async()=>{try{await largeLocalOpen();return false}catch(e){return e.message.includes('占用')}}),'blocked upgrade must fail closed');
  await page.evaluate(()=>window.oldDB.close());
  const verified=await page.evaluate(async()=>{const db=await largeLocalOpen();const result=await new Promise((resolve,reject)=>{const tx=db.transaction(['slots','restores'],'readonly'),a=tx.objectStore('slots').get('vocab_v3_a'+'a'.repeat(32)),b=tx.objectStore('restores').get('vocab_v3_a'+'a'.repeat(32));tx.oncomplete=()=>resolve({version:db.version,old:a.result,restore:b.result??null});tx.onerror=tx.onabort=()=>reject(tx.error)});db.close();return result});
  assert.equal(verified.version,7);assert.deepEqual(verified.old,{marker:'preserve'});assert.equal(verified.restore,null);
  assert(await page.evaluate(()=>new Promise(resolve=>{const r=indexedDB.open('vocab_primary_v1',6);r.onsuccess=()=>{r.result.close();resolve(false)};r.onerror=()=>resolve(r.error?.name==='VersionError')})),'old code must not reopen a lower database version');
  await context.close();console.log('PASS Web restore-store upgrade preserves existing data and fails closed on blocked or old versions');
 } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

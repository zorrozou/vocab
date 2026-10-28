const {chromium}=require('playwright');
const assert=require('assert');const fs=require('fs');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password}),size=8*1024*1024+65536;
 await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage({acceptDownloads:true});await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);await page.locator('#awaitSaveSnapshot').waitFor();
  // Fail the second object-store write: neither record may commit.
  await page.evaluate(()=>{window.realPut=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='sync')throw Error('injected quota');return window.realPut.apply(this,args);};});
  await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('injected quota'));
  assert.equal(await page.evaluate(()=>largeReadVerifiedSnapshot(accountSlot(AUTH))),null);
  await page.evaluate(()=>{IDBObjectStore.prototype.put=window.realPut;});
  await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
  const saved=await page.evaluate(async()=>{const r=await largeReadVerifiedSnapshot(accountSlot(AUTH));return {size:JSON.parse(r.raw).fixtureLarge.length,revision:r.revision};});assert.equal(saved.size,size);
  assert(await page.evaluate(async()=>{const slot=accountSlot(AUTH),record=await largeLocalRead(slot);try{await largeLocalWrite(slot,record,record.raw);return false;}catch(_){return true;}}));
  assert(await page.evaluate(async()=>{try{await largeLocalWithLease(accountSlot(AUTH),async()=>{});return false;}catch(_){return true;}}));
  assert.equal(await page.evaluate(()=>localStorage.getItem(accountSlot(AUTH))),null,'copy must not activate legacy slot');
  await page.reload();await page.locator('#awaitExportSaved').waitFor();
  assert(await page.evaluate(async()=>!await largeResumePreference(accountSlot(AUTH))&&!largeActive),'saving a copy alone must not opt in to automatic learning');
  await page.route('**/api/v1/**',route=>route.abort());
  const event=page.waitForEvent('download');await page.locator('#awaitExportSaved').click();const download=await event;
  assert.equal(JSON.parse(fs.readFileSync(await download.path(),'utf8')).fixtureLarge.length,size);
  // Corrupted baseline must fail closed even if the primary bytes still match.
  await page.evaluate(async()=>{const slot=accountSlot(AUTH),db=await largeLocalOpen();await new Promise((resolve,reject)=>{const tx=db.transaction('sync','readwrite',{durability:'strict'}),store=tx.objectStore('sync'),r=store.get(slot);r.onsuccess=()=>store.put({...r.result,baseSha256:'0'.repeat(64)},slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});db.close();});
  await page.locator('#awaitExportSaved').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('校验失败'));
  const rawEvent=page.waitForEvent('download');await page.locator('#awaitExportRaw').click();
  const raw=JSON.parse(fs.readFileSync(await (await rawEvent).path(),'utf8'));
  assert.equal(JSON.parse(raw.records.slots.raw).fixtureLarge.length,size);assert.equal(raw.records.sync.baseSha256,'0'.repeat(64));
  assert.equal(await page.evaluate(()=>localStorage.getItem(accountSlot(AUTH))),null);
  console.log('PASS large snapshot and baseline commit atomically and export offline; corruption fails closed');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

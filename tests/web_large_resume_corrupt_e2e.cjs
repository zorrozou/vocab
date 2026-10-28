const {chromium}=require('playwright');const assert=require('assert');const fs=require('fs');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size:8*1024*1024+65536});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const context=await browser.newContext({acceptDownloads:true}),page=await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));await page.locator('#awaitUseSnapshot').click();await page.locator('#bStart, #bPlace').first().waitFor();
  const slot=await page.evaluate(async()=>{clearTimeout(save._t);const slot=largeActive.slot,db=await largeLocalOpen();try{await new Promise((resolve,reject)=>{const tx=db.transaction('sync','readwrite',{durability:'strict'}),store=tx.objectStore('sync'),get=store.get(slot);get.onsuccess=()=>{const value=get.result;value.baseSha256='0'.repeat(64);store.put(value,slot);};tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});}finally{db.close();}return slot;});
  await page.close();const reopened=await context.newPage();await reopened.goto(base);await reopened.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('校验失败'),null,{timeout:60000});assert(await reopened.evaluate(slot=>!largeActive&&localStorage.getItem(slot)===null,slot));
  const event=reopened.waitForEvent('download');await reopened.locator('#awaitExportRaw').click();const raw=JSON.parse(fs.readFileSync(await (await event).path(),'utf8'));assert.equal(raw.slot,slot);assert.equal(raw.records.sync.baseSha256,'0'.repeat(64));assert(raw.records.slots.raw.length>8*1024*1024);
  console.log('PASS automatic resume rejects corrupted baseline and exports raw records');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

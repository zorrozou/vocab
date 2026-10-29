const {chromium}=require('playwright');const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size:8*1024*1024+65536});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const context=await browser.newContext(),page=await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
  await page.locator('#awaitUseSnapshot').click();await page.locator('#bStart, #bPlace').first().waitFor();
  const slot=await page.evaluate(()=>accountSlot(AUTH));assert(await page.evaluate(()=>largeActive&&!!S.cards.apple&&S.fixtureLarge.length>8*1024*1024));
  // A second tab must neither edit nor install a competing small slot.
  const other=await context.newPage();await other.goto(base);await other.locator('#awaitUseSnapshot').waitFor();await other.locator('#awaitRetry').click();await other.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('其他页面'));
  assert.equal(await other.evaluate(slot=>localStorage.getItem(slot),slot),null);await other.close();
  await page.locator('#btnSettings').click();
  // Hold the strict journal transaction before the auto-saved setting change.
  await page.evaluate(()=>{window.holdJournal=true;const original=IDBObjectStore.prototype.put;window.originalPut=original;IDBObjectStore.prototype.put=function(...args){const result=original.apply(this,args);if(this.name==='journals'){const store=this;const keep=()=>{if(!window.holdJournal)return;const request=store.get('__hold_test__');request.onsuccess=keep;};keep();window.journalWaiting=true;}return result;};});
  await page.locator('[data-new="15"]').click();await page.waitForFunction(()=>window.journalWaiting===true);assert(await page.evaluate(()=>document.querySelector('#app').inert));assert((await page.locator('#userTag').innerText()).includes('保存中'));assert((await page.locator('#settingsSaveStatus').innerText()).includes('正在保存'));
  await page.evaluate(()=>{window.holdJournal=false;IDBObjectStore.prototype.put=window.originalPut;});await page.waitForFunction(()=>largeActive&&!largeActive.pending&&!localSaveFailed);await page.locator('#bSave').click();await page.evaluate(()=>clearTimeout(save._t));
  assert(await page.evaluate(async()=>!!(await largeJournalRead(accountSlot(AUTH)))));assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),null);
  await page.close();const reopened=await context.newPage();await reopened.goto(base);await reopened.locator('#bStart, #bPlace').first().waitFor();assert.equal(await reopened.evaluate(()=>S.settings.newPerDay),15);await reopened.evaluate(()=>clearTimeout(save._t));
  await reopened.locator('#btnUser').click();await reopened.locator('#mSync').click();await reopened.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('✓ 已同步'),null,{timeout:60000});
  const saved=await reopened.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {setting:JSON.parse(x.baseline.baseRaw).settings.newPerDay,revision:x.revision,pending:(await largeReadRawSnapshot(slot)).uploads};},slot);assert.equal(saved.setting,15);assert.equal(saved.pending,null);
  await reopened.locator('#mBack').click();
  let reviews=0;await reopened.route('**/api/v1/fsrs/review',route=>{reviews++;return route.continue();});
  await reopened.evaluate(()=>{const item={kind:'learn',word:'pear',detail:{word:'pear',pos:2,senses:[{text:'梨'}]}};session={queue:[item],idx:0,reviewedToday:0,learnedToday:0};void showLearn(item);});
  await reopened.locator('#bNext').waitFor();
  await reopened.evaluate(()=>{window.holdJournal=true;const original=IDBObjectStore.prototype.put;window.originalPut=original;IDBObjectStore.prototype.put=function(...args){const result=original.apply(this,args);if(this.name==='journals'){const store=this;const keep=()=>{if(!window.holdJournal)return;const request=store.get('__hold_test__');request.onsuccess=keep;};keep();window.journalWaiting=true;}return result;};});
  await reopened.locator('#bNext').click();try{await reopened.waitForFunction(()=>window.journalWaiting===true,null,{timeout:10000});}catch(e){throw Error('journal not reached: '+JSON.stringify(await reopened.evaluate(()=>({error:largeActive?.error?.message,failed:localSaveFailed,pending:largeActive?.pending,card:!!S.cards.pear,log:S.log.length,tag:document.querySelector('#userTag')?.textContent})))+' reviews='+reviews);}assert.equal(reviews,0,'FSRS must wait for durable journal');
  await reopened.evaluate(()=>{window.holdJournal=false;IDBObjectStore.prototype.put=window.originalPut;});
  await reopened.waitForFunction(()=>S.cards.pear&&S.log.some(e=>e.kind==='learn'&&e.word==='pear')&&largeActive&&!largeActive.pending&&!localSaveFailed,null,{timeout:60000});
  for(let i=0;i<100&&reviews===0;i++)await new Promise(resolve=>setTimeout(resolve,50));assert(reviews>0);
  await reopened.waitForFunction(()=>S.cards.pear?.fsrs&&!S.cards.pear.pendingFsrs&&largeActive&&!largeActive.pending&&!localSaveFailed,null,{timeout:60000});
  await reopened.evaluate(()=>clearTimeout(save._t));await reopened.locator('#btnUser').click();await reopened.locator('#mSync').click();
  await reopened.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('✓ 已同步'),null,{timeout:60000});
  assert(await reopened.evaluate(async slot=>!!JSON.parse((await largeReadVerifiedSnapshot(slot)).baseline.baseRaw).cards.pear,slot));
  await reopened.locator('#mBack').click();await reopened.locator('#btnSettings').click();
  await reopened.evaluate(()=>{window.originalPut=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='journals')throw Error('injected quota');return window.originalPut.apply(this,args);};});
  await reopened.locator('[data-new="20"]').click();await reopened.waitForFunction(()=>largeActive&&!largeActive.pending&&localSaveFailed);assert((await reopened.locator('#settingsSaveStatus').innerText()).includes('保存失败'));assert.equal(await reopened.evaluate(()=>S.settings.newPerDay),20);
  await reopened.locator('#btnUser').click();await reopened.locator('#mSwitch').click();await reopened.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('本机保存失败'));assert(await reopened.evaluate(()=>!!AUTH&&!!largeActive));
  await reopened.evaluate(()=>{IDBObjectStore.prototype.put=window.originalPut;});await reopened.locator('#mBack').click();await reopened.locator('#btnSettings').click();
  const exportEvent=reopened.waitForEvent('download');await reopened.locator('#bExport').click();const exported=JSON.parse(require('fs').readFileSync(await (await exportEvent).path(),'utf8'));assert.equal(exported.settings.newPerDay,20);
  await reopened.locator('#bSave').click();await reopened.waitForFunction(()=>largeActive&&!largeActive.pending&&!localSaveFailed);await reopened.evaluate(()=>clearTimeout(save._t));
  await reopened.locator('#btnUser').click();await reopened.locator('#mSync').click();await reopened.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('✓ 已同步'),null,{timeout:60000});
  assert.equal(await reopened.evaluate(async slot=>JSON.parse((await largeReadVerifiedSnapshot(slot)).baseline.baseRaw).settings.newPerDay,slot),20);
  // A background mutation while the server response is in flight must fence the download.
  await reopened.locator('#mBack').click();
  let releaseResponse, sawRequest;const requested=new Promise(resolve=>sawRequest=resolve), held=new Promise(resolve=>releaseResponse=resolve);
  await reopened.route('**/api/v1/me/state/changes?*',async route=>{sawRequest();await held;await route.continue();});
  const before=await reopened.evaluate(async slot=>(await largeReadVerifiedSnapshot(slot)).raw,slot);
  await reopened.evaluate(()=>{const active=largeActive,before=JSON.stringify(S);window.racePull=largeSyncedPull(active.lease,active.owner,active.token,()=>largeSessionCurrent(active)&&JSON.stringify(S)===before).then(()=>false,()=>true);});
  await requested;await reopened.evaluate(()=>{S.settings.newPerDay=25;});releaseResponse();
  assert(await reopened.evaluate(()=>window.racePull),'download must reject a changed in-memory state');
  assert.equal(await reopened.evaluate(async slot=>(await largeReadVerifiedSnapshot(slot)).raw,slot),before);
  await reopened.unroute('**/api/v1/me/state/changes?*');await reopened.evaluate(raw=>{S=JSON.parse(raw);},before);await reopened.locator('#btnUser').click();
  await reopened.locator('#mSwitch').click();await reopened.locator('#wLogin').waitFor();
  console.log('PASS active large state saves durably, excludes other tabs, resumes and syncs');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

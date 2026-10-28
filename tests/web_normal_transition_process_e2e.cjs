const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(url,method='GET',body){const r=await fetch(base+url,{method,headers:{'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${url}: ${r.status}`);return r.json();}
async function wait(page,condition){for(let i=0;i<400;i++){if(await page.evaluate(condition))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const other=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),otherAuth=await api('/api/v1/auth/login','POST',{username:other.username,password:other.password});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-normal-transition-')));let context;
 try{
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});let page=context.pages()[0]||await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  const slot=await page.evaluate(()=>{S.cards.pear={pos:3};save();clearTimeout(save._t);if(localSaveFailed)throw Error('local save failed');return accountSlot(AUTH);});
  await page.evaluate(()=>normalMigrationStage(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));await page.evaluate(()=>normalMigrationPrepare(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));
  const source=await page.evaluate(slot=>localStorage.getItem(slot),slot),prepared=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot);
  assert(await page.evaluate(async()=>{const original=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='transitions')throw Error('injected failure');return original.apply(this,args);};try{await normalTransitionArm(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=original;}}));
  assert.equal(await page.evaluate(slot=>normalTransitionRaw(slot),slot),undefined);assert.equal(await page.evaluate(slot=>localStorage.getItem(normalTransitionMarker(slot)),slot),null);
  const fence=await page.evaluate(()=>normalTransitionArm(accountSlot(AUTH),AUTH.userId,AUTH.token));
  assert.deepEqual(await page.evaluate(()=>normalTransitionArm(accountSlot(AUTH),AUTH.userId,AUTH.token)),fence);
  assert.equal(await page.evaluate(slot=>localStorage.getItem(normalTransitionMarker(slot)),slot),fence.nonce);
  // Even a matching old receipt cannot clear a currently active fence.
  await page.evaluate(async({slot,fence})=>{const db=await normalDurableOpen();try{await new Promise((resolve,reject)=>{const tx=db.transaction('cancellations','readwrite');tx.objectStore('cancellations').put({...fence,format:2},slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});}finally{db.close();}},{slot,fence});
  assert.equal(await page.evaluate(()=>normalTransitionClearCancelled(accountSlot(AUTH),AUTH.userId,AUTH.token)),false);
  assert.equal(await page.evaluate(slot=>localStorage.getItem(normalTransitionMarker(slot)),slot),fence.nonce);
  // While the asynchronous fence lookup is pending, no existing controls may edit the legacy slot.
  await page.evaluate(()=>{window.savedTransitionExists=normalTransitionExists;window.guardEntered=new Promise(resolve=>window.guardSignal=resolve);window.guardGate=new Promise(resolve=>window.guardRelease=resolve);normalTransitionExists=async slot=>{window.guardSignal();await window.guardGate;return window.savedTransitionExists(slot);};window.guardTask=routePendingNormalTransition(AUTH.userId,AUTH.token,accountSlot(AUTH));});
  await page.evaluate(()=>window.guardEntered);
  assert(await page.evaluate(()=>document.querySelector('#app').inert&&['#btnUser','#btnSettings','#btnStats'].every(id=>document.querySelector(id).disabled)));
  await page.evaluate(()=>window.guardRelease());assert(await page.evaluate(()=>window.guardTask));
  await page.evaluate(()=>{normalTransitionExists=window.savedTransitionExists;});
  await page.evaluate(()=>{S.cards.late={pos:9};save();clearTimeout(save._t);});
  assert(await page.evaluate(()=>localSaveFailed));assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),source);
  await page.evaluate(raw=>{S=JSON.parse(raw);localSaveFailed=false;},source);
  assert.equal(await page.evaluate(()=>pushState()),false);assert.equal(await page.evaluate(()=>syncFromServer()),false);
  assert(await page.evaluate(async()=>{try{await runDeltaMutation(accountSlot(AUTH),async()=>true,()=>true,true);return false;}catch(_){return true;}}));
  // Simulate a lost localStorage sentinel: the strict IndexedDB fence remains.
  await page.evaluate(slot=>localStorage.removeItem(normalTransitionMarker(slot)),slot);
  assert.equal(await page.evaluate(()=>pushState()),false);
  const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'}),matches=listing.split('\n').map(line=>line.trim()).filter(line=>line.includes(`--user-data-dir=${profile}`)&&line.includes(executablePath)&&!line.includes('--type='));
  assert.equal(matches.length,1);const pid=Number(matches[0].split(/\s+/,1)[0]);assert(Number.isInteger(pid)&&pid>1);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;
  for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){break;}await new Promise(r=>setTimeout(r,100));}
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});page=context.pages()[0]||await context.newPage();let writes=0;page.on('request',r=>{if(['PUT','POST'].includes(r.method())&&r.url().includes('/api/v1/me/state'))writes++;});
  await page.goto(base);if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.waitForSelector('#normalTransitionExport');assert.deepEqual(await page.evaluate(slot=>normalTransitionRaw(slot),slot),fence);assert.equal(writes,0);
  assert.deepEqual(await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot),prepared);
  const download=page.waitForEvent('download');await page.locator('#normalTransitionExport').click();const saved=await download;const exported=JSON.parse(fs.readFileSync(await saved.path(),'utf8'));
  assert.equal(exported.records.prepared.transitions.candidateId,fence.candidateId);assert.equal(exported.records.prepared.accounts.raw,prepared.primary.raw);assert.deepEqual(exported.records.prepared.sync,prepared.sync);
  assert.deepEqual(exported.unavailable,[]);
  // A damaged or inaccessible prepared store must not hide the legacy copy.
  await page.evaluate(({slot,source})=>{localStorage.setItem(slot,source);window.savedExportRecords=normalTransitionExportRecords;normalTransitionExportRecords=async()=>{throw Error('injected read failure');};},{slot,source});
  const partialDownload=page.waitForEvent('download');await page.locator('#normalTransitionExport').click();const partialSaved=await partialDownload;const partial=JSON.parse(fs.readFileSync(await partialSaved.path(),'utf8'));
  assert.deepEqual(partial.unavailable,['prepared']);assert.equal(partial.records.legacyRaw,source);assert(partial.records.legacy);assert(await page.locator('#normalTransitionMessage').textContent().then(s=>s.includes('部分存储无法读取')));
  await page.evaluate(()=>{normalTransitionExportRecords=window.savedExportRecords;});
  // Conversely, an inaccessible legacy sync store must not hide the prepared record.
  await page.evaluate(()=>{window.savedDeltaIDB=deltaIDB;deltaIDB=()=>Promise.reject(Error('injected legacy read failure'));});
  const preparedDownload=page.waitForEvent('download');await page.locator('#normalTransitionExport').click();const preparedSaved=await preparedDownload;const preparedOnly=JSON.parse(fs.readFileSync(await preparedSaved.path(),'utf8'));
  assert.deepEqual(preparedOnly.unavailable,['legacy']);assert.equal(preparedOnly.records.prepared.accounts.raw,prepared.primary.raw);assert.equal(preparedOnly.records.legacyRaw,source);
  await page.evaluate(()=>{deltaIDB=window.savedDeltaIDB;});
  const pageDownload=page.waitForEvent('download');await page.locator('#normalTransitionExportPage').click();const pageSaved=await pageDownload;assert(JSON.parse(fs.readFileSync(await pageSaved.path(),'utf8')).cards);
  // A present key with undefined data is corrupt, not an absent fence.
  await page.evaluate(async slot=>{localStorage.removeItem(normalTransitionMarker(slot));const db=await normalDurableOpen();try{await new Promise((resolve,reject)=>{const tx=db.transaction('transitions','readwrite');tx.objectStore('transitions').put(undefined,slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});}finally{db.close();}},slot);
  assert(await page.evaluate(slot=>normalTransitionExists(slot),slot));
  await page.reload();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);await page.waitForSelector('#normalTransitionExport');assert.equal(writes,0);
  const emptyDownload=page.waitForEvent('download');await page.locator('#normalTransitionExport').click();const emptySaved=await emptyDownload;const empty=JSON.parse(fs.readFileSync(await emptySaved.path(),'utf8'));assert.equal(empty.records.prepared.transitionsPresent,true);assert.equal(empty.records.prepared.transitions,null);
  // Even a damaged transition is a fence and remains exportable.
  await page.evaluate(async slot=>{const db=await normalDurableOpen();try{await new Promise((resolve,reject)=>{const tx=db.transaction('transitions','readwrite');tx.objectStore('transitions').put({broken:true},slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});}finally{db.close();}},slot);
  await page.reload();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);await page.waitForSelector('#normalTransitionExport');assert.equal(writes,0);
  await page.locator('#normalTransitionSwitch').click();await page.evaluate(a=>onAuthed(a,false),otherAuth);assert(await page.evaluate(()=>!!AUTH&&S.cards.apple&&!document.querySelector('#normalTransitionExport')));
  console.log('PASS ordinary transition fence survives process termination and blocks legacy writes');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

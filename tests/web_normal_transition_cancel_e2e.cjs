const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const macChrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const chrome=process.env.VOCAB_BROWSER||(fs.existsSync(macChrome)?macChrome:chromium.executablePath());
async function api(path,body){const r=await fetch(base+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
async function wait(page,condition){for(let i=0;i<400;i++){if(await page.evaluate(condition))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case',{}),auth=await api('/api/v1/auth/login',{username:seed.username,password:seed.password});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-cancel-transition-')));let context;
 try {
  context=await chromium.launchPersistentContext(profile,{headless:true,...(fs.existsSync(chrome)?{executablePath:chrome}:{})});let page=context.pages()[0]||await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  const slot=await page.evaluate(()=>{S.cards.pear={pos:3};save();clearTimeout(save._t);if(localSaveFailed)throw Error('save failed');return accountSlot(AUTH);});
  await page.evaluate(()=>normalMigrationStage(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));
  await page.evaluate(()=>normalMigrationPrepare(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));
  const before=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot), source=await page.evaluate(slot=>localStorage.getItem(slot),slot);
  // Preserve the old localStorage source before testing the strict receipt's crash recovery.
  await new Promise(resolve=>setTimeout(resolve,8000));
  await page.evaluate(()=>normalTransitionArm(accountSlot(AUTH),AUTH.userId,AUTH.token));
  // Divergent prepared edits cannot be silently discarded by cancellation.
  await page.evaluate(async({slot,before})=>{const state=JSON.parse(before.primary.raw);state.cards.pear.pos=9;await normalMigrationWritePrepared(slot,before,JSON.stringify(state));},{slot,before});
  assert(await page.evaluate(async()=>{try{await normalTransitionCancel(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}}));
  assert(await page.evaluate(slot=>normalTransitionExists(slot),slot));
  await page.evaluate(({slot,source})=>localStorage.setItem(slot,source+' '),{slot,source});
  assert(await page.evaluate(async()=>{try{await normalTransitionCancel(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}}));
  await page.evaluate(({slot,source})=>localStorage.setItem(slot,source),{slot,source});
  await page.evaluate(async({slot,before})=>{const db=await normalDurableOpen();try{await new Promise((resolve,reject)=>{const tx=db.transaction(['accounts','sync'],'readwrite');tx.objectStore('accounts').put(before.primary,slot);tx.objectStore('sync').put(before.sync,slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});}finally{db.close();}},{slot,before});
  // A failed strict receipt write must leave the original fence and marker intact.
  assert(await page.evaluate(async()=>{const original=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='transitions')throw Error('injected receipt failure');return original.apply(this,args);};try{await normalTransitionCancel(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=original;}}));
  assert.equal((await page.evaluate(slot=>normalTransitionRaw(slot),slot)).format,1);
  assert(await page.evaluate(slot=>!!localStorage.getItem(normalTransitionMarker(slot)),slot));
  // A failure after the cancellation receipt is committed is recoverable.
  assert(await page.evaluate(async()=>{const original=IDBObjectStore.prototype.delete;IDBObjectStore.prototype.delete=function(...args){if(this.name==='transitions')throw Error('injected cleanup failure');return original.apply(this,args);};try{await normalTransitionCancel(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.delete=original;}}));
  assert.equal((await page.evaluate(slot=>normalTransitionRaw(slot),slot)).format,2);
  assert.equal((await page.evaluate(slot=>normalTransitionExportRecords(slot),slot)).cancellations,null);
  assert.equal(await page.evaluate(slot=>localStorage.getItem(normalTransitionMarker(slot)),slot),null);
  const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'}), matches=listing.split('\n').map(line=>line.trim()).filter(line=>line.includes(`--user-data-dir=${profile}`)&&line.includes(chrome)&&!line.includes('--type='));
  assert.equal(matches.length,1);const pid=Number(matches[0].split(/\s+/,1)[0]);assert(Number.isInteger(pid)&&pid>1);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;
  for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){break;}await new Promise(r=>setTimeout(r,100));}
  context=await chromium.launchPersistentContext(profile,{headless:true,...(fs.existsSync(chrome)?{executablePath:chrome}:{})});page=context.pages()[0]||await context.newPage();
  await page.goto(base);if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.waitForSelector('#normalTransitionCancel');await page.locator('#normalTransitionCancel').click();
  await wait(page,()=>!!AUTH&&!document.querySelector('#normalTransitionCancel'));
  assert.equal(await page.evaluate(slot=>normalTransitionExists(slot),slot),false);
  const resumed=JSON.parse(await page.evaluate(slot=>localStorage.getItem(slot),slot));
  assert.deepEqual(resumed.cards,JSON.parse(source).cards);
  assert.deepEqual(await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot),before);
  // A localStorage deletion may roll back after a crash. The strict receipt
  // identifies only the completed cancellation, not an arbitrary new marker.
  const receipt=(await page.evaluate(slot=>normalTransitionExportRecords(slot),slot)).cancellations;
  assert.equal(receipt.format,2);assert.equal(receipt.slot,slot);
  await page.evaluate(({slot,receipt})=>localStorage.setItem(normalTransitionMarker(slot),receipt.nonce),{slot,receipt});
  await page.reload();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.waitForSelector('#bStart');assert.equal(await page.evaluate(slot=>localStorage.getItem(normalTransitionMarker(slot)),slot),null);
  const unknown='f'.repeat(32)===receipt.nonce?'e'.repeat(32):'f'.repeat(32);
  await page.evaluate(({slot,unknown})=>localStorage.setItem(normalTransitionMarker(slot),unknown),{slot,unknown});
  await page.reload();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.waitForSelector('#normalTransitionExport');assert.equal(await page.evaluate(slot=>localStorage.getItem(normalTransitionMarker(slot)),slot),unknown);
  console.log('PASS ordinary transition cancellation preserves both copies and resumes after interrupted cleanup');
 } finally {if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

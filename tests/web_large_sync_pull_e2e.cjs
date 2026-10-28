const {chromium}=require('playwright');const assert=require('assert');const crypto=require('crypto');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();}
async function owner(page,slot){await page.evaluate(slot=>{window.ready=new Promise((resolve,reject)=>{window.ok=resolve;window.fail=reject;});window.gate=new Promise(resolve=>window.release=resolve);window.task=largeLocalWithLease(slot,async lease=>{window.lease=lease;window.ok();await window.gate;},true).catch(e=>{window.fail(e);throw e;});},slot);await page.evaluate(()=>window.ready);}
function batch(baseline,word,pos){return {generation:baseline.generation,base_revision:baseline.revision,restore_epoch:baseline.epoch,batch_id:crypto.randomUUID().replaceAll('-',''),ops:[{op:'set',path:['cards',word],value:{pos,stage:1,due:'2099-01-01T00:00:00Z'}}]};}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size:8*1024*1024+65536});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage();await page.goto(base);await page.evaluate(x=>onAuthed(x,false),auth);await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
  const slot=await page.evaluate(()=>accountSlot(AUTH));await owner(page,slot);
  const before=await page.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {version:x.baseline.version,revision:x.revision,generation:x.generation,epoch:x.baseline.epoch,hash:x.primary.sha256};},slot);
  const first=await api('/api/v1/me/state/experimental-large-deltas','POST',batch(before,'banana',2),seed.token);
  let reached,release,switched=false,lateRequests=0;const started=new Promise(resolve=>reached=resolve),gate=new Promise(resolve=>release=resolve);
  const hold=async route=>{const response=await route.fetch();reached();await gate;await route.fulfill({response});};
  const watch=request=>{if(switched&&request.url().includes('/api/v1/me/'))lateRequests++;};page.on('request',watch);
  await page.route('**/api/v1/me/state/changes?*',hold);
  await page.evaluate(()=>{window.savedAuth=AUTH;window.delayedPull=largeSyncedPull(window.lease,AUTH.userId,AUTH.token).then(()=>false).catch(()=>true);});await started;
  await page.evaluate(()=>{AUTH=null;});switched=true;release();assert(await page.evaluate(()=>window.delayedPull));
  await page.unroute('**/api/v1/me/state/changes?*',hold);page.off('request',watch);assert.equal(lateRequests,0);
  await page.evaluate(()=>{AUTH=window.savedAuth;});assert.equal(await page.evaluate(async slot=>(await largeReadVerifiedSnapshot(slot)).baseline.version,slot),before.version);
  const corrupt=async route=>{const response=await route.fetch(),body=await response.json();if(body.change)body.change.data='AAAA'+body.change.data.slice(4);await route.fulfill({response,json:body});};
  await page.route('**/api/v1/me/state/changes?*',corrupt);
  assert(await page.evaluate(async()=>{try{await largeSyncedPull(window.lease,AUTH.userId,AUTH.token);return false;}catch(_){return true;}}));await page.unroute('**/api/v1/me/state/changes?*',corrupt);
  assert.equal(await page.evaluate(async slot=>(await largeReadVerifiedSnapshot(slot)).baseline.version,slot),before.version);
  assert(await page.evaluate(async()=>{const orig=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='sync')throw Error('quota');return orig.apply(this,args);};try{await largeSyncedPull(window.lease,AUTH.userId,AUTH.token);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=orig;}}));
  const rolled=await page.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {version:x.baseline.version,hash:x.primary.sha256};},slot);assert.deepEqual(rolled,{version:before.version,hash:before.hash});
  const pulled=await page.evaluate(()=>largeSyncedPull(window.lease,AUTH.userId,AUTH.token));assert.equal(pulled.revision,first.state_revision);
  const installed=await page.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {revision:x.revision,banana:!!JSON.parse(x.raw).cards.banana,base:!!JSON.parse(x.baseline.baseRaw).cards.banana,local:!!JSON.parse(x.baseline.localRaw).cards.banana};},slot);assert(installed.banana&&installed.base&&installed.local);
  const second=await api('/api/v1/me/state/experimental-large-deltas','POST',batch({generation:before.generation,revision:first.state_revision,epoch:before.epoch},'elder',4),seed.token);
  let third, advanced=false;
  const advance=async route=>{const response=await route.fetch();if(!advanced){advanced=true;third=await api('/api/v1/me/state/experimental-large-deltas','POST',batch({generation:before.generation,revision:second.state_revision,epoch:before.epoch},'fig',5),seed.token);}await route.fulfill({response});};
  await page.route('**/api/v1/me/state/changes?*',advance);
  const prefix=await page.evaluate(()=>largeSyncedPull(window.lease,AUTH.userId,AUTH.token));await page.unroute('**/api/v1/me/state/changes?*',advance);
  assert.equal(prefix.revision,second.state_revision);assert(JSON.parse(prefix.raw).cards.elder&&!JSON.parse(prefix.raw).cards.fig);
  const advancedPull=await page.evaluate(()=>largeSyncedPull(window.lease,AUTH.userId,AUTH.token));assert.equal(advancedPull.revision,third.state_revision);assert(JSON.parse(advancedPull.raw).cards.fig);
  // Local offline work is never replaced by a new server revision.
  await page.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.cards.cherry={pos:3,stage:1,due:'2099-01-01T00:00:00Z'};await largeLocalAppend(window.lease,JSON.stringify(value));});
  const current={generation:before.generation,revision:third.state_revision,epoch:before.epoch};await api('/api/v1/me/state/experimental-large-deltas','POST',batch(current,'grape',6),seed.token);
  const err=await page.evaluate(async()=>{try{await largeSyncedPull(window.lease,AUTH.userId,AUTH.token);return '';}catch(e){return e.message;}});assert(err.includes('未上传'));
  const retained=await page.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {cherry:!!JSON.parse(x.raw).cards.cherry,grape:!!JSON.parse(x.raw).cards.grape,revision:x.revision};},slot);
  assert(retained.cherry&&!retained.grape);assert.equal(retained.revision,third.state_revision);
  const conflict=await page.evaluate(async()=>{try{await largeSyncedPush(window.lease,AUTH.userId,AUTH.token);return 0;}catch(e){return e.status;}});assert.equal(conflict,409);
  assert((await page.evaluate(async slot=>(await largeReadRawSnapshot(slot)).uploads,slot)).pending);
  await page.evaluate(()=>window.release());await page.evaluate(()=>window.task);
  console.log('PASS large incremental download is atomic, rejects corruption and protects offline changes');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();}
async function wait(page,condition){for(let i=0;i<300;i++){if(await page.evaluate(condition))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
async function bounded(p){let t;const origin=new Error('interruption gate timed out');try{return await Promise.race([p,new Promise((_,reject)=>t=setTimeout(()=>reject(origin),20000))]);}finally{clearTimeout(t);}}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
 const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const context=await browser.newContext(),page=await context.newPage();
  if(process.env.VOCAB_TRACE_SNAPSHOT)context.on('response',r=>{if(r.url().includes('/api/v1/me/state/snapshots')&&!r.ok())console.error(`snapshot response: ${r.status()} ${r.request().method()} ${r.url()}`);});
  await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  assert(await page.evaluate(async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');
   try{validateDeltaHead({generation:r.generation,head_revision:String(BigInt(r.revision)+1n),change:null},r.generation,r.revision,r.epoch);return false;}catch(_){return true;}}));
  let fullGets=0;page.on('request',r=>{if(r.method()==='GET'&&r.url().endsWith('/api/v1/me/state'))fullGets++;});
  async function add(word,pos){const s=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;s.cards[word]={pos,stage:1,due:'2099-01-01T00:00:00Z'};await api('/api/v1/me/state','PUT',s,seed.token);}
  await add('banana',2);assert.equal(await page.evaluate(()=>syncFromServer()),true);assert(await page.evaluate(()=>!!S.cards.banana));assert.equal(fullGets,0);
  for(const [mode,word,pos] of [['before','cherry',3],['after','date',4]]){
   await add(word,pos);
   await page.evaluate(mode=>{window.realDeltaIDB=deltaIDB;window.stageReached=new Promise(r=>window.signalStage=r);window.stageGate=new Promise(r=>window.releaseStage=r);
    deltaIDB=async function(slot,op,value){if(op==='put'&&((mode==='before'&&value?.pull)||(mode==='after'&&!value?.pull&&value?.pending===null))){
     if(mode==='before')await window.realDeltaIDB(slot,op,value);window.signalStage();await window.stageGate;if(mode==='before')return;}
     return window.realDeltaIDB(slot,op,value);};},mode);
   const operation=page.evaluate(()=>syncFromServer()).catch(()=>false);
   await bounded(page.evaluate(()=>window.stageReached));
   assert((await page.evaluate(()=>window.realDeltaIDB(accountSlot(AUTH),'get'))).pull);
   if(mode==='before')assert(!(await page.evaluate(word=>!!S.cards[word],word)));else assert(await page.evaluate(word=>!!S.cards[word],word));
   await page.reload();await operation;
   await wait(page,async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');return !!r&&!r.pull&&!r.pending&&localStorage.getItem(slotClock(accountSlot(AUTH),'dirty'))!=='1';});
   assert(await page.evaluate(word=>!!S.cards[word],word));assert.equal(fullGets,0,mode);
  }
  // A local edit while the staged download is waiting remains intact.
  await add('elder',5);
  await page.evaluate(()=>{window.realDeltaIDB=deltaIDB;window.stageReached=new Promise(r=>window.signalStage=r);window.stageGate=new Promise(r=>window.releaseStage=r);
   deltaIDB=async function(slot,op,value){if(op==='put'&&value?.pull){await window.realDeltaIDB(slot,op,value);window.signalStage();await window.stageGate;return;}return window.realDeltaIDB(slot,op,value);};});
  const conflict=page.evaluate(()=>syncFromServer());await bounded(page.evaluate(()=>window.stageReached));
  await page.evaluate(()=>{S.cards.local={pos:9,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);window.releaseStage();});
  assert.equal(await conflict,false);assert(await page.evaluate(()=>!!S.cards.local&&!S.cards.elder));
  assert((await page.evaluate(()=>window.realDeltaIDB(accountSlot(AUTH),'get'))).pull);
  assert.equal(await page.evaluate(()=>pushState()),false);
  await page.evaluate(()=>{window.confirm=()=>true;deltaIDB=window.realDeltaIDB;});
  const retainedPull=await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pull);
  // Simulate quota failure before the first archive write: neither the
  // unfinished download nor the current local edit may be discarded.
  const archiveFailure=await page.evaluate(async()=>{
   const original=Storage.prototype.setItem;
   Storage.prototype.setItem=function(key,value){if(key.startsWith('vocab_unverified_'))throw new DOMException('quota','QuotaExceededError');return original.call(this,key,value);};
   try{await reloadServerState();return 'unexpected success';}catch(e){return e.message;}finally{Storage.prototype.setItem=original;}
  });
  assert(archiveFailure.includes('保留待同步记录'),archiveFailure);
  assert.deepEqual((await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pull)),retainedPull);
  assert(await page.evaluate(()=>!!S.cards.local));
  const partialFailure=await page.evaluate(async()=>{
   const original=Storage.prototype.setItem;let writes=0;
   Storage.prototype.setItem=function(key,value){if(key.startsWith('vocab_unverified_')&&++writes===2)throw new DOMException('quota','QuotaExceededError');return original.call(this,key,value);};
   try{await reloadServerState();return 'unexpected success';}catch(e){return e.message;}finally{Storage.prototype.setItem=original;}
  });
  assert(partialFailure.includes('保留待同步记录'),partialFailure);
  assert.deepEqual((await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pull)),retainedPull);
  assert((await page.evaluate(()=>reloadServerState())).includes('已加载'));
  const archivedPull=await page.evaluate(()=>Object.keys(localStorage).filter(k=>k.startsWith('vocab_unverified_')).map(k=>localStorage.getItem(k)));
  assert(archivedPull.includes(retainedPull.previous)&&archivedPull.includes(retainedPull.target),'reload did not preserve both staged views');
  assert(await page.evaluate(()=>{
   const mine='vocab_unverified_slot_'+accountSlot(AUTH)+'_fixture', other='vocab_unverified_slot_vocab_v3_a'+('f'.repeat(32))+'_fixture';
   const count=()=>document.querySelectorAll('#unverifiedList button').length;
   showSettings();const before=count();localStorage.setItem(other,'{}');showSettings();const otherCount=count();
   localStorage.setItem(mine,'{}');showSettings();const ownCount=count();
   localStorage.removeItem(mine);localStorage.removeItem(other);home();return otherCount===before&&ownCount===before+2;
  }),'archived pull exposed across account slots');
  assert(JSON.parse(await page.evaluate(()=>localStorage.getItem('vocab_before_restore_'+accountSlot(AUTH)))).cards.local);
  // A pruned journal falls back to a full read and establishes a new baseline.
  assert.equal(await page.evaluate(()=>syncFromServer()),true);await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  await add('fig',6);await api('/api/v1/__ui_fixture/state-changes-prune','POST',{token:seed.token});
  const beforeFallback=fullGets;assert.equal(await page.evaluate(()=>syncFromServer()),true);assert(fullGets>beforeFallback);assert(await page.evaluate(()=>!!S.cards.fig));
  // If both the account slot and shared main slot disappear during a staged
  // read, restart reconstructs the original local view before replaying it.
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  await add('grape',7);
  await page.evaluate(()=>{window.realDeltaIDB=deltaIDB;window.stageReached=new Promise(r=>window.signalStage=r);window.stageGate=new Promise(r=>window.releaseStage=r);
   deltaIDB=async function(slot,op,value){if(op==='put'&&value?.pull){await window.realDeltaIDB(slot,op,value);window.signalStage();await window.stageGate;return;}return window.realDeltaIDB(slot,op,value);};});
  const missingSlot=page.evaluate(()=>syncFromServer()).catch(()=>false);await bounded(page.evaluate(()=>window.stageReached));
  await page.evaluate(()=>{localStorage.removeItem(accountSlot(AUTH));localStorage.removeItem('vocab_v1');localStorage.removeItem('vocab_v1_owner');});
  const beforeRecovery=fullGets;await page.reload();await missingSlot;
  await wait(page,async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');return !!r&&!r.pull&&!r.pending&&!!S.cards.grape;});
  assert(await page.evaluate(()=>!!S.cards.fig));assert.equal(fullGets,beforeRecovery);
  // A staged read belongs to the original account even if another account
  // becomes active while the first account's IndexedDB write is awaiting.
  const other=await api('/api/v1/auth/register','POST',{username:'pull_'+Math.random().toString(36).slice(2,10),password:'test_password_123'});
  await api('/api/v1/me/state','PUT',{v:1,cards:{kiwi:{pos:1}},log:[],pendingNew:[],settings:{}},other.token);
  await add('honey',8);
  await page.evaluate(()=>{window.realDeltaIDB=deltaIDB;window.stageReached=new Promise(r=>window.signalStage=r);window.stageGate=new Promise(r=>window.releaseStage=r);
   deltaIDB=async function(slot,op,value){if(op==='put'&&value?.pull){await window.realDeltaIDB(slot,op,value);window.signalStage();await window.stageGate;return;}return window.realDeltaIDB(slot,op,value);};});
  const switchedPull=page.evaluate(()=>syncFromServer());await bounded(page.evaluate(()=>window.stageReached));
  await page.evaluate(a=>onAuthed(a,false),other);
  assert(await page.evaluate(()=>!!S.cards.kiwi&&!S.cards.honey));
  await page.evaluate(()=>{deltaIDB=window.realDeltaIDB;window.releaseStage();});assert.equal(await switchedPull,false);
  assert(await page.evaluate(()=>!!S.cards.kiwi&&!S.cards.honey));
  await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');return !!r&&!r.pull&&!!S.cards.honey;});
  assert(!(await page.evaluate(()=>!!S.cards.kiwi)));
  await add('iris',9);
  await page.evaluate(()=>{window.realDeltaIDB=deltaIDB;window.stageReached=new Promise(r=>window.signalStage=r);window.stageGate=new Promise(r=>window.releaseStage=r);
   deltaIDB=async function(slot,op,value){if(op==='put'&&value?.pull){await window.realDeltaIDB(slot,op,value);window.signalStage();await window.stageGate;return;}return window.realDeltaIDB(slot,op,value);};});
  const navigationPull=page.evaluate(()=>syncFromServer());await bounded(page.evaluate(()=>window.stageReached));
  await page.evaluate(()=>{showSettings();deltaIDB=window.realDeltaIDB;window.releaseStage();});
  assert.equal(await navigationPull,false);assert(await page.evaluate(()=>!S.cards.iris));
  assert((await page.evaluate(()=>deltaIDB(accountSlot(AUTH),'get'))).pull);
  await page.evaluate(()=>home());assert.equal(await page.evaluate(()=>syncFromServer()),true);
  assert(await page.evaluate(()=>!!S.cards.iris));
  // A staged download must not be installed after a database generation
  // rotation, even when the browser restarts before it finishes.
  await add('jackfruit',10);
  await page.evaluate(()=>{window.realDeltaIDB=deltaIDB;window.stageReached=new Promise(r=>window.signalStage=r);window.stageGate=new Promise(r=>window.releaseStage=r);
   deltaIDB=async function(slot,op,value){if(op==='put'&&value?.pull){await window.realDeltaIDB(slot,op,value);window.signalStage();await window.stageGate;return;}return window.realDeltaIDB(slot,op,value);};});
  const stalePull=page.evaluate(()=>syncFromServer()).catch(()=>false);await bounded(page.evaluate(()=>window.stageReached));
  await api('/api/v1/__ui_fixture/reset-sync-generation','POST',{});await page.reload();await stalePull;
  await wait(page,()=>syncFailed);
  assert(await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get')).pull&&!S.cards.jackfruit));
  assert.equal(await page.evaluate(()=>pushState()),false);
  await page.evaluate(()=>{window.confirm=()=>true;});
  assert((await page.evaluate(()=>reloadServerState())).includes('已加载'));
  assert.equal(await page.evaluate(()=>syncFromServer()),true);
  try { await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get'))); }
  catch (error) {
   const diagnostic=await page.evaluate(()=>({syncFailed,syncFailureMessage,localSaveFailed,deltaMarker:localStorage.getItem(deltaMarker(accountSlot(AUTH))),dirty:localStorage.getItem(slotClock(accountSlot(AUTH),'dirty')),blocked:deltaBlockedSlots.has(accountSlot(AUTH)),view:document.querySelector('#app')?.textContent?.slice(0,120)}));
   throw Error(`baseline missing after reload: ${JSON.stringify(diagnostic)}`,{cause:error});
  }
  // A second tab's saved edit must not be overwritten or marked synced by a
  // tab whose in-memory state is now stale.
  const second=await context.newPage();await second.goto(base);
  await wait(second,async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');return !!r&&!r.pull&&!!S.cards.jackfruit;});
  await second.evaluate(()=>{S.cards.tangerine={pos:11,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);});
  await page.evaluate(()=>{S.cards.staleAfterSync={pos:99};save();clearTimeout(save._t);});
  assert.equal(await page.evaluate(()=>syncFromServer()),false);
  assert.equal(await page.evaluate(()=>pushState()),false);
  assert(await page.evaluate(()=>!!JSON.parse(localStorage.getItem(accountSlot(AUTH))).cards.tangerine&&!JSON.parse(localStorage.getItem(accountSlot(AUTH))).cards.staleAfterSync));
  assert.equal(await second.evaluate(()=>pushState()),true);
  assert((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.tangerine);
  await page.reload();
  // The account state can be visible before the asynchronous boot sync ends.
  // Finish that sync before creating the edit whose upload will be held.
  await page.waitForSelector('#bStart');
  await wait(page,async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');return !!r&&!r.pull&&!r.pending&&!!S.cards.tangerine;});
  await page.evaluate(()=>{S.cards.lemon={pos:12,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);if(localSaveFailed||!JSON.parse(localStorage.getItem(accountSlot(AUTH))).cards.lemon)throw Error('first tab edit was not persisted');});
  await second.evaluate(()=>{if(!loadSlot(accountSlot(AUTH)))throw Error('missing account slot');});
  let entered,release;const sent=new Promise(r=>entered=r),gate=new Promise(r=>release=r);
  const hold=async route=>{const response=await route.fetch();entered();await gate;await route.fulfill({response});};
  await page.route('**/api/v1/me/state/deltas',hold);
  const firstPush=page.evaluate(()=>pushState());
  // Attach a rejection handler immediately: a failed setup assertion closes
  // the browser while the held request is still running.
  firstPush.catch(()=>{});
  try {
   await bounded(Promise.race([sent, firstPush.then(result=>{throw Error(`upload finished before interruption gate: ${result}`);})]));
   await second.evaluate(()=>{S.cards.orange={pos:13,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);});
   assert(await second.evaluate(()=>!localSaveFailed && !!JSON.parse(localStorage.getItem(accountSlot(AUTH))).cards.orange), 'second tab edit must be persisted before releasing the first upload');
  } finally { release(); }
  assert.equal(await firstPush,false);await page.unroute('**/api/v1/me/state/deltas',hold);
  assert.equal(await page.evaluate(()=>localStorage.getItem(slotClock(accountSlot(AUTH),'dirty'))),'1');
  assert(await page.evaluate(()=>!!JSON.parse(localStorage.getItem(accountSlot(AUTH))).cards.orange));
  assert((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.lemon);
  await second.close();
  // Recover a missing primary slot from a validated, settled local baseline.
  const recoverySeed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
  const recoveryAuth=await api('/api/v1/auth/login','POST',{username:recoverySeed.username,password:recoverySeed.password});
  const recoveryContext=await browser.newContext(),recoveryPage=await recoveryContext.newPage();
  await recoveryPage.goto(base);await recoveryPage.evaluate(a=>onAuthed(a,false),recoveryAuth);
  await wait(recoveryPage,async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');return !!r&&!r.pending&&!r.pull;});
  const expected=await recoveryPage.evaluate(()=>JSON.stringify(S.cards));
  await recoveryPage.evaluate(()=>{localStorage.removeItem(accountSlot(AUTH));localStorage.removeItem('vocab_v1');localStorage.removeItem('vocab_v1_owner');});
  await recoveryPage.reload();
  await wait(recoveryPage,()=>!!localStorage.getItem(accountSlot(AUTH)));
  assert.equal(await recoveryPage.evaluate(()=>JSON.stringify(S.cards)),expected);
  await wait(recoveryPage,async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');return !!r&&!r.pending&&!r.pull;});
  // Corrupt metadata cannot turn an absent slot into an empty upload. The
  // raw record remains exportable; an explicit server reload clears the fence.
  await recoveryPage.evaluate(async()=>{const slot=accountSlot(AUTH),r=await deltaIDB(slot,'get');r.local=null;await deltaIDB(slot,'put',r);
   localStorage.removeItem(slot);localStorage.removeItem('vocab_v1');localStorage.removeItem('vocab_v1_owner');});
  await recoveryPage.reload();await wait(recoveryPage,()=>syncFailed&&!!localStorage.getItem(deltaRecoveryBlock(accountSlot(AUTH))));
  await recoveryPage.evaluate(()=>{S.cards.unsaved={pos:99};save();clearTimeout(save._t);});
  assert.equal(await recoveryPage.evaluate(()=>localStorage.getItem(accountSlot(AUTH))),null);
  assert.equal(await recoveryPage.evaluate(()=>pushState()),false);
  assert(!(await api('/api/v1/me/state','GET',undefined,recoverySeed.token)).state.cards.unsaved);
  await recoveryPage.evaluate(()=>showSettings());
  const downloadPromise=recoveryPage.waitForEvent('download');await recoveryPage.click('#bExportSyncRecord');
  const download=await downloadPromise;const exported=JSON.parse(require('fs').readFileSync(await download.path(),'utf8'));assert.equal(exported.local,null);
  await recoveryPage.evaluate(()=>{window.confirm=()=>true;});
  assert((await recoveryPage.evaluate(()=>reloadServerState())).includes('已加载'));
  assert.equal(await recoveryPage.evaluate(()=>localStorage.getItem(deltaRecoveryBlock(accountSlot(AUTH)))),null);
  assert.equal(await recoveryPage.evaluate(()=>JSON.stringify(S.cards)),expected);
  await recoveryContext.close();
  // A different tab can create the missing account slot while authentication
  // is awaiting IndexedDB. Never install the stale recovered/empty view.
  for(const gateAt of ['record','remote']) {
    const raceSeed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
    const raceAuth=await api('/api/v1/auth/login','POST',{username:raceSeed.username,password:raceSeed.password});
    const raceContext=await browser.newContext(),first=await raceContext.newPage(),otherTab=await raceContext.newPage();
    await first.goto(base);await otherTab.goto(base);
    let release,entered;const gate=new Promise(r=>release=r),arrived=new Promise(r=>entered=r);
    if(gateAt==='record') {
      await first.evaluate(()=>{window.realDeltaIDB=deltaIDB;window.recordReached=new Promise(r=>window.signalRecord=r);window.recordGate=new Promise(r=>window.releaseRecord=r);
       deltaIDB=async function(slot,op,value){if(op==='get'){window.signalRecord();await window.recordGate;}return window.realDeltaIDB(slot,op,value);};});
    } else {
      await first.route('**/api/v1/me/state',async route=>{if(route.request().method()!=='GET')return route.continue();entered();await gate;await route.continue();});
    }
    const login=first.evaluate(a=>onAuthed(a,false),raceAuth);
    if(gateAt==='record')await bounded(first.evaluate(()=>window.recordReached));else await bounded(arrived);
    const slot=await first.evaluate(()=>accountSlot(AUTH));
    const concurrent=await otherTab.evaluate(({slot,a})=>{AUTH={userId:a.user.id,accountId:a.user.account_id,username:a.user.username,nickname:a.user.nickname,token:a.token};
     S=defaultState();S.cards.concurrent={pos:17};save();clearTimeout(save._t);return localStorage.getItem(slot);},{slot,a:raceAuth});
    if(gateAt==='record')await first.evaluate(()=>window.releaseRecord());else release();
    await login;
    assert.equal(await first.evaluate(slot=>localStorage.getItem(slot),slot),concurrent,gateAt);
    assert(await first.evaluate(slot=>deltaBlockedSlots.has(slot),slot));
    await first.evaluate(()=>{S.cards.stale={pos:18};save();clearTimeout(save._t);});
    assert.equal(await first.evaluate(slot=>localStorage.getItem(slot),slot),concurrent,gateAt+' save');
    assert.equal(await first.evaluate(()=>pushState()),false);
    assert((await first.locator('#userTag').innerText()).includes('重新加载'));
    const reloadError=await first.evaluate(async()=>{try{await reloadServerState();return '';}catch(e){return e.message;}});assert(reloadError.includes('重新加载'));
    await first.evaluate(()=>userMenu());await first.click('#mSwitch');
    assert.equal(await first.evaluate(slot=>localStorage.getItem(slot),slot),concurrent,gateAt+' switch');
    await raceContext.close();
  }
  // The startup path has the same two asynchronous boundaries.
  for(const gateAt of ['record','remote']) {
    const raceSeed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
    const raceAuth=await api('/api/v1/auth/login','POST',{username:raceSeed.username,password:raceSeed.password});
    const raceContext=await browser.newContext(),first=await raceContext.newPage(),otherTab=await raceContext.newPage();
    await first.goto(base);await otherTab.goto(base);
    await first.evaluate(a=>localStorage.setItem('vocab_auth',JSON.stringify({userId:a.user.id,accountId:a.user.account_id,username:a.user.username,nickname:a.user.nickname,token:a.token})),raceAuth);
    let release,entered;const gate=new Promise(r=>release=r),arrived=new Promise(r=>entered=r);
    if(gateAt==='record') {
      await first.addInitScript(()=>{const real=navigator.locks.request.bind(navigator.locks);window.recordReached=new Promise(r=>window.signalRecord=r);window.recordGate=new Promise(r=>window.releaseRecord=r);
       navigator.locks.request=async function(name,...args){if(name.startsWith('vocab-delta:')){window.signalRecord();await window.recordGate;}return real(name,...args);};});
    } else {
      await first.route('**/api/v1/me/state',async route=>{if(route.request().method()!=='GET')return route.continue();entered();await gate;await route.continue();});
    }
    await first.reload();
    if(gateAt==='record')await bounded(first.evaluate(()=>window.recordReached));else await bounded(arrived);
    const slot=await first.evaluate(()=>accountSlot(AUTH));
    const concurrent=await otherTab.evaluate(({slot,a})=>{AUTH={userId:a.user.id,accountId:a.user.account_id,username:a.user.username,nickname:a.user.nickname,token:a.token};
     S=defaultState();S.cards.concurrent={pos:17};save();clearTimeout(save._t);return localStorage.getItem(slot);},{slot,a:raceAuth});
    if(gateAt==='record')await first.evaluate(()=>window.releaseRecord());else release();
    await wait(first,()=>syncFailed);
    assert.equal(await first.evaluate(slot=>localStorage.getItem(slot),slot),concurrent,'boot '+gateAt);
    assert(await first.evaluate(slot=>deltaBlockedSlots.has(slot),slot));
    await first.evaluate(()=>{S.cards.stale={pos:18};save();clearTimeout(save._t);});
    assert.equal(await first.evaluate(slot=>localStorage.getItem(slot),slot),concurrent,'boot '+gateAt+' save');
    assert((await first.locator('#userTag').innerText()).includes('重新加载'));
    const reloadError=await first.evaluate(async()=>{try{await reloadServerState();return '';}catch(e){return e.message;}});assert(reloadError.includes('重新加载'));
    await first.evaluate(()=>userMenu());await first.click('#mSwitch');
    assert.equal(await first.evaluate(slot=>localStorage.getItem(slot),slot),concurrent,'boot '+gateAt+' switch');
    await raceContext.close();
  }
  // A browser that exposes IndexedDB but cannot open it can still use a
  // legacy service when there is no prior incremental marker.
  const legacyContext=await browser.newContext(),legacyPage=await legacyContext.newPage();await legacyPage.goto(base);
  await legacyPage.route('**/api/v1/me/state',route=>route.fulfill({json:{state:{v:1,cards:{apple:{pos:1}},log:[],pendingNew:[],settings:{}},updated_at:1}}));
  await legacyPage.evaluate(()=>{deltaIDB=async()=>{throw new Error('storage unavailable');};});
  await legacyPage.evaluate(a=>onAuthed(a,false),auth);
  assert.equal(await legacyPage.evaluate(()=>syncFromServer()),true);
  assert(await legacyPage.evaluate(()=>!!S.cards.apple));
  await legacyContext.close();
  console.log('PASS Web incremental pull, process reload recovery, local conflict and pruned fallback');
  await context.close();
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

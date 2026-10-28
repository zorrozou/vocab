const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});
 if(!r.ok) throw Error(`${path}: ${r.status} ${await r.text()}`); return r.json();
}
async function waitRecord(page,predicate){
 for(let i=0;i<300;i++){
  const value=await page.evaluate(async()=>({record:await deltaIDB(accountSlot(AUTH),'get'),dirty:localStorage.getItem(slotClock(accountSlot(AUTH),'dirty'))}));
  if(predicate(value))return value;
  await new Promise(resolve=>setTimeout(resolve,100));
 }
 throw Error('incremental record did not reach expected state');
}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
 const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try {
  const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(base);
  assert.deepEqual(await page.evaluate(()=>deltaApply({log:[1,3]},[{op:'splice_log',path:['log'],value:{index:1,delete:0,items:[2]}}])),{log:[1,2,3]});
  assert(await page.evaluate(()=>{try{deltaApply({log:[1]},[{op:'splice_log',path:['log'],value:{index:1,delete:1,items:[]}}]);return false;}catch(_){return true;}}));
  const diff=await page.evaluate(()=>deltaDiff({cards:{apple:{pos:1}},fsrsSchedulers:{a:1},missing:{x:1}},
    {cards:{apple:{pos:1},banana:{pos:2}},fsrsSchedulers:{a:1,b:2}}, {cards:{apple:{pos:1}},serverOnly:7}));
  assert(diff.some(op=>op.path.join('/')==='cards/banana'));
  assert(diff.some(op=>op.op==='set' && op.path.join('/')==='fsrsSchedulers'));
  assert(!diff.some(op=>op.path[0]==='serverOnly' || op.path[0]==='missing'));
  await page.evaluate(a=>onAuthed(a,false),auth);
  await waitRecord(page,x=>x.record?.base && !x.record.pending);
  let posts=[];page.on('request',r=>{if(r.url().includes('/api/v1/me/state/deltas')) posts.push(JSON.parse(r.postData()));});
  const firstRequest=page.waitForRequest(r=>r.url().includes('/api/v1/me/state/deltas'));
  const first=await page.evaluate(async()=>{S.cards.banana={pos:2,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();});
  await firstRequest;
  assert.equal(first,true);assert.equal(posts.length,1, JSON.stringify(await page.evaluate(async()=>({record:await deltaIDB(accountSlot(AUTH),'get'), supported:deltaSupported(),error:syncFailureMessage}))));assert(posts[0].ops.some(op=>op.path.join('/')==='cards/banana'));
  assert.deepEqual(Object.keys((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards).sort(),['apple','banana']);
  const followupRequest=page.waitForRequest(r=>r.url().includes('/api/v1/me/state/deltas'));
  assert.equal(await page.evaluate(async()=>{S.cards.blackberry={pos:12,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();}),true);
  const followup=JSON.parse((await followupRequest).postData());
  assert(followup.ops.some(op=>op.path.join('/')==='cards/blackberry'));
  const event={eventId:'abcdef0123456789',d:'2026-10-27',word:'apple',rating:4,kind:'review'};
  const appendRequest=page.waitForRequest(r=>r.url().includes('/api/v1/me/state/deltas'));
  assert.equal(await page.evaluate(async e=>{S.log.push(e);save();clearTimeout(save._t);return pushState();},event),true);
  const appendBatch=JSON.parse((await appendRequest).postData());
  assert.deepEqual(appendBatch.ops.find(op=>op.path.join('/')==='log'),{op:'append_log',path:['log'],value:[event]});
  assert((await api('/api/v1/me/state','GET',undefined,seed.token)).state.log.some(e=>e.eventId===event.eventId));
  await page.route('**/api/v1/me/state/delta-capabilities',route=>route.fulfill({status:404,json:{detail:'old server'}}));
  const legacyRequest=page.waitForRequest(r=>r.url().includes('/api/v1/me/state/deltas'));
  assert.equal(await page.evaluate(async()=>{S.log.push({eventId:'abcdef0123456790',d:'2026-10-27',word:'apple',rating:4,kind:'review'});save();clearTimeout(save._t);return pushState();}),true);
  assert.equal(JSON.parse((await legacyRequest).postData()).ops.find(op=>op.path.join('/')==='log').op,'set');
  await page.unroute('**/api/v1/me/state/delta-capabilities');
  await page.evaluate(()=>syncFromServer());
  const firstRevision=(await api('/api/v1/me/state','GET',undefined,seed.token)).state_revision;
  await waitRecord(page,x=>x.record?.revision===firstRevision && !x.record.pending);
  // The response is lost after the server commits; reloading replays the same batch ID.
  await page.evaluate(()=>{S.cards.cherry={pos:3,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);});
  let lost=false;const drop=async route=>{if(!lost){lost=true;await route.fetch();await route.abort('connectionreset');}else await route.continue();};
  await page.route('**/api/v1/me/state/deltas',drop);
  const second=await page.evaluate(()=>pushState());
  assert.equal(second,false);await page.unroute('**/api/v1/me/state/deltas',drop);
  const pending=await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pending);
  assert(pending?.batch?.batch_id);const committed=await api('/api/v1/me/state','GET',undefined,seed.token);
  assert(committed.state.cards.cherry);
  await page.reload();
  await waitRecord(page,x=>!x.record?.pending && x.dirty!=='1');
  assert(posts.filter(p=>p.batch_id===pending.batch.batch_id).length>=2);
  assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state_revision,committed.state_revision);
  await page.evaluate(()=>syncFromServer());
  await waitRecord(page,x=>x.record?.base && !x.record.pending);
  // A corrupt change page must not acknowledge the batch; retry the same ID.
  let corrupted=false;
  const corrupt=async route=>{
    const response=await route.fetch(), result=await response.json();
    if(!corrupted && result.change){corrupted=true;result.change.data=(result.change.data[0]==='A'?'B':'A')+result.change.data.slice(1);}
    await route.fulfill({response,json:result});
  };
  await page.route('**/api/v1/me/state/changes?*',corrupt);
  assert.equal(await page.evaluate(async()=>{S.cards.coconut={pos:8,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();}),false);
  await page.unroute('**/api/v1/me/state/changes?*',corrupt);
  assert(corrupted);
  assert((await page.evaluate(()=>syncFailureMessage)).includes('校验'));
  const unverified=await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pending);
  assert(unverified?.batch?.batch_id && await page.evaluate(()=>!!S.cards.coconut));
  await page.evaluate(()=>showSettings());
  const download=page.waitForEvent('download');await page.locator('#bExportPending').click();
  assert(JSON.parse(fs.readFileSync(await (await download).path(),'utf8')).cards.coconut);
  const beforeRetry=(await api('/api/v1/me/state','GET',undefined,seed.token)).state_revision;
  assert.equal(await page.evaluate(()=>pushState()),true);
  assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state_revision,beforeRetry);
  // A retained receipt with a pruned change uses a generation-fenced merge.
  await page.evaluate(()=>syncFromServer());
  await waitRecord(page,x=>x.record?.base && !x.record.pending);
  let pruned=false, prunedMerges=0;
  const missing=route=>{pruned=true;return route.fulfill({status:410,json:{detail:'pruned'}});};
  page.on('request',r=>{if(r.url().includes('/api/v1/me/state/guarded-merge'))prunedMerges++;});
  await page.route('**/api/v1/me/state/changes?*',missing);
  assert.equal(await page.evaluate(async()=>{S.cards.pomelo={pos:11,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();}),true);
  await page.unroute('**/api/v1/me/state/changes?*',missing);
  assert(pruned && prunedMerges===1 && (await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.pomelo);
  // Failure to persist a pending batch occurs before any network submission.
  await page.evaluate(()=>syncFromServer());
  await waitRecord(page,x=>x.record?.base && !x.record.pending);
  const countBefore=posts.length;
  await page.evaluate(()=>{window.savedDeltaIDB=deltaIDB;deltaIDB=async(...args)=>{if(args[1]==='put' && args[2]?.pending)throw Error('simulated storage failure');return window.savedDeltaIDB(...args);};});
  assert.equal(await page.evaluate(async()=>{S.cards.durian={pos:9,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();}),false);
  assert.equal(posts.length,countBefore);assert(await page.evaluate(()=>!!S.cards.durian));
  assert(!(await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.durian);
  await page.evaluate(()=>{deltaIDB=window.savedDeltaIDB;});
  assert.equal(await page.evaluate(()=>pushState()),true);
  await page.evaluate(()=>syncFromServer());
  await waitRecord(page,x=>x.record?.base && !x.record.pending);
  await page.evaluate(()=>Object.defineProperty(navigator.locks,'request',{configurable:true,value:()=>Promise.reject(Error('simulated lock failure'))}));
  assert.equal(await page.evaluate(async()=>{S.cards.honeydew={pos:13,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();}),false);
  assert(await page.evaluate(()=>!!S.cards.honeydew && syncFailed));
  assert(!(await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.honeydew);
  await page.evaluate(()=>{delete navigator.locks.request;});
  assert.equal(await page.evaluate(()=>pushState()),true);
  // A committed response from an old account cannot affect a newly selected account.
  await page.evaluate(()=>syncFromServer());
  await waitRecord(page,x=>x.record?.base && !x.record.pending);
  const switched=await api('/api/v1/auth/register','POST',{username:'switch_'+Math.random().toString(36).slice(2,10),password:'test_password_123'});
  let releaseOld, startedOld;const oldGate=new Promise(r=>releaseOld=r), oldStarted=new Promise(r=>startedOld=r);
  const holdOld=async route=>{const response=await route.fetch();startedOld();await oldGate;await route.fulfill({response});};
  await page.route('**/api/v1/me/state/deltas',holdOld);
  const oldPush=page.evaluate(async()=>{S.cards.guava={pos:10,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();});
  await oldStarted;
  const oldSlot=await page.evaluate(()=>accountSlot(AUTH));
  await page.evaluate(a=>onAuthed(a,true),switched);
  releaseOld();assert.equal(await oldPush,false);await page.unroute('**/api/v1/me/state/deltas',holdOld);
  assert.equal(await page.evaluate(()=>AUTH.userId),switched.user.id);
  assert(!(await page.evaluate(()=>S.cards.guava)));
  assert((await page.evaluate(slot=>deltaIDB(slot,'get'),oldSlot)).pending);
  assert.equal((await api('/api/v1/me/state','GET',undefined,switched.token)).state,null);
  await page.evaluate(a=>onAuthed(a,false),auth);
  await waitRecord(page,x=>!x.record?.pending && x.dirty!=='1');
  assert((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.guava);
  // Another device writes after the baseline; guarded merge retains both branches.
  await page.evaluate(()=>syncFromServer());
  await waitRecord(page,x=>x.record?.base && !x.record.pending);
  const remote=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;
  remote.cards.date={pos:4,stage:1,due:'2099-01-01T00:00:00Z'};
  await api('/api/v1/me/state','PUT',remote,seed.token);
  let merges=0;page.on('request',r=>{if(r.url().includes('/api/v1/me/state/guarded-merge')) merges++;});
  assert.equal(await page.evaluate(async()=>{S.cards.elder={pos:5,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();}),true);
  assert.equal(merges,1);
  const merged=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;
  assert(merged.cards.date && merged.cards.elder);
  await page.evaluate(()=>syncFromServer());
  await waitRecord(page,x=>x.record?.base && !x.record.pending);
  // An unrepresentable patch must use a durable guarded merge, including after
  // a response is lost; it must not escape through a legacy PUT.
  let legacyPuts=0;page.on('request',r=>{if(r.method()==='PUT' && r.url().endsWith('/api/v1/me/state'))legacyPuts++;});
  await page.evaluate(()=>{window.savedDeltaDiff=deltaDiff;deltaDiff=()=>null;});
  let mergeLost=false;
  const dropMerge=async route=>{if(!mergeLost){mergeLost=true;await route.fetch();await route.abort('connectionreset');}else await route.continue();};
  await page.route('**/api/v1/me/state/guarded-merge',dropMerge);
  assert.equal(await page.evaluate(async()=>{S.cards.jackfruit={pos:14,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();}),false);
  await page.unroute('**/api/v1/me/state/guarded-merge',dropMerge);
  assert((await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pending)).merge);
  assert((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.jackfruit);
  assert.equal(await page.evaluate(()=>pushState()),true);
  assert.equal(legacyPuts,0);
  await page.evaluate(()=>{deltaDiff=window.savedDeltaDiff;});
  await page.evaluate(()=>syncFromServer());
  await waitRecord(page,x=>x.record?.base && !x.record.pending);
  const serverBeforeEpoch=(await api('/api/v1/me/state','GET',undefined,seed.token)).state_revision;
  assert.equal(await page.evaluate(async()=>{window.oldEpoch=S.restoreEpoch;S.restoreEpoch=(S.restoreEpoch||0)+1;save();clearTimeout(save._t);return pushState();}),false);
  assert.equal(legacyPuts,0);
  assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state_revision,serverBeforeEpoch);
  await page.evaluate(()=>{if(window.oldEpoch===undefined)delete S.restoreEpoch;else S.restoreEpoch=window.oldEpoch;save();clearTimeout(save._t);});
  // Even a patch too large for the delta endpoint must retain the generation
  // fence after a database rotation, and preserve the pending target.
  await page.evaluate(()=>{window.savedDeltaDiff=deltaDiff;deltaDiff=()=>[{op:'set',path:['padding'],value:'x'.repeat(2*1024*1024)}];});
  await api('/api/v1/__ui_fixture/reset-sync-generation','POST',{});
  const beforeMerges=merges;
  assert.equal(await page.evaluate(async()=>{S.cards.fig={pos:6,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();}),false);
  assert.equal(merges,beforeMerges);assert.equal(legacyPuts,0);assert(await page.evaluate(()=>!!S.cards.fig));
  assert((await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pending)).staged);
  assert(!(await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.fig);
  await page.evaluate(()=>{deltaDiff=window.savedDeltaDiff;});
  await page.evaluate(()=>{window.confirm=()=>true;});
  assert((await page.evaluate(()=>reloadServerState())).includes('已加载'));
  assert(await page.evaluate(()=>!!JSON.parse(localStorage.getItem('vocab_before_restore_'+accountSlot(AUTH))).cards.fig));
  assert(!(await page.evaluate(()=>deltaIDB(accountSlot(AUTH),'get')))?.pending);
  // Same revision across a database rotation must not bind the old local view to a new baseline.
  const raceAuth=await api('/api/v1/auth/register','POST',{username:'base_'+Math.random().toString(36).slice(2,10),password:'test_password_123'});
  const raceState={v:1,cards:{apple:{pos:1}},log:[],pendingNew:[],settings:{}};
  await api('/api/v1/me/state','PUT',raceState,raceAuth.token);
  const raceContext=await browser.newContext(),racePage=await raceContext.newPage();await racePage.goto(base);
  let releaseSnapshot, startedSnapshot;
  const snapshotGate=new Promise(r=>releaseSnapshot=r), snapshotStarted=new Promise(r=>startedSnapshot=r);
  const holdSnapshot=async route=>{if(route.request().method()!=='POST')return route.continue();startedSnapshot();await snapshotGate;await route.continue();};
  await racePage.route('**/api/v1/me/state/snapshots**',holdSnapshot);
  await racePage.evaluate(a=>onAuthed(a,false),raceAuth);await snapshotStarted;
  await api('/api/v1/__ui_fixture/reset-sync-generation','POST',{});releaseSnapshot();
  await racePage.evaluate(()=>navigator.locks.request('vocab-delta:'+accountSlot(AUTH),()=>true));
  assert.equal(await racePage.evaluate(()=>deltaIDB(accountSlot(AUTH),'get')),undefined);
  assert(await racePage.evaluate(()=>!!S.cards.apple));
  await raceContext.close();
  // A study edit made while the first baseline snapshot is in flight is
  // uploaded against that original baseline, without requiring a reload.
  const editAuth=await api('/api/v1/auth/register','POST',{username:'edit_'+Math.random().toString(36).slice(2,10),password:'test_password_123'});
  await api('/api/v1/me/state','PUT',raceState,editAuth.token);
  const editContext=await browser.newContext(),editPage=await editContext.newPage();await editPage.goto(base);
  let releaseEdit,startedEdit;const editGate=new Promise(r=>releaseEdit=r),editStarted=new Promise(r=>startedEdit=r);
  const holdEdit=async route=>{if(route.request().method()!=='POST')return route.continue();startedEdit();await editGate;await route.continue();};
  await editPage.route('**/api/v1/me/state/snapshots**',holdEdit);
  await editPage.evaluate(a=>onAuthed(a,false),editAuth);await editStarted;
  await editPage.evaluate(()=>{S.cards.pear={pos:2};save();clearTimeout(save._t);if(localSaveFailed)throw Error('edit was not saved');});
  const editingPush=editPage.evaluate(()=>pushState());editingPush.catch(()=>{});releaseEdit();
  assert.equal(await editingPush,true);
  assert((await api('/api/v1/me/state','GET',undefined,editAuth.token)).state.cards.pear);
  await editPage.unroute('**/api/v1/me/state/snapshots**',holdEdit);await editContext.close();
  // A temporary snapshot error cannot downgrade a versioned account to the
  // legacy unguarded PUT path; explicit reload preserves edits and retries.
  const limitedAuth=await api('/api/v1/auth/register','POST',{username:'limit_'+Math.random().toString(36).slice(2,10),password:'test_password_123'});
  await api('/api/v1/me/state','PUT',raceState,limitedAuth.token);
  const limited=await browser.newContext(),limitedPage=await limited.newPage();
  const limitSnapshot=route=>route.fulfill({status:429,json:{detail:'try later'}});
  await limitedPage.route('**/api/v1/me/state/snapshots**',limitSnapshot);
  await limitedPage.goto(base);await limitedPage.evaluate(a=>onAuthed(a,false),limitedAuth);
  await limitedPage.evaluate(()=>navigator.locks.request('vocab-delta:'+accountSlot(AUTH),()=>true));
  assert(await limitedPage.evaluate(()=>localStorage.getItem(deltaMarker(accountSlot(AUTH)))==='1' && syncFailed));
  let limitedPuts=0;limitedPage.on('request',r=>{if(r.method()==='PUT'&&r.url().endsWith('/api/v1/me/state'))limitedPuts++;});
  assert.equal(await limitedPage.evaluate(async()=>{S.cards.pear={pos:2};save();clearTimeout(save._t);return pushState();}),false);
  assert.equal(limitedPuts,0);
  await limitedPage.unroute('**/api/v1/me/state/snapshots**',limitSnapshot);
  await limitedPage.evaluate(()=>{window.confirm=()=>true;});
  assert((await limitedPage.evaluate(()=>reloadServerState())).includes('已加载'));
  assert(await limitedPage.evaluate(()=>!!JSON.parse(localStorage.getItem('vocab_before_restore_'+accountSlot(AUTH))).cards.pear));
  assert.equal(await limitedPage.evaluate(()=>syncFromServer()),true);
  await waitRecord(limitedPage,v=>!!v.record&&!v.record.pending);
  await limited.close();
  // A 404 on a page after successful creation is an expired snapshot, not
  // evidence that the server lacks the snapshot API.
  const pageAuth=await api('/api/v1/auth/register','POST',{username:'page_'+Math.random().toString(36).slice(2,10),password:'test_password_123'});
  await api('/api/v1/me/state','PUT',raceState,pageAuth.token);
  const pageFail=await browser.newContext(),pageFailTab=await pageFail.newPage();
  await pageFailTab.route('**/api/v1/me/state/snapshots/**',route=>route.request().method()==='GET'?route.fulfill({status:404,json:{detail:'expired'}}):route.continue());
  await pageFailTab.goto(base);await pageFailTab.evaluate(a=>onAuthed(a,false),pageAuth);
  await pageFailTab.evaluate(()=>navigator.locks.request('vocab-delta:'+accountSlot(AUTH),()=>true));
  assert(await pageFailTab.evaluate(()=>localStorage.getItem(deltaMarker(accountSlot(AUTH)))==='1' && syncFailed));
  assert.equal(await pageFailTab.evaluate(async()=>{S.cards.orange={pos:3};save();clearTimeout(save._t);return pushState();}),false);
  await pageFail.close();
  // Old servers without snapshots use the existing full-state path.
  const old=await browser.newContext();const oldPage=await old.newPage();
  await oldPage.route('**/api/v1/me/state/snapshots**',route=>route.fulfill({status:404,json:{detail:'not found'}}));
  await oldPage.goto(base);await oldPage.evaluate(a=>onAuthed(a,false),auth);
  await oldPage.waitForTimeout(400);
  let puts=0;oldPage.on('request',r=>{if(r.method()==='PUT' && r.url().endsWith('/api/v1/me/state'))puts++;});
  assert.equal(await oldPage.evaluate(async()=>{S.cards.grape={pos:7,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);return pushState();}),true);
  assert.equal(puts,1);await old.close();
  assert.deepEqual(errors,[]);
  console.log('PASS Web delta baseline, lost response replay, guarded concurrent merge, generation fencing and old-server fallback');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();}
async function wait(page,fn){for(let i=0;i<500;i++){if(await page.evaluate(fn))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const context=await browser.newContext(),page=await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  let legacyPuts=0,partRequests=0,commits=0;
  page.on('request',r=>{if(r.method()==='PUT'&&r.url().endsWith('/api/v1/me/state'))legacyPuts++;if(r.method()==='PUT'&&r.url().includes('/delta-stages/'))partRequests++;if(r.method()==='POST'&&r.url().endsWith('/commit'))commits++;});
  await page.evaluate(()=>{S.notes='a'.repeat(2100*1024);save();clearTimeout(save._t);if(localSaveFailed)throw Error('local save failed');});
  let droppedPart=false;
  const losePart=async route=>{if(!droppedPart&&route.request().url().endsWith('/parts/1')){droppedPart=true;await route.fetch();return route.abort();}return route.continue();};
  await page.route('**/api/v1/me/state/delta-stages/**/parts/*',losePart);
  assert.equal(await page.evaluate(()=>pushState()),false);assert(droppedPart);
  const pending=await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pending);
  assert(pending.staged&&pending.batch.batch_id);assert(!(await api('/api/v1/me/state','GET',undefined,seed.token)).state.notes);
  // A damaged staged patch is never sent when it no longer matches the
  // durable local target; restoring the record resumes the original batch.
  await page.evaluate(async()=>{const slot=accountSlot(AUTH),r=await deltaIDB(slot,'get');window.savedPending=structuredClone(r.pending);
   r.pending.batch.ops[0].value='tampered';await deltaIDB(slot,'put',r);});
  const requestsBefore=partRequests;assert.equal(await page.evaluate(()=>pushState()),false);assert.equal(partRequests,requestsBefore);
  assert((await page.evaluate(()=>syncFailureMessage)).includes('不一致'));
  await page.evaluate(async()=>{const slot=accountSlot(AUTH),r=await deltaIDB(slot,'get');r.pending=window.savedPending;await deltaIDB(slot,'put',r);});
  // Expiry of an uncommitted stage is recoverable: recreate it with the same durable batch.
  assert.equal((await api('/api/v1/__ui_fixture/delta-stage-expire','POST',{token:seed.token,batch_id:pending.batch.batch_id})).changed,1);
  await page.unroute('**/api/v1/me/state/delta-stages/**/parts/*',losePart);
  await page.reload();await wait(page,async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');return !!r&&!r.pending&&localStorage.getItem(slotClock(accountSlot(AUTH),'dirty'))!=='1'&&S.notes?.length===2100*1024;});
  assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state.notes.length,2100*1024);
  assert(partRequests>8&&commits===1&&legacyPuts===0);
  await page.evaluate(()=>navigator.locks.request('vocab-delta:'+accountSlot(AUTH),()=>true));
  let droppedCommit=false;const loseCommit=async route=>{if(!droppedCommit){droppedCommit=true;await route.fetch();return route.abort();}return route.continue();};
  await page.route('**/api/v1/me/state/delta-stages/**/commit',loseCommit);
  await page.evaluate(()=>{S.notes='b'.repeat(2100*1024);save();clearTimeout(save._t);if(localSaveFailed)throw Error('local save failed');});
  assert.equal(await page.evaluate(()=>pushState()),false);if(!droppedCommit)throw Error('commit not reached: '+JSON.stringify(await page.evaluate(async()=>({syncFailureMessage,localSaveFailed,blocked:deltaBlockedSlots.has(accountSlot(AUTH)),pending:(await deltaIDB(accountSlot(AUTH),'get'))?.pending?.staged}))));
  assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state.notes[0],'b');
  const lost=await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pending);assert(lost.staged);
  await page.unroute('**/api/v1/me/state/delta-stages/**/commit',loseCommit);
  assert.equal(await page.evaluate(()=>pushState()),true);
  assert(!(await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pending)));
  assert.equal(legacyPuts,0);
  // Existing services without the new endpoint still use guarded merge.
  await page.evaluate(()=>{S.notes='c'.repeat(2100*1024);save();clearTimeout(save._t);});
  let guarded=0;page.on('request',r=>{if(r.url().endsWith('/guarded-merge'))guarded++;});
  await page.route('**/api/v1/me/state/delta-stages',route=>route.fulfill({status:404,json:{detail:'not found'}}));
  assert.equal(await page.evaluate(()=>pushState()),true);assert(guarded>0);
  assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state.notes[0],'c');assert.equal(legacyPuts,0);
  await page.unroute('**/api/v1/me/state/delta-stages');
  // A response from an old account cannot upload further parts with a new
  // account's credentials; the old account resumes its saved batch later.
  assert.equal(await page.evaluate(()=>syncFromServer()),true);
  await page.evaluate(()=>{S.notes='d'.repeat(2100*1024);save();clearTimeout(save._t);});
  const otherSeed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),otherAuth=await api('/api/v1/auth/login','POST',{username:otherSeed.username,password:otherSeed.password});
  let entered,release;const gate=new Promise(r=>release=r),started=new Promise(r=>entered=r);let heldParts=0;
  const hold=async route=>{heldParts++;const response=await route.fetch();entered();await gate;await route.fulfill({response});};
  await page.route('**/api/v1/me/state/delta-stages/**/parts/0',hold);
  const switching=page.evaluate(()=>pushState());await started;
  await page.evaluate(a=>onAuthed(a,false),otherAuth);release();assert.equal(await switching,false);
  assert.equal(heldParts,1);assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state.notes[0],'c');
  assert(!(await api('/api/v1/me/state','GET',undefined,otherSeed.token)).state.notes);
  await page.unroute('**/api/v1/me/state/delta-stages/**/parts/0',hold);
  await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');return !!r&&!r.pending&&S.notes?.[0]==='d';});
  assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state.notes[0],'d');
  // A competing revision after staging uses guarded merge and releases the
  // no-longer-needed stage only after the merged baseline is durable.
  await page.evaluate(()=>{S.notes='e'.repeat(2100*1024);save();clearTimeout(save._t);});
  let conflictEntered,conflictRelease;const conflictStarted=new Promise(r=>conflictEntered=r),conflictGate=new Promise(r=>conflictRelease=r);
  let releasedStages=0;page.on('request',r=>{if(r.method()==='DELETE'&&r.url().includes('/delta-stages/'))releasedStages++;});
  const holdCommit=async route=>{conflictEntered();await conflictGate;await route.continue();};
  await page.route('**/api/v1/me/state/delta-stages/**/commit',holdCommit);
  const conflicting=page.evaluate(()=>pushState());
  let timer;try{await Promise.race([conflictStarted,new Promise((_,reject)=>timer=setTimeout(()=>reject(Error('conflict gate timed out')),20000))]);}finally{clearTimeout(timer);}
  const remote=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;remote.cards.remote={pos:99};
  await api('/api/v1/me/state','PUT',remote,seed.token);conflictRelease();
  assert.equal(await conflicting,true);await page.unroute('**/api/v1/me/state/delta-stages/**/commit',holdCommit);
  assert(releasedStages>0);
  const merged=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;assert(merged.cards.remote&&merged.notes[0]==='e');
  // A conflict already present when the stage is created also carries the
  // structured conflict code needed to trigger guarded reconciliation.
  merged.cards.remoteTwo={pos:100};await api('/api/v1/me/state','PUT',merged,seed.token);
  await page.evaluate(()=>{S.notes='f'.repeat(2100*1024);save();clearTimeout(save._t);});
  assert.equal(await page.evaluate(()=>pushState()),true);
  const mergedAgain=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;assert(mergedAgain.cards.remoteTwo&&mergedAgain.notes[0]==='f');
  await context.close();console.log('PASS Web staged delta upload, interrupted replay, lost receipt and old-service fallback');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

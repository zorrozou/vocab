const {chromium}=require('playwright'),assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.VOCAB_BROWSER});
 try {
  const pages=await Promise.all([browser.newPage({timezoneId:'Asia/Shanghai'}),browser.newPage({timezoneId:'Asia/Shanghai'})]);
  for(const p of pages)await p.goto(base);
  const seed=await pages[0].evaluate(async()=>{
   const username='shared_'+Math.random().toString(36).slice(2,10),password='isolated_test_123';
   const r=await fetch('/api/v1/auth/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username,password})});
   if(!r.ok)throw Error('register '+r.status);const a=await r.json();
   const state=defaultState();state.calibrated=true;state.pointer=5000;
   state.log=Array.from({length:99},(_,i)=>({eventId:crypto.randomUUID(),d:today(),word:'prior'+i,kind:'review',rating:3}));
   const put=await fetch('/api/v1/me/state',{method:'PUT',headers:{'Content-Type':'application/json',Authorization:'Bearer '+a.token},body:JSON.stringify(state)});
   if(!put.ok)throw Error('seed '+put.status);return {username,password,token:a.token};
  });
  for(const p of pages){
   await p.locator('#wLogin').click();await p.locator('#aUser').fill(seed.username);await p.locator('#aPass').fill(seed.password);await p.locator('#aGo').click();
   await p.locator('#bStart').waitFor();
   // Hold uploads while both devices consume the final shared slot. This is
   // an isolated offline fork, not a race against production or fake grading.
   await p.route('**/api/v1/me/state**',r=>['POST','PUT'].includes(r.request().method())?r.abort():r.continue());
   await p.evaluate(()=>{refreshPersonalJobs=async()=>{};prefetchDay=()=>{};pickProbes=async()=>[];});
  }
  for(let i=0;i<2;i++)await pages[i].evaluate(async word=>{
   const r=await fetch('/api/v1/lexicon/word?word='+word);S.pendingNew=[await r.json()];
  },i?'pear':'apple');
  const queues=await Promise.all(pages.map(p=>p.evaluate(async()=>{
   const ready=await buildQueue();return {ready,words:session.queue.map(i=>i.word),notice:studyNotice};
  })));
  assert(queues.every(q=>q.ready),JSON.stringify(queues));
  assert.equal(queues[0].words.length,1);assert.deepEqual(queues[0].words,queues[1].words,'devices must adopt the same reserved final word');
  const chosen=queues[0].words[0],unreserved=chosen==='apple'?'pear':'apple';
  // A forged/stale screen cannot grade another word, even though the local
  // count is still only 99. Cached permits survive an in-memory cache reset.
  const blocked=await pages[1].evaluate(async({chosen,unreserved})=>{
   sharedStudyPlan=null;const fromDisk=cachedSharedPlan();
   const before=JSON.stringify(S);await learn(unreserved,2390,3);
   return {same:before===JSON.stringify(S),cached:sharedPlanPermits(fromDisk,chosen,'learn'),message:studyNotice};
  },{chosen,unreserved});
  assert(blocked.same);assert(blocked.cached);assert(blocked.message.includes('共享'));
  await pages[1].route('**/api/v1/me/study-plan',r=>r.abort());
  await pages[1].route('**/api/v1/fsrs/review',r=>r.abort());
  const restored=await pages[1].evaluate(async word=>{
   const r=await fetch('/api/v1/lexicon/word?word='+word),detail=await r.json();detail.fromPending=true;
   const queue=await prepareSharedQueue([{word,kind:'learn',detail}],false,()=>true,false);
   session={day:today(),queue,idx:0,learnedToday:0,reviewedToday:0};return queue.map(i=>i.word);
  },chosen);
  assert.deepEqual(restored,[chosen],'offline allocation must reuse the cached permit');
  await Promise.all(pages.map(p=>p.evaluate(async()=>{
   const item=session.queue[0];await learn(item.word,item.detail.pos,3,item.detail.fromPending);save();
  })));
  assert.equal(await pages[1].evaluate(word=>S.cards[word].pendingFsrs.events.length,chosen),1);
  await pages[1].unroute('**/api/v1/fsrs/review');await pages[1].evaluate(()=>flushPendingFsrs());
  const states=await Promise.all(pages.map(p=>p.evaluate(()=>JSON.parse(JSON.stringify(S)))));
  for(const state of states){
   const r=await pages[0].request.put(base+'/api/v1/me/state',{headers:{Authorization:'Bearer '+seed.token},data:state});
   assert(r.ok(),await r.text());
  }
  const r=await pages[0].request.get(base+'/api/v1/me/state',{headers:{Authorization:'Bearer '+seed.token}}),merged=(await r.json()).state;
  assert.equal(new Set(merged.log.map(e=>e.word)).size,100,'the old 101-word fork must now merge to exactly 100');
  assert.equal(merged.log.filter(e=>e.kind==='learn').length,2,'both real learning events survive, even though they refer to one distinct word');
  assert.equal(Object.keys(merged.cards).length,1);
  // An immediate settings change must sync before allocation and retry once,
  // instead of treating the old server cap as a completed learning day.
  await pages[0].unroute('**/api/v1/me/state**');
  const raised=await pages[0].evaluate(async word=>{
   clearTimeout(save._t);if(!await syncFromServer())throw Error('initial sync failed');
   markSettingChanged('dailyCap');S.settings.dailyCap=101;
   const r=await fetch('/api/v1/lexicon/word?word='+word);S.pendingNew=[await r.json()];
   save();clearTimeout(save._t);home();
   const ready=await buildQueue();
   return {ready,words:session.queue.map(i=>i.word),cap:cachedSharedPlan().configured_cap,notice:studyNotice};
  },unreserved);
  assert(raised.ready,JSON.stringify(raised));assert.equal(raised.cap,101);assert.deepEqual(raised.words,[unreserved]);
  await pages[0].route('**/api/v1/me/study-plan',r=>r.abort());
  const offlineChanged=await pages[0].evaluate(async()=>{
   S.settings.dailyCap=102;
   return (await prepareSharedQueue(session.queue,false,()=>true,false)).map(i=>i.word);
  });
  assert.deepEqual(offlineChanged,[unreserved],'a local settings change must not invalidate an existing offline permit');
  // Neither a different account nor the next day can reuse this account's pool.
  assert.equal(await pages[0].evaluate(()=>validSharedPlan(cachedSharedPlan(),'another-account',today())),false);
  assert.equal(await pages[0].evaluate(()=>validSharedPlan(cachedSharedPlan(),AUTH.accountId,addDays(today(),1))),false);
  console.log('PASS shared final word, offline cache, stale-screen blocking, merged 100-word history and immediate settings reconciliation');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

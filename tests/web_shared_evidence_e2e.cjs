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
   state.log=[];
   const put=await fetch('/api/v1/me/state',{method:'PUT',headers:{'Content-Type':'application/json',Authorization:'Bearer '+a.token},body:JSON.stringify(state)});
   if(!put.ok)throw Error('seed '+put.status);return {username,password,token:a.token};
  });
  for(const p of pages){
   await p.locator('#wLogin').click();await p.locator('#aUser').fill(seed.username);await p.locator('#aPass').fill(seed.password);await p.locator('#aGo').click();
   await p.locator('#bStart').waitFor();
   // Both devices answer before either can see the other's grade.
   await p.route('**/api/v1/me/state**',r=>['POST','PUT'].includes(r.request().method())?r.abort():r.continue());
   await p.evaluate(()=>{refreshPersonalJobs=async()=>{};prefetchDay=()=>{};pickProbes=async()=>[];});
  }
  await Promise.all(pages.map((p,index)=>p.evaluate(async ok=>{
   const r=await fetch('/api/v1/lexicon/word?word=apple'),detail=await r.json();
   const queue=await prepareSharedQueue([{kind:'probe',word:detail.word,detail}],false,()=>true,false);
   if(queue.length!==1)throw Error('No probe permit');
   session={day:today(),queue,idx:0};
   if(!answerProbe(detail,ok))throw Error('Probe rejected');save();clearTimeout(save._t);
  },index===0)));
  const states=await Promise.all(pages.map(p=>p.evaluate(()=>JSON.parse(JSON.stringify(S)))));
  for(const page of pages){
   await page.unroute('**/api/v1/me/state**');
   assert(await page.evaluate(()=>syncFromServer()),'real client sync must reconcile both answers');
  }
  const r=await pages[0].request.get(base+'/api/v1/me/state',{headers:{Authorization:'Bearer '+seed.token}}),merged=(await r.json()).state;
  assert.equal(merged.probeCount,1);assert.equal(merged.log.length,2);assert.equal(Object.keys(merged.posteriorHistory.events).length,2);
  console.log(JSON.stringify({localProbeCounts:states.map(s=>s.probeCount),mergedProbeCount:merged.probeCount,uniqueProbeWords:new Set(merged.log.filter(e=>e.kind==='probe').map(e=>e.word)).size,actualProbeGrades:merged.log.filter(e=>e.kind==='probe').length,posteriorEvents:Object.keys(merged.posteriorHistory.events).length}));
  const continued=await pages[0].evaluate(async()=>{
   if(!await syncFromServer())throw Error('sync failed');
   const count=S.probeCount;
   posteriorUpdate(1234,1,1,.25);save();clearTimeout(save._t);
   if(!await syncFromServer())throw Error('legacy-compatible continuation failed');
   return {before:count,after:S.probeCount};
  });
  assert.deepEqual(continued,{before:1,after:2});
  console.log('PASS two real clients retain both probe answers, count one effective observation and continue from the merged posterior');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

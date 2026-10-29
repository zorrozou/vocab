const {chromium}=require('playwright'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.VOCAB_BROWSER});
 try{
  const page=await browser.newPage();await page.goto(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765');await page.locator('#wGuest').click();
  let entered,hold=true;const started=new Promise(r=>entered=r);
  await page.route('**/api/v1/fsrs/review',async route=>{entered();if(hold){hold=false;await new Promise(r=>setTimeout(r,1200));}await route.abort().catch(()=>{});});
  await page.evaluate(()=>{S=defaultState();S.calibrated=true;S.settings.dailyCap=1;S.settings.newPerDay=1;void learn('apple',1,3);});
  await started;
  const stored=await page.evaluate(()=>JSON.parse(localStorage.getItem('vocab_v1')).cards.apple);
  assert.equal(Date.parse(stored.due)-Date.parse(stored.pendingFsrs.events[0].at),600000,'short due must be saved before the request completes');
  assert.equal(stored.stage,1);assert.equal(stored.fsrs,undefined);
  await page.reload();
  const result=await page.evaluate(async()=>{
   const NativeDate=Date,now=NativeDate.now()+11*60000;
   window.Date=class extends NativeDate{constructor(...args){super(...(args.length?args:[now]));}static now(){return now;}};
   // Existing offline archives may still carry the old six-day fallback.
   S.cards.apple.due=addDays(today(),6);refreshPersonalJobs=async()=>{};trackLevelDaily=()=>{};prefetchDay=()=>{};
   await buildQueue();return {queue:session.queue.map(x=>x.word),plan:dailyPlanSummary(S)};
  });
  assert.deepEqual(result.queue,['apple']);assert.equal(result.plan.repeatPlanned,1);assert.equal(result.plan.totalPlanned,1);
  await page.evaluate(()=>review('apple',3));
  const after=await page.evaluate(async()=>{await buildQueue();return {queue:session.queue.length,c:S.cards.apple};});
  assert.equal(after.queue,0);assert.equal(after.c.pendingFsrs.events.length,2);
  assert.equal(Date.parse(after.c.due)-Date.parse(after.c.pendingFsrs.events[1].at),86400000);
  await page.unroute('**/api/v1/fsrs/review');
  await page.evaluate(()=>flushPendingFsrs());
  const final=await page.evaluate(()=>S.cards.apple);
  assert.equal(final.pendingFsrs,undefined);assert.equal(final.fsrs.state,2);assert.equal(final.appliedFsrs.length,2);
  assert.equal(final.due,final.fsrs.due);
  await page.route('**/api/v1/fsrs/review',route=>route.abort());
  const lapse=await page.evaluate(async()=>{
   const at=new Date(Date.now()-11*60000).toISOString();
   const base={is_new:false,state:2,stability:200,difficulty:5,due:at,last_review:at};
   S.cards.apple={pos:1,stage:6,due:addDays(today(),6),fsrs:{...base},pendingFsrs:{base,events:[{id:'lapse',rating:1,at}]}};
   S.log=[{d:today(),word:'apple',kind:'review',rating:1}];await buildQueue();
   return {mastered:isMastered(S.cards.apple),queue:session.queue.map(x=>x.word)};
  });
  assert.equal(lapse.mastered,false);assert.deepEqual(lapse.queue,['apple']);
  console.log('PASS offline learning/relearning survives interruption and old archives, repeats within the cap and reconciles with real FSRS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

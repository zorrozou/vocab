const {chromium}=require('playwright'), assert=require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.VOCAB_BROWSER});
 try {
  const page=await browser.newPage({timezoneId:'Asia/Shanghai'});
  await page.goto(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765'); await page.locator('#wGuest').click();
  await page.route('**/api/v1/fsrs/review',r=>r.abort());
  const learned=await page.evaluate(async()=>{
   S=defaultState(); S.calibrated=true; S.pointer=5000; S.frontier=5000;
   const raw=GRID.map(x=>Math.exp(-.5*((x-5000)/500)**2)), total=raw.reduce((a,b)=>a+b,0);
   S.posterior=raw.map(x=>x/total); session={day:today(),queue:[],idx:0};
   const before=JSON.stringify(S.posterior), expected=expectedKnown();
   for(let i=0;i<10;i++) {
    await learn('word'+i,5000+i,i===0?1:3);
    await review('word'+i,i===1?1:3,false,true,5000+i);
   }
   trackLevelDaily();
   return {same:before===JSON.stringify(S.posterior),count:S.probeCount,pointer:S.pointer,
    completed:S.quizCompleted.length,log:S.log.length,expectedGrowth:expectedKnown()-expected,
    events:Object.values(S.cards).map(c=>c.pendingFsrs.events.length),
    timestamps:S.log.every(e=>typeof e.ts==='string')};
  });
  assert(learned.same,'teaching and immediate acceptance must not change global level');
  assert.equal(learned.pointer,5010,'ten taught words cannot skip hundreds of unseen words');
  assert.equal(learned.count,0); assert.equal(learned.completed,10); assert.equal(learned.log,20);
  assert(learned.events.every(n=>n===2),'all word-specific FSRS grades remain durable');
  assert(learned.timestamps); assert(learned.expectedGrowth<=10);
  await page.reload();
  const repeated=await page.evaluate(async()=>{
   const before=JSON.stringify(S.posterior), logs=S.log.length;session={day:today(),queue:[],idx:0};
   await review('word0',3,false,true,5000); // already accepted
   await review('word0',3,false,false,5000); // same-day learning step
   return {same:before===JSON.stringify(S.posterior),added:S.log.length-logs};
  });
  assert.deepEqual(repeated,{same:true,added:1});
  const delayed=await page.evaluate(async()=>{
   S=defaultState();S.calibrated=true;S.posterior=GRID.map((_,i)=>i===0?1:0);
   session={day:today(),queue:[],idx:0};
   S.cards.old={pos:7000,fsrs:{state:2,stability:30,difficulty:5,due:'2020-02-01T00:00:00Z',lastReview:'2020-01-01T00:00:00Z'}};
   await review('old',3,false,false,7000);
   const first=structuredClone(Object.values(S.posteriorHistory.events));
   await review('old',1,false,false,7000); // pending event overrides old server timestamp
   return {first,updates:Object.values(S.posteriorHistory.events).length,weight:S.track.dayW,log:S.log.length};
  });
  assert.equal(delayed.first.length,1);assert.equal(delayed.first[0].weight,.15);assert.equal(delayed.first[0].guess,.25);
  assert.equal(delayed.updates,1);assert.equal(delayed.weight,.15);assert.equal(delayed.log,2);
  // A delayed failure is still downward evidence, and undo restores it with the grade.
  const undone=await page.evaluate(async()=>{
   S=defaultState();S.calibrated=true; S.cards.old={pos:7000,fsrs:{state:2,stability:30,difficulty:5,lastReview:'2020-01-01T00:00:00Z'}};
   await review('old',1,true,false,7000);
   const evidence=Object.values(S.posteriorHistory.events)[0]; undoReview();
   return {resp:evidence.resp,weight:evidence.weight,logs:S.log.length,history:S.posteriorHistory??null};
  });
  assert.deepEqual(undone,{resp:0,weight:.4,logs:0,history:null});
  const boundaries=await page.evaluate(()=>{
   const now=new Date('2026-10-29T04:00:00Z');
   const base=()=>({cards:{x:{fsrs:{lastReview:'2026-10-28T04:00:00Z'}}},log:[]});
   const s=base(), results=[delayedReviewEvidence(s,'x',now)];
   s.cards.x.fsrs.lastReview='2026-10-28T04:00:00.001Z';results.push(delayedReviewEvidence(s,'x',now));
   s.cards.x.fsrs.lastReview='2020-01-01T00:00:00Z';s.cards.x.pendingFsrs={events:[{at:'2026-10-29T03:59:00Z'}]};
   results.push(delayedReviewEvidence(s,'x',now));delete s.cards.x.pendingFsrs;
   s.cards.x.fsrsHistory={events:[{at:'2026-10-29T03:59:00Z'}]};results.push(delayedReviewEvidence(s,'x',now));delete s.cards.x.fsrsHistory;
   s.log=[{word:'x',kind:'review',d:'2026-10-28'}];results.push(delayedReviewEvidence(s,'x',now));
   s.log[0].d='2026-10-27';results.push(delayedReviewEvidence(s,'x',now));
   s.log[0]={word:'x',kind:'review',d:'2026-10-28',ts:'2026-10-28T03:00:00Z'};results.push(delayedReviewEvidence(s,'x',now));
   s.log[0].ts='2026-10-28T05:00:00Z';results.push(delayedReviewEvidence(s,'x',now));
   results.push(delayedReviewEvidence({cards:{x:{}},log:[]},'x',now));return results;
  });
  assert.deepEqual(boundaries,[true,false,false,false,false,true,true,false,false]);
  console.log('PASS taught/accepted words preserve level; delayed retention counts once; offline/reload, undo and 24-hour/legacy boundaries');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

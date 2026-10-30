const {chromium}=require('playwright');
const assert=require('assert');
const base=process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765/';
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try {
  const page=await browser.newPage();await page.goto(base);await page.locator('#wGuest').click();
  await page.route('**/api/v1/lexicon/meta',r=>r.fulfill({json:{lexicon_revision:'end-v1',positions:10}}));
  await page.route('**/api/v1/lexicon/at?**',r=>r.fulfill({json:{words:[],next_pos:999999,exhausted:true,lexicon_revision:'end-v1'}}));
  await page.evaluate(async()=>{
   S=defaultState();S.pointer=999999;S.settings.newPerDay=10;S.settings.dailyCap=100;
   session={queue:[],idx:0,reviewedToday:0,learnedToday:0};autoPersonalize=async()=>{};
   if(!await buildQueue())throw Error('queue not ready');doneDay();
  });
  assert.equal(await page.locator('#bMore').count(),0);
  assert.equal(await page.evaluate(()=>dailyPlanSummary(S).newPlanned),0);
  assert((await page.locator('#app').innerText()).includes('词库已学完'));
  await page.evaluate(()=>{
   S=defaultState();S.settings.newPerDay=0;
   S.log=[{d:today(),word:'repeat',kind:'review',rating:1}];
   S.cards={repeat:{due:new Date(Date.now()+1200).toISOString(),fsrs:{state:3,stability:2,difficulty:5}}};
   doneDay();
  });
  await page.locator('#bMore').waitFor({timeout:7000});
  assert((await page.locator('#bMore').innerText()).includes('复习 1'));
  const counts=await page.evaluate(()=>{
   S.log=[];for(let i=0;i<10;i++)for(const kind of ['learn','review'])S.log.push({d:today(),word:'new'+i,kind,rating:3});
   for(let i=0;i<90;i++)S.log.push({d:today(),word:'old'+i,kind:'review',rating:3});
   return dailyCounts(S);
  });
  assert.deepEqual(counts,{learn:10,review:90,probe:0,total:100,attempts:110});
  await page.unroute('**/api/v1/lexicon/at?**');
  const word=(await (await page.request.get(base+'api/v1/lexicon/at?pos=1&n=1')).json()).words[0];
  await page.evaluate(async w=>{
   S=defaultState();S.settings.newPerDay=0;S.settings.autoAudio=false;
   S.cards[w.word]={pos:w.pos,due:'2000-01-01T00:00:00Z',fsrs:{state:2,stability:30,difficulty:5,lastReview:'2026-01-01T00:00:00Z'}};
   const item={kind:'review',word:w.word,quizPos:w.pos};session={day:today(),queue:[item],idx:0,reviewedToday:0,learnedToday:0};
   await answerCard(item,true);
  },word);
  await page.locator('#r1').click();
  await page.waitForFunction(()=>S.log.some(e=>e.kind==='review'&&e.rating===1));
  const grade=await page.evaluate(w=>{
   const c=S.cards[w],log=S.log.find(e=>e.word===w&&e.kind==='review');
   return {log:log.eventId,fsrs:c.fsrsHistory.events[0].id,evidence:c.studyEvidence.events[log.eventId],mastered:isMastered(c)};
  },word.word);
  assert.equal(grade.log,grade.fsrs);assert.equal(grade.evidence.rating,1);assert.equal(grade.evidence.guessed,true);assert.equal(grade.mastered,false);
  const blocked=await page.evaluate(()=>{
   const c={fsrs:{state:2,stability:200,difficulty:5},due:'2000-01-01T00:00:00Z'};S.cards.mastered=c;
   const a=studyAdmissionIssue(S,'mastered','review',today());
   c.fsrs.stability=30;c.due='2099-01-01T00:00:00Z';const b=studyAdmissionIssue(S,'mastered','review',today());
   return !!a&&!!b;
  });assert(blocked);
  const isolated=await page.evaluate(async()=>{
   S=defaultState();const at=new Date().toISOString();
   for (const word of ['bad','healthy']) {
    const base={is_new:word==='healthy',state:word==='healthy'?1:2,stability:word==='healthy'?0:-1,difficulty:word==='healthy'?0:5,rating:3};
    const event={id:crypto.randomUUID(),at,rating:3};
    S.cards[word]={pendingFsrs:{base,events:[event]},fsrsHistory:{base,events:[event]},fsrsReplayVersions:{}};
   }
   const original=JSON.stringify(S.cards.bad.pendingFsrs);
   await flushPendingFsrs();
   return {preserved:original===JSON.stringify(S.cards.bad.pendingFsrs),bad:!!S.cards.bad.fsrsIssue,good:!!S.cards.healthy.fsrs&&!S.cards.healthy.pendingFsrs};
  });assert.deepEqual(isolated,{preserved:true,bad:true,good:true});
  console.log('PASS exhaustion, timed refresh, exclusive counts, grade identity, stale review fences and isolated 422 recovery');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

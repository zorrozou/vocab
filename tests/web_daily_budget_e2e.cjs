const {chromium} = require('playwright');
const assert = require('assert');
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page = await browser.newPage();
    await page.goto(process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/');
    await page.locator('#wGuest').click();
    const result = await page.evaluate(async () => {
      S = defaultState(); S.settings.newPerDay = 5;
      S.log = Array.from({length:5}, (_,i) => ({d:today(), kind:'learn', word:'word'+i}));
      flushPendingFsrs = async () => {}; refreshPersonalJobs = async () => {};
      pickProbes = async () => []; trackLevelDaily = () => {}; prefetchDay = () => {};
      await buildQueue();
      return session.queue.filter(x => x.kind === 'learn').length;
    });
    assert.equal(result, 0);
    const budget = await page.evaluate(async () => {
      S = defaultState(); S.settings.dailyCap = 6; S.settings.newPerDay = 5;
      S.log = [
        {d:today(),kind:'learn',word:'learned'}, {d:today(),kind:'review',word:'old'},
        {d:today(),kind:'review',word:'old'}, {d:today(),kind:'probe',word:'tested'},
        {d:today(),kind:'exposure',word:'ignored'}
      ];
      S.cards = Object.fromEntries(['old','due1','due2','due3','due4'].map((w,i)=>[w,{pos:i+1,due:'2000-01-01T00:00:00Z'}]));
      S.pendingNew = [{word:'new1',pos:10,senses:[{text:'x'}]}];
      pickProbes = async () => [{word:'probe1'},{word:'probe2'},{word:'probe3'}];
      await buildQueue();
      const first = session.queue.map(x=>x.word);
      S.log.push(...first.map(word=>({d:today(),kind:'review',word})));
      await buildQueue();
      const next = session.queue.map(x=>x.word);
      const before = [{d:today(),kind:'learn',word:'protected'}, ...Array.from({length:1400},()=>({d:today(),kind:'exposure',word:'noise'}))];
      const trimmed = trimLearningLog(before);
      S = defaultState(); S.settings.dailyCap=2; S.settings.newPerDay=0;
      await buildQueue();
      return {first,next,probes:session.queue.map(x=>x.kind),protected:trimmed.some(x=>x.word==='protected')};
    });
    assert.equal(budget.first.length,3); assert(!budget.first.includes('old'));
    assert(budget.first.includes('new1'), 'new-word target must receive capacity before reviews'); assert(!budget.first.some(w=>w.startsWith('due'))); assert.equal(budget.next.length,0);
    assert.deepEqual(budget.probes,['probe','probe']);
    assert(budget.protected, 'high-volume exposures must not erase today’s learning count');
    const full = await page.evaluate(async () => {
      S = defaultState(); S.settings.dailyCap = 100; S.settings.newPerDay = 10; S.track = {throttle:true};
      S.cards = Object.fromEntries([
        ...Array.from({length:95}, (_,i)=>['due'+i,{pos:i+1,due:'2000-01-01T00:00:00Z',stage:1}]),
        ...Array.from({length:120}, (_,i)=>['mastered'+i,{pos:i+200,due:'2000-01-01T00:00:00Z',stage:6}])
      ]);
      S.pendingNew = Array.from({length:10}, (_,i)=>({word:'new'+i,pos:500+i,senses:[{text:'词义'}]}));
      pickProbes = async () => [];
      await buildQueue();
      return {queue:session.queue.map(x=>({word:x.word,kind:x.kind})), plan:dailyPlanSummary(S)};
    });
    assert.equal(full.queue.length,100); assert.equal(full.queue.filter(x=>x.kind==='learn').length,10);
    assert.equal(full.queue.filter(x=>x.kind==='review').length,90);
    assert(!full.queue.some(x=>x.word.startsWith('mastered')));
    assert.equal(full.plan.dueAvailable,95); assert.equal(full.plan.duePlanned,90); assert.equal(full.plan.newPlanned,10);
    await page.route('**/api/v1/lexicon/at?**', route => route.fulfill({json:{words:[],exhausted:true,next_pos:10988}}));
    const exhausted = await page.evaluate(async () => {
      S.pendingNew = []; S.pointer = 10987;
      await buildQueue();
      return session.queue.map(x=>x.kind);
    });
    assert.equal(exhausted.length,95, 'unused new-word capacity must be returned to due reviews');
    assert(exhausted.every(kind=>kind==='review'));
    const drill = await page.evaluate(() => {
      const state = defaultState(); state.settings.dailyCap=2; state.settings.newPerDay=2;
      state.log=[{d:today(),word:'already',kind:'review'}];
      return stubbornDrillWords(state, [['new-review',2],['already',2]]);
    });
    assert.deepEqual(drill,['already'], 'drill must respect the cap and reserve new-word capacity');
    const repeats = await page.evaluate(async () => {
      S = defaultState(); S.settings.dailyCap = 2; S.settings.newPerDay = 1;
      S.log = [{d:today(),word:'again',kind:'review'}, {d:today(),word:'done',kind:'review'}];
      S.cards = {again:{stage:1,due:'2000-01-01T00:00:00Z',fsrs:{state:3,stability:1}},
                 done:{stage:1,due:'2000-01-01T00:00:00Z',fsrs:{state:2,stability:2}},
                 mastered:{stage:6,due:'2000-01-01T00:00:00Z'}};
      const plan = dailyPlanSummary(S);
      await buildQueue();
      return {plan, queue:session.queue.map(x=>x.word)};
    });
    assert.deepEqual(repeats.queue,['again'], 'due relearning is allowed without adding a distinct word');
    assert.equal(repeats.plan.duePlanned,1); assert.equal(repeats.plan.repeatPlanned,1);
    assert.equal(repeats.plan.totalPlanned,2, 'same-day repeat must not increase distinct daily count');
    const offlineForgotten = await page.evaluate(() => {
      const card = {stage:6,fsrs:{state:2,stability:200},pendingFsrs:{events:[{rating:1}]},due:'2000-01-01T00:00:00Z'};
      S = defaultState(); S.settings.newPerDay=0; S.cards={offlineForgotten:card};
      return {mastered:isMastered(card),due:dailyPlanSummary(S).dueAvailable};
    });
    assert.equal(offlineForgotten.mastered,false); assert.equal(offlineForgotten.due,1);
    assert.equal(await page.evaluate(() => isMastered({fsrs:{state:3,stability:200}})), false,
      'a card in relearning is not mastered even if its stability remains high');
    console.log('PASS daily new-word and total workload limits across sessions, including trimmed logs');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

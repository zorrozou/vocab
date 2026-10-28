const {chromium} = require('playwright');
const assert = require('assert');
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page = await browser.newPage();
    await page.goto('http://127.0.0.1:18765/');
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
    assert(budget.first.every(w=>w.startsWith('due'))); assert.equal(budget.next.length,0);
    assert.deepEqual(budget.probes,['probe','probe']);
    assert(budget.protected, 'high-volume exposures must not erase today’s learning count');
    console.log('PASS daily new-word and total workload limits across sessions, including trimmed logs');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

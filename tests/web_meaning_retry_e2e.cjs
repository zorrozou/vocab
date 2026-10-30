const {chromium} = require('playwright');
const assert = require('assert');
const base = process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/';
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  try {
    const page = await browser.newPage();
    await page.goto(base); await page.locator('#wGuest').click();
    let mode = 'offline', calls = 0;
    await page.route('**/api/v1/lexicon/word?**', route => {
      calls++;
      if (mode === 'offline') return route.fulfill({status:503,body:'offline'});
      if (mode === 'wrong') return route.fulfill({json:{word:'wrong',pos:12,senses:[{text:'wrong meaning'}]}});
      if (mode === 'empty') return route.fulfill({json:{word:'pear',pos:2,senses:[]}});
      return route.fulfill({json:{word:'pear',pos:2,senses:[{pos:'n',text:'梨'}]}});
    });
    await page.evaluate(() => {
      S=defaultState(); S.calibrated=true; S.pointer=1;
      session={queue:[{kind:'learn',word:'pear',detail:{word:'pear',pos:2}},{kind:'learn',word:'apple',detail:{word:'apple',pos:3,senses:[{pos:'n',text:'苹果'}]}}],idx:0,reviewedToday:0,learnedToday:0};
      autoPersonalize=async()=>{}; void showLearn(session.queue[0]);
    });
    await page.locator('#bRetrySense').waitFor();
    assert(await page.locator('#bWeak').isDisabled()); assert(await page.locator('#bNext').isDisabled());
    mode='wrong'; await page.locator('#bRetrySense').click(); await page.locator('#bRetrySense').waitFor();
    assert(await page.locator('#bNext').isDisabled()); assert(!(await page.locator('#app').innerText()).includes('wrong meaning'));
    mode='empty'; await page.locator('#bRetrySense').click(); await page.locator('#bRetrySense').waitFor();
    assert(await page.locator('#bNext').isDisabled());
    mode='ok'; await page.locator('#bRetrySense').click(); await page.locator('#bNext:not([disabled])').waitFor();
    assert((await page.locator('#app .sense').innerText()).includes('梨'));
    // A second failure can be deferred without recording a rating or losing the word.
    mode='offline'; await page.evaluate(() => { session.queue[0].detail={word:'pear',pos:2}; void showLearn(session.queue[0]); });
    await page.locator('#bSkipMeaning').waitFor(); await page.locator('#bSkipMeaning').click();
    await page.locator('#bNext:not([disabled])').waitFor();
    assert.deepEqual(await page.evaluate(() => ({idx:session.idx,pending:S.pendingNew.map(x=>x.word),learns:S.log.filter(x=>x.kind==='learn').length,pointer:S.pointer})),
      {idx:1,pending:['pear'],learns:0,pointer:1});
    await page.locator('#bNext').click();
    await page.waitForFunction(() => !!S.cards.apple);
    const after = await page.evaluate(() => ({pending:S.pendingNew.map(x=>x.word),words:Object.keys(S.cards),pointer:S.pointer,learns:S.log.filter(x=>x.kind==='learn').map(x=>x.word)}));
    assert.deepEqual(after.pending,['pear']); assert.deepEqual(after.words,['apple']); assert.equal(after.pointer,4); assert.deepEqual(after.learns,['apple']);
    // Legacy single-sense cards remain usable without fetching a missing senses array.
    const before=calls;
    await page.evaluate(() => { S=defaultState(); S.calibrated=true; session={queue:[{kind:'learn',word:'old',detail:{word:'old',pos:1,sense:'旧词义'}}],idx:0,reviewedToday:0,learnedToday:0}; void showLearn(session.queue[0]); });
    await page.locator('#bNext:not([disabled])').waitFor(); assert.equal(calls,before);
    mode='wrong';
    const built = await page.evaluate(async () => { S=defaultState(); S.calibrated=true; S.settings.newPerDay=1; S.settings.dailyCap=1; S.pendingNew=[{word:'pear',pos:2}]; session={queue:[],idx:0,reviewedToday:0,learnedToday:0}; prefetchDay=()=>{}; await buildQueue(); return {word:session.queue[0].word,detail:session.queue[0].detail.word}; });
    assert.deepEqual(built,{word:'pear',detail:'pear'}, 'wrong detail must not replace a queued word');
    const beforeLegacyQueue = calls;
    const legacyBuilt = await page.evaluate(async () => { S=defaultState(); S.calibrated=true; S.settings.newPerDay=1; S.settings.dailyCap=1; S.pendingNew=[{word:'old',pos:1,sense:'旧词义'}]; session={queue:[],idx:0,reviewedToday:0,learnedToday:0}; await buildQueue(); return session.queue[0].detail.sense; });
    assert.equal(legacyBuilt,'旧词义'); assert.equal(calls,beforeLegacyQueue+1, 'a changed content revision should attempt refresh while preserving a mismatched legacy word');
    mode='ok';
    const updated=await page.evaluate(async()=>{S.pendingNew=[{word:'pear',pos:2,sense:'过时释义',lexiconRevision:'old'}];session={queue:[],idx:0};await buildQueue();return session.queue[0].detail;});
    assert.equal(updated.senses[0].text,'梨');assert.equal(updated.sense,undefined);
    console.log('PASS missing, wrong and empty meaning; retry, defer, pending preservation and legacy sense');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

const {chromium} = require('playwright');
const assert = require('assert');
const base = process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/';
const question = {word:'apple',pos:1,mode:'forward',options:[{text:'yes',ok:true},{text:'no1',ok:false},{text:'no2',ok:false},{text:'no3',ok:false}]};
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  async function guest() {
    const page = await browser.newPage(); await page.goto(base); await page.locator('#wGuest').click(); return page;
  }
  async function hold(page, pattern, payload) {
    let release, entered, settled;
    const gate = new Promise(r => {release = r;});
    const started = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(Error(`Expected request did not start: ${pattern}`)), 30000);
      entered = () => { clearTimeout(timeout); resolve(); };
    });
    const done = new Promise(r => {settled = r;});
    await page.route(pattern, async route => { entered(); await gate; if (payload) await route.fulfill({json:payload}); else await route.continue(); settled(); });
    return {release, started, done};
  }
  async function expectHeading(page, heading) {
    await page.locator('#app h2').filter({hasText:heading}).waitFor();
    assert.equal(await page.locator('#app h2').first().innerText(), heading);
  }
  try {
    // Queue preparation cannot reopen study after the user leaves its page.
    {
      const page = await guest(), gate = await hold(page,'**/api/v1/lexicon/at?**',{words:[{word:'apple',pos:1,senses:[{text:'x'}]}]});
      await page.evaluate(() => { S=defaultState(); S.calibrated=true; S.settings.newPerDay=1; S.settings.dailyCap=1; home(); });
      await page.locator('#bStart').click(); await gate.started;
      await page.locator('#btnSettings').click(); await expectHeading(page,'设置');
      gate.release(); await gate.done; await page.waitForTimeout(250); await expectHeading(page,'设置');
      assert.equal(await page.evaluate(() => session.queue.length),0); await page.close();
    }
    // A response for the previous account cannot create a queue for a new account.
    {
      const post = async (path, body={}) => { const response=await fetch(base+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}); if (!response.ok) throw Error(`${path}: ${response.status}`); return response.json(); };
      const first=await post('api/v1/__ui_fixture/recovery-case'), second=await post('api/v1/__ui_fixture/recovery-case');
      const authA=await post('api/v1/auth/login',{username:first.username,password:first.password});
      const authB=await post('api/v1/auth/login',{username:second.username,password:second.password});
      const page=await browser.newPage(); await page.goto(base);
      await page.evaluate(async account => { await onAuthed(account,false); S.settings.newPerDay=1; S.settings.dailyCap=1; home(); },authA);
      const gate=await hold(page,'**/api/v1/lexicon/at?**',{words:[{word:'pear',pos:1,senses:[{text:'x'}]}]});
      await page.locator('#bStart').click(); await gate.started;
      await page.evaluate(async account => { await onAuthed(account,false); },authB);
      gate.release(); await gate.done; await page.waitForTimeout(400);
      const result=await page.evaluate(() => ({account:AUTH.accountId, words:Object.keys(S.cards).sort(), queue:session.queue.length, heading:document.querySelector('#app h2').textContent}));
      assert.equal(result.account,authB.user.account_id); assert.deepEqual(result.words,['apple']); assert.equal(result.queue,0); assert.equal(result.heading,'今日任务');
      await page.close();
    }
    // A slow placement request cannot replace a page opened in the meantime.
    {
      const page = await guest(), gate = await hold(page,'**/api/v1/quiz?**',question);
      await page.locator('#bPlace').click(); await gate.started;
      await page.locator('#btnSettings').click(); await expectHeading(page,'设置');
      gate.release(); await gate.done; await page.waitForTimeout(250); await expectHeading(page,'设置');
      await page.close();
    }
    // A placement answer is persisted immediately even if its transition is abandoned.
    {
      const page = await guest();
      await page.route('**/api/v1/quiz?**', route => route.fulfill({json:question}));
      await page.locator('#bPlace').click(); await page.locator('#bUnknown').click();
      await page.locator('#btnSettings').click(); await page.waitForTimeout(700); await expectHeading(page,'设置');
      const result = await page.evaluate(() => ({count:S.probeCount, stored:JSON.parse(localStorage.getItem('vocab_v1')).probeCount}));
      assert.deepEqual(result,{count:1,stored:1}); await page.close();
    }
    // A slow probe request cannot redirect a user who opened statistics.
    {
      const page = await guest(), gate = await hold(page,'**/api/v1/quiz?**',question);
      await page.evaluate(() => { S=defaultState(); S.calibrated=true; const item={kind:'probe',word:'apple',detail:{word:'apple',pos:1}}; session={queue:[item],idx:0,reviewedToday:0,learnedToday:0}; void showProbe(item); });
      await gate.started; await page.locator('#btnStats').click(); await expectHeading(page,'学习统计');
      gate.release(); await gate.done; await page.waitForTimeout(250); await expectHeading(page,'学习统计');
      assert.equal(await page.evaluate(() => session.idx),0); await page.close();
    }
    // A submitted probe survives leaving the page without advancing a stale session.
    {
      const page = await guest(); await page.route('**/api/v1/quiz?**', route => route.fulfill({json:question}));
      await page.evaluate(() => { S=defaultState(); S.calibrated=true; const item={kind:'probe',word:'apple',detail:{word:'apple',pos:1}}; session={queue:[item],idx:0,reviewedToday:0,learnedToday:0}; void showProbe(item); });
      await page.locator('.opt[data-i="1"]').click(); await page.locator('#btnSettings').click();
      await page.waitForTimeout(850); await expectHeading(page,'设置');
      const result = await page.evaluate(() => ({index:session.idx, count:S.log.filter(x=>x.kind==='probe').length,
        stored:JSON.parse(localStorage.getItem('vocab_v1')).log.filter(x=>x.kind==='probe').length}));
      assert.deepEqual(result,{index:0,count:1,stored:1}); await page.close();
    }
    // A slow word detail request cannot reopen a learning card after navigation.
    {
      const page = await guest(), gate = await hold(page,'**/api/v1/lexicon/word?**',{word:'apple',pos:1,senses:[{text:'x'}],sentences:[]});
      await page.evaluate(() => { S=defaultState(); S.calibrated=true; const item={kind:'learn',word:'apple',detail:{word:'apple',pos:1}}; session={queue:[item],idx:0,reviewedToday:0,learnedToday:0}; void showLearn(item); });
      await gate.started; await page.locator('#btnSettings').click(); await expectHeading(page,'设置');
      gate.release(); await gate.done; await page.waitForTimeout(250); await expectHeading(page,'设置'); await page.close();
    }
    // A submitted learning rating survives navigation during the FSRS request.
    {
      const page = await guest(), gate = await hold(page,'**/api/v1/fsrs/review',null);
      await page.evaluate(() => { S=defaultState(); S.calibrated=true; const item={kind:'learn',word:'apple',detail:{word:'apple',pos:1,senses:[{text:'x'}]}}; session={queue:[item],idx:0,reviewedToday:0,learnedToday:0}; void showLearn(item); });
      await page.locator('#bNext').click(); await gate.started; await page.locator('#btnStats').click(); await expectHeading(page,'学习统计');
      gate.release(); await gate.done; await page.waitForFunction(() => session.learnedToday === 1); await expectHeading(page,'学习统计');
      assert.equal(await page.evaluate(() => S.log.filter(x=>x.kind==='learn' && x.word==='apple').length),1); await page.close();
    }
    // A late learning response from the old account must not alter the new account.
    {
      const post = async (path, body={}) => {
        const response=await fetch(base+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
        if (!response.ok) throw Error(`${path}: ${response.status}`); return response.json();
      };
      const first=await post('api/v1/__ui_fixture/recovery-case'), second=await post('api/v1/__ui_fixture/recovery-case');
      const authA=await post('api/v1/auth/login',{username:first.username,password:first.password});
      const authB=await post('api/v1/auth/login',{username:second.username,password:second.password});
      const page=await browser.newPage(); await page.goto(base);
      await page.evaluate(async account => { await onAuthed(account,false); },authA);
      const gate=await hold(page,'**/api/v1/fsrs/review',null);
      await page.evaluate(async() => {
        S.settings.newPerDay=1;markSettingChanged('newPerDay');save();clearTimeout(save._t);
        if(!await syncFromServer())throw Error('Failed to sync the new-word setting');
        const item={kind:'learn',word:'pear',detail:{word:'pear',pos:1,senses:[{text:'x'}]}};
        const queue=await prepareSharedQueue([item],false,()=>true,false);
        if(queue.length!==1)throw Error('Failed to reserve the test word');
        session={day:today(),queue,idx:0,reviewedToday:0,learnedToday:0};void showLearn(item);
      });
      await page.locator('#bNext').click(); await gate.started;
      await page.evaluate(async account => { await onAuthed(account,false); },authB);
      gate.release(); await gate.done; await page.waitForTimeout(400);
      const result=await page.evaluate(a => ({account:AUTH.accountId, words:Object.keys(S.cards).sort(),
        old:JSON.parse(localStorage.getItem(accountSlot({userId:a.user.id,accountId:a.user.account_id,username:a.user.username}))).cards.pear,
        count:session.learnedToday, heading:document.querySelector('#app h2').textContent}),authA);
      assert.equal(result.account,authB.user.account_id); assert.deepEqual(result.words,['apple']);
      assert(result.old && result.old.pendingFsrs); assert.equal(result.count,0); assert.equal(result.heading,'今日任务');
      await page.close();
    }
    // A submitted acceptance rating is saved without reopening the quiz.
    {
      const page = await guest(), gate = await hold(page,'**/api/v1/fsrs/review',null);
      await page.route('**/api/v1/quiz?**', route => route.fulfill({json:question}));
      await page.evaluate(() => { S=defaultState(); S.calibrated=true; S.cards.apple={pos:1,stage:1,due:'2000-01-01T00:00:00Z'}; session={queue:[],idx:0,reviewedToday:0,learnedToday:0}; void quizRound(['apple'],0); });
      await page.locator('.opt[data-i="0"]').click(); await gate.started;
      await page.locator('#btnSettings').click(); await expectHeading(page,'设置');
      gate.release(); await gate.done;
      await page.waitForFunction(() => (S.quizCompleted || []).includes('apple'));
      await page.waitForTimeout(750); await expectHeading(page,'设置');
      assert.equal(await page.evaluate(() => S.log.filter(x=>x.kind==='review' && x.word==='apple').length),1); await page.close();
    }
    // A slow validation-set request cannot take over after navigation.
    {
      const page = await guest(), gate = await hold(page,'**/api/v1/placement/set?**',{words:[{word:'apple',pos:1}]});
      await page.evaluate(() => { void startValidation(); }); await gate.started;
      await page.locator('#btnStats').click(); await expectHeading(page,'学习统计');
      gate.release(); await gate.done; await page.waitForTimeout(250); await expectHeading(page,'学习统计');
      assert.equal(await page.evaluate(() => validation),null); await page.close();
    }
    // An answered validation question cannot reopen its result after navigation.
    {
      const page = await guest(); await page.route('**/api/v1/quiz?**', route => route.fulfill({json:question}));
      await page.evaluate(() => { validation={words:[{word:'apple',pos:1,reverse:false}],idx:0,posterior:null,correct:0,failed:0}; void showValidation(); });
      await page.locator('.opt[data-i="0"]').click(); await page.locator('#btnSettings').click();
      await page.waitForTimeout(650); await expectHeading(page,'设置');
      assert.equal(await page.evaluate(() => validation.idx),1); await page.close();
    }
    console.log('PASS placement, probe and learning navigation guards preserve submitted work');
  } finally { await browser.close(); }
})().catch(error => {console.error(error);process.exit(1)});

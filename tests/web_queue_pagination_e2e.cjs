const {chromium} = require('playwright');
const assert = require('assert');
const base = process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/';
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  const word = (name,pos) => ({word:name,pos,senses:[{pos:'n',text:'meaning'}]});
  try {
    const page = await browser.newPage();
    const first = await (await page.request.get(base+'api/v1/lexicon/at?pos=1&n=1')).json();
    assert.equal(first.words.length,1); assert(first.next_pos > 1); assert.equal(first.exhausted,false);
    const beyond = await (await page.request.get(base+'api/v1/lexicon/at?pos=999999&n=1')).json();
    assert.deepEqual(beyond.words,[]); assert.equal(beyond.exhausted,true); assert.equal(beyond.next_pos,999999);
    await page.goto(base); await page.locator('#wGuest').click();
    let mode = 'fail', requests = [], sizes = [];
    await page.route('**/api/v1/lexicon/at?**', async route => {
      const url = new URL(route.request().url());
      const pos = Number(url.searchParams.get('pos'));
      requests.push(pos); sizes.push(Number(url.searchParams.get('n')));
      if (mode === 'fail' && pos === 4) return route.fulfill({status:503,body:'unavailable'});
      if (mode === 'empty') return route.fulfill({json:{from:pos,words:[],next_pos:pos,exhausted:false}});
      if (mode === 'end') return route.fulfill({json:{from:pos,words:[word('last',pos)],next_pos:pos+1,exhausted:true}});
      if (mode === 'legacy') return route.fulfill({json:{from:pos,words:pos === 1 ? [word('known1',1),word('known2',2),word('known3',3)] : [word('legacynew',4)]}});
      if (pos === 1) return route.fulfill({json:{from:1,words:[word('known1',1),word('known2',2),word('known3',3)],next_pos:4,exhausted:false}});
      if (pos === 4) return route.fulfill({json:{from:4,words:[],next_pos:44,exhausted:false}});
      return route.fulfill({json:{from:pos,words:[word('new1',44),word('new2',45)],next_pos:46,exhausted:false}});
    });
    await page.evaluate(() => {
      S=defaultState(); S.calibrated=true; S.pointer=1; S.frontier=1; S.settings.newPerDay=2; S.settings.dailyCap=2;
      S.cards=Object.fromEntries(['known1','known2','known3'].map((w,i)=>[w,{pos:i+1,due:'2099-01-01T00:00:00Z'}]));
      session={queue:[],idx:0,reviewedToday:0,learnedToday:0}; home();
    });
    await page.locator('#bStart').click();
    await page.waitForFunction(() => document.querySelector('#startHint')?.textContent.includes('任务加载失败'));
    assert.deepEqual(requests,[1,4]);
    assert.equal(await page.evaluate(() => session.queue.length),0);
    assert.equal(await page.evaluate(() => S.pointer),1);
    mode='ok'; requests=[]; sizes=[]; await page.locator('#bStart').click();
    await page.waitForFunction(() => session.queue.length === 2);
    assert.deepEqual(requests,[1,4,44]);
    assert.deepEqual(sizes,[4,8,16]);
    assert.deepEqual(await page.evaluate(() => session.queue.map(x=>x.word)),['new1','new2']);
    assert.equal(await page.evaluate(() => S.pointer),1, 'preparation must not advance learning pointer');
    // An invalid empty response cannot falsely complete the day.
    mode='empty'; requests=[];
    await page.evaluate(() => { S=defaultState(); S.calibrated=true; S.settings.newPerDay=1; S.settings.dailyCap=1; session={queue:[],idx:0,reviewedToday:0,learnedToday:0}; home(); });
    await page.locator('#bStart').click();
    await page.waitForFunction(() => document.querySelector('#startHint')?.textContent.includes('任务加载失败'));
    assert.equal(await page.evaluate(() => session.queue.length),0);
    // At the confirmed end of the vocabulary, a partial final batch is usable.
    mode='end';
    await page.evaluate(() => { S.settings.newPerDay=2; S.settings.dailyCap=2; });
    await page.locator('#bStart').click();
    await page.waitForFunction(() => session.queue.length === 1);
    assert.deepEqual(await page.evaluate(() => session.queue.map(x=>x.word)),['last']);
    // Older servers can still paginate non-empty pages without the new cursor.
    mode='legacy'; requests=[];
    await page.evaluate(() => { S=defaultState(); S.calibrated=true; S.pointer=1; S.settings.newPerDay=1; S.settings.dailyCap=1; S.cards=Object.fromEntries(['known1','known2','known3'].map((w,i)=>[w,{pos:i+1,due:'2099-01-01T00:00:00Z'}])); session={queue:[],idx:0,reviewedToday:0,learnedToday:0}; home(); });
    await page.locator('#bStart').click();
    await page.waitForFunction(() => session.queue.length === 1);
    assert.deepEqual(requests,[1,4]);
    assert.deepEqual(await page.evaluate(() => session.queue.map(x=>x.word)),['legacynew']);
    console.log('PASS queue pagination, transient failure, invalid response, legacy server and confirmed end of vocabulary');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });

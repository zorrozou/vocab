const {chromium} = require('playwright');
const assert = require('assert');
const base = (process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765').replace(/\/$/, '');
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  try {
    const page = await browser.newPage({viewport:{width:320,height:780}});
    await page.goto(base);
    await page.locator('#wGuest').click();
    assert.equal(await page.locator('button#gBanner').count(), 1);
    await page.locator('#btnSettings').click();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'settings overflow on narrow screen');
    assert.equal(await page.locator('[data-voice="en-US-AriaNeural"]').evaluate(e => e.style.borderColor), 'rgb(47, 111, 237)');
    await page.locator('[data-new="20"]').click();
    await page.locator('#btnStats').click();
    await page.reload();
    assert.equal(await page.evaluate(() => S.settings.newPerDay), 20);
    await page.locator('#btnSettings').click();
    await page.route('**/api/v1/placement/set?**', route => route.abort());
    await page.locator('#bValidation').click();
    await page.locator('#validationStartError').waitFor();
    assert.match(await page.locator('#validationStartError').innerText(), /网络/);
    assert.equal(await page.locator('#bValidation').isEnabled(), true);
    await page.unroute('**/api/v1/placement/set?**');
    await page.evaluate(() => {
      S.cards = {apple:{stage:1,due:'2030-01-01',pos:1}, banana:{stage:1,due:'2030-01-01',pos:2}};
      S.log = [
        {d:today(),word:'apple',kind:'learn',rating:1}, {d:today(),word:'apple',kind:'review',rating:2},
        {d:today(),word:'banana',kind:'placement',rating:1}, {d:today(),word:'banana',kind:'shadow',rating:1}
      ];
      showStats();
    });
    assert.match(await page.locator('#bDrill').innerText(), /1 词/);
    await page.locator('#bDrill').click();
    assert.deepStrictEqual(await page.evaluate(() => session.queue.map(x => x.word)), ['apple']);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await page.evaluate(() => { syncFailed = true; syncFailureMessage = '测试同步错误'; renderUserTag(); });
    assert.equal(await page.locator('#syncStatus').isVisible(), true);
    await page.locator('#syncStatus').click();
    await page.locator('#wLogin').click();
    assert.equal(await page.locator('#aUser').getAttribute('aria-label'), '用户名');
    console.log('PASS settings persistence, validation errors, accessible controls and matching drill queue');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });

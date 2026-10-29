const {chromium} = require('playwright');
const assert = require('assert');
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  try {
    const page = await browser.newPage();
    await page.goto(process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/');
    await page.locator('#wGuest').click();
    await page.evaluate(() => {
      S = defaultState(); S.calibrated = true; S.settings.dailyCap = 3; S.settings.newPerDay = 0;
      S.cards = {apple: {pos:1,due:'2000-01-01T00:00:00Z'}, pear: {pos:2,due:'2001-01-01T00:00:00Z'}};
      S.log = ['a','b','c'].map(word => ({d:today(),word,kind:'review',rating:3}));
      session = {reviewedToday:0, learnedToday:0}; autoPersonalize = async () => {};
      doneDay();
    });
    assert.equal(await page.locator('#bMore').count(), 0);
    assert((await page.locator('#laterRow').innerText()).includes('今日已达上限，还有 2 词到期'));
    assert.equal(await page.locator('#app h2').first().innerText(), '今日已达上限');
    assert.equal(await page.locator('.stat').first().innerText(), '3\n今日复习');
    await page.locator('#bAdjustCap').click();
    await page.locator('[data-cap="200"]').click();
    assert.equal(await page.evaluate(() => S.settings.dailyCap), 200);
    await page.evaluate(() => { S.settings.dailyCap = 3; doneDay(); });
    await page.evaluate(() => { S.log = S.log.filter(x => x.word !== 'c'); doneDay(); });
    assert.equal(await page.locator('#bMore').innerText(), '继续今日任务（复习 1 · 新词 0）→');
    await page.evaluate(() => {
      S.cards = {apple: {pos:1,due:'2000-01-01T00:00:00Z'}};
      S.log = [{d:today(),word:'apple',kind:'review',rating:3}]; doneDay();
    });
    assert.equal(await page.locator('#bMore').count(), 0);
    assert.equal((await page.locator('#laterRow').innerText()).trim(), '');
    await page.evaluate(() => { S.log.push({d:today(),word:'probe-word',kind:'probe',rating:3}); doneDay(); });
    assert((await page.locator('#app').innerText()).includes('每日上限还计入 1 个水平探测词'));
    console.log('PASS done screen respects remaining capacity and already-reviewed words');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

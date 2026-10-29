const {chromium} = require('playwright');
const assert = require('assert');
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.route('**/api/v1/tts?**', route => route.fulfill({status:503, body:'offline audio'}));
    await page.goto(process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/', {waitUntil:'domcontentloaded'});
    await page.locator('#wGuest').click();
    await page.locator('#bPlace').click();
    for (let i = 0; i < 30; i++) {
      await page.waitForFunction(() => { const b = document.querySelector('#bUnknown'); return b && !b.disabled; }, null, {timeout:15000});
      await page.locator('#bUnknown').click();
      await page.waitForFunction(n => S.probeCount >= n, i + 1, {timeout:15000});
    }
    await page.locator('#bGo').click({timeout:15000});
    assert.equal(await page.evaluate(() => S.calibrated), true);
    // The completed placement now starts the first study queue directly.
    // Probe cards appear before the first learning card.
    for (let i = 0; i < 5; i++) {
      await page.waitForFunction(() => !!document.querySelector('#bNext') || [...document.querySelectorAll('.opt')].some(x => !x.disabled), null, {timeout:30000});
      if (await page.locator('#bNext').count()) break;
      await page.locator('.opt:not([disabled])').first().click();
    }
    await page.locator('#bNext').click({timeout:30000});
    await page.waitForFunction(() => Object.keys(S.cards).length > 0 && S.log.some(x => x.kind === 'learn'), null, {timeout:30000});
    const state = await page.evaluate(() => ({cards: Object.keys(S.cards).length, stored: JSON.parse(localStorage.getItem('vocab_v1')).log.some(x => x.kind === 'learn')}));
    assert(state.cards >= 1 && state.stored);
    assert.deepEqual(errors, []);
    console.log('PASS browser guest placement, queue, first study and local persistence');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

const { chromium } = require('playwright');
const assert = require('assert');

(async () => {
  const browser = await chromium.launch({headless: true, executablePath: process.env.VOCAB_BROWSER || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    for (const weaveFirst of [true, false]) {
      const page = await browser.newPage();
      let releaseTrio, releaseWeave;
      const trioGate = new Promise(resolve => { releaseTrio = resolve; });
      const weaveGate = new Promise(resolve => { releaseWeave = resolve; });
      await page.route('**/api/v1/sentence/trio?**', async route => {
        await trioGate;
        await route.fulfill({json: {sentences: [{tier: 1, text: 'An apple a day.'}, {tier: 2, text: 'The apple fell.'}, {tier: 3, text: 'Apple trees flourish.'}]}});
      });
      await page.route('**/api/v1/sentence/weave?**', async route => {
        await weaveGate;
        await route.fulfill({json: {text: 'The apple is bright.'}});
      });
      await page.goto(process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/');
      await page.locator('#wGuest').click();
      await page.evaluate(async () => {
        autoPlaySequence = () => {}; personalHeaders = async () => ({}); Math.random = () => 0;
        S.log.push({word:'bright', rating:1, d:today(), kind:'review'});
        const item = {kind:'learn', word:'apple', detail:{word:'apple', pos:1, senses:[{pos:'n', text:'苹果'}], sentences:[]}};
        session.queue = [item]; session.idx = 0;
        await showLearn(item);
      });
      if (weaveFirst) {
        releaseWeave();
        await page.getByText('The apple is bright.').waitFor();
        releaseTrio();
        await page.getByText('Apple trees flourish.').waitFor();
      } else {
        releaseTrio();
        await page.getByText('Apple trees flourish.').waitFor();
        releaseWeave();
        await page.getByText('The apple is bright.').waitFor();
      }
      assert.equal(await page.getByText('The apple is bright.').count(), 1, 'weave sentence must survive trio completion');
      assert.equal(await page.locator('#app .sent').count(), 4, 'three tiers and the weave must all remain visible');
      await page.close();
    }
    {
      const page = await browser.newPage();
      let releaseTrio, calls = 0;
      const trioGate = new Promise(resolve => { releaseTrio = resolve; });
      await page.route('**/api/v1/sentence/report?**', route => route.fulfill({json: {ok: true}}));
      await page.route('**/api/v1/sentence/trio?**', async route => {
        if (++calls === 1) await trioGate;
        await route.fulfill({json: {sentences: [{tier:1,text:'Final first'}, {tier:2,text:'Final second'}, {tier:3,text:'Final third'}]}});
      });
      await page.route('**/api/v1/lexicon/at?**', route => route.fulfill({json: {words:[{word:'apple', sentences:[{tier:1,text:'Swap replacement'}]}]}}));
      await page.goto(process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/');
      await page.locator('#wGuest').click();
      await page.evaluate(async () => {
        autoPlaySequence = () => {};
        const item = {kind:'learn',word:'apple',detail:{word:'apple',pos:1,senses:[{text:'苹果'}],sentences:[{tier:1,text:'Original sentence'}]}};
        session.queue = [item]; session.idx = 0;
        await showLearn(item);
      });
      await page.locator('.bad[data-kind="static"]').click();
      await page.getByText('Swap replacement').waitFor();
      releaseTrio();
      await page.getByText('Final third').waitFor();
      assert.equal(await page.getByText('Swap replacement').count(), 0, 'refreshed base sentences must replace earlier swap results');
      assert.equal(await page.locator('#app .sent').count(), 3);
      await page.close();
    }
    console.log('PASS trio and weave survive both response orders');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

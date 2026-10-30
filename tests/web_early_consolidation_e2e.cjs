const {chromium} = require('playwright');
const assert = require('assert');
const base = (process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765').replace(/\/$/, '');
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  try {
    const page = await browser.newPage(); await page.goto(base); await page.locator('#wGuest').click();
    const result = await page.evaluate(async () => {
      S.calibrated = true; S.posterior = null;
      S.settings.newPerDay = 0; S.settings.dailyCap = 1;
      S.cards = {apple:{pos:1,stage:1,due:'2099-01-01T00:00:00Z',fsrs:{stability:2}}};
      S.log = [{d:addDays(today(),-3),word:'apple',rating:3,kind:'learn'}, {d:today(),word:'apple',rating:3,kind:'exposure',source:'audio'}];
      const random = Math.random; Math.random = () => 0;
      try { const ok = await buildQueue(); clearTimeout(save._t); return {ok, queue:session.queue.map(x=>({kind:x.kind,word:x.word}))}; }
      finally { Math.random = random; }
    });
    assert(result.ok); assert.deepEqual(result.queue,[], 'automatic study must not select a word before it is due');
    const exposureOnly = await page.evaluate(async () => {
      S.log = [{d:addDays(today(),-3),word:'apple',rating:3,kind:'exposure',source:'audio'}];
      const random = Math.random; Math.random = () => 0;
      try { const ok = await buildQueue(); clearTimeout(save._t); return {ok,queue:session.queue}; }
      finally { Math.random = random; }
    });
    assert(exposureOnly.ok); assert.deepEqual(exposureOnly.queue, [], 'exposure alone must not create a review history');
    console.log('PASS automatic study excludes early consolidation regardless of exposure history');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });

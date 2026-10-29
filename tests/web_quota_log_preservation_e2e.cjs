const {chromium} = require('playwright');
const assert = require('assert');
const base = (process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765').replace(/\/$/, '');
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  try {
    const page = await browser.newPage();
    await page.goto(base); await page.locator('#wGuest').click();
    const result = await page.evaluate(() => {
      const slot = accountSlot(AUTH);
      S.log = Array.from({length:1205}, (_, i) => ({d:'2020-01-01', word:'example', kind:'learn', rating:3, eventId:String(i)}));
      const before = JSON.stringify(S), originalSet = Storage.prototype.setItem;
      Storage.prototype.setItem = function(key, value) { if (key === slot) throw Error('injected storage failure'); return originalSet.call(this, key, value); };
      let failed, preserved;
      try { save(); failed = localSaveFailed; preserved = JSON.stringify(S) === before; }
      finally { Storage.prototype.setItem = originalSet; }
      save();
      return {failed, preserved, recovered:!localSaveFailed && JSON.parse(localStorage.getItem(slot)).log.length === 1200};
    });
    assert(result.failed, 'injected write failure must be reported');
    assert(result.preserved, 'a failed save must preserve the complete in-memory state for export');
    assert(result.recovered, 'a retry must save the normally trimmed state');
    console.log('PASS failed browser save preserves the complete in-memory log');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });

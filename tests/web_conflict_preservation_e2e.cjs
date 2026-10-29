const {chromium} = require('playwright');
const assert = require('assert');
const base = (process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765').replace(/\/$/, '');
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  try {
    const page = await browser.newPage();
    await page.goto(base);
    await page.locator('#wGuest').click();
    const result = await page.evaluate(() => {
      const slot = accountSlot(AUTH);
      S.log = Array.from({length:1205}, (_, i) => ({d:'2020-01-01', word:'example', kind:'learn', rating:3, eventId:String(i)}));
      const memory = JSON.stringify(S);
      const other = JSON.parse(localStorage.getItem(slot));
      other.cards.other = {pos:1};
      const otherRaw = JSON.stringify(other);
      localStorage.setItem(slot, otherRaw);
      save();
      const first = {unchanged:JSON.stringify(S) === memory, stored:localStorage.getItem(slot) === otherRaw,
        blocked:deltaConcurrentSlots.has(slot), failed:localSaveFailed, message:document.querySelector('#syncStatus').textContent};
      save();
      return {...first, stillUnchanged:JSON.stringify(S) === memory, stillStored:localStorage.getItem(slot) === otherRaw};
    });
    assert(result.unchanged && result.stored && result.blocked && result.failed);
    assert(result.stillUnchanged && result.stillStored);
    assert.match(result.message, /冲突/);
    await page.locator('#btnSettings').click();
    assert.match(await page.locator('#settingsSaveStatus').innerText(), /不一致/);
    console.log('PASS blocked concurrent saves preserve both the current page and the other stored state');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });

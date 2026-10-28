const {chromium} = require('playwright');
const assert = require('assert');
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page = await browser.newPage({acceptDownloads:true});
    await page.goto('http://127.0.0.1:18765/');
    await page.evaluate(() => { localStorage.setItem('vocab_v1', '{broken'); localStorage.setItem('vocab_guest','1'); localStorage.setItem('vocab_write_ts','900'); localStorage.setItem('vocab_last_sync_ts','800'); });
    await page.reload();
    await page.locator('#bExportCorrupt').waitFor();
    assert.equal(await page.evaluate(() => localStorage.getItem('vocab_v1')), '{broken');
    assert(await page.locator('#btnSettings').isDisabled());
    const download = page.waitForEvent('download');
    await page.locator('#bExportCorrupt').click();
    assert((await download).suggestedFilename().startsWith('vocab-damaged-'));
    page.once('dialog', d => d.dismiss());
    await page.locator('#bClearCorrupt').click();
    assert.equal(await page.evaluate(() => localStorage.getItem('vocab_v1')), '{broken');
    page.once('dialog', d => d.accept());
    await page.locator('#bClearCorrupt').click();
    await page.waitForLoadState('domcontentloaded');
    assert.deepEqual(await page.evaluate(() => Object.keys(JSON.parse(localStorage.getItem('vocab_v1')).cards)), []);
    assert.equal(await page.evaluate(() => localStorage.getItem('vocab_write_ts')), '0');
    // A corrupt guest slot encountered during account switching must not be replaced.
    await page.evaluate(() => { localStorage.removeItem('vocab_guest'); localStorage.setItem('vocab_v1_guest', '{guest-broken'); });
    await page.reload();
    await page.locator('#wGuest').click();
    await page.locator('#bExportCorrupt').waitFor();
    assert.equal(await page.evaluate(() => localStorage.getItem('vocab_v1_guest')), '{guest-broken');
    const slotDownload = page.waitForEvent('download');
    await page.locator('#bExportCorrupt').click();
    assert((await slotDownload).suggestedFilename().startsWith('vocab-damaged-'));
    console.log('PASS corrupt startup and account-slot data are preserved and exportable');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

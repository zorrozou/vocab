const {chromium} = require('playwright');
const assert = require('assert');
const fs = require('fs');
(async () => {
  const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  const browser = await chromium.launch({headless: true, ...(fs.existsSync(chrome) ? {executablePath: chrome} : {})});
  try {
    const page = await browser.newPage();
    let requestedPosition;
    await page.route('http://127.0.0.1:18765/', route => route.fulfill({contentType: 'text/html', body: fs.readFileSync('web/index.html', 'utf8')}));
    await page.route('**/api/v1/quiz?**', route => {
      requestedPosition = Number(new URL(route.request().url()).searchParams.get('pos'));
      return route.fulfill({json: {word: 'fixture-'+requestedPosition, pos: requestedPosition,item_id:'a'.repeat(64),
        options: [{text:'a',ok:true},{text:'b',ok:false},{text:'c',ok:false},{text:'d',ok:false}]}});
    });
    await page.goto('http://127.0.0.1:18765/');
    await page.locator('#wGuest').click();
    await page.evaluate(() => {
      S.probeCount = 3; S.calibrated = false; S.posterior = Array(49).fill(1 / 49);
      S.bandStats = {'0': {a: 1, b: 1}, '1': {a: 0, b: 1}};
      S.bandEvidence = {'1': {events: {old: {pos: 2001,at:'2026-01-01T00:00:00Z',ok:false}}}};
      save(); clearTimeout(save._t);
    });
    await page.reload();
    await page.evaluate(() => { Math.random = () => 0; });
    await page.locator('#bPlace').click();
    await page.locator('#bUnknown').waitFor();
    assert(requestedPosition >= 1 && requestedPosition <= 2000,
      `unattributable legacy totals must not imply a band is known, got ${requestedPosition}`);
    assert.notEqual(requestedPosition, 2001, 'resumed placement repeated an already answered position');
    await page.evaluate(() => {
      S.probeCount = 30;
      S.bandStats = {'0': {a: 1, b: 9}, '1': {a: 3, b: 5}, '2': {a: 2, b: 2},
                     '3': {a: 1, b: 1}, '4': {a: 1, b: 1}, '5': {a: 3, b: 1}};
      finishPlace(0);
    });
    const text = await page.locator('#app').innerText();
    assert(text.includes('待校准'));assert(text.includes('词库内词义识别范围'));
    console.log('PASS web resumes stratified placement and displays persisted band totals');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

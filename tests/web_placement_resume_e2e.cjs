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
      return route.fulfill({json: {word: 'fixture', pos: requestedPosition,
        options: [{text:'a',ok:true},{text:'b',ok:false},{text:'c',ok:false},{text:'d',ok:false}]}});
    });
    await page.goto('http://127.0.0.1:18765/');
    await page.locator('#wGuest').click();
    await page.evaluate(() => {
      S.probeCount = 3; S.calibrated = false; S.posterior = Array(49).fill(1 / 49);
      S.bandStats = {'0': {a: 1, b: 1}, '1': {a: 0, b: 1}};
      S.bandEvidence = {'1': {events: {old: {pos: 2001}}}};
      save(); clearTimeout(save._t);
    });
    await page.reload();
    await page.evaluate(() => { Math.random = () => 0; });
    await page.locator('#bPlace').click();
    await page.locator('#bUnknown').waitFor();
    assert(requestedPosition >= 2001 && requestedPosition <= 4000,
      `fourth question should remain in the second band, got ${requestedPosition}`);
    assert.notEqual(requestedPosition, 2001, 'resumed placement repeated an already answered position');
    await page.evaluate(() => {
      S.probeCount = 30;
      S.bandStats = {'0': {a: 1, b: 9}, '1': {a: 3, b: 5}, '2': {a: 2, b: 2},
                     '3': {a: 1, b: 1}, '4': {a: 1, b: 1}, '5': {a: 3, b: 1}};
      finishPlace(0);
    });
    const text = await page.locator('#app').innerText();
    for (const score of ['1~2000：1/10', '2001~4000：3/8', '10001~10987：3/4']) assert(text.includes(score));
    console.log('PASS web resumes stratified placement and displays persisted band totals');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

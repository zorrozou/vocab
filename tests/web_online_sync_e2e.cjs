const {chromium} = require('playwright');
const fs = require('fs');
const assert = require('assert');
(async () => {
  const fixture = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const browser = await chromium.launch({headless:true, executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page = await browser.newPage();
    let pushes = 0;
    await page.route('**/api/v1/me/state', route => { if (route.request().method() === 'PUT') pushes++; return route.continue(); });
    await page.goto('http://127.0.0.1:18765/');
    await page.evaluate(({token, state, accountId}) => {
      AUTH = {userId:1, accountId, username:'test', token}; S = state; syncFailed = true;
      flushPendingFsrs = async () => {}; refreshPersonalJobs = async () => {};
      localStorage.setItem('vocab_write_ts','42'); localStorage.setItem('vocab_last_sync_ts','0');
      window.dispatchEvent(new Event('online'));
    }, fixture);
    await page.waitForFunction(() => !syncFailed && localStorage.getItem('vocab_last_sync_ts') === '42');
    assert.equal(pushes,1);
    console.log('PASS reconnect retries a previously failed state upload even without pending ratings');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

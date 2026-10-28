const {chromium} = require('playwright');
const assert = require('assert');
const base = 'http://127.0.0.1:18765';
async function request(path, body) {
  const response = await fetch(base + path, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body || {})});
  if (!response.ok) throw Error(`${path}: ${response.status}`);
  return response.json();
}
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  try {
    for (const correct of [false, true]) {
      const seed = await request('/api/v1/__ui_fixture/undo-case');
      const account = await request('/api/v1/auth/login', {username:seed.username,password:seed.password});
      const page = await browser.newPage();
      await page.goto(base + '/');
      await page.evaluate(async auth => { await onAuthed(auth, false); }, account);
      let release, entered;
      const gate = new Promise(resolve => { release = resolve; });
      const started = new Promise(resolve => { entered = resolve; });
      await page.route('**/api/v1/fsrs/review', async route => { entered(); await gate; await route.continue(); });
      await page.locator('#bStart').click();
      await page.locator(`.opt[data-i="${correct ? 0 : 1}"]`).click();
      if (correct) { await page.locator('#r3').click(); }
      await started;
      await page.locator(correct ? '#btnStats' : '#btnSettings').click();
      const heading = correct ? '学习统计' : '设置';
      await page.locator('#app h2').filter({hasText:heading}).waitFor();
      const finished = page.waitForResponse(response => response.url().includes('/api/v1/fsrs/review'));
      release(); await finished;
      await page.waitForFunction(() => session.reviewedToday === 1);
      assert.equal(await page.locator('#app h2').first().innerText(), heading);
      const result = await page.evaluate(() => ({ratings:S.log.filter(x=>x.kind==='review').map(x=>x.rating), undo:undoSnapshot}));
      assert.deepEqual(result.ratings, [correct ? 3 : 1]);
      assert.equal(result.undo, null);
      assert(await page.evaluate(async () => { clearTimeout(save._t); return await pushState(); }), 'review did not sync');
      const response = await fetch(base+'/api/v1/me/state', {headers:{Authorization:'Bearer '+seed.token}});
      assert(response.ok);
      const persisted = (await response.json()).state.log.filter(x => x.kind === 'review').map(x => x.rating);
      assert.deepEqual(persisted, [correct ? 3 : 1]);
      await page.close();
    }
    console.log('PASS delayed review cannot replace settings or stats after navigation');
  } finally { await browser.close(); }
})().catch(error => {console.error(error);process.exit(1)});

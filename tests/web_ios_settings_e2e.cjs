const { chromium } = require('playwright');
const assert = require('assert');
const fs = require('fs');
const base = (process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765').replace(/\/$/, '');
if (!/^http:\/\/127\.0\.0\.1:[0-9]+$/.test(base)) throw Error('Expected isolated loopback fixture');
const mode = process.argv[2];
if (!['setup', 'verify'].includes(mode)) throw Error('Expected setup or verify');

async function request(path, method = 'GET', body) {
  const r = await fetch(base + path, {method, headers: {'Content-Type': 'application/json'},
    ...(body ? {body: JSON.stringify(body)} : {})});
  if (!r.ok) throw Error(`${path}: ${r.status}`);
  return r.json();
}

(async () => {
  if (mode === 'setup') await request('/api/v1/__ui_fixture/interop-case', 'POST');
  const seed = await request('/api/v1/__ui_fixture/interop-case');
  const auth = await request('/api/v1/auth/login', 'POST', {username: seed.username, password: seed.password});
  const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  const browser = await chromium.launch({headless: true, ...(fs.existsSync(chrome) ? {executablePath: chrome} : {})});
  try {
    const page = await browser.newPage();
    await page.goto(base + '/');
    await page.evaluate(async session => { await onAuthed(session, false); showSettings(); }, auth);
    if (mode === 'setup') {
      if (process.env.VOCAB_UI_NORMAL_ACTIVE === '1') {
        await page.waitForFunction(async () => !!(await deltaIDB(accountSlot(AUTH), 'get')));
        await page.evaluate(() => navigator.locks.request(`vocab-delta:${accountSlot(AUTH)}`, () => {}));
        await page.locator('#bPrepareNormal').click();
        await page.waitForSelector('#normalTransitionResume');
        await page.locator('#normalTransitionResume').click();
        await page.waitForSelector('#bStart');
        await page.locator('#btnSettings').click();
      }
      await page.locator('[data-cap="30"]').click();
      await page.evaluate(async () => { await save(); clearTimeout(save._t); });
      if (process.env.VOCAB_UI_NORMAL_RECOVERY === '1') {
        await page.evaluate(() => localStorage.removeItem(accountSlot(AUTH)));
        await page.reload();
        await page.waitForSelector('#normalTransitionRecover');
        page.on('dialog', dialog => dialog.accept());
        await page.locator('#normalTransitionRecover').click();
        await page.waitForFunction(() => document.querySelector('#normalTransitionMessage')?.textContent.includes('旧槽位已恢复'));
        await page.locator('#normalTransitionResume').click();
        await page.waitForSelector('#bStart');
      }
      const result = await page.evaluate(() => pushState());
      assert(result, 'browser settings upload failed');
      console.log('PASS browser sets daily cap');
    } else {
      const settings = await page.evaluate(() => ({newPerDay: S.settings.newPerDay, dailyCap: S.settings.dailyCap, epoch: S.restoreEpoch}));
      assert.deepEqual(settings, {newPerDay: 20, dailyCap: 30, epoch: 1});
      assert((await page.locator('[data-new="20"]').getAttribute('style')).includes('border'));
      assert((await page.locator('[data-cap="30"]').getAttribute('style')).includes('border'));
      const fencing = await page.evaluate(async () => {
        const headers = authHeaders();
        const list = await (await fetch('/api/v1/me/state/backups', {headers})).json();
        const backup = list.backups.find(item => item.reason === 'before_checkpoint');
        if (!backup) throw Error('Server checkpoint backup missing');
        const previous = await (await fetch(`/api/v1/me/state/backups/${backup.id}`, {headers})).json();
        const stale = await fetch('/api/v1/me/state', {method: 'PUT', headers: {...headers, 'Content-Type': 'application/json'}, body: JSON.stringify(previous.state)});
        return {status: stale.status, settings: previous.state.settings};
      });
      assert.equal(fencing.status, 409);
      assert.equal(fencing.settings.newPerDay, 20);
      assert.equal(fencing.settings.dailyCap, 30);
      console.log('PASS browser displays settings after iOS change and checkpoint');
    }
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

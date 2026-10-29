const {chromium} = require('playwright');
const assert = require('assert');
const base = (process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765').replace(/\/$/, '');
async function api(path, method='GET', body) {
  const r = await fetch(base + path, {method, headers:{'Content-Type':'application/json'}, ...(body === undefined ? {} : {body:JSON.stringify(body)})});
  if (!r.ok) throw Error(`${path} ${r.status}`);
  return r.json();
}
(async () => {
  const seed = await api('/api/v1/__ui_fixture/recovery-case','POST',{});
  const auth = await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
  const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  try {
    const page = await browser.newPage();
    await page.goto(base);
    await page.evaluate(a => onAuthed(a,false),auth);
    await page.waitForSelector('#bStart');
    await page.waitForFunction(async () => !!await deltaIDB(accountSlot(AUTH),'get'));
    const result = await page.evaluate(async () => {
      clearTimeout(save._t);
      const slot = accountSlot(AUTH);
      const storedBefore = localStorage.getItem(slot);
      // Queue preparation can change in-memory tracking before its asynchronous
      // word requests finish and save the resulting state.
      S.track = {...(S.track || {}), uiRaceTest:1};
      const sent = await pushState();
      const pulled = await syncFromServer();
      const beforeSave = {sent,pulled,blocked:deltaConcurrentSlots.has(slot), failed:localSaveFailed,
        storedUnchanged:localStorage.getItem(slot) === storedBefore};
      save(); clearTimeout(save._t);
      return {...beforeSave, saved:JSON.parse(localStorage.getItem(slot)).track?.uiRaceTest === 1,
        blockedAfterSave:deltaConcurrentSlots.has(slot),failedAfterSave:localSaveFailed};
    });
    assert.equal(result.sent,false); assert.equal(result.pulled,false);
    assert.equal(result.blocked,false,'same-page temporary edits must not be classified as another tab');
    assert.equal(result.failed,false); assert(result.storedUnchanged && result.saved);
    assert.equal(result.blockedAfterSave,false); assert.equal(result.failedAfterSave,false);
    console.log('PASS single-page asynchronous edits defer sync without a false cross-tab conflict');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });

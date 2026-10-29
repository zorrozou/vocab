const {chromium} = require('playwright');
const assert = require('assert');
const base = (process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765').replace(/\/$/, '');
async function api(path, body) {
  const r = await fetch(base + path, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)});
  if (!r.ok) throw Error(`${path}: ${r.status}`);
  return r.json();
}
(async () => {
  await api('/api/v1/__ui_fixture/experimental-large-deltas', {enabled:true});
  const seed = await api('/api/v1/__ui_fixture/recovery-case', {});
  const auth = await api('/api/v1/auth/login', {username:seed.username, password:seed.password});
  await api('/api/v1/__ui_fixture/oversize-stored-state', {token:seed.token, size:8*1024*1024+65536});
  const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  try {
    const page = await browser.newPage();
    await page.goto(base); await page.evaluate(a => onAuthed(a,false), auth);
    await page.locator('#awaitSaveSnapshot').click();
    await page.waitForFunction(() => document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
    await page.locator('#awaitUseSnapshot').click();
    await page.locator('#bStart, #bPlace').first().waitFor();
    const result = await page.evaluate(async () => {
      clearTimeout(save._t);
      S.log = Array.from({length:1205}, (_, i) => ({d:'2020-01-01',word:'example',kind:'learn',rating:3,eventId:i.toString(16).padStart(8,'0')}));
      const original = JSON.stringify(S), put = IDBObjectStore.prototype.put;
      IDBObjectStore.prototype.put = function(...args) { if (this.name === 'journals') throw Error('injected storage failure'); return put.apply(this,args); };
      try { await save(); return {failed:localSaveFailed, preserved:JSON.stringify(S) === original}; }
      finally { IDBObjectStore.prototype.put = put; }
    });
    assert(result.failed && result.preserved, 'failed large-state save must retain the untrimmed in-memory progress');
    assert(await page.evaluate(async () => { await save(); clearTimeout(save._t); return !localSaveFailed && S.log.length === 1200; }));
    const race = await page.evaluate(async () => {
      const real = largeLocalAppend;
      let release, started;
      const gate = new Promise(r => release = r), seen = new Promise(r => started = r);
      largeLocalAppend = async (...args) => { started(); await gate; return real(...args); };
      try {
        S.log = Array.from({length:1205}, (_, i) => ({d:'2020-01-01',word:'example',kind:'learn',rating:3,eventId:i.toString(16).padStart(8,'0')}));
        const first = save(); await seen;
        S.log.push({d:'2020-01-02',word:'later',kind:'review',rating:3,eventId:'abcdef01'});
        const second = save(); release(); await Promise.all([first,second]); clearTimeout(save._t);
        return {failed:localSaveFailed, contains:S.log.some(x => x.eventId === 'abcdef01'), same:JSON.stringify(S) === largeActive.lease.raw};
      } finally { largeLocalAppend = real; }
    });
    assert(!race.failed && race.contains && race.same, JSON.stringify(race));
    const switched = await page.evaluate(async () => {
      const real = largeLocalAppend;
      let release, started;
      const gate = new Promise(r => release = r), seen = new Promise(r => started = r);
      largeLocalAppend = async (...args) => { started(); await gate; return real(...args); };
      try {
        S.log = Array.from({length:1205}, (_, i) => ({d:'2020-01-01',word:'example',kind:'learn',rating:3,eventId:i.toString(16).padStart(8,'0')}));
        const before = JSON.stringify(S), first = save(); await seen;
        largeActive = null; S = JSON.parse(before); release(); await first;
        return S.log.length;
      } finally { largeLocalAppend = real; }
    });
    assert.equal(switched, 1205, 'old session must not trim a newly selected state');
    console.log('PASS large-state save failure retains the full log and recovery persists the trimmed state');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });

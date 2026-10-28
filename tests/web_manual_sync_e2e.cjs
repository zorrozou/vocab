const {chromium} = require('playwright');
const assert = require('assert');
const base = process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/';
async function api(path, method='GET', body, token) {
  const r = await fetch(base+path, {method,headers:{'Content-Type':'application/json',...(token ? {Authorization:`Bearer ${token}`} : {})},...(body === undefined ? {} : {body:JSON.stringify(body)})});
  if (!r.ok) throw Error(`${path}: ${r.status}`); return r.json();
}
(async () => {
  const seed = await api('api/v1/__ui_fixture/recovery-case','POST',{});
  const auth = await api('api/v1/auth/login','POST',{username:seed.username,password:seed.password});
  const browser = await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  try {
    const page = await browser.newPage(); await page.goto(base);
    await page.evaluate(async account => { await onAuthed(account,false); },auth);
    const remote = (await api('api/v1/me/state','GET',undefined,seed.token)).state;
    remote.cards.pear = {pos:2,stage:1,due:'2099-01-01T00:00:00Z'};
    await api('api/v1/me/state','PUT',remote,seed.token);
    assert.deepEqual(await page.evaluate(()=>Object.keys(S.cards)),['apple']);
    await page.locator('#btnUser').click(); await page.locator('#mSync').click();
    await page.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('✓ 已同步'));
    assert.deepEqual(await page.evaluate(()=>Object.keys(S.cards).sort()),['apple','pear']);
    assert.deepEqual(await page.evaluate(()=>Object.keys(JSON.parse(localStorage.getItem('vocab_v1')).cards).sort()),['apple','pear']);
    // A proxy's HTML 413 must preserve the dirty local state and explain recovery.
    await page.evaluate(()=>{ S.cards.cherry={pos:3,stage:1,due:'2099-01-01T00:00:00Z'}; save(); clearTimeout(save._t); });
    const reject = route => ['PUT','POST'].includes(route.request().method()) ? route.fulfill({status:413,contentType:'text/html',body:'too large'}) : route.continue();
    await page.route('**/api/v1/me/state',reject); await page.route('**/api/v1/me/state/deltas',reject); await page.locator('#mSync').click();
    await page.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('进度超过同步大小限制'));
    assert.deepEqual(await page.evaluate(()=>Object.keys(S.cards).sort()),['apple','cherry','pear']);
    assert.equal(await page.evaluate(()=>!!AUTH),true);
    assert(!(await api('api/v1/me/state','GET',undefined,seed.token)).state.cards.cherry);
    await page.locator('#mLogout').click();
    await page.waitForFunction(()=>!document.querySelector('#mLogout')?.disabled);
    assert.equal(await page.evaluate(()=>!!AUTH),true, 'failed upload must not log out');
    assert((await api('api/v1/me/state','GET',undefined,seed.token)).state.cards.apple);
    // A storage failure must prevent account switching without erasing memory.
    await page.evaluate(() => { window.originalSetItem=Storage.prototype.setItem; Storage.prototype.setItem=function(k,v) { if (k===accountSlot(AUTH)) throw Error('quota'); return window.originalSetItem.call(this,k,v); }; });
    await page.locator('#mSwitch').click();
    await page.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('本机保存失败'));
    assert(await page.evaluate(()=>!!AUTH && !!S.cards.cherry));
    await page.unroute('**/api/v1/me/state',reject);
    await page.unroute('**/api/v1/me/state/deltas',reject);
    let expiredRequests=0;
    const expired = route => { if (!['PUT','POST'].includes(route.request().method())) return route.continue(); expiredRequests++; return route.fulfill({status:401,json:{detail:'登录已过期'}}); };
    await page.route('**/api/v1/me/state',expired); await page.route('**/api/v1/me/state/deltas',expired); await page.locator('#mSync').click();
    await page.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('本机保存失败'));
    assert.equal(expiredRequests,0,'an unsaved edit must not be uploaded');
    assert(await page.evaluate(()=>!!AUTH && !!S.cards.cherry), 'failed local save must not discard unsaved memory');
    await page.unroute('**/api/v1/me/state',expired);
    await page.unroute('**/api/v1/me/state/deltas',expired);
    await page.evaluate(()=>{ Storage.prototype.setItem=window.originalSetItem; save(); clearTimeout(save._t); });
    await page.locator('#mSync').click();
    await page.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('✓ 已同步'));
    assert((await api('api/v1/me/state','GET',undefined,seed.token)).state.cards.cherry);
    // Text in a non-401 error must not invalidate a valid session.
    await page.evaluate(()=>{S.cards.date={pos:4,stage:1,due:'2099-01-01T00:00:00Z'}; save(); clearTimeout(save._t);});
    const conflict=route => ['PUT','POST'].includes(route.request().method()) ? route.fulfill({status:409,json:{detail:'事件 401 已过期'}}) : route.continue();
    await page.route('**/api/v1/me/state',conflict); await page.route('**/api/v1/me/state/deltas',conflict); await page.locator('#mSync').click();
    await page.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('HTTP 409'));
    assert.equal(await page.evaluate(()=>!!AUTH),true); assert(await page.evaluate(()=>!!S.cards.date));
    await page.unroute('**/api/v1/me/state',conflict);
    await page.unroute('**/api/v1/me/state/deltas',conflict);
    // A slow pull must not overwrite state after the user leaves the account menu.
    await page.locator('#mSync').click(); await page.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('✓ 已同步'));
    const changed=(await api('api/v1/me/state','GET',undefined,seed.token)).state;
    changed.cards.elderberry={pos:5,stage:1,due:'2099-01-01T00:00:00Z'};
    await api('api/v1/me/state','PUT',changed,seed.token);
    let release, enter, settle; const gate=new Promise(r=>release=r), started=new Promise(r=>enter=r), finished=new Promise(r=>settle=r);
    let reads=0;
    const hold=async route=>{ if(route.request().method()!=='GET'||++reads===1) return route.continue(); enter(); await gate; await route.continue(); settle(); };
    await page.route('**/api/v1/me/state/changes?*',hold); await page.locator('#mSync').click();
    let timer; try { await Promise.race([started,new Promise((_,reject)=>timer=setTimeout(()=>reject(Error('incremental pull did not start')),20000))]); } finally { clearTimeout(timer); }
    await page.locator('#btnSettings').click(); await page.locator('#app h2').filter({hasText:'设置'}).waitFor();
    release(); await finished; await page.waitForTimeout(300);
    assert.equal(await page.locator('#app h2').first().innerText(),'设置');
    assert.equal(await page.evaluate(()=>!!S.cards.elderberry),false);
    // A newly registered account with no server state can be synced immediately.
    const fresh=await api('api/v1/auth/register','POST',{username:'fresh_'+Math.random().toString(36).slice(2,10),password:'test_password_123'});
    const freshPage=await browser.newPage(); await freshPage.goto(base);
    await freshPage.evaluate(async account => { await onAuthed(account,true); },fresh);
    await freshPage.locator('#btnUser').click(); await freshPage.locator('#mSync').click();
    await freshPage.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('✓ 已同步'));
    assert((await api('api/v1/me/state','GET',undefined,fresh.token)).state);
    await freshPage.locator('#mLogout').click();
    await freshPage.locator('#wLogin').waitFor();
    const revoked = await fetch(base+'api/v1/me/state',{headers:{Authorization:`Bearer ${fresh.token}`}});
    assert.equal(revoked.status,401, 'successful logout must revoke the server session');
    await freshPage.close();
    console.log('PASS manual sync merge, failed logout, storage failure, 413 recovery and navigation');
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exit(1);});

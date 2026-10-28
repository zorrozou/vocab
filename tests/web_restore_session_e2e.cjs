const {chromium} = require('playwright');
const assert = require('assert');
const base = process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765';
async function api(path, method='GET', body, token) {
  const r = await fetch(base + path, {method, headers:{'Content-Type':'application/json', ...(token ? {Authorization:`Bearer ${token}`} : {})}, ...(body === undefined ? {} : {body:JSON.stringify(body)})});
  if (!r.ok) throw Error(`${path}: ${r.status}`); return r.json();
}
const state = word => ({v:1,cards:{[word]:{pos:1}},log:[],pendingNew:[],settings:{}});
(async () => {
  const username = 'restore_'+Math.random().toString(36).slice(2,10), password='test_password_123';
  const a = await api('/api/v1/auth/register','POST',{username,password});
  const b = await api('/api/v1/auth/login','POST',{username,password});
  await api('/api/v1/me/state','PUT',state('apple'),a.token);
  const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
  try {
    const page=await browser.newPage(); await page.goto(base);
    await page.evaluate(({a})=>{AUTH={userId:a.user.id,accountId:a.user.account_id,username:a.user.username,token:a.token}; S=defaultState(); S.cards.apple={pos:1};}, {a});
    const result=await page.evaluate(async ({b, backup})=>{
      let release; const gate=new Promise(r=>release=r);
      const operation=restoreLearningBackup({size:10,text:()=>gate});
      AUTH.token=b.token; release(JSON.stringify(backup));
      try { await operation; return 'unexpected success'; } catch(e) { return e.message; }
    },{b,backup:state('banana')});
    assert(result.includes('进度已变化'));
    assert.deepEqual(Object.keys((await api('/api/v1/me/state','GET',undefined,b.token)).state.cards),['apple']);
    const onConfirm=await page.evaluate(async ({a,b,backup})=>{
      AUTH.token=a.token; window.confirm=()=>{AUTH.token=b.token;return true;};
      try { await restoreLearningBackup(new File([JSON.stringify(backup)],'backup.json')); return 'unexpected success'; } catch(e) { return e.message; }
    },{a,b,backup:state('banana')});
    assert(onConfirm.includes('进度已变化'));
    const reload=await page.evaluate(async ({a,b})=>{
      AUTH.token=a.token; window.confirm=()=>{AUTH.token=b.token;return true;};
      try { await reloadServerState(); return 'unexpected success'; } catch(e) { return e.message; }
    },{a,b});
    assert(reload.includes('本机进度已变化'));
    // A restore already accepted by the server must not update the new local session.
    let release, enter; const gate=new Promise(r=>release=r), started=new Promise(r=>enter=r);
    await page.route('**/api/v1/me/state/*restore', async route=>{
      const response=await route.fetch(); enter(); await gate; await route.fulfill({response});
    });
    const pending=page.evaluate(async ({a,backup})=>{
      AUTH.token=a.token; window.confirm=()=>true; syncFailed=false;
      try { await restoreLearningBackup(new File([JSON.stringify(backup)],'backup.json')); return 'unexpected success'; } catch(e) { return e.message; }
    },{a,backup:state('banana')});
    await started; await page.evaluate(token=>{AUTH.token=token;},b.token); release();
    assert((await pending).includes('服务器已恢复'));
    assert.deepEqual(await page.evaluate(()=>Object.keys(S.cards)),['apple']);
    assert.equal(await page.evaluate(()=>syncFailed),false);
    assert.deepEqual(Object.keys((await api('/api/v1/me/state','GET',undefined,b.token)).state.cards),['banana']);
    console.log('PASS restore file read, confirmation, server reload and late restore response respect same-account session changes');
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exit(1);});

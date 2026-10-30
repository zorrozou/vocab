const {chromium} = require('playwright');
const assert = require('assert');
const fs = require('fs');
const BASE=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
function state(word) { return {v:1,calibrated:true,frontier:1,pointer:2,probeCount:0,posterior:null,cards:{[word]:{pos:1}},log:[],pendingNew:[],personalized:{},streak:0,lastDay:null,settings:{newPerDay:10,dailyCap:100}}; }
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try {
  const page=await browser.newPage({acceptDownloads:true});
  const states={alice:state('apple'),bob:state('banana')};
  await page.route('**/api/v1/me/state', async route=>{
    const key=(route.request().headers().authorization||'').replace('Bearer ','');
    if(route.request().method()==='PUT') {
      const body=route.request().postDataJSON(); states[key]={...states[key],...body,cards:{...states[key].cards,...body.cards}};
      await route.fulfill({json:{ok:true}});
    } else await route.fulfill({json:{state:states[key]||null,updated_at:1}});
  });
  await page.goto(BASE+'/?debug=1');
  await page.evaluate(async()=>{ await onAuthed({user:{id:7,account_id:'a'.repeat(32),username:'Alice',nickname:'Alice'},token:'alice'},true); });
  assert.deepEqual(await page.evaluate(()=>Object.keys(S.cards)),['apple']);
  await page.evaluate(()=>{ S.cards.apricot={pos:2}; save(); });
  await page.evaluate(async()=>{ await onAuthed({user:{id:7,account_id:'b'.repeat(32),username:'Bob',nickname:'Bob'},token:'bob'},true); });
  assert.deepEqual(await page.evaluate(()=>Object.keys(S.cards)),['banana']);
  await page.evaluate(()=>{ S.cards.blueberry={pos:3}; save(); });
  await page.evaluate(async()=>{ await onAuthed({user:{id:7,account_id:'a'.repeat(32),username:'ALICE',nickname:'Alice'},token:'alice'},false); });
  assert.deepEqual((await page.evaluate(()=>Object.keys(S.cards))).sort(),['apple','apricot']);
  const slots=await page.evaluate(()=>({alice:JSON.parse(localStorage.getItem(accountSlot({userId:7,accountId:'a'.repeat(32),username:'alice'}))),
      bob:JSON.parse(localStorage.getItem(accountSlot({userId:7,accountId:'b'.repeat(32),username:'bob'})))}));
  assert(slots.alice.cards.apricot && slots.bob.cards.blueberry && !slots.bob.cards.apple);
  // Clearing this account's cache must leave other account slots untouched.
  page.once('dialog', d => d.accept());
  await Promise.all([page.waitForEvent('domcontentloaded'),page.locator('#tReset').click()]);
  await page.waitForFunction(() => !!S.cards.apple && !!document.querySelector('#bStart'));
  const untouchedBob=await page.evaluate(()=>JSON.parse(localStorage.getItem(accountSlot({userId:7,accountId:'b'.repeat(32),username:'bob'}))));
  assert(untouchedBob.cards.blueberry && !untouchedBob.cards.apple);
  // Same numeric ID and same username can represent a different server account.
  const replaced=await browser.newPage({acceptDownloads:true});
  await replaced.route('**/api/v1/me/state', async route=>{
    const key=(route.request().headers().authorization||'').replace('Bearer ','');
    if(route.request().method()==='PUT') return route.fulfill({json:{ok:true}});
    return route.fulfill({json:{state:states[key]||null,updated_at:1}});
  });
  await replaced.goto(BASE+'/');
  await replaced.evaluate(async()=>{
    localStorage.setItem(accountSlot({userId:7,username:'alice'}), JSON.stringify({cards:{legacyOffline:{pos:1}},log:[],pendingNew:[],settings:{}}));
    await onAuthed({user:{id:7,account_id:'a'.repeat(32),username:'alice',nickname:'Alice'},token:'alice'},true);
    S.cards.unsyncedOld={pos:5}; save();
    await onAuthed({user:{id:7,account_id:'b'.repeat(32),username:'alice',nickname:'Alice'},token:'bob'},true);
  });
  assert.deepEqual(await replaced.evaluate(()=>Object.keys(S.cards)),['banana']);
  assert(await replaced.evaluate(()=>JSON.parse(localStorage.getItem('vocab_v3_a'+'a'.repeat(32))).cards.unsyncedOld));
  await replaced.evaluate(()=>showSettings());
  assert(await replaced.getByText('导出未确认的旧存档 1').count() > 0);
  // An old saved session can still read and edit locally, but cannot upload an
  // unsigned slot merely because the current token belongs to the same UID.
  const oldSession=await browser.newPage(); await oldSession.goto(BASE+'/');
  await oldSession.evaluate(legacy => {
    localStorage.clear();
    const saved={userId:7,username:'Alice',nickname:'Alice',token:'alice'};
    const slot=accountSlot(saved), raw=JSON.stringify(legacy);
    localStorage.setItem('vocab_auth',JSON.stringify(saved)); localStorage.setItem(slot,raw);
    localStorage.setItem('vocab_v1',raw); localStorage.setItem('vocab_v1_owner',slot);
  }, state('legacyOffline'));
  let legacyRequests=0;
  await oldSession.route('**/api/v1/me/state', route=>{legacyRequests++; return route.fulfill({json:{state:state('wrong-account')}});});
  await oldSession.reload();
  assert.deepEqual(await oldSession.evaluate(()=>Object.keys(S.cards)),['legacyOffline']);
  await oldSession.evaluate(async()=>{ S.cards.offlineEdit={pos:4}; save(); await pushState(); await syncFromServer(); window.dispatchEvent(new Event('online')); });
  await oldSession.waitForTimeout(200);
  assert.equal(legacyRequests,0);
  assert(await oldSession.evaluate(()=>JSON.parse(localStorage.getItem(accountSlot(AUTH))).cards.offlineEdit));
  assert((await oldSession.locator('#userTag').innerText()).includes('旧会话仅本机'));
  // An old unowned root and numeric slot must remain available, even if the server is offline.
  const isolated=await browser.newPage({acceptDownloads:true});
  await isolated.goto(BASE+'/');
  const legacy=JSON.stringify(state('legacy-only'));
  await isolated.evaluate(({legacy})=>{
    localStorage.clear(); localStorage.setItem('vocab_v1',legacy); localStorage.setItem('vocab_v1_u7',legacy);
    localStorage.setItem('vocab_auth',JSON.stringify({userId:7,accountId:'b'.repeat(32),username:'Bob',nickname:'Bob',token:'bob'}));
  },{legacy});
  await isolated.route('**/api/v1/me/state', route=>route.abort());
  await isolated.reload();
  await isolated.waitForFunction(()=>syncFailed===true);
  assert.deepEqual(await isolated.evaluate(()=>Object.keys(S.cards)),[]);
  const stored=await isolated.evaluate(()=>({legacy:localStorage.getItem('vocab_v1_u7'), root:localStorage.getItem('vocab_v1')}));
  assert.equal(stored.legacy,legacy); assert.equal(stored.root,legacy);
  await isolated.locator('#awaitRetry').waitFor();
  const download=isolated.waitForEvent('download');
  await isolated.getByText('导出未确认的旧存档 1').click();
  const exported=fs.readFileSync(await (await download).path(),'utf8');
  assert.equal(exported,legacy);
  // A clean, newly-created offline slot must pull first on reconnect, not upload an empty state.
  await isolated.unroute('**/api/v1/me/state');
  let reconnectPushes = 0;
  await isolated.route('**/api/v1/me/state', route => {
    if (route.request().method() === 'PUT') { reconnectPushes++; return route.fulfill({json:{ok:true}}); }
    return route.fulfill({json:{state:states.bob,updated_at:2}});
  });
  await isolated.locator('#awaitRetry').click();
  await isolated.waitForFunction(()=>!!S.cards.banana && !syncFailed);
  assert.equal(reconnectPushes,0);
  // If writing the main mirror fails after the account slot is saved, the next
  // boot must push the dirty account slot before pulling remote data.
  const failMirror=await browser.newPage();
  await failMirror.route('**/api/v1/me/state', async route=>{
    const key=(route.request().headers().authorization||'').replace('Bearer ','');
    if(route.request().method()==='PUT') {
      const body=route.request().postDataJSON(); states[key]={...states[key],...body,cards:{...states[key].cards,...body.cards}};
      await route.fulfill({json:{ok:true}});
    } else await route.fulfill({json:{state:states[key]||null,updated_at:1}});
  });
  await failMirror.goto(BASE+'/');
  await failMirror.evaluate(async()=>{await onAuthed({user:{id:7,account_id:'a'.repeat(32),username:'Alice',nickname:'Alice'},token:'alice'},false);});
  await failMirror.evaluate(()=>{
    const original=Storage.prototype.setItem;
    Storage.prototype.setItem=function(key,value){if(key==='vocab_v1') throw new Error('quota'); return original.call(this,key,value);};
    S.cards.offlineNew={pos:4}; save(); Storage.prototype.setItem=original;
  });
  assert.equal(await failMirror.evaluate(()=>localSaveFailed),true);
  assert.equal(await failMirror.evaluate(()=>localStorage.getItem(slotClock(accountSlot(AUTH),'dirty'))),'1');
  await failMirror.reload();
  await failMirror.waitForFunction(()=>S.cards.offlineNew && localStorage.getItem(slotClock(accountSlot(AUTH),'dirty'))===null);
  assert(states.alice.cards.offlineNew);
  // If preserving an unknown root fails, account switching must stop before any overwrite.
  const quota=await browser.newPage(); await quota.goto(BASE+'/');
  const guarded=await quota.evaluate(async({legacy})=>{
    localStorage.clear(); localStorage.setItem('vocab_v1',legacy); AUTH=null;
    const original=Storage.prototype.setItem;
    Storage.prototype.setItem=function(key,value){if(key.startsWith('vocab_unverified_')) throw new Error('quota'); return original.call(this,key,value);};
    let failed=false;
    try { await onAuthed({user:{id:7,account_id:'b'.repeat(32),username:'Bob',nickname:'Bob'},token:'bob'},true); } catch (_) { failed=true; }
    Storage.prototype.setItem=original;
    return {failed,root:localStorage.getItem('vocab_v1'),auth:AUTH};
  },{legacy});
  assert(guarded.failed && guarded.root===legacy && guarded.auth===null);
  console.log('PASS same-ID slots, offline isolation, crash recovery and preserved legacy export');
 } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exit(1)});

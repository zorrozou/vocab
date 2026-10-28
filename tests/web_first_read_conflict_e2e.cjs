const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const context=await browser.newContext({acceptDownloads:true}),first=await context.newPage(),other=await context.newPage();await first.goto(base);await other.goto(base);
  let release,entered;const gate=new Promise(r=>release=r),started=new Promise(r=>entered=r);
  const hold=async route=>{if(route.request().method()!=='GET')return route.continue();entered();await gate;await route.continue();};
  await first.route('**/api/v1/me/state',hold);
  const login=first.evaluate(a=>onAuthed(a,false),auth);await started;
  const slot=await first.evaluate(()=>accountSlot(AUTH));
  await other.evaluate(a=>{AUTH={userId:a.user.id,accountId:a.user.account_id,username:a.user.username,nickname:a.user.nickname,token:a.token};S=defaultState();S.cards.unsaved={pos:7};save();clearTimeout(save._t);},auth);
  release();await login;await first.unroute('**/api/v1/me/state',hold);
  await first.locator('#awaitResolve').waitFor();assert.equal(await first.evaluate(slot=>localStorage.getItem(awaitingServerSlot(slot)),slot),'conflict');
  assert.equal(await first.evaluate(slot=>localStorage.getItem(slot),slot),null);
  // The other page retains the unsaved edit and can export it before closing.
  const unsaved=await other.evaluate(()=>JSON.stringify(S));assert(JSON.parse(unsaved).cards.unsaved);
  const stored=JSON.stringify({...JSON.parse(unsaved),cards:{saved_elsewhere:{pos:8}}});
  await first.evaluate(({slot,stored})=>localStorage.setItem(slot,stored),{slot,stored});
  await first.locator('#awaitResolve').click();await first.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('不能自动覆盖'));
  assert.equal(await first.evaluate(slot=>localStorage.getItem(slot),slot),stored);
  await first.evaluate(slot=>localStorage.removeItem(slot),slot);
  await first.evaluate(slot=>localStorage.setItem(deltaMarker(slot),'1'),slot);
  await first.locator('#awaitResolve').click();await first.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('不能自动覆盖'));
  assert.equal(await first.evaluate(slot=>localStorage.getItem(deltaMarker(slot)),slot),'1');
  await first.evaluate(slot=>localStorage.removeItem(deltaMarker(slot)),slot);
  await first.evaluate(()=>{S.cards.local_unsaved={pos:12};});
  const download=first.waitForEvent('download');await first.locator('#awaitExportLocal').click();
  assert(JSON.parse(fs.readFileSync(await (await download).path(),'utf8')).cards.local_unsaved);
  await other.close();
  const dismissed=new Promise(resolve=>first.once('dialog',async dialog=>{await dialog.dismiss();resolve();}));await first.locator('#awaitResolve').click();await dismissed;
  assert.equal(await first.evaluate(slot=>localStorage.getItem(awaitingServerSlot(slot)),slot),'conflict');
  first.once('dialog',dialog=>dialog.accept());await first.locator('#awaitResolve').click();
  await first.locator('#bStart, #bPlace').first().waitFor();
  assert(await first.evaluate(()=>!!S.cards.apple&&!S.cards.local_unsaved&&!localSaveFailed&&!deltaBlockedSlots.has(accountSlot(AUTH))));
  assert((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.apple);
  await context.close();console.log('PASS first-read conflict can be exported and safely retried without overwriting an existing slot');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

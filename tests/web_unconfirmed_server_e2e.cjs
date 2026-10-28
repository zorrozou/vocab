const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
  const page=await browser.newPage();await page.goto(base);
  const previous=await page.evaluate(()=>{const value=defaultState();value.cards.previous_account={pos:7};const raw=JSON.stringify(value);localStorage.setItem('vocab_v1',raw);localStorage.setItem('vocab_v1_guest',raw);localStorage.setItem('vocab_v1_owner','vocab_v1_guest');return raw;});
  const offline=route=>route.request().method()==='GET'?route.fulfill({status:503,json:{detail:'offline'}}):route.continue();
  await page.route('**/api/v1/me/state',offline);await page.evaluate(a=>onAuthed(a,false),auth);
  await page.locator('#awaitRetry').waitFor();
  assert(await page.evaluate(()=>!!localStorage.getItem(awaitingServerSlot(accountSlot(AUTH)))));
  assert.equal(await page.evaluate(()=>localStorage.getItem(accountSlot(AUTH))),null);
  assert.equal(await page.evaluate(()=>localStorage.getItem('vocab_v1')),previous);
  assert.equal(await page.evaluate(()=>pushState()),false);
  // If the non-durable marker disappears, no placeholder exists to be
  // mistaken for trusted data; startup must attempt the read again.
  await page.evaluate(()=>localStorage.removeItem(awaitingServerSlot(accountSlot(AUTH))));
  await page.reload();await page.locator('#awaitRetry').waitFor();await page.unroute('**/api/v1/me/state',offline);
  assert(await page.evaluate(()=>!S.cards.previous_account && localStorage.getItem(accountSlot(AUTH))===null));
  await page.locator('#awaitRetry').click();await page.locator('#bStart, #bPlace').first().waitFor();
  assert(await page.evaluate(()=>!!S.cards.apple&&!localStorage.getItem(awaitingServerSlot(accountSlot(AUTH)))));
  await page.close();
  await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
  const large=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),largeAuth=await api('/api/v1/auth/login','POST',{username:large.username,password:large.password});
  const size=8*1024*1024+65536;await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:large.token,size});
  const other=await browser.newPage();await other.goto(base);await other.evaluate(a=>onAuthed(a,false),largeAuth);await other.locator('#awaitRetry').waitFor();
  assert(await other.locator('#btnSettings').isDisabled());
  const corrupt=async route=>{const response=await route.fetch(),body=await response.json();body.data='AAAA'+body.data.slice(4);await route.fulfill({response,json:body});};
  await other.route('**/api/v1/me/state/snapshots/*?page=0',corrupt);
  await other.locator('#awaitExport').click();await other.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('校验失败'));
  assert(await other.evaluate(()=>!!localStorage.getItem(awaitingServerSlot(accountSlot(AUTH)))));
  await other.unroute('**/api/v1/me/state/snapshots/*?page=0',corrupt);
  const downloadPromise=other.waitForEvent('download');await other.locator('#awaitExport').click();const download=await downloadPromise;
  const exported=JSON.parse(fs.readFileSync(await download.path(),'utf8'));assert.equal(exported.fixtureLarge.length,size);
  assert(await other.evaluate(()=>!!localStorage.getItem(awaitingServerSlot(accountSlot(AUTH)))));
  await other.reload();await other.locator('#awaitRetry').waitFor();
  let release, signal;const gate=new Promise(resolve=>release=resolve),started=new Promise(resolve=>signal=resolve);let extraDownloads=0;
  other.on('download',()=>extraDownloads++);
  const held=async route=>{signal();await gate;await route.continue();};
  await other.route('**/api/v1/me/state/snapshots/*?page=0',held);
  await other.locator('#awaitExport').click();await started;
  await other.locator('#awaitSwitch').click();await other.locator('#wLogin').waitFor();release();
  await other.waitForTimeout(500);assert.equal(extraDownloads,0,'switched account must not export the prior account');
  await other.unroute('**/api/v1/me/state/snapshots/*?page=0',held);
  console.log('PASS unconfirmed account stays read-only, retries, reloads and exports verified large snapshot');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

const {chromium}=require('playwright');const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  for(const race of ['server','local']){
   const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
   const remote=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;
   const context=await browser.newContext(),page=await context.newPage();await page.goto(base);
   await page.route('**/api/v1/me/state',route=>route.request().method()==='GET'?route.fulfill({status:503,json:{detail:'offline'}}):route.continue());
   await page.evaluate(a=>onAuthed(a,false),auth);await page.locator('#awaitSaveSnapshot').waitFor();
   let once=false;
   await page.route('**/api/v1/me/state/changes?*',async route=>{
    const response=await route.fetch();
    if(!once){once=true;if(race==='server'){remote.cards.concurrent={pos:19};await api('/api/v1/me/state','PUT',remote,seed.token);}else await page.evaluate(()=>{const raw=JSON.stringify({...defaultState(),cards:{other_page:{pos:9}}});localStorage.setItem(accountSlot(AUTH),raw);});}
    await route.fulfill({response});
   });
   await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('已变化'));
   assert(once);assert.equal(await page.evaluate(()=>largeReadVerifiedSnapshot(accountSlot(AUTH))),null);
   if(race==='local')assert(await page.evaluate(()=>!!JSON.parse(localStorage.getItem(accountSlot(AUTH))).cards.other_page));
   await context.close();
  }
  console.log('PASS large snapshot save rejects server and local races without replacing either state');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

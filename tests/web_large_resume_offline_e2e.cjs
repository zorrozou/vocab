const {chromium}=require('playwright');const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const second=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),otherAuth=await api('/api/v1/auth/login','POST',{username:second.username,password:second.password});
 await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size:8*1024*1024+65536});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});let offline=false;
 try{
  const context=await browser.newContext();await context.addInitScript(()=>Object.defineProperty(navigator,'onLine',{get:()=>localStorage.getItem('test-network-offline')!=='1'}));
  await context.route('**/api/**',route=>offline?route.abort('internetdisconnected'):route.continue());
  let page=await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));await page.locator('#awaitUseSnapshot').click();await page.locator('#bStart, #bPlace').first().waitFor();
  await page.evaluate(()=>{clearTimeout(save._t);localStorage.setItem('test-network-offline','1');});offline=true;await page.close();page=await context.newPage();await page.goto(base);await page.locator('#bStart, #bPlace').first().waitFor();assert(await page.evaluate(()=>!!largeActive&&!!S.cards.apple&&!navigator.onLine));
  await page.locator('#btnSettings').click();await page.locator('[data-new="15"]').click();await page.locator('#bSave').click();await page.waitForFunction(()=>largeActive&&!largeActive.pending&&!localSaveFailed);await page.evaluate(()=>clearTimeout(save._t));
  assert(await page.evaluate(async()=>!!(await largeJournalRead(largeActive.slot))));offline=false;await page.evaluate(()=>{localStorage.removeItem('test-network-offline');window.dispatchEvent(new Event('online'));});
  let synced=false;for(let i=0;i<120&&!synced;i++){synced=await page.evaluate(async()=>{try{const value=await largeReadVerifiedSnapshot(largeActive.slot);return JSON.parse(value.baseline.baseRaw).settings.newPerDay===15;}catch(_){return false;}});if(!synced)await new Promise(resolve=>setTimeout(resolve,250));}assert(synced,'reconnection should upload offline edit');
  await page.waitForFunction(()=>largeActive&&!largeActive.syncing&&!largeActive.pending&&!localSaveFailed,null,{timeout:60000});
  offline=true;await page.evaluate(()=>localStorage.setItem('test-network-offline','1'));await page.evaluate(a=>onAuthed(a,false),otherAuth);await page.locator('#awaitUseSnapshot').waitFor();assert(await page.evaluate(()=>!largeActive&&AUTH.accountId!==null&&S.settings.newPerDay!==15));
  console.log('PASS offline large-state auto-resume, durable edit, reconnect sync and account isolation');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

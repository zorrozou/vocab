const {chromium}=require('playwright');const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size:8*1024*1024+65536});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const context=await browser.newContext(),page=await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
  await page.evaluate(()=>{window.realPut=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='migrations'&&String(args[1]).startsWith('resume:'))throw Error('injected quota');return window.realPut.apply(this,args);};});
  await page.locator('#awaitUseSnapshot').click();await page.locator('#bStart, #bPlace').first().waitFor();assert((await page.locator('#userTag').innerText()).includes('自动恢复设置未保存'));assert(await page.evaluate(()=>!!S.cards.apple&&!localSaveFailed));await page.evaluate(()=>{clearTimeout(save._t);IDBObjectStore.prototype.put=window.realPut;});
  await page.close();const reopened=await context.newPage();await reopened.goto(base);await reopened.locator('#awaitUseSnapshot').waitFor();assert(await reopened.evaluate(async()=>!largeActive&&!await largeResumePreference(accountSlot(AUTH))));await reopened.locator('#awaitUseSnapshot').click();await reopened.locator('#bStart, #bPlace').first().waitFor();assert(await reopened.evaluate(async()=>!!largeActive&&await largeResumePreference(accountSlot(AUTH))&&!largeActive.resumePrefFailed));
  console.log('PASS failed resume preference warns and leaves manual recovery available');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  for(let i=0;i<200&&!await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));i++)await new Promise(r=>setTimeout(r,50));
  const before=await api('/api/v1/me/state','GET',undefined,seed.token);
  const result=await page.evaluate(async()=>{const slot=accountSlot(AUTH),orig=Storage.prototype.setItem;Storage.prototype.setItem=function(key,value){if(key===slot)throw Error('injected quota failure');return orig.call(this,key,value);};try{S.cards.failed_local_save={pos:99};save();clearTimeout(save._t);return {failed:localSaveFailed,pushed:await pushState(),message:syncFailureMessage};}finally{Storage.prototype.setItem=orig;}});
  assert(result.failed);assert.equal(result.pushed,false);assert(result.message.includes('本机保存失败'));
  const after=await api('/api/v1/me/state','GET',undefined,seed.token);
  assert.equal(after.state_revision,before.state_revision);assert(!after.state.cards.failed_local_save);
  assert(await page.evaluate(async()=>{save();clearTimeout(save._t);return !localSaveFailed&&await pushState();}));
  assert((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.failed_local_save);
  console.log('PASS failed local save blocks upload until the edit is durable');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

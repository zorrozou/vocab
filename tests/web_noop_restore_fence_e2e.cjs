const {chromium}=require('playwright');const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});try{
 const page=await browser.newPage();await page.goto(base);await page.evaluate(x=>onAuthed(x,false),auth);
 for(let i=0;i<200&&!await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));i++)await new Promise(r=>setTimeout(r,50));
 const before=await api('/api/v1/me/state','GET',undefined,seed.token),local=await page.evaluate(()=>JSON.stringify(S));
 await api('/api/v1/me/state/restore','POST',{state:before.state,expected_updated_at:before.updated_at},seed.token);
 assert.equal(await page.evaluate(()=>pushState()),false);assert.equal(await page.evaluate(()=>JSON.stringify(S)),local);
 assert(await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get'))));
 console.log('PASS no-op push detects restored epoch and retains local baseline');
 }finally{await browser.close();}})().catch(e=>{console.error(e);process.exit(1);});

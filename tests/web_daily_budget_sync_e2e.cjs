const {chromium} = require('playwright');
const assert = require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try {
  const page=await browser.newPage(); await page.goto('http://127.0.0.1:18765/');
  const result=await page.evaluate(async()=>{
    const api=async(path,method,body,token)=>{
      const r=await fetch(path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body?{body:JSON.stringify(body)}:{})});
      if(!r.ok) throw new Error(`${path}: ${r.status}`);return r.json();
    };
    const account=await api('/api/v1/auth/register','POST',{username:'cap_'+Math.random().toString(36).slice(2,10),password:'test_password_123'});
    const state=(words)=>({...defaultState(),settings:{newPerDay:5,dailyCap:4},log:words.map(word=>({d:today(),word,kind:'review',rating:3}))});
    await api('/api/v1/me/state','PUT',state(['a','b']),account.token);
    await api('/api/v1/me/state','PUT',state(['c','d']),account.token);
    const merged=(await api('/api/v1/me/state','GET',null,account.token)).state;
    AUTH={userId:account.user.id,accountId:account.user.account_id,username:account.user.username,token:account.token};
    S=merged; S.cards={next:{pos:1,due:'2000-01-01T00:00:00Z'}};
    flushPendingFsrs=async()=>{};refreshPersonalJobs=async()=>{};trackLevelDaily=()=>{};prefetchDay=()=>{};pickProbes=async()=>[];
    await buildQueue();
    return {words:S.log.map(x=>x.word).sort(),length:session.queue.length};
  });
  assert.deepEqual(result.words,['a','b','c','d']);assert.equal(result.length,0);
  console.log('PASS synced independent devices count against the same daily workload');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

const assert = require('assert'), {chromium} = require('playwright');
(async () => {
 const browser = await chromium.launch({headless:true, executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try {
  const page = await browser.newPage(); await page.goto('http://127.0.0.1:18765/');
  const result = await page.evaluate(async () => {
   AUTH = null; localStorage.removeItem('vocab_guest_credential_v1');
   const [a,b] = await Promise.all([personalHeaders(), personalHeaders()]);
   const body = {device:'public-device',date:'2026-10-27',weak_words:['apple'],learned_max_pos:5000,sync:true,request_id:'webguest-'+crypto.randomUUID()};
   const first = await fetch('/api/v1/personalize',{method:'POST',headers:{'Content-Type':'application/json',...a},body:JSON.stringify(body)});
   const stolen = await fetch('/api/v1/personalized/job?'+new URLSearchParams({job_id:body.request_id,device:body.device}));
   const own = await fetch('/api/v1/personalized/job?'+new URLSearchParams({job_id:body.request_id,device:body.device}),{headers:b});
   return {same:a['X-Guest-Token']===b['X-Guest-Token'], persisted:localStorage.getItem('vocab_guest_credential_v1')===a['X-Guest-Token'], first:first.status, stolen:stolen.status, own:own.status};
  });
  assert.deepEqual(result,{same:true,persisted:true,first:200,stolen:401,own:200});
  const switched = await page.evaluate(async () => {
   AUTH = null; localStorage.removeItem('vocab_guest_credential_v1');
   const originalFetch = window.fetch; let release;
   window.fetch = () => new Promise(resolve => { release = () => resolve({ok:true,json:async () => ({token:'a'.repeat(64)})}); });
   try {
    const pending = personalHeaders();
    AUTH = {userId:1, accountId:'a'.repeat(32), token:'account-token'};
    release();
    try { await pending; return false; } catch (_) { return true; }
   } finally { window.fetch = originalFetch; AUTH = null; localStorage.removeItem('vocab_guest_credential_v1'); }
  });
  assert(switched, 'credential issuance must not cross account switch');
  console.log('PASS browser guest credential single-flight, persistence and HTTP isolation');
 } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exit(1)});

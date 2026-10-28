const {chromium} = require('playwright');
const assert = require('assert');
(async()=>{
 const browser = await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try {
  const page=await browser.newPage(); await page.goto('http://127.0.0.1:18765/');
  const actual=await page.evaluate(async()=>{
   const response=await fetch('/api/v1/auth/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:'webid_'+Math.random().toString(36).slice(2,10),password:'test_password_123'})});
   const session=await response.json(); if (!response.ok) throw new Error(JSON.stringify(session));
   await onAuthed(session,true);
   return {id:session.user.account_id,saved:AUTH.accountId,slot:accountSlot(AUTH),stored:!!localStorage.getItem(accountSlot(AUTH))};
  });
  assert.match(actual.id,/^[a-f0-9]{32}$/); assert.equal(actual.id,actual.saved); assert.equal(actual.slot,'vocab_v3_a'+actual.id); assert(actual.stored);
  console.log('PASS browser real registration binds the local slot to server identity');
 } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exit(1)});

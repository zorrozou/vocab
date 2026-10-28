const assert = require('assert'), {chromium} = require('playwright');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try {
  const page=await browser.newPage();await page.goto('http://127.0.0.1:18765/');
  const initial = await page.evaluate(async()=>{
   const username='cpweb_'+crypto.randomUUID().replaceAll('-','').slice(0,10);
   const a=await fetch('/api/v1/auth/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username,password:'test_password_123'})}).then(r=>r.json());
   AUTH={userId:a.user.id,accountId:a.user.account_id,username,token:a.token}; S=defaultState();
   recordKnowledge('apple',7,true);posteriorUpdate(1000,1,1,.25);save();clearTimeout(save._t);
   if(!await pushState())throw Error('initial sync failed');
   const before=JSON.stringify(S); showSettings();return {before,slot:accountSlot(AUTH)};
  });
  page.on('dialog', dialog=>dialog.accept());
  await page.locator('#bCheckpoint').click();
  await page.locator('#restoreMsg').getByText('整理完成', {exact:false}).waitFor({timeout:15000});
  const result=await page.evaluate(async({before,slot})=>{
   const backed=localStorage.getItem(`vocab_before_restore_${slot}`)===before;
   const stale=await fetch('/api/v1/me/state',{method:'PUT',headers:{'Content-Type':'application/json',...authHeaders()},body:before});
   return {epoch:S.restoreEpoch, eventCount:Object.keys(S.knowledgeEvidence.apple.events).length, posteriorCount:Object.keys(S.posteriorHistory.events).length, backed, stale:stale.status};
  },initial);
  assert.deepEqual(result,{epoch:1,eventCount:0,posteriorCount:0,backed:true,stale:409});
  console.log('PASS browser checkpoint confirmation, local backup, new baselines and stale-device fencing');
 } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

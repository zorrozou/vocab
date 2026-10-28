const {chromium}=require('playwright');
const assert=require('assert');
const crypto=require('crypto');
const run=require('util').promisify(require('child_process').execFile);
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});
 if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();
}
(async()=>{
 if(!process.env.VOCAB_IOS_STAGED_CHECK)throw Error('VOCAB_IOS_STAGED_CHECK required');
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
 const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const remote=await api('/api/v1/me/state','GET',undefined,seed.token);
 const restored={...remote.state,personalizedWeak:'w'.repeat(9*1024*1024),cards:{...remote.state.cards,web_restore:{pos:77,stage:1}}};
 const payload=JSON.stringify(restored),hash=crypto.createHash('sha256').update(payload).digest('hex');
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try {
  const context=await browser.newContext(), page=await context.newPage();await page.goto(base);
  const slot=await page.evaluate(a=>{AUTH={userId:a.user.id,accountId:a.user.account_id,username:a.user.username,nickname:a.user.nickname,token:a.token};return accountSlot(AUTH)},auth);
  const intent={slot,batch_id:crypto.randomBytes(16).toString('hex'),generation:remote.sync_generation,base_revision:remote.state_revision,restore_epoch:remote.state.restoreEpoch||0,payload,sha256:hash};
  await api('/api/v1/__ui_fixture/delta-hold-response','POST',{});
  await page.evaluate(i=>{window.restoreAttempt=deltaSubmitLargeRestore(i,AUTH.userId,AUTH.token,i.slot).catch(()=>null)},intent);
  let held=false;
  for(let i=0;i<1200;i++){if((await api('/api/v1/__ui_fixture/delta-hold-status')).started){held=true;break}await new Promise(r=>setTimeout(r,100))}
  assert(held,'restore did not commit');
  await context.close();await api('/api/v1/__ui_fixture/delta-release-response','POST',{});
  const context2=await browser.newContext(), page2=await context2.newPage();await page2.goto(base);
  await page2.evaluate(a=>{AUTH={userId:a.user.id,accountId:a.user.account_id,username:a.user.username,nickname:a.user.nickname,token:a.token}},auth);
  const receipt=await page2.evaluate(i=>deltaSubmitLargeRestore(i,AUTH.userId,AUTH.token,i.slot),intent);
  assert.equal(receipt.state_revision,String(BigInt(remote.state_revision)+1n));assert.equal(receipt.restore_epoch,1);
  const retry=await page2.evaluate(i=>deltaSubmitLargeRestore(i,AUTH.userId,AUTH.token,i.slot),intent);assert.deepEqual(retry,receipt);
  const alteredPayload=JSON.stringify({...restored,probeCount:123});
  const altered={...intent,payload:alteredPayload,sha256:crypto.createHash('sha256').update(alteredPayload).digest('hex')};
  const rejected=await page2.evaluate(async i=>{try{await deltaSubmitLargeRestore(i,AUTH.userId,AUTH.token,i.slot);return false}catch{return true}},altered);assert(rejected);
  // A malformed receipt must fail rather than trigger a new upload.
  let sentStage=false;
  await page2.route('**/api/v1/me/state/delta-stages',route=>{sentStage=true;return route.abort()});
  await page2.route('**/api/v1/me/state/experimental-large-restore-receipts/*',route=>route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({...receipt,payload_sha256:'0'.repeat(64)})}));
  assert(await page2.evaluate(async i=>{try{await deltaSubmitLargeRestore(i,AUTH.userId,AUTH.token,i.slot);return false}catch(e){return e.message.includes('回执')}},intent));
  assert(!sentStage,'malformed receipt triggered staging');
  await page2.unroute('**/api/v1/me/state/experimental-large-restore-receipts/*');
  // Mutating the caller's object during an await must not change a request.
  let releaseMutation,notifyMutation;
  const mutationHit=new Promise(resolve=>{notifyMutation=resolve});
  const mutationGate=new Promise(resolve=>{releaseMutation=resolve});
  await page2.route('**/api/v1/me/state/delta-capabilities',async route=>{notifyMutation();await mutationGate;await route.continue()});
  await page2.evaluate(i=>{window.mutableIntent=i;window.immutableAttempt=deltaSubmitLargeRestore(i,AUTH.userId,AUTH.token,i.slot)},intent);
  await mutationHit;
  await page2.evaluate(()=>{window.mutableIntent.batch_id='f'.repeat(32);window.mutableIntent.base_revision='999';window.mutableIntent.payload='{}'});
  releaseMutation();
  const immutableReceipt=await page2.evaluate(()=>window.immutableAttempt);assert.deepEqual(immutableReceipt,receipt);
  assert(!sentStage,'mutated caller object changed the submitted batch');
  await page2.unroute('**/api/v1/me/state/delta-capabilities');
  // Disabled capability and locally corrupted payload fail before any stage.
  await page2.route('**/api/v1/me/state/delta-capabilities',route=>route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({experimental_large_restore_v1:false})}));
  assert(await page2.evaluate(async i=>{try{await deltaSubmitLargeRestore(i,AUTH.userId,AUTH.token,i.slot);return false}catch(e){return e.message.includes('未启用')}},intent));
  assert(!sentStage,'disabled capability triggered staging');
  await page2.unroute('**/api/v1/me/state/delta-capabilities');
  assert(await page2.evaluate(async i=>{try{await deltaSubmitLargeRestore({...i,sha256:'0'.repeat(64)},AUTH.userId,AUTH.token,i.slot);return false}catch(e){return e.message.includes('校验失败')}},intent));
  assert(!sentStage,'corrupt intent triggered staging');
  // A session change while capability discovery is in flight must prevent staging.
  let releaseCapability,notifyCapability;
  const hit=new Promise(resolve=>{notifyCapability=resolve});
  const gate=new Promise(resolve=>{releaseCapability=resolve});
  await page2.route('**/api/v1/me/state/delta-capabilities',async route=>{notifyCapability();await gate;await route.continue()});
  await page2.evaluate(i=>{window.changedSessionAttempt=deltaSubmitLargeRestore(i,AUTH.userId,AUTH.token,i.slot).then(()=>false,e=>e.message.includes('账号已切换'))},intent);
  await hit;await page2.evaluate(()=>{AUTH.token='changed-session'});releaseCapability();
  assert(await page2.evaluate(()=>window.changedSessionAttempt));assert(!sentStage,'session switch triggered staging');
  await page2.unroute('**/api/v1/me/state/delta-capabilities');
  await page2.unroute('**/api/v1/me/state/delta-stages');
  // A later switch, after the first part reaches the server, must prevent all
  // subsequent parts and the commit from using the previous account session.
  await page2.evaluate(a=>{AUTH.token=a.token},auth);
  const nextIntent={...intent,batch_id:crypto.randomBytes(16).toString('hex'),base_revision:receipt.state_revision,restore_epoch:receipt.restore_epoch};
  let parts=0,commits=0,releasePart,notifyPart;
  const partHit=new Promise(resolve=>{notifyPart=resolve}),partGate=new Promise(resolve=>{releasePart=resolve});
  await page2.route('**/api/v1/me/state/delta-stages/*/parts/*',async route=>{parts++;const response=await route.fetch();notifyPart();await partGate;await route.fulfill({response})});
  await page2.route('**/api/v1/me/state/delta-stages/*/experimental-large-restore',route=>{commits++;return route.abort()});
  await page2.evaluate(i=>{window.partSwitchAttempt=deltaSubmitLargeRestore(i,AUTH.userId,AUTH.token,i.slot).then(()=>false,e=>e.message.includes('账号已切换'))},nextIntent);
  await partHit;await page2.evaluate(()=>{AUTH.token='changed-during-part'});releasePart();
  assert(await page2.evaluate(()=>window.partSwitchAttempt));assert.equal(parts,1);assert.equal(commits,0);
  await page2.unroute('**/api/v1/me/state/delta-stages/*/parts/*');
  await page2.unroute('**/api/v1/me/state/delta-stages/*/experimental-large-restore');
  const secondSeed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
  const second=await api('/api/v1/auth/login','POST',{username:secondSeed.username,password:secondSeed.password});
  await page2.evaluate(a=>{AUTH={userId:a.user.id,accountId:a.user.account_id,username:a.user.username,nickname:a.user.nickname,token:a.token}},second);
  const crossAccount=await page2.evaluate(async ({intent,auth})=>{try{await deltaSubmitLargeRestore(intent,auth.user.id,auth.token,intent.slot);return false}catch(e){return e.message.includes('账号已切换')}},{intent,auth});
  assert(crossAccount,'an intent was accepted in another account session');
  const result=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--verify-web-restore',receipt.state_revision,receipt.generation],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000,maxBuffer:1024*1024});
  assert(result.stdout.includes('PASS Swift verifies Web large restore'));
  await api('/api/v1/__ui_fixture/reset-sync-generation','POST',{});
  await page2.evaluate(a=>{AUTH={userId:a.user.id,accountId:a.user.account_id,username:a.user.username,nickname:a.user.nickname,token:a.token}},auth);
  const stale=await page2.evaluate(async i=>{try{await deltaSubmitLargeRestore(i,AUTH.userId,AUTH.token,i.slot);return false}catch(e){return e.status===409}},intent);
  assert(stale,'receipt from an old server generation was accepted');
  await context2.close();console.log('PASS Web staged restore receipt replay and Swift snapshot verification');
 } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}), auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try {
  const page=await browser.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  for(let i=0;i<200&&!await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));i++)await new Promise(r=>setTimeout(r,50));
  assert(await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get'))),'missing initial baseline');
  // The existing UI cannot durably hold 9 MiB yet; exercise its real upload
  // machinery with an in-memory target, without pretending this is an app flow.
  await page.evaluate(()=>{S.cards.large_test={pos:42,extra:'x'.repeat(9*1024*1024)};window.payload=JSON.stringify(S);});
  await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:false});
  assert(await page.evaluate(async()=>{try{await tryDeltaPush(AUTH.userId,AUTH.token,accountSlot(AUTH),window.payload);return false;}catch(_){return !(await deltaIDB(accountSlot(AUTH),'get')).pending;}}));
  await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
  let lost=false;
  await page.route('**/experimental-large-commit',async route=>{const response=await route.fetch({timeout:120000});assert.equal(response.status(),200);lost=true;await route.abort();});
  const first=await page.evaluate(async()=>{try{await tryDeltaPush(AUTH.userId,AUTH.token,accountSlot(AUTH),window.payload);return 'unexpected success';}catch(e){return e.message;}});
  assert(lost,'experimental staged commit was not used: '+first);
  let pending=await page.evaluate(async()=> (await deltaIDB(accountSlot(AUTH),'get')).pending);
  assert.equal(pending.experimentalLarge,true);assert.equal(pending.staged,true);const batch=pending.batch.batch_id;
  await page.unroute('**/experimental-large-commit');
  await page.evaluate(()=>tryDeltaPush(AUTH.userId,AUTH.token,accountSlot(AUTH),window.payload));
  const after=await page.evaluate(async()=>{const record=await deltaIDB(accountSlot(AUTH),'get');return {pending:record.pending,revision:record.revision,size:record.base.cards.large_test.extra.length};});
  assert.equal(after.pending,null);assert.equal(after.size,9*1024*1024);
  // A replayed response must keep the same batch and server revision.
  assert.equal(batch.length,32);
  const remote=await api('/api/v1/me/state/snapshots?representation=stored','POST',{},seed.token);
  assert.equal(remote.state_revision,after.revision);assert(remote.byte_length>8*1024*1024);
  if(process.env.VOCAB_IOS_STAGED_CHECK){
   const {promisify}=require('util'), run=promisify(require('child_process').execFile);
   const swift=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--read-web-large',remote.state_revision,remote.generation],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000,maxBuffer:1024*1024});
   assert(swift.stdout.includes('PASS iOS verifies Web experimental large upload'));
  }
  await page.evaluate(async()=>{S.cards.small={pos:7,stage:1,due:'2099-01-01T00:00:00Z'};window.payload=JSON.stringify(S);await tryDeltaPush(AUTH.userId,AUTH.token,accountSlot(AUTH),window.payload);});
  const small=await page.evaluate(async()=>{const record=await deltaIDB(accountSlot(AUTH),'get');return {revision:record.revision,found:!!record.base.cards.small,pending:record.pending};});
  assert(small.found);assert.equal(small.pending,null);assert.equal(BigInt(small.revision),BigInt(after.revision)+1n);
  const concurrent={generation:remote.generation,base_revision:small.revision,restore_epoch:remote.restore_epoch,
    batch_id:require('crypto').randomUUID().replaceAll('-',''),ops:[{op:'set',path:['cards','concurrent'],value:{pos:99}}]};
  await api('/api/v1/me/state/experimental-large-deltas','POST',concurrent,seed.token);
  await page.evaluate(()=>{S.cards.second={pos:8,stage:1,due:'2099-01-01T00:00:00Z'};window.payload=JSON.stringify(S);});
  const conflict=await page.evaluate(async()=>{try{await tryDeltaPush(AUTH.userId,AUTH.token,accountSlot(AUTH),window.payload);return null;}catch(e){return {status:e.status,code:e.code};}});
  assert.equal(conflict.status,409);
  pending=await page.evaluate(async()=> (await deltaIDB(accountSlot(AUTH),'get')).pending);
  assert.equal(pending.experimentalLarge,true);assert(!pending.merge);assert(!pending.staged);
  await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:false});
  const unavailable=await page.evaluate(async()=>{try{await tryDeltaPush(AUTH.userId,AUTH.token,accountSlot(AUTH),window.payload);return null;}catch(e){return e.status;}});
  // The staging endpoint may reject the stale revision before the disabled
  // commit endpoint is reached; either response must preserve the batch.
  assert([404,409].includes(unavailable));
  assert.equal((await page.evaluate(async()=> (await deltaIDB(accountSlot(AUTH),'get')).pending.batch.batch_id)),pending.batch.batch_id);
  // Even a non-staged large-protocol batch must match its durable target.
  await page.evaluate(async()=>{const slot=accountSlot(AUTH),record=await deltaIDB(slot,'get');record.pending.batch.ops[0].value=999;await deltaIDB(slot,'put',record,true);});
  assert(await page.evaluate(async()=>{try{await tryDeltaPush(AUTH.userId,AUTH.token,accountSlot(AUTH),window.payload);return false;}catch(e){return e.message.includes('与本机目标不一致');}}));
  console.log('PASS Web experimental large staged replay, disabled capability and conflict retention');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

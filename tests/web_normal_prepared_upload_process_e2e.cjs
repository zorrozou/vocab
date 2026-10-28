const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(url,method='GET',body,token){const r=await fetch(base+url,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${url}: ${r.status} ${await r.text()}`);return r.json();}
async function wait(page,condition){for(let i=0;i<400;i++){if(await page.evaluate(condition))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-normal-upload-')));let context;
 try{
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});let page=context.pages()[0]||await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  const slot=await page.evaluate(()=>{S.cards.pear={pos:3};save();clearTimeout(save._t);if(localSaveFailed)throw Error('local save failed');return accountSlot(AUTH);});
  await page.evaluate(()=>normalMigrationStage(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));await page.evaluate(()=>normalMigrationPrepare(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));
  // The currently active legacy slot still uses localStorage, so allow it to
  // settle before killing this process; only the pending record is tested for
  // strict transaction durability. This is not yet a full cutover test.
  await new Promise(r=>setTimeout(r,8000));
  assert(await page.evaluate(async()=>{const original=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='sync')throw Error('injected failure');return original.apply(this,args);};try{await normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=original;}}));
  assert.equal((await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot)).sync.record.pending,null);
  assert(!(await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.pear);
  let signal,release;const entered=new Promise(r=>signal=r),gate=new Promise(r=>release=r);let receipt;
  await page.route('**/api/v1/me/state/deltas',async route=>{const response=await route.fetch();assert.equal(response.status(),200);receipt=await response.json();signal();await gate;await route.abort().catch(()=>{});});
  await page.evaluate(()=>{window.pushTask=normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token).catch(()=>{});});await entered;
  const pending=(await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot)).sync.record.pending;assert.equal(pending.batch.batch_id,receipt.batch_id);
  const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'}),matches=listing.split('\n').map(line=>line.trim()).filter(line=>line.includes(`--user-data-dir=${profile}`)&&line.includes(executablePath)&&!line.includes('--type='));
  assert.equal(matches.length,1);const pid=Number(matches[0].split(/\s+/,1)[0]);assert(Number.isInteger(pid)&&pid>1);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;release();
  for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){break;}await new Promise(r=>setTimeout(r,100));}
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});page=context.pages()[0]||await context.newPage();
  // Avoid normal boot's legacy auto-sync: this isolated component has not yet
  // been connected to the actual startup flow.
  await page.addInitScript(()=>localStorage.removeItem('vocab_auth'));await page.goto(base);
  await page.evaluate(a=>{AUTH={userId:a.user.id,accountId:a.user.account_id,username:a.user.username,nickname:a.user.nickname,token:a.token};},auth);
  const before=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot);assert.equal(before.sync.record.pending.batch.batch_id,receipt.batch_id);
  assert.equal(await page.evaluate(()=>normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token)),true);
  const saved=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot);
  assert.equal(saved.sync.record.pending,null);assert.equal(saved.primary.dirty,false);assert.equal(saved.primary.fence.revision,receipt.state_revision);
  const server=await api('/api/v1/me/state','GET',undefined,seed.token);assert.equal(server.state_revision,receipt.state_revision);assert(server.state.cards.pear);
  if(process.env.VOCAB_IOS_STAGED_CHECK){const run=require('util').promisify(cp.execFile);const result=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--verify-normal-prepared-upload',saved.primary.fence.revision,saved.primary.fence.generation],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000});assert(result.stdout.includes('PASS Swift verifies ordinary prepared Web upload'));}
  assert.equal(await page.evaluate(()=>normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token)),true);
  // Old-page edits must fence this prepared copy, even when its primary exists.
  await page.evaluate(({slot,raw})=>localStorage.setItem(slot,raw+' '),{slot,raw:saved.candidate.value.sourceRaw});
  assert(await page.evaluate(async()=>{try{await normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}}));
  await page.evaluate(({slot,raw})=>localStorage.setItem(slot,raw),{slot,raw:saved.candidate.value.sourceRaw});
  const current=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot);
  const edited=await page.evaluate(async({slot,current})=>{const state=JSON.parse(current.primary.raw);state.cards.plum={pos:4};return normalMigrationWritePrepared(slot,current,JSON.stringify(state));},{slot,current});
  const remote=await api('/api/v1/me/state','GET',undefined,seed.token);remote.state.cards.plum={pos:5};await api('/api/v1/me/state','PUT',remote.state,seed.token);
  assert(await page.evaluate(async()=>{try{await normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}}));
  const conflicted=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot);
  assert(conflicted.sync.record.pending);assert.equal(conflicted.primary.raw,edited.primary.raw);assert.equal(conflicted.primary.dirty,true);
  assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.plum.pos,5);
  // Even a self-consistent checksum cannot make a changed batch represent its
  // persisted target. Reject it before sending any request.
  await page.evaluate(async slot=>{const prepared=await normalMigrationReadPrepared(slot),sync=structuredClone(prepared.sync);sync.record.pending.batch.ops=[];const digest=await normalSyncDigest(sync.record);sync.recordLength=digest.length;sync.recordSha256=digest.sha256;const db=await normalDurableOpen();try{await new Promise((resolve,reject)=>{const tx=db.transaction('sync','readwrite');tx.objectStore('sync').put(sync,slot);tx.oncomplete=resolve;tx.onabort=tx.onerror=()=>reject(tx.error);});}finally{db.close();}},slot);
  let corruptSent=0;page.on('request',r=>{if(r.method()==='POST'&&r.url().endsWith('/api/v1/me/state/deltas'))corruptSent++;});
  assert(await page.evaluate(async()=>{try{await normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}}));assert.equal(corruptSent,0);
  console.log('PASS ordinary prepared upload replays lost receipt and fences conflicts after process termination');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

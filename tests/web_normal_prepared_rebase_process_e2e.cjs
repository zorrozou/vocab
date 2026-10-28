const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process'),crypto=require('crypto');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(url,method='GET',body,token){const r=await fetch(base+url,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${url}: ${r.status} ${await r.text()}`);return r.json();}
async function wait(page,condition){for(let i=0;i<400;i++){if(await page.evaluate(condition))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
function batch(record,ops){return {generation:record.generation,base_revision:record.revision,restore_epoch:record.epoch,batch_id:crypto.randomUUID().replaceAll('-',''),ops};}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
 const initialRemote=await api('/api/v1/me/state','GET',undefined,seed.token);await api('/api/v1/me/state','PUT',initialRemote.state,seed.token);
 const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-normal-rebase-')));let context;
 try{
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});let page=context.pages()[0]||await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  const slot=await page.evaluate(()=>{S.cards.pear={pos:3,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);if(localSaveFailed)throw Error('local save failed');return accountSlot(AUTH);});
  await page.evaluate(()=>normalMigrationStage(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));await page.evaluate(()=>normalMigrationPrepare(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));
  const initial=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot);
  let remote;
  if(process.env.VOCAB_IOS_STAGED_CHECK){const run=require('util').promisify(cp.execFile);const result=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--write-normal-prepared',initial.sync.record.generation,initial.sync.record.revision],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000});assert(result.stdout.includes('PASS Swift writes ordinary delta'));remote={state_revision:(await api('/api/v1/me/state','GET',undefined,seed.token)).state_revision};}
  else remote=await api('/api/v1/me/state/deltas','POST',batch(initial.sync.record,[{op:'set',path:['cards','banana'],value:{pos:2,stage:1,due:'2099-01-01T00:00:00Z'}}]),seed.token);
  // Only the new IndexedDB records, not the legacy localStorage slot, have a
  // strict completion guarantee. Allow the old slot time to settle in this
  // isolated component test; this is not a full startup cutover test.
  await new Promise(r=>setTimeout(r,8000));
  let signal,release;const entered=new Promise(r=>signal=r),gate=new Promise(r=>release=r);let receipt;const requests=[];
  const capture=async route=>{const request=route.request().postDataJSON(),response=await route.fetch();requests.push({request,status:response.status()});if(response.status()===200){receipt=await response.json();signal();await gate;await route.abort().catch(()=>{});}else await route.fulfill({response});};
  const kill=async()=>{const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'}),matches=listing.split('\n').map(line=>line.trim()).filter(line=>line.includes(`--user-data-dir=${profile}`)&&line.includes(executablePath)&&!line.includes('--type='));assert.equal(matches.length,1);const pid=Number(matches[0].split(/\s+/,1)[0]);assert(Number.isInteger(pid)&&pid>1);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){return;}await new Promise(r=>setTimeout(r,100));}throw Error('browser did not terminate');};
  const reopen=async()=>{context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});page=context.pages()[0]||await context.newPage();await page.addInitScript(()=>localStorage.removeItem('vocab_auth'));await page.goto(base);await page.evaluate(a=>{AUTH={userId:a.user.id,accountId:a.user.account_id,username:a.user.username,nickname:a.user.nickname,token:a.token};},auth);};
  await page.route('**/api/v1/me/state/deltas',capture);
  // Failing the rebase transaction must keep the original pending batch and
  // the old primary, even though the server already rejected that batch.
  assert(await page.evaluate(async revision=>{const original=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='sync'&&args[0]?.record?.revision===revision&&args[0]?.record?.pending===null)throw Error('injected rebase failure');return original.apply(this,args);};try{await normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=original;}},remote.state_revision));
  const rolled=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot);assert.equal(rolled.primary.fence.revision,initial.primary.fence.revision);assert(rolled.sync.record.pending);assert.equal(rolled.primary.raw,initial.primary.raw);
  // Fail the write of the new batch after the old conflict has been rebased.
  assert(await page.evaluate(async revision=>{const original=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='sync'&&args[0]?.record?.revision===revision&&args[0]?.record?.pending)throw Error('injected new batch failure');return original.apply(this,args);};try{await normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=original;}},remote.state_revision));
  const rebased=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot);assert.equal(rebased.primary.fence.revision,remote.state_revision);assert.equal(rebased.sync.record.pending,null);assert(rebased.primary.dirty);assert(JSON.parse(rebased.primary.raw).cards.pear);
  await kill();await reopen();assert.deepEqual(await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot),rebased);
  await page.route('**/api/v1/me/state/deltas',capture);
  await page.evaluate(()=>{window.pushError=null;window.pushTask=normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token).catch(error=>{window.pushError=String(error.message||error);});});
  const ended=page.evaluate(()=>window.pushTask.then(()=>window.pushError)).then(error=>{throw Error('rebase ended before response gate: '+String(error));});
  let timer;await Promise.race([entered,ended,new Promise((_,reject)=>timer=setTimeout(()=>reject(Error('rebased upload did not reach server')),30000))]).finally(()=>clearTimeout(timer));
  assert.deepEqual(requests.map(x=>x.status),[409,409,200]);assert.equal(requests[0].request.batch_id,requests[1].request.batch_id);assert.equal(requests[2].request.base_revision,remote.state_revision);assert.notEqual(requests[0].request.batch_id,requests[2].request.batch_id);
  const pending=(await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot)).sync.record.pending;assert.equal(pending.batch.batch_id,receipt.batch_id);
  await kill();release();await reopen();
  assert.equal((await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot)).sync.record.pending.batch.batch_id,receipt.batch_id);
  assert.equal(await page.evaluate(()=>normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token)),true);
  const saved=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot),server=await api('/api/v1/me/state','GET',undefined,seed.token);
  assert.equal(saved.primary.fence.revision,receipt.state_revision);assert.equal(saved.sync.record.pending,null);assert.equal(server.state_revision,receipt.state_revision);assert(server.state.cards.pear&&server.state.cards.banana);
  // A non-card server change is not proven independent and must not be
  // rebased or discarded automatically.
  await page.evaluate(async({slot,saved})=>{const state=JSON.parse(saved.primary.raw);state.cards.plum={pos:4,stage:1,due:'2099-01-01T00:00:00Z'};await normalMigrationWritePrepared(slot,saved,JSON.stringify(state));},{slot,saved});
  await api('/api/v1/me/state/deltas','POST',batch(saved.sync.record,[{op:'set',path:['probeCount'],value:7}]),seed.token);
  assert(await page.evaluate(async()=>{try{await normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}}));
  const refused=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot);assert(refused.sync.record.pending);assert(refused.primary.dirty);assert(JSON.parse(refused.primary.raw).cards.plum);
  // A server word may change and later return to its original value. A final
  // state comparison alone would miss that history and could replay an expired
  // already-applied batch over a later decision.
  let pages=0;const revision=BigInt(refused.sync.record.revision),fakeHead=String(revision+2n);
  const fakeHistory=async route=>{pages++;const after=new URL(route.request().url()).searchParams.get('after');const first=after===String(revision);const ops=first?[{op:'set',path:['cards','plum'],value:{pos:4,stage:1,due:'2099-01-01T00:00:00Z'}}]:[{op:'remove',path:['cards','plum']}];const bytes=Buffer.from(JSON.stringify({ops}));const change={base_revision:after,revision:String(BigInt(after)+1n),restore_epoch:refused.sync.record.epoch,updated_at:1,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),byte_length:bytes.length,page_bytes:128*1024,page_count:1,page:0,data:bytes.toString('base64')};await route.fulfill({status:200,json:{generation:refused.sync.record.generation,head_revision:fakeHead,change}});};
  await page.route('**/api/v1/me/state/changes?*',fakeHistory);
  const historyError=await page.evaluate(async()=>{try{await normalPreparedPush(accountSlot(AUTH),AUTH.userId,AUTH.token);return '';}catch(e){return e.message;}});
  await page.unroute('**/api/v1/me/state/changes?*',fakeHistory);assert(historyError.includes('变更历史'),historyError);assert.equal(pages,1);
  assert.deepEqual(await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot),refused);
  console.log('PASS disjoint card conflict rebases and replays after process termination; other conflicts remain fenced');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

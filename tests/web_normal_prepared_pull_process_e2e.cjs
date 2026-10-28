const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process'),crypto=require('crypto');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(url,method='GET',body,token){const r=await fetch(base+url,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${url}: ${r.status} ${await r.text()}`);return r.json();}
async function wait(page,condition){for(let i=0;i<400;i++){if(await page.evaluate(condition))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
function batch(record,word,pos){return {generation:record.generation,base_revision:record.revision,restore_epoch:record.epoch,batch_id:crypto.randomUUID().replaceAll('-',''),ops:[{op:'set',path:['cards',word],value:{pos,stage:1,due:'2099-01-01T00:00:00Z'}}]};}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-normal-pull-')));let context;
 try{
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});let page=context.pages()[0]||await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  const slot=await page.evaluate(()=>accountSlot(AUTH));await page.evaluate(()=>normalMigrationStage(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));await page.evaluate(()=>normalMigrationPrepare(accountSlot(AUTH),AUTH.userId,AUTH.token,()=>true));
  const before=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot);assert.equal(before.primary.dirty,false);
  let remote;
  if(process.env.VOCAB_IOS_STAGED_CHECK){const run=require('util').promisify(cp.execFile);const result=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--write-normal-prepared',before.sync.record.generation,before.sync.record.revision],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000});assert(result.stdout.includes('PASS Swift writes ordinary delta'));remote={state_revision:(await api('/api/v1/me/state','GET',undefined,seed.token)).state_revision};}
  else remote=await api('/api/v1/me/state/deltas','POST',batch(before.sync.record,'banana',2),seed.token);
  // A bad page or failed second store write must leave both durable records unchanged.
  const corrupt=async route=>{const response=await route.fetch(),body=await response.json();if(body.change)body.change.data='AAAA'+body.change.data.slice(4);await route.fulfill({response,json:body});};
  await page.route('**/api/v1/me/state/changes?*',corrupt);
  assert(await page.evaluate(async()=>{try{await normalPreparedPull(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}}));await page.unroute('**/api/v1/me/state/changes?*',corrupt);
  assert.deepEqual(await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot),before);
  assert(await page.evaluate(async()=>{const original=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='sync')throw Error('injected failure');return original.apply(this,args);};try{await normalPreparedPull(accountSlot(AUTH),AUTH.userId,AUTH.token);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.put=original;}}));
  assert.deepEqual(await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot),before);
  // The old active slot still lacks a strict flush API; only the completed
  // new-store transaction below is tested for immediate process termination.
  await new Promise(r=>setTimeout(r,8000));
  const downloaded=await page.evaluate(()=>normalPreparedPull(accountSlot(AUTH),AUTH.userId,AUTH.token));
  assert.equal(downloaded.primary.fence.revision,remote.state_revision);assert(JSON.parse(downloaded.primary.raw).cards.banana);
  const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'}),matches=listing.split('\n').map(line=>line.trim()).filter(line=>line.includes(`--user-data-dir=${profile}`)&&line.includes(executablePath)&&!line.includes('--type='));
  assert.equal(matches.length,1);const pid=Number(matches[0].split(/\s+/,1)[0]);assert(Number.isInteger(pid)&&pid>1);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;
  for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){break;}await new Promise(r=>setTimeout(r,100));}
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});page=context.pages()[0]||await context.newPage();await page.addInitScript(()=>localStorage.removeItem('vocab_auth'));await page.goto(base);
  await page.evaluate(a=>{AUTH={userId:a.user.id,accountId:a.user.account_id,username:a.user.username,nickname:a.user.nickname,token:a.token};},auth);
  assert.deepEqual(await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot),downloaded);
  const second=await api('/api/v1/me/state/deltas','POST',batch(downloaded.sync.record,'cherry',3),seed.token);
  // Switching accounts while a page is being read must stop before installation.
  let entered,release;let started=new Promise(r=>entered=r),gate=new Promise(r=>release=r);
  const hold=async route=>{const response=await route.fetch();entered();await gate;await route.fulfill({response}).catch(()=>{});};
  await page.route('**/api/v1/me/state/changes?*',hold);
  const switched=page.evaluate(()=>normalPreparedPull(accountSlot(AUTH),AUTH.userId,AUTH.token)).then(()=>false,()=>true);await started;
  await page.evaluate(()=>{window.savedAuth=AUTH;AUTH=null;});release();assert(await switched);await page.unroute('**/api/v1/me/state/changes?*',hold);await page.evaluate(()=>{AUTH=window.savedAuth;});
  assert.deepEqual(await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot),downloaded);
  // A saved local edit during download wins and remains dirty; the pull CAS
  // must not overwrite it or advance the baseline.
  started=new Promise(r=>entered=r);gate=new Promise(r=>release=r);await page.route('**/api/v1/me/state/changes?*',hold);
  const pulling=page.evaluate(()=>normalPreparedPull(accountSlot(AUTH),AUTH.userId,AUTH.token)).then(()=>false,()=>true);await started;
  const edited=await page.evaluate(async({slot,downloaded})=>{const value=JSON.parse(downloaded.primary.raw);value.cards.pear={pos:4};return normalMigrationWritePrepared(slot,downloaded,JSON.stringify(value));},{slot,downloaded});
  release();assert(await pulling);await page.unroute('**/api/v1/me/state/changes?*',hold);
  const after=await page.evaluate(slot=>normalMigrationReadPrepared(slot),slot);assert.deepEqual(after,edited);assert(after.primary.dirty);assert(JSON.parse(after.primary.raw).cards.pear);assert(!JSON.parse(after.primary.raw).cards.cherry);assert.equal(after.primary.fence.revision,remote.state_revision);
  assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state_revision,second.state_revision);
  console.log('PASS ordinary prepared pull is atomic across process termination, account switch and concurrent edit');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

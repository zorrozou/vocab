const {chromium}=require('playwright');const assert=require('assert');const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json()}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const remote=await api('/api/v1/me/state','GET',undefined,seed.token),state=remote.state;
 const event={'device':'ios-one','at':'2026-10-27T12:00:00Z','ok':true,'pos':7},id='aaaaaaaa-1111';
 state.knowledge={...(state.knowledge||{}),checkpointcase:{a:1,b:0,pos:7}};
 state.knowledgeEvidence={...(state.knowledgeEvidence||{}),checkpointcase:{baseId:'empty',base:{a:0,b:0,pos:7},events:{[id]:event}}};
 await api('/api/v1/me/state','PUT',state,seed.token);await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size:8*1024*1024+65536});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-checkpoint-')));let context;
 async function open(){context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});const page=context.pages()[0]||await context.newPage();await page.goto(base);return page}
 async function kill(){const lines=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'}).split('\n').map(x=>x.trim()).filter(x=>x.includes(`--user-data-dir=${profile}`)&&x.includes(executablePath)&&!x.includes('--type='));assert.equal(lines.length,1);const pid=Number(lines[0].split(/\s+/,1)[0]);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;for(let i=0;i<100;i++){try{process.kill(pid,0)}catch{return}await new Promise(r=>setTimeout(r,100))}throw Error('browser did not terminate')}
 try{
  let page=await open();await page.evaluate(a=>onAuthed(a,false),auth);
  await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
  const slot=await page.evaluate(()=>accountSlot(AUTH));await page.locator('#awaitUseSnapshot').click();await page.waitForFunction(()=>!!largeActive&&!largeActive.syncing&&!largeActive.pending);
  await page.locator('#btnSettings').click();await page.waitForFunction(()=>largeActive&&!largeActive.syncing&&!largeActive.pending);
  await page.route('**/api/v1/me/state/experimental-large-checkpoint-preview',route=>route.fulfill({status:409,json:{detail:'history cannot be compacted'}}));
  await page.locator('#bCheckpoint').click();await page.waitForFunction(()=>document.querySelector('#restoreMsg')?.textContent.includes('history cannot be compacted'),null,{timeout:60000});
  assert.equal(await page.evaluate(slot=>largeHasRestoreIntent(slot),slot),false);await page.unroute('**/api/v1/me/state/experimental-large-checkpoint-preview');
  await api('/api/v1/__ui_fixture/delta-hold-response','POST',{});page.once('dialog',d=>d.accept());await page.locator('#bCheckpoint').click();
  let held=false;for(let i=0;i<1200;i++){if((await api('/api/v1/__ui_fixture/delta-hold-status')).started){held=true;break}await new Promise(r=>setTimeout(r,100))}assert(held,'checkpoint did not commit');
  const intent=await page.evaluate(slot=>largeReadVerifiedRestoreIntent(slot),slot);assert.equal(intent.intent.kind,'checkpoint');assert(intent.previousRaw.includes(id));
  await kill();await api('/api/v1/__ui_fixture/delta-release-response','POST',{});page=await open();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.waitForSelector('#awaitRetryRestore');
  assert(await page.evaluate(async slot=>{const old=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(...args){if(this.name==='migrations')throw Error('checkpoint backup quota');return old.apply(this,args)};try{await largeRetryRestore(slot,AUTH.userId,AUTH.token,()=>true);return false}catch(e){return e.message.includes('checkpoint backup quota')}finally{IDBObjectStore.prototype.put=old}},slot));
  assert.equal((await page.evaluate(slot=>largeReadVerifiedRestoreIntent(slot),slot)).intent.batch_id,intent.intent.batch_id);
  await page.locator('#awaitRetryRestore').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('整理结果及整理前备份已保存'),null,{timeout:120000});
  const result=await page.evaluate(slot=>largeReadVerifiedSnapshot(slot),slot);assert.equal(result.baseline.epoch,1);
  const compact=JSON.parse(result.raw);assert.deepEqual(compact.knowledgeEvidence.checkpointcase.events,{});assert.deepEqual(compact.knowledge.checkpointcase,JSON.parse(intent.previousRaw).knowledge.checkpointcase);
  const previous=await page.evaluate(slot=>largeReadLatestRestoreBackup(slot),slot);assert.equal(previous.raw,intent.previousRaw);
  assert.equal(await page.evaluate(slot=>largeHasRestoreIntent(slot),slot),false);
  if(process.env.VOCAB_IOS_STAGED_CHECK){const run=require('util').promisify(cp.execFile);const r=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--verify-web-large-checkpoint',result.revision,result.generation],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000});assert(r.stdout.includes('PASS Swift verifies Web large checkpoint'))}
  await page.locator('#awaitUseSnapshot').click();await page.waitForFunction(()=>!!largeActive);assert.deepEqual(await page.evaluate(()=>S.knowledgeEvidence.checkpointcase.events),{});
  console.log('PASS Web large checkpoint recovers after browser termination'+(process.env.VOCAB_IOS_STAGED_CHECK?' and Swift verifies result':''));
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true})}
})().catch(e=>{console.error(e);process.exit(1)});

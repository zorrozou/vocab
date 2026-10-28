const {chromium}=require('playwright');const assert=require('assert');const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok){const e=Error(`${path}: ${r.status}`);e.status=r.status;throw e}return r.json()}
(async()=>{
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-restore-cancel-')));let context;
 async function open(){context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});const page=context.pages()[0]||await context.newPage();await page.goto(base);return page}
 async function kill(){const lines=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'}).split('\n').map(x=>x.trim()).filter(x=>x.includes(`--user-data-dir=${profile}`)&&x.includes(executablePath)&&!x.includes('--type='));assert.equal(lines.length,1);const pid=Number(lines[0].split(/\s+/,1)[0]);process.kill(pid,'SIGKILL');await context.close().catch(()=>{});context=null;for(let i=0;i<100;i++){try{process.kill(pid,0)}catch{return}await new Promise(r=>setTimeout(r,100))}throw Error('browser did not terminate')}
 try{
  let page=await open();await page.evaluate(a=>onAuthed(a,false),auth);await page.waitForFunction(async()=>{if(!AUTH)return false;const slot=accountSlot(AUTH),r=await deltaIDB(slot,'get');return !!r&&!r.pending&&!r.pull&&JSON.stringify(r.local)===localStorage.getItem(slot)},null,{timeout:30000});
  const slot=await page.evaluate(()=>accountSlot(AUTH)),original=await page.evaluate(slot=>localStorage.getItem(slot),slot);await page.evaluate(slot=>navigator.locks.request(`vocab-delta:${slot}`,async()=>{}),slot);
  const backup=JSON.parse(original);backup.personalizedWeak='w'.repeat(8*1024*1024+65536);backup.cards.web_restore={pos:88,stage:1};
  await page.locator('#btnSettings').click();await page.evaluate(()=>{window.originalDeltaIDB=deltaIDB;deltaIDB=async(...a)=>{if(a[1]==='delete')throw Error('injected transition delete');return window.originalDeltaIDB(...a)}});
  page.once('dialog',d=>d.accept());await page.locator('#bImport').setInputFiles({name:'large.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(backup))});
  await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('injected transition delete'),null,{timeout:90000});
  assert.equal(await page.evaluate(slot=>localStorage.getItem(slot),slot),original);assert(await page.evaluate(slot=>largeReadRestoreTransition(slot),slot));
  await page.evaluate(()=>{deltaIDB=window.originalDeltaIDB});await api('/api/v1/__ui_fixture/large-restore-write-failure','POST',{enabled:true});
  await page.locator('#awaitRetryRestore').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('injected large restore failure'),null,{timeout:120000});
  const record=await page.evaluate(slot=>largeReadVerifiedRestoreIntent(slot),slot);assert.equal(record.intent.kind,undefined);
  await api('/api/v1/__ui_fixture/large-restore-write-failure','POST',{enabled:false});await api('/api/v1/__ui_fixture/delta-hold-response','POST',{});
  page.once('dialog',d=>d.accept());await page.locator('#awaitCancelRestore').click();let held=false;
  for(let i=0;i<1200;i++){if((await api('/api/v1/__ui_fixture/delta-hold-status')).started){held=true;break}await new Promise(r=>setTimeout(r,100))}assert(held,'restore cancel response was not held');
  await kill();await api('/api/v1/__ui_fixture/delta-release-response','POST',{});page=await open();if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await page.waitForSelector('#awaitCancelRestore');page.once('dialog',d=>d.accept());await page.locator('#awaitCancelRestore').click();
  await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('恢复已取消'),null,{timeout:60000});
  assert.equal(await page.evaluate(slot=>largeHasRestoreIntent(slot),slot),false);assert.equal(await page.evaluate(slot=>largeReadRestoreTransition(slot),slot),undefined);
  const saved=await page.evaluate(slot=>largeReadVerifiedSnapshot(slot),slot);assert.equal(saved.raw,record.previousRaw);assert.equal(saved.baseline.epoch,record.intent.restore_epoch);
  const intent=record.intent,stage={batch_id:intent.batch_id,generation:intent.generation,base_revision:intent.base_revision,restore_epoch:intent.restore_epoch,byte_length:Buffer.byteLength(intent.payload),part_count:Math.ceil(Buffer.byteLength(intent.payload)/(256*1024)),sha256:intent.sha256};
  try{await api('/api/v1/me/state/delta-stages','POST',stage,seed.token);assert.fail('late restore stage accepted')}catch(e){assert.equal(e.status,409)}
  await page.locator('#awaitUseSnapshot').click();await page.waitForFunction(()=>!!largeActive&&!largeActive.syncing&&!largeActive.pending);assert(await page.evaluate(()=>largeSyncActive(largeActive,true)));
  const latest=await page.evaluate(slot=>largeReadVerifiedSnapshot(slot),slot);assert.equal(latest.baseline.revision,String(BigInt(intent.base_revision)+1n));assert(!JSON.parse(latest.raw).cards.web_restore);
  if(process.env.VOCAB_IOS_STAGED_CHECK){const run=require('util').promisify(cp.execFile);const r=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--verify-web-restore-cancel',latest.revision,latest.generation],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000});assert(r.stdout.includes('PASS Swift verifies preserved Web restore cancellation state'))}
  console.log('PASS Web restore cancellation recovers after browser termination'+(process.env.VOCAB_IOS_STAGED_CHECK?' with Swift read':''));
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true})}
})().catch(e=>{console.error(e);process.exit(1)});

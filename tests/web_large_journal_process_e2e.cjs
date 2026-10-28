const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath(),slot='vocab_v3_a'+'b'.repeat(32);
(async()=>{
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-large-journal-')));let context;
 async function open(){context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});const page=context.pages()[0]||await context.newPage();await page.goto(base);return page;}
 async function kill(){
  const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'});
  const matches=listing.split('\n').map(line=>line.trim()).filter(line=>line.includes(`--user-data-dir=${profile}`)&&line.includes(executablePath)&&!line.includes('--type='));
  assert.equal(matches.length,1);const pid=Number(matches[0].split(/\s+/,1)[0]);assert(pid>1);process.kill(pid,'SIGKILL');
  await context.close().catch(()=>{});context=null;
  for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){return;}await new Promise(r=>setTimeout(r,100));}
  throw Error('browser process did not terminate');
 }
 async function acquire(page){await page.evaluate(slot=>{window.ready=new Promise((resolve,reject)=>{window.ok=resolve;window.fail=reject;});window.gate=new Promise(r=>window.release=r);window.task=largeLocalWithLease(slot,async lease=>{window.lease=lease;window.ok();await window.gate;}).catch(e=>{window.fail(e);throw e;});},slot);await page.evaluate(()=>window.ready);}
 try{
  let page=await open();
  await page.evaluate(async slot=>{const raw=JSON.stringify({v:1,cards:{apple:{pos:1}},log:[],pendingNew:[],settings:{},payload:'x'.repeat(9*1024*1024)});await largeLocalWrite(slot,null,raw);},slot);
  await acquire(page);
  await page.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.marker=1;await largeLocalAppend(window.lease,JSON.stringify(value));});
  await kill();page=await open();await acquire(page);
  assert.equal(await page.evaluate(()=>JSON.parse(window.lease.raw).marker),1);
  await page.evaluate(()=>largeLocalFlush(window.lease));
  const first=await page.evaluate(async slot=>(await largeLocalRead(slot)).version,slot);
  await page.evaluate(async()=>{const value=JSON.parse(window.lease.raw);value.marker=2;await largeLocalAppend(window.lease,JSON.stringify(value));});
  const failed=await page.evaluate(async slot=>{const orig=IDBObjectStore.prototype.delete;IDBObjectStore.prototype.delete=function(...args){if(this.name==='journals')throw Error('stop after commit');return orig.apply(this,args);};try{await largeLocalFlush(window.lease);return false;}catch(_){return true;}finally{IDBObjectStore.prototype.delete=orig;}},slot);
  assert(failed);const committed=await page.evaluate(async slot=>(await largeLocalRead(slot)).version,slot);assert.notEqual(committed,first);
  await kill();page=await open();await acquire(page);
  assert.equal(await page.evaluate(()=>JSON.parse(window.lease.raw).marker),2);
  await page.evaluate(()=>largeLocalFlush(window.lease));
  assert.equal(await page.evaluate(async slot=>(await largeLocalRead(slot)).version,slot),committed);
  assert.equal(await page.evaluate(async slot=>await largeJournalRead(slot),slot),null);
  // If killed while a new journal transaction is still in flight, the edit
  // was not acknowledged; recovery accepts either the old or complete new view.
  await page.evaluate(()=>{const value=JSON.parse(window.lease.raw);value.marker=3;window.unconfirmed=largeLocalAppend(window.lease,JSON.stringify(value)).catch(()=>{});});
  await kill();page=await open();await acquire(page);
  assert([2,3].includes(await page.evaluate(()=>JSON.parse(window.lease.raw).marker)));
  await page.evaluate(()=>largeLocalFlush(window.lease));
  await page.evaluate(()=>window.release());await page.evaluate(()=>window.task);
  console.log('PASS large-state journal survives killed browser before and after commit');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

const {chromium}=require('playwright');
const {execFile}=require('child_process');
const {promisify}=require('util');
const assert=require('assert');
const run=promisify(execFile);
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
async function wait(page,fn){for(let i=0;i<400;i++){if(await page.evaluate(fn))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
(async()=>{
 if(!process.env.VOCAB_IOS_STAGED_CHECK)throw Error('VOCAB_IOS_STAGED_CHECK is required');
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  await page.evaluate(()=>{S.personalizedDay='2099-01-01';S.personalizedWeak='x'.repeat(2100*1024);S.log.push({eventId:'abcdef0123456789',d:'2026-10-27',word:'web-interop',rating:4,kind:'review'});save();clearTimeout(save._t);if(localSaveFailed)throw Error('local save failed');});
  assert.equal(await page.evaluate(()=>pushState()),true);
  const before=(await api('/api/v1/__ui_fixture/state-upload-status')).stage_successes;assert(before>=1);
  const result=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--interop',auth.user.account_id],{env:{...process.env,VOCAB_TEST_BASE:base,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000,maxBuffer:1024*1024});
  assert(result.stdout.includes('PASS iOS uploads Web-origin state'));
  const after=(await api('/api/v1/__ui_fixture/state-upload-status')).stage_successes;assert(after>before,'Swift client did not submit a staged batch');
  let compactLog=false, observed=[];
  const inspect=async route=>{
   const response=await route.fetch(), body=await response.json();
   observed.push([route.request().url(),body.change?.revision,body.change?.page_count]);
   if(route.request().url().includes('compact=true') && body.change?.page_count===1){
    const ops=JSON.parse(Buffer.from(body.change.data,'base64').toString('utf8')).ops;
    if(ops.some(o=>o.op==='splice_log'&&o.value.items.some(e=>e.word==='swift-compact')))compactLog=true;
   }
   await route.fulfill({response,json:body});
  };
  await page.route('**/api/v1/me/state/changes?*',inspect);
  assert.equal(await page.evaluate(()=>syncFromServer()),true);
  await page.unroute('**/api/v1/me/state/changes?*',inspect);
  assert(compactLog,'Web did not consume the compact Swift log change: '+JSON.stringify(observed));
  assert(await page.evaluate(()=>S.personalizedDay==='2099-01-02'&&S.personalizedWeak?.length===2100*1024&&S.personalizedWeak[0]==='y'));
  assert(await page.evaluate(()=>S.log.some(e=>e.word==='web-interop')&&S.log.some(e=>e.word==='swift-interop')));
  assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state.personalizedWeak[0],'y');
  // Cross the former 2048-operation limit in both directions.
  await page.evaluate(()=>{for(let i=0;i<2500;i++)S.cards['web_bulk_'+String(i).padStart(4,'0')]={pos:i+2,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);if(localSaveFailed)throw Error('local save failed');});
  assert.equal(await page.evaluate(()=>pushState()),true);
  const beforeMany=(await api('/api/v1/__ui_fixture/state-upload-status')).stage_successes;
  const many=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--interop-multiops',auth.user.account_id],{env:{...process.env,VOCAB_TEST_BASE:base,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000,maxBuffer:1024*1024});
  assert(many.stdout.includes('PASS iOS uploads 2100'));
  assert((await api('/api/v1/__ui_fixture/state-upload-status')).stage_successes>beforeMany);
  assert.equal(await page.evaluate(()=>syncFromServer()),true);
  assert(await page.evaluate(()=>Object.keys(S.cards).length===4601&&!!S.cards.swift_bulk_0000&&!!S.cards.web_bulk_0000));
  console.log('PASS Web to Swift to Web staged upload and incremental read');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

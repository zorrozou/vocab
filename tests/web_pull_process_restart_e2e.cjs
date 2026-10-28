const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),childProcess=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(url,method='GET',body,token){const r=await fetch(base+url,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${url}: ${r.status}`);return r.json();}
async function wait(page,condition){for(let i=0;i<300;i++){if(await page.evaluate(condition))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
async function bounded(p){let t;try{return await Promise.race([p,new Promise((_,reject)=>t=setTimeout(()=>reject(Error('staged download did not reach gate')),20000))]);}finally{clearTimeout(t);}}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-pull-profile-')));let context;
 try{
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});let page=context.pages()[0]||await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  const state=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;state.cards.banana={pos:2,stage:1,due:'2099-01-01T00:00:00Z'};
  await api('/api/v1/me/state','PUT',state,seed.token);
  await page.evaluate(()=>{window.originalDelta=deltaIDB;window.reached=new Promise(r=>window.signal=r);window.gate=new Promise(()=>{});
   deltaIDB=async function(slot,op,value){if(op==='put'&&!value?.pull&&value?.pending===null){window.signal();await window.gate;}return window.originalDelta(slot,op,value);};});
  const running=page.evaluate(()=>syncFromServer()).catch(()=>false);await bounded(page.evaluate(()=>window.reached));
  assert(await page.evaluate(async()=>!!S.cards.banana&&!!(await window.originalDelta(accountSlot(AUTH),'get')).pull));
  // Kill only the Chrome main process whose unique user-data directory is this
  // disposable test profile, then reopen the same profile.
  const listing=childProcess.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'});
  const candidates=listing.split('\n').map(line=>line.trim()).filter(line=>line.includes(`--user-data-dir=${profile}`)&&line.includes(executablePath)&&!line.includes('--type='));
  assert.equal(candidates.length,1,`unexpected Chrome processes: ${candidates.length}`);
  const pid=Number(candidates[0].split(/\s+/,1)[0]);assert(Number.isInteger(pid)&&pid>1);process.kill(pid,'SIGKILL');
  await running;await context.close().catch(()=>{});context=null;
  for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){break;}await new Promise(r=>setTimeout(r,100));}
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});page=context.pages()[0]||await context.newPage();
  let fullGets=0;page.on('request',r=>{if(r.method()==='GET'&&r.url().endsWith('/api/v1/me/state'))fullGets++;});
  await page.goto(base);
  if (!await page.evaluate(()=>!!AUTH)) await page.evaluate(a=>onAuthed(a,false),auth);
  try { await wait(page,async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');return !!r&&!r.pull&&!r.pending&&!!S.cards.banana;}); }
  catch (error) {
   const diagnostic=await page.evaluate(async()=>({auth:!!AUTH,cards:Object.keys(S.cards||{}),failure:syncFailureMessage,
    record:AUTH?await deltaIDB(accountSlot(AUTH),'get'):null}));
   throw Error(`${error.message}: ${JSON.stringify(diagnostic)}`);
  }
  assert.equal(fullGets,0);assert(await page.evaluate(()=>!!S.cards.apple));
  console.log('PASS Web staged incremental read survives a killed browser process');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

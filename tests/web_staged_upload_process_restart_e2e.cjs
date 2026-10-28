const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(url,method='GET',body,token){const r=await fetch(base+url,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${url}: ${r.status}`);return r.json();}
async function wait(page,condition){for(let i=0;i<500;i++){if(await page.evaluate(condition))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
async function bounded(p){let t;const error=new Error('staged upload did not reach gate');try{return await Promise.race([p,new Promise((_,reject)=>t=setTimeout(()=>reject(error),20000))]);}finally{clearTimeout(t);}}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-upload-profile-')));let context;
 try{
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});let page=context.pages()[0]||await context.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  await page.evaluate(()=>{S.notes='x'.repeat(2100*1024);save();clearTimeout(save._t);if(localSaveFailed)throw Error('local save failed');});
  let reached;const gate=new Promise(r=>reached=r);
  await page.route('**/api/v1/me/state/delta-stages/**/parts/1',async route=>{await route.fetch();reached();await new Promise(()=>{});});
  const running=page.evaluate(()=>pushState()).catch(()=>false);await bounded(gate);
  const batch=await page.evaluate(async()=>(await deltaIDB(accountSlot(AUTH),'get')).pending.batch.batch_id);
  assert(!(await api('/api/v1/me/state','GET',undefined,seed.token)).state.notes);
  const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'});
  const matches=listing.split('\n').map(line=>line.trim()).filter(line=>line.includes(`--user-data-dir=${profile}`)&&line.includes(executablePath)&&!line.includes('--type='));
  assert.equal(matches.length,1);const pid=Number(matches[0].split(/\s+/,1)[0]);assert(Number.isInteger(pid)&&pid>1);process.kill(pid,'SIGKILL');
  await running;await context.close().catch(()=>{});context=null;
  for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){break;}await new Promise(r=>setTimeout(r,100));}
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});page=context.pages()[0]||await context.newPage();
  let legacy=0,stagedIds=[];page.on('request',r=>{if(r.method()==='PUT'&&r.url().endsWith('/api/v1/me/state'))legacy++;if(r.method()==='POST'&&r.url().endsWith('/delta-stages'))stagedIds.push(r.postDataJSON().batch_id);});
  await page.goto(base);if(!await page.evaluate(()=>!!AUTH))await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');return !!r&&!r.pending&&S.notes?.length===2100*1024&&localStorage.getItem(slotClock(accountSlot(AUTH),'dirty'))!=='1';});
  assert(stagedIds.includes(batch));assert.equal(legacy,0);assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state.notes.length,2100*1024);
  console.log('PASS staged upload survives a killed browser process and replays the same batch');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

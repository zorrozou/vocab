const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs'),os=require('os'),path=require('path'),cp=require('child_process');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
const executablePath=process.env.VOCAB_BROWSER||chromium.executablePath();
async function api(url,method='GET',body,token){const r=await fetch(base+url,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${url}: ${r.status}`);return r.json();}
async function wait(page,condition){for(let i=0;i<400;i++){if(await page.evaluate(condition))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
async function bounded(p){let t;try{return await Promise.race([p,new Promise((_,reject)=>t=setTimeout(()=>reject(Error('snapshot gate timed out')),20000))]);}finally{clearTimeout(t);}}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const profile=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'vocab-bootstrap-profile-')));let context;
 try{
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});let page=context.pages()[0]||await context.newPage();await page.goto(base);
  let reached;const gate=new Promise(r=>reached=r);
  await page.route('**/api/v1/me/state/snapshots?representation=stored',async route=>{reached();await new Promise(()=>{});});
  await page.evaluate(a=>onAuthed(a,false),auth);await bounded(gate);
  await page.evaluate(()=>{S.cards.pear={pos:2};save();clearTimeout(save._t);if(localSaveFailed)throw Error('local save failed');});
  assert(await page.evaluate(()=>localStorage.getItem(deltaMarker(accountSlot(AUTH)))==='1'));
  // localStorage has no API to request a durable flush. This delay tests a
  // settled profile only; it must not be interpreted as power-loss safety.
  await new Promise(r=>setTimeout(r,8000));
  const listing=cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'});
  const matches=listing.split('\n').map(line=>line.trim()).filter(line=>line.includes(`--user-data-dir=${profile}`)&&line.includes(executablePath)&&!line.includes('--type='));
  assert.equal(matches.length,1);const pid=Number(matches[0].split(/\s+/,1)[0]);assert(Number.isInteger(pid)&&pid>1);process.kill(pid,'SIGKILL');
  await context.close().catch(()=>{});context=null;
  for(let i=0;i<100;i++){try{process.kill(pid,0);}catch(_){break;}await new Promise(r=>setTimeout(r,100));}
  context=await chromium.launchPersistentContext(profile,{headless:true,executablePath});page=context.pages()[0]||await context.newPage();let legacy=0;
  page.on('request',r=>{if(r.method()==='PUT'&&r.url().endsWith('/api/v1/me/state'))legacy++;});
  await page.goto(base);
  const startup=await page.evaluate(()=>({auth:!!AUTH,pear:!!S.cards.pear,keys:Object.keys(localStorage).filter(k=>k.startsWith('vocab_v3_')).map(k=>({key:k,value:localStorage.getItem(k)?.slice(0,100)}))}));
  if (!startup.auth || !startup.pear) throw Error('interrupted bootstrap state missing: '+JSON.stringify(startup));
  assert.equal(await page.evaluate(()=>pushState()),false);assert.equal(legacy,0);
  assert(!(await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.pear);
  await page.evaluate(()=>{window.confirm=()=>true;});
  assert((await page.evaluate(()=>reloadServerState())).includes('已加载'));
  assert(await page.evaluate(()=>!!JSON.parse(localStorage.getItem('vocab_before_restore_'+accountSlot(AUTH))).cards.pear));
  assert.equal(await page.evaluate(()=>syncFromServer()),true);
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  assert.equal(legacy,0);
  console.log('PASS interrupted bootstrap retains fence and edit through restart and explicit recovery');
 }finally{if(context)await context.close().catch(()=>{});fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1);});

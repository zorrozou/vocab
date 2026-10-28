const {chromium}=require('playwright');
const {spawnSync}=require('child_process');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
 const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  const sent=await page.evaluate(async()=>{S.cards.apple.due='2020-01-01';S.settings.dailyCap=1;S.settings.newPerDay=0;save();clearTimeout(save._t);return pushState();});
  assert(sent,'Web failed to upload legacy date');
  assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.apple.due,'2020-01-01');
  const helper=process.env.VOCAB_IOS_LEGACY_DATE_CHECK;if(!helper)throw Error('missing Swift helper');
  const run=spawnSync(helper,[],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token,VOCAB_TEST_BASE:base},encoding:'utf8',timeout:60000});
  assert.equal(run.status,0,run.stdout+'\n'+run.stderr);
  assert.equal((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.apple.due,'2020-01-01');
  assert(await page.evaluate(async()=>{await buildQueue();return session.queue.some(x=>x.kind==='review'&&x.word==='apple');}));
  console.log('PASS Web to iOS to Web preserves date-only due and review queue');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

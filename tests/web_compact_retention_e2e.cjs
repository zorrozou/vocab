const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();}
async function wait(page){for(let i=0;i<300;i++){if(await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get'))))return;await new Promise(r=>setTimeout(r,50));}throw Error('no baseline');}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}), auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const state=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;
 state.log=Array.from({length:500},(_,i)=>({eventId:i.toString(16).padStart(32,'0'),d:'2026-10-27',word:'word'+String(i).padStart(4,'0'),kind:'review',rating:3}));
 await api('/api/v1/me/state','PUT',state,seed.token);
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);await wait(page);
  const before=await page.evaluate(async()=>{const x=await deltaIDB(accountSlot(AUTH),'get');return {rev:x.revision,gen:x.generation,epoch:x.epoch};});
  await api('/api/v1/__ui_fixture/state-changes-byte-limit','POST',{limit:1800});
  for(let i=0;i<3;i++){
   const e={eventId:(1000+i).toString(16).padStart(32,'0'),d:'2099-01-01',word:'new'+i,kind:'review',rating:4};
   await api('/api/v1/me/state/deltas','POST',{generation:before.gen,base_revision:String(BigInt(before.rev)+BigInt(i)),restore_epoch:before.epoch,batch_id:crypto.randomUUID().replaceAll('-',''),ops:[{op:'append_log',path:['log'],value:[e]}]},seed.token);
  }
  const legacy=await fetch(`${base}/api/v1/me/state/changes?after=${before.rev}&generation=${before.gen}`,{headers:{Authorization:`Bearer ${seed.token}`}});assert.equal(legacy.status,410);
  let full=0;page.on('request',r=>{if(r.method()==='GET'&&r.url().endsWith('/api/v1/me/state'))full++;});
  assert.equal(await page.evaluate(()=>pushState()),true);
  assert.equal(await page.evaluate(()=>syncFromServer()),true);assert.equal(full,0);
  assert(await page.evaluate(()=>['new0','new1','new2'].every(w=>S.log.some(e=>e.word===w))));
  console.log('PASS Web incremental read survives legacy journal eviction');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

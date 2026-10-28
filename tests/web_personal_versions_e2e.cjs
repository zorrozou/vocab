const {chromium}=require('playwright');
const assert=require('assert');
const base='http://127.0.0.1:18765';
async function call(path,method='GET',body,token){
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body?{body:JSON.stringify(body)}:{})});
 if(!r.ok) throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();
}
(async()=>{
 const username='pv_'+Math.random().toString(36).slice(2,10),password='test_password_123';
 const first=await call('/api/v1/auth/register','POST',{username,password});
 const second=await call('/api/v1/auth/login','POST',{username,password});
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try {
  const a=await browser.newPage(),b=await browser.newPage();
  await Promise.all([a.goto(base+'/'),b.goto(base+'/')]);
  await a.evaluate(async x=>await onAuthed(x,true),first);
  await b.evaluate(async x=>await onAuthed(x,false),second);
  async function commit(page,text){return page.evaluate(async text=>{
    const job={id:crypto.randomUUID(),date:today(),weakKey:'apple',weakWords:['apple'],learnedMaxPos:300,replace:false,owner:deviceId(),status:'complete',personalVersions:reservePersonalVersions(S,['apple'])};
    S.personalJobs=[job];
    if(!applyPersonalJobResult(S,job,{target:'apple',text,recall:null,zh:''})) throw Error('result rejected');
    save();clearTimeout(save._t);if(!await pushState()) throw Error('push failed');
    return {version:job.personalVersions.apple, snapshot:structuredClone(S)};
  },text)}
  const left=await commit(a,'First device sentence.');
  const right=await commit(b,'Second device sentence.');
  assert.notEqual(left.version.device,right.version.device);
  const winner=left.version.device>right.version.device?'First device sentence.':'Second device sentence.';
  let saved=(await call('/api/v1/me/state','GET',null,first.token)).state;
  assert.equal(saved.personalized.apple.text,winner);
  await call('/api/v1/me/state','PUT',left.snapshot,first.token);
  saved=(await call('/api/v1/me/state','GET',null,first.token)).state;
  assert.equal(saved.personalized.apple.text,winner);
  console.log('PASS concurrent browser sentence versions converge and stale results cannot overwrite');
 } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

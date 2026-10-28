const {chromium}=require('playwright');
const assert=require('assert');
const base='http://127.0.0.1:18765';
async function req(path,method='GET',body,token){
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body?{body:JSON.stringify(body)}:{})});
 if(!r.ok)throw Error(`${path} ${r.status} ${await r.text()}`);return r.json();
}
(async()=>{
 const username='know_'+Math.random().toString(36).slice(2,10),password='test_password_123';
 const first=await req('/api/v1/auth/register','POST',{username,password});
 const second=await req('/api/v1/auth/login','POST',{username,password});
 const legacy={v:1,cards:{},log:[],pendingNew:[],settings:{newPerDay:10,dailyCap:100},knowledge:{apple:{a:2,b:1,pos:7}}};
 await req('/api/v1/me/state','PUT',legacy,first.token);
 const concurrent=await Promise.all(Array.from({length:6},()=>req('/api/v1/me/state','GET',null,first.token)));
 const before=concurrent[0];
 assert(concurrent.every(r=>r.state.knowledgeEvidence.apple.baseId===before.state.knowledgeEvidence.apple.baseId && r.updated_at===before.updated_at));
 const again=await req('/api/v1/me/state','GET',null,first.token);
 assert.equal(before.state.knowledgeEvidence.apple.baseId,again.state.knowledgeEvidence.apple.baseId);
 assert.equal(before.updated_at,again.updated_at);
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try{
  const a=await browser.newPage(),b=await browser.newPage();
  await Promise.all([a.goto(base+'/'),b.goto(base+'/')]);
  await a.evaluate(async x=>await onAuthed(x,false),first);
  await b.evaluate(async x=>await onAuthed(x,false),second);
  const left=await a.evaluate(async()=>{recordKnowledge('apple',7,true);save();clearTimeout(save._t);if(!await pushState())throw Error('first push');return structuredClone(S);});
  await b.evaluate(async()=>{recordKnowledge('apple',7,false);save();clearTimeout(save._t);if(!await pushState())throw Error('second push');});
  let state=(await req('/api/v1/me/state','GET',null,first.token)).state;
  assert.equal(state.knowledge.apple.a,3);assert.equal(state.knowledge.apple.b,2);
  assert.equal(Object.keys(state.knowledgeEvidence.apple.events).length,2);
  await req('/api/v1/me/state','PUT',left,first.token);
  state=(await req('/api/v1/me/state','GET',null,first.token)).state;
  assert.equal(state.knowledge.apple.a,3);assert.equal(state.knowledge.apple.b,2);
  const stale=await fetch(base+'/api/v1/me/state',{method:'PUT',headers:{'Content-Type':'application/json',Authorization:`Bearer ${first.token}`},body:JSON.stringify(legacy)});
  assert.equal(stale.status,409);
  console.log('PASS browser devices merge independent anchored evidence once; unverifiable legacy state is rejected');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
 const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  for(let i=0;i<200&&!await page.evaluate(async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));i++)await new Promise(r=>setTimeout(r,50));
  const record=await page.evaluate(()=>deltaIDB(accountSlot(AUTH),'get'));assert(record);
  const review=await api('/api/v1/fsrs/review','POST',{is_new:true,rating:3,deterministic:true},seed.token);
  const enriched=await page.evaluate(async({key,generation})=>deltaResolveSchedulers({cards:{apple:{fsrsReplayVersions:{event:key}}}},generation,AUTH.token),{key:review.scheduler_key,generation:record.generation});
  assert.deepEqual(enriched.fsrsSchedulers[review.scheduler_key],review.scheduler_config);
  assert(await page.evaluate(async({key,generation,config})=>{
   const changed={...config,maximum_interval:config.maximum_interval-1};
   try{await deltaResolveSchedulers({cards:{apple:{fsrsReplayVersions:{event:key}}},fsrsSchedulers:{[key]:changed}},generation,AUTH.token);return false;}catch(_){return true;}
  },{key:review.scheduler_key,generation:record.generation,config:review.scheduler_config}));
  assert(await page.evaluate(async generation=>{try{await deltaResolveSchedulers({cards:{apple:{fsrsReplayVersions:{event:'0'.repeat(64)}}}},generation,AUTH.token);return false;}catch(_){return true;}},record.generation));
  const other=await api('/api/v1/auth/register','POST',{username:'reader_'+Math.random().toString(36).slice(2,10),password:'test_password_123'});
  assert(await page.evaluate(async({key,generation,token})=>{try{await deltaResolveSchedulers({cards:{apple:{fsrsReplayVersions:{event:key}}}},generation,token);return false;}catch(_){return true;}},{key:review.scheduler_key,generation:record.generation,token:other.token}));
  const state=(await api('/api/v1/me/state','GET',undefined,seed.token)).state;
  state.cards.banana={pos:2,stage:1,due:'2099-01-01T00:00:00Z'};state.padding='x'.repeat(200000);await api('/api/v1/me/state','PUT',state,seed.token);
  state.cards.cherry={pos:3,stage:1,due:'2099-01-01T00:00:00Z'};await api('/api/v1/me/state','PUT',state,seed.token);
  const pinned=await api('/api/v1/me/state','GET',undefined,seed.token);
  let injected=false;
  const concurrent=async route=>{
   const response=await route.fetch();
   if(!injected){injected=true;const latest=structuredClone(pinned.state);latest.cards.date={pos:4,stage:1,due:'2099-01-01T00:00:00Z'};await api('/api/v1/me/state','PUT',latest,seed.token);}
   await route.fulfill({response});
  };
  await page.route('**/api/v1/me/state/changes?*',concurrent);
  const actual=await page.evaluate(async r=>deltaReadThrough(r,AUTH.token),record);
  await page.unroute('**/api/v1/me/state/changes?*',concurrent);
  assert(injected);assert.equal(actual.revision,pinned.state_revision);
  assert.deepEqual(Object.keys(actual.base.cards).sort(),['apple','banana','cherry']);
  assert((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards.date);
  let corrupt=false;const bad=async route=>{const response=await route.fetch(),json=await response.json();if(json.change?.page===1&&!corrupt){corrupt=true;json.change.data=(json.change.data[0]==='A'?'B':'A')+json.change.data.slice(1);}await route.fulfill({response,json});};
  await page.route('**/api/v1/me/state/changes?*',bad);
  assert(await page.evaluate(async r=>{try{await deltaReadThrough(r,AUTH.token);return false;}catch(_){return true;}},record));
  await page.unroute('**/api/v1/me/state/changes?*',bad);assert(corrupt);
  assert.equal((await page.evaluate(()=>deltaIDB(accountSlot(AUTH),'get'))).revision,record.revision);
  await api('/api/v1/__ui_fixture/state-changes-prune','POST',{token:seed.token});
  assert(await page.evaluate(async r=>{try{await deltaReadThrough(r,AUTH.token);return false;}catch(e){return e.status===410;}},record));
  await api('/api/v1/__ui_fixture/reset-sync-generation','POST',{});
  const rotated=await page.evaluate(async r=>{try{await deltaReadThrough(r,AUTH.token);return {ok:true};}catch(e){return {status:e.status,message:e.message};}},record);
  assert.equal(rotated.status,409,JSON.stringify(rotated));
  console.log('PASS bounded multi-revision journal reads, concurrent writes, integrity and generation fencing');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

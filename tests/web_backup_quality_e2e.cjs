const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});
 if(!r.ok)throw Error(`${path}: ${r.status} ${await r.text()}`);return r.json();
}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{});
 const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const review=await api('/api/v1/fsrs/review','POST',{is_new:true,rating:3,deterministic:true},auth.token);
 const key=review.scheduler_key, missing=key[0]==='0'?'1'+key.slice(1):'0'+key.slice(1);
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await page.evaluate(()=>navigator.locks.request('vocab-delta:'+accountSlot(AUTH),()=>true));
  await page.evaluate(key=>{S.cards.apple.fsrsHistory={base:{},events:[{id:'saved',schedulerKey:key}]};S.cards.apple.appliedFsrs=['saved'];delete S.fsrsSchedulers;showSettings();},key);
  async function exportBackup(){const event=page.waitForEvent('download');await page.locator('#bExport').click();return JSON.parse(fs.readFileSync(await (await event).path(),'utf8'));}
  let result=await exportBackup();assert(result.fsrsSchedulers[key]);assert(!(await page.locator('#restoreMsg').textContent()).includes('缺少'));
  await api('/api/v1/__ui_fixture/scheduler-backup-oversize','POST',{enabled:true});
  result=await exportBackup();assert(result.fsrsSchedulers[key]);assert.equal(await page.locator('#restoreMsg').textContent(),'');
  await page.evaluate(missing=>{S.cards.apple.fsrsHistory.events.push({id:'missing',schedulerKey:missing},{id:'legacy'});S.cards.apple.appliedFsrs.push('missing','legacy');},missing);
  result=await exportBackup();assert(result.fsrsSchedulers[key]);
  let message=await page.locator('#restoreMsg').textContent();assert(message.includes('缺少')&&message.includes('旧评分'));
  await api('/api/v1/__ui_fixture/scheduler-backup-oversize','POST',{enabled:false});
  await page.evaluate(({key,config})=>{S.cards.apple.fsrsHistory.events=[{id:'saved',schedulerKey:key}];S.cards.apple.appliedFsrs=['saved'];S.fsrsSchedulers={[key]:{...config,library:'local-original'}};}, {key,config:review.scheduler_config});
  result=await exportBackup();assert.equal(result.fsrsSchedulers[key].library,'local-original');assert((await page.locator('#restoreMsg').textContent()).includes('不一致'));
  // A database rotation while resolving must not certify the old lookup.
  await page.evaluate(()=>{delete S.fsrsSchedulers;});
  await api('/api/v1/__ui_fixture/scheduler-backup-oversize','POST',{enabled:true});
  await api('/api/v1/__ui_fixture/scheduler-resolve-hold','POST',{});
  const raceDownload=page.waitForEvent('download');await page.locator('#bExport').click();
  let reached=false;
  for(let i=0;i<100;i++){if((await api('/api/v1/__ui_fixture/scheduler-resolve-status')).started){reached=true;break;}await new Promise(r=>setTimeout(r,50));}
  assert(reached);
  await api('/api/v1/__ui_fixture/reset-sync-generation','POST',{});
  await api('/api/v1/__ui_fixture/scheduler-resolve-release','POST',{});
  result=JSON.parse(fs.readFileSync(await (await raceDownload).path(),'utf8'));
  assert(!result.fsrsSchedulers?.[key]);assert((await page.locator('#restoreMsg').textContent()).includes('未能读取'));
  await api('/api/v1/__ui_fixture/scheduler-backup-oversize','POST',{enabled:false});
  await page.evaluate(missing=>{AUTH=null;S.cards.apple.fsrsHistory.events=[{id:'missing',schedulerKey:missing}];S.cards.apple.appliedFsrs=['missing'];delete S.fsrsSchedulers;showSettings();},missing);
  result=await exportBackup();assert(!result.fsrsSchedulers);assert((await page.locator('#restoreMsg').textContent()).includes('缺少'));
  console.log('PASS browser backup contains available parameters and warns on missing, conflict and guest data');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

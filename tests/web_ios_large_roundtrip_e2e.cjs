const {chromium}=require('playwright');const assert=require('assert');const run=require('util').promisify(require('child_process').execFile);
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 if(!process.env.VOCAB_IOS_STAGED_CHECK)throw Error('VOCAB_IOS_STAGED_CHECK is required');
 await api('/api/v1/__ui_fixture/experimental-large-deltas','POST',{enabled:true});const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size:8*1024*1024+65536});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);await page.locator('#awaitSaveSnapshot').click();await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
  const slot=await page.evaluate(()=>accountSlot(AUTH));await page.locator('#awaitUseSnapshot').click();await page.locator('#bStart, #bPlace').first().waitFor();
  const swift=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--large-web-interop',auth.user.account_id],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000,maxBuffer:1024*1024});assert(swift.stdout.includes('PASS Swift uploads into Web-origin large state'));
  await page.locator('#btnUser').click();await page.locator('#mSync').click();await page.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('✓ 已同步'),null,{timeout:60000});assert(await page.evaluate(()=>!!S.cards.swift_large));await page.locator('#mBack').click();
  await page.evaluate(()=>{const item={kind:'learn',word:'web_large',detail:{word:'web_large',pos:2,senses:[{text:'测试'}]}};session={queue:[item],idx:0,reviewedToday:0,learnedToday:0};void showLearn(item);});await page.locator('#bNext').click();
  await page.waitForFunction(()=>S.cards.web_large?.fsrs&&!S.cards.web_large.pendingFsrs&&largeActive&&!largeActive.pending&&!localSaveFailed,null,{timeout:60000});await page.evaluate(()=>clearTimeout(save._t));
  await page.locator('#btnUser').click();await page.locator('#mSync').click();await page.waitForFunction(()=>document.querySelector('#mMsg')?.textContent.includes('✓ 已同步'),null,{timeout:60000});
  const latest=await page.evaluate(async slot=>{const x=await largeReadVerifiedSnapshot(slot);return {revision:x.revision,generation:x.generation,swift:!!JSON.parse(x.raw).cards.swift_large,web:!!JSON.parse(x.raw).cards.web_large};},slot);assert(latest.swift&&latest.web);
  const verify=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--verify-large-roundtrip',latest.revision,latest.generation],{env:{...process.env,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000,maxBuffer:1024*1024});assert(verify.stdout.includes('PASS Swift verifies Web and Swift large-state changes'));
  console.log('PASS Swift to Web UI download and Web learning to Swift upload on large state');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

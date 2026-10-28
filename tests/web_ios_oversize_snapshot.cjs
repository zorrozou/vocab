const {chromium}=require('playwright');
const {execFile}=require('child_process');
const {promisify}=require('util');
const assert=require('assert');
const run=promisify(execFile);
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
(async()=>{
 if(!process.env.VOCAB_IOS_STAGED_CHECK)throw Error('VOCAB_IOS_STAGED_CHECK is required');
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),size=8*1024*1024+65536;
 const injected=await api('/api/v1/__ui_fixture/oversize-stored-state','POST',{token:seed.token,size});
 const manifest=await api('/api/v1/me/state/snapshots?representation=stored','POST',{},seed.token);
 assert(manifest.byte_length>8*1024*1024&&manifest.state_revision===injected.revision);
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage();await page.goto(base);
  const result=await page.evaluate(async({manifest,token})=>{
    const content=await deltaDecodePages(manifest,async page=>{
      const p=await deltaRequest(`/api/v1/me/state/snapshots/${manifest.snapshot_id}?page=${page}`,token);
      if(p.snapshot_id!==manifest.snapshot_id||p.page!==page)throw Error('invalid page');return p.data;
    },16*1024*1024);
    return {length:content.state.fixtureLarge.length,revision:content.state_revision,generation:content.sync_generation};
  },{manifest,token:seed.token});
  assert.deepEqual(result,{length:size,revision:manifest.state_revision,generation:manifest.generation});
  const swift=await run(process.env.VOCAB_IOS_STAGED_CHECK,['--read-large',manifest.state_revision,manifest.generation],{env:{...process.env,VOCAB_TEST_BASE:base,VOCAB_FIXTURE_TOKEN:seed.token},timeout:120000,maxBuffer:1024*1024});
  assert(swift.stdout.includes('PASS iOS transport verifies a paged oversized stored snapshot'));
  console.log('PASS Web and Swift verify oversized stored snapshot pages without installing them');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

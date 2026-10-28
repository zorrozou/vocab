const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body,token){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});if(!r.ok)throw Error(`${path}: ${r.status}`);return r.json();}
async function wait(page,fn){for(let i=0;i<400;i++){if(await page.evaluate(fn))return;await new Promise(r=>setTimeout(r,50));}throw Error('browser did not reach expected state');}
(async()=>{
 const seed=await api('/api/v1/__ui_fixture/recovery-case','POST',{}),auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage();await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
  await wait(page,async()=>!!(await deltaIDB(accountSlot(AUTH),'get')));
  let stages=0,guarded=0,legacy=0,parts=0;page.on('request',r=>{if(r.method()==='POST'&&r.url().endsWith('/delta-stages'))stages++;if(r.url().endsWith('/guarded-merge'))guarded++;if(r.method()==='PUT'&&r.url().endsWith('/api/v1/me/state'))legacy++;if(r.method()==='PUT'&&r.url().includes('/delta-stages/'))parts++;});
  await page.evaluate(()=>{for(let i=0;i<2500;i++)S.cards['bulk_'+String(i).padStart(4,'0')]={pos:i+2,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);if(localSaveFailed)throw Error('local save failed');});
  assert.equal(await page.evaluate(()=>pushState()),true);assert(stages>0);assert.equal(guarded,0);assert.equal(legacy,0);
  assert.equal(Object.keys((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards).length,2501);
  await page.reload();await wait(page,async()=>{const r=await deltaIDB(accountSlot(AUTH),'get');return !!r&&!r.pending&&Object.keys(S.cards).length===2501;});
  assert(await page.evaluate(()=>{const target={cards:{}};for(let i=0;i<8193;i++)target.cards['x'+i]={pos:i};return deltaDiff({cards:{}},target,{cards:{}})===null;}));
  // Earlier staged servers do not advertise the larger operation limit.
  // Release the unused stage and use the existing guarded merge instead.
  await page.route('**/api/v1/me/state/delta-stages',async route=>{const response=await route.fetch();const body=await response.json();delete body.max_operations;await route.fulfill({response,json:body});});
  await page.evaluate(()=>{for(let i=0;i<2100;i++)S.cards['legacy_'+String(i).padStart(4,'0')]={pos:i+3000,stage:1,due:'2099-01-01T00:00:00Z'};save();clearTimeout(save._t);});
  const previousParts=parts;assert.equal(await page.evaluate(()=>pushState()),true);assert(guarded>0);assert.equal(parts,previousParts);assert.equal(legacy,0);
  assert.equal(Object.keys((await api('/api/v1/me/state','GET',undefined,seed.token)).state.cards).length,4601);
  console.log('PASS Web staged upload of 2500 independent changes without whole-state merge');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

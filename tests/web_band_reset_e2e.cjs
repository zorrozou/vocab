const {chromium}=require('playwright');const assert=require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try{
  const page=await browser.newPage();await page.goto('http://127.0.0.1:18765/');
  await page.evaluate(async()=>{
    const r=await fetch('/api/v1/auth/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:'band_'+Math.random().toString(36).slice(2,10),password:'test_password_123'})});
    await onAuthed(await r.json(),true);
    recordKnowledge('apple',7,true,true);save();clearTimeout(save._t);if(!await pushState())throw Error('initial sync failed');
    window.staleBand=structuredClone(S);window.staleBand.placementResetAt=9999999999;place=()=>{};showSettings();
  });
  page.once('dialog',dialog=>dialog.accept());
  await page.locator('#bReplace').click();
  const outcome=await page.evaluate(async()=>{
    clearTimeout(save._t);if(!await pushState())throw Error('reset sync failed');
    const headers={'Content-Type':'application/json',...authHeaders()};
    const stale=await fetch('/api/v1/me/state',{method:'PUT',headers,body:JSON.stringify(window.staleBand)});
    if(!stale.ok)throw Error(`old state upload ${stale.status}`);
    return (await (await fetch('/api/v1/me/state',{headers:authHeaders()})).json()).state;
  });
  assert.equal(outcome.bandStats,null);assert(!outcome.bandEvidence || Object.keys(outcome.bandEvidence).length===0);
  assert.equal(outcome.calibrated,false);
  assert.equal(outcome.knowledge.apple.a,1);assert(Object.keys(outcome.knowledgeEvidence.apple.events).length===1);
  assert.equal(outcome.placementVersion.counter,1);
  await page.evaluate(()=>{window.firstReset=structuredClone(S);window.firstReset.placementResetAt=9999999999;showSettings();});
  page.once('dialog',dialog=>dialog.accept());await page.locator('#bReplace').click();
  const repeat=await page.evaluate(async()=>{
    S.placementResetAt=1;save();clearTimeout(save._t);if(!await pushState())throw Error('second reset sync failed');
    const r=await fetch('/api/v1/me/state',{method:'PUT',headers:{'Content-Type':'application/json',...authHeaders()},body:JSON.stringify(window.firstReset)});
    if(!r.ok)throw Error(`first reset retry ${r.status}`);
    return (await (await fetch('/api/v1/me/state',{headers:authHeaders()})).json()).state;
  });
  assert.equal(repeat.placementVersion.counter,2);assert.equal(repeat.placementResetAt,1);
  await page.reload();
  await page.waitForFunction(()=>!!document.querySelector('#bPlace'));
  assert.equal(await page.evaluate(()=>S.calibrated),false);
  console.log('PASS browser placement reset survives stale device while retaining word evidence');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

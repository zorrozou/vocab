const assert=require('node:assert/strict');
const {chromium}=require('playwright');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try{
  const page=await browser.newPage();await page.goto('http://127.0.0.1:18765/');await page.locator('#wGuest').click();
  await page.getByRole('button',{name:/进入今日教练课$/}).click();await page.getByRole('button',{name:/看原文$/}).waitFor();
  const saved=await page.evaluate(async()=>{
    const prefix='vocab.study.intervals.v3.vocab.coach.mode.v1.guest.';
    const row={id:crypto.randomUUID(),start:Date.now()/1000-60,end:Date.now()/1000-30,activity:'class'};
    localStorage.setItem(prefix+row.id,JSON.stringify(row));return {prefix,row};
  });
  await page.reload();await page.getByRole('button',{name:/继续今日课程$/}).click();
  await page.waitForFunction(k=>!localStorage.getItem(k),saved.prefix+saved.row.id);
  const used=await page.evaluate(async row=>{
    const headers={...await personalHeaders(),'Content-Type':'application/json'};
    const body={client:crypto.randomUUID(),offset:-new Date().getTimezoneOffset(),action:'record',segments:[row]};
    const post=async()=>{const r=await fetch(API+'/api/v1/coach/clock',{method:'POST',headers,body:JSON.stringify(body)});if(!r.ok)throw Error("clock request failed: "+r.status);return r.json();};
    const a=await post(),b=await post();return {a,b};
  },saved.row);
  assert.equal(used.a.used,used.b.used);assert(used.a.used>=30);assert.equal(used.a.acknowledged[0],saved.row.id);
  console.log('PASS persisted time survives reload, automatically uploads, and duplicate acknowledgements do not add time');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});

const assert=require('assert'),{chromium}=require('playwright');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try {
  const page=await browser.newPage(); await page.goto('http://127.0.0.1:18765/');
  const r=await page.evaluate(()=>{
   AUTH=null;S=defaultState();autoPersonalize=()=>{};
   doneDay();const empty=S.streak;
   S.log.push({d:today(),word:'apple',rating:3,kind:'exposure',source:'personal'});doneDay();const passive=S.streak;
   S.log.push({d:today(),word:'apple',rating:3,kind:'review'});doneDay();const active=S.streak;
   doneDay();return {empty,passive,active,repeated:S.streak,days:S.streakEvidence.days.length};
  });
  assert.deepEqual(r,{empty:0,passive:0,active:1,repeated:1,days:1});
  console.log('PASS empty and passive days do not inflate streak; study counts once');
 } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

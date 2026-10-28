const fs=require('fs'),assert=require('assert'),{chromium}=require('playwright');
(async()=>{
 const fixture=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try{
  const page=await browser.newPage();await page.goto('http://127.0.0.1:18765/');
  const v=await page.evaluate(async({token,uid,accountId,state})=>{
    AUTH={userId:uid,accountId,username:'test',token};S=state;posteriorUpdate(1000,1,1,0.25); S.log.push({eventId:crypto.randomUUID(), d:"2026-10-27", word:"apple", rating:3, kind:"review"});
    save();clearTimeout(save._t);if(!await pushState())throw Error('upload failed');return S.probeCount;
  },fixture);
  assert.equal(v,2);
  console.log('PASS browser submitted its branch of anchored posterior evidence');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

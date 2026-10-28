const fs=require('fs'),assert=require('assert'),{chromium}=require('playwright');
(async()=>{
 const fixture=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try{
  const page=await browser.newPage();await page.goto('http://127.0.0.1:18765/');
  const v=await page.evaluate(async({token,uid,accountId,state})=>{
   AUTH={userId:uid,accountId,username:'test',token};S=state;if(!markPlacementReset())throw Error('cannot mark reset');
   S.placementResetAt=9000000000;S.frontier=4000;S.pointer=4001;S.posterior=[0,1];S.posteriorHistory=null;S.probeCount=4;S.bandStats=null;S.bandEvidence=null;S.track=null;
   save();clearTimeout(save._t);if(!await pushState())throw Error('upload failed');return S.placementVersion;
  },fixture);
  assert.equal(v.counter,1);console.log('PASS Web submitted its concurrent reset');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

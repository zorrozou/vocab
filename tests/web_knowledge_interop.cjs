const fs=require('fs'),assert=require('assert'),{chromium}=require('playwright');
(async()=>{
 const fixture=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try{
  const page=await browser.newPage();await page.goto('http://127.0.0.1:18765/');
  const v=await page.evaluate(async({token,uid,accountId,state})=>{
    AUTH={userId:uid,accountId,username:'test',token};S=state;recordKnowledge('apple',7,true,true);
    save();clearTimeout(save._t);if(!await pushState())throw Error('upload failed');return S.knowledge.apple;
  },fixture);
  assert.equal(v.a,3);assert.equal(v.b,1);
  console.log('PASS browser submitted its branch of anchored knowledge evidence');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

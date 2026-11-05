const assert=require('node:assert/strict'),{chromium}=require('playwright');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try{
  for(const high of [true,false]){
   const page=await browser.newPage({viewport:{width:390,height:844}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
   let injectBad=true,requests=[];
   await page.route('**/api/v1/quiz?**',route=>{
    const pos=Number(new URL(route.request().url()).searchParams.get('pos'));requests.push(pos);
    const actual=injectBad?(high?10987:1):pos;injectBad=false;
    return route.fulfill({json:{word:actual===10987?'facilitator':'word-'+actual,pos:actual,item_id:'a'.repeat(64),options:[{text:'correct',ok:true},{text:'wrong one',ok:false},{text:'wrong two',ok:false},{text:'wrong three',ok:false}]}});
   });
   await page.goto('http://127.0.0.1:18765/');await page.locator('#wGuest').click();
   await page.evaluate(async high=>{
    playText=()=>{};S=defaultState();S.probeCount=12;S.posterior=Array(49).fill(0);S.posterior[high?48:0]=1;
    recordKnowledge(high?'facilitator':'word-1',high?10987:1,true,true);
    Math.random=()=>high?.999999999:0;await place();
   },high);
   const seen=new Set([high?'facilitator':'word-1']);
   for(let n=13;n<=30;n++){
    await page.getByRole('heading',{name:new RegExp('智能定级 · 第 '+n+'/30')}).waitFor();
    const word=await page.locator('#app .big').innerText();assert(!seen.has(word),'repeated '+word);seen.add(word);
    await page.evaluate(high=>{const b=document.querySelector(high?'.opt':'#bUnknown');b.onclick();b.onclick();},high);
    await page.waitForFunction(n=>S.probeCount===n,n);
    if(n===18){
     await page.getByRole('heading',{name:/智能定级 · 第 19\/30/}).waitFor();
     const saved=await page.evaluate(()=>JSON.parse(JSON.stringify(S)));await page.reload();
     await page.evaluate(async({saved,high})=>{S=saved;playText=()=>{};Math.random=()=>high?.999999999:0;await place();},{saved,high});
    }
   }
   await page.getByRole('heading',{name:'定级完成',exact:true}).waitFor();
   assert.equal(await page.evaluate(()=>S.log.filter(e=>e.kind==='placement').length),18,'duplicate answer was recorded');
   assert.equal(seen.size,19);assert.equal(new Set(requests).has(high?10987:1),false,'requested used endpoint');
   assert(await page.locator('#recognitionRange').isVisible());assert((await page.locator('.score').innerText()).includes('～'));assert.equal(await page.evaluate(()=>Object.keys(S.recognitionEvidence).length),18);
   assert.deepEqual(errors,[]);await page.close();
  }
  console.log('PASS browser upper/lower bounds, duplicate taps, invalid quiz, restored state and 30-question completion');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

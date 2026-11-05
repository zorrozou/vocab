const assert=require('node:assert/strict');
const {chromium}=require('playwright');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try {
  for(const size of [{width:320,height:568},{width:390,height:844}]){
   const page=await browser.newPage({viewport:size});const errors=[];page.on('pageerror',e=>errors.push(e.message));
   await page.goto('http://127.0.0.1:18765/');await page.locator('#wGuest').click();
   await page.evaluate(async()=>{
    playText=()=>{};autoPlaySequence=()=>{};S=defaultState();S.calibrated=true;
    const item={kind:'review',word:'apple'};S.cards.apple={pos:1,stage:1,due:today()};session.queue=[item];session.idx=0;
    wordQuiz=async()=>({word:'apple',pos:1,mode:'forward',options:[{text:'苹果',ok:true},{text:'橘子',ok:false},{text:'香甜的梨',ok:false},{text:'树枝与树叶',ok:false}]});
    VocabCoach.page('practice');await showReview(item);
   });
   await page.locator('.thumb-options .opt').last().waitFor();
   const before=await page.locator('.thumb-options').boundingBox();
   assert(before.y>size.height/2-40);assert(before.y+before.height<=size.height);
   for(const option of await page.locator('.opt').all()){
    const box=await option.boundingBox();assert(box.height>=44);assert(box.y+box.height<=size.height);
   }
   assert.equal(await page.evaluate(()=>document.documentElement.scrollHeight>innerHeight+1),false);
   if(process.env.VOCAB_SCREEN_DIR)await page.screenshot({path:process.env.VOCAB_SCREEN_DIR+'/web-review-'+size.width+'.png'});
   await page.locator('.opt').first().click();await page.locator('#r3').waitFor();
   await page.getByText('苹果',{exact:false}).first().waitFor();
   assert.equal(await page.locator('.thumb-quiz').count(),0);
   await page.evaluate(async()=>{S=defaultState();await place()});
   await page.locator('#bPlaceExit').waitFor();
   for(const action of await page.locator('.opt,#bUnknown,#bPlaceExit').all()){
    const box=await action.boundingBox();assert(box.height>=44);assert(box.y+box.height<=size.height);
   }
   assert.equal(await page.evaluate(()=>document.documentElement.scrollHeight>innerHeight+1),false);
   await page.locator('#bPlaceExit').click();
   assert.deepEqual(errors,[]);await page.close();
  }
  console.log('PASS mobile review options remain visible at the bottom on 320x568 and 390x844; grading works, normal layout returns, and placement actions fit');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});

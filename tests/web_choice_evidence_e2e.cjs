const {chromium}=require('playwright'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.VOCAB_BROWSER});
 try{
  const page=await browser.newPage();await page.goto(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765');await page.locator('#wGuest').click();
  const guesses=await page.evaluate(async()=>{
   S=defaultState();S.calibrated=true;session={day:today(),queue:[],idx:0};
   window.observedGuesses=[];posteriorUpdate=(_pos,_resp,_weight,guess)=>observedGuesses.push(guess);scheduleFsrs=async()=>{};
   answerProbe({word:'apple',pos:2389,reverse:true},true);
   answerProbe({word:'pear',pos:2390,reverse:false},false);
   for(const [stability,verifiedPos] of [[30,2389],[1,2389],[30,null]]){
    S.cards.apple={pos:2389,fsrs:{state:2,stability,difficulty:5}};
    await review('apple',3,1,false,false,verifiedPos);
   }
   return observedGuesses;
  });
  assert.deepEqual(guesses,[.25,.25,.25,.25,0],'guessing depends on the four-choice format, not direction or prior stability');
  // Independent validation must identify the word and account for four options too.
  let requested;
  await page.route('**/api/v1/quiz?**',route=>{
   requested=new URL(route.request().url());
   return route.fulfill({json:{word:'apple',pos:2389,mode:'reverse',prompt:'苹果',options:[{text:'apple',ok:true},{text:'pear',ok:false},{text:'book',ok:false},{text:'dog',ok:false}]}});
  });
  await page.evaluate(()=>{
   validation={words:[{word:'apple',pos:1,reverse:true}],idx:0,posterior:null,correct:0,failed:0};
   window.validationEvidence=null;posteriorCalc=(_base,rank,_resp,_weight,guess)=>{validationEvidence={rank,guess};return [.5,.5];};
   void showValidation();
  });
  await page.locator('.opt').first().click();
  assert.equal(requested.searchParams.get('word'),'apple');
  assert.deepEqual(await page.evaluate(()=>validationEvidence),{rank:2389,guess:.25});
  console.log('PASS forward/reverse/mature four-choice evidence uses 25% guessing; independent validation uses verified word identity');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

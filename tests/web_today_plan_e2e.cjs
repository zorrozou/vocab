const {chromium}=require('playwright'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try{
  const page=await browser.newPage();await page.goto(process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/');await page.locator('#wGuest').click();
  await page.evaluate(()=>{
   S=defaultState();S.calibrated=true;S.settings.dailyCap=4;S.settings.newPerDay=5;
   S.log=[{d:today(),word:'apple',kind:'learn',rating:3},{d:today(),word:'apple',kind:'review',rating:3},
          {d:today(),word:'banana',kind:'probe',rating:3},{d:today(),word:'noise',kind:'exposure',rating:3},
          {d:today(),word:'placed',kind:'placement',rating:1}];
   S.cards=Object.fromEntries(['apple','due1','due2','due3'].map(word=>[word,{due:'2000-01-01T00:00:00Z'}]));home();
  });
  const stats=await page.locator('.stat').allTextContents();
  assert(stats.some(x=>x.includes('0')&&x.includes('今日待复习')));
  assert((await page.locator('#app').innerText()).includes('另有 3 个词已到期'));
  assert(stats.some(x=>x.includes('2')&&x.includes('新词上限')));
  console.log('PASS browser homepage displays remaining new-word budget after due reviews');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

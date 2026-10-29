const {chromium}=require('playwright'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.VOCAB_BROWSER});
 try{
  const page=await browser.newPage();await page.goto(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765');await page.locator('#wGuest').click();
  const actual=await page.evaluate(()=>wordQuiz('apple',1));assert.equal(actual.word,'apple');assert.notEqual(actual.pos,1);
  const q={word:'pear',pos:2,options:[{text:'梨',ok:true},{text:'a',ok:false},{text:'b',ok:false},{text:'c',ok:false}]};
  await page.route('**/api/v1/quiz?**',r=>r.fulfill({json:q}));
  await page.evaluate(()=>{S=defaultState();S.calibrated=true;S.cards.apple={pos:1,stage:1,due:'2000-01-01'};session={queue:[{kind:'review',word:'apple'}],idx:0};void showReview(session.queue[0]);});
  await page.locator('#bFlip').waitFor();assert.equal(await page.locator('.opt').count(),0);
  await page.evaluate(()=>quizRound(['apple'],0));await page.locator('#bQuizRetry').waitFor();
  assert.equal(await page.evaluate(()=>S.log.length),0);
  assert.equal(await page.evaluate(()=>S.quizCompleted?.length||0),0);
  await page.unroute('**/api/v1/quiz?**');
  await page.evaluate(()=>quizRound(['apple'],0));await page.locator('.opt').first().waitFor();
  assert.equal(await page.evaluate(()=>S.cards.apple.pos),1,'background quiz loading must not mutate saved card metadata');
  await page.locator('.opt').filter({hasText:actual.options.find(o=>o.ok).text}).click();
  await page.waitForFunction(()=>S.log.some(x=>x.kind==='review'));
  assert.equal(await page.evaluate(()=>S.cards.apple.pos),actual.pos,'verified position is saved with the answer');
  q.word='apple';q.options[1].ok=true;
  await page.route('**/api/v1/quiz?**',r=>r.fulfill({json:q}));
  assert.equal(await page.evaluate(()=>wordQuiz('apple',1)),null);
  console.log('PASS stale-rank quizzes use the correct word; mismatched or ambiguous responses cannot record learning evidence');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

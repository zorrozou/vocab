const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.VOCAB_BROWSER});
 try {
  const page=await browser.newPage(); await page.goto(base); await page.locator('#wGuest').click();
  await page.route('**/api/v1/quiz?**',r=>r.fulfill({json:{word:'apple',pos:1,options:[{text:'苹果',ok:true},{text:'梨',ok:false},{text:'香蕉',ok:false},{text:'桃',ok:false}]}}));
  let started; const gate=new Promise(r=>started=r);
  await page.route('**/api/v1/fsrs/review',async r=>{started(); await new Promise(resolve=>setTimeout(resolve,1200)); await r.abort();});
  await page.evaluate(()=>{
   S=defaultState(); S.calibrated=true; S.cards.apple={pos:1,stage:1,due:'2000-01-01T00:00:00Z'};
   S.log=[{d:today(),word:'apple',kind:'learn',rating:3}];
   void quizRound(['apple'],0);
  });
  await page.locator('.opt[data-i="0"]').click(); await gate;
  const saved=await page.evaluate(()=>JSON.parse(localStorage.getItem('vocab_v1')));
  assert(saved.quizCompleted?.includes('apple'),'completion must be durable before the FSRS response');
  assert.equal(saved.quizProgressDay,saved.log[0].d);
  assert.equal(saved.quizDay,saved.log[0].d);
  assert.equal(saved.cards.apple.pendingFsrs.events.length,1);
  assert.equal(saved.log.filter(x=>x.kind==='review').length,1);
  await page.reload();
  await page.evaluate(()=>{autoPersonalize=async()=>{}; maybeQuiz();});
  assert(!(await page.locator('#app h2').first().innerText()).includes('验收测试'),'reload must not repeat the submitted acceptance');
  await page.evaluate(()=>review('apple',1,1.0,false,true));
  assert.equal(await page.evaluate(()=>S.log.filter(x=>x.kind==='review').length),1,'duplicate acceptance cannot change FSRS twice');
  console.log('PASS acceptance rating and completion persist together before FSRS, survive reload and reject duplicate submission');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

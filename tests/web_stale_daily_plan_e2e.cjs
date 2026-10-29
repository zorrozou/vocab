const {chromium}=require('playwright'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.VOCAB_BROWSER});
 try{
  const page=await browser.newPage();await page.goto(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765');await page.locator('#wGuest').click();
  await page.evaluate(()=>{
   S=defaultState();S.calibrated=true;S.settings.dailyCap=1;S.settings.newPerDay=1;
   refreshPersonalJobs=async()=>{};flushPendingFsrs=async()=>{};trackLevelDaily=()=>{};prefetchDay=()=>{};pickProbes=async()=>[];
  });
  let release,started;const waiting=new Promise(r=>started=r),gate=new Promise(r=>release=r);
  await page.route('**/api/v1/lexicon/at?**',async route=>{started();await gate;await route.continue();});
  const building=page.evaluate(()=>buildQueue());await waiting;
  await page.evaluate(()=>S.log.push({d:today(),word:'other-device',kind:'review',rating:3}));release();
  assert.equal(await building,false,'a changed daily count must invalidate the in-flight plan');
  assert.equal(await page.evaluate(()=>session.queue.length),0);
  await page.unroute('**/api/v1/lexicon/at?**');
  for (const change of ['day', 'state']) {
   await page.evaluate(()=>{S=defaultState();S.calibrated=true;S.settings.dailyCap=1;S.settings.newPerDay=1;session={queue:[],idx:0};home();});
   let allow,enter;const started=new Promise(r=>enter=r),held=new Promise(r=>allow=r);
   await page.route('**/api/v1/lexicon/at?**',async route=>{enter();await held;await route.continue();});
   await page.locator('#bStart').click();await started;
   await page.evaluate(change=>{
    if(change==='day'){
     window.originalDate=Date;const now=Date.now()+86400000;
     window.Date=class extends originalDate{constructor(...args){super(...(args.length?args:[now]));}static now(){return now;}};
    }else{S=structuredClone(S);S.log.push({d:today(),word:'other-device',kind:'review',rating:3});}
   },change);
   allow();await page.waitForFunction(()=>document.querySelector('#bStart')?.disabled===false);
   assert.equal(await page.locator('#bStart').innerText(),'重新加载');
   assert.equal(await page.evaluate(()=>session.queue.length),0);
   if(change==='day')await page.evaluate(()=>{window.Date=originalDate;delete window.originalDate;});
   await page.unroute('**/api/v1/lexicon/at?**');
  }
  // A queue already on screen must be checked again at the point of grading.
  const capped=await page.evaluate(async()=>{
   S.cards.apple={pos:1,stage:1,due:'2000-01-01'};session={day:today(),queue:[{kind:'review',word:'apple'}],idx:0};
   const before=JSON.stringify(S);await review('apple',3);return {same:before===JSON.stringify(S),text:document.querySelector('#app').innerText};
  });
  assert(capped.same,'stale grading must not change cards, evidence, history or logs');assert(capped.text.includes('上限'));
  const newTarget=await page.evaluate(async()=>{
   S=defaultState();S.calibrated=true;S.settings.dailyCap=10;S.settings.newPerDay=1;
   S.log=[{d:today(),word:'already-learned',kind:'learn',rating:3}];session={day:today(),queue:[],idx:0};
   await learn('apple',1,3);return {card:S.cards.apple,logs:S.log.length};
  });
  assert.equal(newTarget.card,undefined);assert.equal(newTarget.logs,1);
  const midnight=await page.evaluate(async()=>{
   S=defaultState();S.calibrated=true;session={day:addDays(today(),-1),queue:[],idx:0};
   await learn('apple',1,3);return {cards:Object.keys(S.cards),logs:S.log.length,text:document.querySelector('#app').innerText};
  });
  assert.equal(midnight.logs,0);assert.deepEqual(midnight.cards,[]);assert(midnight.text.includes('日期'));
  const alreadyLearned=await page.evaluate(async()=>{
   S=defaultState();S.calibrated=true;S.cards.apple={pos:1,stage:2,due:'2030-01-01'};
   session={day:today(),queue:[],idx:0};const before=JSON.stringify(S);await learn('apple',1,3);
   const learned=before===JSON.stringify(S);answerProbe({word:'apple',pos:1},true);
   const probed=before===JSON.stringify(S);
   S.cards={};S.log=[{d:today(),word:'apple',kind:'probe',rating:4}];const beforeProbe=JSON.stringify(S);
   answerProbe({word:'apple',pos:1},true);return {learned,probed,dedup:beforeProbe===JSON.stringify(S)};
  });
  assert.deepEqual(alreadyLearned,{learned:true,probed:true,dedup:true});
  // Repeated learning steps for a counted word remain allowed at the cap.
  await page.route('**/api/v1/fsrs/review',route=>route.abort());
  const repeat=await page.evaluate(async()=>{
   S=defaultState();S.calibrated=true;S.settings.dailyCap=1;S.settings.newPerDay=0;
   S.log=[{d:today(),word:'apple',kind:'review',rating:1}];S.cards.apple={pos:1,stage:1,due:'2000-01-01'};
   session={day:today(),queue:[],idx:0};await review('apple',3);return S.cards.apple.pendingFsrs?.events.length;
  });
  assert.equal(repeat,1);
  console.log('PASS stale in-flight plans, synchronized caps, changed new targets and midnight answers are fenced; counted-word repeats remain allowed');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

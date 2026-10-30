const {chromium}=require('playwright'),assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.VOCAB_BROWSER});
 const context=await browser.newContext({timezoneId:'Asia/Shanghai'}),page=await context.newPage();
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(base);await page.locator('#wGuest').click();
  const partial=await page.evaluate(async()=>{
   VocabLibrary.init(API);const controller=new AbortController();let count=0;
   try{await VocabLibrary.download(n=>{count=n;if(n>=256)controller.abort();},controller.signal);}catch(e){if(e.name!=='AbortError')throw e;}
   return {count,active:await VocabLibrary.active()};
  });assert(partial.count>=256);assert.equal(partial.active,null,'partial library must not activate');
  await page.evaluate(async()=>{
   const name=(await caches.keys()).find(n=>n.startsWith('vocab-library-v1-')&&!n.endsWith('meta'));
   const cache=await caches.open(name),keys=await cache.keys();await cache.put(keys[0],new Response('corrupt'));
   showSettings();
  });
  await page.locator('#bLibraryPack').click();
  await page.waitForFunction(()=>document.querySelector('#maintenanceMsg')?.textContent.includes('已校验保存'),{},{timeout:120000});
  const m=await page.evaluate(()=>VocabLibrary.active());assert.equal(m.words,10986);assert.equal(m.pages.length,86);
  assert(!errors.length,errors.join('\n'));
  // Structured report is independent of sentence swapping and is idempotent.
  await page.evaluate(()=>showContentFeedback('apple','She put an apple on the table.','static'));
  await page.locator('#feedbackReason').selectOption('translation');await page.locator('#feedbackSend').click();
  await page.waitForFunction(()=>document.querySelector('#feedbackStatus').textContent.includes('已进入'),{},{timeout:15000});
  await page.locator('#feedbackClose').click();
  await context.setOffline(true);await page.reload({waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>typeof S==='object',{},{timeout:15000});
  const offline=await page.evaluate(async()=>{
   const m=await VocabLibrary.active(),words=['apple','teen','separate',Object.keys(m.index).at(-1)];let checked=0;
   for(const word of words){
    const r=await fetch(API+'/api/v1/lexicon/word?word='+word),w=await r.json();if(w.word!==word||w.sentences.length!==3)throw Error('word unavailable '+word);
    for(const mode of ['forward','reverse']){const q=await wordQuiz(word,w.pos,mode);if(q?.word!==word||q.options.filter(x=>x.ok).length!==1)throw Error('bad quiz');checked++;}
    const a=await(await fetch(API+'/api/v1/sentence/alternatives?word='+word+'&tier=1')).json();if(!a.sentences.length)throw Error('no alternatives');
   }
   S.cards.apple={};S.log=[{word:'apple',d:today(),kind:'review',rating:1}];const el=document.createElement('div');document.body.append(el);
   const practice=await localWeakPractice(['apple'],el);
   return {checked,practice,text:el.textContent,cards:Object.keys(S.cards),privateKeys:(await Promise.all((await caches.keys()).map(async n=>(await(await caches.open(n)).keys()).map(r=>r.url)))).flat().filter(k=>/\/me\/|\/auth\/|\/personalized/.test(k))};
  });assert.equal(offline.checked,8);assert(offline.practice,JSON.stringify(offline));assert(/本机薄弱词/.test(offline.text));assert.deepEqual(offline.cards,['apple']);assert.deepEqual(offline.privateKeys,[]);
  await page.evaluate(()=>{showSettings();document.querySelector('#bClearLibrary').click();});
  await page.waitForFunction(()=>document.querySelector('#maintenanceMsg').textContent.includes('已删除'));
  assert.equal(await page.evaluate(()=>VocabLibrary.active()),null);
  assert.deepEqual(await page.evaluate(()=>Object.keys(S.cards)),['apple'],'clear content cannot clear progress');
  console.log('PASS full 10,986-word library: cancel/resume, corrupt-page replacement, atomic activation, offline restart/queries/alternatives/practice, private-cache exclusion and safe removal');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

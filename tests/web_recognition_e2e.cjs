const {chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs');
(async()=>{const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});try{
 const page=await browser.newPage({viewport:{width:390,height:844}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 let question;page.on('response',async r=>{if(r.url().includes('/api/v1/quiz?')&&r.status()===200)question=await r.json()});
 await page.goto('http://127.0.0.1:18765/');await page.locator('#wGuest').click();await page.evaluate(()=>{playText=()=>{};});await page.locator('#bPlace').click();
 const seen=new Set();for(let i=0;i<30;i++){
  await page.getByRole('heading',{name:new RegExp('智能定级 · 第 '+(i+1)+'/30')}).waitFor();
  await page.locator('#bUnknown').waitFor();const pos=question.pos;assert(!seen.has(pos));seen.add(pos);
  if(i%3===0)await page.locator('#bUnknown').click();else await page.locator('.opt').nth(question.options.findIndex(o=>o.ok)).click();
  await page.waitForFunction(n=>S.probeCount===n,i+1);
  if(i===13){await page.getByRole('heading',{name:/第 15\/30/}).waitFor();await page.locator('#bPlaceExit').click();await page.reload();await page.evaluate(()=>playText=()=>{});await page.locator('#bPlace').click();}
 }
 await page.getByRole('heading',{name:'定级完成',exact:true}).waitFor();
 const result=await page.evaluate(()=>({counts:VocabRecognition.counts(S),events:Object.keys(S.recognitionEvidence).length,range:VocabRecognition.rangeText(S),pointer:S.pointer,stats:VocabRecognition.estimate(S)}));
 assert.deepEqual(result.counts.map(s=>s.n),[5,5,5,5,5,5]);assert.equal(result.events,30);assert.equal(seen.size,30);
 await page.screenshot({path:'/tmp/vocab-recognition-20261105/web-result.png'});
 const before=await page.evaluate(()=>JSON.stringify([S.cards,S.posterior,S.recognitionEvidence,S.pointer,S.pendingNew]));
 await page.evaluate(()=>startValidation());
 const holdout=new Set();for(let i=0;i<24;i++){
  await page.getByRole('heading',{name:`独立水平校验 ${i+1}/24`}).waitFor();holdout.add(question.pos);assert(!seen.has(question.pos));await page.locator('.opt').nth(question.options.findIndex(o=>o.ok)).click();
 }
 await page.getByRole('heading',{name:'独立校验结果',exact:true}).waitFor();assert.equal(holdout.size,24);
 assert.equal(await page.evaluate(()=>JSON.stringify([S.cards,S.posterior,S.recognitionEvidence,S.pointer,S.pendingNew])),before);
 assert.equal(await page.evaluate(()=>S.evalReport.recognitionVersion),1);
 const noJump=await page.evaluate(()=>{let old=S.pointer;S.posterior=Array(49).fill(0);S.posterior[48]=1;S.track=null;trackLevelDaily();return S.pointer===old;});assert(noJump);
 await page.screenshot({path:'/tmp/vocab-recognition-20261105/web-holdout.png'});
 assert.deepEqual(errors,[]);console.log('PASS real API: 30 stratified unique questions, correct/wrong, reload, 24 independent full-bank questions, unchanged learning state and no automatic jumps');console.log(JSON.stringify(result));
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)});

const {chromium}=require('playwright'),assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.VOCAB_BROWSER});
 const context=await browser.newContext({timezoneId:'Asia/Shanghai'}),page=await context.newPage();
 try {
  await page.goto(base);await page.locator('#wGuest').click();
  await page.request.post(base+'/api/v1/__ui_fixture/content-quality-case');
  const word=(await(await page.request.get(base+'/api/v1/lexicon/word?word=apple')).json());
  assert(word.sentences.some(s=>s.tier===1 && /apple/i.test(s.text) && s.zh),'bad preferred sentence must fall back to a valid translated candidate');
  const repaired=await page.evaluate(async()=>{
   S=defaultState();S.calibrated=true;S.settings.autoAudio=false;
   const event={id:crypto.randomUUID(),at:new Date(Date.now()-3600000).toISOString(),rating:3};
   const original={fsrsIssue:'bad derived base',fsrsHistory:{base:{is_new:true},events:[event]},pendingFsrs:{base:{is_new:false,state:2,stability:-1,difficulty:5},events:[event]}};
   S.cards.apple=original;showSettings();await repairQuarantinedCards(document.querySelector('#maintenanceMsg'));
   return {card:S.cards.apple,message:document.querySelector('#maintenanceMsg').textContent,backup:unverifiedKeys(AUTH).some(k=>k.startsWith('vocab_repair_backup_')),id:event.id};
  });
  assert(repaired.backup);assert(!repaired.card.pendingFsrs);assert(!repaired.card.fsrsIssue);assert.deepEqual(repaired.card.appliedFsrs,[repaired.id]);
  const first=await page.request.post(base+'/api/v1/fsrs/repair',{data:{card:repaired.card}});assert(first.ok(),await first.text());
  assert.deepEqual((await first.json()).card.fsrs,repaired.card.fsrs,'idempotent repair');
  const irreparable=await page.request.post(base+'/api/v1/fsrs/repair',{data:{card:{fsrsIssue:'missing history'}}});assert.equal(irreparable.status(),409);
  const mismatch=structuredClone(repaired.card);mismatch.pendingFsrs={base:{is_new:true},events:[{id:'unknown',at:new Date().toISOString(),rating:3}]};
  assert.equal((await page.request.post(base+'/api/v1/fsrs/repair',{data:{card:mismatch}})).status(),409);
  const seed=await page.evaluate(async card=>{
   const username='maint_'+Math.random().toString(36).slice(2,10),password='test_maintenance_123';
   const r=await fetch('/api/v1/auth/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username,password})});
   const a=await r.json(),state=defaultState();state.calibrated=true;state.pointer=2390;state.settings.autoAudio=false;state.settings.newPerDay=10;
   const p=await fetch('/api/v1/me/state',{method:'PUT',headers:{'Content-Type':'application/json',Authorization:'Bearer '+a.token},body:JSON.stringify(state)});if(!p.ok)throw Error(await p.text());
   return {username,password,token:a.token};
  },repaired.card);
  await page.evaluate(()=>authForm('login'));
  await page.locator('#aUser').fill(seed.username);await page.locator('#aPass').fill(seed.password);await page.locator('#aGo').click();await page.locator('#bStart').waitFor();
  const h=await page.request.get(base+'/api/v1/me/learning-health',{headers:{Authorization:'Bearer '+seed.token}});assert(h.ok(),await h.text());assert.equal(h.headers()['cache-control'],'no-store');
  await page.evaluate(async()=>{
   S.pendingNew=[await(await fetch('/api/v1/lexicon/word?word=apple')).json()];
   const q=await prepareSharedQueue([{kind:'learn',word:'apple',detail:S.pendingNew[0]}],false,()=>true,false);if(q.length!==1)throw Error('permit');
   showSettings();
  });
  await context.route('**/api/v1/tts?**',r=>r.fulfill({status:200,contentType:'audio/mpeg',body:Buffer.alloc(1024,1)}));
  await page.locator('#bOfflinePack').click();
  await page.waitForFunction(()=>document.querySelector('#maintenanceMsg').textContent.includes('1/1'),{},{timeout:30000});
  await context.unroute('**/api/v1/tts?**');
  const cached=await page.evaluate(async()=>{
   const names=await caches.keys();const keys=[];for(const n of names)for(const r of await(await caches.open(n)).keys())keys.push(r.url);
   return keys;
  });
  assert(!cached.some(k=>k.includes('/me/')||k.includes('/auth/')||k.includes('/personalized')),'private endpoints never cached');
  await context.setOffline(true);await page.reload({waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>typeof S==='object' && !!AUTH,{},{timeout:15000});
  const offline=await page.evaluate(async()=>{
   refreshPersonalJobs=async()=>{};const ready=await buildQueue();
   const q=await wordQuiz('apple',2390,'reverse');
   const audio=await fetch('/api/v1/tts?text=apple&v='+encodeURIComponent(S.settings.voice||''));
   return {ready,words:session.queue.map(i=>i.word),quiz:q?.word,audio:audio.status};
  });
  assert(offline.ready,JSON.stringify(offline));assert.deepEqual(offline.words,['apple']);assert.equal(offline.quiz,'apple');assert.equal(offline.audio,200);
  console.log('PASS safe/idempotent repair, original backup, bad-history rejection, private health, offline shell/quiz/audio and issued-only queue');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

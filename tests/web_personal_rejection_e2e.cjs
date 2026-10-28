const {chromium}=require('playwright');
const assert=require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
 try{
  const page=await browser.newPage();await page.goto('http://127.0.0.1:18765/');
  await page.route('**/api/v1/personalize',route=>route.abort());
  await page.evaluate(async()=>{
   const r=await fetch('/api/v1/auth/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:'reject_'+Math.random().toString(36).slice(2,9),password:'test_password_123'})});
   await onAuthed(await r.json(),true);
   S.personalized.apple={text:'An old sentence.',recall:null,zh:'旧句'};save();clearTimeout(save._t);await pushState();
   window.staleState=structuredClone(S);
   document.querySelector('#app').innerHTML='<div class="sent">An old sentence.<button class="bad" data-kind="personal" data-w="apple" data-t="An old sentence.">换一句</button></div>';
   bindPlays();
  });
  await page.locator('.bad').click();
  await page.waitForFunction(()=>S.rejectedPersonalized?.apple?.includes('An old sentence.'));
  const result=await page.evaluate(async()=>{
   clearTimeout(save._t);if (!await pushState()) throw Error('rejection upload failed');
   const headers={'Content-Type':'application/json',...authHeaders()};
   let r=await fetch('/api/v1/me/state',{method:'PUT',headers,body:JSON.stringify(window.staleState)});
   if(!r.ok) throw Error(`stale write ${r.status}`);
   let merged=(await (await fetch('/api/v1/me/state',{headers:authHeaders()})).json()).state;
   const filtered=personalSentence('apple');
   const updated=structuredClone(merged);
   const job={id:'new-replacement-job',date:today(),weakKey:'apple',weakWords:['apple'],learnedMaxPos:300,replace:false,owner:deviceId(),status:'complete',personalVersions:reservePersonalVersions(updated,['apple'])};
   updated.personalJobs.push(job);
   if (!applyPersonalJobResult(updated,job,{target:'apple',text:'A new sentence.',recall:null,zh:'新句'})) throw Error('new job result was not applied');
   r=await fetch('/api/v1/me/state',{method:'PUT',headers,body:JSON.stringify(updated)});
   if(!r.ok) throw Error(`new write ${r.status}`);
   const fresh=(await (await fetch('/api/v1/me/state',{headers:authHeaders()})).json()).state;
   const staleOther=structuredClone(window.staleState);staleOther.personalized.apple.text='Different stale sentence.';
   r=await fetch('/api/v1/me/state',{method:'PUT',headers,body:JSON.stringify(staleOther)});
   if(!r.ok) throw Error(`other stale write ${r.status}`);
   const afterStale=(await (await fetch('/api/v1/me/state',{headers:authHeaders()})).json()).state;
   const current=await (await fetch('/api/v1/me/state',{headers:authHeaders()})).json();
   const oldBackup=structuredClone(fresh);oldBackup.personalized.apple={text:'An old sentence.'};
   const restore=await fetch('/api/v1/me/state/restore',{method:'POST',headers,body:JSON.stringify({state:oldBackup,expected_updated_at:current.updated_at})});
   if(!restore.ok) throw Error(`restore ${restore.status}`);
   const restored=(await restore.json()).state;
   S.cards.pear={stage:6};S.personalized.pear={text:'Mastered sentence.'};
   prunePersonalized();
   return {merged,filtered,fresh,afterStale,restored,pruned:S.personalized.pear,rejected:S.rejectedPersonalized.pear};
  });
  assert(!result.merged.personalized.apple && !result.filtered, JSON.stringify(result));
  assert.deepEqual(result.merged.rejectedPersonalized.apple,['An old sentence.']);
  assert.equal(result.fresh.personalized.apple.text,'A new sentence.');
  assert.equal(result.afterStale.personalized.apple.text,'A new sentence.');
  assert(!result.restored.personalized.apple, 'restoring a contradictory backup must not resurrect the rejected sentence');
  assert(!result.pruned && result.rejected.includes('Mastered sentence.'));
  console.log('PASS user rejection survives stale HTTP sync while new sentences remain available');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

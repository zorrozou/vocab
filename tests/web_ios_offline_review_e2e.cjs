const {chromium}=require('playwright');
const assert=require('assert');
const fs=require('fs');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
if(!/^http:\/\/127\.0\.0\.1:[0-9]+$/.test(base)) throw Error('Expected isolated loopback fixture');
async function request(path, options) {
  const response=await fetch(base+path,options);
  if(!response.ok) throw Error(`${path}: ${response.status}`);
  return response.json();
}
(async()=>{
  assert.deepEqual(await request('/api/v1/__ui_fixture'),{fixture:'vocab-ui-isolated-v1'});
  const seed=process.env.VOCAB_OFFLINE_FIXTURE_USER ? {username:process.env.VOCAB_OFFLINE_FIXTURE_USER,password:'test_password_123'} : await request('/api/v1/__ui_fixture/offline-case');
  assert(seed.username && seed.password,'offline fixture account missing');
  const auth=await request('/api/v1/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:seed.username,password:seed.password})});
  const chrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  const browser=await chromium.launch({headless:true,...(fs.existsSync(chrome)?{executablePath:chrome}:{})});
  try {
    const page=await browser.newPage();await page.goto(base);
    await page.evaluate(session=>onAuthed(session,false),auth);
    const card=await page.evaluate(()=>S.cards.apple);
    assert(card && !card.pendingFsrs && card.fsrs && card.fsrs.due,'replayed review not available on Web');
    const events=card.fsrsHistory?.events;
    assert(Array.isArray(events) && events.length===1,'expected exactly one review event');
    assert(Array.isArray(card.appliedFsrs) && card.appliedFsrs.filter(id=>id===events[0].id).length===1,'review event was not applied exactly once');
    console.log('PASS Web reads the iOS offline review exactly once after replay');
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exit(1);});

const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
async function api(path,method='GET',body){
  const response=await fetch(base+path,{method,headers:{'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});
  if(!response.ok) throw Error(`${path}: ${response.status}`);
  return response.json();
}
(async()=>{
  const seed=await api('/api/v1/__ui_fixture/staged-ui-case');
  const auth=await api('/api/v1/auth/login','POST',{username:seed.username,password:seed.password});
  const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
  try {
    const page=await browser.newPage();
    await page.goto(base);await page.evaluate(a=>onAuthed(a,false),auth);
    await page.locator('#awaitSaveSnapshot').click();
    await page.waitForFunction(()=>document.querySelector('#awaitMsg')?.textContent.includes('同步基线已保存'));
    await page.locator('#awaitUseSnapshot').click();
    await page.locator('#bStart, #bPlace').first().waitFor();
    const mode=process.env.VOCAB_EXPECT_RESTORE_KIND||'resume';
    assert(await page.evaluate(mode=>(S.restoreEpoch ?? 0)===(mode==='cancel'?0:1) && S.personalizedWeak.length===7*1024*1024 &&
      (mode==='new'||mode==='cancel' ? S.personalized.apple.text.length===2100*1024 : !!S.cards.restore_ui_marker),mode));
    console.log(mode==='cancel' ? 'PASS Web reads preserved state after iOS checkpoint cancellation' : 'PASS Web reads state restored through iOS app');
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exit(1)});

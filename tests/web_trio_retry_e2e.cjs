const {chromium} = require('playwright');
const assert = require('assert');
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page = await browser.newPage();
    await page.addInitScript(() => { window.SpeechRecognition = class { start() { this.onresult({results:[[{transcript:'apple on table',confidence:0.8}]]}); } }; });
    let fail = true;
    await page.route('**/api/v1/sentence/trio?**', route => route.fulfill(fail ? {status:503,contentType:'application/json',body:'{}'} : {contentType:'application/json',body:JSON.stringify({sentences:[{tier:1,text:'Apple on table',zh:'苹果在桌上'}]})}));
    await page.goto('http://127.0.0.1:18765/');
    await page.locator('#wGuest').click();
    await page.evaluate(async () => {
      autoPlaySequence = () => {}; playText = () => {}; logExposure = (_word,_kind,target) => { window.testTarget=target; };
      const item = {kind:'learn', word:'apple', detail:{word:'apple',pos:1,senses:[{pos:'n',text:'苹果'}],sentences:[]}};
      session.queue = [item]; session.idx = 0;
      await showLearn(item);
    });
    await page.getByText('重新加载例句').waitFor();
    assert.equal(await page.locator('#pendingSent').count(), 0);
    fail = false;
    await page.getByText('重新加载例句').click();
    await page.getByText('Apple on table').waitFor();
    await page.locator('#bShadow').click();
    assert.equal(await page.evaluate(() => window.testTarget), 'Apple on table');
    console.log('PASS missing sentence retry and shadowing the recovered sentence');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

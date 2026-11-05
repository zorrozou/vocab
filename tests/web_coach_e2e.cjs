const assert = require('node:assert/strict');
const {chromium} = require('playwright');
(async()=>{
  const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page=await browser.newPage({viewport:{width:390,height:844}});
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto('http://127.0.0.1:18765/');
    await page.locator('#wGuest').click();
    // Simulate an unfinished lesson from the original client version.
    await page.evaluate(async()=>{
      const headers={...await personalHeaders(),'Content-Type':'application/json'},client=crypto.randomUUID();
      const post=async(path,more)=>{const r=await fetch(API+'/api/v1/coach/'+path,{method:'POST',headers,body:JSON.stringify({client,offset:-new Date().getTimezoneOffset(),...more})});if(!r.ok)throw Error('fixture seed failed');};
      await post('clock',{action:'pulse'});await post('lesson',{track:'life'});await post('clock',{action:'stop'});home();
    });
    await page.getByRole('button',{name:'接着完成上一版的课'}).click();
    await page.getByRole('button',{name:/看原文$/}).click();
    await page.getByRole('button',{name:/室内$/}).click();
    await page.getByText('一起看这条线索').waitFor();
    await page.getByRole('button',{name:/继续$/}).click();
    await page.getByText('带着线索再试',{exact:false}).waitFor();
    await page.getByRole('button',{name:/暂停并回首页$/}).click();
    await page.getByRole('button',{name:'切回经典界面'}).click();
    await page.getByRole('button',{name:'开启听读教练'}).waitFor();
    await page.reload();
    await page.getByRole('button',{name:'开启听读教练'}).click();
    await page.getByRole('button',{name:'接着完成上一版的课'}).click();
    await page.getByText('带着线索再试',{exact:false}).waitFor();
    await page.locator('#app button.opt').first().click();
    await page.getByRole('button',{name:/继续$/}).click();
    await page.getByRole('button',{name:/看原文$/}).click();
    await page.locator('#app button.opt').first().click();
    await page.getByRole('button',{name:/看本课小结$/}).click();
    await page.getByRole('heading',{name:/今日教练课完成$/}).waitFor();
    await page.getByRole('button',{name:/返回首页$/}).click();
    await page.getByRole('button',{name:'切回经典界面'}).click();
    // A slow/failing clock and a spent hour must never make a study screen inert.
    const clockDay=await page.evaluate(()=>today());
    await page.route('**/api/v1/coach/clock',async route=>{
      await new Promise(r=>setTimeout(r,6000));
      await route.fulfill({json:{day:clockDay,used:3600,limit:2400,credit:0,busy:true,extended:true,acknowledged:[]}}).catch(()=>{});
    });
    await page.locator('#bPlace').click();
    await page.getByText('用时仅作参考',{exact:false}).waitFor();
    assert.equal(await page.locator('#app').evaluate(e=>e.inert),false);
    const known=page.getByRole('button',{name:'不认识',exact:true});
    await known.waitFor();await known.click();
    assert.equal(await page.locator('#app').evaluate(e=>e.inert),false);
    await page.waitForTimeout(16000);
    assert.equal(await page.locator('#app').evaluate(e=>e.inert),false);
    assert.equal(await page.getByText('正在核对今日练习时间…',{exact:true}).count(),0);
    assert(await page.evaluate(()=>Object.keys(localStorage).some(k=>k.startsWith('vocab.study.intervals.v3.'))));
    assert.deepEqual(errors,[]);console.log('PASS mobile Web course, guided follow-up, reload, original interface, nonblocking advisory clock and durable pending time');
  }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});

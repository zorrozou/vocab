const assert = require('node:assert/strict');
const {chromium} = require('playwright');
(async()=>{
  const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page=await browser.newPage({viewport:{width:390,height:844}});
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto('http://127.0.0.1:18765/');
    await page.locator('#wGuest').click();
    await page.getByRole('button',{name:'进入今日教练课'}).click();
    await page.getByRole('button',{name:'看原文'}).click();
    await page.getByRole('button',{name:'室内',exact:true}).click();
    await page.getByText('一起看这条线索').waitFor();
    await page.getByRole('button',{name:'继续',exact:true}).click();
    await page.getByText('带着线索再试',{exact:false}).waitFor();
    await page.getByRole('button',{name:'暂停并回首页'}).click();
    await page.getByRole('button',{name:'切回经典界面'}).click();
    await page.getByRole('button',{name:'开启听读教练'}).waitFor();
    await page.reload();
    await page.getByRole('button',{name:'开启听读教练'}).click();
    await page.getByRole('button',{name:'进入今日教练课'}).click();
    await page.getByText('带着线索再试',{exact:false}).waitFor();
    await page.locator('#app button.opt').first().click();
    await page.getByRole('button',{name:'继续',exact:true}).click();
    await page.getByRole('button',{name:'看原文'}).click();
    await page.locator('#app button.opt').first().click();
    await page.getByRole('button',{name:'看本课小结'}).click();
    await page.getByRole('heading',{name:'今日教练课完成'}).waitFor();
    await page.getByRole('button',{name:'返回首页',exact:true}).click();
    await page.getByRole('button',{name:'切回经典界面'}).click();
    // Force clock boundary responses only. Navigation and input blocking use real app code.
    let extra=false;
    await page.route('**/api/v1/coach/clock',async route=>{
      const b=route.request().postDataJSON(); if(b.action==='extend')extra=true;
      await route.fulfill({json:{day:'2026-11-04',used:extra?2400:1800,limit:extra?2400:1800,credit:0,busy:false,extended:extra}});
    });
    await page.locator('#bPlace').click();
    await page.getByText('今天已练满 30 分钟，建议在这里结束。').waitFor();
    assert(await page.locator('#app').evaluate(e=>e.inert));
    await page.getByRole('button',{name:'再练最多 10 分钟'}).click();
    await page.getByText('今天已到 40 分钟，明天再继续。').waitFor();
    assert(await page.locator('#app').evaluate(e=>e.inert));
    assert.deepEqual(errors,[]);console.log('PASS mobile Web course, guided follow-up, reload, original interface, shared 30/40-minute gates');
  }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});

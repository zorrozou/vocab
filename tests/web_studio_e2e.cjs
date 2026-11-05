const assert=require('node:assert/strict');
const {chromium}=require('playwright');
const base=process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765/';
if(!['localhost','127.0.0.1'].includes(new URL(base).hostname))throw Error('Requires isolated fixture');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.VOCAB_BROWSER||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try{
   const page=await browser.newPage({viewport:{width:390,height:844}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
   const click=async name=>page.getByRole('button',{name:new RegExp(name+'$')}).click();
   await page.goto(base);await page.locator('#wGuest').click();
   // Enter directly even if model generation would be slow or unavailable.
   let prepareCalls=0;
   await page.route('**/coach/prepare',route=>{prepareCalls++;return route.abort();});
   await click('学习档案');await page.getByRole('heading',{name:'我的学习档案'}).waitFor();
   await click('我的目标');await click('职场沟通');
   await page.getByRole('button',{name:'✓ 职场沟通'}).waitFor();await page.reload();await click('今日课堂');
   await page.getByRole('heading',{name:/决定是否发送报价$/}).waitFor();await click('进入今日教练课');assert.equal(prepareCalls,0);
   await page.locator('.task-question .line-en').filter({hasText:'What should you do about the quote?'}).waitFor();
   assert.equal(await page.locator('blockquote').count(),0);assert.equal(await page.locator('button.opt:disabled').count(),3);
   assert.equal(await page.locator('.answer-choices .line-en[lang=en]').count(),3);
   await click('看原文');await click('立即更改报价');await page.getByText('一起看这条线索').waitFor();
   await click('请 AI 再讲一句');await page.locator('.clue-note .line-en').waitFor();
   await page.locator('summary').filter({hasText:'Try a short reply'}).click();await page.getByLabel('我的英文回应').fill('I will send it this afternoon.');await click('看看我的回应');
   await page.getByText('暂无法判断',{exact:true}).waitFor();await click('撤销这次选择');await click('看原文');await click('立即更改报价');
   await click('继续');await page.getByText('财务现在发来新价格了吗？').waitFor();await click('没有');
   await click('继续');await page.locator('button.opt').first().click();await click('继续');await click('看原文');await page.locator('button.opt').first().click();
   await click('看本课小结');await page.getByRole('heading',{name:/今日教练课完成$/}).waitFor();
   await click('返回首页');await click('学习档案');await page.getByRole('heading',{name:'我的学习档案'}).waitFor();
   await page.locator('.studio-line').filter({hasText:/次独立 \/ 4 次作答/}).waitFor();await click('今日课堂');await click('切回经典界面');
   await page.getByRole('button',{name:'开启听读教练'}).waitFor();assert.deepEqual(errors,[]);
   console.log('PASS course home, synced goal, choice-specific diagnostic, response fallback, undo, skills and classic switch');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});

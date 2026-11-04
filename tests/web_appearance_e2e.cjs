const assert=require('node:assert/strict');
const {chromium}=require('playwright');

(async()=>{
 const browser=await chromium.launch({executablePath:process.env.VOCAB_BROWSER || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try {
  const context=await browser.newContext({colorScheme:'light',viewport:{width:390,height:844}});
  const page=await context.newPage();
  const base=process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/';
  if(!['localhost','127.0.0.1'].includes(new URL(base).hostname)) throw Error('Use the isolated fixture');
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const theme=(p,value)=>p.waitForFunction(v=>document.documentElement.dataset.theme===v&&getComputedStyle(document.documentElement).colorScheme===v,value);
  await page.goto(base);await theme(page,'light');await page.locator('#wGuest').click();
  await page.locator('#btnSettings').click();
  const select=mode=>page.locator('[data-appearance="'+mode+'"]').click();
  assert.equal(await page.locator('[data-appearance=system]').getAttribute('aria-pressed'),'true');
  await select('dark');await theme(page,'dark');await page.reload();await theme(page,'dark');
  const other=await context.newPage();await other.goto(base);await theme(other,'dark');
  await page.locator('#btnSettings').click();await select('light');await theme(other,'light');
  await page.emulateMedia({colorScheme:'dark'});await theme(page,'light');
  await select('system');await theme(page,'dark');await theme(other,'light');
  await page.reload();await page.getByRole('button',{name:/直接使用教研课程$/}).click();
  await page.getByRole('button',{name:/看原文$/}).click();await page.locator('blockquote').waitFor();
  const choices=await page.locator('button.opt').allTextContents();
  const current=await page.locator('blockquote').elementHandle();
  for(const mode of ['light','dark']){
   await page.emulateMedia({colorScheme:mode});await theme(page,mode);
   assert(await current.evaluate(e=>e.isConnected));
   assert.deepEqual(await page.locator('button.opt').allTextContents(),choices);
   const ratios=await page.evaluate(()=>{
    function lum(rgb){return rgb.match(/[\d.]+/g).slice(0,3).map(Number).map(n=>n/255).map(s=>s<=.04045?s/12.92:((s+.055)/1.055)**2.4).reduce((v,x,i)=>v+x*[.2126,.7152,.0722][i],0);}
    function contrast(selector,bg){const a=lum(getComputedStyle(document.querySelector(selector)).color),b=lum(getComputedStyle(document.querySelector(bg)).backgroundColor);return (Math.max(a,b)+.05)/(Math.min(a,b)+.05);}
    return [contrast('blockquote','blockquote'),contrast('.task-question .line-zh','.studio-lesson'),contrast('button.opt .line-zh','button.opt'),contrast('.audio-actions .primary .line-zh','.audio-actions .primary')];
   });
   assert(ratios.every(r=>r>=4.5),mode+' text contrast '+ratios);
   if(process.env.VOCAB_APPEARANCE_SHOTS)await page.screenshot({path:process.env.VOCAB_APPEARANCE_SHOTS+'/lesson-'+mode+'.png'});
  }
  await page.locator('button.opt:not(:disabled)').first().click();await page.locator('.answer-evidence').waitFor();assert.deepEqual(errors,[]);
  console.log('PASS default system mode, live scheme change, manual overrides, persistence, tab synchronization, unchanged active question and bilingual contrast');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});

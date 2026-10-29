const {chromium} = require('playwright');
const assert = require('assert');
const base = process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/';
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:process.env.VOCAB_BROWSER});
  try {
    for (const width of [320, 390, 1280]) {
      const page = await browser.newPage({viewport:{width,height:900}});
      await page.goto(base); await page.locator('#wGuest').click();
      await page.evaluate(async () => {
        autoPlaySequence = () => {};
        const word = 'internationalization';
        const item = {kind:'learn',word,detail:{word,pos:500,senses:[{text:'国际化'}],sentences:[
          {tier:1,text:'A short example.'}, {tier:2,text:'Another example to read.',zh:'这是另一条例句。'},
          {tier:3,text:'This sentence is intentionally longer to verify that the text and action buttons stay within the card.'}]}};
        session.queue=[item]; session.idx=0; await showLearn(item);
      });
      const layout = await page.evaluate(() => ({
        overflow:document.documentElement.scrollWidth > innerWidth,
        actions:[...document.querySelectorAll('.study-actions .act')].map(button=>{
          const r=button.getBoundingClientRect(); return {width:r.width,height:r.height};
        }),
        targets:[...document.querySelectorAll('.plays,.playw')].map(button => {
          const b=button.getBoundingClientRect(), parent=button.closest('.sent')?.getBoundingClientRect();
          return {width:b.width,height:b.height,inside:!parent || (b.top>=parent.top && b.bottom<=parent.bottom)};
        })
      }));
      assert(!layout.overflow, `horizontal overflow at ${width}px`);
      assert(layout.actions.every(a=>a.width>=80 && a.height<80), `study actions collapsed into vertical text at ${width}px`);
      assert(layout.targets.every(t=>t.width>=44 && t.height>=44 && t.inside), `small or overlapping sentence actions at ${width}px`);
      await page.locator('.plays:not(.bad)').first().click();
      if (process.env.VOCAB_LAYOUT_SCREENSHOTS) await page.screenshot({path:`${process.env.VOCAB_LAYOUT_SCREENSHOTS}/study-${width}.png`,fullPage:true});
      await page.close();
    }
    console.log('PASS long words and reachable sentence controls at phone and desktop widths');
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exit(1)});

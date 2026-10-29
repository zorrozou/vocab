const {chromium}=require('playwright');
const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  for(const [timezone,expected] of [['Pacific/Kiritimati',[2,2]],['America/Los_Angeles',[3,1]]]){
   const context=await browser.newContext({timezoneId:timezone});const page=await context.newPage();
   await page.goto(base);
   const values=await page.evaluate(()=>{
    const NativeDate=Date;
    window.Date=class extends NativeDate {constructor(...args){super(...(args.length?args:['2026-03-08T08:30:00Z']));} static now(){return NativeDate.parse('2026-03-08T08:30:00Z');}};
    S.cards={a:{due:'2026-03-08T07:30:00Z'},b:{due:'2026-03-09T00:30:00Z'},c:{due:'2026-03-08'},d:{due:'2026-03-08T23:00:00-08:00'},invalid:{due:'2026-02-29'},later:{due:'2026-04-01'},mastered:{stage:6,due:'2026-03-08'}};
    S.log=[];showStats();return [...document.querySelectorAll('#app [title]')].map(e=>e.getAttribute('title'));
   });
   assert.equal(values.length,14);assert.equal(values[0],`2026-03-08: ${expected[0]}词`);assert.equal(values[1],`2026-03-09: ${expected[1]}词`);
   await context.close();
  }
  console.log('PASS browser forecast renders local dates across UTC+14 and DST');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

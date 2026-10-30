const {chromium}=require('playwright');const assert=require('assert');
const base=(process.env.VOCAB_TEST_BASE||'http://127.0.0.1:18765').replace(/\/$/,'');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER?{executablePath:process.env.VOCAB_BROWSER}:{})});
 try{
  const page=await browser.newPage();await page.goto(base);
  const result=await page.evaluate(()=>{
   const NativeDate=Date;window.Date=class extends NativeDate {constructor(...args){super(...(args.length?args:['2026-10-28T12:00:00Z']));}static now(){return NativeDate.parse('2026-10-28T12:00:00Z');}};
   const c=(stability,lastReview)=>({fsrs:{state:2,stability,difficulty:5,...(lastReview===undefined?{}:{lastReview})}});
   S.cards={exact:c(10,'2026-10-08T12:00:00Z'),legacy:c(10),missing:c(10),pending:{...c(10,'2026-10-08T12:00:00Z'),pendingFsrs:{events:[{id:'test'}]}}};
   S.log=[{d:'2026-10-08',word:'legacy',rating:3,kind:'review'},{d:'2026-10-28',word:'legacy',rating:3,kind:'exposure'}];showStats();
   return {bins:[...document.querySelectorAll('[data-retention-index]')].map(e=>Number(e.lastElementChild.textContent)),note:document.querySelector('#retention-note').textContent};
  });
  assert.deepEqual(result.bins,[0,0,2,0,0]);assert(result.note.includes('2 词使用日期或参数近似')&&result.note.includes('2 词缺少可用信息'));
  console.log('PASS browser retention display uses review time, labels approximations and pending data');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});

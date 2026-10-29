const {chromium} = require('playwright');
const assert = require('assert');
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:process.env.VOCAB_BROWSER});
  try {
    const page = await browser.newPage();
    await page.goto(process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765/');
    const result = await page.evaluate(async () => {
      const r = await fetch('/api/v1/sentence/alternatives?word=apple&tier=1');
      return {status:r.status, body:await r.json()};
    });
    assert.equal(result.status, 200);
    assert.equal(result.body.word, 'apple');
    const candidates = [...new Set(result.body.sentences.map(s => s.text))];
    assert(candidates.length >= 2, 'fixture lexicon should provide two real alternatives');
    assert(result.body.sentences.every(s => s.tier === 1));
    await page.locator('#wGuest').click();
    await page.evaluate(async first => {
      autoPlaySequence = () => {};
      const item = {kind:'learn',word:'apple',detail:{word:'apple',pos:1,senses:[{text:'苹果'}],sentences:[{tier:1,text:first},{tier:2,text:'Another visible example'},{tier:3,text:'A third example'}]}};
      session.queue = [item]; session.idx = 0; await showLearn(item);
    }, candidates[0]);
    await page.locator('.bad[data-kind="static"]').first().click();
    await page.getByText(candidates[1], {exact:false}).waitFor();
    assert.equal(await page.locator('#app .sent').count(), 3);
    const unknown = await page.evaluate(async () => (await fetch('/api/v1/sentence/alternatives?word=notawordxyz&tier=1')).json());
    assert.deepEqual(unknown.sentences, []);
    const invalid = await page.evaluate(async () => (await fetch('/api/v1/sentence/alternatives?word=apple&tier=4')).status);
    assert.equal(invalid, 422);
    console.log('PASS real lexicon alternative selection, tier and validation');
  } finally { await browser.close(); }
})().catch(e => {console.error(e); process.exit(1);});

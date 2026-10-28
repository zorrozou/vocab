const {chromium} = require('playwright');
const assert = require('assert');
(async () => {
  const browser = await chromium.launch({headless: true, executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page = await browser.newPage();
    await page.goto(process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18767/', {waitUntil: 'domcontentloaded'});
    const result = await page.evaluate(async () => {
      const bad = `"><img src=x onerror="window.__injected=1"> & 'quoted'`;
      window.__injected = 0;
      S = defaultState();
      AUTH = {userId: 7, username: 'test', nickname: bad, token: 'test'};
      renderUserTag();
      await userMenu();
      const nicknameText = document.querySelector('#app h2').textContent;
      const headerText = document.querySelector('#userTag').textContent;
      const nickImages = document.querySelectorAll('#app img').length;
      S.personalized[bad] = {text: bad, zh: bad};
      const word = {word: bad, pos: 10, senses: [{pos: bad, text: bad}], sentences: [{tier: 1, text: bad, zh: bad}]};
      session = {queue: [{kind: 'learn', word: bad, detail: word}], idx: 0, learnedToday: 0, reviewedToday: 0};
      autoPlaySequence = () => {};
      await showLearn(session.queue[0]);
      const text = document.querySelector('.big').textContent;
      const dataset = document.querySelector('.playw').dataset.t;
      const sentenceData = document.querySelector('.sent .plays').dataset.t;
      const sense = document.querySelector('.sense').textContent;
      const images = document.querySelectorAll('#app img').length;
      await new Promise(resolve => setTimeout(resolve, 50));
      return {bad, nicknameText, headerText, nickImages, text, dataset, sentenceData, sense, images, injected: window.__injected};
    });
    assert.equal(result.nicknameText, result.bad);
    assert(result.headerText.includes(result.bad));
    assert.equal(result.nickImages, 0);
    assert.equal(result.text, result.bad);
    assert.equal(result.dataset, result.bad);
    assert.equal(result.sentenceData, result.bad);
    assert(result.sense.includes(result.bad));
    assert.equal(result.images, 0);
    assert.equal(result.injected, 0);
    console.log('PASS browser escapes nickname, word, sense, sentence and attribute content');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

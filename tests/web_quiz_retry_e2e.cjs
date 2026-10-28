const {chromium} = require('playwright');
const assert = require('assert');
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page = await browser.newPage();
    let fail = true;
    await page.route('**/api/v1/quiz?**', route => route.fulfill({contentType:'application/json', body:JSON.stringify(fail ? {options:[]} : {options:[{text:'a',ok:true},{text:'b',ok:false},{text:'c',ok:false},{text:'d',ok:false}]})}));
    await page.route('**/api/v1/tts?**', route => route.fulfill({status:503,body:'offline'}));
    await page.goto('http://127.0.0.1:18765/', {waitUntil:'domcontentloaded'});
    await page.locator('#wGuest').click();
    await page.evaluate(() => { S.cards.apple = {pos:1}; review = async () => {}; quizRound(['apple'],0); });
    await page.locator('#bQuizRetry').waitFor();
    assert.notEqual(await page.evaluate(() => S.quizDay), await page.evaluate(() => today()));
    fail = false;
    await page.locator('#bQuizRetry').click();
    await page.locator('.opt').first().click();
    await page.waitForFunction(() => S.quizDay === today());
    fail = true;
    await page.evaluate(() => { S.quizDay = null; quizRound(['apple'],0); });
    await page.locator('#bQuizLater').click();
    assert.notEqual(await page.evaluate(() => S.quizDay), await page.evaluate(() => today()));
    // A partially completed quiz resumes at the next word, even after navigating away.
    fail = false;
    await page.evaluate(() => {
      S.quizDay = null; S.quizProgressDay = null; S.quizCompleted = [];
      S.cards.banana = {pos:2};
      S.log.push({d:today(), word:'apple', kind:'learn'}, {d:today(), word:'banana', kind:'learn'});
      maybeQuiz();
    });
    await page.locator('.opt').first().click();
    await page.waitForFunction(() => (S.quizCompleted || []).includes('apple'));
    fail = true;
    await page.locator('#bQuizLater').click();
    await page.evaluate(() => maybeQuiz());
    await page.locator('#bQuizRetry').waitFor();
    assert.equal(await page.evaluate(() => S.quizCompleted.join(',')), 'apple');
    fail = false;
    await page.locator('#bQuizRetry').click();
    assert.equal(await page.locator('.big').first().innerText(), 'banana');
    await page.locator('.opt').first().click();
    await page.waitForFunction(() => S.quizDay === today());
    // A new word learned after completion must still be tested.
    await page.evaluate(() => { S.cards.cherry = {pos:3}; S.log.push({d:today(), word:'cherry', kind:'learn'}); maybeQuiz(); });
    await page.locator('.opt').first().waitFor();
    assert.equal(await page.locator('.big').first().innerText(), 'cherry');
    console.log('PASS acceptance retry, defer, resume and additional same-day words');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

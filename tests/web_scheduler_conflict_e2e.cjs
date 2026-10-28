const {chromium} = require('playwright');
const fs = require('fs');
const assert = require('assert');
(async () => {
  const fixture = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const browser = await chromium.launch({headless:true, executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page = await browser.newPage();
    await page.goto('http://127.0.0.1:18765/');
    const out = await page.evaluate(async ({token,state,accountId}) => {
      AUTH = {userId:1, accountId,username:'test',token}; S = state;
      S.cards.apple.pendingFsrs.events[0].schedulerKey = 'outdated';
      const original = JSON.stringify(S.cards.apple.pendingFsrs);
      const ok = await replayPendingFsrs(S.cards.apple);
      showSettings();
      return {ok, original, pending:JSON.stringify(S.cards.apple.pendingFsrs), warning:fsrsReplayWarning, text:document.querySelector('#app').textContent};
    }, fixture);
    assert.equal(out.ok,false);
    assert.equal(out.pending,out.original);
    assert(out.warning.includes('FSRS 参数版本不可用'));
    assert(out.text.includes('请先导出进度'));
    console.log('PASS changed scheduler preserves pending history and shows an actionable warning');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

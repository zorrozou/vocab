const {chromium} = require('playwright');
const assert = require('assert');
const fs = require('fs');
(async () => {
  const fixture = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const browser = await chromium.launch({headless:true, executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page = await browser.newPage();
    await page.goto('http://127.0.0.1:18765/');
    const result = await page.evaluate(async ({token,state,accountId}) => {
      AUTH = {userId:1, accountId, username:'test', token};
      S = state;
      const card = S.cards.apple;
      if (!await replayPendingFsrs(card)) throw Error('history replay failed');
      const response = await fetch(API + '/api/v1/me/state', {method:'PUT',headers:{'Content-Type':'application/json',...authHeaders()},body:JSON.stringify(S)});
      if (!response.ok) throw Error('merged state write: ' + response.status + ' ' + await response.text());
      const saved = await (await fetch(API + '/api/v1/me/state',{headers:authHeaders()})).json();
      return {card, saved:saved.state.cards.apple, schedulers:S.fsrsSchedulers, savedSchedulers:saved.state.fsrsSchedulers};
    }, fixture);
    const expected = fixture.expected;
    for (const k of ['state','stability','difficulty','due','step']) assert.equal(result.card.fsrs[k], expected[k]);
    assert.equal(result.card.fsrs.lastReview,expected.last_review);
    assert.deepEqual(result.card.fsrsHistory.events.map(e => e.schedulerKey), fixture.state.cards.apple.pendingFsrs.events.map(e => e.schedulerKey));
    assert.deepEqual(new Set(result.saved.appliedFsrs),new Set(['device-a-1','device-b-1']));
    assert.equal(result.saved.pendingFsrs,undefined);
    assert.equal(result.saved.fsrsHistory.events.length,2);
    for (const e of result.saved.fsrsHistory.events) assert.equal(result.saved.fsrsReplayVersions[e.id], e.schedulerKey);
    for (const e of fixture.state.cards.apple.pendingFsrs.events) {
      assert(result.schedulers[e.schedulerKey], 'Web must preserve each scheduler snapshot in the backup state');
      assert(result.savedSchedulers[e.schedulerKey], 'server must retain each scheduler snapshot');
    }
    console.log('PASS Web replays merged HTTP history and commits it once');
  } finally { await browser.close(); }
})().catch(e => {console.error(e);process.exit(1);});

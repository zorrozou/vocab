const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const html = fs.readFileSync('web/index.html', 'utf8');
const fsrsCall = html.slice(html.indexOf('async function fsrsCall('), html.indexOf('const fsrsDue ='));
const provisional=html.slice(html.indexOf('function provisionalSchedule('),html.indexOf('// 服务端调度是无状态计算'));
const replay = html.slice(html.indexOf('async function replayPendingFsrs('), html.indexOf('/* 该词上一次学习'));
const learn = html.slice(html.indexOf('// Validate again at grading time'), html.indexOf('/* ---------------- 定级（'));
let request, online = true;
const timestamp = '2026-10-27T03:14:43+00:00';
const context = { AUTH: null, localSaveFailed:false, session:{voluntary:true},
  API: '', authHeaders: () => ({Authorization: 'Bearer test'}),
  fetch: async (_url, options) => {
    request = JSON.parse(options.body);
    assert.equal(options.headers.Authorization, 'Bearer test');
    if (!online) throw Error('offline');
    return {ok: true, json: async () => ({state: 2, stability: 5, difficulty: 3,
      due: '2026-10-30T00:00:00Z', last_review: timestamp})};
  },
  S: {cards: {apple: {pos: 1, fsrs: {state: 2, stability: 4, difficulty: 3,
    due: '2026-10-26T00:00:00Z', last_review: '2026-10-24T00:00:00Z'}}},
    log: [], pendingNew: [], pointer: 1, calibrated: false, settings:{dailyCap:100,newPerDay:10}},
  lastReviewDate: () => null, recordKnowledge: () => {}, tomorrow: () => '',
  LEGACY_STAB: {}, fsrsDue: x => x,
  today: () => '2026-10-27', addDays: () => '', Date, Number, Math,
  crypto: require('crypto').webcrypto, Uint8Array, structuredClone, save: () => {}, window: {addEventListener: () => {}}
};
vm.createContext(context);
vm.runInContext(provisional + '\n' + fsrsCall + '\n' + replay + '\n' + learn, context);
(async () => {
  await context.review('apple', 3);
  assert.equal(request.last_review, '2026-10-24T00:00:00Z');
  assert.equal(context.S.cards.apple.fsrs.lastReview, timestamp);
  assert.equal(context.S.cards.apple.fsrs.last_review, undefined);
  await context.review('apple', 3);
  assert.equal(request.last_review, timestamp);
  online = false;
  await context.review('apple', 1);
  await context.review('apple', 3);
  const pending = JSON.parse(JSON.stringify(context.S.cards.apple.pendingFsrs));
  assert.equal(pending.events.length, 2);
  assert.deepEqual(pending.events.map(e => e.rating), [1, 3]);
  assert.equal(pending.base.last_review, timestamp);
  online = true;
  assert.equal(await context.replayPendingFsrs(context.S.cards.apple), true);
  assert.equal(context.S.cards.apple.pendingFsrs, undefined);
  assert.equal(request.rating, 3);
  assert.equal(request.now, pending.events[1].at);
  assert.equal(request.deterministic, true);
  online = false;
  await context.review('apple', 1);
  online = true;
  const outcomes = await Promise.all([
    context.replayPendingFsrs(context.S.cards.apple),
    context.replayPendingFsrs(context.S.cards.apple)
  ]);
  assert(outcomes.includes(true));
  assert.equal(context.S.cards.apple.pendingFsrs, undefined);
  assert.equal(context.S.cards.apple.fsrsHistory.events.length, 5);
  assert.equal(new Set(context.S.cards.apple.fsrsHistory.events.map(e => e.id)).size, 5);
  console.log('PASS Web FSRS legacy read, API mapping and next request');
})().catch(e => { console.error(e); process.exit(1); });

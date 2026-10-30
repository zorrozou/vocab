const fs = require('fs'), vm = require('vm'), assert = require('assert');
const html = fs.readFileSync('web/index.html', 'utf8');
const fsrsCall = html.slice(html.indexOf('async function fsrsCall('), html.indexOf('const fsrsDue ='));
const provisional=html.slice(html.indexOf('function provisionalSchedule('),html.indexOf('// 服务端调度是无状态计算'));
const mastery=html.slice(html.indexOf('function legacyMastered('),html.indexOf('/* ---------------- 定级'));
const replay = html.slice(html.indexOf('async function replayPendingFsrs('), html.indexOf('/* 该词上一次学习'));
let offline = true, persisted;
const ctx = {today:()=>new Date().toISOString().slice(0,10), AUTH: null, localSaveFailed: false, API: process.env.VOCAB_TEST_BASE || 'http://127.0.0.1:18765', authHeaders: () => ({}),
  fetch: (url, opts) => offline ? Promise.reject(Error('offline')) : fetch(url, opts),
  crypto: require('crypto').webcrypto, Uint8Array, Date, Number, Math, structuredClone, window: {addEventListener: () => {}},
  save: () => { persisted = JSON.stringify(ctx.S); },
  S: {cards: {apple: {stage: 1, due: '2026-10-28', pos: 1}}}
};
vm.createContext(ctx); vm.runInContext(mastery + '\n' + provisional + '\n' + fsrsCall + '\n' + replay, ctx);
(async () => {
  let card = ctx.S.cards.apple;
  await ctx.scheduleFsrs(card, {is_new: true, rating: 3}, 3);
  await ctx.scheduleFsrs(card, {is_new: false, rating: 1}, 1);
  const events = card.pendingFsrs.events;
  assert.equal(events.length, 2);
  assert.equal(JSON.parse(persisted).cards.apple.pendingFsrs.events.length, 2);
  ctx.S = JSON.parse(persisted); card = ctx.S.cards.apple; offline = false;
  assert.equal(await ctx.replayPendingFsrs(card), true);
  assert.equal(card.pendingFsrs, undefined);
  assert.equal(card.appliedFsrs.length, 2);
  assert.equal(Date.parse(card.fsrs.lastReview), Date.parse(events[1].at));
  assert.equal(card.fsrs.state, 1); // Again while learning
  console.log('PASS Web offline ratings survive reload and replay against the API');
})().catch(e => { console.error(e); process.exit(1); });

const fs = require('fs'), vm = require('vm'), assert = require('assert');
const html = fs.readFileSync('web/index.html', 'utf8');
const saveCode = html.slice(html.indexOf('const save = () =>'), html.indexOf('let session ='));
const admissionCode = html.slice(html.indexOf('// Validate again at grading time'), html.indexOf('async function learn('));
const reviewCode = html.slice(html.indexOf('let undoSnapshot ='), html.indexOf('const isMastered ='));
const syncCode = html.slice(html.indexOf('async function syncFromServer('), html.indexOf('function renderUserTag()'));
const scheduled = new Map(); let nextTimer = 0, pushes = 0;
let failWrites = false, pulls = 0;
const values = {};
values['vocab_daily_plan_v1:'+'a'.repeat(32)] = JSON.stringify({account_id:'a'.repeat(32),day:'2026-10-27',cap:100,new_target:10,
  configured_cap:100,configured_new_per_day:10,approved:[],requires_sync:false,over_limit:false,
  items:[{word:'apple',kind:'review',new_word:false,probe_word:false,completed:false,from_pending:false}]});
const ctx = {
  AUTH: {userId: 1, accountId:'a'.repeat(32)}, S: {cards: {apple: {pos: 1, fsrs: {state: 2, stability: 5, difficulty: 4,
    due: '2026-10-28', lastReview: '2026-10-20T00:00:00Z'}}}, log: [], knowledge: {}, posterior: [1],
    probeCount: 0, track: null, calibrated: false, settings:{dailyCap:100,newPerDay:10}},
  session: {reviewedToday: 0}, largeActive:null, normalActive:null, observedSlotValues:new Map(), deltaBlockedSlots:new Set(), deltaConcurrentSlots:new Set(),
  normalTransitionMarker:slot=>`${slot}:normal-transition`, awaitingServerSlot:slot=>`${slot}:awaiting-server`, deltaRecoveryBlock:slot=>`${slot}:delta-recovery-block`,
  $:()=>({firstElementChild:null}), structuredClone, Date, Math, crypto: require("crypto").webcrypto,
  accountSlot: () => 'slot', slotClock: (slot,name) => `${slot}:${name}`,
  writeSlotAndMain: (_slot,state) => ctx.localStorage.setItem('vocab_v1',JSON.stringify(state)),
  localStorage: {setItem: (k, v) => { if (failWrites) throw Error('quota'); values[k] = v; }, getItem: k => values[k] || null},
  setTimeout: fn => { const id = ++nextTimer; scheduled.set(id, fn); return id; },
  clearTimeout: id => scheduled.delete(id),
  pushState: () => { pushes++; }, pullState: () => { pulls++; }, renderUserTag: () => {},
  today: () => '2026-10-27', lastReviewDate: () => null,
  recordKnowledge: (word, pos, ok) => { ctx.S.knowledge[word] = {a: ok ? 1 : 0, b: ok ? 0 : 1}; ctx.S.knowledgeEvidence = {[word]:{events:{newEvent:{ok}}}}; },
  scheduleFsrs: async c => { c.due = '2026-10-28'; vm.runInContext('save()', ctx); },
  LEGACY_STAB: {}, fsrsDue: x => x
};
vm.createContext(ctx); vm.runInContext(saveCode + '\n' + admissionCode + '\n' + reviewCode + '\n' + syncCode, ctx);
const fireTimers = () => { for (const f of scheduled.values()) f(); scheduled.clear(); };
(async () => {
  await ctx.review('apple', 1, true);
  assert.equal(ctx.S.log.length, 1);
  assert.equal(scheduled.size, 0, 'undoable rating must not reach server before decision');
  assert.equal(JSON.parse(values.vocab_v1).log.length, 1, 'rating still persisted locally');
  ctx.session.reviewedToday++;
  ctx.undoReview();
  assert.equal(ctx.S.log.length, 0);
  assert.equal(ctx.S.knowledge.apple, undefined);
  assert.equal(ctx.S.knowledgeEvidence, undefined, 'undo must remove uncommitted evidence events');
  fireTimers(); assert.equal(pushes, 1);
  await ctx.review('apple', 1, true);
  ctx.commitUndoReview(); fireTimers(); assert.equal(pushes, 2);
  await ctx.review('apple', 1); // acceptance review has no undo UI
  fireTimers(); assert.equal(pushes, 3);
  failWrites = true;
  vm.runInContext('save()', ctx);
  assert.equal(ctx.localSaveFailed, true);
  assert.equal(await ctx.syncFromServer(), false);
  assert.equal(pulls, 0, 'local write failure must not replace in-memory state with remote data');
  failWrites = false;
  vm.runInContext('save()', ctx);
  assert.equal(ctx.localSaveFailed, false);
  console.log('PASS undoable review stays local until undo or commit; acceptance still syncs');
})().catch(e => { console.error(e); process.exit(1); });

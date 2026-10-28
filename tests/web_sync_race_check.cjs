const fs = require('fs'), vm = require('vm'), assert = require('assert');
const html = fs.readFileSync('web/index.html', 'utf8');
const sync = html.slice(html.indexOf('async function pushState('), html.indexOf('function renderUserTag()'));
const data = {vocab_write_ts: '1', vocab_last_sync_ts: '0'};
let request, resolveFetch, failStorage = false;
const appNode = {};
const nextRequest = async previous => { for (let i=0;i<100;i++) { if (request !== previous) return; await new Promise(resolve=>setImmediate(resolve)); } throw Error('request did not start'); };
const ctx = {
  AUTH: {userId: 7, accountId:'a'.repeat(32), username:'alice', token: 'x'}, S: {cards: {apple: {pos: 1}}}, undoSnapshot: null,
  localSaveFailed: false, syncFailed: false, syncFailureMessage:'', largeActive:null, normalActive:null, API: '',
  $: () => ({firstElementChild:appNode}),
  normalTransitionMarker: slot => `${slot}:normal-transition`, awaitingServerSlot: slot => `${slot}:awaiting-server`,
  deltaMarker: slot => `${slot}:delta-v1`, deltaRecoveryBlock: slot => `${slot}:delta-recovery-block`,
  deltaBlockedSlots:new Set(), deltaSlotMatchesMemory:()=>true, deltaSupported:()=>false,
  deltaPull:async()=>null, deltaSession:(owner,token,slot)=>!!ctx.AUTH && ctx.AUTH.userId===owner && ctx.AUTH.token===token && ctx.accountSlot(ctx.AUTH)===slot,
  authHeaders: () => ({Authorization: 'Bearer x'}), defaultState: () => ({cards: {}}),
  accountSlot: a => a ? `slot:${a.userId}:${a.username || ''}` : 'guest',
  slotClock: (slot, name) => `${slot}:${name}`,
  markSlotSynced: () => { data.vocab_last_sync_ts = data.vocab_write_ts || '0'; },
  writeSlotAndMain: (_slot, state) => ctx.localStorage.setItem('vocab_v1', JSON.stringify(state)),
  localStorage: {getItem: k => data[k] || null, setItem: (k, v) => { if (failStorage) throw Error('quota'); data[k] = v; }},
  renderUserTag: () => {}, handleSyncError: () => { throw Error('unexpected error'); },
  fetch: (url, opts) => { request = {url, opts}; return new Promise(resolve => { resolveFetch = resolve; }); },
  JSON, Date
};
vm.createContext(ctx); vm.runInContext(sync, ctx);
const response = payload => ({ok: true, json: async () => payload});
(async () => {
  const upload = ctx.pushState();
  assert.equal(request.opts.method, 'PUT');
  ctx.S.cards.banana = {pos: 2}; data.vocab_write_ts = '2';
  resolveFetch(response({ok: true})); assert.equal(await upload, false);
  assert.equal(data.vocab_last_sync_ts, '0', 'stale upload must not mark later edits as synced');

  data.vocab_last_sync_ts = '2';
  const beforePull = request, pull = ctx.syncFromServer();
  await nextRequest(beforePull);
  assert.equal(request.url, '/api/v1/me/state');
  ctx.S.cards.cherry = {pos: 3}; data.vocab_write_ts = '3';
  resolveFetch(response({state: {cards: {apple: {pos: 1}}}}));
  assert.equal(await pull, false);
  assert(ctx.S.cards.cherry, 'new edits made during pull must survive');

  data.vocab_last_sync_ts = '3';
  const beforeFailedSave = request, failedSave = ctx.syncFromServer();
  await nextRequest(beforeFailedSave);
  failStorage = true;
  resolveFetch(response({state: {cards: {remote: {pos: 4}}}}));
  assert.equal(await failedSave, false);
  assert(ctx.S.cards.cherry && !ctx.S.cards.remote);
  assert.equal(ctx.localSaveFailed, true);
  ctx.localSaveFailed = false;
  let message = '';
  ctx.handleSyncError = e => { message = e.message; };
  ctx.fetch = async () => ({ok:false, status:409, json:async () => ({detail:'学习进度已恢复，请重新加载'})});
  assert.equal(await ctx.pushState(), false);
  assert(message.includes('409') && message.includes('重新加载'));
  let resolveOld; ctx.fetch = () => new Promise(resolve => { resolveOld = resolve; });
  const oldUpload = ctx.pushState();
  ctx.AUTH = {userId:7, accountId:'a'.repeat(32), username:'bob', token:'new'};
  resolveOld({ok:false, status:401, json:async () => ({detail:'未登录'})});
  message = '';
  assert.equal(await oldUpload, false);
  assert.equal(message, '', 'a stale request must not log out another account with the same numeric ID');
  ctx.AUTH = {userId:7, accountId:'a'.repeat(32), username:'alice', token:'older'};
  const oldTokenUpload = ctx.pushState();
  ctx.AUTH = {userId:7, accountId:'a'.repeat(32), username:'alice', token:'newer'};
  resolveOld({ok:false, status:401, json:async () => ({detail:'未登录'})});
  message = '';
  assert.equal(await oldTokenUpload, false);
  assert.equal(message, '', 'an expired previous token must not log out the refreshed session');
  console.log('PASS stale upload, concurrent pull and local storage failure preserve newer state');
})().catch(e => { console.error(e); process.exit(1); });

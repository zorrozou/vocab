const fs = require('fs'), vm = require('vm'), assert = require('assert');
const html = fs.readFileSync('web/index.html','utf8');
const fsrsCall = html.slice(html.indexOf('let fsrsReplayWarning ='), html.indexOf('const fsrsDue ='));
const replay = html.slice(html.indexOf('async function replayPendingFsrs('), html.indexOf('/* 该词上一次学习'));
const requests = [];
const ctx = { AUTH: null, localSaveFailed:false, S:{}, API:'', authHeaders:()=>({}), structuredClone, Date, Math, Number, Map, Set, Uint8Array,
  crypto:require('crypto').webcrypto, save:()=>{}, window:{addEventListener:()=>{}},
  fetch:async (_url, options)=>{
    const body = JSON.parse(options.body); requests.push(body.scheduler_key);
    return {ok:true,json:async()=>({state:2,stability:5,difficulty:4,due:'2026-10-28T00:00:00Z',last_review:body.now,scheduler_key:body.scheduler_key || 'new-version'})};
  }
};
vm.createContext(ctx); vm.runInContext(fsrsCall + '\n' + replay, ctx);
(async()=>{
  const old = {id:'old',rating:3,at:'2026-10-20T00:00:00Z',schedulerKey:'old-version'};
  const card = {fsrsHistory:{base:{is_new:true},events:[old],schedulerKey:'old-version'},appliedFsrs:['old']};
  await ctx.scheduleFsrs(card,{state:2,stability:5,difficulty:4,due:'2026-10-28T00:00:00Z'},3);
  assert.equal(requests[0],null, 'new event must use the current scheduler');
  assert.equal(card.fsrsHistory.events[1].schedulerKey,'new-version');
  requests.length=0;
  card.pendingFsrs = {base:{is_new:true},events:structuredClone(card.fsrsHistory.events)};
  assert(await ctx.replayPendingFsrs(card));
  assert.deepEqual(requests,['old-version','new-version']);
  console.log('PASS Web records per-event scheduler versions and replays across upgrades');
})().catch(e=>{console.error(e);process.exit(1);});

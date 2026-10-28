const fs = require('fs'), vm = require('vm'), assert = require('assert');
const html = fs.readFileSync('web/index.html','utf8');
const code = html.slice(html.indexOf('let fsrsReplayWarning ='), html.indexOf('/* 该词上一次学习'));
let release, entered, calls = [], renders = 0, responseMode = 'ok';
const ctx = {
  AUTH: {userId:1,accountId:'a'.repeat(32),token:'old'},
  API: '', authHeaders: () => ({Authorization:'Bearer '+ctx.AUTH.token}),
  fetch: async (_url, options) => {
    calls.push(options.headers.Authorization);
    if (responseMode === 'conflict-body') return {ok:false,status:409,json:async()=>{
      entered(); await new Promise(resolve => { release=resolve; }); return {detail:'old account conflict'};
    }};
    entered(); await new Promise(resolve => { release=resolve; });
    if (responseMode === 'conflict') return {ok:false,status:409,json:async()=>({detail:'old account conflict'})};
    return {ok:true,json:async()=>({state:2,stability:5,difficulty:3,due:'2026-10-30T00:00:00Z',last_review:'2026-10-27T00:00:00Z'})};
  },
  renderUserTag: () => {renders++;},
  S: {cards:{apple:{pendingFsrs:{base:{state:2,stability:4,difficulty:3},events:[
    {id:'a',rating:3,at:'2026-10-27T00:00:00Z'},{id:'b',rating:3,at:'2026-10-27T00:00:01Z'}]}}}},
  structuredClone, Date, Number, Math, Set, Map, JSON, window:{addEventListener:()=>{}},
  save:()=>{}, tomorrow:()=>'', today:()=>'', addDays:()=>'', crypto:require('crypto').webcrypto, Uint8Array
};
vm.createContext(ctx); vm.runInContext(code,ctx);
(async()=>{
  for (const mode of ['ok','conflict','conflict-body']) {
    responseMode=mode; calls=[]; renders=0;
    ctx.AUTH={userId:1,accountId:'a'.repeat(32),token:'old'};
    vm.runInContext('fsrsReplayWarning=""',ctx);
    let start; const started=new Promise(r=>start=r); entered=start;
    const card=ctx.S.cards.apple, before=JSON.stringify(card.pendingFsrs);
    const replay=ctx.replayPendingFsrs(card); await started;
    // Keep the same state object to exercise the token/session guard independently.
    ctx.AUTH={userId:1,accountId:'a'.repeat(32),token:'new'};
    release(); assert.equal(await replay,false);
    assert.deepEqual(calls,['Bearer old']);
    assert.equal(JSON.stringify(card.pendingFsrs),before);
    assert.equal(vm.runInContext('fsrsReplayWarning',ctx),''); assert.equal(renders,0);
  }
  console.log('PASS old Web FSRS responses do not send later events or warnings under a new session');
})().catch(error=>{console.error(error);process.exit(1)});

const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync('web/index.html','utf8');
const source=html.slice(html.indexOf('const addDays = '),html.indexOf('const INTERVAL ='));
const ctx={};vm.createContext(ctx);vm.runInContext(source+'\nthis.retentionSummary = retentionSummary;',ctx);
const card=(stability,lastReview)=>({fsrs:{stability,...(lastReview===undefined?{}:{lastReview})}});
const cards={exact:card(10,'2026-10-08T12:00:00Z'),legacy:card(10),small:card(0.1,'2026-10-27T12:00:00Z'),missing:card(10),future:card(10,'2026-10-29T12:00:00Z'),invalid:card(10,'2026-02-29T12:00:00Z'),pending:{...card(10,'2026-10-08T12:00:00Z'),pendingFsrs:{events:[{id:'test'}]}},untracked:{stage:1}};
const log=[{d:'2026-10-08',word:'legacy',rating:3,kind:'review'},{d:'2026-10-05',word:'legacy',rating:3,kind:'learn'},{d:'2026-10-28',word:'legacy',rating:3,kind:'exposure'}];
const result=ctx.retentionSummary(cards,log,Date.parse('2026-10-28T12:00:00Z'));
assert.deepEqual(Array.from(result.counts),[0,0,2,1,0]);assert.equal(result.approximate,3);assert.equal(result.unknown,5);
const old=ctx.retentionSummary({old:{fsrs:{stability:10,last_review:'2026-10-08T12:00:00Z'}}},[],Date.parse('2026-10-28T12:00:00Z'));
assert.deepEqual(Array.from(old.counts),[0,0,1,0,0]);
const custom={parameters:Array(20).fill(1).concat([1])};
const versioned=ctx.retentionSummary({w:{...card(1,'2026-10-08T12:00:00Z'),schedulerKey:'custom'}},[],Date.parse('2026-10-28T12:00:00Z'),{custom});
assert.equal(versioned.approximate,0);assert.equal(versioned.counts[4],1);
const tiny=ctx.retentionSummary({w:{...card(.01,'2026-10-27T12:00:00Z'),schedulerKey:'custom'}},[],Date.parse('2026-10-28T12:00:00Z'),{custom});
assert.equal(tiny.counts[4],1); // No artificial stability floor.
console.log('PASS retention uses actual review times, rejects unknowns and labels legacy fallback');

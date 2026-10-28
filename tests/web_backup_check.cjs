const fs = require('fs'), vm = require('vm'), assert = require('assert');
const html = fs.readFileSync('web/index.html', 'utf8');
const source = html.slice(html.indexOf('function exportLearningState()'), html.indexOf('let apHintShown'));
let savedBlob, link, removed = false;
const ctx = {
 S: {cards: {apple: {pos: 1}}, log: [], pendingNew: []}, AUTH: {token: 'private-token'},
 Blob, structuredClone, accountSlot: () => 'guest', today: () => '2026-10-27',
 URL: {createObjectURL: blob => { savedBlob = blob; return 'blob:local'; }, revokeObjectURL: () => {}},
 document: {createElement: () => (link = {click() {}, remove() {removed = true;}}), body: {appendChild() {}}},
 setTimeout: f => f()
};
vm.createContext(ctx); vm.runInContext(source, ctx); ctx.exportLearningState();
(async () => {
 const raw = await savedBlob.text();
 assert.equal(JSON.parse(raw).cards.apple.pos, 1);
 assert(!raw.includes('private-token'));
 assert.equal(link.download, 'vocab-progress-2026-10-27.json');
 assert(removed);
 const key='a'.repeat(64), absent='b'.repeat(64);
 const state={cards:{apple:{fsrsHistory:{events:[{id:'old'},{id:'review',schedulerKey:key}]},appliedFsrs:['old','review']},
                     pear:{pendingFsrs:{schedulerKey:absent,events:[]}}},log:[],pendingNew:[]};
 let audit=ctx.backupSchedulerWarnings(state);
 assert(audit.keys.has(key) && audit.keys.has(absent));
 assert(audit.warnings.some(w=>w.includes('缺少')) && audit.warnings.some(w=>w.includes('旧评分')));
 const config={library:'fsrs',parameters:[1],desired_retention:0.9,learning_steps:[],relearning_steps:[],maximum_interval:365};
 let message={textContent:''};ctx.$=()=>message;ctx.API='http://fixture';ctx.authHeaders=()=>({Authorization:'Bearer test'});
 ctx.AUTH={token:'test',userId:7,accountId:'account'};ctx.AbortController=AbortController;ctx.clearTimeout=()=>{};
 ctx.fetch=async()=>({ok:true,json:async()=>({versions:{[key]:config}})});
 ctx.downloadBackupWithSchedulers(state,'backup.json',7);
 await new Promise(resolve=>setImmediate(resolve));
 let output=JSON.parse(await savedBlob.text());
 assert.deepEqual(output.fsrsSchedulers[key],config);
 assert(message.textContent.includes('缺少') && message.textContent.includes('旧评分'));
 const conflictState={cards:{apple:{fsrsHistory:{events:[{id:'review',schedulerKey:key}]},appliedFsrs:['review']}},
                      fsrsSchedulers:{[key]:{...config,library:'local-original'}}};
 ctx.downloadBackupWithSchedulers(conflictState,'conflict.json',7);
 await new Promise(resolve=>setImmediate(resolve));
 output=JSON.parse(await savedBlob.text());
 assert.equal(output.fsrsSchedulers[key].library,'local-original');
 assert(message.textContent.includes('不一致'));
 const negativeZero={...config,parameters:[-0]};
 assert(ctx.backupSchedulerWarnings({cards:{apple:{pendingFsrs:{schedulerKey:key,events:[]}}},fsrsSchedulers:{[key]:negativeZero}}).warnings.some(w=>w.includes('无法安全')));
 assert.notEqual(ctx.backupValueKey(negativeZero),ctx.backupValueKey({...config,parameters:[0]}));
 const queuedOnly={cards:{apple:{fsrsHistory:{events:[{id:'pending'}]},pendingFsrs:{events:[{id:'pending'}]}}}};
 assert.equal(ctx.backupSchedulerWarnings(queuedOnly).warnings.length,0);
 assert(ctx.backupSchedulerWarnings({cards:{apple:{pendingFsrs:{schedulerKey:7,events:[]}}}}).warnings.some(w=>w.includes('标识无效')));
 const many={};for(let i=0;i<255;i++)many[i.toString(16).padStart(64,'0')]=config;
 const extra='f'.repeat(64), capped={cards:{apple:{pendingFsrs:{schedulerKey:key,events:[]}}},fsrsSchedulers:many};
 ctx.fetch=async()=>({ok:true,json:async()=>({versions:{[extra]:config,[key]:config}})});
 ctx.downloadBackupWithSchedulers(capped,'capped.json',7);
 await new Promise(resolve=>setImmediate(resolve));
 output=JSON.parse(await savedBlob.text());
 assert(output.fsrsSchedulers[key] && !output.fsrsSchedulers[extra] && Object.keys(output.fsrsSchedulers).length===256);
 console.log('PASS Web backup excludes credentials and warns on missing, legacy or conflicting scheduler data');
})().catch(e => { console.error(e); process.exit(1); });

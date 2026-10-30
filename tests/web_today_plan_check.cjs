const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync('web/index.html','utf8');
const code=html.slice(html.indexOf('function availableNewCount('),html.indexOf('/* ---------------- 渲染 ---------------- */'));
const mastery=html.slice(html.indexOf('const isMastered ='),html.indexOf('/* ---------------- 定级'));
const ctx={today:()=> '2026-10-27',Date};vm.createContext(ctx);vm.runInContext(html.slice(html.indexOf('function provisionalSchedule('),html.indexOf('// 服务端调度是无状态计算'))+'\n'+mastery+'\n'+code,ctx);
const day='2026-10-27',state={settings:{dailyCap:4,newPerDay:5},track:null,
 log:[{d:day,word:'apple',kind:'learn'},{d:day,word:'apple',kind:'review'},{d:day,word:'banana',kind:'probe'},
      {d:day,word:'noise',kind:'exposure'},{d:day,word:'placed',kind:'placement'}],
 cards:Object.fromEntries(['apple','due1','due2','due3'].map(word=>[word,{due:'2000-01-01T00:00:00Z'}]))};
const p=ctx.dailyPlanSummary(state,day,new Date('2026-10-27T12:00:00Z'));
assert.equal(p.completed,2);assert.equal(p.dueAvailable,3);assert.equal(p.duePlanned,0);assert.equal(p.newPlanned,2);assert.equal(p.totalPlanned,4);
state.settings.dailyCap=20;const larger=ctx.dailyPlanSummary(state,day,new Date('2026-10-27T12:00:00Z'));
assert.equal(larger.newPlanned,4);assert.equal(larger.totalPlanned,9);
state.cards.mastered={stage:6,due:'2000-01-01T00:00:00Z'};
assert.equal(ctx.dailyPlanSummary(state,day,new Date('2026-10-27T12:00:00Z')).dueAvailable,3);
console.log('PASS homepage counts match deduplication, new-word priority, mastery and daily capacity');

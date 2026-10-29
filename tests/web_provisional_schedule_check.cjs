const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync('web/index.html','utf8');
const ctx={Date};vm.createContext(ctx);
vm.runInContext(html.slice(html.indexOf('function provisionalSchedule('),html.indexOf('// 服务端调度是无状态计算')),ctx);
const cases=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
for(const [index,fixture] of cases.entries()){
 const before=JSON.stringify(fixture.card),p=ctx.provisionalSchedule(fixture.card,fixture.configurations);
 assert(p,`missing plan ${index}`);assert.equal(p.state,fixture.state,`state ${index}`);assert.equal(p.step,fixture.step,`step ${index}`);
 assert.equal(Date.parse(p.due),Date.parse(fixture.due),`due ${index}`);assert.equal(JSON.stringify(fixture.card),before);
 ctx.applyProvisionalSchedule(fixture.card,fixture.configurations);assert.equal(Date.parse(fixture.card.due),Date.parse(fixture.due));
}
assert.equal(ctx.provisionalSchedule({due:'2026-01-01'}),null);
console.log(`PASS ${cases.length} Web offline phase/step cases against official FSRS, with explicit provisional review intervals`);

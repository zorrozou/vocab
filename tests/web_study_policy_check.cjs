const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync('web/index.html','utf8'),ctx={Date};vm.createContext(ctx);
vm.runInContext(html.slice(html.indexOf('const isMastered ='),html.indexOf('/* ---------------- 定级'))+'\nthis.mastered=isMastered;',ctx);
const cases=JSON.parse(fs.readFileSync('tests/study_policy_fixtures.json'));
for(const c of cases)assert.equal(ctx.mastered(c.card),c.mastered,c.name);
console.log(`PASS ${cases.length} Web mastery lifecycle fixtures`);

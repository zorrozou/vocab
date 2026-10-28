const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync('web/index.html','utf8');
const code=html.slice(html.indexOf('function recordStudyDay('),html.indexOf('/* ---- 完成 + 自动触发个性化 ---- */'));
const ctx={S:{lastDay:'2026-10-25',streak:4},crypto:require('crypto').webcrypto,
 addDays:(d,n)=>{const t=new Date(d+'T00:00:00Z');t.setUTCDate(t.getUTCDate()+n);return t.toISOString().slice(0,10)}};
vm.createContext(ctx);vm.runInContext(code,ctx);
ctx.recordStudyDay('2026-10-24');assert.equal(ctx.S.streak,4);
ctx.recordStudyDay('2026-10-20');assert.equal(ctx.S.streak,4);
ctx.recordStudyDay('2026-10-21');assert.equal(ctx.S.streak,6);
ctx.recordStudyDay('2026-10-26');assert.equal(ctx.S.streak,7);
ctx.recordStudyDay('2026-10-21');assert.equal(ctx.S.streak,7);
console.log('PASS earlier day backfill extends only contiguous evidence and does not double count');

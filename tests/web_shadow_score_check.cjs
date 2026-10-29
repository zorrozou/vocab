const fs=require('fs'), vm=require('vm'), assert=require('assert');
const html=fs.readFileSync('web/index.html','utf8');
const code=html.slice(html.indexOf('const tokens ='),html.indexOf('/* ---------------- 调度'));
const context={};vm.createContext(context);vm.runInContext(code,context);
for(const [target,recognized,expected] of [
  ['I know that I know.','I know',40],
  ['I know that I know.','I know that I know',100],
  ['one two three','one two',67],
  ['one two','one one one',50],
  ['one two','',0],['...','anything',0],["Don't stop.","don't stop",100]
]) assert.equal(context.shadowCompleteness(target,recognized),expected);
console.log('PASS shadow completeness respects repeated words, empty input and rounding');

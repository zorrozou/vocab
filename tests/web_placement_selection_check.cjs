const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync('web/index.html','utf8'),box={};vm.createContext(box);
const source='const GRID=Array.from({length:49},(_,i)=>i*250);const logistic=x=>1/(1+Math.exp(-x));\n'+
 html.slice(html.indexOf('function posteriorCalc('),html.indexOf('function effectiveEvidenceSummary('))+
 html.slice(html.indexOf('const posteriorMean ='),html.indexOf('const posteriorStd ='))+
 html.slice(html.indexOf('const PLACEMENT_BANDS ='),html.indexOf('function catFinalMean()'));
vm.runInContext(source,box);
for(const c of JSON.parse(fs.readFileSync('tests/placement_selection_fixtures.json'))){
 const state={probeCount:c.probeCount,posterior:Array(49).fill(0),bandEvidence:{0:{events:Object.fromEntries(c.used.map(pos=>[pos,{pos}]))}}};state.posterior[c.gridIndex]=1;
 const excluded=c.excludedRanges.flatMap(([lo,hi])=>Array.from({length:hi-lo+1},(_,i)=>lo+i));
 const pool=box.placementCandidatePool(state,excluded);
 assert.equal(pool.length,c.count,c.name);assert.equal(pool[0]??null,c.low,c.name);assert.equal(pool.at(-1)??null,c.high,c.name);assert.equal(box.placementAtCeiling(state),c.ceiling,c.name);
}
for(const correct of [true,false]){
 let state={probeCount:0,posterior:null,bandEvidence:{0:{events:{}}}};const seen=new Set();
 for(let i=0;i<30;i++){
  const pool=box.placementCandidatePool(state),pos=pool[Math.floor(pool.length/2)];assert(!seen.has(pos));seen.add(pos);
  state.bandEvidence[0].events[i]={pos};state.posterior=box.posteriorCalc(state.posterior,pos,correct?1:0,1,.25);state.probeCount++;
  if(i===16)state=JSON.parse(JSON.stringify(state));
 }
 assert.equal(seen.size,30);
}
console.log('PASS Web placement upper/lower limits, persisted exclusions, exhausted windows and 30 unique all-correct/all-wrong answers');

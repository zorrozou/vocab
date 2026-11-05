const assert=require('node:assert/strict'),fs=require('node:fs');require('../web/recognition.js');const R=VocabRecognition;
function state(stats){let s={recognitionEvidence:{}};stats.forEach(({n,k},b)=>{for(let i=0;i<n;i++)s.recognitionEvidence[`${b}-${i}`]={version:1,word:`w${b}-${i}`,pos:R.bands[b][0]+i,at:`2026-11-05T01:${String(b).padStart(2,'0')}:${String(i%60).padStart(2,'0')}Z`,correct:i<k,source:'placement',itemId:'a'.repeat(64)};});return s;}
const cases=[Array(6).fill({n:0,k:0}),...Array.from({length:6},(_,k)=>Array(6).fill({n:5,k})),[{n:2,k:2},{n:2,k:2},{n:2,k:2},{n:2,k:2},{n:3,k:3},{n:19,k:14}],Array(6).fill({n:50,k:12}),Array(6).fill({n:100,k:100})];
const fixtures=cases.map((stats,i)=>{const s=state(stats),e=R.estimate(s);assert(e.lower<=e.upper&&e.lower>=0&&e.upper<=10987);return {name:`case-${i}`,stats,lower:e.lower,upper:e.upper,mean:e.mean,pointer:R.pointer(s)};});
if(process.argv[2])fs.writeFileSync(process.argv[2],JSON.stringify(fixtures));
const sparse=R.bandMean({n:2,k:2});assert(sparse<.8&&sparse>.5,'2/2 cannot establish complete knowledge');
const fresh=state(Array(6).fill({n:5,k:3})),before=R.estimate(fresh);
fresh.cards={apple:{pos:3000,fsrs:{state:1,stability:.1,lastReview:new Date().toISOString()}}};fresh.knowledge={apple:{a:100,b:0,pos:3000}};
assert.equal(R.estimate(fresh).mean,before.mean,'practice cannot boost assessment');
let s={recognitionEvidence:{}},seen=new Set();
for(let i=0;i<30;i++){let pool=R.candidatePool(s,[],true),pos=pool[Math.floor(pool.length/2)];assert(!seen.has(pos));seen.add(pos);s.recognitionEvidence[i]={version:1,pos,word:`w${i}`,at:new Date(1e12+i*1000).toISOString(),correct:i%2===0,source:'placement',itemId:'a'.repeat(64)};if(i===17)s=JSON.parse(JSON.stringify(s));}
assert.deepEqual(R.counts(s).map(x=>x.n),[5,5,5,5,5,5]);assert.equal(R.candidatePool(s,Array.from({length:10987},(_,i)=>i+1)).length,0);
const dup=Object.values(s.recognitionEvidence)[0];s.recognitionEvidence.other={...dup,at:'2099-01-01T00:00:00Z',correct:!dup.correct};assert.equal(R.estimate(s).n,30);
const legacy={bandEvidence:{0:{events:{}}},cards:{},bandStats:{0:{a:10000,b:0}},posterior:Array(49).fill(1/49)};
assert.equal(R.estimate(legacy).n,0,'aggregate legacy scores are not attributable samples');
for(let i=0;i<30;i++){let b=i<12?Math.floor(i/2):5,pos=R.bands[b][0]+i;legacy.bandEvidence[0].events[i]={pos,at:new Date(1e12+i*1000).toISOString(),ok:true};}
assert.equal(R.estimate(legacy).n,12,'legacy adaptive tail is excluded');
console.log('PASS recognition correction, independent evidence, sparse uncertainty, full coverage, restart, deduplication and legacy migration');
// Deterministic synthetic calibration, not a claim about real test takers.
let seed=20261105;function rand(){let t=seed+=0x6D2B79F5;t=Math.imul(t^t>>>15,t|1);t^=t+Math.imul(t^t>>>7,t|61);return ((t^t>>>14)>>>0)/4294967296}
const report=[];
for(const known of [0,3000,6000,9000,10987]){
 let sum=0,covered=0,lowerPositive=0,old=0,width=0;
 for(let run=0;run<300;run++){
  const stats=R.bands.map(([lo,hi])=>{let k=0;for(let i=0;i<5;i++){let rank=lo+Math.floor(rand()*(hi-lo+1));if(rank<=known||rand()<.25)k++;}return {n:5,k};});
  const r=R.interval(stats);sum+=r.mean;old+=stats.reduce((v,s,i)=>v+(R.bands[i][1]-R.bands[i][0]+1)*s.k/s.n,0);width+=r.upper-r.lower;if(r.lower<=known+1e-5&&r.upper>=known-1e-5)covered++;if(r.lower>1)lowerPositive++;
 }
 report.push({known,newMLE:Math.round(sum/300),oldRaw:Math.round(old/300),coverage:covered/300,averageWidth:Math.round(width/300),positiveLower:lowerPositive});assert(covered/300>=.9,JSON.stringify(report.at(-1)));
}
console.log(JSON.stringify(report,null,2));

const fs=require('fs'),vm=require('vm'),assert=require('assert');
const box={self:{},URL,URLSearchParams,TextEncoder};box.self=box;vm.createContext(box);
vm.runInContext(fs.readFileSync('web/offline-library.js','utf8'),box);
(async()=>{
 const api=box.VocabLocalSentence,row={text:'The apple fell from the tree.',zh:'苹果从树上掉了下来。'};
 assert(api.valid('apple',row,[5,4,5,5,5,5]));
 for(const [w,r,s] of [['apple',row,[5]],['apple',row,[5,5,5,5,5,3]],['app',row,[5,5,5,5,5,5]],['apple',{...row,zh:'English only'},[5,5,5,5,5,5]],['apple',{...row,zh:'�'},[5,5,5,5,5,5]]])assert(!api.valid(w,r,s));
 assert.equal(await api.available(),false);
 let created=0,destroyed=0,step=0;
 box.LanguageModel={availability:async()=> 'downloadable',create:async()=>{created++;return{prompt:async()=>JSON.stringify(step++%2?[5,5,5,5,5,5]:row),destroy:()=>destroyed++}}};
 await assert.rejects(api.generate('apple','苹果'));assert.equal(created,0,'must never start an implicit model download');
 box.LanguageModel.availability=async opts=>{assert(opts.expectedOutputs[0].languages.includes('zh'));return 'available'};
 const result=await api.generate('apple','苹果');assert.equal(result.text,row.text);assert.equal(destroyed,1);
 box.LanguageModel.create=async()=>({prompt:async()=>'{bad',destroy:()=>destroyed++});
 await assert.rejects(api.generate('apple','苹果'));assert.equal(destroyed,2,'release model after invalid output');
 console.log('PASS local model availability, no implicit downloads, bilingual six-score quality gate, resource cleanup');
})().catch(e=>{console.error(e);process.exit(1)});

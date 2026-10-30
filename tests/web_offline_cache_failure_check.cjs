const fs=require('fs'),vm=require('vm'),assert=require('assert');
(async()=>{
 for(const failure of ['open','put']) {
  const handlers={},cache={put:async()=>{throw Error('quota')},match:async()=>null,keys:async()=>[],delete:async()=>true};
  const box={URL,Response,location:{origin:'https://test.example'},self:{registration:{scope:'https://test.example/vocab/'},addEventListener:(name,fn)=>handlers[name]=fn},importScripts:()=>{},VocabLibrary:{init:()=>{},lookup:async()=>null},caches:{open:async()=>{if(failure==='open')throw Error('storage unavailable');return cache}},fetch:async req=>new Response(req.url.includes('/meta')?' {"lexicon_revision":"test"}':'online content',{headers:{'Content-Type':'application/json'}})};
  vm.createContext(box);vm.runInContext(fs.readFileSync('web/offline-worker.js','utf8'),box);
  for(const [path,mode] of [['/vocab/','navigate'],['/vocab/api/v1/lexicon/meta','cors'],['/vocab/api/v1/lexicon/word?word=apple','cors'],['/vocab/api/v1/tts?text=apple','cors']]) {
   let response;handlers.fetch({request:{url:'https://test.example'+path,method:'GET',mode},respondWith:p=>response=p});
   assert((await response).ok,'cache '+failure+' must not hide online '+path);
  }
 }
 console.log('PASS quota/cache-open failures preserve online shell, metadata, word and audio responses');
})().catch(e=>{console.error(e);process.exit(1)});

const fs=require('fs'), vm=require('vm'), assert=require('assert');
const html=fs.readFileSync('web/index.html','utf8');
const source=html.slice(html.indexOf('async function onAuthed('), html.indexOf('async function userMenu()'));
async function scenario({guest, remote, hasLocal=false, register=false}) {
  const values={}; if (guest) values.vocab_guest='1';
  let archived=0, saved=0, syncs=0, renders=0;
  const old={v:1,cards:{oldword:{pos:1}},probeCount:4};
  const ctx={AUTH:null,S:old,save:()=>{saved++},quizSet:[],syncFailed:false,
    localStorage:{getItem:k=>values[k]||null,setItem:(k,v)=>{values[k]=v},removeItem:k=>delete values[k]},
    clearTimeout:()=>{}, archiveCurrent:()=>{archived++; values.archived=JSON.stringify(ctx.S)},
    accountSlot:a=>a ? `vocab_v2_u${a.userId}_${a.username.toLowerCase()}` : 'vocab_v1_guest',
    preserveMainBeforeSwitch:()=>{}, loadSlotClocks:()=>{}, slotClock:(slot,name)=>`${slot}:${name}`,
    markSlotSynced:()=>{}, writeSlotAndMain:(slot,state)=>{values[slot]=JSON.stringify(state);values.vocab_v1=JSON.stringify(state)},
    defaultState:()=>({v:1,cards:{},probeCount:0}),
    loadSlot:()=>{if(hasLocal){ctx.S={v:1,cards:{own:{pos:2}},probeCount:2};return true}return false},
    syncFromServer:async()=>{syncs++;return false}, pullState:async()=>{if(remote==='error') throw Error('offline');return remote},
    renderUserTag:()=>{renders++},home:()=>{},Date,JSON,Object};
  vm.createContext(ctx);vm.runInContext(source,ctx);
  await ctx.onAuthed({user:{id:9,username:'person',nickname:'',},token:'t'},register);
  return {ctx,archived,saved,syncs,values,renders};
}
(async()=>{
 let r=await scenario({guest:false,remote:'error'});
 assert.equal(r.archived,0);assert.equal(r.saved,0);assert.equal(r.ctx.syncFailed,true);assert.deepEqual(Object.keys(r.ctx.S.cards),[]);
 r=await scenario({guest:true,remote:'error'});
 assert.equal(r.archived,1);assert.equal(r.saved,0);assert.equal(r.ctx.syncFailed,true);assert.deepEqual(Object.keys(r.ctx.S.cards),[]);
 r=await scenario({guest:true,remote:{state:null}});
 assert.equal(r.saved,1);assert.deepEqual(Object.keys(r.ctx.S.cards),['oldword']);
 r=await scenario({guest:false,remote:{state:null}});
 assert.equal(r.saved,0);assert.deepEqual(Object.keys(r.ctx.S.cards),[]);
 r=await scenario({guest:false,remote:'error',hasLocal:true});
 assert.equal(r.syncs,1);assert.equal(r.saved,0);assert.deepEqual(Object.keys(r.ctx.S.cards),['own']);
 console.log('PASS account switch never imports another user or treats network errors as empty server');
})().catch(e=>{console.error(e);process.exit(1)});

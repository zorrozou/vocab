const fs = require('fs'), vm = require('vm'), assert = require('assert');
const html = fs.readFileSync('web/index.html', 'utf8');
const code = html.slice(html.indexOf('let personalRefresh ='), html.indexOf('// Credentials are created'));
const versions = html.slice(html.indexOf('function versionDevice()'), html.indexOf('function rejectPersonalSentence('));
let status = 'running', posts = [], saves = 0, owner = 'u7';
const job = {id: 'task-12345678', date: '2026-10-27', weakKey: 'apple,banana', weakWords: ['apple','banana'],
  learnedMaxPos: 5000, replace: true, owner, status: 'queued'};
const ctx = {AUTH: null, S: {personalJobs: [job], personalized: {}, cards: {}}, API: '',
  deviceId: () => owner, authHeaders: () => ({}), personalHeaders: async () => ({}), isMastered: () => false, save: () => { saves++; },
  fetch: async (url, options) => {
    if (options?.method === 'POST') { posts.push(JSON.parse(options.body)); return {ok: true}; }
    return {ok: true, json: async () => ({status, sentences: [
      {target: 'apple', text: 'An apple.', zh: '苹果'},
      ...(status === 'complete' ? [{target: 'banana', text: 'A banana.', zh: '香蕉'}] : [])]})};
  }, JSON, Date, Math, setTimeout, crypto: require('crypto').webcrypto, Uint8Array,
  localStorage:{getItem:()=>null,setItem:()=>{}}
};
vm.createContext(ctx); vm.runInContext(versions + '\n' + code, ctx);
(async () => {
  await ctx.refreshPersonalJobs();
  assert.equal(ctx.S.personalJobs[0].status, 'running');
  assert.equal(ctx.S.personalized.apple.text, 'An apple.');
  assert.equal(ctx.S.personalizedDay, undefined, 'partial response must not mark job complete');
  ctx.S = JSON.parse(JSON.stringify(ctx.S)); // restart with persisted state
  status = 'complete';
  await ctx.refreshPersonalJobs();
  assert.equal(ctx.S.personalJobs[0].status, 'complete');
  assert.equal(ctx.S.personalized.banana.text, 'A banana.');
  const version1 = {counter:1,device:'device-a',deleted:false};
  const version2 = {counter:2,device:'device-a',deleted:false};
  const older = {...job, id:'older-job', personalVersions:{apple:version1}};
  const newer = {...job, id:'newer-job', personalVersions:{apple:version2}};
  ctx.S.personalJobs.push(older,newer);
  const row={target:'apple',text:'Late old text',recall:null,zh:''};
  assert.equal(ctx.applyPersonalJobResult(ctx.S, older, row),false);
  assert.equal(ctx.applyPersonalJobResult(ctx.S, newer, {...row,text:'New text'}),true);
  assert.equal(ctx.S.personalized.apple.text,'New text');
  assert.equal(ctx.applyPersonalJobResult(ctx.S, older, row),false);
  assert.equal(ctx.S.personalizedDay, job.date);
  assert.equal(posts.length, 2);
  assert.equal(posts[0].request_id, posts[1].request_id, 'restart must reuse idempotency key');
  ctx.S.personalJobs.push({...job, id: 'task-87654321', status: 'queued'});
  status = 'superseded';
  const previous = JSON.stringify(ctx.S.personalized);
  await ctx.refreshPersonalJobs();
  assert.equal(JSON.stringify(ctx.S.personalized), previous);
  delete ctx.S.personalized.apple;
  ctx.S.rejectedPersonalized = {apple:['An apple.']};
  ctx.S.personalJobs.push({...job, id:'task-99999999', status:'queued'});
  status = 'complete';
  await ctx.refreshPersonalJobs();
  assert.equal(ctx.S.personalized.apple, undefined, 'a late task must not resurrect a rejected sentence');
  assert.equal(ctx.S.personalized.banana.text, 'A banana.');
  assert(saves >= 2);
  ctx.S.personalJobs = [{...job, id:'legacy-job-123', status:'queued'}];
  ctx.fetch = async () => ({ok:false, status:409});
  await ctx.refreshPersonalJobs();
  assert.equal(ctx.S.personalJobs[0].status, 'failed', 'old guest job collision must stop automatic retries');
  console.log('PASS partial job recovery, idempotent restart and superseded result isolation');
})().catch(e => { console.error(e); process.exit(1); });

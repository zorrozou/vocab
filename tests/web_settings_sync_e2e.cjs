const {chromium} = require('playwright');
const assert = require('assert');
const base = 'http://127.0.0.1:18765';
async function request(path,method='GET',body,token){
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body?{body:JSON.stringify(body)}:{})});
 if(!r.ok) throw Error(`${path} ${r.status} ${await r.text()}`);return r.json();
}
(async()=>{
 const username='setting_'+Math.random().toString(36).slice(2,9), password='test_password_123';
 const a=await request('/api/v1/auth/register','POST',{username,password});
 const b=await request('/api/v1/auth/login','POST',{username,password});
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
 try {
  const left=await browser.newPage(), right=await browser.newPage();
  await Promise.all([left.goto(base+'/'),right.goto(base+'/')]);
  await left.evaluate(async session=>{await onAuthed(session,true);showSettings();},a);
  await right.evaluate(async session=>{await onAuthed(session,false);showSettings();},b);
  await left.locator('[data-new="20"]').click();
  await right.locator('[data-cap="30"]').click();
  const leftState=await left.evaluate(async()=>{save();clearTimeout(save._t);await pushState();return S.settingsVersions;});
  const rightState=await right.evaluate(async()=>{save();clearTimeout(save._t);await pushState();return S.settingsVersions;});
  assert.notEqual(leftState.newPerDay.device,rightState.dailyCap.device);
  let merged=(await request('/api/v1/me/state','GET',null,a.token)).state;
  assert.equal(merged.settings.newPerDay,20);assert.equal(merged.settings.dailyCap,30);
  assert(merged.settingsVersions.newPerDay && merged.settingsVersions.dailyCap);
  // Old devices without versions must not revert either setting.
  const stale={...merged,settings:{...merged.settings,newPerDay:5,dailyCap:100}};delete stale.settingsVersions;
  await request('/api/v1/me/state','PUT',stale,a.token);
  merged=(await request('/api/v1/me/state','GET',null,a.token)).state;
  assert.equal(merged.settings.newPerDay,20);assert.equal(merged.settings.dailyCap,30);
  const conflict=structuredClone(merged);conflict.settings.newPerDay=5;
  const blocked=await fetch(base+'/api/v1/me/state',{method:'PUT',headers:{'Content-Type':'application/json',Authorization:`Bearer ${a.token}`},body:JSON.stringify(conflict)});
  assert.equal(blocked.status,409);
  assert.equal((await request('/api/v1/me/state','GET',null,a.token)).state.settings.newPerDay,20);
  await right.evaluate(async()=>{await syncFromServer();});
  const received=await right.evaluate(()=>({settings:S.settings,versions:S.settingsVersions}));
  assert.equal(received.settings.newPerDay,20);assert.equal(received.settings.dailyCap,30);
  console.log('PASS browser devices merge independent settings and reject stale legacy overwrite');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});

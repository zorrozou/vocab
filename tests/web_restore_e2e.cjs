const {chromium} = require('playwright');
const assert = require('assert');
const fs = require('fs');
const BASE = 'http://127.0.0.1:18765';
async function api(path, method, body, token) {
  const response = await fetch(BASE + path, {method, headers:{'Content-Type':'application/json', ...(token ? {Authorization:`Bearer ${token}`} : {})}, body: body === undefined ? undefined : JSON.stringify(body)});
  if (!response.ok) throw Error(`HTTP ${response.status}`);
  return response.json();
}
function state(word) { return {v:1, calibrated:true, frontier:1, pointer:2, probeCount:0, posterior:null,
  cards:{[word]:{pos:1}}, log:[], pendingNew:[], personalized:{}, streak:0, lastDay:null,
  settings:{newPerDay:10,dailyCap:100}}; }
(async () => {
 const auth = await api('/api/v1/auth/register','POST',{username:'wr_' + Math.random().toString(36).slice(2,10),password:'test_password_123'});
 const initial = state('apple');
 await api('/api/v1/me/state','PUT',initial,auth.token);
 const browser = await chromium.launch({headless:true, ...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
 try {
  const page = await browser.newPage();
  await page.goto(BASE + '/', {waitUntil:'domcontentloaded'});
  await page.evaluate(({auth, initial}) => { AUTH={userId:auth.user.id,accountId:auth.user.account_id,username:auth.user.username,nickname:'test',token:auth.token}; S=initial; showSettings(); }, {auth,initial});
  const input = page.locator('#bImport');
  const file = data => ({name:'backup.json', mimeType:'application/json', buffer:Buffer.from(JSON.stringify(data))});
  page.once('dialog', d => d.dismiss());
  await input.setInputFiles(file(state('banana')));
  await page.waitForFunction(() => document.querySelector('#restoreMsg').textContent.includes('已取消'));
  assert.deepEqual(Object.keys((await api('/api/v1/me/state','GET',undefined,auth.token)).state.cards), ['apple']);
  await input.setInputFiles(file({v:1,cards:[]}));
  await page.waitForFunction(() => document.querySelector('#restoreMsg').textContent.includes('格式无效'));
  page.once('dialog', d => d.accept());
  await input.setInputFiles(file(state('banana')));
  await page.waitForFunction(() => document.querySelector('#restoreMsg').textContent.includes('恢复完成'));
  let result = await api('/api/v1/me/state','GET',undefined,auth.token);
  assert.deepEqual(Object.keys(result.state.cards), ['banana']);
  assert.equal(result.state.restoreEpoch, 1);
  const localBackup = await page.evaluate(() => JSON.parse(localStorage.getItem('vocab_before_restore_' + accountSlot(AUTH))));
  assert.deepEqual(Object.keys(localBackup.cards), ['apple']);
  assert.equal((await api('/api/v1/me/state/backups','GET',undefined,auth.token)).backups.length, 1);
  page.once('dialog', async d => {
    const current = await api('/api/v1/me/state','GET',undefined,auth.token);
    current.state.cards.cherry = {pos:3};
    await api('/api/v1/me/state','PUT',current.state,auth.token);
    await d.accept();
  });
  await input.setInputFiles(file(state('date')));
  await page.waitForFunction(() => document.querySelector('#restoreMsg').textContent.includes('服务器进度已变化'));
  result = await api('/api/v1/me/state','GET',undefined,auth.token);
  assert(result.state.cards.banana && result.state.cards.cherry && !result.state.cards.date);
  const local = await page.evaluate(() => Object.keys(S.cards));
  assert.deepEqual(local, ['banana']);
  await page.evaluate(() => userMenu());
  await page.locator('#mBackups').click();
  const backupButton = page.locator('#backupList button').first();
  await backupButton.waitFor();
  const downloadPromise = page.waitForEvent('download');
  await backupButton.click();
  const download = await downloadPromise;
  const exported = JSON.parse(fs.readFileSync(await download.path(), 'utf8'));
  assert.deepEqual(Object.keys(exported.cards), ['apple']);
  page.once('dialog', d => d.accept());
  await page.locator('#mReload').click();
  await page.waitForFunction(() => document.querySelector('#mMsg').textContent.includes('服务器进度已加载'));
  const reloaded = await page.evaluate(() => Object.keys(S.cards).sort());
  assert.deepEqual(reloaded, ['banana', 'cherry']);
  const priorLocal = await page.evaluate(() => JSON.parse(localStorage.getItem('vocab_before_restore_' + accountSlot(AUTH))));
  assert.deepEqual(Object.keys(priorLocal.cards), ['banana']);
  await page.evaluate(legacy => {
    localStorage.setItem(accountSlot({...AUTH,accountId:null}), JSON.stringify(legacy)); showSettings();
  }, state('legacyword'));
  page.once('dialog', d => { assert(d.message().includes('归属未确认') && d.message().includes('legacyword')); d.dismiss(); });
  await page.getByText('检查并恢复旧存档 1').click();
  await page.waitForFunction(() => document.querySelector('#restoreMsg').textContent.includes('已取消'));
  assert.deepEqual((await api('/api/v1/me/state','GET',undefined,auth.token)).state.cards, result.state.cards);
  page.once('dialog', d => d.accept());
  await page.getByText('检查并恢复旧存档 1').click();
  await page.waitForFunction(() => document.querySelector('#restoreMsg').textContent.includes('恢复完成'));
  assert.deepEqual(Object.keys((await api('/api/v1/me/state','GET',undefined,auth.token)).state.cards), ['legacyword']);
  assert(await page.evaluate(() => !!localStorage.getItem(accountSlot({...AUTH,accountId:null}))));
  await page.evaluate(() => userMenu());
  await page.locator('#mSwitch').click();
  await page.evaluate(() => localStorage.removeItem('vocab_v1_guest'));
  await page.locator('#wGuest').click();
  assert.deepEqual(await page.evaluate(() => Object.keys(S.cards)), []);
  await page.reload({waitUntil:'domcontentloaded'});
  assert.deepEqual(await page.evaluate(() => Object.keys(S.cards)), []);
  console.log('PASS browser cancel, validation, restore, backup and concurrent server change');
 } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

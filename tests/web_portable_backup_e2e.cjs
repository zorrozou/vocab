const {chromium} = require('playwright');
const fs = require('fs');
const assert = require('assert');
(async () => {
  const fixture = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const browser = await chromium.launch({headless:true, executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page = await browser.newPage({acceptDownloads:true});
    await page.goto('http://127.0.0.1:18765/');
    await page.evaluate(({token, uid, state, accountId}) => {
      AUTH = {userId:uid,accountId,username:'test',token}; S = state; delete S.fsrsSchedulers; showSettings();
    }, fixture);
    const first = page.waitForEvent('download');
    await page.locator('#bExport').click();
    const data = fs.readFileSync(await (await first).path(), 'utf8');
    const backup = JSON.parse(data);
    for (const e of fixture.state.cards.apple.pendingFsrs.events) assert(backup.fsrsSchedulers[e.schedulerKey]);
    assert(!data.includes(fixture.token));
    await page.route('**/api/v1/me/fsrs-schedulers', route => route.abort());
    const second = page.waitForEvent('download');
    await page.locator('#bExport').click();
    assert(await (await second).path());
    await page.getByText('未能读取服务器参数快照；已导出本机内容，备份可能不完整。').waitFor();
    console.log('PASS portable browser backup includes account snapshots, excludes token and warns on offline export');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

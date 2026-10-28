const {chromium} = require('playwright');
const assert = require('assert');
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page = await browser.newPage();
    const response = await page.goto('http://127.0.0.1:18765/', {waitUntil:'domcontentloaded'});
    assert(response.headers()['content-security-policy'].includes("'nonce-"));
    assert(!response.headers()['content-security-policy'].includes("script-src 'self' 'unsafe-inline'"));
    const result = await page.evaluate(async () => {
      const health = await fetch(API + '/api/v1/health').then(r => r.json());
      window.__blocked = 0;
      const script = document.createElement('script');
      script.textContent = 'window.__blocked = 1'; document.body.appendChild(script);
      const div = document.createElement('div');
      div.innerHTML = '<img src="/missing-csp-test" onerror="window.__blocked=2">';
      document.body.appendChild(div);
      await new Promise(resolve => setTimeout(resolve, 100));
      return {api: API, health: health.ok, blocked: window.__blocked, loaded: typeof escapeHTML === 'function'};
    });
    assert.deepEqual(result, {api:'', health:true, blocked:0, loaded:true});
    // Emulate nginx stripping /vocab/ while retaining the public URL in the browser.
    await page.route('http://127.0.0.1:18765/vocab/**', async route => {
      const url = new URL(route.request().url());
      url.pathname = url.pathname.replace(/^\/vocab/, '') || '/';
      const response = await route.fetch({url: url.toString()});
      await route.fulfill({response});
    });
    await page.goto('http://127.0.0.1:18765/vocab/', {waitUntil:'domcontentloaded'});
    const proxied = await page.evaluate(async () => ({api: API, health: (await fetch(API + '/api/v1/health').then(r => r.json())).ok}));
    assert.deepEqual(proxied, {api:'/vocab', health:true});
    console.log('PASS nonce CSP blocks injected scripts and root/proxy API paths both work');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });

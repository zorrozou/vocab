const {chromium}=require('playwright'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.VOCAB_BROWSER ? {executablePath:process.env.VOCAB_BROWSER} : {})});
 try{
  const page=await browser.newPage(); await page.goto('http://127.0.0.1:18765/');
  const username='auth_'+Math.random().toString(36).slice(2,10);
  await page.locator('#wRegister').click();await page.locator('#aUser').fill(username);await page.locator('#aPass').fill('test_password_123');await page.locator('#aGo').click();
  await page.waitForFunction(()=>AUTH?.accountId); const oldId=await page.evaluate(()=>AUTH.accountId);
  await page.evaluate(()=>{AUTH=null;localStorage.removeItem('vocab_auth');welcome()});
  await page.locator('#wLogin').click();await page.locator('#aUser').fill(username.toUpperCase());await page.locator('#aPass').fill('test_password_123');await page.locator('#aGo').click();
  await page.waitForFunction(()=>AUTH?.accountId);assert.equal(await page.evaluate(()=>AUTH.accountId),oldId);
  console.log('PASS browser registration and case-insensitive login against Argon2id service');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});

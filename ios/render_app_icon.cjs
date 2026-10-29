// Rasterize the repository's vector icon for the iOS asset catalog.
const fs = require('fs');
const path = require('path');
const {chromium} = require('playwright');
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:process.env.VOCAB_BROWSER || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page = await browser.newPage({viewport:{width:1024,height:1024},deviceScaleFactor:1});
    await page.setContent('<style>body{margin:0;background:#164ab8}svg{display:block}</style>' + fs.readFileSync(path.join(__dirname,'app-icon.svg'),'utf8'));
    await page.screenshot({path:path.join(__dirname,'VocabApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png')});
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exit(1)});

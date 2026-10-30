/* Public vocabulary only. Auth, progress, personal sentences and mutations never enter this cache. */
importScripts('./offline-library.js');
const SHELL = 'vocab-shell-20261030-library1', CONTENT = 'vocab-public-20261030-';
const base = new URL(self.registration.scope).pathname.replace(/\/$/, '');
VocabLibrary.init(base);
let revision = null;
async function revisionName() {
  if (!revision) {
    const meta = await (await caches.open(SHELL)).match(base+'/api/v1/lexicon/meta');
    revision = meta ? (await meta.json()).lexicon_revision : 'unknown';
  }
  return CONTENT + revision;
}
function publicKey(url) {
  const p = url.pathname.slice(base.length);
  if (!['/api/v1/lexicon/word','/api/v1/quiz','/api/v1/tts','/api/v1/sentence/trio','/api/v1/sentence/alternatives'].includes(p)) return null;
  if (p.endsWith('/quiz')) {
    if (!url.searchParams.get('word')) return null;
    url.searchParams.delete('seed'); url.searchParams.delete('pos');
  }
  url.searchParams.sort(); return url.href;
}
self.addEventListener('install', event => event.waitUntil((async()=>{
  const response = await fetch(self.registration.scope, {cache:'reload'});
  if (!response.ok) throw Error('Offline shell unavailable');
  await (await caches.open(SHELL)).put(self.registration.scope,response);
  const script=await fetch(base+'/offline-library.js',{cache:'reload'});
  if(!script.ok)throw Error('Offline library script unavailable');
  await(await caches.open(SHELL)).put(base+'/offline-library.js',script);
  await self.skipWaiting();
})()));
self.addEventListener('activate', event => event.waitUntil((async()=>{
  for (const name of await caches.keys()) if (name.startsWith('vocab-shell-') && name !== SHELL) await caches.delete(name);
  await self.clients.claim();
})()));
self.addEventListener('fetch', event => {
  const req=event.request, url=new URL(req.url);
  if(req.method!=='GET'||url.origin!==location.origin||!url.pathname.startsWith(base+'/'))return;
  if(url.pathname===base+'/offline-library.js'){event.respondWith((async()=>{try{return await fetch(req);}catch(e){return(await caches.open(SHELL)).match(url.pathname);}})());return;}
  if(req.mode==='navigate' && [base+'/',base].includes(url.pathname)) {
    event.respondWith((async()=>{try{const r=await fetch(req);if(r.ok)try{await(await caches.open(SHELL)).put(self.registration.scope,r.clone());}catch(_){}return r;}catch(e){return (await caches.open(SHELL)).match(self.registration.scope);}})());return;
  }
  if(url.pathname===base+'/api/v1/lexicon/meta') {
    event.respondWith((async()=>{
      const cache=await caches.open(SHELL).catch(()=>null);
      try { const r=await fetch(req); if(r.ok) {const m=await r.clone().json(); revision=m.lexicon_revision;try{await cache?.put(url.pathname,r.clone());}catch(_){}}return r; }
      catch(e){const old=await cache?.match(url.pathname);if(old)return old;throw e;}
    })());return;
  }
  const key=publicKey(url);if(!key)return;
  event.respondWith((async()=>{
    let cache=null;try{cache=await caches.open(await revisionName());}catch(_){}
    if(url.pathname.endsWith('/tts')) { const hit=await cache?.match(key);if(hit){return hit;} }
    try {
      const r=await fetch(req);
      if(r.status>=500)throw Error('Public content temporarily unavailable');
      try { if(cache && r.ok && !(r.headers.get('cache-control')||'').includes('private')) {
        const size=(await r.clone().blob()).size;
        if(size<2*1024*1024) {
          await cache.put(key,r.clone());
          const keys=await cache.keys();
          for(const old of keys.slice(0,Math.max(0,keys.length-800)))await cache.delete(old);
        }
      }
      } catch (_) { /* A cache write failure must not hide a valid online response. */ }
      return r;
    }catch(e){const old=await cache?.match(key);if(old)return old;const packed=await VocabLibrary.lookup(url.pathname.slice(base.length),url.searchParams,revision);if(packed)return packed;throw e;}
  })());
});
self.addEventListener('message',event=>{
  if(event.data==='library-status')event.ports[0]?.postMessage({libraryVersion:1});
  if(event.data==='prune-public-cache')event.waitUntil((async()=>{
    const keep=await revisionName();
    for(const name of await caches.keys())if(name.startsWith(CONTENT)&&name!==keep)await caches.delete(name);
  })());
});

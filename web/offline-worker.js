/* Public vocabulary only. Auth, progress, personal sentences and mutations never enter this cache. */
const SHELL = 'vocab-shell-20261030-health1', CONTENT = 'vocab-public-20261030-';
const base = new URL(self.registration.scope).pathname.replace(/\/$/, '');
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
  if (!['/api/v1/lexicon/word','/api/v1/quiz','/api/v1/tts'].includes(p)) return null;
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
  await self.skipWaiting();
})()));
self.addEventListener('activate', event => event.waitUntil((async()=>{
  for (const name of await caches.keys()) if (name.startsWith('vocab-shell-') && name !== SHELL) await caches.delete(name);
  await self.clients.claim();
})()));
self.addEventListener('fetch', event => {
  const req=event.request, url=new URL(req.url);
  if(req.method!=='GET'||url.origin!==location.origin||!url.pathname.startsWith(base+'/'))return;
  if(req.mode==='navigate' && [base+'/',base].includes(url.pathname)) {
    event.respondWith((async()=>{try{const r=await fetch(req);if(r.ok)await(await caches.open(SHELL)).put(self.registration.scope,r.clone());return r;}catch(e){return (await caches.open(SHELL)).match(self.registration.scope);}})());return;
  }
  if(url.pathname===base+'/api/v1/lexicon/meta') {
    event.respondWith((async()=>{
      const cache=await caches.open(SHELL);
      try { const r=await fetch(req); if(r.ok) {const m=await r.clone().json(); revision=m.lexicon_revision;await cache.put(url.pathname,r.clone());}return r; }
      catch(e){const old=await cache.match(url.pathname);if(old)return old;throw e;}
    })());return;
  }
  const key=publicKey(url);if(!key)return;
  event.respondWith((async()=>{
    const cache=await caches.open(await revisionName());
    if(url.pathname.endsWith('/tts')) { const hit=await cache.match(key);if(hit){await cache.delete(key);await cache.put(key,hit.clone());return hit;} }
    try {
      const r=await fetch(req);
      if(r.ok && !(r.headers.get('cache-control')||'').includes('private')) {
        const size=(await r.clone().blob()).size;
        if(size<2*1024*1024) {
          await cache.delete(key);
          await cache.put(key,r.clone());
          const keys=await cache.keys();
          for(const old of keys.slice(0,Math.max(0,keys.length-800)))await cache.delete(old);
        }
      }
      return r;
    }catch(e){const old=await cache.match(key);if(old)return old;throw e;}
  })());
});
self.addEventListener('message',event=>{
  if(event.data==='prune-public-cache')event.waitUntil((async()=>{
    const keep=await revisionName();
    for(const name of await caches.keys())if(name.startsWith(CONTENT)&&name!==keep)await caches.delete(name);
  })());
});

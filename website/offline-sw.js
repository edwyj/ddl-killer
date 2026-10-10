/* Root-domain transition: preserve offline data and existing shell caches. */
self.addEventListener('install',()=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('fetch',e=>{
 const u=new URL(e.request.url);
 if(e.request.method!=='GET'||u.origin!==self.location.origin||
    u.pathname.startsWith('/api/')||u.pathname.startsWith('/mcp')||
    u.pathname.startsWith('/.well-known/')||u.pathname.startsWith('/oauth/'))return;
 e.respondWith(fetch(e.request).catch(async()=>{
  const key=e.request.mode==='navigate'&&['/','/index.html','/app'].includes(u.pathname)?'/index.html':e.request;
  const cached=await caches.match(key);
  return cached||new Response('暂时无法联网，请稍后重试。',{status:503,headers:{'Content-Type':'text/plain; charset=utf-8'}});
 }));
});
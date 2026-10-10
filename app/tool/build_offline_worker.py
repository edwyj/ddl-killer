"""Run after flutter build web --pwa-strategy=none --no-web-resources-cdn."""
import hashlib,json,pathlib
root=pathlib.Path(__file__).resolve().parents[1]/'build'/'web'
files=sorted(p for p in root.rglob('*') if p.is_file() and p.suffix!='.apk' and p.name not in {'app-update.json','offline-sw.js','flutter_service_worker.js','.last_build_id'} and 'download' not in p.parts and 'releases' not in p.parts)
urls=['/'+p.relative_to(root).as_posix() for p in files]
digest=hashlib.sha256(pathlib.Path(__file__).read_bytes()+b''.join(p.read_bytes() for p in files)).hexdigest()[:20]
worker=r'''
const CACHE='ddl-shell-VERSION';
const ASSETS=URLS;
self.addEventListener('message',event=>{if(event.data==='ACTIVATE_UPDATE')self.skipWaiting();});
self.addEventListener('install',event=>event.waitUntil((async()=>{
 const cache=await caches.open(CACHE);
 // Activate only after a complete download. Existing pages are never reloaded.
 try{await cache.addAll(ASSETS.map(url=>new Request(url,{cache:'reload'})));}
 catch(error){await caches.delete(CACHE);throw error;}
 await self.skipWaiting();
})()));
self.addEventListener('activate',event=>event.waitUntil((async()=>{
 const previous=(await caches.keys()).filter(name=>name.startsWith('ddl-shell-')&&name!==CACHE);
 // Retain the previous complete shell for in-flight clients; never touch user databases.
 for(const name of previous.slice(0,-1))await caches.delete(name);
 await self.clients.claim();
})()));
self.addEventListener('fetch',event=>{
 const request=event.request,url=new URL(request.url);
 if(request.method!=='GET'||url.origin!==self.location.origin||url.pathname.startsWith('/api/'))return;
 const key=request.mode==='navigate'&&url.pathname==='/'?'/index.html':url.pathname;
 if(!ASSETS.includes(key))return;
 event.respondWith((async()=>{const cache=await caches.open(CACHE);return await cache.match(key)||fetch(request);})());
});
'''.replace('VERSION',digest).replace('URLS',json.dumps(urls))
(root/'offline-sw.js').write_text(worker,encoding='utf-8')
print(f'Offline shell: {len(files)} assets, {sum(p.stat().st_size for p in files)} bytes, {digest}')

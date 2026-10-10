import {readFileSync,existsSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../build/web');
const listeners={},cached=new Map(),deleted=[];let requested=0,activationRequested=0,claimed=0;
const context={URL,Request:class {constructor(url){this.url=url;}},fetch:async()=>{throw new Error('offline');},
 self:{skipWaiting:async()=>{assert.ok(requested>50);activationRequested++;},location:{origin:'https://test.example'},clients:{claim:async()=>{claimed++;}},addEventListener:(type,fn)=>listeners[type]=fn},
 caches:{keys:async()=>["other-app-cache","ddl-shell-obsolete","ddl-shell-previous"],delete:async name=>deleted.push(name),open:async()=>({addAll:async requests=>{for(const req of requests){const p=path.join(root,req.url);assert.ok(existsSync(p),`Missing asset ${req.url}`);cached.set(req.url,readFileSync(p));requested++;}},match:async key=>cached.get(key)})}};
vm.runInNewContext(readFileSync(path.join(root,'offline-sw.js'),'utf8'),context);
let job;listeners.install({waitUntil:p=>job=p});await job;
assert.ok(requested>50);assert.equal(activationRequested,1,'new shell must activate after complete installation');assert.ok(cached.has('/assets/assets/fonts/NotoSansSC.ttf'));assert.ok(cached.has('/assets/assets/fonts/NotoColorEmoji.ttf'));
let response;listeners.fetch({request:{method:'GET',url:'https://test.example/',mode:'navigate'},respondWith:p=>response=p});
assert.match((await response).toString(),/offline-client.js/);
response=null;listeners.fetch({request:{method:'GET',url:'https://test.example/api/sync/snapshot',mode:'cors'},respondWith:p=>response=p});assert.equal(response,null);
assert.ok(![...cached.keys()].some(p=>p.includes('/api/')||p.endsWith('.apk')));
assert.ok(!cached.has('/app-update.json'));
assert.ok(cached.has('/site-theme.js') && cached.has('/site-theme.css'), 'Shared appearance must remain available offline');
console.log(`Offline worker passed: ${requested} local assets, bundled Chinese/emoji fonts, cached navigation while offline, API excluded`);

listeners.activate({waitUntil:p=>job=p});await job;
assert.equal(claimed,1);assert.deepEqual(deleted,["ddl-shell-obsolete"]);
// Installation failures never activate an incomplete shell.
let failedActivation=0,removed=0;
const failedListeners={};
vm.runInNewContext(readFileSync(path.join(root,'offline-sw.js'),'utf8'),{
 URL,Request:context.Request,
 self:{location:{origin:'https://test.example'},skipWaiting:async()=>{failedActivation++;},addEventListener:(t,f)=>failedListeners[t]=f},
 caches:{open:async()=>({addAll:async()=>{throw Error('network interrupted');}}),delete:async()=>{removed++;}}
});
failedListeners.install({waitUntil:p=>job=p});
await assert.rejects(job,/network interrupted/);
assert.equal(failedActivation,0);
assert.equal(removed,1);
console.log('Update lifecycle passed: complete shell activates, failed shell remains inactive; no page reload required by worker.');

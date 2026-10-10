import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source=readFileSync(new URL('../web/offline-client.js',import.meta.url),'utf8');
function setup(registration){
 let reloads=0;
 const context={window:{addEventListener(){}},navigator:{serviceWorker:{addEventListener(){},register:async()=>registration,getRegistration:async()=>registration}},location:{reload(){reloads++;}},setTimeout,clearTimeout};
 vm.runInNewContext(source,context);
 return {api:context.window.ddlOffline,reloads:()=>reloads};
}
{
 const s=setup({update:async()=>{},installing:null,waiting:null});
 assert.equal(s.reloads(),0);
 await s.api.update();
 assert.equal(s.reloads(),1,'explicit update works when new worker already active');
}
{
 let checked=0;
 const s=setup({update:async()=>{checked++;}});
 s.api.pending(1);
 await assert.rejects(s.api.update(),/Pending changes/);
 assert.equal(checked,0);assert.equal(s.reloads(),0);
}
{
 const listeners=new Set();
 const worker={state:'installing',addEventListener:(_,fn)=>listeners.add(fn),removeEventListener:(_,fn)=>listeners.delete(fn)};
 const s=setup({update:async()=>{},installing:worker});
 const update=s.api.update();
 await new Promise(resolve=>setTimeout(resolve,0));
 assert.equal(s.reloads(),0,'installation is not a completed update');
 s.api.pending(1);
 worker.state='activated';for(const fn of listeners)fn();
 await assert.rejects(update,/Pending changes/);
 assert.equal(s.reloads(),0,'new unsynced edits prevent reload even after activation');
}
console.log('Manual update passed: already-active worker, pending-edit guards, no unsolicited reload.');
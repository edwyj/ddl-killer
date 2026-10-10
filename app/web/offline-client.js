window.ddlOffline=(()=>{
  let held=false,changes=0,callback=null;
  window.addEventListener('online',()=>callback?.());
  navigator.serviceWorker?.addEventListener('controllerchange',()=>callback?.());
  window.addEventListener('beforeunload',event=>{if(changes>0){event.preventDefault();event.returnValue='';}});
  if('serviceWorker' in navigator)navigator.serviceWorker.register('/offline-sw.js',{scope:'/',updateViaCache:'none'}).catch(()=>{});
  return {
    async update(){
      if(changes>0)throw new Error('Pending changes');
      const r=await navigator.serviceWorker.getRegistration('/');
      if(!r)throw new Error('No offline resources');
      await r.update();
      const next=r.installing || r.waiting;
      if(next && next.state!=='activated')await new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>{next.removeEventListener('statechange',check);reject(new Error('Update not ready'));},45000);
        function check(){
          if(next.state==='activated'){clearTimeout(timer);next.removeEventListener('statechange',check);resolve();}
          if(next.state==='redundant'){clearTimeout(timer);next.removeEventListener('statechange',check);reject(new Error('Update failed'));}
        }
        next.addEventListener('statechange',check);
        if(r.waiting)r.waiting.postMessage('ACTIVATE_UPDATE');
        check();
      });
      if(changes>0)throw new Error('Pending changes');
      // Explicit user action only. Background activation never reloads a page.
      location.reload();
    },
    async prepare(){
      if(held)return true;
      if(!navigator.locks)throw new Error('浏览器不支持安全的离线数据协调，请更新浏览器');
      return new Promise((resolve,reject)=>navigator.locks.request('ddl-offline-account',{ifAvailable:true},async lock=>{
        if(!lock){resolve(false);return;}
        held=true;resolve(true);await new Promise(()=>{});
      }).catch(reject));
    },
    async persist(){try{return !!(navigator.storage?.persist && await navigator.storage.persist());}catch{return false;}},
    watch(fn){callback=fn;},pending(count){changes=count;},
    shellReady(){return !!navigator.serviceWorker?.controller?.scriptURL.endsWith('/offline-sw.js');}
  };
})();

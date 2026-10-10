window.ddlPush = (() => {
  const registration = () => navigator.serviceWorker.register('/reminder-sw.js', {scope:'/push/'});
  async function ready() {
    const r=await registration();
    if(!r.active) await new Promise((resolve,reject)=> {
      const w=r.installing || r.waiting;
      if(!w) return reject(new Error('通知服务未就绪'));
      w.addEventListener('statechange',()=> {if(w.state==='activated')resolve();if(w.state==='redundant')reject(new Error('通知服务安装失败'));});
    });
    return r;
  }
  return {
    async permission() {
      if(!('Notification' in window) || !('serviceWorker' in navigator) || !('PushManager' in window))return false;
      return await Notification.requestPermission()==='granted';
    },
    async activate(token,key) {
      const r=await ready();
      const bytes=Uint8Array.from(atob(key.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0));
      const subscription=await r.pushManager.getSubscription() || await r.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:bytes});
      const response=await fetch('/api/push/subscribe',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:JSON.stringify(subscription),signal:AbortSignal.timeout(12000)});
      if(!response.ok)throw new Error('推送订阅保存失败，请重试');
      localStorage.setItem('ddl_push_enabled','1');
    },
    async enabled() {
      if(localStorage.getItem('ddl_push_enabled')!=='1' || !('Notification' in window) || Notification.permission!=='granted')return false;
      const r=await navigator.serviceWorker.getRegistration('/push/');
      return !!(r && await r.pushManager.getSubscription());
    },
    async clear(token) {
      localStorage.removeItem('ddl_push_enabled');
      if(!('serviceWorker' in navigator))return;
      const r=await navigator.serviceWorker.getRegistration('/push/');
      const s=r && await r.pushManager.getSubscription();
      if(!s)return;
      await s.unsubscribe();
      if(token) await fetch('/api/push/subscribe',{method:'DELETE',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:JSON.stringify({endpoint:s.endpoint}),signal:AbortSignal.timeout(10000)}).catch(()=>{});
    },
    async test() { await (await ready()).showNotification('DDL Killer 测试提醒',{body:'浏览器通知已开启；任务提醒由服务器推送',icon:'/icons/Icon-192.png',tag:'test'}); },
  };
})();

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('push', event => {
  const data=event.data?.json() || {};
  event.waitUntil(self.registration.showNotification(data.title || 'DDL Killer 提醒',{
    body:data.body || '有任务需要处理',tag:data.tag,icon:'/icons/Icon-192.png',data:{url:'/'},
  }));
});
self.addEventListener('notificationclick',event=> {
  event.notification.close();
  event.waitUntil(clients.openWindow(self.location.hostname==='ddlkiller.com'?'/app':'/'));
});

import webpush from 'web-push';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { db } from './db.js';

db.exec(`CREATE TABLE IF NOT EXISTS push_subscriptions (
  endpoint TEXT PRIMARY KEY,user_id INTEGER NOT NULL,subscription TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS reminder_deliveries (
  endpoint TEXT NOT NULL,task_id INTEGER NOT NULL,reminder_at TEXT NOT NULL,
  PRIMARY KEY(endpoint,task_id,reminder_at));`);

let keys;
function vapid() {
  if(keys) return keys;
  const database=db.prepare('PRAGMA database_list').get().file;
  if(!database) { keys=webpush.generateVAPIDKeys(); return keys; }
  const path=join(dirname(database),'web-push-keys.json');
  if(existsSync(path)) keys=JSON.parse(readFileSync(path,'utf8'));
  else { keys=webpush.generateVAPIDKeys(); writeFileSync(path,JSON.stringify(keys),{mode:0o600,flag:'wx'}); }
  return keys;
}
export function validSubscription(s) {
  try {
    const u=new URL(s.endpoint);
    const allowed=['fcm.googleapis.com','updates.push.services.mozilla.com','web.push.apple.com'];
    return u.protocol==='https:' && !u.username && !u.password && (!u.port || u.port==='443') &&
      (allowed.includes(u.hostname) || u.hostname.endsWith('.notify.windows.com') || u.hostname.endsWith('.push.services.mozilla.com')) &&
      typeof s.keys?.p256dh==='string' && /^[A-Za-z0-9_-]{80,150}$/.test(s.keys.p256dh) && /^[A-Za-z0-9_-]{20,50}$/.test(s.keys.auth || '');
  }catch{return false;}
}
export function mountReminders(app,auth) {
  app.get('/api/reminders',auth,(req,res)=>{
    const hide=db.prepare('SELECT hide_notification_content FROM users WHERE id=?').get(req.user.uid)?.hide_notification_content!==0;
    res.json(db.prepare('SELECT id,title,reminder_at FROM inbox WHERE user_id=? AND done=0 AND deleted_at IS NULL AND reminder_at>? ORDER BY reminder_at').all(req.user.uid,new Date().toISOString()).map(t=>({...t,title:hide?'你有一项任务需要处理':t.title})));
  });
  app.get('/api/push/key',auth,(req,res)=>res.json({publicKey:vapid().publicKey}));
  app.post('/api/push/subscribe',auth,(req,res)=> {
    if(!validSubscription(req.body)) return res.status(400).json({error:'浏览器推送订阅无效'});
    const s=req.body;
    const owner=db.prepare('SELECT user_id FROM push_subscriptions WHERE endpoint=?').get(s.endpoint);
    if(owner && owner.user_id!==req.user.uid)return res.status(409).json({error:'此浏览器订阅已绑定其他账号，请关闭后重新开启通知'});
    const count=db.prepare('SELECT count(*) n FROM push_subscriptions WHERE user_id=?').get(req.user.uid).n;
    if(count>=10 && !db.prepare('SELECT endpoint FROM push_subscriptions WHERE endpoint=? AND user_id=?').get(s.endpoint,req.user.uid)) return res.status(400).json({error:'最多启用 10 台浏览器设备'});
    db.prepare('INSERT INTO push_subscriptions(endpoint,user_id,subscription) VALUES(?,?,?) ON CONFLICT(endpoint) DO UPDATE SET user_id=excluded.user_id,subscription=excluded.subscription').run(s.endpoint,req.user.uid,JSON.stringify(s));
    res.json({ok:true});
  });
  app.delete('/api/push/subscribe',auth,(req,res)=> {
    db.prepare('DELETE FROM push_subscriptions WHERE endpoint=? AND user_id=?').run(req.body?.endpoint || '',req.user.uid);
    res.json({ok:true});
  });
}
export async function deliverDue(send,now=new Date()) {
  const tasks=db.prepare(`SELECT * FROM inbox WHERE done=0 AND deleted_at IS NULL AND reminder_at<=? AND reminder_at>?`).all(now.toISOString(),new Date(now.getTime()-86400000).toISOString());
  for(const t of tasks) {
    const subscriptions=db.prepare('SELECT * FROM push_subscriptions WHERE user_id=?').all(t.user_id);
    for(const s of subscriptions) {
      if(db.prepare('SELECT 1 FROM reminder_deliveries WHERE endpoint=? AND task_id=? AND reminder_at=?').get(s.endpoint,t.id,t.reminder_at)) continue;
      // 发送前复查一次：这一轮里任务可能已经被打了勾或丢进回收站，那就不该再推了。
      const current=db.prepare('SELECT done,reminder_at FROM inbox WHERE id=? AND deleted_at IS NULL').get(t.id);
      if(!current || current.done || current.reminder_at!==t.reminder_at) break;
      try {
        // Recheck ownership after asynchronous deliveries; a logout/delete may have removed this subscription.
        if(!db.prepare('SELECT 1 FROM push_subscriptions WHERE endpoint=? AND user_id=?').get(s.endpoint,t.user_id))continue;
        const hide=db.prepare('SELECT hide_notification_content FROM users WHERE id=?').get(t.user_id)?.hide_notification_content!==0;
        await send(JSON.parse(s.subscription),JSON.stringify({title:'DDL Killer 提醒',body:hide?'你有一项任务需要处理':t.title,tag:`task-${t.id}`,url:'/'}));
        if(db.prepare('SELECT 1 FROM push_subscriptions WHERE endpoint=? AND user_id=?').get(s.endpoint,t.user_id) &&
           db.prepare('SELECT 1 FROM inbox WHERE id=? AND user_id=?').get(t.id,t.user_id))
          db.prepare('INSERT OR IGNORE INTO reminder_deliveries VALUES(?,?,?)').run(s.endpoint,t.id,t.reminder_at);
      }catch(e) {
        if(e.statusCode===404 || e.statusCode===410) db.prepare('DELETE FROM push_subscriptions WHERE endpoint=?').run(s.endpoint);
        else console.warn('Reminder delivery will retry',e.statusCode || 'network');
      }
    }
  }
  db.prepare('DELETE FROM reminder_deliveries WHERE reminder_at<?').run(new Date(now.getTime()-7*86400000).toISOString());
}
export function startReminderWorker() {
  const k=vapid();
  const send=(s,p)=>webpush.sendNotification(s,p,{TTL:3600,timeout:10000,vapidDetails:{subject:'https://ddlkiller.com',...k}});
  let running=false;
  const tick=async()=> { if(running)return; running=true; try{await deliverDue(send);}catch(e){console.error('Reminder worker failed',e.message);}finally{running=false;} };
  void tick();
  const timer=setInterval(tick,30000); timer.unref();
  return timer;
}

import {createHash} from 'node:crypto';
import {betaGeneration} from './beta.js';
import {db} from './db.js';
import {getUserSchedule} from './schedule.js';
import {taskWithSchedule} from './task-planning.js';

db.exec(`CREATE TABLE IF NOT EXISTS sync_receipts(user_id INTEGER NOT NULL,op_id TEXT NOT NULL,request_hash TEXT NOT NULL,response TEXT NOT NULL,PRIMARY KEY(user_id,op_id));`);
const clone=x=>JSON.parse(JSON.stringify(x));
const stable=x=>JSON.stringify(x,(_,v)=>v && typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.entries(v).sort(([a],[b])=>a.localeCompare(b))):v);
const equal=(a,b)=>stable(a??null)===stable(b??null);
// Device clocks and server-generated metadata are not user edits. Preserve all
// business fields while comparing delete/restore intents from offline chains.
function comparable(value){
 if(!value || typeof value!=='object')return value;
 if(Array.isArray(value))return value.map(comparable);
 return Object.fromEntries(Object.entries(value).filter(([k,v])=>!['created_at','done_at','user_id','version','restore_epoch'].includes(k)&&!(k==='estimate_minutes'&&v==null)).map(([k,v])=>[k,k==='deleted_at'?!!v:k==='schedule'&&v?{date:v.date,start_min:v.start_min,end_min:v.end_min}:comparable(v)]));
}
function entity(uid,path) {
 const m=path.match(/^\/api\/(inbox|blocks|lists)\/(\d+)(?:\/tasks)?$/);
 if(m){const table={inbox:'inbox',blocks:'blocks',lists:'lists'}[m[1]];const row=db.prepare(`SELECT * FROM ${table} WHERE id=? AND user_id=?`).get(+m[2],uid);return row&&m[1]==='inbox'?taskWithSchedule(row):row||null;}
 const trash=path.match(/^\/api\/trash\/(task|block)\/(\d+)(?:\/restore)?$/);
 if(trash)return entity(uid,`/api/${trash[1]==='task'?'inbox':'blocks'}/${trash[2]}`);
 const done=path.match(/^\/api\/done\/(\d+)$/);
 if(done)return entity(uid,`/api/inbox/${done[1]}`);
 if(path==='/api/schedule')return getUserSchedule(uid);
 if(path==='/api/me')return db.prepare('SELECT nickname,avatar FROM users WHERE id=?').get(uid);
 if(path==='/api/account/privacy')return {hide_notification_content:!!db.prepare('SELECT hide_notification_content FROM users WHERE id=?').get(uid).hide_notification_content};
 return null;
}
export function snapshot(uid){
 const profile=db.prepare('SELECT id,username,nickname,avatar,hide_notification_content FROM users WHERE id=?').get(uid);
 return {schema:1,uid,profile,...(betaGeneration() ? {generation:betaGeneration()} : {}),lists:db.prepare('SELECT * FROM lists WHERE user_id=? ORDER BY id').all(uid),
 tasks:db.prepare('SELECT * FROM inbox WHERE user_id=? ORDER BY id').all(uid).map(taskWithSchedule),
 blocks:db.prepare('SELECT * FROM blocks WHERE user_id=? ORDER BY id').all(uid),schedule:getUserSchedule(uid),server_time:new Date().toISOString()};
}
function allowed(method,path){
 if(method==='POST'&&/^\/api\/(inbox|blocks|lists)$/.test(path))return true;
 if(['PATCH','DELETE'].includes(method)&&/^\/api\/(inbox|blocks|lists)\/\d+$/.test(path))return true;
 if(method==='POST'&&/^\/api\/trash\/(task|block)\/\d+\/restore$/.test(path))return true;
 if(method==='DELETE'&&/^\/api\/(trash\/(task|block)|done)\/\d+$/.test(path))return true;
 return (method==='PUT'&&path==='/api/schedule') || (method==='PATCH'&&['/api/me','/api/account/privacy'].includes(path));
}
export function mountOfflineSync(app,auth){
 app.get('/api/sync/snapshot',auth,(req,res)=>res.json(snapshot(req.user.uid)));
 // The whitelist contains synchronous business routes only. Reuse their validation
 // and deletion semantics; their JSON response commits the mutation and receipt together.
 app.post('/api/sync/mutation',auth,(req,res,next)=>{
  const op=req.body,uid=req.user.uid;
  const generation = betaGeneration();
  if (generation && op?.generation !== generation) {
    return res.status(409).json({code:'DATASET_REFRESHED',error:'测试数据已更新，正在读取最新内容',snapshot:snapshot(uid)});
  }
  if(op?.uid!==uid)return res.status(401).json({code:'SESSION_INVALID',error:'请重新登录原账号后同步'});
  if(!op || !/^[A-Za-z0-9-]{16,100}$/.test(op.id||'') || !allowed(op.method,op.path))return res.status(400).json({error:'无效的同步操作'});
  if(op.body!=null&&(typeof op.body!=='object'||Array.isArray(op.body)))return res.status(400).json({error:'操作内容必须为对象'});
  if(op.base!=null&&(typeof op.base!=='object'||Array.isArray(op.base)))return res.status(400).json({error:'原始版本必须为对象'});
  for(const [key,max] of Object.entries({title:300,name:100,notes:10000,color:32,emoji:32,source:64})){
    const value=op.body?.[key];if(value!=null&&(typeof value!=='string'||value.length>max))return res.status(400).json({error:`${key} 格式不正确或过长`});
  }
  const hash=createHash('sha256').update(stable(op)).digest('hex');
  const old=db.prepare('SELECT * FROM sync_receipts WHERE user_id=? AND op_id=?').get(uid,op.id);
  if(old)return old.request_hash===hash?res.json({...JSON.parse(old.response),snapshot:snapshot(uid)}):res.status(409).json({code:'OP_ID_REUSED',error:'同步操作标识已用于其他内容'});
  const current=clone(entity(uid,op.path));
  const creating=op.method==='POST'&&/^\/api\/(inbox|blocks|lists)$/.test(op.path);
  let body=clone(op.body||{});
  if(!creating){
   if(!Object.hasOwn(op,'base'))return res.status(400).json({error:'缺少原始版本'});
   const affectsRestoredState=/^\/api\/(blocks|trash\/block)\//.test(op.path) ||
     /^\/api\/(inbox|trash\/task|done)\//.test(op.path) &&
       (op.method!=='PATCH'||Object.hasOwn(body,'schedule')||Object.hasOwn(body,'done'));
   if(affectsRestoredState && current && (current.restore_epoch??0)!==(op.base?.restore_epoch??0))
    return res.status(409).json({code:'SYNC_CONFLICT',error:'这项安排已经撤销并恢复，请核对最新内容后再修改',current,fields:['schedule']});
   if(op.method==='PATCH'&&current&&op.base){
    const conflicts=[];
    for(const key of Object.keys(body)){
     const normalize=v=>key==='done'?(v?1:0):key==='schedule'&&v?{date:v.date,start_min:v.start_min,end_min:v.end_min}:v;
     const before=normalize(op.base[key]),now=normalize(current[key]),desired=normalize(body[key]);
     if(equal(before,desired)){delete body[key];continue;}
     if(!equal(before,now)&&!equal(now,desired))conflicts.push(key);
    }
    if(!!current.deleted_at!==!!op.base.deleted_at)conflicts.push('deleted_at');
    if(conflicts.length)return res.status(409).json({code:'SYNC_CONFLICT',error:'同一内容已在其他设备修改',current,fields:conflicts});
   }else if(!equal(comparable(current),comparable(op.base)))return res.status(409).json({code:'SYNC_CONFLICT',error:current?'线上内容已变化':'该内容已在线上删除',current});
  }
  const originalJson=res.json.bind(res);
  db.exec('SAVEPOINT offline_mutation');
  let closed=false;
  const rollback=()=>{if(!closed){closed=true;db.exec('ROLLBACK TO offline_mutation; RELEASE offline_mutation');}};
  res.json=data=>{
   if(res.statusCode>=400){rollback();return originalJson(data);}
   try{
    const response={result:data,snapshot:snapshot(uid)};
    db.prepare('INSERT INTO sync_receipts VALUES(?,?,?,?)').run(uid,op.id,hash,JSON.stringify({result:data}));
    db.exec('RELEASE offline_mutation');closed=true;
    return originalJson(response);
   }catch(e){rollback();throw e;}
  };
  res.on('close',rollback);
  if(op.method==='PATCH'&&Object.keys(body).length===0)return res.json({ok:true,...(current?.id?{id:current.id}:{}),...(op.path.startsWith('/api/inbox/')?{task:current}:{})});
  req.method=op.method;req.url=op.path;req.body=body;req.offlineReplay=true;
  next();
 });
}

import jwt from 'jsonwebtoken';
import bcrypt from 'bcryptjs';
import {randomBytes,createHash} from 'node:crypto';
import {db} from './db.js';
import {purgeCommunityUser} from './community.js';
import {betaAllowed, isBeta} from './beta.js';

const secret=process.env.JWT_SECRET;
if(!secret || (process.env.NODE_ENV==='production' && (secret.length<32 || secret==='dev-secret-change-me')))
  throw new Error('JWT_SECRET must be configured; production requires at least 32 characters');
const origin=process.env.PUBLIC_ORIGIN || 'https://ddlkiller.com';
const allowedOrigins=new Set([origin,process.env.LEGACY_PUBLIC_ORIGIN,process.env.APP_ORIGIN].filter(Boolean));
const cookieName='__Host-ddl_session';
const lifetime=30*86400;
db.exec(`CREATE TABLE IF NOT EXISTS sessions (
 id TEXT PRIMARY KEY,user_id INTEGER NOT NULL,created_at INTEGER NOT NULL,expires_at INTEGER NOT NULL);
 CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
 CREATE TABLE IF NOT EXISTS auth_limits (key TEXT PRIMARY KEY,count INTEGER NOT NULL,expires_at INTEGER NOT NULL);`);
export const asyncRoute=fn=>(req,res,next)=>Promise.resolve(fn(req,res,next)).catch(next);
export const validPassword=p=>typeof p==='string' && p.length>=12 && Buffer.byteLength(p,'utf8')<=72;
export const passwordError=p=>typeof p!=='string'||p.length<12
 ?'密码至少需要12个字符'
 :Buffer.byteLength(p,'utf8')>72?'密码太长，请缩短一些。只使用英文字母、数字和英文符号时最多72个，中文通常最多24个。':null;
const validLogin=p=>typeof p==='string' && p.length>0 && Buffer.byteLength(p,'utf8')<=72;
const validUsername=u=>typeof u==='string' && /^[A-Za-z0-9_]{2,32}$/.test(u);
const dummyHash=bcrypt.hashSync(randomBytes(24).toString('hex'),10);
const cookieOptions={httpOnly:true,secure:true,sameSite:'strict',path:'/'};
function clearCookie(res){res.clearCookie(cookieName,cookieOptions);}
export function issueSession(user) {
 const now=Date.now(),sid=randomBytes(32).toString('hex');
 db.prepare('DELETE FROM sessions WHERE expires_at<=?').run(now);
 db.prepare('INSERT INTO sessions VALUES(?,?,?,?)').run(sid,user.id,now,now+lifetime*1000);
 // Bound stored sessions without exposing session identifiers in any API.
 db.prepare('DELETE FROM sessions WHERE user_id=? AND id NOT IN (SELECT id FROM sessions WHERE user_id=? ORDER BY created_at DESC LIMIT 30)').run(user.id,user.id);
 return jwt.sign({uid:user.id,username:user.username,sid},secret,{algorithm:'HS256',expiresIn:lifetime});
}
export function issueMcpInternalSession(principal, username) {
 return jwt.sign({
  uid:principal.userId,username,aud:'mcp-internal',client_id:principal.clientId,scopes:principal.scopes,
 },secret,{algorithm:'HS256',expiresIn:300});
}
export function auth(req,res,next) {
 const h=req.headers.authorization;
 const fromHeader=typeof h==='string' && h.startsWith('Bearer ');
 const cookie=(req.headers.cookie || '').split(';').map(x=>x.trim()).find(x=>x.startsWith(cookieName+'='));
 const token=fromHeader?h.slice(7):cookie?.slice(cookieName.length+1);
 if(!token)return res.status(401).json({error:'未登录',code:'SESSION_INVALID'});
 if(!fromHeader && !['GET','HEAD','OPTIONS'].includes(req.method) && !allowedOrigins.has(req.headers.origin))
   return res.status(403).json({error:'请求来源不受信任，请从应用内操作'});
 try {
  const p=jwt.verify(token,secret,{algorithms:['HS256']});
  if (!betaAllowed(p.uid) || (isBeta() && p.aud === 'mcp-internal')) {
   return res.status(403).json({error:'此账号暂未开通测试版权限'});
  }
  if(p.aud==='mcp-internal'){
   const client=Number.isSafeInteger(p.uid) && typeof p.client_id==='string' &&
    db.prepare(`SELECT c.id,u.username FROM mcp_clients c JOIN users u ON u.id=c.user_id
      WHERE c.id=? AND c.user_id=? AND c.revoked_at IS NULL AND c.expires_at>?`).get(p.client_id,p.uid,new Date().toISOString());
   if(!client || !Array.isArray(p.scopes))throw new Error('revoked');
   req.user={uid:p.uid,username:client.username,sid:null,mcpClientId:p.client_id,scopes:p.scopes};
   return next();
  }
  const row=typeof p.sid==='string' && Number.isSafeInteger(p.uid) && db.prepare('SELECT s.id,u.username FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.id=? AND s.user_id=? AND s.expires_at>?').get(p.sid,p.uid,Date.now());
  if(!row)throw new Error('revoked');
  req.user={uid:p.uid,username:row.username,sid:p.sid};next();
 } catch {clearCookie(res);return res.status(401).json({error:'登录已失效，请重新登录',code:'SESSION_INVALID'});}
}
export function limit(scope,max,windowMs=15*60000,keyFn=req=>req.ip,options={}) {
 return (req,res,next)=>{
  const now=Date.now();
  db.prepare('DELETE FROM auth_limits WHERE expires_at<=?').run(now);
  const key=createHash('sha256').update(scope+':'+keyFn(req)).digest('hex');
  const row=db.prepare('SELECT count,expires_at FROM auth_limits WHERE key=?').get(key);
  if(row?.count>=max){const seconds=Math.max(1,Math.ceil((row.expires_at-now)/1000));res.set('Retry-After',String(seconds));return res.status(429).json({error:options.message||'尝试过于频繁，请稍后重试',...(options.code?{code:options.code,retryAfterSeconds:seconds}:{})});}
  if(!row && db.prepare('SELECT count(*) n FROM auth_limits').get().n>=50000) return res.status(429).json({error:'服务繁忙，请稍后重试'});
  db.prepare('INSERT INTO auth_limits VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1').run(key,now+windowMs);
  next();
 };
}
export function securityHeaders(req,res,next){
 res.set({'X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','X-Frame-Options':'DENY'});
  if(req.headers.origin && !allowedOrigins.has(req.headers.origin))return res.status(403).json({error:'请求来源不受信任'});
 next();
}
export async function requireRecentLogin(user,maxAge,password){
 if(!user?.sid)return false;
 const session=db.prepare('SELECT created_at FROM sessions WHERE id=? AND user_id=?').get(user.sid,user.uid);
 if(!session)return false;
 if(Date.now()-session.created_at<=maxAge)return true;
 const account=db.prepare('SELECT password_hash FROM users WHERE id=?').get(user.uid);
 if(!account || !validLogin(password) || !await bcrypt.compare(password,account.password_hash))return false;
 db.prepare('UPDATE sessions SET created_at=? WHERE id=? AND user_id=?').run(Date.now(),user.sid,user.uid);
 return true;
}
function tableExists(name){return !!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name);}
function deleteAiRows(table,uid){if(tableExists(table))db.prepare(`DELETE FROM ${table} WHERE user_id=?`).run(uid);}
function purgeAccount(uid){
 db.exec('SAVEPOINT delete_account');
 try {
  purgeCommunityUser(uid);
  if(tableExists('email_challenges')){const email=db.prepare('SELECT email FROM users WHERE id=?').get(uid)?.email;if(email)db.prepare('DELETE FROM email_challenges WHERE email=? OR old_email=?').run(email,email);}
  if(tableExists('ai_generation_attempts'))db.prepare('UPDATE ai_generation_attempts SET user_id=NULL WHERE user_id=?').run(uid);
  if(tableExists('ai_invites')) db.prepare('UPDATE ai_invites SET user_id=NULL,revoked_at=COALESCE(revoked_at,?) WHERE user_id=?').run(Date.now(),uid);
  db.prepare('DELETE FROM reminder_deliveries WHERE task_id IN (SELECT id FROM inbox WHERE user_id=?) OR endpoint IN (SELECT endpoint FROM push_subscriptions WHERE user_id=?)').run(uid,uid);
  db.prepare('DELETE FROM mcp_credentials WHERE client_id IN (SELECT id FROM mcp_clients WHERE user_id=?)').run(uid);
  db.prepare('DELETE FROM schedule_drafts WHERE user_id=?').run(uid);
  db.prepare('DELETE FROM mcp_oauth_requests WHERE user_id=?').run(uid);
  db.prepare('DELETE FROM mcp_oauth_codes WHERE user_id=?').run(uid);
  db.prepare('DELETE FROM mcp_audit_log WHERE user_id=?').run(uid);
  db.prepare('DELETE FROM mcp_clients WHERE user_id=?').run(uid);
  for(const table of ['ai_plan_applications','ai_planning_preferences','asr_daily_usage','ai_planning_turns','ai_planning_sessions','ai_quota_reservations','ai_quota_daily','ai_audit_log','ai_provider_configs'])deleteAiRows(table,uid);
  for(const table of ['email_challenges','email_jobs'])deleteAiRows(table,uid);
  for(const table of ['sync_receipts','push_subscriptions','sessions','blocks','inbox','lists','schedules'])db.prepare(`DELETE FROM ${table} WHERE user_id=?`).run(uid);
  db.prepare('DELETE FROM users WHERE id=?').run(uid);
  db.exec('RELEASE delete_account');
 }catch(e){db.exec('ROLLBACK TO delete_account; RELEASE delete_account');throw e;}
}
export function mountSecurity(app){
 app.get('/api/account/privacy',auth,(req,res)=>res.json({hide_notification_content:db.prepare('SELECT hide_notification_content FROM users WHERE id=?').get(req.user.uid).hide_notification_content===1}));
 app.patch('/api/account/privacy',auth,(req,res)=>{
  if(typeof req.body?.hide_notification_content!=='boolean')return res.status(400).json({error:'设置格式不正确'});
  db.prepare('UPDATE users SET hide_notification_content=? WHERE id=?').run(req.body.hide_notification_content?1:0,req.user.uid);
  res.json({ok:true});
 });
 app.post('/api/auth/login',limit('login-ip',120),limit('login-account-ip',10,15*60000,req=>req.ip+':'+String(req.body?.username).toLowerCase()),asyncRoute(async(req,res)=>{
  const {username,password,client}=req.body || {};
  if(!validUsername(username)||!validLogin(password))return res.status(400).json({error:'账号或密码格式不正确'});
  if(client==='web' && !allowedOrigins.has(req.headers.origin))return res.status(403).json({error:'请从本站登录'});
  const user=db.prepare('SELECT * FROM users WHERE username=?').get(username);
  const ok=await bcrypt.compare(password,user?.password_hash || dummyHash);
  if(!user || !ok)return res.status(401).json({error:'账号或密码错误'});
  if (!betaAllowed(user.id)) return res.status(403).json({error:'此账号暂未开通测试版权限'});
  if(!db.prepare('SELECT 1 FROM users WHERE id=? AND password_hash=?').get(user.id,user.password_hash))return res.status(401).json({error:'账号状态已改变，请重新登录'});
  const token=issueSession(user);
  if(client==='web'){res.cookie(cookieName,token,{...cookieOptions,maxAge:lifetime*1000});return res.json({uid:user.id});}
  res.json({token});
 }));
 app.get('/api/auth/session',auth,(req,res)=>res.json({uid:req.user.uid}));
 app.post('/api/auth/logout',auth,(req,res)=>{db.prepare('DELETE FROM sessions WHERE id=?').run(req.user.sid);clearCookie(res);res.json({ok:true});});
 app.post('/api/auth/logout-all',auth,limit('logout-all',10), (req,res)=>{
  db.prepare('DELETE FROM sessions WHERE user_id=?').run(req.user.uid);
  db.prepare('DELETE FROM push_subscriptions WHERE user_id=?').run(req.user.uid);
  clearCookie(res);res.json({ok:true});
 });
 app.post('/api/auth/password',auth,limit('password',8,15*60000,req=>String(req.user.uid)),asyncRoute(async(req,res)=>{
  const {old_password,new_password}=req.body || {};
  if(!validPassword(new_password))return res.status(400).json({error:passwordError(new_password)});
  const u=db.prepare('SELECT password_hash,email FROM users WHERE id=?').get(req.user.uid);
  if(!validLogin(old_password)||!await bcrypt.compare(old_password,u.password_hash))return res.status(401).json({error:'原密码错误'});
  const hash=await bcrypt.hash(new_password,10);
  db.exec('SAVEPOINT change_password');
  try{
   // Another request may have changed this password while bcrypt was running.
   if(!db.prepare('SELECT 1 FROM sessions WHERE id=? AND user_id=?').get(req.user.sid,req.user.uid))throw new Error('Session revoked');
   const changed=db.prepare('UPDATE users SET password_hash=? WHERE id=? AND password_hash=?').run(hash,req.user.uid,u.password_hash);
   if(changed.changes!==1)throw new Error('Account changed concurrently');
   db.prepare('DELETE FROM sessions WHERE user_id=?').run(req.user.uid);
   db.prepare('DELETE FROM push_subscriptions WHERE user_id=?').run(req.user.uid);
   if(tableExists('email_challenges'))db.prepare('UPDATE email_challenges SET used_at=? WHERE user_id=? AND used_at IS NULL').run(Date.now(),req.user.uid);
   const currentEmail=db.prepare('SELECT email FROM users WHERE id=?').get(req.user.uid)?.email;
   if(currentEmail)app.locals.email?.enqueue({uid:req.user.uid,to:currentEmail,purpose:'password_changed'});
   db.exec('RELEASE change_password');
  }catch(e){db.exec('ROLLBACK TO change_password; RELEASE change_password');throw e;}
  clearCookie(res);res.json({ok:true});
 }));
 const verifyPassword=asyncRoute(async(req,res,next)=>{
  const u=db.prepare('SELECT password_hash FROM users WHERE id=?').get(req.user.uid);
  if(!validLogin(req.body?.password)||!await bcrypt.compare(req.body.password,u.password_hash))return res.status(401).json({error:'密码不正确'});
  if(!db.prepare('SELECT 1 FROM sessions WHERE id=? AND user_id=?').get(req.user.sid,req.user.uid))return res.status(401).json({error:'登录已失效'});
  next();
 });
 app.post('/api/account/export',auth,limit('export',5,15*60000,req=>String(req.user.uid)),verifyPassword,(req,res)=>{
  const uid=req.user.uid;
  res.json({format:'ddl-killer-export-v1',exported_at:new Date().toISOString(),
   profile:db.prepare('SELECT username,nickname,avatar,email,email_verified_at,created_at FROM users WHERE id=?').get(uid),
   lists:db.prepare('SELECT * FROM lists WHERE user_id=?').all(uid),
   tasks:db.prepare('SELECT * FROM inbox WHERE user_id=?').all(uid),
   blocks:db.prepare('SELECT * FROM blocks WHERE user_id=?').all(uid),
   schedule:db.prepare('SELECT json FROM schedules WHERE user_id=?').get(uid)?.json || null});
 });
 app.delete('/api/account',auth,limit('delete-account',5,15*60000,req=>String(req.user.uid)),verifyPassword,(req,res)=>{
  if(req.body.confirmation!=='删除我的账号')return res.status(400).json({error:'请输入“删除我的账号”确认'});
  purgeAccount(req.user.uid);clearCookie(res);res.json({ok:true});
 });
}

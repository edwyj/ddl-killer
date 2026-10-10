import {randomUUID,randomInt,createHmac,timingSafeEqual} from 'node:crypto';
import bcrypt from 'bcryptjs';
import {db} from './db.js';
import {auth,limit,asyncRoute,validPassword,passwordError} from './security.js';
import {betaAllowed,isBeta} from './beta.js';
import {createUserWithDefaultLists} from './default-lists.js';
import {normalizeEmail,emailMask,createEmailService} from './email-service.js';
import {migrateEmailQueue} from './email-schema.js';

// Migration is additive; old accounts remain usable without an email.
const columns=new Set(db.prepare('PRAGMA table_info(users)').all().map(c=>c.name));
if(!columns.has('email'))db.exec('ALTER TABLE users ADD COLUMN email TEXT');
if(!columns.has('email_verified_at'))db.exec('ALTER TABLE users ADD COLUMN email_verified_at INTEGER');
db.exec(`CREATE UNIQUE INDEX IF NOT EXISTS users_verified_email ON users(email) WHERE email IS NOT NULL;
 CREATE TABLE IF NOT EXISTS email_challenges(id TEXT PRIMARY KEY,purpose TEXT NOT NULL,email TEXT NOT NULL,user_id INTEGER,code_hash TEXT NOT NULL,account_hash TEXT,old_email TEXT,expires_at INTEGER NOT NULL,used_at INTEGER,attempts INTEGER NOT NULL DEFAULT 0);
 CREATE INDEX IF NOT EXISTS email_challenge_lookup ON email_challenges(purpose,email,expires_at);`);
migrateEmailQueue(db);
const digest=(id,code)=>createHmac('sha256',process.env.JWT_SECRET).update('email-code:'+id+':'+code).digest('hex');
export function mountEmailAccount(app,verifyCaptcha,options={}) {
 const mail=createEmailService(options);app.locals.email=mail;
 const message='如果这个邮箱已绑定账号，你会收到验证码。';
 const invalid=res=>res.status(400).json({error:'验证码不正确或已失效，请重新获取',code:'EMAIL_CODE_INVALID'});
 const rate=limit('email-send-ip',15,3600000,undefined,{code:'EMAIL_RATE_LIMITED'});
 const accountRate=limit('email-send-account',10,3600000,req=>String(req.user.uid),{code:'EMAIL_RATE_LIMITED'});
 const confirmRate=limit('email-confirm-ip',30,900000,undefined,{code:'EMAIL_RATE_LIMITED'});
 function issue(purpose,email,user,send=true) {
  const time=mail.now();const previous=db.prepare('SELECT expires_at FROM email_challenges WHERE email=? AND purpose=? ORDER BY expires_at DESC LIMIT 1').get(email,purpose);
  if(previous&&previous.expires_at-600000+60000>time){const seconds=Math.ceil((previous.expires_at-600000+60000-time)/1000);const error=new Error('请稍等一会儿再获取验证码');error.status=429;error.seconds=seconds;throw error;}
  const recent=db.prepare('SELECT count(*) n FROM email_challenges WHERE email=? AND expires_at>?').get(email,time-86400000+600000).n;
  if(recent>=10){const e=new Error('今天的验证邮件已达到上限，请明天再试');e.status=429;e.seconds=86400;throw e;}
  const id=randomUUID(),code=String(randomInt(100000,1000000));
  // Binding proofs belong to the requesting account: another person requesting
  // the same mailbox must not invalidate a code its owner is already entering.
  if(purpose==='bind'||purpose==='bind_old')db.prepare('UPDATE email_challenges SET used_at=? WHERE email=? AND purpose=? AND user_id=? AND used_at IS NULL').run(time,email,purpose,user.id);
  else db.prepare('UPDATE email_challenges SET used_at=? WHERE email=? AND purpose=? AND used_at IS NULL').run(time,email,purpose);
  db.prepare('INSERT INTO email_challenges(id,purpose,email,user_id,code_hash,account_hash,old_email,expires_at) VALUES(?,?,?,?,?,?,?,?)')
   .run(id,purpose,email,user?.id||null,digest(id,code),user?.password_hash||null,user?.email||null,time+600000);
  if(send){if(!mail.enqueue({uid:user?.id,to:email,purpose:purpose==='bind_old'?'bind':purpose,code,requestId:id})){const e=new Error('暂时无法发送验证邮件，请稍后重试');e.status=503;throw e;}}
  // Uniform reservation also prevents probing account existence via remaining quota.
  if(!send&&!mail.reserve()){const e=new Error('暂时无法发送验证邮件，请稍后重试');e.status=503;throw e;}
  return id;
 }
 function usable(id,purpose,email,userId,code) {
  if(typeof id!=='string'||id.length>64||typeof code!=='string'||!/^\d{6}$/.test(code))return null;
  const c=db.prepare('SELECT * FROM email_challenges WHERE id=?').get(id);
  if(!c||c.purpose!==purpose||c.email!==email||c.user_id!==userId||c.used_at!==null||c.expires_at<=mail.now()||c.attempts>=5)return null;
  db.prepare('UPDATE email_challenges SET attempts=attempts+1 WHERE id=?').run(id);
  const actual=Buffer.from(digest(id,code),'hex'),expected=Buffer.from(c.code_hash,'hex');
  return timingSafeEqual(actual,expected)?c:null;
 }
 function invalidate(uid){db.prepare('UPDATE email_challenges SET used_at=? WHERE user_id=? AND used_at IS NULL').run(mail.now(),uid);}
 function transaction(fn){db.exec('SAVEPOINT email_operation');try{const result=fn();db.exec('RELEASE email_operation');return result;}catch(e){db.exec('ROLLBACK TO email_operation; RELEASE email_operation');throw e;}}
 async function account(req,res){const u=db.prepare('SELECT * FROM users WHERE id=?').get(req.user.uid);if(!req.user.sid||!u||typeof req.body?.password!=='string'||Buffer.byteLength(req.body.password,'utf8')>72||!await bcrypt.compare(req.body.password,u.password_hash)){res.status(401).json({error:'当前密码不正确'});return null;}
  if(!db.prepare('SELECT 1 FROM sessions WHERE id=? AND user_id=?').get(req.user.sid,u.id)||!db.prepare('SELECT 1 FROM users WHERE id=? AND password_hash=? AND email IS ?').get(u.id,u.password_hash,u.email)){res.status(409).json({error:'账号状态已改变，请重新登录'});return null;}return u;}
 function guarded(fn){return asyncRoute(async(req,res)=>{try{await fn(req,res);}catch(e){if(e.status){if(e.seconds)res.set('Retry-After',String(e.seconds));return res.status(e.status).json({error:e.message,code:e.status===429?'EMAIL_RATE_LIMITED':'EMAIL_UNAVAILABLE',retryAfterSeconds:e.seconds});}throw e;}});}
 app.get('/api/auth/email/config',(req,res)=>res.json({enabled:mail.enabled,registration_requires_email:true}));
 app.get('/api/account/email',auth,(req,res)=>{const u=db.prepare('SELECT email FROM users WHERE id=?').get(req.user.uid);res.json({bound:!!u.email,masked_email:emailMask(u.email),enabled:mail.enabled});});
 app.post('/api/auth/email/register',rate,guarded(async(req,res)=>{
  if(isBeta())return res.status(403).json({error:'测试版不开放新账号注册'});
  if(!verifyCaptcha(req.body?.captcha_id,req.body?.captcha_code))return res.status(400).json({error:'图形验证码错误或已过期'});
  const email=normalizeEmail(req.body?.email);if(!email)return res.status(400).json({error:'请填写有效的邮箱地址'});
  // Registration is unauthenticated, so the response stays uniform: it must not
  // become an oracle for "does this address already have an account?". But the old
  // message was uniform AND useless — an occupied address got no mail and no
  // explanation, so the person simply waited. The added clause is still uniform
  // (it says nothing about *this* address) while telling them what to do next.
  if(!mail.available(email)||!mail.capacity())return res.status(503).json({error:'邮箱验证服务暂时不可用，请稍后再试'});
  const occupied=db.prepare('SELECT id FROM users WHERE email=?').get(email);
  const id=transaction(()=>issue('register',email,null,!occupied));res.json({request_id:id,resend_after:60,message:'如果这个邮箱可以注册，你会收到验证码；若一直收不到，它可能已经注册过了，请直接登录或用邮箱找回。'});
 }));
 // Replaces the old unauthenticated registration route; no unverified fallback.
 app.post('/api/auth/register',confirmRate,guarded(async(req,res)=>{
  const {username,password,request_id,code}=req.body||{},email=normalizeEmail(req.body?.email);
  if(typeof username!=='string'||!/^[A-Za-z0-9_]{2,32}$/.test(username))return res.status(400).json({error:'用户名需2-32位字母、数字或下划线'});
  if(!email)return res.status(400).json({error:'请填写有效的邮箱地址'});
  if(!validPassword(password))return res.status(400).json({error:passwordError(password)});
  const c=usable(request_id,'register',email,null,code);if(!c)return invalid(res);
  const hash=await bcrypt.hash(password,10);
  try{transaction(()=>{const latest=db.prepare('SELECT used_at,expires_at FROM email_challenges WHERE id=?').get(c.id);if(!latest||latest.used_at!==null||latest.expires_at<=mail.now())throw new Error('STALE_EMAIL_CODE');
   const uid=createUserWithDefaultLists(username,hash);db.prepare('UPDATE users SET email=?,email_verified_at=? WHERE id=?').run(email,mail.now(),uid);
   db.prepare('UPDATE email_challenges SET used_at=? WHERE email=? AND purpose=?').run(mail.now(),email,'register');});
  }catch(e){if(/users\.username/.test(e.message))return res.status(409).json({error:'用户名已被占用'});
   // The address was free when the code was requested but taken by the time it was
   // entered. Old code folded this into EMAIL_CODE_INVALID, so the person was told
   // their correct code was wrong and would retry forever.
   if(/users\.email|users_verified_email/.test(e.message))return res.status(409).json({error:'这个邮箱已经绑定了其他账号，请换一个邮箱',code:'EMAIL_TAKEN'});
   if(/STALE_EMAIL_CODE/.test(e.message))return invalid(res);throw e;}
  res.json({ok:true,username});
 }));
 app.post('/api/account/email/code',auth,rate,accountRate,guarded(async(req,res)=>{
  const u=await account(req,res);if(!u)return;const email=normalizeEmail(req.body?.email);if(!email)return res.status(400).json({error:'请填写有效的邮箱地址'});
  if(email===u.email)return res.status(400).json({error:'这已经是你绑定的邮箱'});
  // Login proves the caller's identity, not ownership of the target mailbox.
  // Send proof for both free and occupied addresses; disclose conflicts only after
  // mailbox verification. The unique index still prevents taking another account's email.
  if(!mail.available(email)||(u.email&&!mail.available(u.email)))return res.status(503).json({error:'测试版只能向允许的测试邮箱发信，或发信服务暂不可用'});
  if(!mail.capacity(u.email?2:1))return res.status(503).json({error:'验证邮件暂时无法发送，请稍后再试'});
  const ids=transaction(()=>({request_id:issue('bind',email,u),old_request_id:u.email?issue('bind_old',u.email,u):null}));res.json({...ids,resend_after:60,message:u.email?'验证码请求已提交，请用原邮箱和新邮箱收到的验证码继续验证。':'验证码请求已提交，收到后请填写验证码继续验证。'});
 }));
 app.post('/api/account/email',auth,confirmRate,guarded(async(req,res)=>{
  const u=await account(req,res);if(!u)return;const email=normalizeEmail(req.body?.email),c=usable(req.body?.request_id,'bind',email,u.id,req.body?.code);
  if(!c||c.account_hash!==u.password_hash||c.old_email!==u.email)return invalid(res);
  if(u.email){const old=usable(req.body.old_request_id,'bind_old',u.email,u.id,req.body.old_code);if(!old||old.account_hash!==u.password_hash)return invalid(res);}
  try{transaction(()=>{const changed=db.prepare('UPDATE users SET email=?,email_verified_at=? WHERE id=? AND password_hash=? AND email IS ?').run(email,mail.now(),u.id,u.password_hash,u.email);if(changed.changes!==1)throw new Error('STALE_EMAIL_CODE');invalidate(u.id);
   if(u.email)mail.enqueue({uid:u.id,to:u.email,purpose:'email_changed'});});}catch(e){
   if(/users\.email|users_verified_email/.test(e.message))return res.status(409).json({error:'这个邮箱已经绑定了其他账号，请换一个邮箱',code:'EMAIL_TAKEN'});
   if(/STALE_EMAIL_CODE/.test(e.message))return invalid(res);throw e;}
  res.json({ok:true});
 }));
 app.post('/api/auth/email/reset',rate,guarded(async(req,res)=>{
  if(!verifyCaptcha(req.body?.captcha_id,req.body?.captcha_code))return res.status(400).json({error:'图形验证码错误或已过期'});
  const email=normalizeEmail(req.body?.email);if(!email)return res.status(400).json({error:'请填写有效的邮箱地址'});
  if(!mail.available(email)||!mail.capacity())return res.status(503).json({error:'邮箱验证服务暂时不可用，测试版请使用指定测试邮箱'});
  const u=db.prepare('SELECT * FROM users WHERE email=?').get(email);const eligible=u&&betaAllowed(u.id)?u:null;
  const id=transaction(()=>issue('reset',email,eligible,!!eligible));res.json({request_id:id,resend_after:60,message});
 }));
 app.post('/api/auth/email/reset-confirm',confirmRate,guarded(async(req,res)=>{
  const email=normalizeEmail(req.body?.email);if(!validPassword(req.body?.new_password))return res.status(400).json({error:passwordError(req.body?.new_password)});
  const u=db.prepare('SELECT * FROM users WHERE email=?').get(email);const c=usable(req.body?.request_id,'reset',email,u?.id||null,req.body?.code);
  if(!u||!betaAllowed(u.id)||!c||c.account_hash!==u.password_hash||c.old_email!==u.email)return invalid(res);
  const hash=await bcrypt.hash(req.body.new_password,10);
  try{transaction(()=>{const latest=db.prepare('SELECT used_at,expires_at FROM email_challenges WHERE id=?').get(c.id);if(!latest||latest.used_at!==null||latest.expires_at<=mail.now())throw new Error('STALE_EMAIL_CODE');
   const changed=db.prepare('UPDATE users SET password_hash=? WHERE id=? AND password_hash=? AND email=?').run(hash,u.id,u.password_hash,email);if(changed.changes!==1)throw new Error('STALE_EMAIL_CODE');
   db.prepare('DELETE FROM sessions WHERE user_id=?').run(u.id);db.prepare('DELETE FROM push_subscriptions WHERE user_id=?').run(u.id);invalidate(u.id);mail.enqueue({uid:u.id,to:email,purpose:'password_changed'});});}catch(e){if(e.message==='STALE_EMAIL_CODE')return invalid(res);throw e;}
  res.clearCookie('__Host-ddl_session',{httpOnly:true,secure:true,sameSite:'strict',path:'/'});res.json({ok:true,username:u.username});
 }));
 return mail;
}

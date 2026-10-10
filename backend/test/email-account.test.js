import test from 'node:test';
import assert from 'node:assert/strict';
process.env.DB_PATH=':memory:';process.env.JWT_SECRET='email-test-secret-only-32-characters';
const svgCaptcha=(await import('svg-captcha')).default;const realCaptcha=svgCaptcha.create;let lastCaptcha;svgCaptcha.create=opts=>{const c=realCaptcha(opts);lastCaptcha=c.text;return c;};
const {createApp}=await import('../src/app.js');const {db}=await import('../src/db.js');
const {createUserWithDefaultLists}=await import('../src/default-lists.js');
const bcrypt=(await import('bcryptjs')).default;
const sent=[];let clock=Date.now();
const app=createApp({email:{send:async mail=>{sent.push(mail);return 'test-message';},now:()=>clock}});
const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));
const base=`http://127.0.0.1:${server.address().port}`;
test.after(()=>{server.close();db.close();});
// Each case has its own IP-budget window; per-mailbox cooldown remains tested.
test.beforeEach(()=>db.prepare('DELETE FROM auth_limits').run());
async function call(path,body,token,method='POST') {if(path==='/api/auth/email/reset'){const cap=await (await fetch(base+'/api/auth/captcha')).json();body={...body,captcha_id:cap.id,captcha_code:lastCaptcha};}const r=await fetch(base+path,{method,headers:{'content-type':'application/json',...(token?{authorization:`Bearer ${token}`}:{})},...(body?{body:JSON.stringify(body)}:{})});return {status:r.status,data:await r.json()};}
const owner=createUserWithDefaultLists('mail_owner',bcrypt.hashSync('Owner-password-123',10));
const other=createUserWithDefaultLists('mail_other',bcrypt.hashSync('Other-password-123',10));
const login=async(name='mail_owner',password='Owner-password-123')=>(await call('/api/auth/login',{username:name,password})).data.token;
async function request(email,token,password='Owner-password-123') {const r=await call('/api/account/email/code',{email,password},token);assert.equal(r.status,200);await app.locals.email.flush();return r.data;}
function code(to,purpose) {return sent.findLast(m=>m.to===to&&m.purpose===purpose)?.code;}
test('new registration requires a verified email',async()=>{
 const r=await call('/api/auth/register',{username:'new_mail_user',password:'Owner-password-123'});assert.equal(r.status,400);assert.equal(db.prepare('SELECT id FROM users WHERE username=?').get('new_mail_user'),undefined);
});
test('binding requires password, verifies code once and never stores plaintext code',async()=>{
 const t=await login();assert.equal((await call('/api/account/email/code',{email:'owner@example.com',password:'wrong'},t)).status,401);
 const q=await request('owner@example.com',t);const c=code('owner@example.com','bind');assert.match(c,/^\d{6}$/);
 assert.ok(!JSON.stringify(db.prepare('SELECT * FROM email_challenges').all()).includes(c));
 assert.equal((await call('/api/account/email',{email:'owner@example.com',password:'Owner-password-123',request_id:q.request_id,code:c},t)).status,200);
 assert.equal(db.prepare('SELECT email FROM users WHERE id=?').get(owner).email,'owner@example.com');
 assert.equal((await call('/api/account/email',{email:'owner@example.com',password:'Owner-password-123',request_id:q.request_id,code:c},t)).status,400);
});
test('reset is purpose-bound, revokes sessions and code replay cannot reset twice',async()=>{
 const t=await login();const q=await call('/api/auth/email/reset',{email:'OWNER@example.com'});assert.equal(q.status,200);await app.locals.email.flush();
 const c=code('owner@example.com','reset');assert.match(c,/^\d{6}$/);
 const payload={email:'owner@example.com',request_id:q.data.request_id,code:c,new_password:'Owner-new-password-123'};
 assert.equal((await call('/api/auth/email/reset-confirm',payload)).status,200);
 assert.equal((await call('/api/me',null,t,'GET')).status,401);
 assert.equal((await call('/api/auth/email/reset-confirm',payload)).status,400);
 assert.ok(await bcrypt.compare(payload.new_password,db.prepare('SELECT password_hash FROM users WHERE id=?').get(owner).password_hash));
});
test('unknown email reset response is indistinguishable and sends nothing',async()=>{
 clock+=60001;const before=sent.length;const q=await call('/api/auth/email/reset',{email:'unknown@example.com'});assert.equal(q.status,200);assert.equal(q.data.message,'如果这个邮箱已绑定账号，你会收到验证码。');await app.locals.email.flush();assert.equal(sent.filter(m=>m.purpose==='reset').length,1);
 const r=await call('/api/auth/email/reset-confirm',{email:'unknown@example.com',request_id:q.data.request_id,code:'123456',new_password:'New-password-123'});assert.equal(r.status,400);
});
test('wrong guesses lock a challenge and resend is throttled',async()=>{
 const t=await login('mail_other','Other-password-123');const q=await request('other@example.com',t,'Other-password-123');
 assert.equal((await call('/api/account/email/code',{email:'other@example.com',password:'Other-password-123'},t)).status,429);
 for(let i=0;i<5;i++)assert.equal((await call('/api/account/email',{email:'other@example.com',password:'Other-password-123',request_id:q.request_id,code:'000000'},t)).status,400);
 assert.equal((await call('/api/account/email',{email:'other@example.com',password:'Other-password-123',request_id:q.request_id,code:code('other@example.com','bind')},t)).status,400);
});
test('expired codes and codes from a different account cannot bind',async()=>{
 clock+=60001;const t=await login('mail_other','Other-password-123');const q=await request('expiry@example.com',t,'Other-password-123');const c=code('expiry@example.com','bind');
 const stranger=await login('mail_owner','Owner-new-password-123');assert.equal((await call('/api/account/email',{email:'expiry@example.com',password:'Owner-new-password-123',request_id:q.request_id,code:c},stranger)).status,400);
 clock+=600001;assert.equal((await call('/api/account/email',{email:'expiry@example.com',password:'Other-password-123',request_id:q.request_id,code:c},t)).status,400);
});

test('change email needs both old and new mailbox proof; other accounts cannot reuse a bound email',async()=>{
 const t=await login('mail_owner','Owner-new-password-123');clock+=60001;
 const q=await request('new-owner@example.com',t,'Owner-new-password-123');const fresh=code('new-owner@example.com','bind'),old=code('owner@example.com','bind');
 const body={email:'new-owner@example.com',password:'Owner-new-password-123',request_id:q.request_id,code:fresh};
 assert.equal((await call('/api/account/email',body,t)).status,400);
 assert.equal(db.prepare('SELECT email FROM users WHERE id=?').get(owner).email,'owner@example.com');
 assert.equal((await call('/api/account/email',{...body,old_request_id:q.old_request_id,old_code:old},t)).status,200);
 clock+=60001;const stranger=await login('mail_other','Other-password-123');
 const otherQ=await call('/api/account/email/code',{email:'new-owner@example.com',password:'Other-password-123'},stranger);
 assert.equal(otherQ.status,200);await app.locals.email.flush();
 const conflict=await call('/api/account/email',{email:'new-owner@example.com',password:'Other-password-123',request_id:otherQ.data.request_id,code:code('new-owner@example.com','bind')},stranger);
 assert.equal(conflict.status,409);assert.equal(conflict.data.code,'EMAIL_TAKEN');
 assert.equal(db.prepare('SELECT email FROM users WHERE id=?').get(owner).email,'new-owner@example.com');
});
test('password change invalidates pending email proof and enqueues a security notification',async()=>{
 clock+=60001;const t=await login('mail_owner','Owner-new-password-123');
 const q=await request('discarded@example.com',t,'Owner-new-password-123');const c=code('discarded@example.com','bind');
 assert.equal((await call('/api/auth/password',{old_password:'Owner-new-password-123',new_password:'Another-new-password-123'},t)).status,200);
 const fresh=await login('mail_owner','Another-new-password-123');
 assert.equal((await call('/api/account/email',{email:'discarded@example.com',password:'Another-new-password-123',request_id:q.request_id,code:c},fresh)).status,400);
 await app.locals.email.flush();assert.ok(sent.some(m=>m.purpose==='password_changed'&&m.to==='new-owner@example.com'));
});
test('known and unknown recovery emails consume the same reservation budget',async()=>{
 clock+=60001;const before=db.prepare('SELECT sum(count) n FROM email_daily').get().n;
 await call('/api/auth/email/reset',{email:'new-owner@example.com'});
 const middle=db.prepare('SELECT sum(count) n FROM email_daily').get().n;
 await call('/api/auth/email/reset',{email:'reservation-unknown@example.com'});
 const after=db.prepare('SELECT sum(count) n FROM email_daily').get().n;
 assert.equal(middle-before,1);assert.equal(after-middle,1);
});
test('daily quota exhaustion does not reveal registered emails',async()=>{
 process.env.EMAIL_DAILY_LIMIT='1';
 const existing=await call('/api/auth/email/reset',{email:'new-owner@example.com'});
 const absent=await call('/api/auth/email/reset',{email:'quota-unknown@example.com'});
 assert.equal(existing.status,503);assert.equal(absent.status,503);assert.deepEqual(existing.data,absent.data);
 delete process.env.EMAIL_DAILY_LIMIT;
});
test('a concurrent email update during password hashing notifies the current mailbox',async()=>{
 const t=await login('mail_owner','Another-new-password-123');
 const originalHash=bcrypt.hash;let release;const gate=new Promise(r=>release=r);let started;const pending=new Promise(r=>started=r);
 bcrypt.hash=async(...args)=>{started();await gate;return originalHash(...args);};
 const change=call('/api/auth/password',{old_password:'Another-new-password-123',new_password:'Final-new-password-123'},t);
 await pending;
 db.prepare('UPDATE users SET email=? WHERE id=?').run('concurrent@example.com',owner);
 release();const response=await change;bcrypt.hash=originalHash;assert.equal(response.status,200);
 await app.locals.email.flush();assert.ok(sent.some(m=>m.to==='concurrent@example.com'&&m.purpose==='password_changed'));
});
test('bound and free binding requests both send proof; ownership is disclosed only after valid codes',async()=>{
 const t=await login('mail_owner','Final-new-password-123');
 db.prepare('UPDATE users SET email=? WHERE id=?').run('bound-other@example.com',other);
 const budget=()=>db.prepare('SELECT coalesce(sum(count),0) n FROM email_daily').get().n;
 const before=budget();
 const known=await call('/api/account/email/code',{email:'bound-other@example.com',password:'Final-new-password-123'},t);
 assert.equal(known.status,200);assert.equal(budget()-before,2);
 await app.locals.email.flush();
 const body={email:'bound-other@example.com',password:'Final-new-password-123',request_id:known.data.request_id,old_request_id:known.data.old_request_id,old_code:code('concurrent@example.com','bind')};
 assert.equal((await call('/api/account/email',{...body,code:'000000'},t)).status,400);
 const conflict=await call('/api/account/email',{...body,code:code('bound-other@example.com','bind')},t);
 assert.equal(conflict.status,409);assert.equal(conflict.data.code,'EMAIL_TAKEN');
 assert.equal(db.prepare('SELECT email FROM users WHERE id=?').get(other).email,'bound-other@example.com');
 assert.equal(db.prepare('SELECT email FROM users WHERE id=?').get(owner).email,'concurrent@example.com');
 clock+=60001;
 const free=await request('missing-other@example.com',t,'Final-new-password-123');
 assert.equal(known.data.message,free.message);assert.equal(known.data.resend_after,free.resend_after);
 assert.match(code('missing-other@example.com','bind'),/^\d{6}$/);
});
test('registration answers identically for a taken and a free address, but points at the way out',async()=>{
 // /api/auth/email/register is unauthenticated, so it must not become an oracle for
 // "does this address have an account": same status, same wording, same quota burn.
 // The wording is uniform yet actionable, so the owner of a taken address is no
 // longer left waiting for a code that was never going to arrive.
 const ask=async email=>{const cap=await (await fetch(base+'/api/auth/captcha')).json();
  return call('/api/auth/email/register',{email,captcha_id:cap.id,captcha_code:lastCaptcha});};
 const budget=()=>db.prepare('SELECT coalesce(sum(count),0) n FROM email_daily').get().n;
 const b0=budget();const taken=await ask('bound-other@example.com');const b1=budget();
 const free=await ask('free-to-register@example.com');const b2=budget();
 assert.equal(taken.status,200);assert.equal(free.status,200);
 assert.equal(taken.data.message,free.data.message);assert.equal(taken.data.resend_after,free.data.resend_after);
 assert.equal(b1-b0,1);assert.equal(b2-b1,1);
 await app.locals.email.flush();
 assert.equal(sent.filter(m=>m.to==='bound-other@example.com'&&m.purpose==='register').length,0);
 assert.equal(sent.filter(m=>m.to==='free-to-register@example.com'&&m.purpose==='register').length,1);
});
test('password change persists its notice even when the sending quota is exhausted',async()=>{
 const uid=createUserWithDefaultLists('notice_fixture',bcrypt.hashSync('Notice-password-123',10));
 db.prepare('UPDATE users SET email=? WHERE id=?').run('notice@example.com',uid);
 const t=await login('notice_fixture','Notice-password-123');process.env.EMAIL_DAILY_LIMIT='1';
 try{
  const result=await call('/api/auth/password',{old_password:'Notice-password-123',new_password:'Notice-next-password-123'},t);
  assert.equal(result.status,200);
  assert.ok(db.prepare("SELECT id FROM email_jobs WHERE user_id=? AND status='queued'").get(uid));
  await app.locals.email.flush();
  assert.ok(!sent.some(m=>m.to==='notice@example.com'));
  clock+=86400001;await app.locals.email.flush();
  assert.ok(sent.some(m=>m.to==='notice@example.com'&&m.purpose==='password_changed'));
 }finally{delete process.env.EMAIL_DAILY_LIMIT;}
});

test('different requesting accounts do not invalidate each others mailbox proof and uniqueness wins a race',async()=>{
 for(const name of ['race_one','race_two'])createUserWithDefaultLists(name,bcrypt.hashSync('Race-password-123',10));
 const a=await login('race_one','Race-password-123'),b=await login('race_two','Race-password-123');
 const qa=await request('race@example.com',a,'Race-password-123'),ca=code('race@example.com','bind');
 clock+=60001;const qb=await request('race@example.com',b,'Race-password-123'),cb=code('race@example.com','bind');
 assert.equal((await call('/api/account/email',{email:'race@example.com',password:'Race-password-123',request_id:qa.request_id,code:ca},a)).status,200);
 const conflict=await call('/api/account/email',{email:'race@example.com',password:'Race-password-123',request_id:qb.request_id,code:cb},b);
 assert.equal(conflict.status,409);assert.equal(conflict.data.code,'EMAIL_TAKEN');
});

test('binding send limit follows the account across different source IPs',async()=>{
 createUserWithDefaultLists('send_limit',bcrypt.hashSync('Limit-password-123',10));
 const t=await login('send_limit','Limit-password-123');
 for(let i=0;i<11;i++){
  const response=await fetch(base+'/api/account/email/code',{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${t}`,'x-forwarded-for':`192.0.2.${i+1}`},body:JSON.stringify({email:`limit-${i}@example.com`,password:'Limit-password-123'})});
  assert.equal(response.status,i<10?200:429);
  if(i===10)assert.equal((await response.json()).code,'EMAIL_RATE_LIMITED');
 }
});

test('account deletion removes bound email and all its pending challenges/jobs',async()=>{
 const t=await login('mail_owner','Final-new-password-123');
 assert.equal((await call('/api/account',{password:'Final-new-password-123',confirmation:'删除我的账号'},t,'DELETE')).status,200);
 assert.equal(db.prepare('SELECT id FROM users WHERE id=?').get(owner),undefined);
 assert.equal(db.prepare('SELECT count(*) n FROM email_jobs WHERE user_id=?').get(owner).n,0);
 assert.equal(db.prepare('SELECT count(*) n FROM email_challenges WHERE user_id=?').get(owner).n,0);
});

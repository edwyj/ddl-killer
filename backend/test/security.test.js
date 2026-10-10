import test from 'node:test';
import assert from 'node:assert/strict';
process.env.APP_ORIGIN='https://app.ddlkiller.com';
process.env.DB_PATH=':memory:';
process.env.JWT_SECRET='security-test-secret-only-32-characters';
process.env.LEGACY_PUBLIC_ORIGIN='https://legacy.example.com';
const {createApp}=await import('../src/app.js');
const {db}=await import('../src/db.js');
const {createUserWithDefaultLists}=await import('../src/default-lists.js');
const bcrypt=(await import('bcryptjs')).default;
const uid=createUserWithDefaultLists('secure_owner',bcrypt.hashSync('Owner-password-123',10));
const other=createUserWithDefaultLists('secure_other',bcrypt.hashSync('Other-password-123',10));
const server=createApp().listen(0,'127.0.0.1');
await new Promise(r=>server.once('listening',r));
test.after(()=>{server.close();db.close();});
const base=`http://127.0.0.1:${server.address().port}`;
async function call(path,method='GET',body,token,headers={}) {
 const r=await fetch(base+path,{method,headers:{'content-type':'application/json',...(token?{authorization:`Bearer ${token}`} :{}),...headers},...(body?{body:JSON.stringify(body)}:{})});
 return {status:r.status,headers:r.headers,data:await r.json()};
}
const login=async(user='secure_owner',password='Owner-password-123',extra={})=>call('/api/auth/login','POST',{username:user,password,...extra});
test('logout revokes one session; password change revokes all sessions',async()=>{
 const a=(await login()).data.token,b=(await login()).data.token;
 assert.equal((await call('/api/auth/logout','POST',{},a)).status,200);
 assert.equal((await call('/api/me','GET',null,a)).status,401);
 assert.equal((await call('/api/me','GET',null,b)).status,200);
 assert.equal((await call('/api/auth/password','POST',{old_password:'Owner-password-123',new_password:'Owner-new-password-123'},b)).status,200);
 assert.equal((await call('/api/me','GET',null,b)).status,401);
 assert.equal((await login()).status,401);
});
test('browser login uses protected cookie; cross-origin writes fail',async()=>{
 const r=await login('secure_other','Other-password-123',{client:'web'});
 assert.equal(r.status,403); // A browser login must prove its origin.
 const good=await call('/api/auth/login','POST',{username:'secure_other',password:'Other-password-123',client:'web'},null,{origin:'https://ddlkiller.com'});
 assert.equal(good.status,200); assert.equal(good.data.token,undefined);
 const appLogin=await call('/api/auth/login','POST',{username:'secure_other',password:'Other-password-123',client:'web'},null,{origin:'https://app.ddlkiller.com'});
 assert.equal(appLogin.status,200);
 const appCookie=appLogin.headers.get('set-cookie').split(';')[0];
 assert.equal((await call('/api/me','PATCH',{nickname:'app-safe'},null,{cookie:appCookie,origin:'https://app.ddlkiller.com'})).status,200);
 const set=good.headers.get('set-cookie'); assert.match(set,/HttpOnly/);assert.match(set,/Secure/);assert.match(set,/SameSite=Strict/);
 const cookie=set.split(';')[0];
 assert.equal((await call('/api/auth/session','GET',null,null,{cookie})).data.uid,other);
 assert.equal((await call('/api/me','PATCH',{nickname:'attack'},null,{cookie,origin:'https://evil.example'})).status,403);
 assert.equal((await call('/api/me','PATCH',{nickname:'safe'},null,{cookie,origin:'https://ddlkiller.com'})).status,200);
 assert.equal((await call('/api/me','PATCH',{nickname:'legacy-safe'},null,{cookie,origin:'https://legacy.example.com'})).status,200);
});
test('export excludes credentials and deletion clears only the owning account',async()=>{
 const token=(await login('secure_owner','Owner-new-password-123')).data.token;
 await call('/api/inbox','POST',{title:'private task'},token);
 const ex=await call('/api/account/export','POST',{password:'Owner-new-password-123'},token);
 assert.equal(ex.status,200);assert.equal(ex.data.tasks.length,1);
 assert.ok(!JSON.stringify(ex.data).includes('password_hash'));
 assert.ok(!JSON.stringify(ex.data).includes('Owner-new-password-123'));
 assert.equal((await call('/api/account','DELETE',{password:'wrong',confirmation:'删除我的账号'},token)).status,401);
 assert.equal((await call('/api/account','DELETE',{password:'Owner-new-password-123',confirmation:'删除我的账号'},token)).status,200);
 for(const table of ['inbox','blocks','lists','schedules','push_subscriptions','sessions']) assert.equal(db.prepare(`SELECT count(*) n FROM ${table} WHERE user_id=?`).get(uid).n,0);
 assert.ok(db.prepare('SELECT id FROM users WHERE id=?').get(other));
 assert.equal((await call('/api/me','GET',null,token)).status,401);
});
test('bounded login failures are rate limited and malformed input is rejected',async()=>{
 assert.equal((await call('/api/auth/login','POST',{username:[],password:{}})).status,400);
 let last;
 for(let i=0;i<12;i++) last=await login('brute_test','not-the-password');
 assert.equal(last.status,429);assert.ok(last.headers.get('retry-after'));
});

test('cross-account IDs cannot read, change, delete or restore another user data',async()=>{
 const owner=createUserWithDefaultLists('isolation_owner',bcrypt.hashSync('Isolation-owner-123',10));
 const token=(await login('isolation_owner','Isolation-owner-123')).data.token;
 const stranger=(await login('secure_other','Other-password-123')).data.token;
 const list=(await call('/api/lists','POST',{name:'Private list'},token)).data.id;
 const task=(await call('/api/inbox','POST',{title:'Private',list_id:list,schedule:{date:'2030-01-01',start_min:600,end_min:660}},token)).data;
 const block=task.task.schedule.id;
 for(const [path,method,body] of [
  [`/api/lists/${list}/tasks`,'GET',null],[`/api/lists/${list}`,'PATCH',{name:'stolen'}],[`/api/lists/${list}`,'DELETE',{}],
  [`/api/inbox/${task.id}`,'PATCH',{title:'stolen'}],[`/api/inbox/${task.id}`,'DELETE',{}],
  [`/api/blocks/${block}`,'PATCH',{title:'stolen'}],[`/api/blocks/${block}`,'DELETE',{}],
  [`/api/done/${task.id}`,'DELETE',{}],[`/api/trash/task/${task.id}/restore`,'POST',{}]
 ]) assert.equal((await call(path,method,body,stranger)).status,404,path);
 assert.equal((await call('/api/inbox','POST',{title:'injection',list_id:list},stranger)).status,400);
 assert.equal(db.prepare('SELECT title FROM inbox WHERE id=?').get(task.id).title,'Private');
 assert.equal(db.prepare('SELECT user_id FROM lists WHERE id=?').get(list).user_id,owner);
});
test('logout-all revokes other sessions and notification preferences hide content by default',async()=>{
 const a=(await login('secure_other','Other-password-123')).data.token;
 const b=(await login('secure_other','Other-password-123')).data.token;
 assert.equal((await call('/api/account/privacy','GET',null,a)).data.hide_notification_content,true);
 assert.equal((await call('/api/account/privacy','PATCH',{hide_notification_content:'false'},a)).status,400);
 await call('/api/inbox','POST',{title:'Sensitive title',reminder_at:'2030-01-01T09:00:00Z'},a);
 assert.ok(!(JSON.stringify((await call('/api/reminders','GET',null,a)).data).includes('Sensitive title')));
 assert.equal((await call('/api/auth/logout-all','POST',{},a)).status,200);
 assert.equal((await call('/api/me','GET',null,b)).status,401);
});

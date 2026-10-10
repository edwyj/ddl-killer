import test from 'node:test';import assert from 'node:assert/strict';
process.env.DB_PATH=':memory:';process.env.JWT_SECRET='password-copy-fixture-secret-only';
const {createApp}=await import('../src/app.js');const {db}=await import('../src/db.js');
const bcrypt=(await import('bcryptjs')).default;const {createUserWithDefaultLists}=await import('../src/default-lists.js');
const uid=createUserWithDefaultLists('copy_fixture',bcrypt.hashSync('Existing-password-123',10));
const server=createApp().listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));
test.after(()=>{server.close();db.close();});
const base=`http://127.0.0.1:${server.address().port}`;
async function post(path,body,token){const r=await fetch(base+path,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body)});return {status:r.status,data:await r.json()};}
test('password validation explains length in ordinary language and retains existing unicode limits',async()=>{
 const token=(await post('/api/auth/login',{username:'copy_fixture',password:'Existing-password-123'})).data.token;
 for(const value of ['short','a'.repeat(73),'字'.repeat(25)]){
  const result=await post('/api/auth/password',{old_password:'Existing-password-123',new_password:value},token);
  assert.equal(result.status,400);assert.ok(!result.data.error.includes('UTF-8'));assert.ok(!result.data.error.includes('字节'));
  const recovery=await post('/api/auth/email/reset-confirm',{email:'fixture@example.com',new_password:value});
  assert.equal(recovery.status,400);assert.ok(!recovery.data.error.includes('UTF-8'));
 }
 const ok=await post('/api/auth/password',{old_password:'Existing-password-123',new_password:'字'.repeat(24)},token);
 assert.equal(ok.status,200);assert.ok(await bcrypt.compare('字'.repeat(24),db.prepare('SELECT password_hash FROM users WHERE id=?').get(uid).password_hash));
});

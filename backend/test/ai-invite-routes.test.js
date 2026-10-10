import assert from 'node:assert/strict';
import test from 'node:test';
process.env.DB_PATH=':memory:';
process.env.JWT_SECRET='invite-route-tests-secret-at-least-32';
process.env.AI_INVITE_SECRET='invite-derivation-test-at-least-32';
process.env.AI_INVITE_ADMIN_TOKEN='invite-admin-test-at-least-32-characters';
const {createApp}=await import('../src/app.js');
const {db}=await import('../src/db.js');
const {issueSession}=await import('../src/security.js');
db.prepare('INSERT INTO users(id,username,password_hash) VALUES(1,?,?)').run('invite_route','test');
const token=issueSession({id:1,username:'invite_route'});
const server=createApp().listen(0,'127.0.0.1');
await new Promise(resolve=>server.once('listening',resolve));
test.after(()=>server.close());
const base=`http://127.0.0.1:${server.address().port}`;
async function call(path,body,credential){
 const r=await fetch(base+path,{method:'POST',headers:{'content-type':'application/json',...(credential?{authorization:`Bearer ${credential}`}:{})},body:JSON.stringify(body)});
 return {status:r.status,value:await r.json()};
}
test('public user cannot issue; admin cannot redeem without user session; preview and redeem are private',async()=>{
 const path='/api/internal/ai-invites/issue',body={plan:'week',count:1,requestKey:'route-test-one'};
 assert.equal((await call(path,body)).status,403);
 assert.equal((await call(path,body,token)).status,403);
 const result=await call(path,body,process.env.AI_INVITE_ADMIN_TOKEN);assert.equal(result.status,200);
 const code=result.value.invites[0].code;
 assert.equal((await call('/api/ai/invites/redeem',{code},process.env.AI_INVITE_ADMIN_TOKEN)).status,401);
 assert.equal((await call('/api/ai/invites/preview',{code},token)).value.dailyLimit,10);
 assert.equal((await call('/api/ai/invites/redeem',{code},token)).status,200);
 assert.equal(db.prepare('SELECT user_id FROM ai_invites').get().user_id,1);
});
test('malformed code is rate-limited without echoing input',async()=>{
 for(let i=0;i<20;i++)await call('/api/ai/invites/preview',{code:'sensitive-invalid-code'},token);
 const result=await call('/api/ai/invites/preview',{code:'sensitive-invalid-code'},token);
 assert.equal(result.status,429);assert.ok(!JSON.stringify(result.value).includes('sensitive-invalid-code'));
});

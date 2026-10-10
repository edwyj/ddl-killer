import test from 'node:test';
import assert from 'node:assert/strict';
import bcrypt from 'bcryptjs';
process.env.DB_PATH=':memory:';
process.env.JWT_SECRET='beta-test-signing-key-separate-from-production';
process.env.RELEASE_CHANNEL='beta';
process.env.BETA_ALLOWED_USER_IDS='2,5';
process.env.BETA_ALLOWED_USERNAMES='tester_alpha,tester_bravo';
process.env.PUBLIC_ORIGIN='https://beta.ddlkiller.com';
const {db}=await import('../src/db.js');
db.exec("CREATE TABLE beta_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO beta_meta VALUES('generation','first')");
const {createApp}=await import('../src/app.js');
const {issueSession}=await import('../src/security.js');
const {refreshBeta}=await import('../scripts/beta-refresh.mjs');
let server,base,authorizedToken;
test.before(async()=>{
  const hash=await bcrypt.hash('beta-test-password',4);
  for(const [id,username] of [[2,'tester_alpha'],[5,'tester_bravo'],[9,'outsider']]) db.prepare('INSERT INTO users(id,username,password_hash) VALUES(?,?,?)').run(id,username,hash);
  authorizedToken=issueSession({id:2,username:'tester_alpha'});
  server=createApp().listen(0);
  await new Promise(resolve=>server.once('listening',resolve));
  base=`http://127.0.0.1:${server.address().port}`;
});
test.after(()=>new Promise(resolve=>server.close(resolve)));
const request=(path,{body,token=authorizedToken,method=body?'POST':'GET'}={})=>fetch(base+path,{method,headers:{'Content-Type':'application/json',authorization:`Bearer ${token}`},...(body?{body:JSON.stringify(body)}:{})});
test('only authorized Beta identities can log in or use an existing session',async()=>{
  assert.equal((await request('/api/auth/login',{body:{username:'tester_alpha',password:'beta-test-password'}})).status,200);
  assert.equal((await request('/api/auth/login',{body:{username:'outsider',password:'beta-test-password'}})).status,403);
  const outsider=issueSession({id:9,username:'outsider'});
  assert.equal((await request('/api/me',{token:outsider})).status,403);
  assert.equal((await request('/api/auth/register',{body:{}})).status,403);
  assert.equal((await request('/api/auth/setup',{body:{}})).status,403);
  assert.equal((await request('/api/internal/ai-invites',{body:{}})).status,403);
});
test('old or missing snapshot generation cannot replay offline mutations',async()=>{
  for(const generation of [undefined,'stale']) {
    const response=await request('/api/sync/mutation',{body:{uid:2,id:'test-id-1234567890123456',method:'POST',path:'/api/lists',body:{name:'old beta data'},generation}});
    assert.equal(response.status,409);
    assert.equal((await response.json()).code,'DATASET_REFRESHED');
  }
  assert.equal(db.prepare('SELECT count(*) n FROM lists').get().n,0);
});
test('refresh accepts only business rows and syncs authorized password hashes with independent sessions',async()=>{
  const passwordBefore=db.prepare('SELECT password_hash FROM users WHERE id=2').get().password_hash;
  const users=[{id:2,username:'tester_alpha',password_hash:passwordBefore,nickname:'tester_alpha',avatar:'',hide_notification_content:1,created_at:'2026-01-01'},
    {id:5,username:'tester_bravo',password_hash:passwordBefore,nickname:'tester_bravo',avatar:'',hide_notification_content:1,created_at:'2026-01-01'}];
  const source={format:'ddl-beta-business-v1',users,tables:{lists:[{id:77,user_id:2,name:'正式账号的清单'}],inbox:[{id:88,user_id:2,list_id:77,title:'正式账号的任务'}],ai_plan_applications:[{id:'synthetic-apply',user_id:2,session_id:'synthetic-session',draft_id:'synthetic-draft',before_json:'[]',after_json:'{"tasks":[],"blocks":[]}',created_at:1}]}};
  db.prepare('INSERT INTO ai_provider_configs VALUES(?,?,?,?,?,?,?,?,?,?,?,?)').run('private-key',2,'deepseek','https://api.deepseek.com','deepseek-chat','v1','nonce','encrypted','tag','mask','now','now');
  await assert.rejects(refreshBeta({...source,tables:{sessions:[]}},{}));
  await assert.rejects(refreshBeta({...source,tables:{lists:[{id:78,user_id:9,name:'not authorized'}]}},{}));
  const refreshed=await refreshBeta(source,{});
  assert.notEqual(refreshed.generation,'first');
  assert.equal(db.prepare('SELECT count(*) n FROM users').get().n,2);
  assert.equal(db.prepare('SELECT count(*) n FROM ai_provider_configs').get().n,0);
  assert.equal(db.prepare('SELECT count(*) n FROM ai_plan_applications WHERE user_id=2').get().n,1);
  assert.equal(db.prepare('SELECT password_hash FROM users WHERE id=2').get().password_hash,passwordBefore);
  assert.equal((await request('/api/me')).status,200);
  const snapshot=await (await request('/api/sync/snapshot')).json();
  assert.equal(snapshot.tasks[0].title,'正式账号的任务');
  assert.equal(snapshot.generation,refreshed.generation);
  const response=await request('/api/sync/mutation',{body:{uid:2,id:'fresh-op-1234567890123456',method:'POST',path:'/api/lists',body:{name:'本轮测试清单'},generation:refreshed.generation}});
  assert.equal(response.status,200);
  const nextHash=await bcrypt.hash('same-as-production-new-password',4);
  await assert.rejects(refreshBeta({...source,users:users.map(u=>({...u,password_hash:'invalid'}))}));
  await refreshBeta({...source,users:users.map(u=>({...u,password_hash:nextHash}))});
  assert.equal(db.prepare('SELECT password_hash FROM users WHERE id=2').get().password_hash,nextHash);
  assert.equal((await request('/api/me')).status,401);
  assert.equal((await request('/api/auth/login',{body:{username:'tester_alpha',password:'beta-test-password'}})).status,401);
  assert.equal((await request('/api/auth/login',{body:{username:'tester_alpha',password:'same-as-production-new-password'}})).status,200);
});
test('the authorized account list is configurable and must match the snapshot exactly',async()=>{
  const hash=db.prepare('SELECT password_hash FROM users WHERE id=2').get().password_hash;
  const account=(id,username)=>({id,username,password_hash:hash,nickname:username,avatar:'',hide_notification_content:1,created_at:'2026-01-01'});
  const two=[account(2,'tester_alpha'),account(5,'tester_bravo')];
  const source={format:'ddl-beta-business-v1',users:two,tables:{lists:[]}};
  // A snapshot carrying an account the running configuration does not list is refused.
  await assert.rejects(refreshBeta({...source,users:[...two,account(9,'outsider')]}));
  // Same names in a different order is fine; the comparison is on the set.
  await refreshBeta({...source,users:[two[1],two[0]]});
  // Adding a tester is configuration: whitelist it and the same snapshot is accepted.
  const before={ids:process.env.BETA_ALLOWED_USER_IDS,names:process.env.BETA_ALLOWED_USERNAMES};
  process.env.BETA_ALLOWED_USER_IDS='2,5,9';
  process.env.BETA_ALLOWED_USERNAMES='tester_alpha,tester_bravo,outsider';
  try {
    await assert.rejects(refreshBeta(source),/Invalid Beta refresh/,'a listed account missing from the snapshot is refused');
    await refreshBeta({...source,users:[...two,account(9,'outsider')]});
    assert.equal(db.prepare('SELECT count(*) n FROM users').get().n,3);
    // The id whitelist is enforced independently of the name list.
    process.env.BETA_ALLOWED_USER_IDS='2,5';
    await assert.rejects(refreshBeta({...source,users:[...two,account(9,'outsider')]}),/Unexpected user IDs/);
  } finally {
    process.env.BETA_ALLOWED_USER_IDS=before.ids;
    process.env.BETA_ALLOWED_USERNAMES=before.names;
  }
});

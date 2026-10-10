import test from 'node:test';
import assert from 'node:assert/strict';

process.env.DB_PATH=':memory:';
process.env.JWT_SECRET='test-planning';
const {db}=await import('../src/db.js');
const {createApp}=await import('../src/app.js');
const {issueSession}=await import('../src/security.js');
const {deliverDue,validSubscription}=await import('../src/reminders.js');
db.prepare('INSERT INTO users(id,username,password_hash) VALUES(1,?,?)').run('owner','test');
db.prepare('INSERT INTO users(id,username,password_hash) VALUES(2,?,?)').run('other','test');
const server=createApp().listen(0);
await new Promise(r=>server.once('listening',r));
test.after(()=>{server.close();db.close();});
async function call(method,path,body,uid=1) {
  const r=await fetch(`http://127.0.0.1:${server.address().port}${path}`,{method,headers:{'content-type':'application/json',authorization:`Bearer ${issueSession(db.prepare('SELECT id,username FROM users WHERE id=?').get(uid))}`},...(body===undefined?{}:{body:JSON.stringify(body)})});
  return {status:r.status,data:await r.json()};
}
test('linked task lifecycle: deadline independent, atomic save, ownership, no double counts',async()=> {
  const due='2030-04-20';
  const created=await call('POST','/api/inbox',{title:'报告',due_date:due,schedule:{date:'2030-04-18',start_min:600,end_min:660}});
  assert.equal(created.status,200);
  const id=created.data.id,bid=created.data.task.schedule.id;
  assert.equal(created.data.task.due_date,due);
  assert.equal((await call('GET','/api/stats')).data.todos,1);
  assert.equal((await call('PATCH',`/api/inbox/${id}`,{title:'偷改'},2)).status,404);
  assert.equal((await call('PATCH',`/api/blocks/${bid}`,{done:true},2)).status,404);
  assert.equal((await call('PATCH',`/api/inbox/${id}`,{title:'应回滚',schedule:{date:'2030-02-30',start_min:20,end_min:10}})).status,400);
  assert.equal(db.prepare('SELECT title FROM inbox WHERE id=?').get(id).title,'报告');
  await call('PATCH',`/api/blocks/${bid}`,{title:'完成报告',done:true});
  assert.equal((await call('GET','/api/inbox')).data[0].done,1);
  assert.equal((await call('GET','/api/stats')).data.done,1);
  await call('PATCH',`/api/inbox/${id}`,{done:false,schedule:{date:'2030-04-19',start_min:700,end_min:760}});
  assert.equal(db.prepare('SELECT count(*) n FROM blocks WHERE inbox_id=?').get(id).n,1);
  assert.equal(db.prepare('SELECT done FROM blocks WHERE id=?').get(bid).done,0);
  await call('DELETE',`/api/blocks/${bid}`);
  assert.ok(db.prepare('SELECT id FROM inbox WHERE id=?').get(id));
  await call('PATCH',`/api/inbox/${id}`,{schedule:{date:'2030-04-19',start_min:700,end_min:760}});
  // 删除改成软删：任务和它的排期块一起进回收站，但都还躺在库里等着还原
  await call('DELETE',`/api/inbox/${id}`);
  assert.ok(db.prepare('SELECT deleted_at FROM inbox WHERE id=?').get(id).deleted_at);
  assert.ok(db.prepare('SELECT deleted_at FROM blocks WHERE inbox_id=?').get(id).deleted_at);
  assert.equal((await call('GET','/api/inbox')).data.length,0);
});
test('reminder queue respects ownership, completion and cancellation; failed delivery retries once successful',async()=> {
  const future=new Date(Date.now()+3600000).toISOString();
  const r=await call('POST','/api/inbox',{title:'提醒',reminder_at:future});
  const id=r.data.id;
  assert.equal((await call('GET','/api/reminders')).data.length,1);
  assert.equal((await call('GET','/api/reminders',undefined,2)).data.length,0);
  await call('PATCH',`/api/inbox/${id}`,{done:true});
  assert.equal((await call('GET','/api/reminders')).data.length,0);
  await call('PATCH',`/api/inbox/${id}`,{done:false,reminder_at:null});
  assert.equal((await call('GET','/api/reminders')).data.length,0);
  const now=new Date();
  const past=new Date(now.getTime()-1000).toISOString();
  db.prepare('UPDATE inbox SET reminder_at=? WHERE id=?').run(past,id);
  db.prepare('INSERT INTO push_subscriptions VALUES(?,?,?)').run('test-endpoint',1,JSON.stringify({endpoint:'test-endpoint'}));
  let calls=0;
  await deliverDue(async()=>{calls++;throw new Error('offline');},now);
  await deliverDue(async()=>{calls++;},now);
  await deliverDue(async()=>{calls++;},now);
  assert.equal(calls,2);
  db.prepare('UPDATE inbox SET done=1 WHERE id=?').run(id);
  await deliverDue(async()=>{throw new Error('Should not deliver completed task');},now);
});
test('push subscription rejects private endpoints',()=> {
  assert.equal(validSubscription({endpoint:'https://127.0.0.1',keys:{p256dh:'a'.repeat(87),auth:'b'.repeat(22)}}),false);
});

test('deadline edits from older clients move existing reminders by the same delta',async()=> {
  const r=await call('POST','/api/inbox',{title:'改期提醒',due_date:'2030-04-20',due_time:600,reminder_at:'2030-04-20T01:00:00.000Z'});
  const id=r.data.id;
  const changed=await call('PATCH',`/api/inbox/${id}`,{due_date:'2030-04-21'});
  assert.equal(changed.data.task.reminder_at,'2030-04-21T01:00:00.000Z');
  const cleared=await call('PATCH',`/api/inbox/${id}`,{due_date:null});
  assert.equal(cleared.data.task.reminder_at,null);
});

test('task duration survives older clients, validates bounds and can be cleared',async()=> {
  const made=await call('POST','/api/inbox',{title:'预计用时测试',estimate_minutes:90});
  assert.equal(made.data.task.estimate_minutes,90);
  const id=made.data.id;
  const renamed=await call('PATCH',`/api/inbox/${id}`,{title:'预计用时改名'});
  assert.equal(renamed.data.task.estimate_minutes,90);
  for(const estimate_minutes of [0,-1,10081,1.5,'60']) {
    const invalid=await call('PATCH',`/api/inbox/${id}`,{estimate_minutes});
    assert.equal(invalid.status,400);
  }
  const cleared=await call('PATCH',`/api/inbox/${id}`,{estimate_minutes:null});
  assert.equal(cleared.data.task.estimate_minutes,null);
});

test('task and block versions advance only for real mutations',async()=> {
  const made=await call('POST','/api/inbox',{title:'版本任务',schedule:{date:'2030-05-10',start_min:600,end_min:660}});
  const id=made.data.id,bid=made.data.task.schedule.id;
  const versions=()=>({task:db.prepare('SELECT version FROM inbox WHERE id=?').get(id).version,block:db.prepare('SELECT version FROM blocks WHERE id=?').get(bid).version});
  assert.deepEqual(versions(),{task:1,block:1});
  await call('PATCH',`/api/inbox/${id}`,{title:'版本任务'});
  assert.deepEqual(versions(),{task:1,block:1});
  await call('PATCH',`/api/inbox/${id}`,{title:'新标题'});
  assert.deepEqual(versions(),{task:2,block:2});
  await call('PATCH',`/api/inbox/${id}`,{schedule:{date:'2030-05-11',start_min:600,end_min:660}});
  assert.deepEqual(versions(),{task:2,block:3});
});

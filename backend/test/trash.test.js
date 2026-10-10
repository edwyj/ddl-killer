import test from 'node:test';
import assert from 'node:assert/strict';

process.env.DB_PATH=':memory:';
process.env.JWT_SECRET='test-trash';
const {db}=await import('../src/db.js');
const {createApp}=await import('../src/app.js');
const {issueSession}=await import('../src/security.js');
const {purgeExpired}=await import('../src/retention.js');
const {createUserWithDefaultLists}=await import('../src/default-lists.js');

const server=createApp().listen(0);
await new Promise(r=>server.once('listening',r));
test.after(()=>{server.close();db.close();});

// 每个用例一个账号：共用一个内存库时，不然前一个用例的任务会漏进后一个的断言里。
let seq=0;
const newUser=()=>createUserWithDefaultLists(`u${++seq}`,'hash');
async function call(method,path,body,uid) {
  const r=await fetch(`http://127.0.0.1:${server.address().port}${path}`,{method,headers:{'content-type':'application/json',authorization:`Bearer ${issueSession(db.prepare('SELECT id,username FROM users WHERE id=?').get(uid))}`},...(body===undefined?{}:{body:JSON.stringify(body)})});
  return {status:r.status,data:await r.json()};
}
const sysId=(uid,key)=>db.prepare('SELECT id FROM lists WHERE user_id=? AND system=?').get(uid,key).id;
const titles=(uid)=>db.prepare('SELECT title FROM inbox WHERE user_id=?').all(uid).map(t=>t.title);
const dayAgo=(n)=>new Date(Date.now()-n*86400000).toISOString();

test('deleting a task moves it and its schedule block to the trash, restore brings both back',async()=>{
  const u=newUser();
  const r=await call('POST','/api/inbox',{title:'交报告',due_date:'2030-05-01',schedule:{date:'2030-04-30',start_min:600,end_min:660}},u);
  const id=r.data.id;
  const bid=r.data.task.schedule.id;
  assert.equal(db.prepare('SELECT version FROM inbox WHERE id=?').get(id).version,1);
  assert.equal(db.prepare('SELECT version FROM blocks WHERE id=?').get(bid).version,1);
  assert.equal((await call('DELETE',`/api/inbox/${id}`,undefined,u)).status,200);
  assert.equal(db.prepare('SELECT version FROM inbox WHERE id=?').get(id).version,2);
  assert.equal(db.prepare('SELECT version FROM blocks WHERE id=?').get(bid).version,2);
  assert.equal((await call('GET','/api/inbox',undefined,u)).data.length,0);
  // 回收站里任务只出现一次：挂在它下面的排期块跟随任务，不单独露脸
  const trash=(await call('GET','/api/trash',undefined,u)).data.items;
  assert.equal(trash.length,1);
  assert.equal(trash[0].kind,'task');
  assert.equal(trash[0].title,'交报告');
  assert.ok(trash[0].deleted_at);
  assert.ok(db.prepare('SELECT deleted_at FROM blocks WHERE inbox_id=?').get(id).deleted_at);
  // 回收站里的任务不参与编辑，否则会改出一个看不见的幽灵任务
  assert.equal((await call('PATCH',`/api/inbox/${id}`,{title:'偷改'},u)).status,404);
  // 还原：任务回来，排期也跟着回来
  assert.equal((await call('POST',`/api/trash/task/${id}/restore`,undefined,u)).status,200);
  assert.equal(db.prepare('SELECT version FROM inbox WHERE id=?').get(id).version,3);
  assert.equal(db.prepare('SELECT version FROM blocks WHERE id=?').get(bid).version,3);
  const back=(await call('GET','/api/inbox',undefined,u)).data;
  assert.equal(back.length,1);
  assert.equal(back[0].schedule.date,'2030-04-30');
  assert.equal((await call('GET','/api/trash',undefined,u)).data.items.length,0);
});

test('restoring a task revives the same block row instead of fighting the unique index',async()=>{
  const u=newUser();
  const id=(await call('POST','/api/inbox',{title:'占位',schedule:{date:'2030-06-01',start_min:540,end_min:600}},u)).data.id;
  await call('DELETE',`/api/inbox/${id}`,undefined,u);
  await call('POST',`/api/trash/task/${id}/restore`,undefined,u);
  // 软删过的行还占着 inbox_id 的唯一索引，重新排期必须复活它而不是插一条新的
  await call('PATCH',`/api/inbox/${id}`,{schedule:{date:'2030-06-02',start_min:600,end_min:660}},u);
  assert.equal(db.prepare('SELECT count(*) n FROM blocks WHERE inbox_id=?').get(id).n,1);
  assert.equal(db.prepare('SELECT date FROM blocks WHERE inbox_id=?').get(id).date,'2030-06-02');
});

test('standalone calendar blocks are recoverable too, and hidden from the calendar while deleted',async()=>{
  const u=newUser();
  const bid=(await call('POST','/api/blocks',{date:'2030-07-01',start_min:540,end_min:600,title:'跑步'},u)).data.id;
  assert.equal((await call('GET','/api/day?date=2030-07-01',undefined,u)).data.blocks.length,1);
  await call('DELETE',`/api/blocks/${bid}`,undefined,u);
  assert.equal((await call('GET','/api/day?date=2030-07-01',undefined,u)).data.blocks.length,0);
  const trash=(await call('GET','/api/trash',undefined,u)).data.items;
  assert.equal(trash.length,1);
  assert.equal(trash[0].kind,'block');
  assert.equal((await call('POST',`/api/trash/block/${bid}/restore`,undefined,u)).status,200);
  assert.equal((await call('GET','/api/day?date=2030-07-01',undefined,u)).data.blocks.length,1);
});

test('deleting a planned task from the calendar only unschedules it, the task stays',async()=>{
  const u=newUser();
  const r=await call('POST','/api/inbox',{title:'留着',schedule:{date:'2030-08-01',start_min:540,end_min:600}},u);
  const bid=r.data.task.schedule.id;
  await call('DELETE',`/api/blocks/${bid}`,undefined,u);
  const tasks=(await call('GET','/api/inbox',undefined,u)).data;
  assert.equal(tasks.length,1);
  assert.equal(tasks[0].schedule,null);
  assert.equal((await call('GET','/api/trash',undefined,u)).data.items.length,0); // 取消排期不是删除，不该进回收站
});

test('permanent delete and empty-trash only touch rows that are already in the trash',async()=>{
  const u=newUser();
  const keep=(await call('POST','/api/inbox',{title:'别删我'},u)).data.id;
  const a=(await call('POST','/api/inbox',{title:'甲'},u)).data.id;
  const b=(await call('POST','/api/inbox',{title:'乙'},u)).data.id;
  await call('DELETE',`/api/inbox/${a}`,undefined,u);
  await call('DELETE',`/api/inbox/${b}`,undefined,u);
  assert.equal((await call('DELETE',`/api/trash/task/${a}`,undefined,u)).status,200);
  assert.equal(db.prepare('SELECT id FROM inbox WHERE id=?').get(a),undefined);
  assert.equal((await call('DELETE',`/api/trash/task/${keep}`,undefined,u)).status,404); // 不在回收站里的删不掉
  assert.equal((await call('DELETE','/api/trash',undefined,u)).data.tasks,1);
  assert.deepEqual((await call('GET','/api/inbox',undefined,u)).data.map(t=>t.title),['别删我']);
});

test('another user cannot see, restore or purge your trash',async()=>{
  const u=newUser(),v=newUser();
  const id=(await call('POST','/api/inbox',{title:'私事'},u)).data.id;
  await call('DELETE',`/api/inbox/${id}`,undefined,u);
  assert.equal((await call('GET','/api/trash',undefined,v)).data.items.length,0);
  assert.equal((await call('POST',`/api/trash/task/${id}/restore`,undefined,v)).status,404);
  assert.equal((await call('DELETE',`/api/trash/task/${id}`,undefined,v)).status,404);
  assert.ok(db.prepare('SELECT deleted_at FROM inbox WHERE id=?').get(id).deleted_at);
});

test('checking a task off stamps done_at, unchecking clears it, unrelated edits leave it alone',async()=>{
  const u=newUser();
  const id=(await call('POST','/api/inbox',{title:'写作业'},u)).data.id;
  await call('PATCH',`/api/inbox/${id}`,{done:true},u);
  const stamped=db.prepare('SELECT done_at FROM inbox WHERE id=?').get(id).done_at;
  assert.ok(stamped);
  assert.deepEqual((await call('GET','/api/done',undefined,u)).data.items.map(t=>t.title),['写作业']);
  // 改标题/改截止日期不能把完成时刻刷掉，否则「已完成」的排序和 3 天到期都会被无限推迟
  await call('PATCH',`/api/inbox/${id}`,{title:'写完了',due_date:'2030-09-09'},u);
  assert.equal(db.prepare('SELECT done_at FROM inbox WHERE id=?').get(id).done_at,stamped);
  await call('PATCH',`/api/inbox/${id}`,{done:false},u);
  assert.equal(db.prepare('SELECT done_at FROM inbox WHERE id=?').get(id).done_at,null);
  assert.equal((await call('GET','/api/done',undefined,u)).data.items.length,0);
});

test('done tasks disappear from the stats counters only after they are purged',async()=>{
  const u=newUser();
  const id=(await call('POST','/api/inbox',{title:'统计'},u)).data.id;
  await call('PATCH',`/api/inbox/${id}`,{done:true},u);
  assert.equal((await call('GET','/api/stats',undefined,u)).data.done,1);
  db.prepare('UPDATE inbox SET done_at=? WHERE id=?').run(dayAgo(4),id);
  purgeExpired(new Date());
  assert.equal((await call('GET','/api/stats',undefined,u)).data.done,0);
});

test('trash and done are derived views, never hand-assignable containers',async()=>{
  const u=newUser();
  assert.equal((await call('POST','/api/inbox',{title:'塞进去',list_id:sysId(u,'trash')},u)).status,400);
  assert.equal((await call('POST','/api/inbox',{title:'塞进去',list_id:sysId(u,'done')},u)).status,400);
  // 收集箱不一样，它是真容器
  assert.equal((await call('POST','/api/inbox',{title:'想法',list_id:sysId(u,'inbox')},u)).status,200);
  const detail=(await call('GET',`/api/lists/${sysId(u,'inbox')}/tasks`,undefined,u)).data;
  assert.deepEqual(detail.inbox.map(t=>t.title),['想法']);
});

test('trash keeps a week, done keeps three days, and the purge spares everything else',async()=>{
  const u=newUser();
  const fresh=(await call('POST','/api/inbox',{title:'刚删'},u)).data.id;
  const stale=(await call('POST','/api/inbox',{title:'删很久了'},u)).data.id;
  const recentlyDone=(await call('POST','/api/inbox',{title:'刚完成'},u)).data.id;
  const longDone=(await call('POST','/api/inbox',{title:'完成很久了',schedule:{date:'2030-10-01',start_min:540,end_min:600}},u)).data.id;
  await call('POST','/api/inbox',{title:'活着'},u);
  await call('DELETE',`/api/inbox/${fresh}`,undefined,u);
  await call('DELETE',`/api/inbox/${stale}`,undefined,u);
  db.prepare('UPDATE inbox SET deleted_at=? WHERE id=?').run(dayAgo(8),stale);
  db.prepare('UPDATE blocks SET deleted_at=? WHERE inbox_id=?').run(dayAgo(8),stale);
  await call('PATCH',`/api/inbox/${recentlyDone}`,{done:true},u);
  db.prepare('UPDATE inbox SET done_at=? WHERE id=?').run(dayAgo(2),recentlyDone);
  await call('PATCH',`/api/inbox/${longDone}`,{done:true},u);
  db.prepare('UPDATE inbox SET done_at=? WHERE id=?').run(dayAgo(4),longDone);
  const r=purgeExpired(new Date());
  assert.equal(r.tasks,2);                       // 只清「删够 8 天」和「完成够 4 天」这两条
  const left=titles(u);
  assert.ok(left.includes('刚删') && left.includes('刚完成') && left.includes('活着'));
  assert.ok(!left.includes('删很久了') && !left.includes('完成很久了'));
  // 过期任务的时间块要跟着走，否则会留下挂在幽灵任务上的孤儿块
  assert.equal(db.prepare('SELECT count(*) n FROM blocks WHERE inbox_id=?').get(longDone).n,0);
  assert.equal((await call('GET','/api/done',undefined,u)).data.items.filter(t=>t.title==='刚完成').length,1);
});

test('purging one done task takes its block with it and refuses to touch anything live',async()=>{
  const u=newUser();
  const doneId=(await call('POST','/api/inbox',{title:'完成的',schedule:{date:'2030-11-01',start_min:540,end_min:600}},u)).data.id;
  await call('PATCH',`/api/inbox/${doneId}`,{done:true},u);
  const openId=(await call('POST','/api/inbox',{title:'没完成的'},u)).data.id;
  // 没打勾的任务不该被这个口子删掉 —— 「删完成的」不能变成「删所有的」
  assert.equal((await call('DELETE',`/api/done/${openId}`,undefined,u)).status,404);
  assert.equal((await call('DELETE',`/api/done/${doneId}`,undefined,u)).status,200);
  assert.equal(db.prepare('SELECT id FROM inbox WHERE id=?').get(doneId),undefined);
  assert.equal(db.prepare('SELECT count(*) n FROM blocks WHERE inbox_id=?').get(doneId).n,0);
  assert.deepEqual(titles(u),['没完成的']);
});

test('emptying done spares open tasks and never reaches into the trash',async()=>{
  const u=newUser();
  const a=(await call('POST','/api/inbox',{title:'完成甲'},u)).data.id;
  const b=(await call('POST','/api/inbox',{title:'完成乙'},u)).data.id;
  const open=(await call('POST','/api/inbox',{title:'待办'},u)).data.id;
  const binned=(await call('POST','/api/inbox',{title:'在回收站'},u)).data.id;
  await call('PATCH',`/api/inbox/${a}`,{done:true},u);
  await call('PATCH',`/api/inbox/${b}`,{done:true},u);
  await call('DELETE',`/api/inbox/${binned}`,undefined,u);
  assert.equal((await call('DELETE','/api/done',undefined,u)).data.tasks,2);
  assert.deepEqual(titles(u),['待办','在回收站']);
  // 回收站里的东西还在回收站，得走回收站自己的清空
  assert.equal((await call('GET','/api/trash',undefined,u)).data.items.length,1);
  assert.equal((await call('DELETE','/api/done',undefined,u)).data.tasks,0);
});

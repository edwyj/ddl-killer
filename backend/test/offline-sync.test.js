import test from 'node:test';
import assert from 'node:assert/strict';
process.env.DB_PATH=':memory:';process.env.JWT_SECRET='offline-test-key';
const {db}=await import('../src/db.js');
const {createApp}=await import('../src/app.js');
const {issueSession}=await import('../src/security.js');
const {createUserWithDefaultLists}=await import('../src/default-lists.js');
const uid=createUserWithDefaultLists('offline_a','hash'),other=createUserWithDefaultLists('offline_b','hash');
const token=issueSession({id:uid,username:'offline_a'}),otherToken=issueSession({id:other,username:'offline_b'});
const server=createApp().listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));
test.after(()=>{server.close();db.close();});let seq=0;
async function request(path,method='GET',body,t=token){const r=await fetch(`http://127.0.0.1:${server.address().port}${path}`,{method,headers:{authorization:`Bearer ${t}`,'content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});return {status:r.status,data:await r.json()};}
const op=(method,path,body,base=null)=>({id:`test-operation-${++seq}`,uid,method,path,body,base});

test('undo rejects pre-restoration offline block and task schedule writes while metadata still merges',async()=>{
 const {randomUUID}=await import('node:crypto');
 const {createDraft}=await import('../src/mcp-drafts.js');
 const {applyAiDraft,undoAiApplication}=await import('../src/ai-draft-actions.js');
 const date=new Date(Date.now()+5*86400000).toISOString().slice(0,10);
 const made=(await request('/api/inbox','POST',{title:'合成撤销同步',estimate_minutes:60,schedule:{date,start_min:600,end_min:660}})).data.task;
 const before=(await request('/api/sync/snapshot')).data;
 const oldBlock=before.blocks.find(b=>b.inbox_id===made.id),oldTask=before.tasks.find(t=>t.id===made.id);
 // A legacy client has no restoration marker at all.
 delete oldBlock.restore_epoch;delete oldTask.restore_epoch;
 const sessionId=randomUUID(),now=Date.now();
 db.prepare("INSERT INTO ai_planning_sessions(id,user_id,mode,start_date,end_date,status,created_at,updated_at,expires_at) VALUES(?,?,'hosted',?,?,'active',?,?,?)").run(sessionId,uid,date,date,now,now,now+1800000);
 const draft=createDraft(uid,'ai-planner',[{op:'unschedule_task',taskId:made.id}],{policy:{sessionId,requirements:[],exceptions:[]}});
 db.prepare('UPDATE ai_planning_sessions SET current_draft_id=? WHERE id=?').run(draft.id,sessionId);
 undoAiApplication(uid,applyAiDraft(uid,draft.id).applicationId);
 const blockReplay=await request('/api/sync/mutation','POST',op('PATCH',`/api/blocks/${oldBlock.id}`,{start_min:900,end_min:960},oldBlock));
 assert.equal(blockReplay.status,409);assert.equal(blockReplay.data.code,'SYNC_CONFLICT');
 assert.equal((await request('/api/sync/mutation','POST',op('PATCH',`/api/inbox/${made.id}`,{schedule:{date,start_min:900,end_min:960}},oldTask))).status,409);
 assert.equal((await request('/api/sync/mutation','POST',op('PATCH',`/api/inbox/${made.id}`,{notes:'合成备注'},oldTask))).status,200);
 const fresh=(await request('/api/sync/snapshot')).data.tasks.find(t=>t.id===made.id);
 assert.equal((await request('/api/sync/mutation','POST',op('PATCH',`/api/inbox/${made.id}`,{schedule:{date,start_min:900,end_min:960}},fresh))).status,200);
 await request(`/api/inbox/${made.id}`,'DELETE');
 db.prepare('DELETE FROM blocks WHERE inbox_id=?').run(made.id);db.prepare('DELETE FROM inbox WHERE id=?').run(made.id);
});
test('lost response retries create once and receipts survive app recreation',async()=>{
 const action=op('POST','/api/inbox',{title:'Offline task'});
 const first=await request('/api/sync/mutation','POST',action);
 assert.equal(first.status,200);const id=first.data.result.id;
 const again=await request('/api/sync/mutation','POST',action);
 assert.equal(again.data.result.id,id);assert.equal(db.prepare('SELECT count(*) n FROM inbox WHERE user_id=?').get(uid).n,1);
 assert.equal((await request('/api/sync/mutation','POST',{...action,body:{title:'changed'}})).status,409);
});
test('different fields merge; same fields conflict including legacy clients',async()=>{
 const row=(await request('/api/sync/snapshot')).data.tasks[0];
 await request(`/api/inbox/${row.id}`,'PATCH',{notes:'other device'});
 assert.equal(db.prepare('SELECT version FROM inbox WHERE id=?').get(row.id).version,row.version+1);
 const merged=await request('/api/sync/mutation','POST',op('PATCH',`/api/inbox/${row.id}`,{title:'new title'},row));
 assert.equal(merged.status,200);assert.equal(merged.data.snapshot.tasks[0].notes,'other device');
 assert.equal(db.prepare('SELECT version FROM inbox WHERE id=?').get(row.id).version,row.version+2);
 const conflict=await request('/api/sync/mutation','POST',op('PATCH',`/api/inbox/${row.id}`,{title:'competing'},row));
 assert.equal(conflict.status,409);assert.equal(conflict.data.code,'SYNC_CONFLICT');
});
test('sync cannot change another account, access credentials or bypass business rules',async()=>{
 const row=(await request('/api/sync/snapshot')).data.tasks[0];
 assert.equal((await request('/api/sync/mutation','POST',op('PATCH',`/api/inbox/${row.id}`,{title:'attack'},row),otherToken)).status,401);
 assert.equal((await request('/api/sync/mutation','POST',{...op('POST','/api/inbox',{title:'wrong account'}),uid:other})).status,401);
 assert.equal((await request('/api/sync/mutation','POST',{...op('PATCH',`/api/inbox/${row.id}`,{title:'attack'},row),uid:other},otherToken)).status,409);
 assert.equal((await request('/api/sync/mutation','POST',op('POST','/api/inbox',{title:'x'.repeat(301)}))).status,400);
 assert.equal((await request('/api/sync/mutation','POST',op('POST','/api/auth/logout-all',{}))).status,400);
 const bad=await request('/api/sync/mutation','POST',op('POST','/api/inbox',{title:'bad',schedule:{date:'bad'}}));
 assert.equal(bad.status,400);assert.equal(db.prepare('SELECT count(*) n FROM inbox').get().n,1);
 const snapshot=(await request('/api/sync/snapshot', 'GET',null,otherToken)).data;
 assert.equal(snapshot.tasks.length,0);assert.ok(!JSON.stringify(snapshot).includes('password_hash'));
});
test('already desired privacy value is an idempotent no-op; expired offline reminders do not block replay',async()=>{
 const base={hide_notification_content:true};
 const noop=await request('/api/sync/mutation','POST',op('PATCH','/api/account/privacy',base,base));
 assert.equal(noop.status,200);
 const reminder_at=new Date(Date.now()-3600000).toISOString();
 assert.equal((await request('/api/inbox','POST',{title:'online past rejected',reminder_at})).status,400);
 const replay=await request('/api/sync/mutation','POST',op('POST','/api/inbox',{title:'offline retained',reminder_at}));
 assert.equal(replay.status,200);assert.equal(replay.data.result.task.reminder_at,reminder_at);
});
test('old offline bases omit unknown duration without false delete conflicts but preserve real changes',async()=>{
 const first=(await request('/api/inbox','POST',{title:'合成旧离线任务'})).data.task;
 const legacy={...first};delete legacy.estimate_minutes;
 assert.equal((await request('/api/sync/mutation','POST',op('DELETE',`/api/inbox/${first.id}`,{},legacy))).status,200);
 const second=(await request('/api/inbox','POST',{title:'合成新用时任务'})).data.task;
 const prior={...second};delete prior.estimate_minutes;
 await request(`/api/inbox/${second.id}`,'PATCH',{estimate_minutes:90});
 const changed=await request('/api/sync/mutation','POST',op('DELETE',`/api/inbox/${second.id}`,{},prior));
 assert.equal(changed.status,409);assert.equal(changed.data.current.estimate_minutes,90);
});

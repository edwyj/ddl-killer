import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
process.env.DB_PATH=':memory:';
const {db}=await import('../src/db.js');
const {saveTask}=await import('../src/task-planning.js');
const {createUserWithDefaultLists}=await import('../src/default-lists.js');
const {createDraft,applyDraft}=await import('../src/mcp-drafts.js');
const actions=await import('../src/ai-draft-actions.js').catch(()=>({}));
let sequence=0;
const date=new Date(Date.now()+5*86400000).toISOString().slice(0,10);
function fixture(changes) {
  const uid=createUserWithDefaultLists(`application_fixture_${++sequence}`,'unused');
  const a=saveTask(uid,null,{title:'合成甲',estimate_minutes:60,schedule:{date,start_min:600,end_min:660}});
  const b=saveTask(uid,null,{title:'合成乙',estimate_minutes:60,schedule:{date,start_min:720,end_min:780}});
  const sessionId=randomUUID(),now=Date.now();
  db.prepare("INSERT INTO ai_planning_sessions(id,user_id,mode,start_date,end_date,status,created_at,updated_at,expires_at) VALUES(?,?,'hosted',?,?,'active',?,?,?)").run(sessionId,uid,date,date,now,now,now+1800000);
  const draft=createDraft(uid,'ai-planner',changes(a,b),{policy:{sessionId,requirements:[],exceptions:[]}});
  db.prepare('UPDATE ai_planning_sessions SET current_draft_id=? WHERE id=?').run(draft.id,sessionId);
  return {uid,a,b,draft,sessionId};
}
const move=(task,start)=>({op:'schedule_task',taskId:task.id,date,start,end:start+60});
test.after(()=>db.close());

test('partial apply validates selected final calendar and leaves all writes unchanged on conflict',()=>{
  assert.equal(typeof actions.applyAiDraft,'function');
  const f=fixture((a,b)=>[move(a,900),move(b,600)]);
  assert.throws(()=>actions.applyAiDraft(f.uid,f.draft.id,{selectedChangeIds:[f.draft.changes[1].id]}),{code:'AI_PLAN_CONFLICT'});
  assert.equal(db.prepare('SELECT start_min FROM blocks WHERE inbox_id=?').get(f.a.id).start_min,600);
  assert.equal(db.prepare('SELECT count(*) n FROM ai_plan_applications').get().n,0);
});
test('an AI-origin draft cannot bypass acknowledgement through the generic MCP apply entry',()=>{
  const f=fixture(a=>[move(a,900)]);
  assert.throws(()=>applyDraft(f.uid,'synthetic-mcp-client',f.draft.id),{code:'DRAFT_BLOCKED'});
  assert.equal(db.prepare('SELECT start_min FROM blocks WHERE inbox_id=?').get(f.a.id).start_min,600);
});
test('partial apply seals old selection, produces remainder and idempotent undo with increasing versions',()=>{
  assert.equal(typeof actions.applyAiDraft,'function');
  const f=fixture((a,b)=>[move(a,900),move(b,1020)]);
  assert.throws(()=>actions.applyAiDraft(f.uid,f.draft.id,{selectedChangeIds:[]}));
  const options={selectedChangeIds:[f.draft.changes[0].id]};
  const result=actions.applyAiDraft(f.uid,f.draft.id,options);
  assert.equal(result.applied,1);assert.equal(result.remainingDraft.changes.length,1);
  assert.deepEqual(actions.applyAiDraft(f.uid,f.draft.id,options),result);
  assert.throws(()=>actions.applyAiDraft(f.uid,f.draft.id,{selectedChangeIds:[f.draft.changes[1].id]}));
  assert.equal(db.prepare('SELECT start_min FROM blocks WHERE inbox_id=?').get(f.b.id).start_min,720);
  const version=db.prepare('SELECT version FROM blocks WHERE inbox_id=?').get(f.a.id).version;
  const undone=actions.undoAiApplication(f.uid,result.applicationId);
  assert.equal(undone.status,'undone');
  assert.equal(db.prepare('SELECT start_min FROM blocks WHERE inbox_id=?').get(f.a.id).start_min,600);
  assert.ok(db.prepare('SELECT version FROM blocks WHERE inbox_id=?').get(f.a.id).version>version);
  assert.deepEqual(actions.undoAiApplication(f.uid,result.applicationId),undone);
  assert.throws(()=>actions.applyAiDraft(f.uid,f.draft.id,options),{code:'DRAFT_ALREADY_UNDONE'});
});
test('undo refuses later edits and completion; empty or foreign selections cannot apply',()=>{
  assert.equal(typeof actions.applyAiDraft,'function');
  const f=fixture(a=>[move(a,900)]);
  assert.throws(()=>actions.applyAiDraft(f.uid,f.draft.id,{selectedChangeIds:['invented']}));
  const result=actions.applyAiDraft(f.uid,f.draft.id);
  saveTask(f.uid,f.a.id,{done:true});
  assert.throws(()=>actions.undoAiApplication(f.uid,result.applicationId),{code:'AI_UNDO_STALE'});
  assert.equal(db.prepare('SELECT done FROM inbox WHERE id=?').get(f.a.id).done,1);
  assert.equal(db.prepare('SELECT start_min FROM blocks WHERE inbox_id=?').get(f.a.id).start_min,900);
  assert.throws(()=>actions.undoAiApplication(99999,result.applicationId));
});
test('undo removes new independent blocks and restores cancelled linked block identifiers',()=>{
  assert.equal(typeof actions.applyAiDraft,'function');
  const f=fixture(a=>[{op:'unschedule_task',taskId:a.id},{op:'create_block',date,start:900,end:960,title:'合成独立安排'}]);
  const original=db.prepare('SELECT id FROM blocks WHERE inbox_id=?').get(f.a.id).id;
  const result=actions.applyAiDraft(f.uid,f.draft.id);
  assert.equal(db.prepare('SELECT count(*) n FROM blocks WHERE user_id=? AND inbox_id IS NULL').get(f.uid).n,1);
  actions.undoAiApplication(f.uid,result.applicationId);
  assert.equal(db.prepare('SELECT id FROM blocks WHERE inbox_id=?').get(f.a.id).id,original);
  assert.equal(db.prepare('SELECT count(*) n FROM blocks WHERE user_id=? AND inbox_id IS NULL').get(f.uid).n,0);
});

test('undo conflict rolls back removal of created blocks and retains the applied schedule',()=>{
  const f=fixture(a=>[move(a,900),{op:'create_block',date,start:1020,end:1080,title:'合成新安排'}]);
  const result=actions.applyAiDraft(f.uid,f.draft.id);
  db.prepare('INSERT INTO blocks(user_id,date,start_min,end_min,title) VALUES(?,?,?,?,?)').run(f.uid,date,600,660,'合成后续占用');
  assert.throws(()=>actions.undoAiApplication(f.uid,result.applicationId),{code:'AI_UNDO_STALE'});
  assert.equal(db.prepare('SELECT start_min FROM blocks WHERE inbox_id=?').get(f.a.id).start_min,900);
  assert.equal(db.prepare("SELECT count(*) n FROM blocks WHERE user_id=? AND title='合成新安排'").get(f.uid).n,1);
  assert.equal(db.prepare('SELECT status FROM ai_plan_applications WHERE id=?').get(result.applicationId).status,'applied');
});

test('requirements require explicit acknowledgement; remainder can apply without another model call',()=>{
  const f=fixture((a,b)=>[move(a,900),move(b,1020)]);
  const policy=JSON.parse(db.prepare('SELECT ai_policy_json FROM schedule_drafts WHERE id=?').get(f.draft.id).ai_policy_json);
  policy.requirements=[{id:'duration-evidence',kind:'task_duration',taskId:f.a.id,value:60,source:'一个小时',confirmed:false}];
  db.prepare('UPDATE schedule_drafts SET ai_policy_json=? WHERE id=?').run(JSON.stringify(policy),f.draft.id);
  assert.throws(()=>actions.applyAiDraft(f.uid,f.draft.id),{code:'AI_REQUIREMENTS_INVALID'});
  const first=actions.applyAiDraft(f.uid,f.draft.id,{selectedChangeIds:[f.draft.changes[0].id],confirmedRequirementIds:['duration-evidence']});
  const last=actions.applyAiDraft(f.uid,first.remainingDraft.id);
  assert.equal(last.applied,1);assert.equal(last.remainingDraft,null);
  assert.equal(db.prepare('SELECT status FROM ai_planning_sessions WHERE id=?').get(f.sessionId).status,'applied');
  assert.equal(db.prepare('SELECT start_min FROM blocks WHERE inbox_id=?').get(f.b.id).start_min,1020);
});

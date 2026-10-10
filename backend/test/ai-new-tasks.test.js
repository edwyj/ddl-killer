import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
process.env.DB_PATH=':memory:';
const {db}=await import('../src/db.js');
const {createUserWithDefaultLists}=await import('../src/default-lists.js');
const {createDraft}=await import('../src/mcp-drafts.js');
const {parsePlanningProposal,buildPlanningContext}=await import('../src/ai-planner.js');
const {applyAiDraft,undoAiApplication}=await import('../src/ai-draft-actions.js');
const {saveTask}=await import('../src/task-planning.js');
const date=new Date(Date.now()+5*86400000).toISOString().slice(0,10);
let serial=0;
function fixture(changes){
 const uid=createUserWithDefaultLists(`new_task_${++serial}`,'unused'),sessionId=randomUUID(),now=Date.now();
 db.prepare("INSERT INTO ai_planning_sessions(id,user_id,mode,start_date,end_date,status,created_at,updated_at,expires_at) VALUES(?,?,'hosted',?,?,'active',?,?,?)").run(sessionId,uid,date,date,now,now,now+1800000);
 const draft=createDraft(uid,'ai-planner',changes,{policy:{sessionId,requirements:[],exceptions:[]}});
 db.prepare('UPDATE ai_planning_sessions SET current_draft_id=? WHERE id=?').run(draft.id,sessionId);
 return {uid,draft};
}
const newTask=(title,start=600)=>({op:'create_task',title,notes:'合成测试',estimateMinutes:60,dueDate:null,dueTime:null,date,start,end:start+60,reason:'先预留一小时，可再调整'});
test.after(()=>db.close());
test('a new task and its schedule are created only on confirmation, idempotently, and undo removes both',()=>{
 const f=fixture([newTask('合成作业')]);
 assert.equal(db.prepare('SELECT count(*) n FROM inbox WHERE user_id=?').get(f.uid).n,0);
 const applied=applyAiDraft(f.uid,f.draft.id);
 const task=db.prepare('SELECT * FROM inbox WHERE user_id=?').get(f.uid);
 assert.equal(task.title,'合成作业');assert.equal(task.estimate_minutes,60);
 assert.equal(db.prepare('SELECT start_min FROM blocks WHERE inbox_id=?').get(task.id).start_min,600);
 assert.deepEqual(applyAiDraft(f.uid,f.draft.id),applied);
 undoAiApplication(f.uid,applied.applicationId);
 assert.equal(db.prepare('SELECT count(*) n FROM inbox WHERE user_id=?').get(f.uid).n,0);
 assert.equal(db.prepare('SELECT count(*) n FROM blocks WHERE user_id=?').get(f.uid).n,0);
 assert.equal(saveTask(f.uid,task.id,{done:true}),null);
});
test('partial application creates only selected tasks, and undo refuses to delete a later edited task',()=>{
 const f=fixture([newTask('合成作业甲'),newTask('合成作业乙',720)]);
 const first=applyAiDraft(f.uid,f.draft.id,{selectedChangeIds:[f.draft.changes[0].id]});
 assert.equal(first.remainingDraft.changes.length,1);
 assert.equal(db.prepare('SELECT count(*) n FROM inbox WHERE user_id=?').get(f.uid).n,1);
 const task=db.prepare('SELECT id FROM inbox WHERE user_id=?').get(f.uid);
 saveTask(f.uid,task.id,{notes:'合成后续编辑'});
 assert.throws(()=>undoAiApplication(f.uid,first.applicationId),{code:'AI_UNDO_STALE'});
 const second=applyAiDraft(f.uid,first.remainingDraft.id);
 undoAiApplication(f.uid,second.applicationId);
 assert.equal(db.prepare('SELECT count(*) n FROM inbox WHERE user_id=?').get(f.uid).n,1);
});
test('new tasks without a schedule remain in the task list and generic MCP cannot create tasks through this operation',()=>{
 const c={...newTask('合成未排期'),estimateMinutes:null,date:null,start:null,end:null};
 const f=fixture([c]);applyAiDraft(f.uid,f.draft.id);
 assert.equal(db.prepare('SELECT count(*) n FROM inbox WHERE user_id=?').get(f.uid).n,1);
 assert.equal(db.prepare('SELECT count(*) n FROM blocks WHERE user_id=?').get(f.uid).n,0);
 assert.throws(()=>createDraft(f.uid,'synthetic-mcp',[c]),{code:'VALIDATION_FAILED'});
});
test('new tasks have strict fields, estimated duration and deadline validation before writes',()=>{
 const uid=createUserWithDefaultLists('new_parser_fixture','unused');
 const context=buildPlanningContext(uid,{startDate:date,endDate:date});
 const raw=changes=>({summary:'合成草案',changes,questions:[],warnings:[],requirements:[]});
 assert.equal(parsePlanningProposal(raw([newTask('合成任务')]),context).changes[0].op,'create_task');
 for(const c of [{...newTask('合成任务'),estimateMinutes:-1},{...newTask('合成任务'),dueTime:600},
   {...newTask('合成任务'),dueDate:'2026-02-30'}, {...newTask('合成任务'),userId:123}])
   assert.throws(()=>parsePlanningProposal(raw([c]),context),{code:'AI_PROPOSAL_INVALID'});
 const f=fixture([{...newTask('合成太短'),estimateMinutes:90}]);
 assert.throws(()=>applyAiDraft(f.uid,f.draft.id),{code:'AI_PLAN_CONFLICT'});
 assert.equal(db.prepare('SELECT count(*) n FROM inbox WHERE user_id=?').get(f.uid).n,0);
});
test('a task added between generation and confirmation prevents duplicate creation',()=>{
 const f=fixture([newTask('合成并发添加')]);
 saveTask(f.uid,null,{title:'合成并发添加'});
 assert.throws(()=>applyAiDraft(f.uid,f.draft.id),{code:'AI_PLAN_CONFLICT'});
 assert.equal(db.prepare('SELECT count(*) n FROM inbox WHERE user_id=?').get(f.uid).n,1);
});

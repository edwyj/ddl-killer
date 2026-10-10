import {randomUUID} from 'node:crypto';
import {db} from './db.js';
import {applyDraft,createDraft,calendarWarnings} from './mcp-drafts.js';
import {assertAiPlan,validateAiPlan} from './ai-plan-rules.js';
import {planningStateRevision} from './ai-planner.js';

const fail=(code,message)=>Object.assign(new Error(message),{code});
const taskState=(uid,id)=>({
  task:db.prepare('SELECT * FROM inbox WHERE id=? AND user_id=?').get(id,uid)??null,
  block:db.prepare('SELECT * FROM blocks WHERE inbox_id=? AND user_id=?').get(id,uid)??null,
});
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);

export function applyAiDraft(userId,draftId,options={}) {
  const row=db.prepare("SELECT * FROM schedule_drafts WHERE id=? AND user_id=? AND created_by_client_id='ai-planner'").get(draftId,userId);
  if(!row)throw fail('OBJECT_NOT_FOUND','AI 方案不存在');
  if(db.prepare("SELECT 1 FROM ai_plan_applications WHERE draft_id=? AND user_id=? AND status='undone'").get(draftId,userId))
    throw fail('DRAFT_ALREADY_UNDONE','这次应用已经撤销，请重新生成方案');
  const policy=JSON.parse(row.ai_policy_json||'{}');
  const sessionId=policy.sessionId??db.prepare('SELECT session_id FROM ai_planning_turns WHERE draft_id=? AND user_id=?').get(draftId,userId)?.session_id;
  const session=db.prepare('SELECT * FROM ai_planning_sessions WHERE id=? AND user_id=?').get(sessionId,userId);
  if(!session)throw fail('OBJECT_NOT_FOUND','AI 会话不存在');
  const requirements=policy.requirements??[],exceptions=policy.exceptions??[];
  let before;
  return applyDraft(userId,'ai-planner',draftId,{
    selectedChangeIds:options.selectedChangeIds,
    beforeApply:({changes})=>{
      const currentSession=db.prepare('SELECT * FROM ai_planning_sessions WHERE id=? AND user_id=?').get(sessionId,userId);
      if(currentSession?.current_draft_id!==draftId || !['active','closed'].includes(currentSession.status) || currentSession.expires_at<=Date.now())
        throw fail('DRAFT_STALE','这份方案已不再是当前方案，请重新规划');
      const confirmed=options.confirmedRequirementIds??[];
      if(!Array.isArray(confirmed) || confirmed.some(id=>!requirements.some(r=>r.id===id)) ||
          requirements.some(r=>!r.confirmed&&!confirmed.includes(r.id)))
        throw fail('AI_REQUIREMENTS_INVALID','请先确认方案上方列出的本次要求');
      if(exceptions.length && policy.revision!==planningStateRevision(userId))
        throw fail('DRAFT_STALE','日程已经变化，请重新确认冲突例外');
      assertAiPlan(userId,changes,requirements,exceptions);
      before=changes.filter(c=>c.taskId!=null).map(c=>({id:c.taskId,...taskState(userId,c.taskId)}));
    },
    afterApply:({changes,allChanges,createdBlockIds,createdTaskIds})=>{
      const applicationId=randomUUID();
      const after={tasks:before.map(t=>({id:t.id,...taskState(userId,t.id)})),
        blocks:createdBlockIds.map(id=>db.prepare('SELECT * FROM blocks WHERE id=? AND user_id=?').get(id,userId)),
        createdTasks:createdTaskIds.map(id=>({id,...taskState(userId,id)}))};
      db.prepare('INSERT INTO ai_plan_applications(id,user_id,session_id,draft_id,before_json,after_json,created_at) VALUES(?,?,?,?,?,?,?)')
        .run(applicationId,userId,sessionId,draftId,JSON.stringify(before),JSON.stringify(after),Date.now());
      const accepted=requirements.map(r=>({...r,confirmed:true}));
      const remaining=allChanges.filter(c=>!changes.includes(c));
      let remainingDraft=null;
      if(remaining.length) {
        remainingDraft=createDraft(userId,'ai-planner',remaining,{policy:{sessionId,requirements:accepted,exceptions:[],revision:planningStateRevision(userId)}});
        remainingDraft.warnings=validateAiPlan(userId,remaining,accepted,[]);
        db.prepare('UPDATE schedule_drafts SET warnings_json=? WHERE id=?').run(JSON.stringify(remainingDraft.warnings),remainingDraft.id);
      }
      db.prepare('UPDATE ai_planning_sessions SET current_draft_id=?,status=?,requirements_json=?,exceptions_json=?,exceptions_revision=NULL,updated_at=? WHERE id=? AND user_id=?')
        .run(remainingDraft?.id??draftId,remainingDraft?'active':'applied',JSON.stringify(accepted),'[]',Date.now(),sessionId,userId);
      return {applicationId,selectedChangeIds:changes.map(c=>c.id).sort(),remainingDraft};
    },
  });
}

export function undoAiApplication(userId,id) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const row=db.prepare('SELECT * FROM ai_plan_applications WHERE id=? AND user_id=?').get(id,userId);
    if(!row)throw fail('OBJECT_NOT_FOUND','应用记录不存在');
    if(row.status==='undone') {db.exec('COMMIT');return JSON.parse(row.result_json);}
    const before=JSON.parse(row.before_json),after=JSON.parse(row.after_json);
    const stale=()=>fail('AI_UNDO_STALE','相关任务或日程已经变化，无法直接撤销，请重新规划');
    for(const expected of after.tasks) {
      const current=taskState(userId,expected.id);
      if(!same(current.task,expected.task)||!same(current.block,expected.block))throw stale();
    }
    for(const expected of after.createdTasks??[]) {
      const current=taskState(userId,expected.id);
      if(!same(current.task,expected.task)||!same(current.block,expected.block))throw stale();
      db.prepare('DELETE FROM blocks WHERE inbox_id=? AND user_id=?').run(expected.id,userId);
      db.prepare('DELETE FROM inbox WHERE id=? AND user_id=?').run(expected.id,userId);
    }
    for(const expected of after.blocks) {
      if(!same(db.prepare('SELECT * FROM blocks WHERE id=? AND user_id=?').get(expected.id,userId),expected))throw stale();
      // Removed inside this transaction so restoring a task never conflicts with a block
      // this same application is about to undo. Any failure rolls this deletion back.
      db.prepare('DELETE FROM blocks WHERE id=? AND user_id=?').run(expected.id,userId);
    }
    const restore=before.map(t=>t.block&&!t.block.deleted_at?
      {op:'schedule_task',taskId:t.id,date:t.block.date,start:t.block.start_min,end:t.block.end_min}:
      {op:'unschedule_task',taskId:t.id});
    if(calendarWarnings(userId,restore).length)throw stale();
    const columns=db.prepare('PRAGMA table_info(blocks)').all().map(c=>c.name);
    for(const expected of before) {
      const current=taskState(userId,expected.id).block;
      if(current)db.prepare('DELETE FROM blocks WHERE id=? AND user_id=?').run(current.id,userId);
      if(expected.block) {
        if(db.prepare('SELECT 1 FROM blocks WHERE id=?').get(expected.block.id))throw stale();
        const restored={...expected.block,version:Math.max(expected.block.version,current?.version??0)+1,
          restore_epoch:Math.max(expected.block.restore_epoch??0,current?.restore_epoch??0)+1};
        db.prepare(`INSERT INTO blocks(${columns.join(',')}) VALUES(${columns.map(()=>'?').join(',')})`)
          .run(...columns.map(c=>restored[c]??null));
      }
      db.prepare('UPDATE inbox SET restore_epoch=restore_epoch+1,version=version+1 WHERE id=? AND user_id=?').run(expected.id,userId);
    }
    const result={applicationId:id,status:'undone'};
    db.prepare("UPDATE ai_plan_applications SET status='undone',undone_at=?,result_json=? WHERE id=? AND user_id=?")
      .run(Date.now(),JSON.stringify(result),id,userId);
    db.prepare("UPDATE ai_planning_sessions SET updated_at=?,status=CASE WHEN status='applied' AND current_draft_id=? THEN 'closed' ELSE status END WHERE id=? AND user_id=?").run(Date.now(),row.draft_id,row.session_id,userId);
    db.exec('COMMIT');
    return result;
  }catch(error){db.exec('ROLLBACK');throw error;}
}

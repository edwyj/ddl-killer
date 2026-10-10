import { db } from './db.js';
import { getDraft } from './mcp-drafts.js';
import {visibleRequirements} from './ai-requirements.js';
import {planningStateRevision} from './ai-planner.js';

export const AI_HISTORY_DAYS = 30;
const MAX_HISTORY = 20;

function notFound() {
  return Object.assign(new Error('AI 会话不存在'), { code: 'OBJECT_NOT_FOUND' });
}

function refreshExpiry(userId, id) {
  db.prepare(`UPDATE ai_planning_sessions SET status='expired',updated_at=?
    WHERE id=? AND user_id=? AND status='active' AND expires_at<=?`)
    .run(Date.now(), id, userId, Date.now());
}

function optionalDraft(userId, id) {
  if (!id) return null;
  try { return getDraft(userId, id); } catch { return null; }
}

function turnView(userId, row) {
  return {
    id: row.id,
    input: row.input_text,
    proposal: JSON.parse(row.proposal_json),
    draft: optionalDraft(userId, row.draft_id),
    createdAt: row.created_at,
  };
}

function summaryView(row) {
  const proposal = row.proposal_json ? JSON.parse(row.proposal_json) : null;
  return {
    id: row.id,
    status: row.status,
    mode: row.mode,
    firstMessage: row.input_text || '',
    summary: proposal?.summary || '',
    hasPendingDraft: row.draft_status === 'pending' && JSON.parse(row.draft_changes||'[]').length>0,
    currentDraftId: row.current_draft_id,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    expiresAt: row.expires_at,
  };
}

export function listAiSessions(userId, { limit = MAX_HISTORY } = {}) {
  db.prepare(`UPDATE ai_planning_sessions SET status='expired',updated_at=?
    WHERE user_id=? AND status='active' AND expires_at<=?`).run(Date.now(), userId, Date.now());
  const bounded = Math.min(Math.max(Number(limit) || MAX_HISTORY, 1), MAX_HISTORY);
  return db.prepare(`SELECT s.*,
      (SELECT input_text FROM ai_planning_turns WHERE session_id=s.id AND user_id=s.user_id ORDER BY created_at ASC LIMIT 1) input_text,
      (SELECT proposal_json FROM ai_planning_turns WHERE session_id=s.id AND user_id=s.user_id ORDER BY created_at DESC LIMIT 1) proposal_json,
      d.status draft_status,d.changes_json draft_changes
    FROM ai_planning_sessions s
    LEFT JOIN schedule_drafts d ON d.id=s.current_draft_id AND d.user_id=s.user_id
    WHERE s.user_id=? ORDER BY s.updated_at DESC,s.created_at DESC LIMIT ?`).all(userId, bounded).map(summaryView);
}

export function getAiSessionView(userId, id) {
  refreshExpiry(userId, id);
  const row = db.prepare('SELECT * FROM ai_planning_sessions WHERE id=? AND user_id=?').get(id, userId);
  if (!row) throw notFound();
  const turns = db.prepare(`SELECT * FROM ai_planning_turns
    WHERE session_id=? AND user_id=? ORDER BY created_at,id`).all(id, userId).map((turn) => turnView(userId, turn));
  return {
    id: row.id,
    status: row.status,
    mode: row.mode,
    startDate: row.start_date,
    endDate: row.end_date,
    currentDraftId: row.current_draft_id,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    expiresAt: row.expires_at,
    turns,
    requirements: visibleRequirements(userId,JSON.parse(row.requirements_json||'[]')),
    exceptions: JSON.parse(row.exceptions_json||'[]'),
    exceptionsRevision: row.exceptions_revision,
    exceptionsStale: JSON.parse(row.exceptions_json||'[]').length>0 && row.exceptions_revision!==planningStateRevision(userId),
    currentDraft: optionalDraft(userId,row.current_draft_id),
    applications: db.prepare('SELECT id,draft_id,status,created_at,undone_at,after_json FROM ai_plan_applications WHERE session_id=? AND user_id=? ORDER BY created_at DESC').all(id,userId)
      .map(({after_json,...application})=>{const after=JSON.parse(after_json);return {...application,applied:after.tasks.length+after.blocks.length+(after.createdTasks?.length??0)};}),
  };
}

export function closeAiSession(userId, id) {
  const result = db.prepare(`UPDATE ai_planning_sessions SET status='closed',updated_at=?
    WHERE id=? AND user_id=? AND status='active'`).run(Date.now(), id, userId);
  if (!result.changes && !db.prepare('SELECT 1 FROM ai_planning_sessions WHERE id=? AND user_id=?').get(id, userId)) {
    throw notFound();
  }
  return getAiSessionView(userId, id);
}

export function deleteAiSession(userId, id) {
  const row = db.prepare('SELECT current_draft_id FROM ai_planning_sessions WHERE id=? AND user_id=?').get(id, userId);
  if (!row) throw notFound();
  db.exec('SAVEPOINT delete_ai_session');
  try {
    removeSessionDrafts(userId,id,row.current_draft_id);
    db.prepare('DELETE FROM ai_plan_applications WHERE session_id=? AND user_id=?').run(id, userId);
    db.prepare('DELETE FROM ai_planning_turns WHERE session_id=? AND user_id=?').run(id, userId);
    db.prepare('DELETE FROM ai_planning_sessions WHERE id=? AND user_id=?').run(id, userId);
    db.exec('RELEASE delete_ai_session');
  } catch (error) {
    db.exec('ROLLBACK TO delete_ai_session; RELEASE delete_ai_session');
    throw error;
  }
  return { ok: true };
}

// Source quotes also live in policy/result JSON. Remainders have no turn, so
// collect through policy session ownership as well as older turn references.
function removeSessionDrafts(userId,id,currentDraftId) {
  const ids=new Set([currentDraftId,
    ...db.prepare('SELECT draft_id FROM ai_planning_turns WHERE session_id=? AND user_id=?').all(id,userId).map(r=>r.draft_id),
    ...db.prepare('SELECT draft_id FROM ai_plan_applications WHERE session_id=? AND user_id=?').all(id,userId).map(r=>r.draft_id)]);
  const drafts=db.prepare("SELECT id,ai_policy_json FROM schedule_drafts WHERE user_id=? AND created_by_client_id='ai-planner'").all(userId);
  for(const draft of drafts) {
    let policy;try{policy=JSON.parse(draft.ai_policy_json||'{}');}catch{policy={};}
    if(ids.has(draft.id)||policy.sessionId===id)
      db.prepare("DELETE FROM schedule_drafts WHERE id=? AND user_id=? AND created_by_client_id='ai-planner'").run(draft.id,userId);
  }
}

export function markAiSessionApplied(userId, id, draftId) {
  const result = db.prepare(`UPDATE ai_planning_sessions SET status='applied',updated_at=?
    WHERE id=? AND user_id=? AND current_draft_id=?`).run(Date.now(), id, userId, draftId);
  if (!result.changes) throw notFound();
}

export function purgeExpiredAiHistory(now = Date.now()) {
  const before = now - AI_HISTORY_DAYS * 86400000;
  db.prepare("UPDATE ai_planning_sessions SET status='expired',updated_at=? WHERE status='active' AND expires_at<=?")
    .run(now, now);
  const ids = db.prepare(`SELECT id,user_id FROM ai_planning_sessions
    WHERE status IN ('closed','expired','applied') AND updated_at<?`).all(before);
  let turns = 0;
  db.exec('SAVEPOINT purge_ai_history');
  try {
    for (const row of ids) {
      removeSessionDrafts(row.user_id,row.id,db.prepare('SELECT current_draft_id FROM ai_planning_sessions WHERE id=? AND user_id=?').get(row.id,row.user_id)?.current_draft_id);
      db.prepare('DELETE FROM ai_plan_applications WHERE session_id=? AND user_id=?').run(row.id, row.user_id);
      turns += db.prepare('DELETE FROM ai_planning_turns WHERE session_id=? AND user_id=?').run(row.id, row.user_id).changes;
      db.prepare('DELETE FROM ai_planning_sessions WHERE id=? AND user_id=?').run(row.id, row.user_id);
    }
    db.exec('RELEASE purge_ai_history');
  } catch (error) {
    db.exec('ROLLBACK TO purge_ai_history; RELEASE purge_ai_history');
    throw error;
  }
  return { aiSessions: ids.length, aiTurns: turns };
}

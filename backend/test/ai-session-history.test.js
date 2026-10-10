import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import test from 'node:test';

process.env.DB_PATH = ':memory:';
process.env.JWT_SECRET = 'ai-history-test-secret-at-least-32-chars';
process.env.AI_KEY_ENCRYPTION_KEYS = `v1:${randomBytes(32).toString('base64')}`;
process.env.AI_FEATURE_ENABLED = 'true';
process.env.AI_HOSTED_ENABLED = 'true';
process.env.AI_HOSTED_DAILY_LIMIT = '100';
process.env.AI_HOSTED_GLOBAL_DAILY_LIMIT = '1000';
process.env.AI_HOSTED_DEEPSEEK_KEY = 'sk-history-sentinel';

const { db } = await import('../src/db.js');
const { createApp } = await import('../src/app.js');
const { createUserWithDefaultLists } = await import('../src/default-lists.js');
const { saveTask } = await import('../src/task-planning.js');
const { purgeExpired } = await import('../src/retention.js');
const bcrypt = (await import('bcryptjs')).default;

const password = 'History-owner-password-123';
const owner = createUserWithDefaultLists('history_owner', bcrypt.hashSync(password, 10));
const other = createUserWithDefaultLists('history_other', bcrypt.hashSync(password, 10));
const task = saveTask(owner, null, { title: '恢复这份安排', priority: 2,estimate_minutes:60 });
const dateAt = (offset) => {
  const date = new Date();
  date.setUTCDate(date.getUTCDate() + offset);
  return date.toISOString().slice(0, 10);
};

const generate = async () => ({
  value: {
    summary: '我先为你留出一小时，你可以继续调整。',
    changes: [{
      op: 'schedule_task', taskId: task.id, date: dateAt(2),
      start: 600, end: 660, reason: '这段时间目前没有其他安排',
    }],
    questions: [], warnings: [],
  },
  usage: { promptTokens: 10, completionTokens: 5 },
});

const app = createApp({ ai: { generate } });
const server = app.listen(0, '127.0.0.1');
await new Promise((resolve) => server.once('listening', resolve));
test.after(() => { server.close(); db.close(); });
const base = `http://127.0.0.1:${server.address().port}`;

async function call(path, method = 'GET', body, token) {
  const response = await fetch(base + path, {
    method,
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  return { status: response.status, data: await response.json() };
}
const login = async (username) =>
  (await call('/api/auth/login', 'POST', { username, password })).data.token;
const createSession = (token, message = '帮我安排任务') => call('/api/ai/sessions', 'POST', {
  startDate: dateAt(1), endDate: dateAt(5), message,
}, token);

test('closing keeps turns and pending draft available through list and detail', async () => {
  const token = await login('history_owner');
  const made = await createSession(token, '下周帮我安排一小时');
  assert.equal(made.status, 201);

  const closed = await call(`/api/ai/sessions/${made.data.sessionId}/close`, 'POST', {}, token);
  assert.equal(closed.status, 200);
  assert.equal(closed.data.status, 'closed');
  assert.ok(db.prepare('SELECT 1 FROM ai_planning_turns WHERE session_id=?').get(made.data.sessionId));
  assert.equal(db.prepare('SELECT status FROM schedule_drafts WHERE id=?').get(made.data.draft.id).status, 'pending');

  const listed = await call('/api/ai/sessions?limit=20', 'GET', null, token);
  assert.equal(listed.status, 200);
  assert.equal(listed.data.items[0].firstMessage, '下周帮我安排一小时');
  assert.equal(listed.data.items[0].hasPendingDraft, true);

  const detail = await call(`/api/ai/sessions/${made.data.sessionId}`, 'GET', null, token);
  assert.equal(detail.status, 200);
  assert.equal(detail.data.turns[0].input, '下周帮我安排一小时');
  assert.equal(detail.data.turns[0].draft.status, 'pending');
});

test('new session closes previous active and history is isolated and capped at twenty', async () => {
  const token = await login('history_owner');
  const stranger = await login('history_other');
  const first = await createSession(token, '第一份 active');
  const second = await createSession(token, '第二份 active');
  assert.equal(first.status, 201);
  assert.equal(second.status, 201);
  assert.equal(db.prepare('SELECT status FROM ai_planning_sessions WHERE id=?').get(first.data.sessionId).status, 'closed');
  assert.equal(db.prepare('SELECT status FROM ai_planning_sessions WHERE id=?').get(second.data.sessionId).status, 'active');
  assert.equal((await call(`/api/ai/sessions/${second.data.sessionId}`, 'GET', null, stranger)).status, 404);
  assert.equal((await call(`/api/ai/sessions/${second.data.sessionId}`, 'DELETE', null, stranger)).status, 404);

  const now = Date.now();
  for (let i = 0; i < 22; i += 1) {
    const id = randomUUID();
    db.prepare(`INSERT INTO ai_planning_sessions(
      id,user_id,mode,start_date,end_date,current_draft_id,status,created_at,updated_at,expires_at
    ) VALUES(?,?,?,?,?,NULL,'closed',?,?,?)`).run(
      id, owner, 'hosted', dateAt(1), dateAt(2), now + i, now + i, now + 60_000,
    );
    db.prepare(`INSERT INTO ai_planning_turns(
      id,session_id,user_id,input_text,proposal_json,draft_id,created_at
    ) VALUES(?,?,?,?,?,?,?)`).run(
      randomUUID(), id, owner, `历史 ${i}`, JSON.stringify({ summary: `摘要 ${i}`, changes: [], questions: [], warnings: [] }), `missing-${i}`, now + i,
    );
  }
  const listed = await call('/api/ai/sessions?limit=999', 'GET', null, token);
  assert.equal(listed.data.items.length, 20);
  assert.equal(listed.data.items[0].firstMessage, '历史 21');
});

test('apply marks session applied; permanent delete discards pending draft and removes rows', async () => {
  const token = await login('history_owner');
  const appliedSession = await createSession(token, '应用这份安排');
  const applied = await call(`/api/ai/drafts/${appliedSession.data.draft.id}/apply`, 'POST', {}, token);
  assert.equal(applied.status, 200);
  assert.equal(db.prepare('SELECT status FROM ai_planning_sessions WHERE id=?').get(appliedSession.data.sessionId).status, 'applied');

  const removable = await createSession(token, '随后删除');
  const removed = await call(`/api/ai/sessions/${removable.data.sessionId}`, 'DELETE', null, token);
  assert.equal(removed.status, 200);
  assert.equal(db.prepare('SELECT 1 FROM ai_planning_sessions WHERE id=?').get(removable.data.sessionId), undefined);
  assert.equal(db.prepare('SELECT 1 FROM ai_planning_turns WHERE session_id=?').get(removable.data.sessionId), undefined);
  assert.equal(db.prepare('SELECT status FROM schedule_drafts WHERE id=?').get(removable.data.draft.id), undefined);
});

test('retention removes only AI history older than thirty days', () => {
  const old = Date.now() - 31 * 86400000;
  const fresh = Date.now() - 29 * 86400000;
  const insert = (id, updatedAt) => db.prepare(`INSERT INTO ai_planning_sessions(
    id,user_id,mode,start_date,end_date,current_draft_id,status,created_at,updated_at,expires_at
  ) VALUES(?,?,?,?,?,NULL,'closed',?,?,?)`).run(
    id, owner, 'hosted', dateAt(1), dateAt(2), updatedAt, updatedAt, updatedAt,
  );
  insert('history-old', old);
  insert('history-fresh', fresh);
  db.prepare(`INSERT INTO ai_planning_turns(id,session_id,user_id,input_text,proposal_json,draft_id,created_at) VALUES(?,?,?,?,?,?,?)`).run(
    randomUUID(), 'history-old', owner, '旧记录', '{"summary":"旧","changes":[],"questions":[],"warnings":[]}', 'missing-old', old,
  );
  const result = purgeExpired(new Date());
  assert.equal(result.aiSessions >= 1, true);
  assert.equal(db.prepare("SELECT 1 FROM ai_planning_sessions WHERE id='history-old'").get(), undefined);
  assert.ok(db.prepare("SELECT 1 FROM ai_planning_sessions WHERE id='history-fresh'").get());
  assert.equal(db.prepare("SELECT 1 FROM ai_planning_turns WHERE session_id='history-old'").get(), undefined);
  assert.ok(db.prepare('SELECT 1 FROM inbox WHERE id=?').get(task.id));
});

test('deletion and retention remove source quotes from every AI draft including unlinked remainders',async()=>{
 const {createDraft}=await import('../src/mcp-drafts.js');
 const {deleteAiSession,purgeExpiredAiHistory}=await import('../src/ai-session-history.js');
 for(const purge of [false,true]){
  const id=randomUUID(),now=Date.now()-31*86400000;
  db.prepare("INSERT INTO ai_planning_sessions(id,user_id,mode,start_date,end_date,status,created_at,updated_at,expires_at) VALUES(?,?,'hosted',?,?,'closed',?,?,?)").run(id,owner,dateAt(1),dateAt(2),now,now,now);
  const policy={sessionId:id,requirements:[{source:'PRIVATE-SOURCE-SENTINEL'}]};
  const original=createDraft(owner,'ai-planner',[],{policy});
  const remainder=createDraft(owner,'ai-planner',[],{policy});
  db.prepare('UPDATE schedule_drafts SET result_json=? WHERE id=?').run(JSON.stringify({remainingDraft:{requirements:policy.requirements}}),original.id);
  db.prepare('UPDATE ai_planning_sessions SET current_draft_id=? WHERE id=?').run(remainder.id,id);
  db.prepare('INSERT INTO ai_planning_turns(id,session_id,user_id,input_text,proposal_json,draft_id,created_at) VALUES(?,?,?,?,?,?,?)').run(randomUUID(),id,owner,'合成私有要求','{}',original.id,now);
  if(purge)purgeExpiredAiHistory();else deleteAiSession(owner,id);
  assert.equal(db.prepare('SELECT 1 FROM schedule_drafts WHERE id IN (?,?)').get(original.id,remainder.id),undefined);
 }
 assert.ok(db.prepare('SELECT 1 FROM inbox WHERE id=?').get(task.id));
});

test('history exposes scoped exceptions with the calendar revision and staleness',async()=>{
 const {getAiSessionView}=await import('../src/ai-session-history.js');
 const {planningStateRevision}=await import('../src/ai-planner.js');
 const id=randomUUID(),now=Date.now(),revision=planningStateRevision(owner);
 db.prepare("INSERT INTO ai_planning_sessions(id,user_id,mode,start_date,end_date,status,created_at,updated_at,expires_at,exceptions_json,exceptions_revision) VALUES(?,?,'hosted',?,?,'active',?,?,?,?,?)")
  .run(id,owner,dateAt(1),dateAt(2),now,now,now+1800000,JSON.stringify([{taskId:task.id,kind:'rest'}]),revision);
 const first=getAiSessionView(owner,id);
 assert.deepEqual(first.exceptions,[{taskId:task.id,kind:'rest'}]);assert.equal(first.exceptionsRevision,revision);assert.equal(first.exceptionsStale,false);
 saveTask(owner,task.id,{notes:'合成后续变化'});
 assert.equal(getAiSessionView(owner,id).exceptionsStale,true);
});

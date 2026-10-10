import assert from 'node:assert/strict';
import test from 'node:test';
import { randomBytes } from 'node:crypto';

process.env.DB_PATH = ':memory:';
process.env.RELEASE_CHANNEL = 'stable';
process.env.JWT_SECRET = 'ai-audit-isolated-test-secret-32-characters';
process.env.AI_KEY_ENCRYPTION_KEYS = `v1:${randomBytes(32).toString('base64')}`;
process.env.AI_FEATURE_ENABLED = 'true';
process.env.AI_HOSTED_ENABLED = 'true';
process.env.AI_HOSTED_DAILY_LIMIT = '100';
process.env.AI_HOSTED_GLOBAL_DAILY_LIMIT = '1000';
process.env.AI_FAILURE_COOLDOWN_SECONDS = '0';
process.env.AI_HOSTED_DEEPSEEK_KEY = 'sk-isolated-audit-fixture';
const { db } = await import('../src/db.js');
const { createApp } = await import('../src/app.js');
const { createUserWithDefaultLists } = await import('../src/default-lists.js');
const { saveTask } = await import('../src/task-planning.js');
const bcrypt = (await import('bcryptjs')).default;
let respond;
const seen = [];
const server = createApp({ ai: { generate: async args => {
  seen.push(args);
  return { value: await respond(args), usage: { promptTokens: 10, completionTokens: 10 } };
} } }).listen(0, '127.0.0.1');
await new Promise(resolve => server.once('listening', resolve));
test.after(() => { server.close(); db.close(); });
const base = `http://127.0.0.1:${server.address().port}`;
const date = new Date(Date.now() + 3 * 86400000).toISOString().slice(0,10);
async function request(path, body, token) {
  const response = await fetch(base + path, { method: 'POST',
    headers: { 'content-type':'application/json', ...(token ? {authorization:`Bearer ${token}`} : {}) },
    body: JSON.stringify(body) });
  return { status:response.status, data:await response.json() };
}
let sequence = 0;
async function fixture() {
  const username = `audit_user_${++sequence}`, password = 'Isolated-audit-password-123';
  const uid = createUserWithDefaultLists(username, bcrypt.hashSync(password, 10));
  const task = saveTask(uid, null, { title:'虚构报告任务',estimate_minutes:60 });
  const {data:{token}} = await request('/api/auth/login',{username,password});
  return {uid,task,token};
}
const proposal = task => ({summary:'先为报告留出一小时，等你确认。',changes:[{
  op:'schedule_task',taskId:task.id,date,start:600,end:660,reason:'留出完整时段',
}],questions:[],warnings:[]});
const reply = (summary, draftAction) => ({summary,changes:[],questions:[],warnings:[],
  ...(draftAction ? {draftAction} : {})});
const start = token => request('/api/ai/sessions',{startDate:date,endDate:date,message:'安排报告一小时'},token);
const turn = (token,id,message) => request(`/api/ai/sessions/${id}/turns`,{message},token);

test('asking for an explanation preserves the pending plan and its context', async () => {
  const {task,token}=await fixture();
  respond=()=>proposal(task);
  const first=await start(token);
  respond=()=>reply('先处理报告是因为你希望优先完成它。');
  const second=await turn(token,first.data.sessionId,'为什么这么安排？');
  assert.equal(second.status,200);
  assert.equal(second.data.draft.id,first.data.draft.id);
  assert.equal(second.data.draft.changes.length,1);
  assert.equal(db.prepare('SELECT status FROM schedule_drafts WHERE id=?').get(first.data.draft.id).status,'pending');
  assert.equal(second.data.quota.used,1);
  await turn(token,first.data.sessionId,'就保留这份方案');
  const payload=JSON.parse(seen.at(-1).messages.at(-1).content);
  assert.equal(payload.previous.changes[0].taskId,task.id);
  assert.equal(Object.hasOwn(payload.previous.changes[0],'id'),false);
  assert.equal(Object.hasOwn(payload.previous.changes[0],'before'),false);
  assert.equal(Object.hasOwn(payload.previous.changes[0],'title'),false);
});

test('explicitly cancelling a pending proposal discards it without touching the calendar', async () => {
  const {uid,task,token}=await fixture();
  respond=()=>proposal(task);
  const first=await start(token);
  respond=()=>reply('好的，这份待确认方案先取消，已有日程没有变化。','discard');
  const cancelled=await turn(token,first.data.sessionId,'不用这份方案了');
  assert.equal(cancelled.status,200);
  assert.equal(cancelled.data.draft.changes.length,0);
  assert.equal(db.prepare('SELECT status FROM schedule_drafts WHERE id=?').get(first.data.draft.id).status,'discarded');
  assert.equal(db.prepare('SELECT count(*) n FROM blocks WHERE user_id=?').get(uid).n,0);
});

test('a recently closed conversation resumes with its original context', async () => {
  const {task,token}=await fixture();
  respond=()=>proposal(task);
  const first=await start(token);
  await request(`/api/ai/sessions/${first.data.sessionId}/close`,{},token);
  respond=()=>reply('可以，保留这份待确认方案。');
  const resumed=await turn(token,first.data.sessionId,'还是原来那份安排');
  assert.equal(resumed.status,200);
  const payload=JSON.parse(seen.at(-1).messages.at(-1).content);
  assert.equal(payload.history[0].input,'安排报告一小时');
});

test('a calendar edit while the model is generating rejects its stale proposal', async () => {
  const {uid,task,token}=await fixture();
  let release,started;
  const began=new Promise(resolve=>started=resolve);
  respond=async()=>{started();await new Promise(resolve=>release=resolve);return proposal(task);};
  const pending=start(token);
  await began;
  saveTask(uid,task.id,{schedule:{date,start_min:900,end_min:960}});
  release();
  const response=await pending;
  assert.equal(response.status,409);
  assert.equal(response.data.code,'AI_CONTEXT_CHANGED');
  assert.equal(db.prepare('SELECT count(*) n FROM schedule_drafts WHERE user_id=?').get(uid).n,0);
  assert.equal(db.prepare('SELECT start_min FROM blocks WHERE inbox_id=?').get(task.id).start_min,900);
  assert.equal(db.prepare('SELECT used,reserved FROM ai_quota_daily WHERE user_id=?').get(uid).used,0);
});

test('exhausting schedule allowance does not prevent asking about the existing proposal', async () => {
  process.env.AI_HOSTED_DAILY_LIMIT='1';
  try {
    const {task,token}=await fixture();
    respond=()=>proposal(task);
    const first=await start(token);
    assert.equal(first.data.quota.remaining,0);
    respond=()=>reply('报告的截止时间比较近，所以先安排它。');
    const second=await turn(token,first.data.sessionId,'为什么先安排报告？');
    assert.equal(second.status,200);
    assert.equal(second.data.quota.used,1);
    respond=()=>({...proposal(task),summary:'调整到另一个时间',changes:[{...proposal(task).changes[0],start:720,end:780}]});
    const changed=await turn(token,first.data.sessionId,'改到中午');
    assert.equal(changed.status,429);
    assert.equal(changed.data.code,'AI_QUOTA_EXHAUSTED');
    assert.equal(db.prepare('SELECT status FROM schedule_drafts WHERE id=?').get(first.data.draft.id).status,'pending');
  } finally {process.env.AI_HOSTED_DAILY_LIMIT='100';}
});

test('the provider schema meets strict object requirements for all scheduling operations', async () => {
  const {task,token}=await fixture();
  respond=()=>proposal(task);
  await start(token);
  const schema=seen.at(-1).schema.schema;
  const visit=node=>{
    if (node.type==='object') {
      assert.equal(node.additionalProperties,false);
      assert.deepEqual([...node.required].sort(),Object.keys(node.properties).sort());
      for(const child of Object.values(node.properties)) visit(child);
    }
    if(node.items) visit(node.items);
    if(node.anyOf) node.anyOf.forEach(visit);
  };
  visit(schema);
  assert.equal(schema.properties.changes.items.anyOf.length,4);
});

test('an older seven-day client can plan next Saturday and create a task only after applying',async()=>{
  const {uid,token}=await fixture();
  const {localClock}=await import('../src/ai-availability.js');
  const {planningRequestDates}=await import('../src/ai-request-dates.js');
  const today=localClock().date,target=planningRequestDates('下周六',[],localClock())[0].date;
  respond=()=>{
    const p=JSON.parse(seen.at(-1).messages.find(m=>m.role==='user').content);
    assert.equal(p.context.dateReferences.find(r=>r.text==='下周六').date,target);
    assert.ok(p.context.range.endDate>=target);
    return {summary:'先给你新任务草案，确认后保存',questions:[],warnings:[],requirements:[],draftAction:'replace',changes:[{
      op:'create_task',title:'合成新增任务',notes:'',estimateMinutes:60,dueDate:null,dueTime:null,date:target,start:600,end:660,reason:'用户给出一小时',
    }]};
  };
  const response=await request('/api/ai/sessions',{startDate:today,endDate:new Date(Date.parse(today)+7*86400000).toISOString().slice(0,10),message:'下周六做合成新增任务，预计一小时'},token);
  assert.equal(response.status,201);
  assert.equal(db.prepare("SELECT count(*) n FROM inbox WHERE user_id=? AND title='合成新增任务'").get(uid).n,0);
  const applied=await request(`/api/ai/drafts/${response.data.draft.id}/apply`,{},token);
  assert.equal(applied.status,200);
  assert.equal(db.prepare("SELECT count(*) n FROM inbox WHERE user_id=? AND title='合成新增任务'").get(uid).n,1);
  const detail=await fetch(base+`/api/ai/sessions/${response.data.sessionId}`,{headers:{authorization:`Bearer ${token}`}}).then(r=>r.json());
  assert.equal(detail.applications[0].applied,1);
});

test('another account editing its tasks does not invalidate this account planning', async () => {
  const owner=await fixture(), other=await fixture();
  let release,started;
  const began=new Promise(resolve=>started=resolve);
  respond=async()=>{started();await new Promise(resolve=>release=resolve);return proposal(owner.task);};
  const pending=start(owner.token);
  await began;
  saveTask(other.uid,other.task.id,{title:'另一账号的修改'});
  release();
  assert.equal((await pending).status,201);
});

test('AI apply is idempotent and expired closed conversations cannot be resumed', async () => {
  const {uid,task,token}=await fixture();
  respond=()=>proposal(task);
  const first=await start(token);
  const path=`/api/ai/drafts/${first.data.draft.id}/apply`;
  assert.equal((await request(path,{},token)).status,200);
  assert.equal((await request(path,{},token)).status,200);
  assert.equal(db.prepare('SELECT count(*) n FROM blocks WHERE inbox_id=? AND user_id=?').get(task.id,uid).n,1);
  const next=await start(token);
  await request(`/api/ai/sessions/${next.data.sessionId}/close`,{},token);
  db.prepare('UPDATE ai_planning_sessions SET expires_at=? WHERE id=?').run(Date.now()-1,next.data.sessionId);
  const expired=await turn(token,next.data.sessionId,'继续修改');
  assert.equal(expired.status,410);
  assert.equal(expired.data.code,'AI_SESSION_EXPIRED');
});

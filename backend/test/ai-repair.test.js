import test from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
process.env.DB_PATH=':memory:';
process.env.JWT_SECRET='repair-fixture-secret-at-least-32-characters';
process.env.AI_KEY_ENCRYPTION_KEYS=`v1:${randomBytes(32).toString('base64')}`;
process.env.AI_FEATURE_ENABLED='true';process.env.AI_HOSTED_ENABLED='true';
process.env.AI_HOSTED_DEEPSEEK_KEY='synthetic-provider-key';
process.env.AI_HOSTED_GLOBAL_DAILY_LIMIT='100';
process.env.AI_FAILURE_COOLDOWN_SECONDS='30';
const {db}=await import('../src/db.js');
const {createApp}=await import('../src/app.js');
const {saveTask}=await import('../src/task-planning.js');
const {createUserWithDefaultLists}=await import('../src/default-lists.js');
const bcrypt=(await import('bcryptjs')).default;
const behaviors=new Map();
const date=new Date(Date.now()+3*86400000).toISOString().slice(0,10);
const generate=async args=>{
  const payload=JSON.parse(args.messages.find(m=>m.role==='user').content);
  const task=payload.context.tasks[0],state=behaviors.get(task.id);state.calls.push(args);
  if(state.kind==='network')throw Object.assign(new Error('private upstream body'),{code:'AI_PROVIDER_NETWORK_ERROR'});
  if(state.kind==='stale')saveTask(state.uid,task.id,{title:'合成后续修改'});
  if(state.kind==='invalid'||state.calls.length===1) {
    if(state.kind==='malformed')throw Object.assign(new Error('AI_PROVIDER_INVALID_RESPONSE'),{code:'AI_PROVIDER_INVALID_RESPONSE',usage:{promptTokens:10,completionTokens:5}});
    return {value:{summary:'错误方案',changes:[{op:'schedule_task',taskId:task.id,date,start:600,end:615}],questions:[],warnings:[]},usage:{promptTokens:10,completionTokens:5}};
  }
  return {value:{summary:'合成有效方案',changes:[{op:'schedule_task',taskId:task.id,date,start:600,end:660}],questions:[],warnings:[]},usage:{promptTokens:20,completionTokens:8}};
};
const server=createApp({ai:{generate}}).listen(0,'127.0.0.1');
await new Promise(r=>server.once('listening',r));
const base=`http://127.0.0.1:${server.address().port}`;
const request=async(path,body,token)=>{
 const response=await fetch(base+path,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body)});
 return {status:response.status,data:await response.json()};
};
let seq=0;
async function run(kind){
 const username=`repair_${++seq}`,password='Synthetic-password-123';
 const uid=createUserWithDefaultLists(username,bcrypt.hashSync(password,10));
 const task=saveTask(uid,null,{title:'合成修复任务',estimate_minutes:60});
 const state={kind,uid,calls:[]};behaviors.set(task.id,state);
 const token=(await request('/api/auth/login',{username,password})).data.token;
 const result=await request('/api/ai/sessions',{message:'安排合成任务',startDate:date,endDate:date},token);
 return {result,state,uid};
}
test.after(()=>{server.close();db.close();});
test('one repair uses two budgeted attempts, aggregates usage and consumes one allowance',async()=>{
 const {result,state,uid}=await run('repair');
 assert.equal(result.status,201);assert.equal(state.calls.length,2);assert.equal(result.data.repaired,true);
 assert.equal(result.data.quota.used,1);
 const attempts=db.prepare('SELECT charged_tokens,success FROM ai_generation_attempts WHERE user_id=?').all(uid);
 assert.deepEqual(attempts.map(a=>a.charged_tokens).sort((a,b)=>a-b),[15,28]);
 const audit=db.prepare('SELECT prompt_tokens,completion_tokens FROM ai_audit_log WHERE user_id=?').get(uid);
 assert.deepEqual({...audit},{prompt_tokens:30,completion_tokens:13});
 assert.match(state.calls[1].messages.at(-1).content,/DURATION_TOO_SHORT/);
 assert.equal(db.prepare('SELECT count(*) n FROM blocks WHERE user_id=?').get(uid).n,0);
});
test('repair cannot bypass the attempt budget',async()=>{
 process.env.AI_HOSTED_ATTEMPT_DAILY_LIMIT='1';
 try {
  const {result,state,uid}=await run('repair');
  assert.equal(result.status,429);assert.equal(result.data.code,'AI_BUDGET_EXHAUSTED');assert.equal(state.calls.length,1);
  assert.equal(db.prepare('SELECT sum(charged_tokens) n FROM ai_generation_attempts WHERE user_id=?').get(uid).n,15);
  assert.equal(db.prepare("SELECT count(*) n FROM ai_quota_reservations WHERE user_id=? AND state='consumed'").get(uid).n,0);
 }finally{delete process.env.AI_HOSTED_ATTEMPT_DAILY_LIMIT;}
});
test('the whole turn has a deadline even if a provider ignores cancellation',async()=>{
 const name='deadline_fixture',password='Synthetic-password-123';
 const uid=createUserWithDefaultLists(name,bcrypt.hashSync(password,10));
 saveTask(uid,null,{title:'合成超时任务',estimate_minutes:60});
 const token=(await request('/api/auth/login',{username:name,password})).data.token;
 let calls=0,signal;
 const deadlineServer=createApp({ai:{totalTimeoutMs:15,generate:args=>{calls++;signal=args.signal;return new Promise(()=>{});}}}).listen(0,'127.0.0.1');
 await new Promise(r=>deadlineServer.once('listening',r));
 try {
  const response=await fetch(`http://127.0.0.1:${deadlineServer.address().port}/api/ai/sessions`,{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:JSON.stringify({message:'合成超时测试',startDate:date,endDate:date})});
  assert.equal(response.status,502);assert.equal(calls,1);assert.equal(signal.aborted,true);
  assert.equal(db.prepare('SELECT count(*) n FROM ai_planning_turns WHERE user_id=?').get(uid).n,0);
 }finally{deadlineServer.close();}
});
test('two invalid results stop, release allowance and retain both attempt costs',async()=>{
 const {result,state,uid}=await run('invalid');
 assert.equal(result.status,400);assert.equal(state.calls.length,2);
 assert.equal(db.prepare('SELECT sum(charged_tokens) n FROM ai_generation_attempts WHERE user_id=?').get(uid).n,30);
  assert.equal(db.prepare("SELECT count(*) n FROM ai_quota_reservations WHERE user_id=? AND state='consumed'").get(uid).n,0);
  assert.equal(result.data.retryAfterSeconds,undefined);
  const {beginHostedAttempt,finishHostedAttempt}=await import('../src/ai-quota.js');
  const next=beginHostedAttempt(uid,100);
  finishHostedAttempt(next,{promptTokens:1,completionTokens:1},true);
});
test('malformed JSON retains usage and network/context failures never trigger repair',async()=>{
 const malformed=await run('malformed');
 assert.equal(malformed.result.status,201);assert.equal(malformed.state.calls.length,2);
 assert.equal(db.prepare('SELECT sum(charged_tokens) n FROM ai_generation_attempts WHERE user_id=?').get(malformed.uid).n,43);
 for(const kind of ['network','stale']){
  const {result,state}=await run(kind);assert.equal(state.calls.length,1);
  assert.equal(result.status,kind==='stale'?409:502);
 }
});

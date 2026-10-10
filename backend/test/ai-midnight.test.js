import test from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
process.env.DB_PATH=':memory:';
process.env.JWT_SECRET='synthetic-midnight-secret-at-least-32-characters';
process.env.AI_KEY_ENCRYPTION_KEYS=`v1:${randomBytes(32).toString('base64')}`;
process.env.AI_FEATURE_ENABLED='true';process.env.AI_HOSTED_ENABLED='true';
process.env.AI_HOSTED_DEEPSEEK_KEY='synthetic-unused-key';
process.env.AI_HOSTED_DAILY_LIMIT='100';process.env.AI_HOSTED_GLOBAL_DAILY_LIMIT='100';
const {db}=await import('../src/db.js');
const {createApp}=await import('../src/app.js');
const {createUserWithDefaultLists}=await import('../src/default-lists.js');
const {issueSession}=await import('../src/security.js');
test.after(()=>db.close());
test('a reply finishing after midnight retains the original user date on follow-up',async()=>{
 const original=Date.now;let now=Date.parse('2026-10-08T15:59:50Z');Date.now=()=>now;
 const payloads=[];
 const uid=createUserWithDefaultLists('synthetic_midnight','unused');
 const token=issueSession({id:uid,username:'synthetic_midnight'});
 const server=createApp({ai:{generate:async({messages})=>{
   payloads.push(JSON.parse(messages.find(m=>m.role==='user').content));
   if(payloads.length===1)now=Date.parse('2026-10-08T16:00:10Z');
   return {value:{summary:'合成询问',changes:[],questions:['需要多长时间？'],warnings:[],requirements:[],draftAction:'keep'},usage:{promptTokens:1,completionTokens:1}};
 }}}).listen(0,'127.0.0.1');
 await new Promise(r=>server.once('listening',r));
 try{
  const send=(path,body)=>fetch(`http://127.0.0.1:${server.address().port}${path}`,{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:JSON.stringify(body)}).then(r=>r.json());
  const first=await send('/api/ai/sessions',{message:'明天做合成作业',startDate:'2026-10-08',endDate:'2026-10-21'});
  await send(`/api/ai/sessions/${first.sessionId}/turns`,{message:'一小时，按刚才的日期排'});
  assert.equal(payloads[0].context.dateReferences[0].date,'2026-10-09');
  assert.equal(payloads[1].context.dateReferences[0].date,'2026-10-09');
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));Date.now=original;}
});

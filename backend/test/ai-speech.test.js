import assert from 'node:assert/strict';
import test from 'node:test';
import {randomBytes} from 'node:crypto';
process.env.DB_PATH=':memory:';
process.env.JWT_SECRET='test-speech-secret-at-least-32-characters';
process.env.ASR_SILICONFLOW_KEY='private-test-key';
process.env.ASR_ENABLED='true';
const {db}=await import('../src/db.js');
const {validateWav,transcribeSpeech}=await import('../src/ai-speech.js');
 db.prepare('INSERT INTO users(id,username,password_hash) VALUES(1,?,?)').run('voice-owner','unused');
test.beforeEach(()=>{db.exec('DELETE FROM asr_daily_usage');process.env.ASR_USER_DAILY_SECONDS='600';});
function wav(seconds=1){
 const b=Buffer.alloc(44+seconds*32000);
 b.write('RIFF');b.writeUInt32LE(b.length-8,4);b.write('WAVEfmt ',8);
 b.writeUInt32LE(16,16);b.writeUInt16LE(1,20);b.writeUInt16LE(1,22);
 b.writeUInt32LE(16000,24);b.writeUInt32LE(32000,28);b.writeUInt16LE(2,32);
 b.writeUInt16LE(16,34);b.write('data',36);b.writeUInt32LE(b.length-44,40);
 return b;
}
test('WAV duration is derived from bytes, malformed and long uploads rejected',()=>{
 assert.equal(validateWav(wav(10)).seconds,10);
 assert.throws(()=>validateWav(wav(61)),{code:'ASR_AUDIO_INVALID'});
 assert.throws(()=>validateWav(Buffer.from('bad')),{code:'ASR_AUDIO_INVALID'});
 const b=wav();b.writeUInt32LE(48000,24);
 assert.throws(()=>validateWav(b),{code:'ASR_AUDIO_INVALID'});
});
test('speech route requires a user session, trusted origin and validates before provider',async()=>{
 process.env.AI_FEATURE_ENABLED='true';
 process.env.AI_KEY_ENCRYPTION_KEYS=`v1:${randomBytes(32).toString('base64')}`;
 process.env.ASR_USER_DAILY_SECONDS='600';
 const {createApp}=await import('../src/app.js');
 const {issueSession}=await import('../src/security.js');
 const token=issueSession({id:1,username:'voice-owner'});
 let calls=0;
 const app=createApp({speech:{fetcher:async()=>{calls++;return {ok:true,json:async()=>({text:'安排复习'})};}}});
 const server=app.listen(0,'127.0.0.1');await new Promise(resolve=>server.once('listening',resolve));
 const url=`http://127.0.0.1:${server.address().port}/api/ai/speech`;
 const send=(headers,body)=>fetch(url,{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(body)});
 try{
  assert.equal((await send({},{})).status,401);
  assert.equal((await send({Authorization:`Bearer ${token}`,Origin:'https://evil.example'},{})).status,403);
  assert.equal((await send({Authorization:`Bearer ${token}`},{audio_base64:'not-wav'})).status,400);
  assert.equal(calls,0);
  const r=await send({Authorization:`Bearer ${token}`},{audio_base64:wav().toString('base64')});
  assert.equal(r.status,200);assert.deepEqual(await r.json(),{text:'安排复习'});assert.equal(calls,1);
 }finally{await new Promise(resolve=>server.close(resolve));}
});
test('daily budgets survive calls, upstream failure is sanitized and no audio is persisted',async()=>{

 process.env.ASR_USER_DAILY_SECONDS='2';
 let called=0;
 const fetcher=async(url,options)=>{
  called++;assert.equal(url,'https://api.siliconflow.cn/v1/audio/transcriptions');
  assert.equal(options.body.get('model'),'FunAudioLLM/SenseVoiceSmall');
  assert.equal(options.body.get('file').type,'audio/wav');
  assert.equal(options.headers.Authorization,'Bearer private-test-key');
  return {ok:true,json:async()=>({text:'明天复习高数'})};
 };
 assert.equal(await transcribeSpeech(1,wav().toString('base64'),{fetcher}),'明天复习高数');
 await assert.rejects(transcribeSpeech(1,wav().toString('base64'),{fetcher:async()=>{throw new Error('private-test-key');}}),{code:'ASR_UNAVAILABLE'});
 await assert.rejects(transcribeSpeech(1,wav().toString('base64'),{fetcher}),{code:'ASR_BUDGET_EXHAUSTED'});
 assert.equal(called,1);
 assert.ok(!JSON.stringify(db.prepare('SELECT * FROM asr_daily_usage').all()).includes('private-test-key'));
});

import express from 'express';
import {db} from './db.js';
import {auth,limit,asyncRoute} from './security.js';

const active = new Set();
const fail = code => Object.assign(new Error(code),{code});
db.exec(`CREATE TABLE IF NOT EXISTS asr_daily_usage (
 user_id INTEGER NOT NULL, day TEXT NOT NULL, seconds INTEGER NOT NULL,
 PRIMARY KEY(user_id,day));`);

// Accept only the canonical 16kHz mono PCM WAV produced by our recorder.
// A client-supplied duration must never determine the billable budget.
export function validateWav(b) {
 if(!Buffer.isBuffer(b)||b.length<44||b.length>44+60*32000||
 b.toString('ascii',0,4)!=='RIFF'||b.readUInt32LE(4)!==b.length-8||
 b.toString('ascii',8,16)!=='WAVEfmt '||b.readUInt32LE(16)!==16||
 b.readUInt16LE(20)!==1||b.readUInt16LE(22)!==1||b.readUInt32LE(24)!==16000||
 b.readUInt32LE(28)!==32000||b.readUInt16LE(32)!==2||b.readUInt16LE(34)!==16||
 b.toString('ascii',36,40)!=='data'||b.readUInt32LE(40)!==b.length-44||
 (b.length-44)%2!==0||b.length<44+16000)throw fail('ASR_AUDIO_INVALID');
 return {seconds:Math.ceil((b.length-44)/32000)};
}
function budget(userId,seconds){
 const day=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
 const userMax=Number(process.env.ASR_USER_DAILY_SECONDS||600);
 const globalMax=Number(process.env.ASR_GLOBAL_DAILY_SECONDS||3600);
 if(!Number.isSafeInteger(userMax)||userMax<1||!Number.isSafeInteger(globalMax)||globalMax<1)throw fail('ASR_DISABLED');
 db.exec('BEGIN IMMEDIATE');
 try{
  db.prepare('DELETE FROM asr_daily_usage WHERE day<?').run(day);
  const used=db.prepare('SELECT seconds FROM asr_daily_usage WHERE user_id=? AND day=?').get(userId,day)?.seconds||0;
  const total=db.prepare('SELECT coalesce(sum(seconds),0) n FROM asr_daily_usage WHERE day=?').get(day).n;
  if(used+seconds>userMax||total+seconds>globalMax)throw fail('ASR_BUDGET_EXHAUSTED');
  db.prepare(`INSERT INTO asr_daily_usage VALUES(?,?,?) ON CONFLICT(user_id,day) DO UPDATE SET seconds=seconds+excluded.seconds`).run(userId,day,seconds);
  db.exec('COMMIT');
 }catch(e){db.exec('ROLLBACK');throw e;}
}
export async function transcribeSpeech(userId,base64,{fetcher=fetch}={}){
 if(process.env.ASR_ENABLED!=='true'||!process.env.ASR_SILICONFLOW_KEY)throw fail('ASR_DISABLED');
 if(typeof base64!=='string'||base64.length>2560060||!/^[A-Za-z0-9+/]+={0,2}$/.test(base64))throw fail('ASR_AUDIO_INVALID');
 const audio=Buffer.from(base64,'base64');
 if(audio.toString('base64')!==base64)throw fail('ASR_AUDIO_INVALID');
 const {seconds}=validateWav(audio);
 if(active.has(userId)||active.size>=4)throw fail('ASR_BUSY');
 budget(userId,seconds);active.add(userId);
 try{
  const form=new FormData();form.append('model','FunAudioLLM/SenseVoiceSmall');
  form.append('file',new Blob([audio],{type:'audio/wav'}),'speech.wav');
  const response=await fetcher('https://api.siliconflow.cn/v1/audio/transcriptions',{
   method:'POST',redirect:'error',signal:AbortSignal.timeout(20000),
   headers:{Authorization:`Bearer ${process.env.ASR_SILICONFLOW_KEY}`},
   body:form,
  });
  if(!response.ok)throw fail('ASR_UNAVAILABLE');
  const body=await response.json();const text=body?.text;
  if(typeof text!=='string'||text.length>2000)throw fail('ASR_UNAVAILABLE');
  if(!text.trim())throw fail('ASR_EMPTY');
  return text.trim();
 }catch(e){throw fail(e?.code==='ASR_EMPTY'?'ASR_EMPTY':'ASR_UNAVAILABLE');}
 finally{active.delete(userId);}
}
export function mountAiSpeech(app,options={}){
 const sessionOnly=(req,res,next)=>req.user.sid?next():res.status(403).json({error:'请使用应用账号录音'});
 app.post('/api/ai/speech',auth,sessionOnly,limit('asr-user',20,15*60000,req=>req.user.uid),
  express.json({limit:'3mb'}),asyncRoute(async(req,res)=>{
   if(process.env.AI_FEATURE_ENABLED!=='true')
    return res.status(403).json({code:'ASR_DISABLED',error:'请先开启 AI 计划助手'});
   try{return res.json({text:await transcribeSpeech(req.user.uid,req.body?.audio_base64,options)});}
   catch(e){const code=e.code||'ASR_UNAVAILABLE';const errors={ASR_DISABLED:'语音服务暂未开启，请使用文字输入',ASR_AUDIO_INVALID:'录音格式不正确或超过一分钟，请重新录音',ASR_BUSY:'语音服务正在忙，请稍后重试',ASR_BUDGET_EXHAUSTED:'今日语音额度已用完，请使用文字输入',ASR_EMPTY:'没有听清，请重新录音',ASR_UNAVAILABLE:'语音识别暂时失败，可重试或使用文字输入'};
    return res.status(code==='ASR_AUDIO_INVALID'?400:['ASR_BUSY','ASR_BUDGET_EXHAUSTED'].includes(code)?429:503).json({code,error:errors[code]||errors.ASR_UNAVAILABLE});}
  }));
}

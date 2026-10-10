import {createHash,createHmac,randomBytes,createCipheriv,createDecipheriv} from 'node:crypto';
import {db} from './db.js';
import {isBeta} from './beta.js';

const hash=s=>createHash('sha256').update(s).digest('hex');
const hmac=(key,value)=>createHmac('sha256',key).update(value).digest();
const securityPurposes=new Set(['password_changed','email_changed']);
const RETRY_DELAY_MS=20000,MAX_ATTEMPTS=3,NOTICE_LIFETIME=2*86400000;
const transientCodes=new Set(['MAIL_NETWORK_ERROR','MAIL_TIMEOUT','MAIL_SEND_INTERRUPTED','InternalError','ServiceUnavailable','RequestLimitExceeded','FailedOperation.FrequencyLimit']);
const networkCodes=new Set(['ECONNRESET','ECONNREFUSED','ETIMEDOUT','EAI_AGAIN','ENOTFOUND','ENETUNREACH','EPIPE','UND_ERR_SOCKET','UND_ERR_CONNECT_TIMEOUT','UND_ERR_HEADERS_TIMEOUT','UND_ERR_BODY_TIMEOUT']);
function safeError(error) {
 if(error?.name==='TimeoutError'||error?.name==='AbortError')return 'MAIL_TIMEOUT';
 if(error?.message==='fetch failed'||networkCodes.has(error?.code)||networkCodes.has(error?.cause?.code))return 'MAIL_NETWORK_ERROR';
 const code=error?.message||'';
 return /^(?:AuthFailure|InvalidParameter|InvalidParameterValue|MissingParameter|UnauthorizedOperation|UnsupportedOperation|ResourceNotFound|ResourceUnavailable|LimitExceeded|FailedOperation|InternalError|ServiceUnavailable|RequestLimitExceeded)(?:\.[A-Za-z0-9_]+)*$/.test(code)
  || /^MAIL_(?:EXPIRED|INVALIDATED|RECIPIENT_NOT_ALLOWED|SERVICE_UNAVAILABLE|SEND_INTERRUPTED)$/.test(code)
  || code==='SES_NO_MESSAGE_ID' ?code:'SES_FAILED';
}
const transient=code=>transientCodes.has(code)||code.startsWith('InternalError.')||code.startsWith('RequestLimitExceeded.');
export function normalizeEmail(value) {
 if(typeof value!=='string'||value.length>254)return null;
 const s=value.trim().toLowerCase();
 return /^[a-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}$/.test(s)&&!s.includes('..')?s:null;
}
export function emailMask(s) {if(!s)return null;const [local,domain]=s.split('@');return local.slice(0,2)+'***@'+domain;}
export function tencentRequest(payload,config,timestamp=Math.floor(Date.now()/1000)) {
 const host='ses.tencentcloudapi.com',body=JSON.stringify(payload),date=new Date(timestamp*1000).toISOString().slice(0,10);
 const scope=date+'/ses/tc3_request';
 const canonical='POST\n/\n\ncontent-type:application/json; charset=utf-8\nhost:'+host+'\n\ncontent-type;host\n'+hash(body);
 const stringToSign='TC3-HMAC-SHA256\n'+timestamp+'\n'+scope+'\n'+hash(canonical);
 const key=hmac(hmac(hmac('TC3'+config.secretKey,date),'ses'),'tc3_request');
 const signature=createHmac('sha256',key).update(stringToSign).digest('hex');
 return {url:'https://'+host,body,headers:{'Content-Type':'application/json; charset=utf-8',
  'Authorization':'TC3-HMAC-SHA256 Credential='+config.secretId+'/'+scope+', SignedHeaders=content-type;host, Signature='+signature,
  'X-TC-Action':'SendEmail','X-TC-Version':'2020-10-02','X-TC-Timestamp':String(timestamp),'X-TC-Region':config.region}};
}
export function createEmailService(options={}) {
 const config={secretId:process.env.TENCENT_SES_SECRET_ID,secretKey:process.env.TENCENT_SES_SECRET_KEY,
  region:process.env.TENCENT_SES_REGION,from:process.env.TENCENT_SES_FROM};
 const templates={register:process.env.TENCENT_SES_TEMPLATE_REGISTER,bind:process.env.TENCENT_SES_TEMPLATE_BIND,
  reset:process.env.TENCENT_SES_TEMPLATE_RESET,password_changed:process.env.TENCENT_SES_TEMPLATE_PASSWORD_CHANGED,email_changed:process.env.TENCENT_SES_TEMPLATE_EMAIL_CHANGED};
 const enabled=!!options.send||!!(config.secretId&&config.secretKey&&['ap-hongkong','ap-guangzhou'].includes(config.region)&&normalizeEmail(config.from)&&Object.values(templates).every(v=>/^\d+$/.test(v||'')));
 const now=options.now||Date.now;
 const encryptionKey=createHash('sha256').update('ddl-mail-outbox:'+process.env.JWT_SECRET).digest();
 const allowed=new Set((process.env.BETA_EMAIL_RECIPIENTS||'').split(',').map(normalizeEmail).filter(Boolean));
 const day=()=>new Date(now()).toISOString().slice(0,10);
 const tomorrow=()=>Date.parse(day()+'T00:00:00Z')+86400000;
 function seal(mail){const iv=randomBytes(12),c=createCipheriv('aes-256-gcm',encryptionKey,iv);const data=Buffer.concat([c.update(JSON.stringify(mail),'utf8'),c.final()]);return Buffer.concat([iv,c.getAuthTag(),data]).toString('base64');}
 function open(value){const b=Buffer.from(value,'base64'),d=createDecipheriv('aes-256-gcm',encryptionKey,b.subarray(0,12));d.setAuthTag(b.subarray(12,28));return JSON.parse(Buffer.concat([d.update(b.subarray(28)),d.final()]).toString('utf8'));}
 function available(to){return enabled&&(!isBeta()||allowed.has(to));}
 function capacity(count=1,kind='verification'){
  const day=new Date(now()).toISOString().slice(0,10),used=db.prepare('SELECT count,security_count FROM email_daily WHERE day=?').get(day)||{count:0,security_count:0};
  const maximum=Number(process.env.EMAIL_DAILY_LIMIT||(isBeta()?40:300));
  if(!Number.isSafeInteger(maximum)||maximum<=0||used.count+count>maximum)return false;
  // Small custom limits can still send a code; normal limits reserve 20% for notices.
  const noticeMaximum=Math.max(1,Math.floor(maximum/5)),verificationMaximum=maximum-Math.floor(maximum/5);
  return kind==='security'?used.security_count+count<=noticeMaximum:used.count-used.security_count+count<=verificationMaximum;
 }
 function reserve(kind='verification') {
  if(!capacity(1,kind))return false;
  const day=new Date(now()).toISOString().slice(0,10);
  db.prepare('INSERT INTO email_daily(day,count,security_count) VALUES(?,1,?) ON CONFLICT(day) DO UPDATE SET count=count+1,security_count=security_count+excluded.security_count').run(day,kind==='security'?1:0);
  return true;
 }
 function enqueue(mail) {
  if(!normalizeEmail(mail.to))throw new Error('Invalid internal mail recipient');
  const notice=securityPurposes.has(mail.purpose);
  if(!notice&&(!available(mail.to)||!reserve()))return false;
  // Notifications must be durably recorded even when mail is disabled or today's
  // budget is exhausted. They reserve a slot only when the worker can send them.
  db.prepare('INSERT INTO email_jobs(user_id,payload,status,created_at,expires_at,kind,purpose,quota_reserved,updated_at,quota_day) VALUES(?,?,?,?,?,?,?,?,?,?)')
   .run(mail.uid||null,seal(mail),'queued',now(),now()+(notice?NOTICE_LIFETIME:600000),notice?'security':'verification',mail.purpose,notice?0:1,now(),notice?null:day());return true;
 }

 async function send(mail) {
  if(options.send)return options.send(mail);
  const titles={register:'注册邮箱验证',bind:'邮箱绑定验证',reset:'找回密码验证',password_changed:'密码变更通知',email_changed:'邮箱变更通知'};
  const payload={FromEmailAddress:'DDL Killer <'+config.from+'>',Destination:[mail.to],Subject:(isBeta()?'[Beta 测试] ':'')+'DDL Killer · '+titles[mail.purpose],
   Template:{TemplateID:Number(templates[mail.purpose]),TemplateData:JSON.stringify(mail.code?{code:mail.code}:{})},TriggerType:1,Unsubscribe:'0'};
  const req=tencentRequest(payload,config);const response=await fetch(req.url,{method:'POST',headers:req.headers,body:req.body,signal:AbortSignal.timeout(15000),redirect:'error'});
  if(response.status>=500)throw new Error('ServiceUnavailable');
  if(response.status===429)throw new Error('RequestLimitExceeded');
  const result=await response.json();if(!response.ok||result.Response?.Error)throw new Error(result.Response?.Error?.Code||'SES_FAILED');
  if(!result.Response?.MessageId)throw new Error('SES_NO_MESSAGE_ID');return result.Response.MessageId;
 }
 let flushing=false;
 function finish(job,status,error,payload=''){
  db.prepare('UPDATE email_jobs SET status=?,last_error=?,payload=?,next_attempt_at=0,updated_at=? WHERE id=?').run(status,error,payload,now(),job.id);
 }
 // Explicit operator action only, after fixing the cause. No public retry endpoint.
 function retryNotice(id){
  return db.prepare("UPDATE email_jobs SET status='queued',attempts=0,next_attempt_at=0,updated_at=? WHERE id=? AND kind='security' AND status='failed' AND payload!='' AND expires_at>?").run(now(),id,now()).changes===1;
 }
 async function flush(){if(flushing)return;flushing=true;try{
  db.prepare("UPDATE email_jobs SET last_error=CASE WHEN status='failed' THEN last_error ELSE 'MAIL_EXPIRED' END,status='expired',payload='',next_attempt_at=0,updated_at=? WHERE expires_at<=? AND (status IN ('queued','retrying','sending') OR (status='failed' AND payload!=''))").run(now(),now());
  db.prepare("DELETE FROM email_jobs WHERE updated_at<? AND status IN ('accepted','failed','expired')").run(now()-7*86400000);
  db.prepare('DELETE FROM email_challenges WHERE expires_at<?').run(now()-86400000);
  db.prepare('DELETE FROM email_daily WHERE day<?').run(new Date(now()-7*86400000).toISOString().slice(0,10));
  // flush() is single-flight (the guard above), so no send is in flight right now:
  // any 'sending' row is an orphan from a restart or a crash mid-send. Recover it.
  db.prepare("UPDATE email_jobs SET status='retrying',last_error='MAIL_SEND_INTERRUPTED',next_attempt_at=?,updated_at=? WHERE status='sending'").run(now(),now());
  const jobs=db.prepare("SELECT * FROM email_jobs WHERE status IN ('queued','retrying') AND payload!='' AND next_attempt_at<=? AND expires_at>? ORDER BY id LIMIT 10").all(now(),now());
  for(const job of jobs){
   let attempted=false;
   try {const mail=open(job.payload);
    if(job.expires_at<=now()){finish(job,'expired','MAIL_EXPIRED');continue;}
    // Infer legacy notices from the sealed payload without exposing it in metadata.
    if(securityPurposes.has(mail.purpose)){job.kind='security';db.prepare("UPDATE email_jobs SET kind='security',purpose=? WHERE id=?").run(mail.purpose,job.id);}
    if(mail.requestId){const c=db.prepare('SELECT used_at,expires_at FROM email_challenges WHERE id=?').get(mail.requestId);if(!c||c.used_at!==null||c.expires_at<=now())throw new Error('MAIL_INVALIDATED');}
    if(isBeta()&&!allowed.has(mail.to))throw new Error('MAIL_RECIPIENT_NOT_ALLOWED');
    if(!enabled){
     if(job.kind!=='security')throw new Error('MAIL_SERVICE_UNAVAILABLE');
     db.prepare("UPDATE email_jobs SET status='queued',last_error='MAIL_SERVICE_UNAVAILABLE',next_attempt_at=?,updated_at=? WHERE id=?").run(now()+60000,now(),job.id);continue;
    }
    if(!job.quota_reserved||job.quota_day!==day()){
     if(!reserve(job.kind)){
      if(job.kind!=='security'){finish(job,'failed','MAIL_QUOTA_DEFERRED');continue;}
      db.prepare("UPDATE email_jobs SET status='queued',last_error='MAIL_QUOTA_DEFERRED',next_attempt_at=?,updated_at=? WHERE id=?").run(tomorrow(),now(),job.id);continue;
     }
     db.prepare('UPDATE email_jobs SET quota_reserved=1,quota_day=? WHERE id=?').run(day(),job.id);
    }
    if(job.attempts>=MAX_ATTEMPTS){finish(job,'failed','MAIL_SEND_INTERRUPTED',job.kind==='security'?job.payload:'');continue;}
    if(db.prepare("UPDATE email_jobs SET status='sending',attempts=attempts+1,updated_at=? WHERE id=? AND status IN ('queued','retrying')").run(now(),job.id).changes!==1)continue;
    attempted=true;
    const id=await send(mail);
    if(typeof id!=='string'||!id||id.length>256)throw new Error('SES_NO_MESSAGE_ID');
    db.prepare("UPDATE email_jobs SET status='accepted',payload='',provider_id=?,accepted_at=?,last_error=NULL,next_attempt_at=0,updated_at=? WHERE id=?").run(id,now(),now(),job.id);
   }catch(e){
    const error=safeError(e),attempts=job.attempts+(attempted?1:0);
    if(error==='FailedOperation.ExceedSendLimit'&&job.kind==='security'){
     db.prepare("UPDATE email_jobs SET status='queued',last_error=?,next_attempt_at=?,updated_at=? WHERE id=?").run(error,tomorrow(),now(),job.id);continue;
    }
    const retry=transient(error)&&attempts<MAX_ATTEMPTS&&job.expires_at>now()+RETRY_DELAY_MS;
    db.prepare("UPDATE email_jobs SET status=?,last_error=?,next_attempt_at=?,payload=?,updated_at=? WHERE id=?")
     .run(retry?'retrying':'failed',error,retry?now()+RETRY_DELAY_MS:0,retry||job.kind==='security'?job.payload:'',now(),job.id);
    console.warn('[mail] send failed',error,retry?'retry scheduled':'stopped');
   }
  }
 }finally{flushing=false;}}
 return {enabled,available,capacity,reserve,enqueue,flush,retryNotice,now};
}

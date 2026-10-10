import test from 'node:test';import assert from 'node:assert/strict';
process.env.DB_PATH=':memory:';process.env.JWT_SECRET='mail-service-fixture-secret-long';
await import('../src/email-account.js');const {db}=await import('../src/db.js');const {createEmailService,normalizeEmail,tencentRequest}=await import('../src/email-service.js');
test.after(()=>db.close());
test.beforeEach(()=>{
 db.exec('DELETE FROM email_jobs; DELETE FROM email_daily; DELETE FROM email_challenges;');
 process.env.RELEASE_CHANNEL='stable';delete process.env.BETA_EMAIL_RECIPIENTS;delete process.env.EMAIL_DAILY_LIMIT;
});
test('recipient normalization rejects header injection and Tencent signer covers exact payload',()=>{
 assert.equal(normalizeEmail(' A.Name@example.COM '),'a.name@example.com');assert.equal(normalizeEmail('bad\r\nBcc:attacker@example.com'),null);
 const request=tencentRequest({Subject:'账号验证'}, {secretId:'fixture-id',secretKey:'fixture-key',region:'ap-hongkong'},1700000000);
 assert.equal(request.url,'https://ses.tencentcloudapi.com');assert.equal(request.headers['X-TC-Region'],'ap-hongkong');assert.match(request.headers.Authorization,/TC3-HMAC-SHA256 Credential=fixture-id\/2023-11-14\/ses\/tc3_request/);assert.equal(request.body,JSON.stringify({Subject:'账号验证'}));
});
test('Beta recipient whitelist and daily cap fail closed, jobs are encrypted, and a transient failure is retried inside the code lifetime',async()=>{
 process.env.RELEASE_CHANNEL='beta';process.env.BETA_EMAIL_RECIPIENTS='only@example.com';process.env.EMAIL_DAILY_LIMIT='1';let attempts=0,clock=Date.now();
 const mail=createEmailService({send:async()=>{attempts++;throw new Error('InternalError');},now:()=>clock});
 assert.equal(mail.enqueue({to:'other@example.com',purpose:'bind',code:'123456'}),false);
 assert.equal(mail.enqueue({to:'only@example.com',purpose:'bind',code:'123456'}),true);
 assert.ok(!JSON.stringify(db.prepare('SELECT * FROM email_jobs').all()).includes('only@example.com'));assert.ok(!JSON.stringify(db.prepare('SELECT * FROM email_jobs').all()).includes('123456'));
 assert.equal(mail.enqueue({to:'only@example.com',purpose:'bind',code:'654321'}),false);
 // Transient failure: the job survives sealed so the code can still be delivered.
 await mail.flush();assert.equal(attempts,1);assert.equal(db.prepare('SELECT status,attempts FROM email_jobs').get().status,'retrying');
 assert.ok(db.prepare('SELECT payload FROM email_jobs').get().payload.length>0);
 clock+=1000;await mail.flush();assert.equal(attempts,1);           // backoff has not elapsed
 clock+=20000;await mail.flush();assert.equal(attempts,2);          // retried, same sealed code
 clock+=20001;await mail.flush();assert.equal(attempts,3);          // last permitted attempt
 clock+=20001;await mail.flush();assert.equal(attempts,3);          // cap reached: no fourth send
 assert.equal(db.prepare('SELECT payload FROM email_jobs').get().payload,'');
 // Retries reuse the reserved job, so they never consume extra daily quota.
 assert.equal(db.prepare('SELECT sum(count) n FROM email_daily').get().n,1);
 assert.ok(!JSON.stringify(db.prepare('SELECT * FROM email_jobs').all()).includes('123456'));
});

test('permanent permission failure stops immediately and persists a safe diagnostic',async()=>{
 let calls=0,clock=Date.now();
 const mail=createEmailService({send:async()=>{calls++;throw new Error('AuthFailure.UnauthorizedOperation');},now:()=>clock});
 assert.equal(mail.enqueue({to:'person@example.com',purpose:'bind',code:'123456'}),true);
 await mail.flush();clock+=20001;await mail.flush();
 assert.equal(calls,1);
 const job=db.prepare('SELECT * FROM email_jobs').get();
 assert.equal(job.status,'failed');assert.equal(job.last_error,'AuthFailure.UnauthorizedOperation');assert.equal(job.payload,'');assert.equal(job.attempts,1);
});

test('provider acceptance is recorded as accepted, not inbox delivery',async()=>{
 const mail=createEmailService({send:async()=> 'fixture-provider-id'});
 mail.enqueue({to:'person@example.com',purpose:'bind',code:'123456'});await mail.flush();
 const job=db.prepare('SELECT * FROM email_jobs').get();
 assert.equal(job.status,'accepted');assert.equal(job.provider_id,'fixture-provider-id');assert.ok(job.accepted_at);assert.equal(job.last_error,null);assert.equal(job.attempts,1);assert.equal(job.payload,'');
});

test('security notices survive quota exhaustion, reuse reservations, and are sent after UTC rollover',async()=>{
 process.env.EMAIL_DAILY_LIMIT='5';let clock=Date.UTC(2030,0,1,12),sends=0;
 const mail=createEmailService({send:async()=>{sends++;return 'fixture-id';},now:()=>clock});
 for(let i=0;i<4;i++)assert.equal(mail.enqueue({to:'person@example.com',purpose:'bind',code:'123456'}),true);
 assert.equal(mail.enqueue({to:'person@example.com',purpose:'bind',code:'123456'}),false);
 assert.equal(mail.enqueue({to:'old@example.com',purpose:'email_changed'}),true);
 assert.equal(mail.enqueue({to:'old@example.com',purpose:'password_changed'}),true);
 await mail.flush();assert.equal(sends,5);
 const pending=db.prepare("SELECT * FROM email_jobs WHERE status='queued'").get();
 assert.equal(pending.kind,'security');assert.equal(pending.last_error,'MAIL_QUOTA_DEFERRED');assert.ok(pending.payload);
 clock+=86400001;await mail.flush();assert.equal(sends,6);
 assert.equal(db.prepare('SELECT sum(count) n FROM email_daily').get().n,6);
});

test('notice with disabled sender remains traceable and expires without sending; failed metadata lasts seven days',async()=>{
 let clock=Date.UTC(2030,0,1,12);const mail=createEmailService({now:()=>clock});
 assert.equal(mail.enqueue({to:'old@example.com',purpose:'email_changed'}),true);
 await mail.flush();let job=db.prepare('SELECT * FROM email_jobs').get();
 assert.equal(job.status,'queued');assert.equal(job.last_error,'MAIL_SERVICE_UNAVAILABLE');
 clock+=2*86400000+1;await mail.flush();job=db.prepare('SELECT * FROM email_jobs').get();
 assert.equal(job.status,'expired');assert.equal(job.last_error,'MAIL_EXPIRED');assert.equal(job.payload,'');
 clock+=86400001;await mail.flush();assert.ok(db.prepare('SELECT id FROM email_jobs').get());
 clock+=7*86400000;await mail.flush();assert.equal(db.prepare('SELECT id FROM email_jobs').get(),undefined);
});

test('invalidated code never sends and unexpected errors cannot persist a recipient or code',async()=>{
 const mail=createEmailService({send:async()=>{throw new Error('person@example.com code=123456');}});
 mail.enqueue({to:'person@example.com',purpose:'bind',code:'123456',requestId:'gone'});
 await mail.flush();assert.equal(db.prepare('SELECT last_error FROM email_jobs').get().last_error,'MAIL_INVALIDATED');
 mail.enqueue({to:'person@example.com',purpose:'bind',code:'123456'});await mail.flush();
 const rows=db.prepare('SELECT * FROM email_jobs').all();
 assert.equal(rows[1].last_error,'SES_FAILED');assert.equal(rows[1].status,'failed');
 assert.ok(!JSON.stringify(rows).includes('person@example.com'));assert.ok(!JSON.stringify(rows).includes('123456'));
});

test('failed security notice can only be retried explicitly before expiry and never bypasses Beta recipients',async()=>{
 let clock=Date.UTC(2030,0,1,12),fail=true,calls=0;
 const mail=createEmailService({now:()=>clock,send:async()=>{calls++;if(fail)throw new Error('FailedOperation.InvalidTemplateID');return 'fixed-id';}});
 mail.enqueue({to:'old@example.com',purpose:'email_changed'});await mail.flush();
 const job=db.prepare('SELECT * FROM email_jobs').get();assert.equal(job.status,'failed');assert.ok(job.payload);
 clock+=20001;await mail.flush();assert.equal(calls,1);
 fail=false;assert.equal(mail.retryNotice(job.id),true);await mail.flush();assert.equal(calls,2);assert.equal(db.prepare('SELECT status FROM email_jobs').get().status,'accepted');
 assert.equal(mail.retryNotice(job.id),false);
 process.env.RELEASE_CHANNEL='beta';process.env.BETA_EMAIL_RECIPIENTS='only@example.com';
 const beta=createEmailService({send:async()=>{throw new Error('must not send');},now:()=>clock});
 beta.enqueue({to:'blocked@example.com',purpose:'password_changed'});await beta.flush();
 const blocked=db.prepare("SELECT * FROM email_jobs WHERE status='failed'").get();assert.equal(blocked.last_error,'MAIL_RECIPIENT_NOT_ALLOWED');
 assert.equal(beta.retryNotice(blocked.id),true);await beta.flush();assert.equal(db.prepare('SELECT last_error FROM email_jobs WHERE id=?').get(blocked.id).last_error,'MAIL_RECIPIENT_NOT_ALLOWED');
 clock+=2*86400000;assert.equal(beta.retryNotice(blocked.id),false);
});

test('legacy queue migration is idempotent and preserves historical reservations and accepted messages',async()=>{
 const {DatabaseSync}=await import('node:sqlite');const {migrateEmailQueue}=await import('../src/email-schema.js');const old=new DatabaseSync(':memory:');
 try{
  old.exec("CREATE TABLE email_jobs(id INTEGER PRIMARY KEY,user_id INTEGER,payload TEXT NOT NULL,status TEXT NOT NULL,provider_id TEXT,created_at INTEGER NOT NULL,expires_at INTEGER NOT NULL);CREATE TABLE email_daily(day TEXT PRIMARY KEY,count INTEGER NOT NULL);INSERT INTO email_jobs VALUES(1,NULL,'','sent','old-id',10,20);INSERT INTO email_daily VALUES('2030-01-01',3);");
  migrateEmailQueue(old);migrateEmailQueue(old);
  const row=old.prepare('SELECT * FROM email_jobs').get();assert.equal(row.status,'accepted');assert.equal(row.provider_id,'old-id');assert.equal(row.accepted_at,null);assert.equal(row.quota_reserved,1);assert.equal(row.updated_at,10);
  assert.equal(old.prepare('SELECT count FROM email_daily').get().count,3);
 }finally{old.close();}
});

test('notice retries on another day must respect that day\'s quota',async()=>{
 process.env.EMAIL_DAILY_LIMIT='5';let clock=Date.UTC(2030,0,1,12),fail=true,calls=0;
 const mail=createEmailService({now:()=>clock,send:async()=>{calls++;if(fail)throw new Error('FailedOperation.InvalidTemplateID');return 'fixture-id';}});
 mail.enqueue({to:'old@example.com',purpose:'email_changed'});await mail.flush();const id=db.prepare('SELECT id FROM email_jobs').get().id;
 clock+=86400001;fail=false;
 mail.enqueue({to:'other@example.com',purpose:'password_changed'});await mail.flush();assert.equal(calls,2);
 assert.equal(mail.retryNotice(id),true);await mail.flush();assert.equal(calls,2);
 assert.equal(db.prepare('SELECT last_error FROM email_jobs WHERE id=?').get(id).last_error,'MAIL_QUOTA_DEFERRED');
 clock=Date.UTC(2030,0,3,0,1);await mail.flush();assert.equal(calls,3);
});

test('provider daily quota defers a security notice to the next day without a busy retry loop',async()=>{
 let clock=Date.UTC(2030,0,1,12),calls=0;
 const mail=createEmailService({now:()=>clock,send:async()=>{if(++calls===1)throw new Error('FailedOperation.ExceedSendLimit');return 'fixture-id';}});
 mail.enqueue({to:'old@example.com',purpose:'email_changed'});await mail.flush();
 let job=db.prepare('SELECT * FROM email_jobs').get();assert.equal(job.status,'queued');assert.equal(job.last_error,'FailedOperation.ExceedSendLimit');
 clock+=20001;await mail.flush();assert.equal(calls,1);
 clock+=86400000;await mail.flush();assert.equal(calls,2);assert.equal(db.prepare('SELECT status FROM email_jobs').get().status,'accepted');
});

test('network disconnect while reading Tencent response is retried with the same verification code',async()=>{
 const values={TENCENT_SES_SECRET_ID:'fixture-id',TENCENT_SES_SECRET_KEY:'fixture-key',TENCENT_SES_REGION:'ap-hongkong',TENCENT_SES_FROM:'sender@example.com',TENCENT_SES_TEMPLATE_REGISTER:'1',TENCENT_SES_TEMPLATE_BIND:'2',TENCENT_SES_TEMPLATE_RESET:'3',TENCENT_SES_TEMPLATE_PASSWORD_CHANGED:'4',TENCENT_SES_TEMPLATE_EMAIL_CHANGED:'5'};
 const original=Object.fromEntries(Object.keys(values).map(key=>[key,process.env[key]])),originalFetch=globalThis.fetch;
 let calls=0,clock=Date.now();const codes=[];
 Object.assign(process.env,values);
 globalThis.fetch=async(url,request)=>{
  calls++;codes.push(JSON.parse(JSON.parse(request.body).Template.TemplateData).code);
  if(calls===1)return new Response(new ReadableStream({start(controller){controller.error(new TypeError('terminated',{cause:Object.assign(new Error('socket closed'),{code:'UND_ERR_SOCKET'})}));}}),{status:200});
  return new Response(JSON.stringify({Response:{MessageId:'fixture-provider-id'}}),{status:200});
 };
 try{
  const mail=createEmailService({now:()=>clock});assert.equal(mail.enqueue({to:'person@example.com',purpose:'bind',code:'123456'}),true);
  await mail.flush();assert.equal(db.prepare('SELECT status,last_error FROM email_jobs').get().status,'retrying');
  clock+=20001;await mail.flush();assert.equal(calls,2);assert.deepEqual(codes,['123456','123456']);assert.equal(db.prepare('SELECT status FROM email_jobs').get().status,'accepted');
 }finally{globalThis.fetch=originalFetch;for(const [key,value] of Object.entries(original)){if(value===undefined)delete process.env[key];else process.env[key]=value;}}
});

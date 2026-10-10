// Run inside the intended API container. Never print recipients, codes or payloads.
import {DatabaseSync} from 'node:sqlite';
const path=process.env.DB_PATH;
if(!path)throw new Error('An explicit DB_PATH is required');
const args=process.argv.slice(2);
if(!args.length){
 const db=new DatabaseSync(path,{readOnly:true});
 try{console.log(JSON.stringify({
  summary:db.prepare('SELECT status,kind,last_error,count(*) AS count FROM email_jobs GROUP BY status,kind,last_error').all(),
  retryable_notices:db.prepare("SELECT id,purpose,status,last_error,expires_at FROM email_jobs WHERE kind='security' AND status='failed' AND payload!='' AND expires_at>? ORDER BY expires_at,id LIMIT 100").all(Date.now()),
 }));}finally{db.close();}
}else if(args.length===2&&args[0]==='--retry-notice'&&/^[1-9][0-9]{0,9}$/.test(args[1])){
 // Explicitly mutating operator command; it requeues only a retained security
 // notification. The normal worker rechecks recipient policy and daily quota.
 await import('../src/email-account.js');
 const {createEmailService}=await import('../src/email-service.js');
 const {db}=await import('../src/db.js');
 try{const requeued=createEmailService().retryNotice(Number(args[1]));console.log(JSON.stringify({requeued}));if(!requeued)process.exitCode=1;}finally{db.close();}
}else throw new Error('Usage: email-queue.mjs [--retry-notice JOB_ID]');

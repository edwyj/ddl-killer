import test from 'node:test';import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';import {mkdtempSync,rmSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';import {execFileSync} from 'node:child_process';
import {migrateEmailQueue} from '../src/email-schema.js';
test('operator inspection is read-only and lists retryable IDs without secret mail contents',()=>{
 const dir=mkdtempSync(join(tmpdir(),'ddl-mail-fixture-')),path=join(dir,'fixture.db'),db=new DatabaseSync(path);
 try{
  migrateEmailQueue(db);const expiry=Date.now()+60000;
  db.prepare("INSERT INTO email_jobs(id,payload,status,created_at,expires_at,kind,purpose,last_error) VALUES(1,?,'failed',?,?,'security','email_changed','FailedOperation.InvalidTemplateID')").run('private-fixture-payload',Date.now(),expiry);
  const output=execFileSync(process.execPath,['scripts/email-queue.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,DB_PATH:path},encoding:'utf8'});
  const result=JSON.parse(output);assert.equal(result.summary[0].count,1);assert.equal(result.retryable_notices[0].id,1);assert.equal(result.retryable_notices[0].expires_at,expiry);
  assert.ok(!output.includes('private-fixture-payload'));assert.equal(db.prepare('SELECT status,payload FROM email_jobs').get().status,'failed');
 }finally{db.close();rmSync(dir,{recursive:true,force:true});}
});

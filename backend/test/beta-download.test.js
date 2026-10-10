import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import bcrypt from 'bcryptjs';
process.env.DB_PATH=':memory:';
process.env.JWT_SECRET='beta-download-test-private-signing-key';
process.env.RELEASE_CHANNEL='beta';
process.env.BETA_ALLOWED_USER_IDS='2,5';
process.env.PUBLIC_ORIGIN='https://beta.ddlkiller.com';
const dir=mkdtempSync(join(tmpdir(),'ddl-beta-download-'));
process.env.BETA_RELEASE_DIR=dir;
const bytes=Buffer.from('verified-test-apk-bytes');
writeFileSync(join(dir,'app-beta-release.apk'),bytes);
writeFileSync(join(dir,'release.json'),JSON.stringify({version:'0.11.5-beta.2',build_number:31,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')}));
const {db}=await import('../src/db.js');
db.exec("CREATE TABLE beta_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);INSERT INTO beta_meta VALUES('generation','download-test')");
const {createApp}=await import('../src/app.js');
const {issueSession}=await import('../src/security.js');
let server,base;
test.before(async()=>{
  const hash=await bcrypt.hash('beta-download-test-password',4);
  for(const [uid,name] of [[2,'tester_alpha'],[5,'tester_bravo'],[9,'other']])db.prepare('INSERT INTO users(id,username,password_hash)VALUES(?,?,?)').run(uid,name,hash);
  server=createApp().listen(0);await new Promise(r=>server.once('listening',r));base=`http://127.0.0.1:${server.address().port}`;
});
test.after(async()=>{await new Promise(r=>server.close(r));rmSync(dir,{recursive:true,force:true});});
test('anonymous, other accounts and revoked sessions cannot download',async()=>{
  for(const route of ['/api/beta/release','/api/beta/apk']) {
    assert.equal((await fetch(base+route)).status,401);
    const other=issueSession({id:9,username:'other'});
    assert.equal((await fetch(base+route,{headers:{authorization:'Bearer '+other}})).status,403);
  }
  const token=issueSession({id:2,username:'tester_alpha'});
  db.prepare('DELETE FROM sessions WHERE user_id=2').run();
  assert.equal((await fetch(base+'/api/beta/apk',{headers:{authorization:'Bearer '+token}})).status,401);
});
test('authorized browser cookie downloads the exact APK and supports byte ranges',async()=>{
  const login=await fetch(base+'/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json',Origin:process.env.PUBLIC_ORIGIN},body:JSON.stringify({username:'tester_alpha',password:'beta-download-test-password',client:'web'})});
  assert.equal(login.status,200);
  const cookie=login.headers.get('set-cookie').split(';')[0];
  const metadata=await fetch(base+'/api/beta/release',{headers:{cookie}});
  assert.equal(metadata.status,200);assert.equal((await metadata.json()).version,'0.11.5-beta.2');
  const download=await fetch(base+'/api/beta/apk',{headers:{cookie}});
  assert.equal(download.status,200);assert.match(download.headers.get('content-disposition'),/attachment.*DDL_Killer_Beta/);
  assert.match(download.headers.get('cache-control'),/private.*no-store/);
  assert.deepEqual(Buffer.from(await download.arrayBuffer()),bytes);
  const partial=await fetch(base+'/api/beta/apk',{headers:{cookie,Range:'bytes=0-7'}});
  assert.equal(partial.status,206);assert.deepEqual(Buffer.from(await partial.arrayBuffer()),bytes.subarray(0,8));
});

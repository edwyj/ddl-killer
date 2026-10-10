// Additive and idempotent: old installations keep their data and reservations.
export function migrateEmailQueue(db) {
 db.exec(`CREATE TABLE IF NOT EXISTS email_jobs(id INTEGER PRIMARY KEY,user_id INTEGER,payload TEXT NOT NULL,status TEXT NOT NULL,provider_id TEXT,created_at INTEGER NOT NULL,expires_at INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS email_daily(day TEXT PRIMARY KEY,count INTEGER NOT NULL);`);
 const columns=new Set(db.prepare('PRAGMA table_info(email_jobs)').all().map(c=>c.name));
 const additions={attempts:'INTEGER NOT NULL DEFAULT 0',next_attempt_at:'INTEGER NOT NULL DEFAULT 0',
  kind:"TEXT NOT NULL DEFAULT 'verification'",purpose:'TEXT',quota_reserved:'INTEGER NOT NULL DEFAULT 1',
  last_error:'TEXT',accepted_at:'INTEGER',updated_at:'INTEGER NOT NULL DEFAULT 0',quota_day:'TEXT'};
 for(const [name,type] of Object.entries(additions))if(!columns.has(name))db.exec(`ALTER TABLE email_jobs ADD COLUMN ${name} ${type}`);
 const dailyColumns=new Set(db.prepare('PRAGMA table_info(email_daily)').all().map(c=>c.name));
 if(!dailyColumns.has('security_count'))db.exec('ALTER TABLE email_daily ADD COLUMN security_count INTEGER NOT NULL DEFAULT 0');
 db.exec(`UPDATE email_jobs SET updated_at=created_at WHERE updated_at=0;
 UPDATE email_jobs SET quota_day=strftime('%Y-%m-%d',created_at/1000,'unixepoch') WHERE quota_reserved=1 AND quota_day IS NULL;
 UPDATE email_jobs SET status='accepted' WHERE status='sent';
 UPDATE email_jobs SET status='retrying' WHERE status='failed' AND payload!='' AND next_attempt_at>0;`);
}

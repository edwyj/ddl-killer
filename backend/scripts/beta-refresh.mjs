import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {db} from '../src/db.js';
import '../src/app.js'; // Initialize the full Beta schema; do not start workers.

export function expectedAccounts() {
  // deploy_beta.py writes this alongside BETA_ALLOWED_USER_IDS, from ops/beta-accounts.json.
  const names = (process.env.BETA_ALLOWED_USERNAMES || '').split(',').filter(name => name.length > 0);
  if (!names.length) throw new Error('Beta requires an explicit authorized account list');
  return names.slice().sort();
}

export async function refreshBeta(snapshot) {
  const names = snapshot?.users?.map(user => user.username).sort();
  if (process.env.RELEASE_CHANNEL !== 'beta' || snapshot?.format !== 'ddl-beta-business-v1' ||
      JSON.stringify(names) !== JSON.stringify(expectedAccounts())) throw new Error('Invalid Beta refresh');
  const allowed = new Set(snapshot.users.map(user => user.id));
  if (snapshot.users.some(user => !Number.isSafeInteger(user.id)) ||
      [...allowed].some(id => !process.env.BETA_ALLOWED_USER_IDS.split(',').includes(String(id)))) throw new Error('Unexpected user IDs');
  const whitelist = new Set(['lists','inbox','blocks','schedules','ai_planning_preferences',
    'schedule_drafts','ai_planning_sessions','ai_planning_turns','ai_plan_applications','user_messages','user_feedback','feedback_files']);
  for (const [table, rows] of Object.entries(snapshot.tables)) {
    if (!whitelist.has(table) || !Array.isArray(rows) || rows.some(row => !allowed.has(row.user_id))) throw new Error('Unexpected snapshot table or owner');
  }
  const accounts = [];
  const changedPasswords = new Set();
  for (const user of snapshot.users) {
    const old = db.prepare('SELECT password_hash,email,email_verified_at FROM users WHERE id=? AND username=?').get(user.id,user.username);
    if (typeof user.password_hash !== 'string' || !/^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$/.test(user.password_hash)) throw new Error('Production password hash required');
    if (old?.password_hash !== user.password_hash) changedPasswords.add(user.id);
    accounts.push({...user,email:Object.hasOwn(user,'email')?user.email:(old?.email||null),email_verified_at:Object.hasOwn(user,'email_verified_at')?user.email_verified_at:(old?.email_verified_at||null)});
  }
  const sessions = db.prepare('SELECT * FROM sessions').all().filter(row => allowed.has(row.user_id) && !changedPasswords.has(row.user_id));
  const generation = randomUUID();
  db.exec('BEGIN IMMEDIATE');
  try {
    for (const {name} of db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").all()) {
      if (!/^[a-z_]+$/.test(name)) throw new Error('Unexpected table name');
      db.exec(`DELETE FROM ${name}`);
    }
    for (const user of accounts) {
      db.prepare('INSERT INTO users (id,username,password_hash,nickname,avatar,hide_notification_content,created_at,email,email_verified_at) VALUES(?,?,?,?,?,?,?,?,?)')
        .run(user.id,user.username,user.password_hash,user.nickname,user.avatar,user.hide_notification_content,user.created_at,user.email,user.email_verified_at);
    }
    for (const [table, rows] of Object.entries({...snapshot.tables, sessions})) {
      const columns = new Set(db.prepare(`PRAGMA table_info(${table})`).all().map(col => col.name));
      for (const row of rows) {
        const keys = Object.keys(row);
        if (keys.some(key => !columns.has(key))) throw new Error('Snapshot schema incompatible with candidate build');
        const values = keys.map(key => row[key] && typeof row[key] === 'object' && Object.hasOwn(row[key],'base64')
          ? Buffer.from(row[key].base64,'base64') : row[key]);
        db.prepare(`INSERT INTO ${table} (${keys.map(key => '"'+key+'"').join(',')}) VALUES(${keys.map(() => '?').join(',')})`).run(...values);
      }
    }
    db.prepare("INSERT INTO beta_meta VALUES ('generation',?)").run(generation);
    db.prepare("INSERT INTO beta_meta VALUES ('refreshed_at',?)").run(new Date().toISOString());
    if (db.prepare('PRAGMA integrity_check').get().integrity_check !== 'ok') throw new Error('Beta DB integrity failed');
    db.exec('COMMIT');
    return {generation,users:accounts.map(user => ({id:user.id,username:user.username})),
      counts:Object.fromEntries(Object.entries(snapshot.tables).map(([table,rows]) => [table,rows.length]))};
  } catch (error) {db.exec('ROLLBACK'); throw error;}
}

if (process.argv[1]?.endsWith('/beta-refresh.mjs') || process.argv[1]?.endsWith('\\beta-refresh.mjs')) {
  db.exec('CREATE TABLE IF NOT EXISTS beta_meta (key TEXT PRIMARY KEY,value TEXT NOT NULL)');
  const source = JSON.parse(readFileSync(0,'utf8'));
  const result = await refreshBeta(source);
  console.log(JSON.stringify(result));
}

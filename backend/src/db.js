import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(fileURLToPath(import.meta.url));
process.umask(0o077);
const dataDir = path.join(root, '..', 'data');
mkdirSync(dataDir, { recursive: true });

// DB_PATH 环境变量可覆盖（测试用 ':memory:'）；默认 data/plan.db
const DB_PATH = process.env.DB_PATH || path.join(dataDir, 'plan.db');

export const db = new DatabaseSync(DB_PATH);

db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS blocks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    date TEXT NOT NULL,
    start_min INTEGER NOT NULL,
    end_min INTEGER NOT NULL,
    title TEXT NOT NULL,
    color TEXT DEFAULT '',
    done INTEGER DEFAULT 0,
    notes TEXT DEFAULT '',
    source TEXT DEFAULT 'manual',
    created_at TEXT DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS inbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    title TEXT NOT NULL,
    priority INTEGER DEFAULT 0,
    done INTEGER DEFAULT 0,
    notes TEXT DEFAULT '',
    created_at TEXT DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS lists (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    color TEXT DEFAULT '',
    emoji TEXT DEFAULT '',
    created_at TEXT DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS schedules (
    user_id INTEGER PRIMARY KEY,
    json TEXT NOT NULL,
    updated_at TEXT DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_blocks_date ON blocks(user_id, date);
  CREATE TABLE IF NOT EXISTS mcp_clients (
    id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    client_type TEXT NOT NULL CHECK(client_type IN ('pat','oauth')),
    scopes_json TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    last_used_at TEXT,
    revoked_at TEXT,
    created_at TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_mcp_clients_user ON mcp_clients(user_id, revoked_at);
  CREATE TABLE IF NOT EXISTS mcp_credentials (
    id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    token_prefix TEXT NOT NULL,
    secret_hash TEXT UNIQUE NOT NULL,
    family_id TEXT,
    expires_at TEXT NOT NULL,
    revoked_at TEXT,
    created_at TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_mcp_credentials_client ON mcp_credentials(client_id, revoked_at);
  CREATE TABLE IF NOT EXISTS mcp_audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    client_id TEXT,
    tool_name TEXT NOT NULL,
    result_code TEXT NOT NULL,
    object_ids_json TEXT NOT NULL DEFAULT '[]',
    request_id TEXT,
    created_at TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_mcp_audit_user_created ON mcp_audit_log(user_id, created_at);
  CREATE TABLE IF NOT EXISTS ai_provider_configs (
    id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    base_url TEXT NOT NULL,
    model TEXT NOT NULL,
    key_version TEXT NOT NULL,
    nonce TEXT NOT NULL,
    ciphertext TEXT NOT NULL,
    auth_tag TEXT NOT NULL,
    key_mask TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS ai_quota_daily (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    quota_date TEXT NOT NULL,
    used INTEGER NOT NULL DEFAULT 0,
    reserved INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY(user_id, quota_date)
  );
  CREATE TABLE IF NOT EXISTS ai_quota_reservations (
    id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    quota_date TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('reserved','consumed','released')),
    usage_json TEXT,
    reason TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_ai_quota_reservations_daily
    ON ai_quota_reservations(quota_date, state, created_at);
  CREATE TABLE IF NOT EXISTS ai_planning_sessions (
    id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    mode TEXT NOT NULL CHECK(mode IN ('hosted','byok')),
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    current_draft_id TEXT,
    status TEXT NOT NULL CHECK(status IN ('active','closed','expired','applied')),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_ai_sessions_user ON ai_planning_sessions(user_id, expires_at);
  CREATE TABLE IF NOT EXISTS ai_planning_turns (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    input_text TEXT NOT NULL,
    proposal_json TEXT NOT NULL,
    draft_id TEXT NOT NULL,
    created_at INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_ai_turns_session ON ai_planning_turns(session_id, created_at);
  CREATE TABLE IF NOT EXISTS ai_audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_id TEXT,
    mode TEXT NOT NULL,
    result_code TEXT NOT NULL,
    latency_ms INTEGER NOT NULL,
    prompt_tokens INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    draft_id TEXT,
    created_at INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_ai_audit_user ON ai_audit_log(user_id, created_at);
`);

// 为既有表补列(已存在则忽略)
function ensureCol(table, col, def) {
  try {
    db.exec(`ALTER TABLE ${table} ADD COLUMN ${col} ${def}`);
  } catch (e) {
    // 只吞「列已存在」；表不存在/库锁住/列定义非法等真失败必须炸出来,
    // 否则会被静默跳过,之后在运行时变成 API 500。
    if (!/duplicate column name/i.test(e.message)) throw e;
  }
}
ensureCol('blocks', 'list_id', 'INTEGER');
ensureCol('blocks', 'inbox_id', 'INTEGER');
ensureCol('inbox', 'estimate_minutes', 'INTEGER');
ensureCol('ai_audit_log', 'issue_codes_json', "TEXT NOT NULL DEFAULT '[]'");
ensureCol('ai_planning_turns','input_at','INTEGER');
ensureCol('inbox', 'reminder_at', 'TEXT');
db.exec('CREATE UNIQUE INDEX IF NOT EXISTS idx_blocks_inbox ON blocks(inbox_id) WHERE inbox_id IS NOT NULL');
ensureCol('inbox', 'list_id', 'INTEGER');
ensureCol('inbox', 'due_date', 'TEXT');   // 截止日期 YYYY-MM-DD(可空=无 ddl)
ensureCol('inbox', 'due_time', 'INTEGER'); // 截止时刻(当天分钟 0-1439，可空=只到日期)
ensureCol('users', 'nickname', 'TEXT');    // 昵称(可空=空串)
ensureCol('users', 'avatar', 'TEXT');      // 头像 spec: preset:<#hex>:<char> / data:image/*;base64,...
ensureCol('users', 'hide_notification_content', 'INTEGER NOT NULL DEFAULT 1');
ensureCol('users', 'ai_mode', "TEXT NOT NULL DEFAULT 'hosted'");

// 0.9.1 adds the applied lifecycle state. SQLite cannot alter CHECK constraints,
// so migrate only databases created by 0.9.0 and preserve every session row.
const aiSessionTable = db.prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name='ai_planning_sessions'").get()?.sql || '';
if (!aiSessionTable.includes("'applied'")) {
  db.exec(`
    BEGIN IMMEDIATE;
    DROP INDEX IF EXISTS idx_ai_sessions_user;
    ALTER TABLE ai_planning_sessions RENAME TO ai_planning_sessions_v090;
    CREATE TABLE ai_planning_sessions (
      id TEXT PRIMARY KEY,
      user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      mode TEXT NOT NULL CHECK(mode IN ('hosted','byok')),
      start_date TEXT NOT NULL,
      end_date TEXT NOT NULL,
      current_draft_id TEXT,
      status TEXT NOT NULL CHECK(status IN ('active','closed','expired','applied')),
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    );
    INSERT INTO ai_planning_sessions SELECT * FROM ai_planning_sessions_v090;
    DROP TABLE ai_planning_sessions_v090;
    CREATE INDEX idx_ai_sessions_user ON ai_planning_sessions(user_id, expires_at);
    COMMIT;
  `);
}

// 回收站：NULL=正常；有值=已删，值为删除时刻(ISO)。超过 7 天由每日清理真删。
ensureCol('inbox', 'deleted_at', 'TEXT');
// 任务被软删时，它的排期块一起软删，还原时一起回来(见 task-planning.js)。
ensureCol('blocks', 'deleted_at', 'TEXT');
// 完成时刻(ISO)：done 由 0→1 时写入，1→0 时清空。超过 3 天由每日清理真删。
ensureCol('inbox', 'done_at', 'TEXT');
ensureCol('inbox', 'version', 'INTEGER NOT NULL DEFAULT 1');
ensureCol('blocks', 'version', 'INTEGER NOT NULL DEFAULT 1');
// Durable restoration boundary: stale offline intents cannot overwrite an undo
// even when the restored business values equal their original base (ABA).
ensureCol('inbox', 'restore_epoch', 'INTEGER NOT NULL DEFAULT 0');
ensureCol('blocks', 'restore_epoch', 'INTEGER NOT NULL DEFAULT 0');
ensureCol('mcp_clients', 'oauth_registered_client_id', 'TEXT');
// 系统清单标记：'inbox'=收集箱(真容器) / 'trash'=回收站 / 'done'=已完成 / NULL=普通清单。
// 回收站和已完成的成员是「算」出来的(deleted_at / done_at)，任务不会带它们的 id；
// 收集箱才是真容器。按标记认，不按名字认 —— 用户改了名也不会把系统清单弄丢。
ensureCol('lists', 'system', 'TEXT');
db.exec('CREATE INDEX IF NOT EXISTS idx_inbox_deleted ON inbox(user_id, deleted_at)');
db.exec('CREATE INDEX IF NOT EXISTS idx_inbox_done ON inbox(user_id, done, done_at)');
db.exec(`CREATE TABLE IF NOT EXISTS schedule_drafts (
  id TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL,
  created_by_client_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending','applied','discarded','expired')),
  changes_json TEXT NOT NULL,
  snapshot_json TEXT NOT NULL,
  warnings_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  applied_at TEXT,
  result_json TEXT
);
CREATE INDEX IF NOT EXISTS idx_schedule_drafts_user ON schedule_drafts(user_id, created_at);`);
db.exec(`CREATE TABLE IF NOT EXISTS mcp_registered_clients (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  redirect_uris_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  disabled_at TEXT
);
CREATE TABLE IF NOT EXISTS mcp_oauth_requests (
  id TEXT PRIMARY KEY,
  registered_client_id TEXT NOT NULL,
  user_id INTEGER,
  redirect_uri TEXT NOT NULL,
  state TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  scopes_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_mcp_oauth_requests_user ON mcp_oauth_requests(user_id, created_at);
CREATE TABLE IF NOT EXISTS mcp_oauth_codes (
  id TEXT PRIMARY KEY,
  code_hash TEXT UNIQUE NOT NULL,
  registered_client_id TEXT NOT NULL,
  user_id INTEGER NOT NULL,
  redirect_uri TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  scopes_json TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_mcp_oauth_codes_user ON mcp_oauth_codes(user_id, created_at);`);
// 一次性回填：done_at 这一列是新加的，老数据里 done=1 的行没有完成时刻。
// created_at 是 datetime('now') 的 UTC 格式('YYYY-MM-DD HH:MM:SS')，转成 ISO 再存，
// 免得两种格式混在一起做字符串比较时排错序。填完之后本语句匹配 0 行，天然幂等。
db.prepare(`UPDATE inbox SET done_at = replace(created_at,' ','T')||'Z'
  WHERE done=1 AND done_at IS NULL`).run();
ensureCol('ai_planning_sessions','requirements_json',"TEXT NOT NULL DEFAULT '[]'");
ensureCol('ai_planning_sessions','exceptions_json',"TEXT NOT NULL DEFAULT '[]'");
ensureCol('ai_planning_sessions','exceptions_revision','TEXT');
ensureCol('schedule_drafts','ai_policy_json','TEXT');
db.exec(`CREATE TABLE IF NOT EXISTS ai_plan_applications (
 id TEXT PRIMARY KEY,user_id INTEGER NOT NULL,session_id TEXT NOT NULL,draft_id TEXT NOT NULL UNIQUE,
 status TEXT NOT NULL DEFAULT 'applied',before_json TEXT NOT NULL,after_json TEXT NOT NULL,
 created_at INTEGER NOT NULL,undone_at INTEGER,result_json TEXT);
 CREATE INDEX IF NOT EXISTS idx_ai_applications_session ON ai_plan_applications(user_id,session_id,created_at);`);

import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// 线上是「老库 + 新代码」，不是空库。这个用例先把升级前的表结构原样造出来、灌进数据，
// 再让新代码去开它，验证迁移和回填不会把既有数据弄坏或搞重。
const dir = mkdtempSync(join(tmpdir(), 'plan-migrate-'));
const file = join(dir, 'plan.db');

const OLD_SCHEMA = `
  CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL, created_at TEXT DEFAULT (datetime('now')));
  CREATE TABLE blocks (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, date TEXT NOT NULL,
    start_min INTEGER NOT NULL, end_min INTEGER NOT NULL, title TEXT NOT NULL, color TEXT DEFAULT '',
    done INTEGER DEFAULT 0, notes TEXT DEFAULT '', source TEXT DEFAULT 'manual',
    created_at TEXT DEFAULT (datetime('now')));
  CREATE TABLE inbox (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, title TEXT NOT NULL,
    priority INTEGER DEFAULT 0, done INTEGER DEFAULT 0, notes TEXT DEFAULT '',
    created_at TEXT DEFAULT (datetime('now')));
  CREATE TABLE lists (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, name TEXT NOT NULL,
    color TEXT DEFAULT '', emoji TEXT DEFAULT '', created_at TEXT DEFAULT (datetime('now')));
  CREATE TABLE schedules (user_id INTEGER PRIMARY KEY, json TEXT NOT NULL,
    updated_at TEXT DEFAULT (datetime('now')));
  ALTER TABLE blocks ADD COLUMN list_id INTEGER;
  ALTER TABLE blocks ADD COLUMN inbox_id INTEGER;
  ALTER TABLE inbox ADD COLUMN reminder_at TEXT;
  CREATE UNIQUE INDEX idx_blocks_inbox ON blocks(inbox_id) WHERE inbox_id IS NOT NULL;
  ALTER TABLE inbox ADD COLUMN list_id INTEGER;
  ALTER TABLE inbox ADD COLUMN due_date TEXT;
  ALTER TABLE inbox ADD COLUMN due_time INTEGER;
  ALTER TABLE users ADD COLUMN nickname TEXT;
  ALTER TABLE users ADD COLUMN avatar TEXT;
`;

{
  const old = new DatabaseSync(file);
  old.exec(OLD_SCHEMA);
  old.prepare('INSERT INTO users(id,username,password_hash,created_at) VALUES(1,?,?,?)').run('legacy_user_a', 'h', '2025-03-01 08:00:00');
  old.prepare('INSERT INTO users(id,username,password_hash) VALUES(2,?,?)').run('legacy_user_b', 'h');
  old.prepare('INSERT INTO lists(user_id,name,color,emoji) VALUES(1,?,?,?)').run('考试', '#E05858', '✏️');
  // 早就打完勾的旧任务：新加的 done_at 是空的，得靠回填
  old.prepare('INSERT INTO inbox(user_id,title,done,created_at) VALUES(1,?,1,?)').run('旧完成', '2025-04-02 09:30:00');
  old.prepare('INSERT INTO inbox(user_id,title,done) VALUES(1,?,0)').run('旧待办');
  old.prepare('INSERT INTO inbox(user_id,title,list_id) VALUES(1,?,?)').run('归了类', 1);
  old.prepare('INSERT INTO blocks(user_id,date,start_min,end_min,title) VALUES(1,?,?,?,?)').run('2026-09-01', 540, 600, '旧时间块');
  old.close();
}

process.env.DB_PATH = file;
const { db } = await import('../src/db.js');
const { ensureSystemListsForAllUsers } = await import('../src/default-lists.js');
test.after(() => { db.close(); rmSync(dir, { recursive: true, force: true }); });

const cols = (t) => db.prepare(`PRAGMA table_info(${t})`).all().map(c => c.name);

test('老库能直接开：新列补上，且既有数据一行不动', () => {
  for (const c of ['deleted_at', 'done_at']) assert.ok(cols('inbox').includes(c), `inbox.${c}`);
  assert.ok(cols('blocks').includes('deleted_at'));
  assert.ok(cols('lists').includes('system'));
  assert.deepEqual(db.prepare('SELECT id,title,done FROM inbox WHERE user_id=1 ORDER BY id').all().map(t => [t.id, t.title, t.done]),
    [[1, '旧完成', 1], [2, '旧待办', 0], [3, '归了类', 0]]);
  assert.equal(db.prepare('SELECT list_id FROM inbox WHERE id=3').get().list_id, 1);
  assert.equal(db.prepare('SELECT count(*) n FROM blocks').get().n, 1);
  // 老数据没有 deleted_at，等于「都没删」，不能被当成回收站里的东西
  assert.equal(db.prepare('SELECT count(*) n FROM inbox WHERE deleted_at IS NOT NULL').get().n, 0);
});

test('旧完成任务的 done_at 由 created_at 换算成 ISO，之后不再被重复回填', () => {
  assert.equal(db.prepare('SELECT done_at FROM inbox WHERE id=1').get().done_at, '2025-04-02T09:30:00Z');
  assert.equal(db.prepare('SELECT done_at FROM inbox WHERE id=2').get().done_at, null); // 没完成的不能有完成时刻
});

test('系统清单按账号补齐，重复跑不会插重', () => {
  assert.equal(ensureSystemListsForAllUsers(), 6);   // 2 个账号 × 3 条
  assert.equal(ensureSystemListsForAllUsers(), 0);
  for (const uid of [1, 2]) {
    assert.deepEqual(db.prepare('SELECT system FROM lists WHERE user_id=? AND system IS NOT NULL ORDER BY system').all(uid).map(l => l.system),
      ['done', 'inbox', 'trash']);
  }
  // 老清单(考试)还在，颜色/emoji 没被覆盖
  assert.equal(db.prepare('SELECT color FROM lists WHERE user_id=1 AND name=?').get('考试').color, '#E05858');
  assert.equal(db.prepare('SELECT count(*) n FROM lists WHERE user_id=1 AND system IS NULL').get().n, 1);
});

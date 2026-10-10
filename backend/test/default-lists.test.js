import test from 'node:test';
import assert from 'node:assert/strict';

process.env.DB_PATH = ':memory:';
const { db } = await import('../src/db.js');
const { addMissingDefaultLists, createUserWithDefaultLists } = await import('../src/default-lists.js');
test.after(() => db.close());

test('backfill preserves existing list styling and other users, and is idempotent', () => {
  const uid = Number(db.prepare('INSERT INTO users(username,password_hash) VALUES (?,?)').run('existing', 'hash').lastInsertRowid);
  db.prepare('INSERT INTO lists(user_id,name,color,emoji) VALUES (?,?,?,?)').run(uid, '考试', '#123456', '🎓');
  db.prepare('INSERT INTO lists(user_id,name) VALUES (?,?)').run(uid, '自定义');
  const other = createUserWithDefaultLists('other', 'hash');
  const before = db.prepare('SELECT * FROM lists WHERE user_id=?').all(other);
  // 补齐 4 条缺的普通清单 + 3 条系统清单(收集箱/已完成/回收站)
  assert.equal(addMissingDefaultLists(uid), 7);
  assert.equal(addMissingDefaultLists(uid), 0);
  assert.equal(db.prepare('SELECT count(*) n FROM lists WHERE user_id=?').get(uid).n, 9);
  assert.equal(db.prepare('SELECT color FROM lists WHERE user_id=? AND name=?').get(uid, '考试').color, '#123456');
  // 系统清单按标记判重：改名之后再回填不该多长一条出来
  db.prepare('UPDATE lists SET name=? WHERE user_id=? AND system=?').run('待办收集', uid, 'inbox');
  assert.equal(addMissingDefaultLists(uid), 0);
  assert.equal(db.prepare('SELECT count(*) n FROM lists WHERE user_id=? AND system=?').get(uid, 'inbox').n, 1);
  assert.deepEqual(db.prepare('SELECT * FROM lists WHERE user_id=?').all(other), before);
});

test('a list initialization failure rolls back both account and partially inserted lists', () => {
  const count = db.prepare('SELECT count(*) n FROM lists').get().n;
  db.exec(`CREATE TRIGGER fail_defaults BEFORE INSERT ON lists WHEN NEW.name='工作事项'
    BEGIN SELECT RAISE(ABORT, 'test list failure'); END`);
  try {
    assert.throws(() => createUserWithDefaultLists('rolledback', 'hash'), /test list failure/);
    assert.equal(db.prepare('SELECT id FROM users WHERE username=?').get('rolledback'), undefined);
    assert.equal(db.prepare('SELECT count(*) n FROM lists').get().n, count);
  } finally {
    db.exec('DROP TRIGGER fail_defaults');
  }
});

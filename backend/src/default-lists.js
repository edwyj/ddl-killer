import { db } from './db.js';
import {initializeCommunityUser} from './community.js';

export const DEFAULT_LISTS = [
  { name: '学习安排', color: '#5C8DEF', emoji: '📚' },
  { name: '考试', color: '#E05858', emoji: '✏️' },
  { name: '工作事项', color: '#C48EDE', emoji: '💼' },
  { name: '生活日常', color: '#6BB5A0', emoji: '🏡' },
  { name: '购物清单', color: '#E4A45E', emoji: '🛒' },
];

// 系统清单：收集箱 = 临时缓冲区(放突然冒出来的想法)，回收站 = 被删任务的暂存处，
// 已完成 = 打完勾的任务的暂存处。按 system 标记判重而不是按名字 —— 用户把「收集箱」
// 改名了也不会多长一条出来。后端拒绝删除它们，所以对每个用户永远存在。
export const SYSTEM_LISTS = [
  { system: 'inbox', name: '收集箱', color: '#5C8DEF', emoji: '📥' },
  { system: 'done', name: '已完成', color: '#6BB5A0', emoji: '✅' },
  { system: 'trash', name: '回收站', color: '#8A8F98', emoji: '🗑️' },
];

// 回收站/已完成里的成员是算出来的，任务永远不该带这两个 id。
// 收集箱是例外：它是真容器，list_id 指向它是合法的。
export const DERIVED_SYSTEMS = ['trash', 'done'];

/** 取该用户的系统清单 id：{ inbox: 3, trash: 4 }；没建出来则对应键缺省。 */
export function getSystemListIds(userId) {
  const rows = db.prepare('SELECT id, system FROM lists WHERE user_id=? AND system IS NOT NULL').all(userId);
  const out = {};
  for (const r of rows) out[r.system] = r.id;
  return out;
}

// Only called during account creation or an explicit one-off backfill.
// Normal lists are never seeded on login/startup: users may intentionally delete them.
// System lists are the exception — they're re-ensured by system flag on every backfill.
export function addMissingDefaultLists(userId) {
  db.exec('SAVEPOINT default_lists');
  try {
    if (!db.prepare('SELECT id FROM users WHERE id=?').get(userId)) {
      throw new Error('Cannot initialize lists for a missing user');
    }
    const insert = db.prepare(`
      INSERT INTO lists (user_id,name,color,emoji)
      SELECT ?,?,?,? WHERE NOT EXISTS (
        SELECT 1 FROM lists WHERE user_id=? AND trim(name)=?
      )
    `);
    let added = 0;
    for (const { name, color, emoji } of DEFAULT_LISTS) {
      added += Number(insert.run(userId, name, color, emoji, userId, name).changes);
    }
    added += insertSystemLists(userId);
    db.exec('RELEASE default_lists');
    return added;
  } catch (error) {
    db.exec('ROLLBACK TO default_lists; RELEASE default_lists');
    throw error;
  }
}

/** 只补系统清单，按 system 标记判重(改名后再跑不会重复插)。 */
function insertSystemLists(userId) {
  const insertSystem = db.prepare(`
    INSERT INTO lists (user_id,name,color,emoji,system)
    SELECT ?,?,?,?,? WHERE NOT EXISTS (
      SELECT 1 FROM lists WHERE user_id=? AND system=?
    )
  `);
  let added = 0;
  for (const { system, name, color, emoji } of SYSTEM_LISTS) {
    added += Number(insertSystem.run(userId, name, color, emoji, system, userId, system).changes);
  }
  return added;
}

/**
 * 启动时兜底：给所有已有账号补齐系统清单。
 * 普通默认清单绝不这么补(用户删了就是删了)，但系统清单是功能入口 ——
 * 缺了「回收站」，被删的任务就没有落脚点。老账号是升级后才多出 system 这一列的，
 * 所以只能在这里补一次，而不是等用户下次登录(登录不碰数据)。
 */
export function ensureSystemListsForAllUsers() {
  let added = 0;
  for (const { id } of db.prepare('SELECT id FROM users').all()) {
    db.exec('SAVEPOINT ensure_system_lists');
    try {
      added += insertSystemLists(id);
      initializeCommunityUser(id);
      db.exec('RELEASE ensure_system_lists');
    } catch (error) {
      db.exec('ROLLBACK TO ensure_system_lists; RELEASE ensure_system_lists');
      throw error;
    }
  }
  return added;
}

export function createUserWithDefaultLists(username, passwordHash) {
  db.exec('SAVEPOINT create_account');
  try {
    const result = db.prepare('INSERT INTO users (username,password_hash) VALUES (?,?)')
      .run(username, passwordHash);
    const userId = Number(result.lastInsertRowid);
    addMissingDefaultLists(userId);
    initializeCommunityUser(userId,{welcome:true});
    db.exec('RELEASE create_account');
    return userId;
  } catch (error) {
    db.exec('ROLLBACK TO create_account; RELEASE create_account');
    throw error;
  }
}

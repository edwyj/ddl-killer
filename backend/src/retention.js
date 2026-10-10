import { db } from './db.js';
import { purgeExpiredAiHistory } from './ai-session-history.js';
import {purgeExpiredCommunity} from './community.js';

const DAY = 86400000;
export const TRASH_DAYS = 7;   // 回收站：放一周，让人有后悔的时间
export const DONE_DAYS = 3;    // 已完成：只当临时落脚点，三天就够回顾了

/** 到期清理：回收站超过 7 天、已完成超过 3 天的行真删。返回删掉的条数。 */
export function purgeExpired(now = new Date()) {
  const trashBefore = new Date(now.getTime() - TRASH_DAYS * DAY).toISOString();
  const doneBefore = new Date(now.getTime() - DONE_DAYS * DAY).toISOString();
  // 待清理的任务：在回收站待够 7 天的，或已完成够 3 天的
  const expiredTask = `SELECT id FROM inbox WHERE
    (deleted_at IS NOT NULL AND deleted_at<?)
    OR (done=1 AND deleted_at IS NULL AND done_at IS NOT NULL AND done_at<?)`;
  db.exec('SAVEPOINT retention');
  try {
    // 先删时间块再删任务：块靠 inbox_id 找任务，反了就找不着了。
    // 两块来源：自己已过期的，以及挂在过期任务下的。
    const blocks = db.prepare(`DELETE FROM blocks WHERE
      (deleted_at IS NOT NULL AND deleted_at<?)
      OR inbox_id IN (${expiredTask})`).run(trashBefore, trashBefore, doneBefore).changes;
    const tasks = db.prepare(`DELETE FROM inbox WHERE
      (deleted_at IS NOT NULL AND deleted_at<?)
      OR (done=1 AND deleted_at IS NULL AND done_at IS NOT NULL AND done_at<?)`)
      .run(trashBefore, doneBefore).changes;
    const community=purgeExpiredCommunity(now.getTime());
    db.exec('RELEASE retention');
    const ai = purgeExpiredAiHistory(now.getTime());
    return { blocks, tasks, ...ai,...community };
  } catch (error) {
    db.exec('ROLLBACK TO retention; RELEASE retention');
    throw error;
  }
}

export function startRetentionWorker() {
  const tick = () => {
    try {
      const r = purgeExpired();
      if (r.tasks || r.blocks || r.aiSessions) console.log(`[retention] 清理任务 ${r.tasks} 条 / 时间块 ${r.blocks} 条 / AI 会话 ${r.aiSessions} 条`);
    } catch (e) { console.error('Retention worker failed', e.message); }
  };
  void tick();                                    // 启动时先跑一次：服务重启期间的到期数据不留到明天
  const timer = setInterval(tick, DAY);
  timer.unref();
  return timer;
}

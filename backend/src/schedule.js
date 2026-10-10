import { readFileSync, existsSync } from 'node:fs';
import { db } from './db.js';

const SCHEDULE_PATH = process.env.SCHEDULE_PATH || '/data/schedule.json';
const SEMESTER_START = process.env.SEMESTER_START || '2026-08-31';

// 某用户的课表（schedules 表）；无则 null。'json' 列为 TEXT，解析成对象。
export function getUserSchedule(uid) {
  const row = db.prepare('SELECT json FROM schedules WHERE user_id=?').get(uid);
  if (!row) return null;
  try { return JSON.parse(row.json); } catch { return null; }
}

// 启动迁移：把旧全局文件 seed 给指定用户（幂等，已有则不覆盖）。返回是否写入。
export function seedScheduleFromFile(uid) {
  if (!db.prepare('SELECT 1 FROM users WHERE id=?').get(uid)) return false;
  if (getUserSchedule(uid)) return false;          // 已有课表，不动
  if (!existsSync(SCHEDULE_PATH)) return false;
  try {
    const raw = readFileSync(SCHEDULE_PATH, 'utf8');
    JSON.parse(raw);                                // 校验有效 JSON
    db.prepare('INSERT OR REPLACE INTO schedules (user_id, json) VALUES (?,?)')
      .run(uid, raw);
    return true;
  } catch { return false; }
}

function toMin(hhmm) {
  const [h, m] = String(hhmm).split(':').map(Number);
  return h * 60 + (m || 0);
}

export function currentWeek(schedule, dateStr) {
  const start = (schedule && schedule.semester_start) || SEMESTER_START;
  if (!start) return 1;
  const s = new Date(start + 'T00:00:00');
  const d = new Date(dateStr + 'T00:00:00');
  const diff = Math.floor((d - s) / 86400000);
  if (diff < 0) return 0; // 学期开始前：无课(避免把之前周误判成第1周)
  return Math.floor(diff / 7) + 1;
}

export function weekday(dateStr) {
  const d = new Date(dateStr + 'T00:00:00');
  return d.getDay() === 0 ? 7 : d.getDay();
}

// TickTick 柔和彩色(课程块每门课固定一色,不用纯灰)
const COURSE_PALETTE = [
  '#5C8DEF', '#E891A8', '#9B7EDE', '#E4C56B',
  '#6BB5A0', '#E89A6B', '#C48EDE', '#6BB5C9',
];
function colorForCourse(id) {
  let h = 0;
  for (const ch of String(id)) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return COURSE_PALETTE[h % COURSE_PALETTE.length];
}

/** 某天的课程(按 schedule.json 计算) */
export function getDayClasses(schedule, dateStr) {
  const wd = weekday(dateStr);
  const weekNum = currentWeek(schedule, dateStr);
  const p2b = schedule.period_to_block || {};
  const pt = schedule.period_times || {};
  const classes = [];
  for (const c of schedule.courses || []) {
    for (const slot of c.slots || []) {
      if (slot.weekday !== wd) continue;
      if (!(slot.weeks || []).includes(weekNum)) continue;
      const periods = slot.periods || [];
      const blockNum = periods.length ? p2b[String(periods[0])] : null;
      const times = blockNum ? pt[String(blockNum)] : null;
      const [start_min, end_min] = times ? times.map(toMin) : [0, 0];
      classes.push({
        type: 'class',
        title: c.name,
        teacher: c.teacher || '',
        room: slot.room || '',
        group: slot.group || '',
        weeks: slot.weeks,
        weekNum,
        block: blockNum, // 大节号(供课表网格分行)
        start_min,
        end_min,
        color: colorForCourse(c.course_id),
      });
    }
  }
  return classes.sort((a, b) => a.start_min - b.start_min);
}

export function getClassesInRange(schedule, startDate, endDate) {
  const days = [];
  for (let cursor = Date.parse(`${startDate}T00:00:00Z`), end = Date.parse(`${endDate}T00:00:00Z`);
    cursor <= end; cursor += 86400000) {
    const date = new Date(cursor).toISOString().slice(0, 10);
    days.push(...getDayClasses(schedule, date).map((course) => ({ date, ...course })));
  }
  return days;
}

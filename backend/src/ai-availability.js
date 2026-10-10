import { db } from "./db.js";
db.exec(
  "CREATE TABLE IF NOT EXISTS ai_planning_preferences(user_id INTEGER PRIMARY KEY,start_minute INTEGER NOT NULL,end_minute INTEGER NOT NULL,break_minutes INTEGER NOT NULL)",
);
export function localClock(now = Date.now()) {
  const shifted = new Date(now + 8 * 3600000);
  return {
    date: shifted.toISOString().slice(0, 10),
    minute: shifted.getUTCHours() * 60 + shifted.getUTCMinutes(),
    timeZone: "Asia/Shanghai",
  };
}
export function planningPreferences(uid) {
  const row = db
    .prepare("SELECT * FROM ai_planning_preferences WHERE user_id=?")
    .get(uid);
  return {
    startMinute: row?.start_minute ?? 480,
    endMinute: row?.end_minute ?? 1320,
    breakMinutes: row?.break_minutes ?? 15,
  };
}
export function savePlanningPreferences(uid, value) {
  const {
    startMinute: start,
    endMinute: end,
    breakMinutes: rest,
  } = value ?? {};
  if (
    !Number.isInteger(start) ||
    !Number.isInteger(end) ||
    !Number.isInteger(rest) ||
    start < 0 ||
    end > 1440 ||
    start >= end ||
    start % 15 ||
    end % 15 ||
    rest < 0 ||
    rest > 60 ||
    rest % 5
  )
    throw Object.assign(new Error("请检查可安排时段和休息间隔"), {
      status: 400,
    });
  db.prepare(
    "INSERT INTO ai_planning_preferences VALUES(?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET start_minute=excluded.start_minute,end_minute=excluded.end_minute,break_minutes=excluded.break_minutes",
  ).run(uid, start, end, rest);
  return planningPreferences(uid);
}
export function freeWindows(
  startDate,
  endDate,
  blocks,
  courses,
  preferences,
  now = Date.now(),
) {
  if (blocks.length + courses.length > 10000)
    throw Object.assign(new Error("AI_CONTEXT_INVALID"), {
      code: "AI_CONTEXT_INVALID",
    });
  const clock = localClock(now),
    windows = [];
  const all = [
    ...blocks.map((b) => ({
      date: b.date,
      start: b.start_min,
      end: b.end_min,
    })),
    ...courses.map((c) => ({
      date: c.date,
      start: c.start_min,
      end: c.end_min,
    })),
  ];
  const byDate = new Map();
  for (const block of all) {
    if (!byDate.has(block.date)) byDate.set(block.date, []);
    byDate.get(block.date).push(block);
  }
  for (
    let cursor = Date.parse(startDate + "T00:00:00Z"),
      end = Date.parse(endDate + "T00:00:00Z");
    cursor <= end;
    cursor += 86400000
  ) {
    const date = new Date(cursor).toISOString().slice(0, 10);
    if (date < clock.date) continue;
    let position =
      date === clock.date
        ? Math.max(preferences.startMinute, Math.ceil(clock.minute / 15) * 15)
        : preferences.startMinute;
    const intervals = (byDate.get(date) ?? [])
      .filter((b) => b.end > b.start)
      .map((b) => ({
        start: Math.max(0, b.start - preferences.breakMinutes),
        end: Math.min(1440, b.end + preferences.breakMinutes),
      }))
      .sort((a, b) => a.start - b.start);
    for (const interval of intervals) {
      const before = Math.min(interval.start, preferences.endMinute);
      if (before - position >= 15)
        windows.push({ date, start: position, end: before });
      position = Math.max(position, interval.end);
    }
    if (preferences.endMinute - position >= 15)
      windows.push({ date, start: position, end: preferences.endMinute });
  }
  return windows.map(w=>({...w,start:Math.ceil(w.start/15)*15,end:Math.floor(w.end/15)*15})).filter(w=>w.end-w.start>=15);
}

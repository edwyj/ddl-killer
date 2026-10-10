// 文档示例校验器；使用实际课程展开函数，不连接教务系统或运行中的后端。
// 从仓库根目录运行：node docs/examples/validate-timetable-demo.mjs [课表文件路径]
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const isDemo = !process.argv[2];
const file = process.argv[2] || fileURLToPath(new URL('./timetable-demo.json', import.meta.url));
const raw = readFileSync(file);
assert.ok(raw.length <= 1024 * 1024, '文件需不超过 1 MB');
const schedule = JSON.parse(raw.toString('utf8').replace(/^\uFEFF/, ''));
assert.ok(schedule && typeof schedule === 'object' && !Array.isArray(schedule), '顶层需为对象');
assert.match(schedule.semester_start || '', /^\d{4}-\d{2}-\d{2}$/, '需提供 semester_start');
const firstDay = new Date(schedule.semester_start + 'T00:00:00Z');
assert.ok(Number.isFinite(firstDay.getTime()), 'semester_start 需为有效日期');
assert.equal(firstDay.toISOString().slice(0, 10), schedule.semester_start, '日期不能溢出到下个月');
assert.equal(firstDay.getUTCDay(), 1, 'semester_start 需为第 1 周周一');
assert.ok(Array.isArray(schedule.courses) && schedule.courses.length > 0, '需有至少一门课程');

function sortedPositiveIntegers(values, label) {
  assert.ok(Array.isArray(values) && values.length > 0, label + ' 需为非空数组');
  assert.ok(values.every((n) => Number.isInteger(n) && n > 0), label + ' 需为正整数');
  assert.deepEqual(values, [...new Set(values)].sort((a, b) => a - b), label + ' 需去重并升序排列');
}
function minutes(value) {
  assert.match(value || '', /^(?:[01]\d|2[0-3]):[0-5]\d$/, '时间需为 HH:mm');
  const [h, m] = value.split(':').map(Number);
  return h * 60 + m;
}

const ids = new Set();
let slotCount = 0;
for (const course of schedule.courses) {
  assert.ok(typeof course.course_id === 'string' && course.course_id.trim(), '需有稳定的 course_id');
  assert.ok(!ids.has(course.course_id), '同一课程请合并 slots，避免重复 course_id');
  ids.add(course.course_id);
  assert.ok(typeof course.name === 'string' && course.name.trim(), '课名不能为空');
  assert.ok(Array.isArray(course.slots) && course.slots.length > 0, '固定课程需有 slots');
  for (const slot of course.slots) {
    slotCount++;
    assert.ok(Number.isInteger(slot.weekday) && slot.weekday >= 1 && slot.weekday <= 7, 'weekday 需为 1..7');
    sortedPositiveIntegers(slot.weeks, 'weeks');
    sortedPositiveIntegers(slot.periods, 'periods');
    const block = schedule.period_to_block?.[String(slot.periods[0])];
    assert.ok(Number.isInteger(block) && block > 0, '每个节次需映射到正整数大节');
    assert.ok(slot.periods.every((p) => schedule.period_to_block?.[String(p)] === block),
      '一个 slot 的全部节次需属于同一个大节；跨大节请拆分');
    const times = schedule.period_times?.[String(block)];
    assert.ok(Array.isArray(times) && times.length === 2, '大节需有起止时间');
    assert.ok(minutes(times[0]) < minutes(times[1]), '开始时间需早于结束时间');
  }
}

// 必须在动态导入前设置，避免 schedule.js 的数据库依赖打开真实数据库。
process.env.DB_PATH = ':memory:';
const { getDayClasses, currentWeek } = await import('../../backend/src/schedule.js');
const { db } = await import('../../backend/src/db.js');
try {
  // 每个时段在它的首个上课日，都应按实际后端逻辑展开到正确时刻。
  for (const course of schedule.courses) {
    for (const slot of course.slots) {
      const date = new Date(firstDay);
      date.setUTCDate(date.getUTCDate() + (slot.weeks[0] - 1) * 7 + slot.weekday - 1);
      const ymd = date.toISOString().slice(0, 10);
      const block = schedule.period_to_block[String(slot.periods[0])];
      const [start, end] = schedule.period_times[String(block)].map(minutes);
      assert.ok(getDayClasses(schedule, ymd).some((c) => c.title === course.name &&
        c.room === (slot.room || '') && c.start_min === start && c.end_min === end),
      '时段未按预期展开到具体日期与时刻');
    }
  }
  if (isDemo) {
    assert.equal(currentWeek(schedule, '2026-08-30'), 0);
    assert.deepEqual(getDayClasses(schedule, '2026-08-30'), [], '学期前无课');
    assert.equal(getDayClasses(schedule, '2026-08-31')[0].start_min, 480);
    assert.equal(getDayClasses(schedule, '2026-08-31')[0].end_min, 575);
    assert.equal(getDayClasses(schedule, '2026-09-02').length, 1, '第 1 周有单周习题课');
    assert.equal(getDayClasses(schedule, '2026-09-09').length, 0, '第 2 周没有单周习题课');
    assert.equal(getDayClasses(schedule, '2026-09-01').length, 0, '第 1 周没有双周程序设计课');
    assert.equal(getDayClasses(schedule, '2026-09-08')[0].title, '示例程序设计课');
    assert.equal(getDayClasses(schedule, '2026-09-11')[0].room, '虚构楼 C301');
    assert.equal(getDayClasses(schedule, '2026-09-25')[0].room, '虚构楼 C302', '第 4 周更换实验室');
    assert.deepEqual(getDayClasses(schedule, '2026-09-28'), [], '第 5 周不应多出课程');
  }
  console.log('课表校验通过：' + schedule.courses.length + ' 门课程，' + slotCount + ' 个时段；已核对实际后端日期与时刻展开。');
} finally {
  db.close();
}

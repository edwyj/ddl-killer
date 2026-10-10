// 哈工深课表导出脚本的离线解析测试。
// ⚠️ 这里的课程名、教师、教室、周次全部是编造的样例，不含任何真实教务数据。
// 运行：cd app && node tool/hitsz_kebiao_export_test.mjs
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';

const require = createRequire(import.meta.url);
const api = require('../web/userscript/hitsz-kebiao-export.user.js');

// ───────── 单个格子的 SKSJ 解析 ─────────

// ① 理论课：课名 / 教师 / 周次+教室 / 节次
const theory = api.parseSKSJ([
  '课程甲',
  '[甲老师]',
  '[1-5,7-13周][A101]',
  '第1-2节',
].join('\n'));
assert.equal(theory.name, '课程甲');
assert.equal(theory.teacher, '甲老师');
assert.equal(theory.room, 'A101');
assert.deepEqual(theory.weeks, [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13]);
assert.deepEqual(theory.periods, [1, 2]);

// ② 课名占两行的体育课；两段周次各带一个场地，中间用逗号相连（合并后的形态）
const sport = api.parseSKSJ([
  '课程乙',
  '项目乙',
  '[乙老师]',
  '[1周][A201],[2-5,7-17周][第二运动场]',
  '第3-4节',
].join('\n'));
assert.equal(sport.name, '课程乙 项目乙');
assert.equal(sport.teacher, '乙老师');
assert.equal(sport.room, 'A201/第二运动场');
assert.deepEqual(sport.weeks, [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]);
assert.deepEqual(sport.periods, [3, 4]);

// ③ 实验课：节次和周次同一行、教室单独一行且排在周次之后 ⇒ 不能把它当成教师
const lab = api.parseSKSJ([
  '【实验】课程丙 第1组',
  '[3-4节][9-10周]',
  '[B202]',
].join('\n'));
assert.equal(lab.name, '【实验】课程丙 第1组');
assert.equal(lab.teacher, '', '周次行之后的方括号是教室，不是教师');
assert.equal(lab.room, 'B202');
assert.deepEqual(lab.weeks, [9, 10]);
assert.deepEqual(lab.periods, [3, 4]);

// ④ 实验课课名末尾自带 [实验项目名]，不能被当成元信息行
const labNamed = api.parseSKSJ([
  '【实验】课程丁 第2批/第三组[项目名称样例]',
  '[1-2节][3周]',
  '[B303]',
].join('\n'));
assert.equal(labNamed.name, '【实验】课程丁 第2批/第三组[项目名称样例]');
assert.equal(labNamed.room, 'B303');
assert.deepEqual(labNamed.weeks, [3]);

// ⑤ 单周 / 双周要展开成具体周次
const odd = api.parseSKSJ(['课程戊', '[1-8周][A301]', '第5-6节'].join('\n'));
assert.deepEqual(odd.weeks, [1, 2, 3, 4, 5, 6, 7, 8]);
const oddOnly = api.parseSKSJ(['课程己', '[1-8周 单周][A302]', '第5-6节'].join('\n'));
assert.deepEqual(oddOnly.weeks, [1, 3, 5, 7]);
assert.equal(oddOnly.parity, '单');
const evenOnly = api.parseSKSJ(['课程庚', '[1-8周 双][A303]', '第5-6节'].join('\n'));
assert.deepEqual(evenOnly.weeks, [2, 4, 6, 8]);
assert.equal(evenOnly.parity, '双');

// ⑥ 单个小节的写法
assert.deepEqual(api.parsePeriods('[9节]'), [9]);
assert.deepEqual(api.parsePeriods('第7-8节'), [7, 8]);
assert.deepEqual(api.parseWeeks('第3周,第5周').weeks, [3, 5]);

// ───────── KEY / 课名归一 ─────────
assert.deepEqual(api.parseKey('xq1_jc3'), {weekday: 1, block: 3});
assert.deepEqual(api.parseKey('xq7_jc1'), {weekday: 7, block: 1});
assert.equal(api.parseKey('随便什么'), null);
assert.equal(api.canonicalName('【实验】课程丁 第2批/第三组[项目名称样例]'), '【实验】课程丁 第2批/第三组');
assert.equal(api.extractGroup('【实验】课程丁 第2批/第三组[项目名称样例]'), '第三组');
assert.equal(api.extractGroup('课程甲'), '');

// ───────── 整学期条目 → 时段 ─────────
// 同一门课被教务拆成多条（不同周次），应当各自成段；重复条目要去掉
const items = [
  {KEY: 'xq1_jc1', SKSJ: '课程甲\n[甲老师]\n[1-5周][A101]\n第1-2节'},
  {KEY: 'xq1_jc1', SKSJ: '课程甲\n[甲老师]\n[7-13周][A101]\n第1-2节'},
  {KEY: 'xq1_jc1', SKSJ: '课程甲\n[甲老师]\n[7-13周][A101]\n第1-2节'},   // 完全重复
  {KEY: 'xq3_jc2', SKSJ: '课程甲\n[乙老师]\n[1-13周][A102]\n第3-4节'},
  {KEY: 'xq9_jc1', SKSJ: '课程辛\n[丙老师]\n[1周][A101]\n第1-2节'},      // 星期几不合法
  {KEY: 'xq2_jc1', SKSJ: '没有周次也没有节次的怪数据'},
];
const sections = api.parseItems(items);
assert.equal(sections.length, 3, '重复条目去重、非法星期丢弃、无法解析的丢弃');
assert.deepEqual(sections.map((s) => [s.name, s.weekday, s.weeks.length]),
  [['课程甲', 1, 5], ['课程甲', 1, 7], ['课程甲', 3, 13]]);

// 缺 KEY 时用 XQJ 兜底；缺节次时用 KSJC/JSJC 兜底
const fallback = api.parseItems([
  {XQJ: 4, KSJC: 5, JSJC: 6, SKSJ: '课程壬\n[丁老师]\n[1周][A401]'},
]);
assert.equal(fallback.length, 1);
assert.equal(fallback[0].weekday, 4);
assert.deepEqual(fallback[0].periods, [5, 6]);
assert.equal(fallback[0].block, 3);

// ───────── 课程聚合 ─────────
const courses = api.groupCourses(sections);
assert.deepEqual(courses.map((c) => c.name), ['课程甲']);
assert.equal(courses[0].teacher, '甲老师、乙老师', '同一门课的不同教师合并展示');
assert.equal(courses[0].slots.length, 3);
assert.deepEqual(courses[0].slots.map((s) => s.section), [1, 2, 3]);
assert.match(courses[0].course_id, /^hitsz-[0-9a-z]+$/);
// 课程号必须稳定：同样的课名，两次调用得到同一个 id
assert.equal(api.courseId('课程甲'), courses[0].course_id);
assert.notEqual(api.courseId('课程甲'), api.courseId('课程乙'));

const labCourses = api.groupCourses(api.parseItems([
  {KEY: 'xq2_jc3', SKSJ: '【实验】课程丙 第1组[实验一]\n[3-4节][9周]\n[B202]'},
  {KEY: 'xq2_jc3', SKSJ: '【实验】课程丙 第1组[实验二]\n[3-4节][10周]\n[B203]'},
]));
assert.equal(labCourses.length, 1, '不同周的实验项目名不应把一门课拆成多门');
assert.equal(labCourses[0].name, '【实验】课程丙 第1组');
assert.equal(labCourses[0].slots.length, 2);
assert.equal(labCourses[0].slots[0].group, '第1组');

// ───────── 作息表 ─────────
const tables = api.buildPeriodTables([
  {dj: 1, xj: 1, kssj: '08:30', jssj: '09:15'},
  {dj: 1, xj: 2, kssj: '09:20', jssj: '10:05'},
  {dj: 3, xj: 5, kssj: '14:00:00', jssj: '15:35:00'},
], [1, 3, 6]);
assert.deepEqual(tables.period_times['1'], ['08:30', '10:05'], '取该大节最早开始 / 最晚结束');
assert.deepEqual(tables.period_times['3'], ['14:00', '15:35'], '秒要截掉');
assert.equal(tables.period_to_block['2'], 1);
assert.equal(tables.period_to_block['5'], 3);
assert.deepEqual(tables.period_times['6'], api.FALLBACK_PERIOD_TIMES['6'], '教务没覆盖的大节用兜底作息补齐');
assert.equal(tables.period_to_block['12'], 6);
const noKbjg = api.buildPeriodTables([], [1]);
assert.deepEqual(noKbjg.period_times['1'], api.FALLBACK_PERIOD_TIMES['1']);

// ───────── 日期 ─────────
assert.equal(api.normalizeDate('2026-09-07', '2026'), '2026-09-07');
assert.equal(api.normalizeDate('2026/9/7', '2026'), '2026-09-07');
assert.equal(api.normalizeDate('09-07', '2026-2027'), '2026-09-07', '只有月日时用学年补年份');
assert.equal(api.normalizeDate('9-7', '2026'), '2026-09-07');
assert.equal(api.normalizeDate('2026-13-40', '2026'), '');
assert.equal(api.normalizeDate('', '2026'), '');
assert.equal(api.normalizeDate(null, '2026'), '');

// 2026-09-07 是周一，2026-09-13 是周日 → 同一周的周一都是 09-07
assert.equal(api.mondayOf(new Date(2026, 8, 7)), '2026-09-07');
assert.equal(api.mondayOf(new Date(2026, 8, 13)), '2026-09-07');
assert.equal(api.mondayOf(new Date(2026, 8, 14)), '2026-09-14');
assert.equal(api.shiftDays('2026-09-14', -7), '2026-09-07');
assert.equal(api.shiftDays('2026-12-28', 7), '2027-01-04', '跨年');

// ───────── 接口路径（2026-10-05 真机首点即 404 的回归测试）─────────
// 教务平台自己的代码是 var baseUrl="/" 再拼路径 ⇒ 全部是站点根绝对路径。
// 若写成不带斜杠的相对路径，fetch 会按「当前页面所在目录」解析：
// 在 /authentication/main 下点导出就打到 /authentication/component/…，必然 404。
assert.ok(api.ENDPOINTS, '脚本必须导出 ENDPOINTS 供本测试核对');
for (const [name, path] of Object.entries(api.ENDPOINTS)) {
  assert.ok(path.startsWith('/'), name + ' 必须是站点根绝对路径，实际是「' + path + '」');
}
assert.deepEqual(api.ENDPOINTS, {
  xnxq: '/component/querydangqianxnxq',
  zc: '/component/querydangqianzc',
  all: '/xszykb/queryxszykbzong',
  kbjg: '/component/queryKbjg',
  rlzc: '/component/queryRlZcSj',
});

console.log('哈工深课表导出脚本：解析测试全部通过');

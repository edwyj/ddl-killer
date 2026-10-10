import {emailOptions,registerVerified} from './helpers/verified-registration.js';
import test from 'node:test';
import assert from 'node:assert/strict';

process.env.DB_PATH = ':memory:';
process.env.JWT_SECRET = 'test-secret';

const { createApp } = await import('../src/app.js');
const { db } = await import('../src/db.js');
const { getUserSchedule } = await import('../src/schedule.js');

// 注册现已要求图形验证码(契约变更)。包一层真实的 svgCaptcha.create 并记下明文。
const svgCaptcha = (await import('svg-captcha')).default;
const realCreate = svgCaptcha.create;
let lastCode = null;
svgCaptcha.create = (opts) => { const cap = realCreate(opts); lastCode = cap.text; return cap; };

let app, server, base;
test.before(async () => {
  app = createApp({email:emailOptions});
  server = await new Promise((r) => {
    const s = app.listen(0, () => { base = `http://127.0.0.1:${s.address().port}`; r(s); });
  });
});
test.after(async () => {
  await new Promise((r) => server.close(r));
  db.close();
});

const SAMPLE = { semester_start: '2026-08-31', courses: [{ course_id: 'c1', name: '高数', teacher: '张', slots: [{ weekday: 1, periods: [1], weeks: [1,2], room: 'A101' }] }], period_to_block: { '1': '1' }, period_times: { '1': ['08:00','10:00'] } };

async function registerAndLogin(username) {
  lastCode = null;
  const cap = await (await fetch(`${base}/api/auth/captcha`)).json();
  const reg=await registerVerified(app,base,{username,password:'secret123-strong',captcha_id:cap.id,captcha_code:lastCode});
  if (reg.status !== 200) throw new Error(`register ${username} 失败: ${reg.status} ${await reg.text()}`);
  const r = await fetch(`${base}/api/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username, password: 'secret123-strong' }) });
  return (await r.json()).token;
}

test('GET /api/schedule 无课表返回 404', async () => {
  const t = await registerAndLogin('zoe');
  const r = await fetch(`${base}/api/schedule`, { headers: { authorization: `Bearer ${t}` } });
  assert.equal(r.status, 404);
});
test('PUT 导入课表 -> GET 返回本人课表；他人无', async () => {
  const ta = await registerAndLogin('ann');
  const r = await fetch(`${base}/api/schedule`, { method: 'PUT', headers: { 'content-type': 'application/json', authorization: `Bearer ${ta}` }, body: JSON.stringify(SAMPLE) });
  assert.equal(r.status, 200);
  const g = await fetch(`${base}/api/schedule`, { headers: { authorization: `Bearer ${ta}` } });
  const s = await g.json();
  assert.equal(s.courses.length, 1);
  const tb = await registerAndLogin('ben');
  const gb = await fetch(`${base}/api/schedule`, { headers: { authorization: `Bearer ${tb}` } });
  assert.equal(gb.status, 404);
});
test('per-user timeline：ann 有一天有课程，ben 同天无', async () => {
  const ta = await (await fetch(`${base}/api/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username: 'ann', password: 'secret123-strong' }) })).json();
  const tb = await (await fetch(`${base}/api/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username: 'ben', password: 'secret123-strong' }) })).json();
  const da = await (await fetch(`${base}/api/day?date=2026-08-31`, { headers: { authorization: `Bearer ${ta.token}` } })).json();
  const db2 = await (await fetch(`${base}/api/day?date=2026-08-31`, { headers: { authorization: `Bearer ${tb.token}` } })).json();
  assert.equal(da.classes.length, 1);
  assert.equal(db2.classes.length, 0);
});

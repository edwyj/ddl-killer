import {emailOptions,registerVerified} from './helpers/verified-registration.js';
import test from 'node:test';
import assert from 'node:assert/strict';

// 必须在 import db/app 前设 env
process.env.DB_PATH = ':memory:';
process.env.JWT_SECRET = 'test-secret';

const { createApp } = await import('../src/app.js');
const { db } = await import('../src/db.js');

// 注册现已要求图形验证码(契约变更)。这里包一层真实的 svgCaptcha.create，
// 顺便记下明文，好让测试能提交正确的 captcha_code。
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

// 取一张验证码 + 带上明文注册。captcha 环节先断言好，
// 否则验证码一坏，下面期望 400 的用例会「因为错误的原因」通过。
async function reg(username, password) {
  lastCode = null;
  const cr = await fetch(`${base}/api/auth/captcha`);
  assert.equal(cr.status, 200, 'captcha 端点应可用');
  const cap = await cr.json();
  assert.ok(lastCode, '探针应拿到真实验证码明文');
  return registerVerified(app,base,{ username, password, captcha_id:cap.id,captcha_code:lastCode });
}

test('register 成功并返回 username', async () => {
  const r = await reg('alice', 'secret123-strong');
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.username, 'alice');
});
test('register 重名返回 409', async () => {
  const r = await reg('alice', 'secret123-strong');
  assert.equal(r.status, 409);
});

test('new account gets editable default lists; deleted defaults stay deleted after login', async () => {
  assert.equal((await reg('defaults', 'secret123-strong')).status, 200);
  const login = async () => {
    const r = await fetch(`${base}/api/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username: 'defaults', password: 'secret123-strong' }) });
    assert.equal(r.status, 200);
    return { authorization: `Bearer ${(await r.json()).token}` };
  };
  let headers = await login();
  const lists = await (await fetch(`${base}/api/lists`, { headers })).json();
  const normal = lists.filter(l => !l.system);
  assert.deepEqual(normal.map(l => l.name), ['学习安排', '考试', '工作事项', '生活日常', '购物清单']);
  assert.ok(normal.every(l => /^#[0-9A-F]{6}$/.test(l.color) && l.emoji && l.task_count === 0));
  // 三条系统清单：收集箱是真容器，已完成/回收站是自动归集的入口
  assert.deepEqual(lists.filter(l => l.system).map(l => [l.name, l.system]),
    [['收集箱', 'inbox'], ['已完成', 'done'], ['回收站', 'trash']]);
  // 系统清单删不得：删了功能入口就没了，而且靠标记认、名字改了也认得出
  const sysId = lists.find(l => l.system === 'trash').id;
  assert.equal((await fetch(`${base}/api/lists/${sysId}`, { method: 'DELETE', headers })).status, 400);
  assert.equal((await fetch(`${base}/api/lists/${normal[0].id}`, { method: 'DELETE', headers })).status, 200);
  headers = await login();
  const after = await (await fetch(`${base}/api/lists`, { headers })).json();
  assert.equal(after.filter(l => !l.system).length, 4);
  assert.equal(after.filter(l => l.system).length, 3); // 删普通清单不该误伤系统清单
});
test('register 弱密码返回 400', async () => {
  const r = await reg('bob', '123');
  assert.equal(r.status, 400);
  // 钉死是「密码」这条校验挂的，不是验证码那关挂的
  assert.match((await r.json()).error, /密码/);
});
test('login 成功 + me 返回 has_schedule', async () => {
  const r = await fetch(`${base}/api/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username: 'alice', password: 'secret123-strong' }) });
  assert.equal(r.status, 200);
  const { token } = await r.json();
  const me = await fetch(`${base}/api/me`, { headers: { authorization: `Bearer ${token}` } });
  assert.equal((await me.json()).has_schedule, false);
});
test('改密：旧密错误 401，改后新密登录成功', async () => {
  const login = await fetch(`${base}/api/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username: 'alice', password: 'secret123-strong' }) });
  const { token } = await login.json();
  const bad = await fetch(`${base}/api/auth/password`, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` }, body: JSON.stringify({ old_password: 'nope', new_password: 'newpass123-strong' }) });
  assert.equal(bad.status, 401);
  const ok = await fetch(`${base}/api/auth/password`, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` }, body: JSON.stringify({ old_password: 'secret123-strong', new_password: 'newpass123-strong' }) });
  assert.equal(ok.status, 200);
  const relogin = await fetch(`${base}/api/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username: 'alice', password: 'newpass123-strong' }) });
  assert.equal(relogin.status, 200);
});
test('数据隔离：A 建的任务 B 看不到', async () => {
  const mk = async (u, p) => (await (await fetch(`${base}/api/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username: u, password: p }) })).json()).token;
  const ta = await mk('alice', 'newpass123-strong');
  const rb = await reg('carol', 'secret123-strong');
  assert.equal(rb.status, 200);
  const tc = await mk('carol', 'secret123-strong');
  await fetch(`${base}/api/inbox`, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${ta}` }, body: JSON.stringify({ title: 'A的私事' }) });
  const inboxA = await (await fetch(`${base}/api/inbox`, { headers: { authorization: `Bearer ${ta}` } })).json();
  const inboxC = await (await fetch(`${base}/api/inbox`, { headers: { authorization: `Bearer ${tc}` } })).json();
  assert.equal(inboxA.length, 1);
  assert.equal(inboxC.length, 0);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import bcrypt from 'bcryptjs';

// 必须在 import db/app 前设 env
process.env.DB_PATH = ':memory:';
process.env.JWT_SECRET = 'test-secret';

const { createApp } = await import('../src/app.js');
const { db } = await import('../src/db.js');

let app, server, base, token;

const JSON_HEADERS = { 'content-type': 'application/json' };
const authHeaders = (t) => ({ ...JSON_HEADERS, authorization: `Bearer ${t}` });

test.before(async () => {
  app = createApp();
  server = await new Promise((r) => {
    const s = app.listen(0, () => { base = `http://127.0.0.1:${s.address().port}`; r(s); });
  });

  // 首个账号走 setup（users 表空时可用，不受注册验证码影响），再 login 拿 token
  const su = await fetch(`${base}/api/auth/setup`, {
    method: 'POST', headers: JSON_HEADERS,
    body: JSON.stringify({ username: 'profile_user', password: 'secret123-strong' }),
  });
  assert.equal(su.status, 200);
  const lg = await fetch(`${base}/api/auth/login`, {
    method: 'POST', headers: JSON_HEADERS,
    body: JSON.stringify({ username: 'profile_user', password: 'secret123-strong' }),
  });
  assert.equal(lg.status, 200);
  token = (await lg.json()).token;
  assert.ok(token, 'login 应返回 token');
});

test.after(async () => {
  await new Promise((r) => server.close(r));
  db.close();
});

// ---------- GET /api/me ----------

test('GET /api/me 返回 4 字段，nickname/avatar 初始为空串', async () => {
  const r = await fetch(`${base}/api/me`, { headers: authHeaders(token) });
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.username, 'profile_user');
  assert.equal(j.nickname, '');
  assert.equal(j.avatar, '');
  assert.equal(j.has_schedule, false);
});

test('GET /api/me 无 token 返回 401', async () => {
  const r = await fetch(`${base}/api/me`);
  assert.equal(r.status, 401);
});

// ---------- PATCH /api/me ----------

test('PATCH /api/me 昵称往返：写进去再读出来一致', async () => {
  const p = await fetch(`${base}/api/me`, {
    method: 'PATCH', headers: authHeaders(token),
    body: JSON.stringify({ nickname: '无意' }),
  });
  assert.equal(p.status, 200);
  assert.deepEqual(await p.json(), { ok: true });

  const j = await (await fetch(`${base}/api/me`, { headers: authHeaders(token) })).json();
  assert.equal(j.nickname, '无意');
  assert.equal(j.username, 'profile_user', '改昵称不应影响用户名');
});

test('PATCH /api/me 昵称超 24 字返回 400 且不写入', async () => {
  // 自带基线，不依赖前面用例留下的状态（可乱序/并发跑）
  const BASE = '基线昵称';
  const set = await fetch(`${base}/api/me`, {
    method: 'PATCH', headers: authHeaders(token),
    body: JSON.stringify({ nickname: BASE }),
  });
  assert.equal(set.status, 200);

  const r = await fetch(`${base}/api/me`, {
    method: 'PATCH', headers: authHeaders(token),
    body: JSON.stringify({ nickname: '很'.repeat(25) }),
  });
  assert.equal(r.status, 400);
  assert.ok(typeof (await r.json()).error === 'string');

  const j = await (await fetch(`${base}/api/me`, { headers: authHeaders(token) })).json();
  assert.equal(j.nickname, BASE, '校验失败不应改动已存昵称');
});

test('PATCH /api/me 昵称非字符串返回 400', async () => {
  const r = await fetch(`${base}/api/me`, {
    method: 'PATCH', headers: authHeaders(token),
    body: JSON.stringify({ nickname: 12345 }),
  });
  assert.equal(r.status, 400);
});

test('PATCH /api/me 预设头像往返：preset:#7C4DFF:意', async () => {
  const spec = 'preset:#7C4DFF:意';
  const p = await fetch(`${base}/api/me`, {
    method: 'PATCH', headers: authHeaders(token),
    body: JSON.stringify({ avatar: spec }),
  });
  assert.equal(p.status, 200);
  const j = await (await fetch(`${base}/api/me`, { headers: authHeaders(token) })).json();
  assert.equal(j.avatar, spec);
});

test('PATCH /api/me 照片头像 data:image/ 往返', async () => {
  const spec = 'data:image/png;base64,' + Buffer.from('fake-png-bytes').toString('base64');
  const p = await fetch(`${base}/api/me`, {
    method: 'PATCH', headers: authHeaders(token),
    body: JSON.stringify({ avatar: spec }),
  });
  assert.equal(p.status, 200);
  const j = await (await fetch(`${base}/api/me`, { headers: authHeaders(token) })).json();
  assert.equal(j.avatar, spec);
});

test('PATCH /api/me 非法头像格式返回 400', async () => {
  // 自带基线，不依赖前面用例留下的状态
  const BASE = 'preset:#3D5AFE:测';
  const set = await fetch(`${base}/api/me`, {
    method: 'PATCH', headers: authHeaders(token),
    body: JSON.stringify({ avatar: BASE }),
  });
  assert.equal(set.status, 200);

  for (const bad of ['javascript:alert(1)', 'https://evil.example/a.png', 'preset', 'data:text/html;base64,PHNjcmlwdD4=']) {
    const r = await fetch(`${base}/api/me`, {
      method: 'PATCH', headers: authHeaders(token),
      body: JSON.stringify({ avatar: bad }),
    });
    assert.equal(r.status, 400, `avatar=${bad} 应被拒绝`);
    assert.ok(typeof (await r.json()).error === 'string');
  }
  const j = await (await fetch(`${base}/api/me`, { headers: authHeaders(token) })).json();
  assert.equal(j.avatar, BASE, '被拒的头像不应覆盖原值');
});

test('PATCH /api/me 头像超 500000 字符返回 400', async () => {
  const tooBig = 'data:image/jpeg;base64,' + 'A'.repeat(500001);
  const r = await fetch(`${base}/api/me`, {
    method: 'PATCH', headers: authHeaders(token),
    body: JSON.stringify({ avatar: tooBig }),
  });
  assert.equal(r.status, 400);
});

test('PATCH /api/me 接受 >100kb 的 base64 头像（证明 json limit 已提到 2mb）', async () => {
  // 200kb 的 body：默认 express.json() 100kb 上限会直接 413
  const big = 'data:image/jpeg;base64,' + 'B'.repeat(200 * 1024);
  const r = await fetch(`${base}/api/me`, {
    method: 'PATCH', headers: authHeaders(token),
    body: JSON.stringify({ avatar: big }),
  });
  assert.equal(r.status, 200);
  const j = await (await fetch(`${base}/api/me`, { headers: authHeaders(token) })).json();
  assert.equal(j.avatar.length, big.length);
});

test('PATCH /api/me 空串头像=清空，可回落到默认渲染', async () => {
  const r = await fetch(`${base}/api/me`, {
    method: 'PATCH', headers: authHeaders(token),
    body: JSON.stringify({ avatar: '' }),
  });
  assert.equal(r.status, 200);
  const j = await (await fetch(`${base}/api/me`, { headers: authHeaders(token) })).json();
  assert.equal(j.avatar, '');
});

test('PATCH /api/me 无 token 返回 401', async () => {
  const r = await fetch(`${base}/api/me`, {
    method: 'PATCH', headers: JSON_HEADERS, body: JSON.stringify({ nickname: 'x' }),
  });
  assert.equal(r.status, 401);
});

// ---------- GET /api/stats ----------

// 造一个全新的空账号：直接落库 + 走真实 login（注册要验证码，这里不想引入探针）。
// 这样统计用例自带基线，不依赖文件内其它用例的先后顺序。
async function freshUserToken(username) {
  db.prepare('INSERT INTO users (username, password_hash) VALUES (?,?)')
    .run(username, bcrypt.hashSync('secret123-strong', 10));
  const r = await fetch(`${base}/api/auth/login`, {
    method: 'POST', headers: JSON_HEADERS,
    body: JSON.stringify({ username, password: 'secret123-strong' }),
  });
  assert.equal(r.status, 200, '新账号应能登录');
  return (await r.json()).token;
}

test('GET /api/stats 四个字段都是整数（空账号全 0）', async () => {
  const t = await freshUserToken('statszero');
  const r = await fetch(`${base}/api/stats`, { headers: authHeaders(t) });
  assert.equal(r.status, 200);
  const s = await r.json();
  for (const k of ['lists', 'todos', 'done', 'courses']) {
    assert.equal(typeof s[k], 'number', `${k} 应为 number`);
    assert.ok(Number.isInteger(s[k]), `${k} 应为整数`);
  }
  assert.deepEqual(s, { lists: 0, todos: 0, done: 0, courses: 0 });
});

test('GET /api/stats 反映真实数据（清单/待办/已完成/课程）', async () => {
  // 1 个清单
  const lr = await fetch(`${base}/api/lists`, {
    method: 'POST', headers: authHeaders(token), body: JSON.stringify({ name: '学习' }),
  });
  assert.equal(lr.status, 200);

  // 2 条收件箱待办，其中 1 条标记完成
  const t1 = await (await fetch(`${base}/api/inbox`, {
    method: 'POST', headers: authHeaders(token), body: JSON.stringify({ title: '写作业' }),
  })).json();
  await fetch(`${base}/api/inbox`, {
    method: 'POST', headers: authHeaders(token), body: JSON.stringify({ title: '背单词' }),
  });
  const pd = await fetch(`${base}/api/inbox/${t1.id}`, {
    method: 'PATCH', headers: authHeaders(token), body: JSON.stringify({ done: true }),
  });
  assert.equal(pd.status, 200);

  // 1 个时间块（未完成，也应计入 todos）
  await fetch(`${base}/api/blocks`, {
    method: 'POST', headers: authHeaders(token),
    body: JSON.stringify({ date: '2026-09-10', start_min: 600, end_min: 660, title: '复习' }),
  });

  // 课表含 2 门课
  const sched = {
    semester_start: '2026-08-31',
    courses: [
      { course_id: 'c1', name: '高数', slots: [] },
      { course_id: 'c2', name: '英语', slots: [] },
    ],
  };
  const ps = await fetch(`${base}/api/schedule`, {
    method: 'PUT', headers: authHeaders(token), body: JSON.stringify(sched),
  });
  assert.equal(ps.status, 200);

  const s = await (await fetch(`${base}/api/stats`, { headers: authHeaders(token) })).json();
  // Setup now creates five default lists, in addition to the custom list above.
  assert.deepEqual(s, { lists: 6, todos: 2, done: 1, courses: 2 });
});

test('GET /api/stats 只统计本人数据（别人 uid 的行不算进来）', async () => {
  // 自带账号 + 自带数据：本人 1 清单 / 1 待办 / 1 已完成
  const t = await freshUserToken('statsisolated');
  await fetch(`${base}/api/lists`, {
    method: 'POST', headers: authHeaders(t), body: JSON.stringify({ name: '我的清单' }),
  });
  const mine = await (await fetch(`${base}/api/inbox`, {
    method: 'POST', headers: authHeaders(t), body: JSON.stringify({ title: '我的待办' }),
  })).json();
  await fetch(`${base}/api/inbox`, {
    method: 'POST', headers: authHeaders(t), body: JSON.stringify({ title: '我的已完成' }),
  });
  await fetch(`${base}/api/inbox/${mine.id}`, {
    method: 'PATCH', headers: authHeaders(t), body: JSON.stringify({ done: true }),
  });

  // 另一个不存在用户的脏数据，统计必须按 user_id 隔离掉
  db.prepare('INSERT INTO inbox (user_id,title) VALUES (?,?)').run(99999, '别人的任务');
  db.prepare('INSERT INTO lists (user_id,name) VALUES (?,?)').run(99999, '别人的清单');
  db.prepare('INSERT INTO blocks (user_id,date,start_min,end_min,title,done) VALUES (?,?,?,?,?,1)')
    .run(99999, '2026-09-10', 0, 30, '别人的块');

  const s = await (await fetch(`${base}/api/stats`, { headers: authHeaders(t) })).json();
  assert.deepEqual(s, { lists: 1, todos: 1, done: 1, courses: 0 });
});

test('GET /api/stats 无 token 返回 401', async () => {
  const r = await fetch(`${base}/api/stats`);
  assert.equal(r.status, 401);
});

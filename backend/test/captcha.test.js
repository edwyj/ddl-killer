import {emailOptions,registerVerified} from './helpers/verified-registration.js';
import test from 'node:test';
import assert from 'node:assert/strict';

process.env.DB_PATH = ':memory:';
process.env.JWT_SECRET = 'test-secret';

// 探针：包一层真实的 svgCaptcha.create（仍走真实生成），顺便记下明文，
// 否则测试无法知道随机出来的 4 个字符，注册成功路径就测不了。
const svgCaptcha = (await import('svg-captcha')).default;
const realCreate = svgCaptcha.create;
let lastCode = null;
let lastOpts = null;
svgCaptcha.create = (opts) => {
  const cap = realCreate(opts);
  lastCode = cap.text;
  lastOpts = opts;
  return cap;
};

const { createApp } = await import('../src/app.js');
const { db } = await import('../src/db.js');

let app, server, base;
const JSON_HEADERS = { 'content-type': 'application/json' };

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

// 取一张验证码，返回 { id, code, opts }（code / opts 来自探针）
async function issueCaptcha() {
  lastCode = null;
  lastOpts = null;
  const r = await fetch(`${base}/api/auth/captcha`);
  assert.equal(r.status, 200);
  const j = await r.json();
  return { id: j.id, code: lastCode, opts: lastOpts, raw: j };
}

const register = body => registerVerified(app,base,body);

// ---------- GET /api/auth/captcha ----------

test('GET /api/auth/captcha 返回 {id, svg}，svg 是真实生成的 SVG 标记', async () => {
  const { id, code, raw } = await issueCaptcha();
  assert.equal(typeof id, 'string');
  assert.ok(id.length >= 16, 'id 应为 uuid 形态');
  assert.equal(typeof raw.svg, 'string');
  assert.ok(raw.svg.includes('<svg'), 'svg 应含 <svg 标记');
  assert.ok(raw.svg.includes('</svg>'), 'svg 应闭合');
  assert.ok(raw.svg.length > 200, 'svg 应有实际内容');
  assert.equal(typeof code, 'string', '探针应拿到真实生成的明文');
});

test('captcha 生成参数被精确固定（size/noise/color/background/ignoreChars）', async () => {
  const { opts } = await issueCaptcha();
  // 逐字段深比较：不看随机结果，直接钉住传给 svgCaptcha.create 的配置，
  // 这样删掉 size/noise/color/background/ignoreChars 中任何一个都会失败。
  assert.deepEqual(opts, {
    size: 4,
    noise: 2,
    color: true,
    background: '#f2f4f7',
    ignoreChars: '0o1il',
  });
});

test('每次请求返回不同的 id', async () => {
  const a = await issueCaptcha();
  const b = await issueCaptcha();
  assert.notEqual(a.id, b.id);
});

// ---------- register 验证码校验 ----------

test('register 缺 captcha_id / captcha_code → 400', async () => {
  const r = await register({ username: 'nope1', password: 'secret123-strong' });
  assert.equal(r.status, 400);
  assert.equal((await r.json()).error, '图形验证码错误或已过期');
});

test('register 用假 captcha_id → 400', async () => {
  const r = await register({
    username: 'nope2', password: 'secret123-strong',
    captcha_id: 'fake-id-not-in-store', captcha_code: 'abcd',
  });
  assert.equal(r.status, 400);
  assert.equal((await r.json()).error, '图形验证码错误或已过期');
});

test('register 验证码错误 → 400，且该码作废（不能拿同一 id 重试）', async () => {
  const { id, code } = await issueCaptcha();
  const wrong = await register({
    username: 'nope3', password: 'secret123-strong', captcha_id: id, captcha_code: 'zzzz',
  });
  assert.equal(wrong.status, 400);
  // 一次性：验证失败的 id 已被 delete，正确码也救不回来
  const retry = await register({
    username: 'nope3', password: 'secret123-strong', captcha_id: id, captcha_code: code,
  });
  assert.equal(retry.status, 400);
});

test('register 验证码正确 → 200 {ok, username}，可登录；同 id 复用 → 400', async () => {
  const { id, code } = await issueCaptcha();
  const ok = await register({
    username: 'capuser', password: 'secret123-strong', captcha_id: id, captcha_code: code,
  });
  assert.equal(ok.status, 200);
  assert.deepEqual(await ok.json(), { ok: true, username: 'capuser' });

  const login = await fetch(`${base}/api/auth/login`, {
    method: 'POST', headers: JSON_HEADERS,
    body: JSON.stringify({ username: 'capuser', password: 'secret123-strong' }),
  });
  assert.equal(login.status, 200);
  assert.ok((await login.json()).token);

  // 用后即焚：同一个 id 再来一次必须失败
  const replay = await register({
    username: 'capuser2', password: 'secret123-strong', captcha_id: id, captcha_code: code,
  });
  assert.equal(replay.status, 400);
});

test('register 验证码大小写不敏感、允许首尾空格', async () => {
  const { id, code } = await issueCaptcha();
  const r = await register({
    username: 'capuser3', password: 'secret123-strong',
    captcha_id: id, captcha_code: `  ${code.toUpperCase()}  `,
  });
  assert.equal(r.status, 200);
});

test('register 验证码通过后仍会拦截非法用户名/弱密码', async () => {
  const a = await issueCaptcha();
  const badName = await register({
    username: 'a', password: 'secret123-strong', captcha_id: a.id, captcha_code: a.code,
  });
  assert.equal(badName.status, 400);
  assert.match((await badName.json()).error, /用户名/);

  const b = await issueCaptcha();
  const weak = await register({
    username: 'weakpwd', password: '123', captcha_id: b.id, captcha_code: b.code,
  });
  assert.equal(weak.status, 400);
  assert.match((await weak.json()).error, /密码/);
});

test('register 重名（带合法验证码）→ 409', async () => {
  const { id, code } = await issueCaptcha();
  const r = await register({
    username: 'capuser', password: 'secret123-strong', captcha_id: id, captcha_code: code,
  });
  assert.equal(r.status, 409);
});

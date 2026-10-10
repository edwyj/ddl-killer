import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';

const sentinel = 'sk-SENTINEL-MONEY-SECRET';
const dbPath = path.join(tmpdir(), `ddl-killer-ai-leak-${process.pid}.db`);
process.env.DB_PATH = dbPath;
process.env.JWT_SECRET = 'ai-leak-test-jwt-secret-at-least-32-chars';
process.env.AI_KEY_ENCRYPTION_KEYS = `v1:${randomBytes(32).toString('base64')}`;
process.env.AI_FEATURE_ENABLED = 'true';
process.env.AI_HOSTED_ENABLED = 'false';

const logs = [];
const originalLog = console.log;
const originalError = console.error;
console.log = (...args) => logs.push(args.map(String).join(' '));
console.error = (...args) => logs.push(args.map(String).join(' '));

const { db } = await import('../src/db.js');
const { createApp } = await import('../src/app.js');
const { createUserWithDefaultLists } = await import('../src/default-lists.js');
const { saveTask } = await import('../src/task-planning.js');
const bcrypt = (await import('bcryptjs')).default;
const password = 'AI-leak-password-123';
const uid = createUserWithDefaultLists('ai_leak_owner', bcrypt.hashSync(password, 10));
const task = saveTask(uid, null, { title: '安全测试任务', estimate_minutes: 60 });
let failGeneration = false;
const generate = async ({ schema }) => {
  if (failGeneration) throw Object.assign(new Error(`upstream echoed ${sentinel}`), { code: 'AI_PROVIDER_TIMEOUT' });
  if (schema.name === 'connection_test') return { value: { ok: true }, usage: {} };
  const date = new Date();
  date.setUTCDate(date.getUTCDate() + 1);
  return {
    value: {
      summary: '安全测试',
      changes: [{
        op: 'schedule_task', taskId: task.id,
        date: date.toISOString().slice(0, 10), start: 600, end: 660,
      }],
      questions: [], warnings: [],
    },
    usage: { promptTokens: 1, completionTokens: 1 },
  };
};
const app = createApp({ ai: {
  resolver: async () => [{ address: '93.184.216.34', family: 4 }],
  generate,
} });
const server = app.listen(0, '127.0.0.1');
await new Promise((resolve) => server.once('listening', resolve));
const base = `http://127.0.0.1:${server.address().port}`;

const bodies = [];
async function call(route, method = 'GET', body, token) {
  const response = await fetch(base + route, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await response.text();
  bodies.push(text);
  return { status: response.status, data: JSON.parse(text) };
}

test.after(() => {
  console.log = originalLog;
  console.error = originalError;
  server.close();
  db.close();
  rmSync(dbPath, { force: true });
});

test('sentinel key never appears in responses, logs, audit, export or sqlite bytes', async () => {
  const token = (await call('/api/auth/login', 'POST', {
    username: 'ai_leak_owner', password,
  })).data.token;
  assert.equal((await call('/api/ai/provider', 'PUT', {
    provider: 'custom', base_url: 'https://api.example.com/v1',
    model: 'planner', key: sentinel,
  }, token)).status, 200);
  assert.equal((await call('/api/ai/provider/test', 'POST', {}, token)).status, 200);
  await call('/api/ai/settings', 'PATCH', { mode: 'byok' }, token);

  const start = new Date();
  const end = new Date();
  end.setUTCDate(end.getUTCDate() + 3);
  const date = (value) => value.toISOString().slice(0, 10);
  assert.equal((await call('/api/ai/sessions', 'POST', {
    message: '安排任务', startDate: date(start), endDate: date(end),
  }, token)).status, 201);
  failGeneration = true;
  const failed = await call('/api/ai/sessions', 'POST', {
    message: '触发安全错误', startDate: date(start), endDate: date(end),
  }, token);
  assert.equal(failed.status, 502);
  assert.equal(failed.data.code, 'AI_PROVIDER_UNAVAILABLE');
  const exported = await call('/api/account/export', 'POST', { password }, token);
  assert.equal(exported.status, 200);

  const observable = JSON.stringify({ bodies, logs,
    audit: db.prepare('SELECT * FROM ai_audit_log WHERE user_id=?').all(uid),
    exported: exported.data,
  });
  assert.equal(observable.includes(sentinel), false);
  assert.equal(readFileSync(dbPath).includes(Buffer.from(sentinel)), false);

  assert.equal((await call('/api/ai/provider', 'DELETE', {}, token)).status, 200);
  assert.equal((await call('/api/ai/provider', 'GET', null, token)).status, 404);
  assert.equal(JSON.stringify({ bodies, logs }).includes(sentinel), false);
});

test('enabled AI fails closed when required secret configuration is absent', () => {
  const ring = process.env.AI_KEY_ENCRYPTION_KEYS;
  delete process.env.AI_KEY_ENCRYPTION_KEYS;
  assert.throws(() => createApp(), /AI_KEY_ENCRYPTION_KEYS/);
  process.env.AI_KEY_ENCRYPTION_KEYS = ring;
});

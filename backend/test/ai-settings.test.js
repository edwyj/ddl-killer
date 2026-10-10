import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import test from 'node:test';

process.env.DB_PATH = ':memory:';
process.env.JWT_SECRET = 'ai-settings-test-secret-32-characters';
process.env.AI_KEY_ENCRYPTION_KEYS = `v1:${randomBytes(32).toString('base64')}`;

const generated = [];
const resolver = async () => [{ address: '93.184.216.34', family: 4 }];
const { createApp } = await import('../src/app.js');
const { db } = await import('../src/db.js');
const { createUserWithDefaultLists } = await import('../src/default-lists.js');
const bcrypt = (await import('bcryptjs')).default;

const users = [
  ['ai_owner', 'AI-owner-password-123'],
  ['ai_other', 'AI-other-password-123'],
  ['ai_stale', 'AI-stale-password-123'],
  ['ai_limited', 'AI-limited-password-123'],
];
const ids = new Map(users.map(([name, password]) => [
  name,
  createUserWithDefaultLists(name, bcrypt.hashSync(password, 10)),
]));

const app = createApp({
  ai: {
    resolver,
    generate: async (args) => {
      generated.push(args);
      return { value: { ok: true }, usage: { promptTokens: 1, completionTokens: 1 } };
    },
  },
});
const server = app.listen(0, '127.0.0.1');
await new Promise((resolve) => server.once('listening', resolve));
test.after(() => { server.close(); db.close(); });
const base = `http://127.0.0.1:${server.address().port}`;

async function call(path, method = 'GET', body, token) {
  const response = await fetch(base + path, {
    method,
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  return { status: response.status, data: await response.json() };
}

async function login(username, password) {
  return (await call('/api/auth/login', 'POST', { username, password })).data.token;
}

const provider = (key, password) => ({
  provider: 'deepseek',
  base_url: 'https://api.deepseek.com/v1',
  model: 'deepseek-chat',
  key,
  ...(password ? { password } : {}),
});

test('provider API is isolated and never returns key material', async () => {
  const owner = await login(...users[0]);
  const other = await login(...users[1]);
  const sentinel = 'sk-sentinel-money-bearing-secret';
  assert.equal((await call('/api/ai/provider', 'PUT', provider(sentinel), owner)).status, 200);
  assert.equal((await call('/api/ai/provider', 'PUT', provider('sk-other-secret'), other)).status, 200);

  const shown = await call('/api/ai/provider', 'GET', null, owner);
  assert.equal(shown.status, 200);
  assert.deepEqual(Object.keys(shown.data).sort(), [
    'baseUrl', 'keyMask', 'model', 'provider', 'updatedAt',
  ]);
  assert.equal(shown.data.keyMask, 'sk-s••••cret');
  assert.doesNotMatch(JSON.stringify(shown), /sentinel-money-bearing/);
  assert.equal((await call('/api/ai/provider', 'DELETE', {}, other)).status, 200);
  assert.equal((await call('/api/ai/provider', 'GET', null, owner)).status, 200);
  assert.equal((await call('/api/ai/provider', 'DELETE', {}, other)).status, 200);
});

test('stale sessions require the account password and reject a wrong password', async () => {
  const token = await login(...users[2]);
  db.prepare('UPDATE sessions SET created_at=? WHERE user_id=?')
    .run(Date.now() - 11 * 60 * 1000, ids.get('ai_stale'));
  assert.equal((await call('/api/ai/provider', 'PUT', provider('sk-stale'), token)).status, 401);
  assert.equal((await call('/api/ai/provider', 'PUT', provider('sk-stale', 'wrong'), token)).status, 401);
  assert.equal((await call(
    '/api/ai/provider',
    'PUT',
    provider('sk-stale', 'AI-stale-password-123'),
    token,
  )).status, 200);
});

test('invalid custom destinations are rejected before a key is stored', async () => {
  const token = await login(...users[0]);
  const response = await call('/api/ai/provider', 'PUT', {
    provider: 'custom',
    base_url: 'https://127.0.0.1/v1',
    model: 'private-model',
    key: 'sk-never-store-this',
  }, token);
  assert.equal(response.status, 400);
  assert.equal(response.data.code, 'AI_PROVIDER_URL_INVALID');
  assert.doesNotMatch(JSON.stringify(response), /never-store-this/);
});

test('provider test sends only a fixed probe and AI mode can be changed', async () => {
  const token = await login(...users[0]);
  const result = await call('/api/ai/provider/test', 'POST', {}, token);
  assert.equal(result.status, 200);
  assert.equal(generated.length, 1);
  assert.equal(generated[0].maxTokens, 8);
  assert.deepEqual(generated[0].messages, [{ role: 'user', content: 'Return only {"ok":true}.' }]);
  assert.doesNotMatch(JSON.stringify(generated[0].messages), /任务|课表|规划/);

  assert.deepEqual((await call('/api/ai/settings', 'GET', null, token)).data, {
    mode: 'hosted', featureEnabled: false,
  });
  assert.deepEqual((await call('/api/ai/settings', 'PATCH', { mode: 'byok' }, token)).data, { mode: 'byok' });
});

test('provider mutations are rate limited per account', async () => {
  const token = await login(...users[3]);
  let result;
  for (let i = 0; i < 9; i += 1) {
    result = await call('/api/ai/provider', 'DELETE', {}, token);
  }
  assert.equal(result.status, 429);
});

test('account deletion removes provider and all present AI-owned rows', async () => {
  const username = 'ai_delete';
  const password = 'AI-delete-password-123';
  const uid = createUserWithDefaultLists(username, bcrypt.hashSync(password, 10));
  const token = await login(username, password);
  await call('/api/ai/provider', 'PUT', provider('sk-delete-sentinel'), token);
  const now = Date.now();
  db.prepare(`INSERT INTO ai_planning_sessions(
    id,user_id,mode,start_date,end_date,status,created_at,updated_at,expires_at
  ) VALUES(?,?,'hosted','2026-09-27','2026-09-28','active',?,?,?)`)
    .run('delete-session', uid, now, now, now + 1800000);
  db.prepare(`INSERT INTO ai_planning_turns(
    id,session_id,user_id,input_text,proposal_json,draft_id,created_at
  ) VALUES(?,?,?,?,?,?,?)`).run(
    'delete-turn', 'delete-session', uid, '安排', '{}', 'delete-draft', now,
  );
  db.prepare(`INSERT INTO ai_audit_log(
    user_id,session_id,mode,result_code,latency_ms,prompt_tokens,completion_tokens,created_at
  ) VALUES(?,?,'hosted','OK',1,1,1,?)`).run(uid, 'delete-session', now);
  db.prepare(`INSERT INTO ai_quota_daily(user_id,quota_date,used,reserved,updated_at)
    VALUES(?,?,?,?,?)`).run(uid, '2026-09-27', 1, 0, Date.now());
  db.prepare(`INSERT INTO ai_quota_reservations(
    id,user_id,quota_date,state,created_at,updated_at
  ) VALUES(?,?,?,'consumed',?,?)`).run('delete-reservation', uid, '2026-09-27', now, now);

  assert.equal((await call('/api/account', 'DELETE', {
    password,
    confirmation: '删除我的账号',
  }, token)).status, 200);
  for (const table of [
    'ai_provider_configs', 'ai_planning_sessions', 'ai_planning_turns',
    'ai_quota_reservations', 'ai_quota_daily', 'ai_audit_log',
  ]) {
    assert.equal(db.prepare(`SELECT count(*) n FROM ${table} WHERE user_id=?`).get(uid).n, 0, table);
  }
});

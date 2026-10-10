import test from 'node:test';
import assert from 'node:assert/strict';

process.env.DB_PATH = ':memory:';
process.env.JWT_SECRET = 'mcp-test-jwt-secret-at-least-32-characters';
process.env.MCP_TOKEN_PEPPER = 'mcp-test-pepper-at-least-32-characters';

const {db} = await import('../src/db.js');
const {createUserWithDefaultLists} = await import('../src/default-lists.js');
const bcrypt = (await import('bcryptjs')).default;
const {
  createPat,
  verifyMcpCredential,
  revokeClient,
  listClients,
} = await import('../src/mcp-credentials.js');

const ownerPassword = 'Mcp-owner-password-123';
const uid = createUserWithDefaultLists('mcp_owner', bcrypt.hashSync(ownerPassword, 4));
createUserWithDefaultLists('mcp_other', bcrypt.hashSync('Mcp-other-password-123', 4));
const future = new Date(Date.now() + 30 * 86400000).toISOString();

test.after(() => db.close());

test('PAT plaintext is returned once and only a peppered hash is stored', () => {
  const created = createPat({
    userId: uid,
    name: 'Claude',
    scopes: ['mcp:read'],
    expiresAt: future,
  });
  assert.match(created.token, /^ddl_mcp_[A-Za-z0-9_-]+$/);
  const client = db.prepare('SELECT * FROM mcp_clients WHERE id=?').get(created.client.id);
  const credential = db.prepare('SELECT * FROM mcp_credentials WHERE client_id=?').get(created.client.id);
  assert.equal(JSON.stringify({client, credential}).includes(created.token), false);
  assert.equal(credential.secret_hash.length, 64);
  assert.equal(verifyMcpCredential(created.token).principal.userId, uid);
  assert.equal(listClients(uid)[0].tokenPrefix, created.token.slice(0, 16));
});

test('invalid scope combinations and permanent expiry are rejected', () => {
  assert.throws(
    () => createPat({userId: uid, name: 'bad', scopes: ['mcp:schedule:apply'], expiresAt: future}),
    /scope/i,
  );
  assert.throws(
    () => createPat({userId: uid, name: 'never', scopes: ['mcp:read'], expiresAt: null}),
    /expires/i,
  );
});

test('only ten active clients are allowed and revocation is immediate', () => {
  const made = [];
  for (let i = listClients(uid).length; i < 10; i++) {
    made.push(createPat({userId: uid, name: `client-${i}`, scopes: ['mcp:read'], expiresAt: future}));
  }
  assert.throws(
    () => createPat({userId: uid, name: 'eleventh', scopes: ['mcp:read'], expiresAt: future}),
    /active client limit/i,
  );
  const target = made.at(-1);
  assert.equal(revokeClient(uid, target.client.id), true);
  assert.equal(verifyMcpCredential(target.token), null);
  assert.equal(revokeClient(uid, target.client.id), false);
});

test('owner creates, lists and revokes a PAT while another user cannot see it', async () => {
  const {createApp} = await import('../src/app.js');
  const server = createApp().listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = async (path, method = 'GET', body, token) => {
    const response = await fetch(base + path, {
      method,
      headers: {'content-type': 'application/json', ...(token ? {authorization: `Bearer ${token}`} : {})},
      ...(body ? {body: JSON.stringify(body)} : {}),
    });
    return {status: response.status, data: await response.json()};
  };
  try {
    const owner = (await call('/api/auth/login', 'POST', {username: 'mcp_owner', password: ownerPassword})).data.token;
    const other = (await call('/api/auth/login', 'POST', {username: 'mcp_other', password: 'Mcp-other-password-123'})).data.token;
    const made = await call('/api/mcp/clients', 'POST', {
      name: 'Codex', preset: 'planning', expires_at: future, password: ownerPassword,
    }, owner);
    assert.equal(made.status, 201);
    assert.match(made.data.token, /^ddl_mcp_/);
    assert.deepEqual(made.data.client.scopes, [
      'mcp:read', 'mcp:tasks:write', 'mcp:schedule:draft', 'mcp:schedule:apply',
    ]);
    assert.equal((await call('/api/mcp/clients', 'GET', null, other)).data.length, 0);
    assert.equal((await call('/api/mcp/clients', 'POST', {
      name: 'wrong password', preset: 'readonly', expires_at: future, password: 'incorrect-password',
    }, owner)).status, 401);
    db.prepare(`INSERT INTO mcp_audit_log
      (user_id,client_id,tool_name,result_code,object_ids_json,request_id,created_at)
      VALUES (?,?,?,?,?,?,?)`).run(uid, made.data.client.id, 'plan_add_task', 'OK', '[7]', 'req-1', new Date().toISOString());
    const audit = await call('/api/mcp/audit', 'GET', null, owner);
    assert.equal(audit.status, 200);
    assert.deepEqual(audit.data[0].objectIds, [7]);
    assert.equal(JSON.stringify(audit.data).includes(made.data.token), false);
    assert.equal((await call('/api/me', 'GET', null, made.data.token)).status, 401);
    const exchanged = await call('/api/internal/mcp/exchange', 'POST', null, made.data.token);
    assert.equal(exchanged.status, 200);
    assert.equal(exchanged.data.principal.userId, uid);
    assert.equal((await call('/api/me', 'GET', null, exchanged.data.token)).status, 200);
    assert.equal((await call(`/api/mcp/clients/${made.data.client.id}`, 'DELETE', {password: ownerPassword}, owner)).status, 200);
    assert.equal(verifyMcpCredential(made.data.token), null);
    assert.equal((await call('/api/internal/mcp/exchange', 'POST', null, made.data.token)).status, 401);
  } finally {
    server.close();
  }
});

import assert from 'node:assert/strict';
import { readFileSync, rmSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';

const dbPath = path.join(tmpdir(), `ddl-killer-ai-credentials-${process.pid}.db`);
process.env.DB_PATH = dbPath;
const v1 = randomBytes(32).toString('base64');
const v2 = randomBytes(32).toString('base64');
process.env.AI_KEY_ENCRYPTION_KEYS = `v1:${v1}`;

const { db } = await import('../src/db.js');
const credentials = await import('../src/ai-credentials.js');

db.prepare('INSERT INTO users(id,username,password_hash) VALUES(?,?,?)')
  .run(7, 'ai-key-owner', 'test-only');

test.after(() => {
  db.close();
  rmSync(dbPath, { force: true });
});

test('provider key is authenticated, user-bound and absent from sqlite bytes', () => {
  const secret = 'sk-money-bearing-test-value';
  const saved = credentials.saveProviderConfig(7, {
    provider: 'custom',
    baseUrl: 'https://api.example.com/v1',
    model: 'planner',
    key: secret,
  });

  assert.equal(credentials.loadProviderKey(7), secret);
  assert.equal(credentials.getProviderConfig(7).keyMask, 'sk-m••••alue');
  assert.throws(
    () => credentials.decryptProviderKey({ ...saved, user_id: 8 }),
    /AI_KEY_DECRYPT_FAILED/,
  );
  assert.equal(readFileSync(dbPath).includes(Buffer.from(secret)), false);
});

test('every encryption uses a unique nonce and tampering fails', () => {
  const input = {
    recordId: 'same-record',
    userId: 7,
    provider: 'deepseek',
    key: 'sk-another-money-bearing-value',
  };
  const a = credentials.encryptProviderKey(input);
  const b = credentials.encryptProviderKey(input);
  assert.notEqual(a.nonce, b.nonce);

  const changed = Buffer.from(a.ciphertext, 'base64');
  changed[0] ^= 1;
  assert.throws(
    () => credentials.decryptProviderKey({
      ...a,
      id: input.recordId,
      user_id: input.userId,
      provider: input.provider,
      ciphertext: changed.toString('base64'),
    }),
    /AI_KEY_DECRYPT_FAILED/,
  );
});

test('key versions rotate row-by-row without exposing plaintext', () => {
  process.env.AI_KEY_ENCRYPTION_KEYS = `v2:${v2},v1:${v1}`;
  assert.equal(credentials.rotateProviderKeys(), 1);
  const row = db.prepare('SELECT * FROM ai_provider_configs WHERE user_id=?').get(7);
  assert.equal(row.key_version, 'v2');
  assert.equal(credentials.loadProviderKey(7), 'sk-money-bearing-test-value');

  process.env.AI_KEY_ENCRYPTION_KEYS = `v2:${v2}`;
  assert.doesNotThrow(() => credentials.validateProviderCredentialState());

  db.prepare('UPDATE ai_provider_configs SET key_version=? WHERE user_id=?').run('v1', 7);
  assert.throws(
    () => credentials.validateProviderCredentialState(),
    /AI_KEY_VERSION_UNAVAILABLE/,
  );
});

test('malformed, duplicated and non-32-byte key rings are rejected', () => {
  for (const value of [
    '',
    'broken',
    `v1:${randomBytes(16).toString('base64')}`,
    `v1:${v1},v1:${v2}`,
  ]) {
    process.env.AI_KEY_ENCRYPTION_KEYS = value;
    assert.throws(() => credentials.validateProviderCredentialState());
  }
});

test('provider config deletion removes ciphertext and load access', () => {
  process.env.AI_KEY_ENCRYPTION_KEYS = `v2:${v2},v1:${v1}`;
  credentials.deleteProviderConfig(7);
  assert.equal(credentials.getProviderConfig(7), null);
  assert.throws(() => credentials.loadProviderKey(7), /AI_PROVIDER_NOT_CONFIGURED/);
});

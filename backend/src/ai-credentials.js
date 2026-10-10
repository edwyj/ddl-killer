import {
  createCipheriv,
  createDecipheriv,
  randomBytes,
  randomUUID,
} from 'node:crypto';

import { db } from './db.js';

const KEY_BYTES = 32;
const NONCE_BYTES = 12;

function credentialError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

function parseKeyRing(raw = process.env.AI_KEY_ENCRYPTION_KEYS) {
  if (!raw?.trim()) throw credentialError('AI_KEY_RING_INVALID');
  const ring = new Map();
  const fingerprints = new Set();
  for (const entry of raw.split(',')) {
    const separator = entry.indexOf(':');
    if (separator < 1) throw credentialError('AI_KEY_RING_INVALID');
    const version = entry.slice(0, separator).trim();
    const encoded = entry.slice(separator + 1).trim();
    if (!/^[A-Za-z0-9._-]+$/.test(version) || ring.has(version)) {
      throw credentialError('AI_KEY_RING_INVALID');
    }
    const key = Buffer.from(encoded, 'base64');
    if (key.length !== KEY_BYTES || key.toString('base64') !== encoded) {
      key.fill(0);
      throw credentialError('AI_KEY_RING_INVALID');
    }
    const fingerprint = key.toString('hex');
    if (fingerprints.has(fingerprint)) {
      key.fill(0);
      throw credentialError('AI_KEY_RING_INVALID');
    }
    fingerprints.add(fingerprint);
    ring.set(version, key);
  }
  return ring;
}

function disposeKeyRing(ring) {
  for (const key of ring.values()) key.fill(0);
}

function aadFor({ id, user_id: userId, provider, created_at: createdAt, key_version: keyVersion }) {
  return Buffer.from(`${id}:${userId}:${provider}:${createdAt}:${keyVersion}`, 'utf8');
}

export function encryptProviderKey({ recordId, userId, provider, key, createdAt = new Date().toISOString() }) {
  const ring = parseKeyRing();
  try {
    const [keyVersion, encryptionKey] = ring.entries().next().value;
    const nonce = randomBytes(NONCE_BYTES);
    const cipher = createCipheriv('aes-256-gcm', encryptionKey, nonce);
    cipher.setAAD(aadFor({
      id: recordId,
      user_id: userId,
      provider,
      created_at: createdAt,
      key_version: keyVersion,
    }));
    const ciphertext = Buffer.concat([
      cipher.update(String(key), 'utf8'),
      cipher.final(),
    ]);
    return {
      key_version: keyVersion,
      created_at: createdAt,
      nonce: nonce.toString('base64'),
      ciphertext: ciphertext.toString('base64'),
      auth_tag: cipher.getAuthTag().toString('base64'),
    };
  } finally {
    disposeKeyRing(ring);
  }
}

export function decryptProviderKey(row) {
  let ring;
  try {
    ring = parseKeyRing();
    const key = ring.get(row.key_version);
    if (!key) throw credentialError('AI_KEY_VERSION_UNAVAILABLE');
    const nonce = Buffer.from(row.nonce, 'base64');
    const authTag = Buffer.from(row.auth_tag, 'base64');
    if (nonce.length !== NONCE_BYTES || authTag.length !== 16) {
      throw credentialError('AI_KEY_DECRYPT_FAILED');
    }
    const decipher = createDecipheriv('aes-256-gcm', key, nonce);
    decipher.setAAD(aadFor(row));
    decipher.setAuthTag(authTag);
    return Buffer.concat([
      decipher.update(Buffer.from(row.ciphertext, 'base64')),
      decipher.final(),
    ]).toString('utf8');
  } catch (error) {
    if (error?.code === 'AI_KEY_VERSION_UNAVAILABLE') throw error;
    throw credentialError('AI_KEY_DECRYPT_FAILED');
  } finally {
    if (ring) disposeKeyRing(ring);
  }
}

export function maskProviderKey(key) {
  const value = String(key);
  if (value.length <= 8) return '••••';
  return `${value.slice(0, 4)}••••${value.slice(-4)}`;
}

export function saveProviderConfig(userId, config) {
  const existing = db.prepare(
    'SELECT id,created_at FROM ai_provider_configs WHERE user_id=?',
  ).get(userId);
  const id = existing?.id ?? randomUUID();
  const now = new Date().toISOString();
  const createdAt = existing?.created_at ?? now;
  const encrypted = encryptProviderKey({
    recordId: id,
    userId,
    provider: config.provider,
    key: config.key,
    createdAt,
  });
  const row = {
    id,
    user_id: userId,
    provider: config.provider,
    base_url: config.baseUrl,
    model: config.model,
    ...encrypted,
    key_mask: maskProviderKey(config.key),
    created_at: createdAt,
    updated_at: now,
  };
  db.prepare(`INSERT INTO ai_provider_configs(
      id,user_id,provider,base_url,model,key_version,nonce,ciphertext,auth_tag,key_mask,created_at,updated_at
    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(user_id) DO UPDATE SET
      provider=excluded.provider,base_url=excluded.base_url,model=excluded.model,
      key_version=excluded.key_version,nonce=excluded.nonce,ciphertext=excluded.ciphertext,
      auth_tag=excluded.auth_tag,key_mask=excluded.key_mask,updated_at=excluded.updated_at`)
    .run(
      row.id, row.user_id, row.provider, row.base_url, row.model,
      row.key_version, row.nonce, row.ciphertext, row.auth_tag, row.key_mask,
      row.created_at, row.updated_at,
    );
  return row;
}

export function getProviderConfig(userId) {
  const row = db.prepare(
    'SELECT provider,base_url,model,key_mask,updated_at FROM ai_provider_configs WHERE user_id=?',
  ).get(userId);
  if (!row) return null;
  return {
    provider: row.provider,
    baseUrl: row.base_url,
    model: row.model,
    keyMask: row.key_mask,
    hasKey: true,
    updatedAt: row.updated_at,
  };
}

export function loadProviderKey(userId) {
  const row = db.prepare('SELECT * FROM ai_provider_configs WHERE user_id=?').get(userId);
  if (!row) throw credentialError('AI_PROVIDER_NOT_CONFIGURED');
  return decryptProviderKey(row);
}

export function deleteProviderConfig(userId) {
  return db.prepare('DELETE FROM ai_provider_configs WHERE user_id=?').run(userId).changes > 0;
}

export function validateProviderCredentialState() {
  const ring = parseKeyRing();
  try {
    for (const row of db.prepare(
      'SELECT DISTINCT key_version FROM ai_provider_configs',
    ).all()) {
      if (!ring.has(row.key_version)) {
        throw credentialError('AI_KEY_VERSION_UNAVAILABLE');
      }
    }
  } finally {
    disposeKeyRing(ring);
  }
}

export function rotateProviderKeys() {
  const ring = parseKeyRing();
  const currentVersion = ring.keys().next().value;
  disposeKeyRing(ring);
  const rows = db.prepare('SELECT * FROM ai_provider_configs WHERE key_version<>?').all(currentVersion);
  let changed = 0;
  db.exec('BEGIN IMMEDIATE');
  try {
    for (const row of rows) {
      const plaintext = decryptProviderKey(row);
      const encrypted = encryptProviderKey({
        recordId: row.id,
        userId: row.user_id,
        provider: row.provider,
        key: plaintext,
        createdAt: row.created_at,
      });
      db.prepare(`UPDATE ai_provider_configs SET
        key_version=?,nonce=?,ciphertext=?,auth_tag=?,updated_at=? WHERE id=?`)
        .run(
          encrypted.key_version,
          encrypted.nonce,
          encrypted.ciphertext,
          encrypted.auth_tag,
          new Date().toISOString(),
          row.id,
        );
      const updated = db.prepare('SELECT * FROM ai_provider_configs WHERE id=?').get(row.id);
      if (decryptProviderKey(updated) !== plaintext) {
        throw credentialError('AI_KEY_ROTATION_FAILED');
      }
      changed += 1;
    }
    db.exec('COMMIT');
    return changed;
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
}

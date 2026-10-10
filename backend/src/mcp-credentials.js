import {createHash, createHmac, randomBytes, randomUUID} from 'node:crypto';
import {db} from './db.js';

const configuredPepper = process.env.MCP_TOKEN_PEPPER;
const pepper = configuredPepper || (process.env.NODE_ENV !== 'production' && process.env.JWT_SECRET
  ? createHash('sha256').update(`ddl-killer-mcp:${process.env.JWT_SECRET}`).digest('hex')
  : null);
if (!pepper || (configuredPepper && configuredPepper.length < 32)) {
  throw new Error('MCP_TOKEN_PEPPER must be configured with at least 32 characters');
}

export const MCP_SCOPES = Object.freeze([
  'mcp:read',
  'mcp:tasks:write',
  'mcp:schedule:draft',
  'mcp:schedule:apply',
  'mcp:delete',
  'mcp:purge',
]);

const dependencyMap = Object.freeze({
  'mcp:tasks:write': ['mcp:read'],
  'mcp:schedule:draft': ['mcp:read'],
  'mcp:schedule:apply': ['mcp:read', 'mcp:schedule:draft'],
  'mcp:delete': ['mcp:read'],
  'mcp:purge': ['mcp:read', 'mcp:delete'],
});

export function normalizeScopes(scopes) {
  if (!Array.isArray(scopes) || scopes.length === 0) throw new Error('scope list is required');
  const unique = new Set(scopes);
  if (unique.size !== scopes.length || [...unique].some((scope) => !MCP_SCOPES.includes(scope))) {
    throw new Error('scope list contains duplicates or unknown scope');
  }
  for (const scope of unique) {
    for (const dependency of dependencyMap[scope] ?? []) {
      if (!unique.has(dependency)) throw new Error(`scope ${scope} requires ${dependency}`);
    }
  }
  return MCP_SCOPES.filter((scope) => unique.has(scope));
}

export function credentialDigest(raw) {
  if (typeof raw !== 'string' || raw.length < 32) return null;
  return createHmac('sha256', pepper).update(raw).digest('hex');
}

function isoNow() {
  return new Date().toISOString();
}

function validateExpiry(value) {
  if (typeof value !== 'string' || !value) throw new Error('expiresAt is required');
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp) || timestamp <= Date.now()) throw new Error('expiresAt must be in the future');
  return new Date(timestamp).toISOString();
}

function publicClient(row) {
  return {
    id: row.id,
    name: row.name,
    clientType: row.client_type,
    scopes: JSON.parse(row.scopes_json),
    tokenPrefix: row.token_prefix ?? null,
    expiresAt: row.expires_at,
    lastUsedAt: row.last_used_at,
    revokedAt: row.revoked_at,
    createdAt: row.created_at,
  };
}

export function createPat({userId, name, scopes, expiresAt}) {
  if (!Number.isSafeInteger(userId) || userId <= 0) throw new Error('userId is invalid');
  const trimmedName = typeof name === 'string' ? name.trim() : '';
  if (!trimmedName || trimmedName.length > 80) throw new Error('name must contain 1-80 characters');
  const normalizedScopes = normalizeScopes(scopes);
  const normalizedExpiry = validateExpiry(expiresAt);
  const active = db.prepare(`SELECT count(*) count FROM mcp_clients
    WHERE user_id=? AND revoked_at IS NULL AND expires_at>?`).get(userId, isoNow()).count;
  if (active >= 10) throw new Error('active client limit is 10');

  const now = isoNow();
  const clientId = randomUUID();
  const credentialId = randomUUID();
  const token = `ddl_mcp_${randomBytes(32).toString('base64url')}`;
  const prefix = token.slice(0, 16);
  db.exec('SAVEPOINT create_mcp_pat');
  try {
    db.prepare(`INSERT INTO mcp_clients
      (id,user_id,name,client_type,scopes_json,expires_at,created_at)
      VALUES (?,?,?,?,?,?,?)`).run(
      clientId, userId, trimmedName, 'pat', JSON.stringify(normalizedScopes), normalizedExpiry, now,
    );
    db.prepare(`INSERT INTO mcp_credentials
      (id,client_id,kind,token_prefix,secret_hash,expires_at,created_at)
      VALUES (?,?,?,?,?,?,?)`).run(
      credentialId, clientId, 'pat', prefix, credentialDigest(token), normalizedExpiry, now,
    );
    db.exec('RELEASE create_mcp_pat');
  } catch (error) {
    db.exec('ROLLBACK TO create_mcp_pat; RELEASE create_mcp_pat');
    throw error;
  }
  return {
    token,
    client: publicClient({
      id: clientId,
      name: trimmedName,
      client_type: 'pat',
      scopes_json: JSON.stringify(normalizedScopes),
      token_prefix: prefix,
      expires_at: normalizedExpiry,
      last_used_at: null,
      revoked_at: null,
      created_at: now,
    }),
  };
}

export function verifyMcpCredential(raw) {
  const digest = credentialDigest(raw);
  if (!digest) return null;
  const now = isoNow();
  const row = db.prepare(`SELECT c.*,k.id credential_id,k.kind,k.token_prefix
    FROM mcp_credentials k JOIN mcp_clients c ON c.id=k.client_id
    LEFT JOIN mcp_registered_clients r ON r.id=c.oauth_registered_client_id
    WHERE k.secret_hash=? AND k.kind IN ('pat','oauth_access') AND k.revoked_at IS NULL AND c.revoked_at IS NULL
      AND (c.client_type!='oauth' OR r.disabled_at IS NULL)
      AND k.expires_at>? AND c.expires_at>?`).get(digest, now, now);
  if (!row) return null;
  db.prepare('UPDATE mcp_clients SET last_used_at=? WHERE id=?').run(now, row.id);
  return {
    principal: {
      userId: row.user_id,
      clientId: row.id,
      clientName: row.name,
      scopes: JSON.parse(row.scopes_json),
      expiresAt: row.expires_at,
    },
    credentialRow: {
      id: row.credential_id,
      kind: row.kind,
      tokenPrefix: row.token_prefix,
    },
  };
}

export function revokeClient(userId, id) {
  const row = db.prepare(`SELECT id FROM mcp_clients
    WHERE id=? AND user_id=? AND revoked_at IS NULL`).get(id, userId);
  if (!row) return false;
  const now = isoNow();
  db.exec('SAVEPOINT revoke_mcp_client');
  try {
    db.prepare('UPDATE mcp_clients SET revoked_at=? WHERE id=?').run(now, id);
    db.prepare('UPDATE mcp_credentials SET revoked_at=? WHERE client_id=? AND revoked_at IS NULL').run(now, id);
    db.exec('RELEASE revoke_mcp_client');
    return true;
  } catch (error) {
    db.exec('ROLLBACK TO revoke_mcp_client; RELEASE revoke_mcp_client');
    throw error;
  }
}

export function listClients(userId) {
  return db.prepare(`SELECT c.*,
      (SELECT token_prefix FROM mcp_credentials k WHERE k.client_id=c.id ORDER BY k.created_at LIMIT 1) token_prefix
    FROM mcp_clients c WHERE c.user_id=? ORDER BY c.created_at DESC`).all(userId).map(publicClient);
}

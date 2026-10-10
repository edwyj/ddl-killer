import bcrypt from 'bcryptjs';
import {db} from './db.js';
import {auth, asyncRoute, limit} from './security.js';
import {createPat, listClients, normalizeScopes, revokeClient} from './mcp-credentials.js';

const PRESETS = Object.freeze({
  readonly: ['mcp:read'],
  planning: ['mcp:read', 'mcp:tasks:write', 'mcp:schedule:draft', 'mcp:schedule:apply'],
  full: ['mcp:read', 'mcp:tasks:write', 'mcp:schedule:draft', 'mcp:schedule:apply', 'mcp:delete', 'mcp:purge'],
});

async function verifyPassword(uid, password) {
  if (typeof password !== 'string') return false;
  const row = db.prepare('SELECT password_hash FROM users WHERE id=?').get(uid);
  return !!row && bcrypt.compare(password, row.password_hash);
}

export function mountMcpManagement(app) {
  app.get('/api/mcp/clients', auth, (req, res) => {
    res.json(listClients(req.user.uid));
  });

  app.post('/api/mcp/clients', auth, limit('mcp-manage', 20, 15 * 60000, (req) => String(req.user.uid)), asyncRoute(async (req, res) => {
    const {name, preset, scopes, expires_at: expiresAt, password} = req.body || {};
    if (!(await verifyPassword(req.user.uid, password))) {
      return res.status(401).json({error: '密码不正确', code: 'PASSWORD_INVALID'});
    }
    let selected;
    try {
      selected = normalizeScopes(scopes ?? PRESETS[preset]);
      const result = createPat({userId: req.user.uid, name, scopes: selected, expiresAt});
      res.status(201).json(result);
    } catch (error) {
      res.status(400).json({error: error.message, code: 'VALIDATION_FAILED'});
    }
  }));

  app.delete('/api/mcp/clients/:id', auth, limit('mcp-manage', 20, 15 * 60000, (req) => String(req.user.uid)), asyncRoute(async (req, res) => {
    if (!(await verifyPassword(req.user.uid, req.body?.password))) {
      return res.status(401).json({error: '密码不正确', code: 'PASSWORD_INVALID'});
    }
    if (!revokeClient(req.user.uid, req.params.id)) {
      return res.status(404).json({error: '连接不存在', code: 'OBJECT_NOT_FOUND'});
    }
    res.json({ok: true});
  }));

  app.get('/api/mcp/audit', auth, (req, res) => {
    const rows = db.prepare(`SELECT a.id,a.client_id,c.name client_name,a.tool_name,a.result_code,
        a.object_ids_json,a.created_at
      FROM mcp_audit_log a LEFT JOIN mcp_clients c ON c.id=a.client_id
      WHERE a.user_id=? ORDER BY a.id DESC LIMIT 50`).all(req.user.uid);
    res.json(rows.map((row) => ({
      id: row.id,
      clientId: row.client_id,
      clientName: row.client_name ?? '已删除的连接',
      toolName: row.tool_name,
      resultCode: row.result_code,
      objectIds: JSON.parse(row.object_ids_json),
      createdAt: row.created_at,
    })));
  });
}

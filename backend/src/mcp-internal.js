import {db} from './db.js';
import {verifyMcpCredential} from './mcp-credentials.js';
import {issueMcpInternalSession} from './security.js';
import {auth} from './security.js';
import {createDraft, getDraft, applyDraft, discardDraft} from './mcp-drafts.js';

const DRAFT_STATUS = Object.freeze({
  VALIDATION_FAILED: 400,
  OBJECT_NOT_FOUND: 404,
  DRAFT_STALE: 409,
  DRAFT_EXPIRED: 409,
  DRAFT_ALREADY_DISCARDED: 409,
  DRAFT_BLOCKED: 409,
});

function needScope(scope) {
  return (req, res, next) => req.user.scopes?.includes(scope)
    ? next()
    : res.status(403).json({error: '该连接没有所需权限', code: 'SCOPE_REQUIRED'});
}

function draftRoute(handler) {
  return (req, res) => {
    try { handler(req, res); }
    catch (error) {
      const status = DRAFT_STATUS[error.code] || 500;
      res.status(status).json({error: status === 500 ? '服务暂不可用' : error.message, code: error.code || 'INTERNAL_ERROR'});
    }
  };
}

export function mountMcpInternal(app) {
  app.post('/api/internal/mcp/exchange', (req, res) => {
    const header = req.headers.authorization;
    const raw = typeof header === 'string' && header.startsWith('Bearer ') ? header.slice(7) : null;
    const verified = raw ? verifyMcpCredential(raw) : null;
    if (!verified) return res.status(401).json({error: '连接凭据无效或已过期', code: 'AUTH_REQUIRED'});
    const user = db.prepare('SELECT username FROM users WHERE id=?').get(verified.principal.userId);
    if (!user) return res.status(401).json({error: '连接凭据无效或已过期', code: 'AUTH_REQUIRED'});
    res.json({
      token: issueMcpInternalSession(verified.principal, user.username),
      principal: verified.principal,
    });
  });

  app.post('/api/internal/mcp/drafts', auth, needScope('mcp:schedule:draft'), draftRoute((req, res) => {
    res.status(201).json(createDraft(req.user.uid, req.user.mcpClientId, req.body?.changes));
  }));
  app.get('/api/internal/mcp/drafts/:id', auth, needScope('mcp:schedule:draft'), draftRoute((req, res) => {
    res.json(getDraft(req.user.uid, req.params.id));
  }));
  app.delete('/api/internal/mcp/drafts/:id', auth, needScope('mcp:schedule:draft'), draftRoute((req, res) => {
    res.json(discardDraft(req.user.uid, req.params.id));
  }));
  app.post('/api/internal/mcp/drafts/:id/apply', auth, needScope('mcp:schedule:apply'), draftRoute((req, res) => {
    res.json(applyDraft(req.user.uid, req.user.mcpClientId, req.params.id));
  }));
}

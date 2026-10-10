export class McpApiError extends Error {
  constructor(code, message, status = 500) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

const base = (process.env.PLAN_INTERNAL_BASE || 'http://plan-api:3000').replace(/\/$/, '');

async function jsonRequest(path, init) {
  const response = await fetch(`${base}${path}`, init);
  const text = await response.text();
  let data;
  try { data = text ? JSON.parse(text) : null; } catch { data = {error: text}; }
  if (!response.ok) throw new McpApiError(data?.code || 'PLAN_API_ERROR', data?.error || `HTTP ${response.status}`, response.status);
  return data;
}

export async function exchangeCredential(raw) {
  if (typeof raw !== 'string' || !raw) throw new McpApiError('AUTH_REQUIRED', '缺少连接凭据', 401);
  return jsonRequest('/api/internal/mcp/exchange', {
    method: 'POST',
    headers: {authorization: `Bearer ${raw}`, 'content-type': 'application/json'},
  });
}

export function requireScope(context, scope) {
  if (!context?.principal?.scopes?.includes(scope)) {
    throw new McpApiError('INSUFFICIENT_SCOPE', `连接缺少权限：${scope}`, 403);
  }
}

export async function planRequest(context, method, path, body) {
  return jsonRequest(path, {
    method,
    headers: {authorization: `Bearer ${context.internalToken}`, 'content-type': 'application/json'},
    ...(body === undefined ? {} : {body: JSON.stringify(body)}),
  });
}

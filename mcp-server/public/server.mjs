import express from 'express';
import {fileURLToPath} from 'node:url';
import {McpServer, createMcpHandler} from '@modelcontextprotocol/server';
import {toNodeHandler} from '@modelcontextprotocol/node';
import {exchangeCredential, planRequest} from './api-client.mjs';
import {registerReadTools} from './tools-read.mjs';
import {registerWriteTools} from './tools-write.mjs';
import {registerDraftTools} from './tools-drafts.mjs';

export function createPublicApp({exchange = exchangeCredential, request = planRequest} = {}) {
  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({limit: '1mb'}));
  app.get('/health', (_req, res) => res.json({ok: true}));
  const origin=(process.env.PUBLIC_ORIGIN || 'https://ddlkiller.com').replace(/\/$/,'');
  const resourceMetadata={resource:`${origin}/mcp`,authorization_servers:[origin],bearer_methods_supported:['header'],scopes_supported:['mcp:read','mcp:tasks:write','mcp:schedule:draft','mcp:schedule:apply','mcp:delete','mcp:purge']};
  app.get(['/.well-known/oauth-protected-resource','/.well-known/oauth-protected-resource/mcp'],(_req,res)=>res.json(resourceMetadata));

  const handler = createMcpHandler((ctx) => {
    const server = new McpServer({name: 'ddl-killer', version: '1.0.0'});
    const auth = ctx.authInfo;
    const context = {principal: auth?._principal, internalToken: auth?.token, requestId: crypto.randomUUID()};
    registerReadTools(server, context, request);
    registerWriteTools(server, context, request);
    registerDraftTools(server, context, request);
    return server;
  }, {legacy: 'stateless'});
  const nodeHandler = toNodeHandler(handler, {onerror: (error) => console.error('MCP adapter error', error)});

  app.all('/mcp', async (req, res) => {
    if (['token', 'access_token', 'api_key'].some((name) => name in req.query)) {
      return res.status(400).json({error: '凭据只能放在 Authorization 请求头', code: 'AUTH_REQUIRED'});
    }
    const header = req.headers.authorization;
    const raw = typeof header === 'string' && header.startsWith('Bearer ') ? header.slice(7) : null;
    if (!raw) {
      res.set('WWW-Authenticate',`Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource/mcp"`);
      return res.status(401).json({error: '需要智能体连接凭据', code: 'AUTH_REQUIRED'});
    }
    try {
      const exchanged = await exchange(raw);
      req.auth = {
        token: exchanged.token,
        clientId: exchanged.principal.clientId,
        scopes: exchanged.principal.scopes,
        _principal: exchanged.principal,
      };
      await nodeHandler(req, res, req.body);
    } catch (error) {
      const status = Number.isInteger(error.status) ? error.status : 500;
      if(status===401) res.set('WWW-Authenticate',`Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource/mcp"`);
      res.status(status).json({error: error.message, code: error.code || 'MCP_INTERNAL_ERROR'});
    }
  });
  return app;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const port = Number(process.env.PORT || 8787);
  createPublicApp().listen(port, '0.0.0.0', () => console.log(`DDL Killer public MCP listening on ${port}`));
}

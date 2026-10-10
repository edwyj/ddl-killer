import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const html=readFileSync('web/mcp-help.html','utf8');
const caddy=readFileSync('../Caddyfile','utf8');
for(const text of [
  '什么是 MCP',
  'Claude Code',
  'Codex',
  'OpenClaw',
  '任务与规划（推荐）',
  'https://ddlkiller.com/mcp',
  '撤销',
  '令牌只显示一次',
]) assert.ok(html.includes(text),`Missing tutorial content: ${text}`);
assert.ok(!html.includes('ddl_mcp_secret'),'Tutorial must not contain a real-looking token');
assert.match(html,/meta name="viewport"/);
assert.match(caddy,/handle \/mcp \{/,'MCP route must match only the endpoint');
assert.doesNotMatch(caddy,/handle \/mcp\*/,'MCP route must not swallow mcp-help.html');
console.log('MCP help tutorial passed');

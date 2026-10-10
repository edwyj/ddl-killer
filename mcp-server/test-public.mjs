import test from 'node:test';
import assert from 'node:assert/strict';
import {Client as LegacyClient} from '@modelcontextprotocol/sdk/client/index.js';
import {StreamableHTTPClientTransport as LegacyTransport} from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import {Client, StreamableHTTPClientTransport} from '@modelcontextprotocol/client';
import {createPublicApp} from './public/server.mjs';

const principal = {
  userId: 7,
  clientId: 'client-1',
  clientName: 'test',
  scopes: ['mcp:read'],
  expiresAt: '2090-01-01T00:00:00.000Z',
};

async function fixture() {
  const calls = [];
  let draftChanges = [];
  const app = createPublicApp({
    exchange: async (raw) => {
      const scopes = raw === 'valid-pat' ? ['mcp:read']
        : raw === 'draft-pat' ? ['mcp:read', 'mcp:schedule:draft']
        : raw === 'planning-pat' ? ['mcp:read', 'mcp:tasks:write', 'mcp:schedule:draft', 'mcp:schedule:apply']
        : raw === 'full-pat' ? ['mcp:read', 'mcp:tasks:write', 'mcp:schedule:draft', 'mcp:schedule:apply', 'mcp:delete', 'mcp:purge']
        : null;
      if (!scopes) throw Object.assign(new Error('bad token'), {status: 401, code: 'AUTH_REQUIRED'});
      return {principal: {...principal, scopes}, token: 'internal-token'};
    },
    request: async (_ctx, method, path, body) => {
      calls.push([method, path, body]);
      if (path.includes('/999')) throw Object.assign(new Error('对象不存在'), {status: 404, code: 'OBJECT_NOT_FOUND'});
      if (method === 'POST' && path === '/api/internal/mcp/drafts') {
        draftChanges = body.changes;
        return {id: 'draft-1', status: 'pending', changes: draftChanges, warnings: [], expiresAt: '2090-01-01T00:30:00.000Z'};
      }
      if (method === 'GET' && path === '/api/internal/mcp/drafts/draft-1') return {
        id: 'draft-1', status: 'pending', changes: draftChanges,
        warnings: [], expiresAt: '2090-01-01T00:30:00.000Z',
      };
      if (method === 'POST' && path === '/api/internal/mcp/drafts/draft-1/apply') return {draftId: 'draft-1', applied: 2};
      if (method === 'DELETE' && path === '/api/internal/mcp/drafts/draft-1') return {id: 'draft-1', status: 'discarded', changes: [], warnings: []};
      if (method === 'POST') return {id: 11};
      if (method === 'PATCH' || method === 'DELETE') return {ok: true};
      if (path === '/api/lists') return [{id: 1, name: '收集箱', system: 'inbox', task_count: 1}];
      if (path.startsWith('/api/day')) return {classes: [], blocks: []};
      if (path === '/api/done' || path === '/api/trash') return [];
      if (path === '/api/inbox') return [{id: 1, title: '任务', due_date: '2030-01-02'}];
      throw new Error(`unexpected path ${path}`);
    },
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  return {url: `http://127.0.0.1:${server.address().port}/mcp`, calls, close: () => server.close()};
}

async function legacyClient(url, token = 'valid-pat') {
  const client = new LegacyClient({name: 'public-mcp-test', version: '1.0.0'});
  await client.connect(new LegacyTransport(new URL(url), {
    requestInit: {headers: {authorization: `Bearer ${token}`}},
  }));
  return client;
}

async function modernClient(url, token = 'valid-pat') {
  const client = new Client({name: 'public-mcp-modern-test', version: '1.0.0'});
  await client.connect(new StreamableHTTPClientTransport(new URL(url), {
    requestInit: {headers: {authorization: `Bearer ${token}`}},
  }));
  return client;
}

test('unauthorized MCP returns 401 and authorized legacy client lists read-only tools', async () => {
  const f = await fixture();
  try {
    const unauthorized=await fetch(f.url, {method: 'POST'});
    assert.equal(unauthorized.status, 401);
    assert.match(unauthorized.headers.get('www-authenticate'),/oauth-protected-resource\/mcp/);
    const metadata=await fetch(f.url.replace(/\/mcp$/,'/.well-known/oauth-protected-resource/mcp'));
    assert.equal(metadata.status,200);
    assert.equal((await metadata.json()).resource,'https://ddlkiller.com/mcp');
    assert.equal((await fetch(`${f.url}?token=valid-pat`, {method: 'POST'})).status, 400);
    const client = await legacyClient(f.url);
    const tools = (await client.listTools()).tools;
    assert.deepEqual(tools.map((tool) => tool.name).sort(), [
      'plan_get_planning_context', 'plan_lists', 'plan_view_day',
      'plan_view_done', 'plan_view_tasks', 'plan_view_trash',
    ]);
    assert.ok(tools.every((tool) => tool.annotations?.readOnlyHint === true));
    await client.close();
    const modern = await modernClient(f.url);
    const modernTools = (await modern.listTools()).tools;
    assert.deepEqual(modernTools.map((tool) => tool.name).sort(), tools.map((tool) => tool.name).sort());
    await modern.close();
  } finally { f.close(); }
});

test('planning context rejects over 14 days and caps objects at 200', async () => {
  const f = await fixture();
  try {
    const client = await legacyClient(f.url);
    const bad = await client.callTool({
      name: 'plan_get_planning_context',
      arguments: {startDate: '2030-01-01', endDate: '2030-01-15'},
    });
    assert.equal(bad.isError, true);
    assert.match(bad.content[0].text, /14 天/);
    const good = await client.callTool({
      name: 'plan_get_planning_context',
      arguments: {startDate: '2030-01-01', endDate: '2030-01-14'},
    });
    assert.equal(good.isError, undefined);
    assert.ok(JSON.parse(good.content[0].text).items.length <= 200);
    await client.close();
  } finally { f.close(); }
});

test('write tools follow scope presets and return stable cross-user errors', async () => {
  const f = await fixture();
  try {
    const planning = await legacyClient(f.url, 'planning-pat');
    const planningNames = (await planning.listTools()).tools.map((tool) => tool.name);
    assert.ok(planningNames.includes('plan_add_task'));
    assert.ok(planningNames.includes('plan_add_scheduled'));
    assert.ok(!planningNames.includes('plan_delete_task'));
    assert.ok(!planningNames.includes('plan_purge'));
    const made = await planning.callTool({name: 'plan_add_task', arguments: {title: '新任务'}});
    assert.match(made.content[0].text, /#11/);
    await planning.close();

    const full = await legacyClient(f.url, 'full-pat');
    const names = (await full.listTools()).tools.map((tool) => tool.name);
    assert.ok(names.includes('plan_delete_list'));
    assert.ok(names.includes('plan_purge'));
    const missing = await full.callTool({
      name: 'plan_update_task', arguments: {kind: 'inbox', id: 999, title: '越权'},
    });
    assert.equal(missing.isError, true);
    assert.match(missing.content[0].text, /OBJECT_NOT_FOUND/);
    await full.close();
  } finally { f.close(); }
});

test('draft tools are scoped, annotated and apply the exact persisted preview', async () => {
  const f = await fixture();
  try {
    const readonly = await legacyClient(f.url);
    assert.ok(!(await readonly.listTools()).tools.some((tool) => tool.name.includes('schedule_draft')));
    await readonly.close();

    const drafter = await legacyClient(f.url, 'draft-pat');
    const draftOnlyNames = (await drafter.listTools()).tools.map((tool) => tool.name);
    assert.ok(draftOnlyNames.includes('plan_create_schedule_draft'));
    assert.ok(!draftOnlyNames.includes('plan_apply_schedule_draft'));
    await drafter.close();

    const planner = await legacyClient(f.url, 'planning-pat');
    const tools = (await planner.listTools()).tools;
    const byName = Object.fromEntries(tools.map((tool) => [tool.name, tool]));
    for (const name of ['plan_create_schedule_draft','plan_get_schedule_draft','plan_apply_schedule_draft','plan_discard_schedule_draft']) assert.ok(byName[name]);
    assert.equal(byName.plan_get_schedule_draft.annotations.readOnlyHint, true);
    assert.equal(byName.plan_apply_schedule_draft.annotations.destructiveHint, true);
    const changes = [
      {op: 'schedule_task', taskId: 1, date: '2030-01-03', start: 600, end: 660},
      {op: 'create_block', date: '2030-01-03', start: 720, end: 780, title: '专注', notes: '不应回显的备注'},
    ];
    const made = await planner.callTool({name: 'plan_create_schedule_draft', arguments: {changes}});
    assert.match(made.content[0].text, /2 项/);
    assert.equal(made.structuredContent.draftId, 'draft-1');
    assert.ok(!JSON.stringify(made).includes('不应回显的备注'));
    const viewed = await planner.callTool({name: 'plan_get_schedule_draft', arguments: {draftId: 'draft-1'}});
    assert.deepEqual(viewed.structuredContent.changes, changes.map(({notes, ...item}) => item));
    const badApply = await planner.callTool({name: 'plan_apply_schedule_draft', arguments: {draftId: 'draft-1', changes: []}});
    assert.equal(badApply.isError, true);
    const applied = await planner.callTool({name: 'plan_apply_schedule_draft', arguments: {draftId: 'draft-1'}});
    assert.equal(applied.structuredContent.applied, 2);
    assert.deepEqual(f.calls.find(([method,path]) => method === 'POST' && path.endsWith('/apply'))[2], undefined);
    await planner.close();
  } finally { f.close(); }
});

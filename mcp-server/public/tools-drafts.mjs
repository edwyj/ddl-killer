import {z} from 'zod';
import {requireScope} from './api-client.mjs';

const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
const minute = z.number().int().min(0).max(1440);
const change = z.discriminatedUnion('op', [
  z.object({op: z.literal('schedule_task'), taskId: z.number().int().positive(), date, start: minute, end: minute, reason: z.string().optional()}).strict(),
  z.object({op: z.literal('unschedule_task'), taskId: z.number().int().positive(), reason: z.string().optional()}).strict(),
  z.object({op: z.literal('create_block'), date, start: minute, end: minute, title: z.string().min(1), notes: z.string().optional(), color: z.string().optional(), reason: z.string().optional()}).strict(),
]);

const annotations = ({readOnly = false, destructive = false, idempotent = false} = {}) => ({
  readOnlyHint: readOnly,
  destructiveHint: destructive,
  idempotentHint: idempotent,
  openWorldHint: false,
});
const fail = (error) => ({content: [{type: 'text', text: `${error.code || 'PLAN_API_ERROR'}：${error.message}`}], isError: true});
const clean = (draft) => {
  const changes = (draft.changes || []).map(({notes: _notes, reason: _reason, ...item}) => item);
  return {...draft, draftId: draft.id || draft.draftId, changes};
};
const preview = (draft) => {
  const data = clean(draft);
  const blocking = (data.warnings || []).filter((warning) => warning.severity === 'blocking').length;
  const warnings = (data.warnings || []).length - blocking;
  const status = data.status === 'pending' ? '待确认 pending' : data.status;
  return {
    content: [{type: 'text', text: `排期草案 ${data.draftId}：${data.changes.length} 项变更；状态 ${status}；${blocking} 个阻塞冲突，${warnings} 个提醒。`}],
    structuredContent: data,
  };
};

export function registerDraftTools(server, context, request) {
  const has = (scope) => context.principal?.scopes?.includes(scope);
  const register = (name, description, inputSchema, scope, toolAnnotations, handler) => {
    if (!has(scope)) return;
    server.registerTool(name, {description, inputSchema, annotations: toolAnnotations}, async (args) => {
      try { requireScope(context, scope); return await handler(args); }
      catch (error) { return fail(error); }
    });
  };

  register(
    'plan_create_schedule_draft',
    '创建排期草案。AI 自行选时、批量安排或重排时必须先创建草案，不会立即改动日程。',
    z.object({changes: z.array(change).min(1).max(100)}).strict(),
    'mcp:schedule:draft', annotations(),
    async ({changes}) => preview(await request(context, 'POST', '/api/internal/mcp/drafts', {changes})),
  );
  register(
    'plan_get_schedule_draft',
    '查看已保存的排期草案、状态与冲突，不会改动日程。',
    z.object({draftId: z.string().min(1)}).strict(),
    'mcp:schedule:draft', annotations({readOnly: true, idempotent: true}),
    async ({draftId}) => preview(await request(context, 'GET', `/api/internal/mcp/drafts/${encodeURIComponent(draftId)}`)),
  );
  register(
    'plan_discard_schedule_draft',
    '丢弃待确认的排期草案，不会改动日程。',
    z.object({draftId: z.string().min(1)}).strict(),
    'mcp:schedule:draft', annotations({idempotent: true}),
    async ({draftId}) => preview(await request(context, 'DELETE', `/api/internal/mcp/drafts/${encodeURIComponent(draftId)}`)),
  );
  register(
    'plan_apply_schedule_draft',
    '应用已经查看过的排期草案。高影响写操作；只接受 draftId，实际执行内容以服务端保存的预览为准。',
    z.object({draftId: z.string().min(1)}).strict(),
    'mcp:schedule:apply', annotations({destructive: true, idempotent: true}),
    async ({draftId}) => {
      const result = await request(context, 'POST', `/api/internal/mcp/drafts/${encodeURIComponent(draftId)}/apply`);
      return {content: [{type: 'text', text: `已应用排期草案 ${draftId}，共 ${result.applied} 项。`}], structuredContent: result};
    },
  );
}

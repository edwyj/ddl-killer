import {z} from 'zod';
import {requireScope} from './api-client.mjs';

const annotations = (destructive = false) => ({readOnlyHint: false, destructiveHint: destructive, idempotentHint: false, openWorldHint: false});
const ok = (message, data) => ({content: [{type: 'text', text: message}], ...(data ? {structuredContent: data} : {})});
const fail = (error) => ({content: [{type: 'text', text: `${error.code || 'PLAN_API_ERROR'}：${error.message}`}], isError: true});
const toMin = (value) => {
  if (Number.isInteger(value)) return value;
  const match = typeof value === 'string' && value.match(/^(\d{1,2}):(\d{2})$/);
  return match ? Number(match[1]) * 60 + Number(match[2]) : null;
};
const toIso = (value) => {
  if (value == null || value === '') return null;
  const raw = String(value).trim();
  const naive = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?$/.test(raw);
  const date = new Date(naive ? `${raw.replace(' ', 'T')}+08:00` : raw);
  if (!Number.isFinite(date.getTime())) throw Object.assign(new Error('提醒时间格式不正确'), {code: 'VALIDATION_FAILED'});
  return date.toISOString();
};

export function registerWriteTools(server, context, request) {
  const has = (scope) => context.principal?.scopes?.includes(scope);
  const register = (name, description, inputSchema, scope, destructive, handler) => {
    if (!has(scope)) return;
    server.registerTool(name, {description, inputSchema, annotations: annotations(destructive)}, async (args) => {
      try { requireScope(context, scope); return await handler(args); } catch (error) { return fail(error); }
    });
  };

  register('plan_add_list', '新建清单。', z.object({name: z.string().min(1), color: z.string().optional(), emoji: z.string().optional()}), 'mcp:tasks:write', false,
    async (a) => { const data = await request(context, 'POST', '/api/lists', {name: a.name, color: a.color || '', emoji: a.emoji || ''}); return ok(`已创建清单 #${data.id}「${a.name}」`, data); });
  register('plan_update_list', '修改清单。', z.object({id: z.number().int(), name: z.string().min(1).optional(), color: z.string().optional(), emoji: z.string().optional()}), 'mcp:tasks:write', false,
    async ({id, ...body}) => { await request(context, 'PATCH', `/api/lists/${id}`, body); return ok(`已修改清单 #${id}`); });
  register('plan_delete_list', '删除普通清单，任务会落到“其他”。', z.object({id: z.number().int()}), 'mcp:delete', true,
    async ({id}) => { await request(context, 'DELETE', `/api/lists/${id}`); return ok(`已删除清单 #${id}`); });

  register('plan_add_task', '添加普通任务或 DDL。', z.object({
    title: z.string().min(1), listId: z.number().int().nullable().optional(),
    dueDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).nullable().optional(),
    dueTime: z.union([z.string(), z.number()]).nullable().optional(), priority: z.number().int().min(0).max(2).optional(),
    notes: z.string().optional(), reminder: z.string().nullable().optional(),
  }), 'mcp:tasks:write', false, async (a) => {
    const body = {title: a.title, list_id: a.listId ?? null, due_date: a.dueDate ?? null, due_time: toMin(a.dueTime), priority: a.priority ?? 0, notes: a.notes || ''};
    if (a.reminder !== undefined) body.reminder_at = toIso(a.reminder);
    const data = await request(context, 'POST', '/api/inbox', body);
    return ok(`已添加任务 #${data.id}「${a.title}」`, data);
  });
  register('plan_add_scheduled', '按用户明确给出的时间创建单个独立时间块。AI 自行选时或批量安排必须走草案。', z.object({
    date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/), start: z.union([z.string(), z.number()]), end: z.union([z.string(), z.number()]),
    title: z.string().min(1), notes: z.string().optional(), color: z.string().optional(),
  }), 'mcp:schedule:apply', false, async (a) => {
    const start_min = toMin(a.start), end_min = toMin(a.end);
    if (start_min == null || end_min == null) throw Object.assign(new Error('时间格式不正确'), {code: 'VALIDATION_FAILED'});
    const data = await request(context, 'POST', '/api/blocks', {...a, start_min, end_min, start: undefined, end: undefined, color: a.color || '#8e7cc3'});
    return ok(`已安排时间块 #${data.id}「${a.title}」`, data);
  });

  if (has('mcp:tasks:write') || has('mcp:schedule:apply')) server.registerTool('plan_update_task', {
    description: '修改任务或时间块。创建、移动或取消排期需要 schedule:apply。',
    inputSchema: z.object({
      id: z.number().int(), kind: z.enum(['inbox', 'scheduled']), title: z.string().optional(), done: z.boolean().optional(),
      priority: z.number().int().min(0).max(2).optional(), notes: z.string().optional(), listId: z.number().int().nullable().optional(),
      dueDate: z.union([z.literal(''), z.string().regex(/^\d{4}-\d{2}-\d{2}$/)]).optional(), dueTime: z.union([z.string(), z.number()]).optional(),
      reminder: z.string().optional(), schedule: z.object({date: z.string(), start: z.union([z.string(), z.number()]), end: z.union([z.string(), z.number()])}).nullable().optional(),
      start: z.union([z.string(), z.number()]).optional(), end: z.union([z.string(), z.number()]).optional(), color: z.string().optional(),
    }), annotations: annotations(false),
  }, async (a) => {
    try {
      const changesSchedule = a.schedule !== undefined || a.start !== undefined || a.end !== undefined;
      requireScope(context, changesSchedule ? 'mcp:schedule:apply' : 'mcp:tasks:write');
      const path = a.kind === 'inbox' ? `/api/inbox/${a.id}` : `/api/blocks/${a.id}`;
      const body = {};
      for (const key of ['title', 'done', 'priority', 'notes', 'color']) if (a[key] !== undefined) body[key] = a[key];
      if (a.listId !== undefined) body.list_id = a.listId;
      if (a.reminder !== undefined) body.reminder_at = toIso(a.reminder);
      if (a.dueDate !== undefined) { body.due_date = a.dueDate || null; if (!a.dueDate) body.due_time = null; }
      if (a.dueTime !== undefined) body.due_time = toMin(a.dueTime);
      if (a.schedule !== undefined) body.schedule = a.schedule === null ? null : {date: a.schedule.date, start_min: toMin(a.schedule.start), end_min: toMin(a.schedule.end)};
      if (a.start !== undefined) body.start_min = toMin(a.start);
      if (a.end !== undefined) body.end_min = toMin(a.end);
      await request(context, 'PATCH', path, body); return ok(`已修改 ${a.kind} #${a.id}`);
    } catch (error) { return fail(error); }
  });

  register('plan_delete_task', '软删除任务；删除挂载排期块只会取消安排。', z.object({id: z.number().int(), kind: z.enum(['inbox', 'scheduled'])}), 'mcp:delete', true,
    async (a) => { await request(context, 'DELETE', a.kind === 'inbox' ? `/api/inbox/${a.id}` : `/api/blocks/${a.id}`); return ok(`已删除 ${a.kind} #${a.id}`); });
  register('plan_restore', '从回收站恢复。', z.object({kind: z.enum(['task', 'block']), id: z.number().int()}), 'mcp:tasks:write', false,
    async (a) => { await request(context, 'POST', `/api/trash/${a.kind}/${a.id}/restore`); return ok(`已还原 ${a.kind} #${a.id}`); });
  register('plan_purge', '永久删除，不可恢复。', z.object({kind: z.enum(['task', 'block', 'done']), id: z.number().int()}), 'mcp:purge', true,
    async (a) => { await request(context, 'DELETE', a.kind === 'done' ? `/api/done/${a.id}` : `/api/trash/${a.kind}/${a.id}`); return ok(`已永久删除 ${a.kind} #${a.id}`); });
  register('plan_empty', '清空回收站或已完成，不可恢复。', z.object({what: z.enum(['trash', 'done'])}), 'mcp:purge', true,
    async (a) => { await request(context, 'DELETE', a.what === 'trash' ? '/api/trash' : '/api/done'); return ok(`已清空${a.what === 'trash' ? '回收站' : '已完成'}`); });
}

import {z} from 'zod';

const readAnnotations = {readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false};
const text = (value) => ({content: [{type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value)}]});
const failure = (message) => ({content: [{type: 'text', text: message}], isError: true});

function daysBetween(start, end) {
  const a = new Date(`${start}T00:00:00Z`);
  const b = new Date(`${end}T00:00:00Z`);
  if (!Number.isFinite(a.getTime()) || !Number.isFinite(b.getTime())) return null;
  return Math.floor((b - a) / 86400000) + 1;
}

export function registerReadTools(server, context, request) {
  const register = (name, description, inputSchema, handler) => server.registerTool(
    name,
    {description, inputSchema, annotations: readAnnotations},
    async (args) => {
      try { return await handler(args); }
      catch (error) { return failure(`${error.code || 'PLAN_API_ERROR'}：${error.message}`); }
    },
  );

  register('plan_lists', '列出当前用户的清单。收集箱有真实 id，其他为 list_id=null。', z.object({}),
    async () => text(await request(context, 'GET', '/api/lists')));
  register('plan_view_tasks', '查看当前用户未删除的任务与 DDL。', z.object({}),
    async () => text(await request(context, 'GET', '/api/inbox')));
  register('plan_view_day', '查看某天课程和排期。', z.object({date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/)}),
    async ({date}) => text(await request(context, 'GET', `/api/day?date=${encodeURIComponent(date)}`)));
  register('plan_view_done', '查看已完成任务。', z.object({}),
    async () => text(await request(context, 'GET', '/api/done')));
  register('plan_view_trash', '查看回收站。', z.object({}),
    async () => text(await request(context, 'GET', '/api/trash')));
  register(
    'plan_get_planning_context',
    '读取最多 14 天的课程、排期和任务，供智能体生成排期草案。',
    z.object({
      startDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
      endDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    }),
    async ({startDate, endDate}) => {
      const count = daysBetween(startDate, endDate);
      if (count == null || count < 1 || count > 14) return failure('VALIDATION_FAILED：日期范围必须为 1–14 天');
      const tasks = await request(context, 'GET', '/api/inbox');
      const items = [];
      const cursor = new Date(`${startDate}T00:00:00Z`);
      for (let index = 0; index < count && items.length < 200; index++) {
        const date = cursor.toISOString().slice(0, 10);
        const day = await request(context, 'GET', `/api/day?date=${date}`);
        for (const entry of [...(day.classes || []), ...(day.blocks || [])]) {
          if (items.length < 200) items.push({...entry, date});
        }
        cursor.setUTCDate(cursor.getUTCDate() + 1);
      }
      for (const task of Array.isArray(tasks) ? tasks : []) {
        if (items.length < 200) items.push({...task, kind: 'task'});
      }
      return text({startDate, endDate, items});
    },
  );
}

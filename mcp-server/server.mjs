// Plan MCP server — 供受信任客户端管理当前授权用户的 DDL Killer 数据（旧账号密码集成）。
//
// 三种「任务」形态，改/删前先分清：
//   1. inbox/DDL 任务  —— 收件箱/清单里的任务(inbox 表)：due_date/due_time/priority/list_id/reminder_at
//   2. 排期块         —— 把某条 inbox 任务排到时间轴(blocks.inbox_id 有值)；删它=取消安排，任务还在
//   3. 独立时间块     —— 直接属于某清单、不挂任务的时间块(blocks.inbox_id IS NULL)
//
// 语义要点(2026-09-12 改版后，别再按老文档说)：
//   · 「收集箱」是**真清单**(system='inbox')，有真实 id；list_id=null 是「其他」，不是收集箱。
//   · 「已完成」「回收站」是**算出来的**视图，不能往里放任务，plan_lists 也不再列出它们。
//   · 删除任务 = 软删进回收站，保留 7 天可还原；已完成保留 3 天后自动清理。
//   · reminder_at 是 ISO UTC 时刻；不带时区的时间一律按北京时间(UTC+8)解释。
//
// 鉴权用 PLAN_USER/PLAN_PASS 登录，内存缓存 token，401 自动重登。
import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

const PLAN_BASE = (process.env.PLAN_BASE || "https://ddlkiller.com").replace(/\/$/, "");
const USER = process.env.PLAN_USER;
const PASS = process.env.PLAN_PASS;
if (!USER || !PASS) {
  console.error("缺 PLAN_USER / PLAN_PASS 环境变量");
  process.exit(1);
}

const TRASH_DAYS = 7;
const DONE_DAYS = 3;

let token = null;

async function login() {
  const r = await fetch(`${PLAN_BASE}/api/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: USER, password: PASS }),
  });
  if (!r.ok) throw new Error(`login ${r.status}: ${await r.text()}`);
  const d = await r.json();
  if (!d.token) throw new Error("login 未返回 token");
  token = d.token;
  return token;
}

// 带鉴权调用 plan-api；401 时重登重试一次
async function api(method, path, body, retried = false) {
  if (!token) token = await login();
  const r = await fetch(`${PLAN_BASE}${path}`, {
    method,
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (r.status === 401 && !retried) { token = null; return api(method, path, body, true); }
  const text = await r.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  return { status: r.status, data };
}

// 'HH:mm' 或数字(分钟) -> 当天分钟数；否则 null
function toMin(v) {
  if (v == null || v === "") return null;
  if (typeof v === "number") return Math.floor(v);
  if (typeof v === "string") {
    const m = v.match(/^(\d{1,2}):(\d{2})$/);
    if (m) return Number(m[1]) * 60 + Number(m[2]);
    const n = Number(v);
    return Number.isFinite(n) ? Math.floor(n) : null;
  }
  return null;
}

// 提醒时间 -> ISO UTC 字符串。后端只认 `...Z`，而容器时区是 UTC：
// 直接 new Date('2026-09-14T09:00') 会被当 UTC 解析，比北京时间早 8 小时。
// 所以「不带时区」的输入一律显式按 +08:00 解释。
function toIso(v) {
  if (v == null) return null;
  const s = String(v).trim();
  if (!s) return null;
  const naive = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?$/.test(s);
  const d = new Date(naive ? `${s.replace(" ", "T")}+08:00` : s);
  if (!Number.isFinite(d.getTime())) throw new Error(`提醒时间格式不对: ${s}`);
  return d.toISOString();
}

function fmtMin(m) {
  if (m == null) return "";
  return ` ${Math.floor(m / 60)}:${String(m % 60).padStart(2, "0")}`;
}
const isDate = (s) => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
const CN_WD = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"];
const pad = (n) => String(n).padStart(2, "0");
function todayStr() {
  const t = new Date();
  return `${t.getFullYear()}-${pad(t.getMonth() + 1)}-${pad(t.getDate())}`;
}
function weekdayOf(dateStr) {
  const g = new Date(`${dateStr}T00:00:00`);
  return CN_WD[g.getDay() === 0 ? 7 : g.getDay()];
}
// 北京时间显示（容器是 UTC，直接 toLocaleString 会差 8 小时）
function fmtCST(iso) {
  if (!iso) return "";
  const d = new Date(Date.parse(iso) + 8 * 3600 * 1000);
  if (!Number.isFinite(d.getTime())) return "";
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
}
function daysLeft(stamp, window) {
  const left = window - (Date.now() - Date.parse(stamp)) / 86400000;
  return Math.max(0, Math.ceil(left));
}
// list_id -> 清单名。null/0 是「其他」——**不是**收集箱！
function listNameOf(map, id) {
  return id ? (map.get(id) || `#${id}`) : "其他";
}
// 排期块在 DDL 视图里的一行摘要
function scheduleNote(s) {
  return s && isDate(s.date)
    ? `  📅已排期=${s.date} ${weekdayOf(s.date)} ${fmtMin(s.start_min).trim()}-${fmtMin(s.end_min).trim()}`
    : "";
}

function buildServer() {
  const server = new McpServer({ name: "plan", version: "1.3.0" });

  server.tool(
    "plan_lists",
    "列出当前授权用户的清单(名字/颜色/任务数)。记任务前先调这个问用户记到哪个清单。\n" +
      "· id=null 的那条叫「其他」=不归任何清单(散任务)，**它和「收集箱」不是一回事**。\n" +
      "· 「收集箱」是普通清单之一，有真实 id；「已完成」「回收站」是自动归集的视图，不在此列出、也不能往里放任务。",
    {},
    async () => {
      const { status, data } = await api("GET", "/api/lists");
      if (status !== 200 || !Array.isArray(data))
        return { content: [{ type: "text", text: `获取清单失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      const lists = data.filter((l) => l.system !== "done" && l.system !== "trash");
      const inbox = lists.filter((l) => l.system === "inbox");
      const normal = lists.filter((l) => l.system !== "inbox");
      const line = (l) => `· id=${l.id}  ${l.emoji || ""}${l.name}  (${l.task_count ?? 0}任务)`;
      const text = [
        ...inbox.map(line),
        ...normal.map(line),
        "· id=null  📦其他(不归任何清单)",
      ].join("\n");
      return { content: [{ type: "text", text }] };
    }
  );

  server.tool(
    "plan_add_list",
    "新建一个清单。name 必填；color 可选(如 '#8e7cc3')；emoji 可选(如 '📚')。建好后让用户按需往里加任务。",
    {
      name: z.string().min(1),
      color: z.string().optional(),
      emoji: z.string().optional(),
    },
    async (args) => {
      const body = { name: args.name, color: args.color || "", emoji: args.emoji || "" };
      const { status, data } = await api("POST", "/api/lists", body);
      if (status !== 200) return { content: [{ type: "text", text: `创建清单失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      return { content: [{ type: "text", text: `已创建清单 #${data && data.id}「${args.name}」` }] };
    }
  );

  server.tool(
    "plan_update_list",
    "修改清单名字/颜色/emoji。id 从 plan_lists 拿到，只传要改的字段(其余保留)。改名字用这个，别新建。",
    {
      id: z.number().int(),
      name: z.string().min(1).optional(),
      color: z.string().optional(),
      emoji: z.string().optional(),
    },
    async (args) => {
      const body = {};
      if (args.name !== undefined) body.name = args.name;
      if (args.color !== undefined) body.color = args.color;
      if (args.emoji !== undefined) body.emoji = args.emoji;
      const { status, data } = await api("PATCH", `/api/lists/${args.id}`, body);
      if (status !== 200) return { content: [{ type: "text", text: `修改清单失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      return { content: [{ type: "text", text: `已修改清单 #${args.id}${args.name ? `→「${args.name}」` : ""}` }] };
    }
  );

  server.tool(
    "plan_delete_list",
    "删除一个清单(清单本身删了就没了，动手前先跟用户确认；但**清单里的任务不会被删**)。删后该清单下的任务 list_id 清空，落到「其他」而不是「收集箱」。",
    { id: z.number().int() },
    async (args) => {
      const { status, data } = await api("DELETE", `/api/lists/${args.id}`);
      if (status !== 200) return { content: [{ type: "text", text: `删除清单失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      return { content: [{ type: "text", text: `已删除清单 #${args.id}(其下任务未删，已落到「其他」)` }] };
    }
  );

  server.tool(
    "plan_view_tasks",
    "查看收件箱/DDL 任务(带截止时间的任务)。scope='today' 今天到期; 'upcoming' 未来未完成; 'all' 全部(含已完成)。可加 listId 限定某清单(listId=null 查「其他」)。\n" +
      "返回每条含 id(供后续改/删)、标题、到期、完成、清单、优先级、备注、提醒、是否已排期。",
    {
      scope: z.enum(["today", "upcoming", "all"]).optional(),
      listId: z.number().int().nullable().optional(),
    },
    async (args) => {
      const today = todayStr();
      const listsRes = await api("GET", "/api/lists");
      const listName = new Map((Array.isArray(listsRes.data) ? listsRes.data : []).map((l) => [l.id, l.name]));
      const { status, data } = await api("GET", "/api/inbox");
      if (status !== 200 || !Array.isArray(data))
        return { content: [{ type: "text", text: `获取任务失败(status=${status})` }], isError: true };
      let rows = data;
      const scope = args.scope || "today";
      if (scope === "today") rows = rows.filter((t) => t.due_date === today && !t.done);
      else if (scope === "upcoming") rows = rows.filter((t) => t.due_date && t.due_date > today && !t.done);
      if (args.listId !== undefined) rows = rows.filter((t) => (t.list_id ?? null) === args.listId);
      rows.sort((a, b) => (a.due_date || "9999").localeCompare(b.due_date || "9999"));
      if (rows.length === 0) return { content: [{ type: "text", text: "没有符合条件的任务。" }] };
      const text = rows.map((t) =>
        `- #${t.id} ${t.done ? "✅" : "☐"}「${t.title}」 到期=${t.due_date || "无"}${fmtMin(t.due_time)}  清单=${listNameOf(listName, t.list_id)}  P=${t.priority}` +
        `${t.notes ? `  📝备注=${t.notes}` : ""}` +
        `${t.reminder_at ? `  ⏰提醒=${fmtCST(t.reminder_at)}(北京时间)` : ""}` +
        `${scheduleNote(t.schedule)}`).join("\n");
      return { content: [{ type: "text", text: `${rows.length} 条:\n${text}` }] };
    }
  );

  server.tool(
    "plan_view_day",
    "查看某天(或连续 N 天)的完整时间轴=任务视图：课程(课表) + 时间块。Alice 用它看某天安排了什么、找空档/冲突。date 形如 2026-09-07；count 1-7 默认 1(单天)，>1 看连续几天。\n" +
      "返回行会标明【课程·不可改】/【排期块·属于某条任务】/【独立时间块】；带 #id 的都能用 plan_update_task(kind:'scheduled') 改。",
    {
      date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
      count: z.number().int().min(1).max(7).optional(),
    },
    async (args) => {
      const count = args.count || 1;
      const { status, data } = await api("GET", `/api/days?start=${args.date}&count=${count}`);
      if (status !== 200 || !data || !Array.isArray(data.days))
        return { content: [{ type: "text", text: `获取时间轴失败(status=${status})` }], isError: true };
      const out = [];
      for (const d of data.days) {
        out.push(`=== ${d.date} ${weekdayOf(d.date)}${data.weekNum != null ? ` 第${data.weekNum}周` : ""} ===`);
        const tl = (d.timeline || []).map((it) => {
          const span = `${fmtMin(it.start_min).trim().padStart(5)}-${fmtMin(it.end_min).trim().padEnd(5)}`;
          if (it.type === "class")
            return `  ${span} 🎓${it.title}${it.room ? `(${it.room})` : ""}${it.teacher ? ` ${it.teacher}` : ""}  【课程·不可改】`;
          const head = `${span} ${it.inbox_id ? "📅" : "📌"}#${it.id} ${it.done ? "✅" : "☐"}${it.title}${it.notes ? `  📝${it.notes}` : ""}`;
          return it.inbox_id
            ? `  ${head}  【排期块·任务#${it.inbox_id}的安排；删#${it.id}=取消安排，任务仍在】`
            : `  ${head}  【独立时间块·可改/删】`;
        });
        if (tl.length === 0) tl.push("  (无安排)");
        out.push(...tl);
      }
      return { content: [{ type: "text", text: out.join("\n") }] };
    }
  );

  server.tool(
    "plan_add_task",
    "往 Plan 应用添加一条收件箱/DDL 任务(title 必填)。listId 选清单(id 或 null=「其他」；收集箱也有自己的 id，从 plan_lists 拿)；dueDate 形如 2026-09-10(截止日)；dueTime 'HH:mm' 或分钟数；priority 0=低 1=中 2=高；notes 备注；reminder 提醒时刻(形如 '2026-09-10T08:00'，不带时区按北京时间算，必须晚于现在)。带明确起止时间、要上时间轴的任务用 plan_add_scheduled。",
    {
      title: z.string().min(1),
      listId: z.number().int().nullable().optional(),
      dueDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).nullable().optional(),
      dueTime: z.union([z.string(), z.number()]).nullable().optional(),
      priority: z.number().int().min(0).max(2).optional(),
      notes: z.string().nullable().optional(),
      reminder: z.string().nullable().optional(),
    },
    async (args) => {
      let reminder;
      try { reminder = args.reminder === undefined ? undefined : toIso(args.reminder); }
      catch (e) { return { content: [{ type: "text", text: e.message }], isError: true }; }
      const body = { title: args.title, priority: args.priority ?? 0, list_id: args.listId ?? null, due_date: args.dueDate || null, due_time: toMin(args.dueTime), notes: args.notes || "" };
      if (reminder !== undefined) body.reminder_at = reminder;
      const { status, data } = await api("POST", "/api/inbox", body);
      if (status !== 200) return { content: [{ type: "text", text: `添加失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      return { content: [{ type: "text", text: `已添加任务 #${data && data.id}「${args.title}」${reminder ? ` ⏰${fmtCST(reminder)}` : ""}` }] };
    }
  );

  server.tool(
    "plan_add_scheduled",
    "把一条任务放到某天时间轴(任务视图)的指定时间来安排(建独立时间块)。date 形如 2026-09-07；start/end 为 'HH:mm' 或分钟数；title 必填；notes 可选；color 可选(#8e7cc3 默认)。适合用户说比如'周三下午2点到4点写论文'。\n若用户说的是**已有的某条 DDL 任务**要排时间，别新建，用 plan_update_task(kind:'inbox', schedule:{...})。只有截止日没具体时间用 plan_add_task。",
    {
      date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
      start: z.union([z.string(), z.number()]),
      end: z.union([z.string(), z.number()]),
      title: z.string().min(1),
      notes: z.string().optional(),
      color: z.string().optional(),
    },
    async (args) => {
      const start_min = toMin(args.start);
      const end_min = toMin(args.end);
      if (start_min == null || end_min == null) return { content: [{ type: "text", text: "时间格式不对(需 'HH:mm' 或分钟数)" }], isError: true };
      const body = { date: args.date, start_min, end_min, title: args.title, notes: args.notes || "", color: args.color || "#8e7cc3" };
      const { status, data } = await api("POST", "/api/blocks", body);
      if (status !== 200) return { content: [{ type: "text", text: `添加失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      return { content: [{ type: "text", text: `已安排到时间轴 #${data && data.id}「${args.title}」 ${args.date} ${weekdayOf(args.date)} ${fmtMin(start_min)}-${fmtMin(end_min)}` }] };
    }
  );

  server.tool(
    "plan_update_task",
    "修改已有任务。kind='inbox' 改收件箱/DDL 任务；kind='scheduled' 改时间轴上的块(独立块或某条任务的排期块都行)。id 从 plan_view_tasks/plan_view_day 拿到。只传要改的字段(其余保留)。\n" +
      "· inbox: title/done/priority/notes；listId(换清单, null=移到「其他」)；dueDate(设=改截止日, 传''=清空截止)；dueTime(可单独传只改时间)；reminder(设提醒, 传''=清除)；schedule(排到时间轴 {date,start,end} / 传 null=取消安排)。\n" +
      "· scheduled: title/done/color/start/end(改起止)。**date 不能在这里改**——跨天移动用 plan_update_task(kind:'inbox') 找到它对应的任务改 schedule，或删掉再用 plan_add_scheduled。",
    {
      id: z.number().int(),
      kind: z.enum(["inbox", "scheduled"]),
      title: z.string().optional(),
      done: z.boolean().optional(),
      priority: z.number().int().min(0).max(2).optional(),
      notes: z.string().optional(),
      listId: z.number().int().nullable().optional(),
      dueDate: z.union([z.literal(""), z.string().regex(/^\d{4}-\d{2}-\d{2}$/)]).optional(),
      dueTime: z.union([z.string(), z.number()]).optional(),
      reminder: z.string().optional(),
      schedule: z.object({
        date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
        start: z.union([z.string(), z.number()]),
        end: z.union([z.string(), z.number()]),
      }).nullable().optional(),
      start: z.union([z.string(), z.number()]).optional(),
      end: z.union([z.string(), z.number()]).optional(),
      color: z.string().optional(),
    },
    async (args) => {
      let body, path;
      if (args.kind === "inbox") {
        body = {};
        if (args.title !== undefined) body.title = args.title;
        if (args.done !== undefined) body.done = !!args.done;
        if (args.priority !== undefined) body.priority = args.priority;
        if (args.notes !== undefined) body.notes = args.notes;
        if (args.listId !== undefined) body.list_id = args.listId;
        if (args.reminder !== undefined) {
          try { body.reminder_at = args.reminder === "" ? null : toIso(args.reminder); }
          catch (e) { return { content: [{ type: "text", text: e.message }], isError: true }; }
        }
        if (args.schedule !== undefined) {
          if (args.schedule === null) body.schedule = null;
          else {
            const start_min = toMin(args.schedule.start), end_min = toMin(args.schedule.end);
            if (start_min == null || end_min == null) return { content: [{ type: "text", text: "时间格式不对(需 'HH:mm' 或分钟数)" }], isError: true };
            body.schedule = { date: args.schedule.date, start_min, end_min };
          }
        }
        if (args.dueDate !== undefined) {
          if (args.dueDate === "") { body.due_date = null; body.due_time = null; }
          else {
            body.due_date = args.dueDate;
            // 只定日期/改日期 → 清时刻, 与前端保持一致
            body.due_time = args.dueTime !== undefined ? toMin(args.dueTime) : null;
          }
        } else if (args.dueTime !== undefined) {
          body.due_time = toMin(args.dueTime); // 只改时刻, 保留原日期
        }
        path = `/api/inbox/${args.id}`;
      } else {
        body = {};
        if (args.title !== undefined) body.title = args.title;
        if (args.done !== undefined) body.done = !!args.done;
        if (args.color !== undefined) body.color = args.color;
        if (args.start !== undefined) body.start_min = toMin(args.start);
        if (args.end !== undefined) body.end_min = toMin(args.end);
        if (args.notes !== undefined) body.notes = args.notes;
        path = `/api/blocks/${args.id}`;
      }
      const { status, data } = await api("PATCH", path, body);
      if (status !== 200) return { content: [{ type: "text", text: `修改失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      const extra = args.schedule === null ? "，已取消时间轴安排" : (args.schedule ? `，已排到 ${args.schedule.date}` : "");
      return { content: [{ type: "text", text: `已修改 ${args.kind} #${args.id}${extra}` }] };
    }
  );

  server.tool(
    "plan_delete_task",
    "删除一条任务。kind='inbox' 或 'scheduled'；id 从 plan_view_tasks/plan_view_day 拿到。动手前跟用户确认一句。\n" +
      "· inbox：**不是真删**，进回收站保留 7 天(`plan_view_trash` 看、`plan_restore` 还原)，排期块一起进。\n" +
      "· scheduled：若它是挂在任务上的排期块，这一步只是**取消安排**(任务本身还在收件箱/清单里)；若是独立时间块，则进回收站。",
    { id: z.number().int(), kind: z.enum(["inbox", "scheduled"]) },
    async (args) => {
      const path = args.kind === "inbox" ? `/api/inbox/${args.id}` : `/api/blocks/${args.id}`;
      const { status, data } = await api("DELETE", path);
      if (status !== 200) return { content: [{ type: "text", text: `删除失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      return {
        content: [{
          type: "text",
          text: args.kind === "inbox"
            ? `已把任务 #${args.id} 放进回收站(7 天内可用 plan_restore 还原)`
            : `已移除时间安排 #${args.id}（若它挂在某条任务上，该任务本身仍保留；独立时间块则进了回收站）`,
        }],
      };
    }
  );

  server.tool(
    "plan_view_trash",
    "查看回收站(删掉的任务/独立时间块，保留 7 天)。返回 kind(task|block) + id，供 plan_restore 还原或 plan_purge 彻底删除。",
    {},
    async () => {
      const { status, data } = await api("GET", "/api/trash");
      const items = data && Array.isArray(data.items) ? data.items : [];
      if (status !== 200) return { content: [{ type: "text", text: `获取回收站失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      if (items.length === 0) return { content: [{ type: "text", text: "回收站是空的。" }] };
      const text = items.map((it) =>
        `- [${it.kind}] #${it.id} 「${it.title}」 删除于=${fmtCST(it.deleted_at)} ${it.kind === "block" && isDate(it.date) ? `原定=${it.date} ${fmtMin(it.start_min).trim()}-${fmtMin(it.end_min).trim()} ` : ""}(还剩 ${daysLeft(it.deleted_at, TRASH_DAYS)} 天)`).join("\n");
      return { content: [{ type: "text", text: `${items.length} 条:\n${text}` }] };
    }
  );

  server.tool(
    "plan_restore",
    "从回收站还原一条(7 天内的都能还原)。kind 用 'task' 或 'block'，id 从 plan_view_trash 拿。还原任务时会连它一起被删的排期块一起恢复。",
    { kind: z.enum(["task", "block"]), id: z.number().int() },
    async (args) => {
      const { status, data } = await api("POST", `/api/trash/${args.kind}/${args.id}/restore`);
      if (status !== 200) return { content: [{ type: "text", text: `还原失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      return { content: [{ type: "text", text: `已还原 ${args.kind} #${args.id}` }] };
    }
  );

  server.tool(
    "plan_view_done",
    "查看「已完成」里的任务(勾掉的任务只在这里停留 3 天，之后自动清理)。返回 id 供 plan_update_task(kind:'inbox', done:false) 取消完成、或 plan_purge({kind:'done'}) 彻底删除。",
    {},
    async () => {
      const { status, data } = await api("GET", "/api/done");
      const items = data && Array.isArray(data.items) ? data.items : [];
      if (status !== 200) return { content: [{ type: "text", text: `获取已完成失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      if (items.length === 0) return { content: [{ type: "text", text: "「已完成」里现在是空的。" }] };
      const text = items.map((it) =>
        `- #${it.id} 「${it.title}」 完成于=${fmtCST(it.done_at)} (还剩 ${daysLeft(it.done_at, DONE_DAYS)} 天自动清理)`).join("\n");
      return { content: [{ type: "text", text: `${items.length} 条:\n${text}` }] };
    }
  );

  server.tool(
    "plan_purge",
    "彻底删除一条(不可恢复，动手前务必跟用户确认)。kind：'task'/'block' = 回收站里那条(先 plan_view_trash 拿 id)；'done' = 「已完成」里那条(先 plan_view_done 拿 id，走的是直接永久删除，不经过回收站)。",
    { kind: z.enum(["task", "block", "done"]), id: z.number().int() },
    async (args) => {
      const path = args.kind === "done" ? `/api/done/${args.id}` : `/api/trash/${args.kind}/${args.id}`;
      const { status, data } = await api("DELETE", path);
      if (status !== 200) return { content: [{ type: "text", text: `彻底删除失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      return { content: [{ type: "text", text: `已彻底删除 ${args.kind} #${args.id}(不可恢复)` }] };
    }
  );

  server.tool(
    "plan_empty",
    "清空：what='trash' 清空回收站；what='done' 清空「已完成」。**不可恢复，动手前务必跟用户确认一句**「确定要清空吗」。只影响已删除/已完成的行，正常任务一行不动。",
    { what: z.enum(["trash", "done"]) },
    async (args) => {
      const { status, data } = await api("DELETE", args.what === "trash" ? "/api/trash" : "/api/done");
      if (status !== 200) return { content: [{ type: "text", text: `清空失败(status=${status}): ${JSON.stringify(data)}` }], isError: true };
      const n = args.what === "trash" ? (data?.tasks ?? 0) + (data?.blocks ?? 0) : data?.tasks ?? 0;
      return { content: [{ type: "text", text: `已清空${args.what === "trash" ? "回收站" : "已完成"}，共 ${n} 条(不可恢复)` }] };
    }
  );

  return server;
}

// ---- Streamable HTTP 传输(无状态：每个 POST 独立 server + transport，GET/DELETE 405)----
const app = express();
app.use(express.json());

app.get("/health", (_req, res) => res.json({ ok: true, version: "1.3.0" }));

app.post("/mcp", async (req, res) => {
  const server = buildServer();
  try {
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
    res.on("close", () => {
      try { transport.close(); } catch {}
      try { server.close(); } catch {}
    });
  } catch (e) {
    console.error("MCP request error:", e);
    if (!res.headersSent) {
      res.status(500).json({ jsonrpc: "2.0", error: { code: -32603, message: "Internal server error" }, id: null });
    }
  }
});

app.get("/mcp", (_req, res) => res.status(405).json({ jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed." }, id: null }));
app.delete("/mcp", (_req, res) => res.status(405).json({ jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed." }, id: null }));

const PORT = Number(process.env.PORT || 8787);
app.listen(PORT, "0.0.0.0", () => {
  console.log(`plan-mcp listening on :${PORT} (/mcp, /health)`);
});

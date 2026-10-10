import { createHash } from "node:crypto";
import { db } from "./db.js";
import { getClassesInRange, getUserSchedule } from "./schedule.js";
import {effectiveRequirements} from './ai-requirements.js';
import {
  planningPreferences,
  freeWindows,
  localClock,
} from "./ai-availability.js";

const MAX_DAYS = 14;
const MAX_OBJECTS = 200;
const MAX_CHANGES = 50;
const INTERNAL_DISPLAY_TERM =
  /\b(?:schedule_task|unschedule_task|create_block|create_task|DRAFT_[A-Z_]+|taskId|JSON Schema)\b/i;

function plannerError(code = "AI_PROPOSAL_INVALID") {
  const error = new Error(code);
  error.code = code;
  return error;
}

function validDate(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value))
    return false;
  const date = new Date(`${value}T00:00:00Z`);
  return (
    Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value
  );
}

function rangeDays(startDate, endDate) {
  if (!validDate(startDate) || !validDate(endDate))
    throw plannerError("AI_CONTEXT_INVALID");
  const count =
    (Date.parse(`${endDate}T00:00:00Z`) -
      Date.parse(`${startDate}T00:00:00Z`)) /
      86400000 +
    1;
  if (!Number.isSafeInteger(count) || count < 1 || count > MAX_DAYS) {
    throw plannerError("AI_CONTEXT_INVALID");
  }
  return count;
}

export function planningStateRevision(userId) {
  // Versions cover normal edits, while course JSON and preferences have no
  // version column. Keep this fingerprint private; it is not model input.
  const state = {
    tasks: db.prepare('SELECT id,version,done,deleted_at FROM inbox WHERE user_id=? ORDER BY id').all(userId),
    blocks: db.prepare('SELECT id,version,deleted_at FROM blocks WHERE user_id=? ORDER BY id').all(userId),
    schedule: getUserSchedule(userId),
    preferences: planningPreferences(userId),
  };
  return createHash('sha256').update(JSON.stringify(state)).digest('hex');
}

export function buildPlanningContext(userId, { startDate, endDate, requirements=[], maxCharacters=44000 }) {
  const minuteLabel=minute=>`${String(Math.floor(minute/60)).padStart(2,'0')}:${String(minute%60).padStart(2,'0')}`;
  const timeRange=(start,end)=>`${minuteLabel(start)}–${minuteLabel(end)}`;
  rangeDays(startDate, endDate);
  const taskRows = db
    .prepare(
      `SELECT i.id,i.title,i.notes,i.priority,i.due_date,i.due_time,i.reminder_at,i.estimate_minutes,
      b.start_min,b.end_min
    FROM inbox i LEFT JOIN blocks b ON b.inbox_id=i.id AND b.user_id=i.user_id AND b.deleted_at IS NULL
    WHERE i.user_id=? AND i.deleted_at IS NULL AND i.done=0
    ORDER BY i.priority DESC,i.id ASC`,
    )
    .all(userId);
  const blockRows = db
    .prepare(
      `SELECT id,inbox_id,title,notes,date,start_min,end_min
    FROM blocks WHERE user_id=? AND deleted_at IS NULL AND date BETWEEN ? AND ?
    ORDER BY date,start_min,id`,
    )
    .all(userId, startDate, endDate);
  const schedule = getUserSchedule(userId);
  const courseRows = schedule
    ? getClassesInRange(schedule, startDate, endDate)
    : [];

  const tasks = taskRows.map((row) => ({
    id: row.id,
    title: row.title,
    notes: (row.notes || "").slice(0, 400),
    priority: row.priority,
    dueDate: row.due_date,
    dueTime: row.due_time,
    reminderAt: row.reminder_at,
    estimateMinutes: row.estimate_minutes,
    scheduledMinutes: row.start_min == null ? null : row.end_min - row.start_min,
  }));
  const blocks = blockRows.map((row) => ({
    id: row.id,
    inboxId: row.inbox_id,
    title: row.title,
    notes: (row.notes || "").slice(0, 400),
    date: row.date,
    start: row.start_min,
    end: row.end_min,
    timeRange:timeRange(row.start_min,row.end_min),
  }));
  const courses = courseRows.map((row) => ({
    title: row.title,
    teacher: row.teacher,
    room: row.room,
    date: row.date,
    start: row.start_min,
    end: row.end_min,
    timeRange:timeRange(row.start_min,row.end_min),
  }));

  const boundedTasks = [],
    boundedBlocks = [],
    boundedCourses = [];
  const sources = [tasks, blocks, courses],
    outputs = [boundedTasks, boundedBlocks, boundedCourses];
  let budget = MAX_OBJECTS;
  for (
    let index = 0;
    budget > 0 && sources.some((s) => index < s.length);
    index++
  )
    for (let source = 0; source < sources.length && budget > 0; source++)
      if (index < sources[source].length) {
        outputs[source].push(sources[source][index]);
        budget--;
      }
  const {preferences} = effectiveRequirements(userId,requirements);
  const context = {
    range: { startDate, endDate },
    tasks: boundedTasks,
    blocks: boundedBlocks,
    courses: boundedCourses,
    objectCount: MAX_OBJECTS - budget,
    truncated:
      tasks.length + blocks.length + courses.length > MAX_OBJECTS - budget ||
      taskRows.some((t) => (t.notes?.length ?? 0) > 400) ||
      blockRows.some((b) => (b.notes?.length ?? 0) > 400),
    now: localClock(),
    preferences,
    freeWindows: freeWindows(
      startDate,
      endDate,
      blockRows,
      courseRows,
      preferences,
    ).map(w=>({...w,timeRange:timeRange(w.start,w.end)})),
  };
  if (JSON.stringify(context).length > maxCharacters) {
    for (const item of [...boundedTasks, ...boundedBlocks]) item.notes = "";
    context.truncated = true;
  }
  while (
    JSON.stringify(context).length > maxCharacters &&
    outputs.some((a) => a.length)
  ) {
    const largest = [...outputs].sort((a, b) => b.length - a.length)[0];
    largest.pop();
    context.objectCount--;
    context.truncated = true;
  }
  if (JSON.stringify(context).length > maxCharacters)
    throw plannerError("AI_CONTEXT_INVALID");
  return context;
}

function exactKeys(value, allowed) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  return Object.keys(value).every((key) => allowed.includes(key));
}

function cleanText(value, max, required = false) {
  if (typeof value !== "string") {
    if (!required && value === undefined) return "";
    throw plannerError();
  }
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, " ").trim();
  if ((required && !cleaned) || cleaned.length > max) throw plannerError();
  return cleaned;
}

function cleanDisplayText(value, max, required = false) {
  const cleaned = cleanText(value, max, required);
  if (INTERNAL_DISPLAY_TERM.test(cleaned)) throw plannerError();
  return cleaned;
}

function parseDisplayList(value) {
  if (!Array.isArray(value) || value.length > 10) throw plannerError();
  return value.map((item) => cleanDisplayText(item, 300, true));
}

function validateTime(start, end) {
  if (
    !Number.isInteger(start) ||
    !Number.isInteger(end) ||
    start < 0 ||
    end > 1440 ||
    start >= end ||
    start % 15 !== 0 ||
    end % 15 !== 0 ||
    end - start > 12 * 60
  ) {
    throw plannerError();
  }
}

function blockLabel(block) {
  const time = (minute) =>
    `${String(Math.floor(minute / 60)).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")}`;
  return `${block.date} ${time(block.start)}–${time(block.end)}`;
}

export function parsePlanningProposal(raw, context) {
  if (
    !exactKeys(raw, ["summary", "changes", "questions", "warnings", "draftAction", "requirements"]) ||
    typeof raw.summary !== "string" ||
    !Array.isArray(raw.changes) ||
    raw.changes.length > MAX_CHANGES
  ) {
    throw plannerError();
  }
  const draftAction = raw.draftAction ?? (raw.changes.length ? 'replace' : 'keep');
  if (!['replace', 'keep', 'discard'].includes(draftAction) ||
      (raw.changes.length && draftAction !== 'replace') ||
      (!raw.changes.length && draftAction === 'replace')) throw plannerError();
  const taskIds = new Set(context.tasks.map((task) => task.id));
  const tasksById = new Map(context.tasks.map((task) => [task.id, task]));
  const usedTaskIds = new Set();
  const changes = raw.changes.map((change) => {
    if (!change || typeof change !== "object" || Array.isArray(change))
      throw plannerError();
    if (change.op === 'create_task') {
      if(!exactKeys(change,['op','title','notes','estimateMinutes','dueDate','dueTime','date','start','end','reason']))throw plannerError();
      const title=cleanDisplayText(change.title,300,true);
      if(change.estimateMinutes!==null&&(!Number.isInteger(change.estimateMinutes)||change.estimateMinutes<1||change.estimateMinutes>10080))throw plannerError();
      if(change.dueDate!==null&&!validDate(change.dueDate))throw plannerError();
      if(change.dueTime!==null&&(!change.dueDate||!Number.isInteger(change.dueTime)||change.dueTime<0||change.dueTime>1439))throw plannerError();
      if(change.date===null){if(change.start!==null||change.end!==null)throw plannerError();}
      else {
        if(!validDate(change.date)||change.date<context.range.startDate||change.date>context.range.endDate)throw plannerError();
        validateTime(change.start,change.end);
        if(change.estimateMinutes===null)throw plannerError();
      }
      const key=title.normalize('NFKC').replace(/\s/g,'').toLowerCase();
      if(context.tasks.some(t=>t.title.normalize('NFKC').replace(/\s/g,'').toLowerCase()===key)||
          usedTaskIds.has('new:'+key))throw plannerError();
      usedTaskIds.add('new:'+key);
      return {...change,title,notes:cleanText(change.notes,10000),reason:cleanDisplayText(change.reason,300),before:'新建任务'};
    }
    if (change.op === "schedule_task") {
      if (
        !exactKeys(change, ["op", "taskId", "date", "start", "end", "reason"])
      )
        throw plannerError();
      if (!taskIds.has(change.taskId) || usedTaskIds.has(change.taskId))
        throw plannerError();
      if (
        !validDate(change.date) ||
        change.date < context.range.startDate ||
        change.date > context.range.endDate
      )
        throw plannerError();
      validateTime(change.start, change.end);
      usedTaskIds.add(change.taskId);
      const previous = context.blocks.find(
        (block) => block.inboxId === change.taskId,
      );
      return {
        op: change.op,
        taskId: change.taskId,
        title: tasksById.get(change.taskId).title,
        date: change.date,
        start: change.start,
        end: change.end,
        reason: cleanDisplayText(change.reason, 300),
        before: previous ? blockLabel(previous) : "未安排",
      };
    }
    if (change.op === "unschedule_task") {
      if (
        !exactKeys(change, ["op", "taskId", "reason"]) ||
        !taskIds.has(change.taskId) ||
        usedTaskIds.has(change.taskId)
      )
        throw plannerError();
      usedTaskIds.add(change.taskId);
      const previous = context.blocks.find(
        (block) => block.inboxId === change.taskId,
      );
      return {
        op: change.op,
        taskId: change.taskId,
        title: tasksById.get(change.taskId).title,
        reason: cleanDisplayText(change.reason, 300),
        before: previous ? blockLabel(previous) : "未安排",
      };
    }
    if (change.op === "create_block") {
      if (
        !exactKeys(change, [
          "op",
          "date",
          "start",
          "end",
          "title",
          "notes",
          "color",
          "reason",
        ])
      )
        throw plannerError();
      if (
        !validDate(change.date) ||
        change.date < context.range.startDate ||
        change.date > context.range.endDate
      )
        throw plannerError();
      validateTime(change.start, change.end);
      const color = change.color === undefined ? "#8e7cc3" : change.color;
      if (typeof color !== "string" || !/^#[0-9a-fA-F]{6}$/.test(color))
        throw plannerError();
      return {
        op: change.op,
        date: change.date,
        start: change.start,
        end: change.end,
        title: cleanDisplayText(change.title, 300, true),
        notes: cleanText(change.notes, 10000),
        color,
        reason: cleanDisplayText(change.reason, 300),
        before: "不存在",
      };
    }
    throw plannerError();
  });
  const warnings = parseDisplayList(raw.warnings);
  for (const change of changes) {
    if (change.op === "unschedule_task" || !change.date) continue;
    if (
      context.now &&
      (change.date < context.now.date ||
        (change.date === context.now.date && change.start < context.now.minute))
    )
      throw plannerError();
    const task = tasksById.get(change.taskId);
    if (
      task?.dueDate &&
      (change.date > task.dueDate ||
        (change.date === task.dueDate && change.end > (task.dueTime ?? 1440)))
    )
      warnings.push(
        "有任务安排在截止时间之后，请确认是否需要缩减内容或调整截止日期。",
      );
  }
  const questions = parseDisplayList(raw.questions);
  return {
    summary: cleanDisplayText(raw.summary, 1000, true),
    outcome: changes.length ? "proposal" : questions.length ? "clarification" : "no_change",
    draftAction,
    changes,
    questions,
    warnings: [...new Set(warnings)],
    requirements: raw.requirements ?? [],
  };
}

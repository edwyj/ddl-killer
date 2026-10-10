import { randomUUID } from "node:crypto";
import { db } from "./db.js";
import { saveTask } from "./task-planning.js";
import { getDayClasses } from "./schedule.js";
import { localClock } from "./ai-availability.js";

function coded(code, message) {
  return Object.assign(new Error(message), { code });
}
function validDate(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value))
    return false;
  const date = new Date(`${value}T00:00:00Z`);
  return (
    Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value
  );
}
function checkWindow(date) {
  if (!validDate(date)) throw coded("VALIDATION_FAILED", "日期格式不正确");
  const floor = Date.parse(localClock().date + "T00:00:00Z");
  const delta = (Date.parse(`${date}T00:00:00Z`) - floor) / 86400000;
  if (delta < 0 || delta > 31)
    throw coded("VALIDATION_FAILED", "草案只能安排未来 31 天");
}
function checkTime(start, end) {
  if (
    !Number.isInteger(start) ||
    !Number.isInteger(end) ||
    start < 0 ||
    end > 1440 ||
    start >= end
  ) {
    throw coded("VALIDATION_FAILED", "起止时间必须位于同一天且结束晚于开始");
  }
}
function publicDraft(row) {
  const undone=row.status==='applied' && db.prepare("SELECT 1 FROM ai_plan_applications WHERE draft_id=? AND user_id=? AND status='undone'").get(row.id,row.user_id);
  return {
    id: row.id,
    status: undone?'undone':row.status,
    changes: JSON.parse(row.changes_json),
    warnings: JSON.parse(row.warnings_json),
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    appliedAt: row.applied_at,
    ...(row.result_json ? { result: JSON.parse(row.result_json) } : {}),
    ...(row.ai_policy_json ? {requirements: JSON.parse(row.ai_policy_json).requirements ?? []} : {}),
  };
}
function overlaps(aStart, aEnd, bStart, bEnd) {
  return aStart < bEnd && bStart < aEnd;
}
export function calendarWarnings(userId, changes) {
  const warnings = [],
    moved = new Set(
      changes.filter((c) => c.taskId != null).map((c) => c.taskId),
    );
  const candidates = changes.filter((c) => c.op !== "unschedule_task" && c.date);
  const scheduleRow = db
    .prepare("SELECT json FROM schedules WHERE user_id=?")
    .get(userId);
  const schedule = scheduleRow ? JSON.parse(scheduleRow.json) : null;
  for (let index = 0; index < candidates.length; index++) {
    const change = candidates[index];
    const existing = db
      .prepare(
        "SELECT id,inbox_id,start_min,end_min,version FROM blocks WHERE user_id=? AND date=? AND deleted_at IS NULL",
      )
      .all(userId, change.date)
      .filter((b) => !moved.has(b.inbox_id));
    for (const block of existing)
      if (overlaps(change.start, change.end, block.start_min, block.end_min))
        warnings.push({
          code: "TIME_OVERLAP",
          severity: "warning",
          key: `${index}:${block.id}:${block.version}`,
          message: `${change.date} 的安排与现有任务重叠`,
        });
    for (let other = 0; other < index; other++) {
      const prior = candidates[other];
      if (
        prior.date === change.date &&
        overlaps(change.start, change.end, prior.start, prior.end)
      )
        warnings.push({
          code: "TIME_OVERLAP",
          severity: "warning",
          key: `batch:${other}:${index}`,
          message: `${change.date} 的新安排之间有重叠`,
        });
    }
    const classes = schedule ? getDayClasses(schedule, change.date) : [];
    if (
      classes.some((c) =>
        overlaps(change.start, change.end, c.start_min, c.end_min),
      )
    )
      warnings.push({
        code: "COURSE_CONFLICT",
        severity: "blocking",
        message: `${change.date} 的安排与课程冲突`,
      });
  }
  return warnings;
}

export function createDraft(userId, clientId, changes, {policy=null}={}) {
  db.prepare(
    "UPDATE schedule_drafts SET status='expired' WHERE status='pending' AND expires_at<=?",
  ).run(new Date().toISOString());
  if (
    !Array.isArray(changes) ||
    changes.length < (clientId === "ai-planner" ? 0 : 1) ||
    changes.length > 100
  ) {
    throw coded("VALIDATION_FAILED", "草案需要 1–100 项变更");
  }
  const normalized = [];
  const snapshot = [];
  const seen = new Set();
  for (const raw of changes) {
    if (
      !raw ||
      !["schedule_task", "unschedule_task", "create_block", ...(clientId==='ai-planner'?['create_task']:[])].includes(raw.op)
    ) {
      throw coded("VALIDATION_FAILED", "不支持的草案操作");
    }
    if(raw.op==='create_task') {
      if(typeof raw.title!=='string'||!raw.title.trim()||raw.title.length>300||
        (raw.estimateMinutes!==null&&(!Number.isInteger(raw.estimateMinutes)||raw.estimateMinutes<1||raw.estimateMinutes>10080))||
        (raw.dueDate!==null&&!validDate(raw.dueDate))||
        (raw.dueTime!==null&&(!raw.dueDate||!Number.isInteger(raw.dueTime)||raw.dueTime<0||raw.dueTime>1439)))
        throw coded('VALIDATION_FAILED','请检查新任务的标题、预计用时和截止时间');
      if(raw.date!==null){checkWindow(raw.date);checkTime(raw.start,raw.end);if(raw.estimateMinutes===null)throw coded('VALIDATION_FAILED','请提供预计用时');}
      else if(raw.start!==null||raw.end!==null)throw coded('VALIDATION_FAILED','请检查新任务的安排');
      normalized.push({op:raw.op,title:raw.title.trim(),notes:raw.notes||'',estimateMinutes:raw.estimateMinutes,
        dueDate:raw.dueDate,dueTime:raw.dueTime,date:raw.date,start:raw.start,end:raw.end,
        reason:raw.reason||'',before:'新建任务'});
    } else if (raw.op === "create_block") {
      checkWindow(raw.date);
      checkTime(raw.start, raw.end);
      if (typeof raw.title !== "string" || !raw.title.trim())
        throw coded("VALIDATION_FAILED", "独立时间块需要标题");
      normalized.push({
        op: raw.op,
        date: raw.date,
        start: raw.start,
        end: raw.end,
        title: raw.title.trim(),
        notes: raw.notes || "",
        color: raw.color || "#8e7cc3",
        ...(raw.reason ? { reason: raw.reason } : {}),
        ...(raw.before ? { before: raw.before } : {}),
      });
    } else {
      if (!Number.isSafeInteger(raw.taskId))
        throw coded("VALIDATION_FAILED", "taskId 不正确");
      const key = `task:${raw.taskId}`;
      if (seen.has(key))
        throw coded("VALIDATION_FAILED", "同一任务不能出现多个互斥操作");
      seen.add(key);
      const task = db
        .prepare(
          "SELECT id,version,title FROM inbox WHERE id=? AND user_id=? AND deleted_at IS NULL",
        )
        .get(raw.taskId, userId);
      if (!task) throw coded("OBJECT_NOT_FOUND", "任务不存在");
      const block = db
        .prepare("SELECT id,version FROM blocks WHERE inbox_id=? AND user_id=?")
        .get(raw.taskId, userId);
      snapshot.push({
        taskId: task.id,
        taskVersion: task.version,
        blockId: block?.id ?? null,
        blockVersion: block?.version ?? null,
      });
      if (raw.op === "schedule_task") {
        checkWindow(raw.date);
        checkTime(raw.start, raw.end);
        normalized.push({
          op: raw.op,
          taskId: raw.taskId,
          title: raw.title || task.title,
          date: raw.date,
          start: raw.start,
          end: raw.end,
          ...(raw.reason ? { reason: raw.reason } : {}),
          ...(raw.before ? { before: raw.before } : {}),
        });
      } else
        normalized.push({
          op: raw.op,
          taskId: raw.taskId,
          title: raw.title || task.title,
          ...(raw.reason ? { reason: raw.reason } : {}),
          ...(raw.before ? { before: raw.before } : {}),
        });
    }
  }

  const warnings = calendarWarnings(userId, normalized);
  if(clientId==='ai-planner')for(const change of normalized)change.id=randomUUID();
  const now = new Date();
  const row = {
    id: randomUUID(),
    user_id: userId,
    created_by_client_id: clientId,
    status: "pending",
    changes_json: JSON.stringify(normalized),
    snapshot_json: JSON.stringify(snapshot),
    warnings_json: JSON.stringify(warnings),
    created_at: now.toISOString(),
    expires_at: new Date(now.getTime() + 30 * 60000).toISOString(),
  };
  db.prepare(
    `INSERT INTO schedule_drafts
    (id,user_id,created_by_client_id,status,changes_json,snapshot_json,warnings_json,created_at,expires_at)
    VALUES (?,?,?,?,?,?,?,?,?)`,
  ).run(
    row.id,
    row.user_id,
    row.created_by_client_id,
    row.status,
    row.changes_json,
    row.snapshot_json,
    row.warnings_json,
    row.created_at,
    row.expires_at,
  );
  if(policy) {
    row.ai_policy_json=JSON.stringify(policy);
    db.prepare('UPDATE schedule_drafts SET ai_policy_json=? WHERE id=? AND user_id=?').run(row.ai_policy_json,row.id,userId);
  }
  return publicDraft({ ...row, applied_at: null, result_json: null });
}

export function getDraft(userId, id) {
  const row = db
    .prepare("SELECT * FROM schedule_drafts WHERE id=? AND user_id=?")
    .get(id, userId);
  if (!row) throw coded("OBJECT_NOT_FOUND", "草案不存在");
  if (row.status === "pending" && Date.parse(row.expires_at) <= Date.now()) {
    db.prepare("UPDATE schedule_drafts SET status='expired' WHERE id=?").run(
      id,
    );
    row.status = "expired";
  }
  return publicDraft(row);
}

export function discardDraft(userId, id) {
  const draft = getDraft(userId, id);
  if (draft.status === "discarded") return draft;
  if (draft.status !== "pending")
    throw coded("VALIDATION_FAILED", `不能丢弃 ${draft.status} 草案`);
  db.prepare(
    "UPDATE schedule_drafts SET status='discarded' WHERE id=? AND user_id=?",
  ).run(id, userId);
  return getDraft(userId, id);
}

export function applyDraft(userId, clientId, id, options = {}) {
  const row = db
    .prepare("SELECT * FROM schedule_drafts WHERE id=? AND user_id=?")
    .get(id, userId);
  if (!row) throw coded("OBJECT_NOT_FOUND", "草案不存在");
  if(row.created_by_client_id==='ai-planner'&&!options.beforeApply)
    throw coded('DRAFT_BLOCKED','请在 AI 助手中确认本次要求并应用方案');
  const allChanges = JSON.parse(row.changes_json);
  let selected = null;
  if (options.selectedChangeIds !== undefined) {
    const ids = options.selectedChangeIds;
    if (!Array.isArray(ids) || !ids.length || new Set(ids).size !== ids.length ||
        ids.some(id => typeof id !== 'string' || !allChanges.some(c => c.id === id)))
      throw coded('VALIDATION_FAILED', '请选择方案中需要应用的安排');
    selected = [...ids].sort();
  }
  if (row.status === "applied") {
    const result = JSON.parse(row.result_json);
    const requested = selected ?? allChanges.map(c => c.id).sort();
    if (result.selectedChangeIds && JSON.stringify(requested) !== JSON.stringify(result.selectedChangeIds))
      throw coded('DRAFT_STALE', '这份方案已经应用，请使用剩余方案');
    return result;
  }
  if (row.status === "discarded")
    throw coded("DRAFT_ALREADY_DISCARDED", "草案已丢弃");
  if (row.status !== "pending" || Date.parse(row.expires_at) <= Date.now()) {
    db.prepare(
      "UPDATE schedule_drafts SET status='expired' WHERE id=? AND status='pending'",
    ).run(id);
    throw coded("DRAFT_EXPIRED", "草案已过期");
  }
  const warnings = JSON.parse(row.warnings_json);
  const changes = selected ? allChanges.filter(c => selected.includes(c.id)) : allChanges;
  if (changes.length === 0)
    throw coded("DRAFT_BLOCKED", "先补充信息，再生成可以应用的安排");
  const snapshots = JSON.parse(row.snapshot_json).filter(s => changes.some(c => c.taskId === s.taskId));
  db.exec("BEGIN IMMEDIATE");
  try {
    if (db.prepare('SELECT status FROM schedule_drafts WHERE id=?').get(id)?.status !== 'pending')
      throw coded('DRAFT_STALE', '这份方案已经发生变化，请刷新后重试');
    options.beforeApply?.({changes, allChanges});
    const fresh = calendarWarnings(userId, changes);
    if (fresh.some((w) => w.severity === "blocking"))
      throw coded("DRAFT_BLOCKED", "当前日程存在课程冲突，请重新调整");
    const known = new Set(
      warnings.filter((w) => w.code === "TIME_OVERLAP").map((w) => w.key),
    );
    if (!options.beforeApply && fresh.some((w) => w.code === "TIME_OVERLAP" && !known.has(w.key)))
      throw coded(
        "DRAFT_STALE",
        "日程发生变化，新安排与其他任务重叠，请重新生成",
      );
    if (clientId === "ai-planner") {
      const clock = localClock();
      if (
        changes.some(
          (c) =>
            c.op !== "unschedule_task" && c.date &&
            (c.date < clock.date ||
              (c.date === clock.date && c.start < clock.minute)),
        )
      )
        throw coded("DRAFT_STALE", "安排时间已过去，请重新生成");
    }
    for (const expected of snapshots) {
      const task = db
        .prepare(
          "SELECT version FROM inbox WHERE id=? AND user_id=? AND deleted_at IS NULL",
        )
        .get(expected.taskId, userId);
      const block = db
        .prepare("SELECT id,version FROM blocks WHERE inbox_id=? AND user_id=?")
        .get(expected.taskId, userId);
      if (
        !task ||
        task.version !== expected.taskVersion ||
        (block?.id ?? null) !== expected.blockId ||
        (block?.version ?? null) !== expected.blockVersion
      ) {
        throw coded("DRAFT_STALE", "任务或排期已在其他设备发生变化");
      }
    }
    const createdBlockIds = [],createdTaskIds=[];
    for (const change of changes) {
      if(change.op==='create_task') {
        const task=saveTask(userId,null,{title:change.title,notes:change.notes,estimate_minutes:change.estimateMinutes,
          due_date:change.dueDate,due_time:change.dueTime,
          ...(change.date?{schedule:{date:change.date,start_min:change.start,end_min:change.end}}:{})});
        createdTaskIds.push(task.id);
      } else if (change.op === "schedule_task")
        saveTask(userId, change.taskId, {
          schedule: {
            date: change.date,
            start_min: change.start,
            end_min: change.end,
          },
        });
      else if (change.op === "unschedule_task")
        saveTask(userId, change.taskId, { schedule: null });
      else {
        const inserted = db.prepare(
          `INSERT INTO blocks(user_id,date,start_min,end_min,title,color,notes,source)
        VALUES (?,?,?,?,?,?,?,'mcp')`,
        ).run(
          userId,
          change.date,
          change.start,
          change.end,
          change.title,
          change.color,
          change.notes,
        );
        createdBlockIds.push(Number(inserted.lastInsertRowid));
      }
    }
    const result = { draftId: id, applied: changes.length,
      ...options.afterApply?.({changes, allChanges, createdBlockIds,createdTaskIds}) };
    const now = new Date().toISOString();
    db.prepare(
      `UPDATE schedule_drafts SET status='applied',applied_at=?,result_json=?
      WHERE id=? AND user_id=?`,
    ).run(now, JSON.stringify(result), id, userId);
    db.prepare(
      `INSERT INTO mcp_audit_log
      (user_id,client_id,tool_name,result_code,object_ids_json,created_at)
      VALUES (?,?,?,?,?,?)`,
    ).run(
      userId,
      clientId,
      "plan_apply_schedule_draft",
      "OK",
      JSON.stringify(changes.map((change) => change.taskId).filter(Boolean)),
      now,
    );
    db.exec("COMMIT");
    return result;
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

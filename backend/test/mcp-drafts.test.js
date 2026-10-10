import test from "node:test";
import assert from "node:assert/strict";

process.env.DB_PATH = ":memory:";
process.env.JWT_SECRET = "draft-test-jwt-secret-at-least-32-chars";
process.env.MCP_TOKEN_PEPPER = "draft-test-pepper-at-least-32-characters";

const { db } = await import("../src/db.js");
const { createUserWithDefaultLists } = await import("../src/default-lists.js");
const { saveTask } = await import("../src/task-planning.js");
const { createDraft, getDraft, applyDraft, discardDraft } = await import(
  "../src/mcp-drafts.js"
);
const { createApp } = await import("../src/app.js");
const { issueMcpInternalSession } = await import("../src/security.js");

const uid = createUserWithDefaultLists("draft_owner", "unused");
const other = createUserWithDefaultLists("draft_other", "unused");
const client = "client-draft";
const taskA = saveTask(uid, null, { title: "A" });
const taskB = saveTask(uid, null, { title: "B" });
const otherTask = saveTask(other, null, { title: "private" });
const futureDate = (days) => {
  const date = new Date();
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
};

test.after(() => db.close());

test("whole-batch validation ignores moved old positions and detects new mutual overlaps", () => {
  const date = futureDate(10);
  const a = saveTask(uid, null, {
    title: "swap-A",
    schedule: { date, start_min: 600, end_min: 660 },
  });
  const b = saveTask(uid, null, {
    title: "swap-B",
    schedule: { date, start_min: 720, end_min: 780 },
  });
  const swap = createDraft(uid, client, [
    schedule(a.id, 720, date),
    schedule(b.id, 600, date),
  ]);
  assert.equal(
    swap.warnings.filter((w) => w.code === "TIME_OVERLAP").length,
    0,
  );
  const overlap = createDraft(uid, client, [
    schedule(a.id, 900, date),
    schedule(b.id, 930, date),
  ]);
  assert.ok(overlap.warnings.some((w) => w.code === "TIME_OVERLAP"));
});
test("apply rechecks courses introduced after draft creation", () => {
  const date = futureDate(11);
  const task = saveTask(uid, null, { title: "course-race" });
  const draft = createDraft(uid, client, [schedule(task.id, 600, date)]);
  const weekday = new Date(`${date}T00:00:00Z`).getUTCDay() || 7;
  db.prepare("INSERT OR REPLACE INTO schedules(user_id,json) VALUES(?,?)").run(
    uid,
    JSON.stringify({
      semester_start: date,
      period_to_block: { 1: 1 },
      period_times: { 1: ["10:00", "11:00"] },
      courses: [
        {
          course_id: "new",
          name: "临时课程",
          slots: [{ weekday, weeks: [1], periods: [1] }],
        },
      ],
    }),
  );
  assert.throws(() => applyDraft(uid, client, draft.id), {
    code: "DRAFT_BLOCKED",
  });
  assert.equal(
    db.prepare("SELECT count(*) n FROM blocks WHERE inbox_id=?").get(task.id).n,
    0,
  );
  db.prepare("DELETE FROM schedules WHERE user_id=?").run(uid);
});

const schedule = (taskId, start, date = futureDate(5)) => ({
  op: "schedule_task",
  taskId,
  date,
  start,
  end: start + 60,
});

test("draft applies atomically and repeated apply is idempotent", () => {
  const draft = createDraft(uid, client, [
    schedule(taskA.id, 600),
    schedule(taskB.id, 720),
  ]);
  assert.equal(getDraft(uid, draft.id).status, "pending");
  const first = applyDraft(uid, client, draft.id);
  const second = applyDraft(uid, client, draft.id);
  assert.deepEqual(second, first);
  assert.equal(first.applied, 2);
  assert.equal(
    db
      .prepare("SELECT count(*) n FROM blocks WHERE inbox_id IN (?,?)")
      .get(taskA.id, taskB.id).n,
    2,
  );
});

test("stale draft applies nothing", () => {
  const c = saveTask(uid, null, { title: "C" });
  const d = saveTask(uid, null, { title: "D" });
  const draft = createDraft(uid, client, [
    schedule(c.id, 840),
    schedule(d.id, 960),
  ]);
  saveTask(uid, d.id, { title: "changed" });
  assert.throws(
    () => applyDraft(uid, client, draft.id),
    (error) => error.code === "DRAFT_STALE",
  );
  assert.equal(
    db
      .prepare("SELECT count(*) n FROM blocks WHERE inbox_id IN (?,?)")
      .get(c.id, d.id).n,
    0,
  );
});

test("invalid shapes, duplicate objects, oversized drafts and cross-user IDs are rejected", () => {
  const invalid = [
    [{ ...schedule(taskA.id, 60), end: 60 }],
    [{ ...schedule(taskA.id, 1380), end: 60 }],
    [schedule(taskA.id, 60, "2030-02-30")],
    [schedule(taskA.id, 60), schedule(taskA.id, 180)],
    Array.from({ length: 101 }, (_, i) => ({
      op: "create_block",
      date: futureDate(5),
      start: i,
      end: i + 1,
      title: `x${i}`,
    })),
    [schedule(otherTask.id, 60)],
  ];
  for (const changes of invalid)
    assert.throws(() => createDraft(uid, client, changes));
});

test("overlap is a warning, discard is idempotent and blocks apply", () => {
  saveTask(uid, taskA.id, {
    schedule: { date: futureDate(6), start_min: 600, end_min: 660 },
  });
  const draft = createDraft(uid, client, [
    {
      op: "create_block",
      date: futureDate(6),
      start: 630,
      end: 690,
      title: "overlap",
    },
  ]);
  assert.ok(draft.warnings.some((warning) => warning.code === "TIME_OVERLAP"));
  assert.equal(discardDraft(uid, draft.id).status, "discarded");
  assert.equal(discardDraft(uid, draft.id).status, "discarded");
  assert.throws(
    () => applyDraft(uid, client, draft.id),
    (error) => error.code === "DRAFT_ALREADY_DISCARDED",
  );
});

test("course conflicts block apply and expired drafts cannot be applied", () => {
  const date = futureDate(8);
  const weekday = new Date(`${date}T00:00:00Z`).getUTCDay() || 7;
  db.prepare("INSERT OR REPLACE INTO schedules(user_id,json) VALUES (?,?)").run(
    uid,
    JSON.stringify({
      semester_start: date,
      period_to_block: { 1: "1" },
      period_times: { 1: ["10:00", "11:00"] },
      courses: [
        {
          course_id: "course-1",
          name: "课程",
          slots: [{ weekday, weeks: [1], periods: [1] }],
        },
      ],
    }),
  );
  const blocked = createDraft(uid, client, [
    { op: "create_block", date, start: 630, end: 690, title: "冲突" },
  ]);
  assert.ok(
    blocked.warnings.some(
      (warning) =>
        warning.code === "COURSE_CONFLICT" && warning.severity === "blocking",
    ),
  );
  assert.throws(
    () => applyDraft(uid, client, blocked.id),
    (error) => error.code === "DRAFT_BLOCKED",
  );

  const expiring = createDraft(uid, client, [
    {
      op: "create_block",
      date: futureDate(9),
      start: 720,
      end: 780,
      title: "过期",
    },
  ]);
  db.prepare(
    "UPDATE schedule_drafts SET expires_at='2000-01-01T00:00:00.000Z' WHERE id=?",
  ).run(expiring.id);
  assert.equal(getDraft(uid, expiring.id).status, "expired");
  assert.throws(
    () => applyDraft(uid, client, expiring.id),
    (error) => error.code === "DRAFT_EXPIRED",
  );
});

test("internal draft REST endpoints enforce identity and apply scope", async () => {
  const clientId = "client-rest-draft";
  const expires = new Date(Date.now() + 3600000).toISOString();
  db.prepare(
    `INSERT INTO mcp_clients
    (id,user_id,name,client_type,scopes_json,expires_at,created_at)
    VALUES (?,?,?,'pat',?,?,?)`,
  ).run(
    clientId,
    uid,
    "REST draft",
    JSON.stringify(["mcp:read", "mcp:schedule:draft", "mcp:schedule:apply"]),
    expires,
    new Date().toISOString(),
  );
  const principal = {
    userId: uid,
    clientId,
    scopes: ["mcp:read", "mcp:schedule:draft", "mcp:schedule:apply"],
  };
  const token = issueMcpInternalSession(principal, "draft_owner");
  const noApplyToken = issueMcpInternalSession(
    { ...principal, scopes: ["mcp:read", "mcp:schedule:draft"] },
    "draft_owner",
  );
  const server = createApp().listen(0, "127.0.0.1");
  await new Promise((resolve) => server.once("listening", resolve));
  const call = async (path, method, body, bearer = token) => {
    const response = await fetch(
      `http://127.0.0.1:${server.address().port}${path}`,
      {
        method,
        headers: {
          authorization: `Bearer ${bearer}`,
          "content-type": "application/json",
        },
        ...(body ? { body: JSON.stringify(body) } : {}),
      },
    );
    return { status: response.status, body: await response.json() };
  };
  try {
    const task = saveTask(uid, null, { title: "REST task" });
    const made = await call("/api/internal/mcp/drafts", "POST", {
      changes: [schedule(task.id, 1080)],
    });
    assert.equal(made.status, 201);
    assert.equal(
      (await call(`/api/internal/mcp/drafts/${made.body.id}`, "GET")).status,
      200,
    );
    assert.equal(
      (
        await call(
          `/api/internal/mcp/drafts/${made.body.id}/apply`,
          "POST",
          null,
          noApplyToken,
        )
      ).status,
      403,
    );
    assert.equal(
      (await call(`/api/internal/mcp/drafts/${made.body.id}/apply`, "POST"))
        .status,
      200,
    );
    assert.equal(
      db
        .prepare(
          "SELECT count(*) n FROM mcp_audit_log WHERE tool_name='plan_apply_schedule_draft' AND client_id=?",
        )
        .get(clientId).n,
      1,
    );
  } finally {
    await new Promise((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
});

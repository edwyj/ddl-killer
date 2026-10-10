import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import test from "node:test";

process.env.DB_PATH = ":memory:";
process.env.JWT_SECRET = "ai-session-test-secret-at-least-32-chars";
process.env.AI_KEY_ENCRYPTION_KEYS = `v1:${randomBytes(32).toString("base64")}`;
process.env.AI_FEATURE_ENABLED = "true";
process.env.AI_HOSTED_ENABLED = "true";
process.env.AI_HOSTED_DAILY_LIMIT = "3";
process.env.AI_HOSTED_GLOBAL_DAILY_LIMIT = "100";
process.env.AI_HOSTED_DEEPSEEK_KEY = "sk-SENTINEL-HOSTED-SECRET";
process.env.AI_FAILURE_COOLDOWN_SECONDS = "0";

const { db } = await import("../src/db.js");
const { createApp } = await import("../src/app.js");
const { createUserWithDefaultLists } = await import("../src/default-lists.js");
const { saveTask } = await import("../src/task-planning.js");
const { saveProviderConfig } = await import("../src/ai-credentials.js");
const bcrypt = (await import("bcryptjs")).default;

const owner = createUserWithDefaultLists(
  "session_owner",
  bcrypt.hashSync("Session-owner-123", 10),
);
const other = createUserWithDefaultLists(
  "session_other",
  bcrypt.hashSync("Session-other-123", 10),
);
const byok = createUserWithDefaultLists(
  "session_byok",
  bcrypt.hashSync("Session-byok-123", 10),
);
const task = saveTask(owner, null, { title: "写报告", priority: 3,estimate_minutes:60 });
const byokTask = saveTask(byok, null, { title: "BYOK 任务",estimate_minutes:60 });

const dateAt = (offset) => {
  const date = new Date();
  date.setUTCDate(date.getUTCDate() + offset);
  return date.toISOString().slice(0, 10);
};
const startDate = dateAt(1);
const endDate = dateAt(4);

let behavior = "valid";
let releaseDelayed, startedDelayed;
const generated = [];
const proposalFor = (taskId, start = 600) => ({
  summary: "安排完成",
  changes: [
    { op: "schedule_task", taskId, date: dateAt(2), start, end: start + 60 },
  ],
  questions: [],
  warnings: [],
});
const generate = async (args) => {
  generated.push(args);
  if (behavior === "no_change") return {
    value: { summary: "好的，保持现有安排。", changes: [], questions: [], warnings: [] },
    usage: { promptTokens: 20, completionTokens: 8 },
  };
  if (behavior === "questions")
    return {
      value: {
        summary: "先聊聊你的时间",
        changes: [],
        questions: ["想安排多久？"],
        warnings: [],
      },
      usage: { promptTokens: 20, completionTokens: 8 },
    };
  if (behavior === "delayed") {
    startedDelayed?.();
    await new Promise((resolve) => {
      const prior = releaseDelayed;
      releaseDelayed = () => {
        prior?.();
        resolve();
      };
    });
  }
  if (behavior === "timeout")
    throw Object.assign(new Error("contains sk-SENTINEL-HOSTED-SECRET"), {
      code: "AI_PROVIDER_TIMEOUT",
    });
  if (behavior === "invalid")
    return { value: { changes: [{ op: "steal_key" }] }, usage: {} };
  const payload = JSON.parse(
    args.messages.find((message) => message.role === "user").content,
  );
  const target = payload.context.tasks[0].id;
  if(behavior==='partial')return {value:{...proposalFor(target,600),changes:payload.context.tasks.slice(0,2).map((t,i)=>({...proposalFor(t.id,600+i*150).changes[0]}))},usage:{promptTokens:20,completionTokens:8}};
  const start = behavior === "adjusted" ? 750 : 600;
  if (behavior==='requirements') return {
    value:{...proposalFor(target,start),requirements:[{kind:'end_minute',taskId:null,value:1320,source:'22点前结束'}]},
    usage:{promptTokens:20,completionTokens:8},
  };
  return {
    value: proposalFor(target, start),
    usage: { promptTokens: 20, completionTokens: 8 },
  };
};

const app = createApp({ ai: { generate } });
const server = app.listen(0, "127.0.0.1");
await new Promise((resolve) => server.once("listening", resolve));
test.after(() => {
  server.close();
  db.close();
});
const base = `http://127.0.0.1:${server.address().port}`;

async function call(path, method = "GET", body, token) {
  const response = await fetch(base + path, {
    method,
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  return { status: response.status, data: await response.json() };
}
const login = async (username, password) =>
  (await call("/api/auth/login", "POST", { username, password })).data.token;
const newSession = (token, message = "帮我安排报告") =>
  call(
    "/api/ai/sessions",
    "POST",
    {
      startDate,
      endDate,
      message,
    },
    token,
  );

test('source-backed requirements survive more than six turns and history restoration',async()=>{
  const name='sticky_requirements',password='Sticky-requirements-123';
  const uid=createUserWithDefaultLists(name,bcrypt.hashSync(password,10));
  saveTask(uid,null,{title:'合成会话任务',estimate_minutes:60});
  const token=await login(name,password);
  behavior='requirements';
  const first=await newSession(token,'22点前结束');
  assert.equal(first.status,201);assert.equal(first.data.requirements[0].source,'22点前结束');
  behavior='no_change';
  for(let i=0;i<7;i++)assert.equal((await call(`/api/ai/sessions/${first.data.sessionId}/turns`,'POST',{message:'好的，继续说明'},token)).status,200);
  const payload=JSON.parse(generated.at(-1).messages.find(m=>m.role==='user').content);
  assert.equal(payload.requirements[0].value,1320);
  const restored=await call(`/api/ai/sessions/${first.data.sessionId}`,'GET',undefined,token);
  assert.equal(restored.data.requirements[0].value,1320);
});

test("clarification and no-change turns retain bounded user history and do not spend schedule allowance", async () => {
  const name = "terminal_reply_owner", password = "Terminal-reply-123";
  const uid = createUserWithDefaultLists(name, bcrypt.hashSync(password, 10));
  const token = await login(name, password);
  behavior = "questions";
  const first = await newSession(token, "保持今晚原来的安排");
  assert.equal(first.status, 201);
  assert.equal(first.data.outcome, "clarification");
  assert.equal(first.data.quota.used, 0);
  behavior = "no_change";
  const second = await call(`/api/ai/sessions/${first.data.sessionId}/turns`, "POST",
    { message: "不用确认，不需要调整" }, token);
  assert.equal(second.status, 200);
  assert.equal(second.data.outcome, "no_change");
  assert.equal(second.data.quota.used, 0);
  assert.equal(second.data.quota.reserved, 0);
  const payload = JSON.parse(generated.at(-1).messages.at(-1).content);
  assert.equal(payload.history[0].input, "保持今晚原来的安排");
  assert.equal(payload.history[0].draftStatus, "pending");
  assert.equal(payload.previousStatus, "pending");
  assert.equal(db.prepare("SELECT count(*) n FROM blocks WHERE user_id=?").get(uid).n, 0);
  assert.equal(db.prepare("SELECT count(*) n FROM ai_generation_attempts WHERE user_id=?").get(uid).n, 2);
});

test("AI request rate limit reports a machine-readable cooldown without calling the provider", async () => {
  const name = "rate_reply_owner", password = "Rate-reply-owner-123";
  const uid = createUserWithDefaultLists(name, bcrypt.hashSync(password, 10));
  const token = await login(name, password);
  behavior = "questions";
  // Invalid input still counts toward abuse protection, but makes no model calls.
  for (let i = 0; i < 20; i++) await newSession(token, " ");
  const before = generated.length;
  const response = await newSession(token);
  assert.equal(response.status, 429);
  assert.equal(response.data.code, "AI_RATE_LIMITED");
  assert.ok(response.data.retryAfterSeconds > 0 && response.data.retryAfterSeconds <= 900);
  assert.equal(generated.length, before);
  assert.equal(db.prepare("SELECT count(*) n FROM ai_quota_reservations WHERE user_id=?").get(uid).n, 0);
});

test("long conversations trim older turns while retaining recent user answers and account boundaries", async () => {
  const name = "bounded_history_owner", password = "Bounded-history-123";
  createUserWithDefaultLists(name, bcrypt.hashSync(password, 10));
  const token = await login(name, password);
  behavior = "questions";
  const first = await newSession(token, "本轮独有要求-0");
  assert.equal(first.status, 201);
  for (let i = 1; i <= 7; i++) {
    const response = await call(`/api/ai/sessions/${first.data.sessionId}/turns`, "POST",
      { message: `本轮独有要求-${i} ` + "补充说明".repeat(450) }, token);
    assert.equal(response.status, 200);
  }
  const payload = JSON.parse(generated.at(-1).messages.at(-1).content);
  assert.ok(payload.history.length > 0 && payload.history.length <= 6);
  assert.ok(JSON.stringify(payload.history).length <= 10020);
  assert.ok(payload.history.at(-1).input.startsWith("本轮独有要求-6"));
  assert.ok(payload.history.every((turn) => turn.input.startsWith("本轮独有要求-")));
  assert.ok(JSON.stringify(generated.at(-1).messages).length <= 60000);
});

test("provider failure refunds allowance and advertises the same cooldown that the next request enforces", async () => {
  const name = "cooldown_reply_owner", password = "Cooldown-reply-123";
  const uid = createUserWithDefaultLists(name, bcrypt.hashSync(password, 10));
  const token = await login(name, password);
  behavior = "timeout";
  process.env.AI_FAILURE_COOLDOWN_SECONDS = "30";
  try {
    const before = generated.length;
    const first = await newSession(token);
    assert.equal(first.status, 502);
    assert.equal(first.data.retryAfterSeconds, 30);
    const second = await newSession(token);
    assert.equal(second.status, 429);
    assert.equal(second.data.code, "AI_RETRY_LATER");
    assert.ok(second.data.retryAfterSeconds > 0 && second.data.retryAfterSeconds <= 30);
    assert.equal(generated.length - before, 1);
    assert.equal(db.prepare("SELECT used FROM ai_quota_daily WHERE user_id=?").get(uid).used, 0);
    assert.equal(db.prepare("SELECT count(*) n FROM ai_generation_attempts WHERE user_id=?").get(uid).n, 1);
  } finally {
    process.env.AI_FAILURE_COOLDOWN_SECONDS = "0";
  }
});

test("questions-only turns preserve conversation without an applicable schedule and cap output", async () => {
  const uid = createUserWithDefaultLists(
    "question_owner",
    bcrypt.hashSync("Question-owner-123", 10),
  );
  const token = await login("question_owner", "Question-owner-123");
  behavior = "questions";
  const response = await newSession(token, "帮我安排一下");
  assert.equal(response.status, 201);
  assert.equal(response.data.draft.changes.length, 0);
  assert.equal(response.data.questions.length, 1);
  assert.ok(generated.at(-1).maxTokens <= 4096);
  assert.equal(
    (
      await call(
        `/api/ai/drafts/${response.data.draft.id}/apply`,
        "POST",
        {},
        token,
      )
    ).status,
    409,
  );
  assert.equal(
    db.prepare("SELECT count(*) n FROM blocks WHERE user_id=?").get(uid).n,
    0,
  );
});
test("one account cannot run overlapping model generations", async () => {
  const uid = createUserWithDefaultLists(
    "busy_owner",
    bcrypt.hashSync("Busy-owner-123", 10),
  );
  saveTask(uid, null, { title: "测试任务",estimate_minutes:60 });
  const token = await login("busy_owner", "Busy-owner-123");
  behavior = "delayed";
  releaseDelayed = null;
  const started = new Promise((resolve) => (startedDelayed = resolve));
  const first = newSession(token);
  await started;
  const second = newSession(token);
  await new Promise((resolve) => setTimeout(resolve, 40));
  behavior = "valid";
  releaseDelayed();
  assert.equal((await first).status, 201);
  assert.equal((await second).status, 429);
  startedDelayed = null;
});

test("hosted first turn creates a preview and adjustment discards the previous draft", async () => {
  const token = await login("session_owner", "Session-owner-123");
  behavior = "valid";
  const first = await newSession(token);
  assert.equal(first.status, 201);
  assert.equal(first.data.summary, "安排完成");
  assert.equal(first.data.draft.status, "pending");
  assert.equal(first.data.quota.used, 1);
  assert.equal(first.data.quota.remaining, 2);
  assert.match(generated.at(-1).messages[0].content, /schedule_task/);
  assert.match(generated.at(-1).messages[0].content, /不得增加字段/);
  assert.match(generated.at(-1).messages[0].content, /自然、温和、简洁/);
  assert.match(generated.at(-1).messages[0].content, /不要出现.*schedule_task/);

  behavior = "adjusted";
  const second = await call(
    `/api/ai/sessions/${first.data.sessionId}/turns`,
    "POST",
    {
      message: "改到晚一点",
    },
    token,
  );
  assert.equal(second.status, 200);
  assert.notEqual(second.data.draft.id, first.data.draft.id);
  assert.equal(
    db
      .prepare("SELECT status FROM schedule_drafts WHERE id=?")
      .get(first.data.draft.id).status,
    "discarded",
  );
});

test("BYOK decrypts only for the call and consumes no hosted quota", async () => {
  saveProviderConfig(byok, {
    provider: "custom",
    baseUrl: "https://api.example.com/v1",
    model: "planner",
    key: "sk-SENTINEL-BYOK-SECRET",
  });
  db.prepare("UPDATE users SET ai_mode='byok' WHERE id=?").run(byok);
  const token = await login("session_byok", "Session-byok-123");
  behavior = "valid";
  const response = await newSession(token, "安排 BYOK 任务");
  assert.equal(response.status, 201);
  assert.equal(response.data.quota.used, 0);
  assert.equal(generated.at(-1).key, "sk-SENTINEL-BYOK-SECRET");
  assert.equal(
    db
      .prepare("SELECT count(*) n FROM ai_quota_reservations WHERE user_id=?")
      .get(byok).n,
    0,
  );
});

test("session ownership and thirty-minute expiry are enforced", async () => {
  const token = await login("session_owner", "Session-owner-123");
  const stranger = await login("session_other", "Session-other-123");
  behavior = "valid";
  const created = await newSession(token);
  assert.equal(
    (
      await call(
        `/api/ai/sessions/${created.data.sessionId}/turns`,
        "POST",
        { message: "偷看" },
        stranger,
      )
    ).status,
    404,
  );
  db.prepare("UPDATE ai_planning_sessions SET expires_at=? WHERE id=?").run(
    Date.now() - 1,
    created.data.sessionId,
  );
  const expired = await call(
    `/api/ai/sessions/${created.data.sessionId}/turns`,
    "POST",
    { message: "继续" },
    token,
  );
  assert.equal(expired.status, 410);
  assert.equal(expired.data.code, "AI_SESSION_EXPIRED");
});

test("provider and schema failures refund hosted quota with stable redacted errors", async () => {
  const username = "session_failures";
  const password = "Session-failures-123";
  const uid = createUserWithDefaultLists(
    username,
    bcrypt.hashSync(password, 10),
  );
  saveTask(uid, null, { title: "失败测试任务" });
  const token = await login(username, password);
  for (const [nextBehavior, expectedCode, expectedStatus] of [
    ["timeout", "AI_PROVIDER_UNAVAILABLE", 502],
    ["invalid", "AI_PROPOSAL_INVALID", 400],
  ]) {
    behavior = nextBehavior;
    const response = await newSession(token, "测试失败退款");
    assert.equal(response.status, expectedStatus);
    assert.equal(response.data.code, expectedCode);
    assert.doesNotMatch(JSON.stringify(response), /SENTINEL/);
  }
  const daily = db
    .prepare("SELECT used,reserved FROM ai_quota_daily WHERE user_id=?")
    .get(uid);
  assert.equal(daily.used, 0);
  assert.equal(daily.reserved, 0);
  assert.doesNotMatch(
    JSON.stringify(
      db.prepare("SELECT * FROM ai_audit_log WHERE user_id=?").all(uid),
    ),
    /SENTINEL/,
  );
});

test("AI draft applies through the authenticated application endpoint", async () => {
  const username = "session_apply";
  const password = "Session-apply-123";
  const uid = createUserWithDefaultLists(
    username,
    bcrypt.hashSync(password, 10),
  );
  const ownTask = saveTask(uid, null, { title: "应用草案任务",estimate_minutes:60 });
  const token = await login(username, password);
  behavior = "valid";
  const response = await newSession(token, "安排应用草案任务");
  assert.equal(response.status, 201);
  const applied = await call(
    `/api/ai/drafts/${response.data.draft.id}/apply`,
    "POST",
    {},
    token,
  );
  assert.equal(applied.status, 200);
  assert.equal(applied.data.applied, 1);
  assert.equal(
    db.prepare("SELECT count(*) n FROM blocks WHERE inbox_id=?").get(ownTask.id)
      .n,
    1,
  );
});

test("disabled feature rejects generation without touching quota", async () => {
  const token = await login("session_other", "Session-other-123");
  process.env.AI_FEATURE_ENABLED = "false";
  const response = await newSession(token);
  assert.equal(response.status, 503);
  assert.equal(response.data.code, "AI_DISABLED");
  assert.equal(
    db
      .prepare("SELECT count(*) n FROM ai_quota_reservations WHERE user_id=?")
      .get(other).n,
    0,
  );
  process.env.AI_FEATURE_ENABLED = "true";
});

test('after partial apply the model receives the pending remainder and its matching status',async()=>{
 const name='partial_followup_fixture',password='Partial-fixture-123';
 const uid=createUserWithDefaultLists(name,bcrypt.hashSync(password,10));
 saveTask(uid,null,{title:'合成甲',estimate_minutes:60});saveTask(uid,null,{title:'合成乙',estimate_minutes:60});
 const token=await login(name,password);behavior='partial';
 const first=await newSession(token);
 assert.equal(first.status,201);
 const applied=await call(`/api/ai/drafts/${first.data.draft.id}/apply`,'POST',{selectedChangeIds:[first.data.draft.changes[0].id]},token);
 assert.equal(applied.status,200);
 behavior='no_change';
 const follow=await call(`/api/ai/sessions/${first.data.sessionId}/turns`,'POST',{message:'剩下的继续保留'},token);
 assert.equal(follow.status,200);
 const payload=JSON.parse(generated.at(-1).messages.find(m=>m.role==='user').content);
 assert.equal(payload.previousStatus,'pending');
 assert.deepEqual(payload.previous.changes,applied.data.remainingDraft.changes.map(({op,taskId,date,start,end})=>({op,taskId,date,start,end})));
});

test("deleting an account during generation never recreates private history", async () => {
  const name = "session_deleted_pending",
    password = "Delete-pending-123";
  const uid = createUserWithDefaultLists(name, bcrypt.hashSync(password, 10));
  saveTask(uid, null, { title: "pending private task" });
  const token = await login(name, password);
  behavior = "delayed";
  const started = new Promise((resolve) => {
    startedDelayed = resolve;
  });
  const pending = newSession(token);
  await started;
  const deleted = await call(
    "/api/account",
    "DELETE",
    { password, confirmation: "删除我的账号" },
    token,
  );
  assert.equal(deleted.status, 200);
  behavior = "valid";
  releaseDelayed();
  const response = await pending;
  startedDelayed = null;
  assert.equal(response.status, 410);
  for (const table of [
    "ai_planning_turns",
    "ai_planning_sessions",
    "schedule_drafts",
    "ai_audit_log",
  ])
    assert.equal(
      db.prepare(`SELECT count(*) n FROM ${table} WHERE user_id=?`).get(uid).n,
      0,
      table,
    );
});

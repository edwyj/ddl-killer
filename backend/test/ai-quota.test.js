import assert from "node:assert/strict";
import test from "node:test";

process.env.DB_PATH = ":memory:";
process.env.AI_HOSTED_ENABLED = "true";
process.env.AI_HOSTED_DAILY_LIMIT = "3";
process.env.AI_HOSTED_GLOBAL_DAILY_LIMIT = "100";

const { db } = await import("../src/db.js");
const quota = await import("../src/ai-quota.js");

db.prepare("INSERT INTO users(id,username,password_hash) VALUES(1,?,?)").run(
  "quota_one",
  "test",
);
db.prepare("INSERT INTO users(id,username,password_hash) VALUES(2,?,?)").run(
  "quota_two",
  "test",
);

test.beforeEach(() => {
  db.exec("DELETE FROM ai_quota_reservations; DELETE FROM ai_quota_daily;");
  process.env.AI_HOSTED_ENABLED = "true";
  process.env.AI_HOSTED_DAILY_LIMIT = "3";
  process.env.AI_HOSTED_GLOBAL_DAILY_LIMIT = "100";
});
test.after(() => db.close());
test("paid failed attempts keep cost charges and cannot be retried beyond the budget", () => {
  process.env.AI_HOSTED_GLOBAL_ATTEMPT_LIMIT = "1";
  process.env.AI_HOSTED_TOKEN_DAILY_LIMIT = "1000";
  process.env.AI_FAILURE_COOLDOWN_SECONDS = "0";
  const now = new Date("2026-10-01T01:00:00Z");
  try {
    const id = quota.beginHostedAttempt(1, 500, now);
    quota.finishHostedAttempt(id, null, false);
    assert.throws(() => quota.beginHostedAttempt(2, 500, now), {
      code: "AI_BUDGET_EXHAUSTED",
    });
    assert.equal(
      db
        .prepare("SELECT charged_tokens FROM ai_generation_attempts WHERE id=?")
        .get(id).charged_tokens,
      500,
    );
  } finally {
    delete process.env.AI_HOSTED_GLOBAL_ATTEMPT_LIMIT;
    delete process.env.AI_HOSTED_TOKEN_DAILY_LIMIT;
    delete process.env.AI_FAILURE_COOLDOWN_SECONDS;
  }
});

test("three concurrent reservations win and the fourth fails atomically", async () => {
  const now = new Date("2026-09-27T01:00:00.000Z");
  const results = await Promise.allSettled(
    [1, 2, 3, 4].map(() => quota.reserveHostedGeneration(1, now)),
  );
  assert.equal(
    results.filter((result) => result.status === "fulfilled").length,
    3,
  );
  assert.equal(
    results.filter((result) => result.reason?.code === "AI_QUOTA_EXHAUSTED")
      .length,
    1,
  );
  assert.equal(quota.quotaStatus(1, now).reserved, 3);
});

test("Asia/Shanghai midnight resets the account allowance", async () => {
  const before = new Date("2026-09-27T15:59:59.000Z");
  const after = new Date("2026-09-27T16:00:00.000Z");
  const reservation = await quota.reserveHostedGeneration(1, before);
  quota.consumeReservation(reservation.id, {
    promptTokens: 5,
    completionTokens: 2,
  });

  const oldStatus = quota.quotaStatus(1, before);
  const newStatus = quota.quotaStatus(1, after);
  assert.equal(oldStatus.used, 1);
  assert.equal(oldStatus.resetsAt, "2026-09-27T16:00:00.000Z");
  assert.equal(newStatus.used, 0);
  assert.equal(newStatus.remaining, 3);
  assert.equal(newStatus.resetsAt, "2026-09-28T16:00:00.000Z");
});

test("transport/schema failures release, while consumed drafts cannot be refunded", async () => {
  const now = new Date("2026-09-27T01:00:00.000Z");
  const failed = await quota.reserveHostedGeneration(1, now);
  assert.equal(
    quota.releaseReservation(failed.id, "AI_PROVIDER_UNAVAILABLE"),
    true,
  );
  assert.equal(quota.quotaStatus(1, now).remaining, 3);

  const completed = await quota.reserveHostedGeneration(1, now);
  assert.equal(
    quota.consumeReservation(completed.id, {
      promptTokens: 8,
      completionTokens: 3,
    }),
    true,
  );
  assert.equal(quota.releaseReservation(completed.id, "late-refund"), false);
  assert.deepEqual(quota.quotaStatus(1, now), {
    limit: 3,
    used: 1,
    reserved: 0,
    remaining: 2,
    resetsAt: "2026-09-27T16:00:00.000Z",
    hostedEnabled: true,
    copy: quota.AI_BETA_COPY,
  });
});

test("expired reservations are released after ten minutes", async () => {
  const start = new Date("2026-09-27T01:00:00.000Z");
  await quota.reserveHostedGeneration(1, start);
  assert.equal(
    quota.quotaStatus(1, new Date("2026-09-27T01:10:01.000Z")).reserved,
    0,
  );
});

test("global daily limit caps all users and BYOK bypass does not reserve", async () => {
  process.env.AI_HOSTED_GLOBAL_DAILY_LIMIT = "2";
  const now = new Date("2026-09-27T01:00:00.000Z");
  await quota.reserveHostedGeneration(1, now);
  await quota.reserveHostedGeneration(2, now);
  await assert.rejects(
    quota.reserveHostedGeneration(2, now),
    (error) => error.code === "AI_GLOBAL_QUOTA_EXHAUSTED",
  );
  assert.equal(await quota.reserveGeneration("byok", 2, now), null);
  assert.equal(quota.quotaStatus(2, now).reserved, 1);
});

test("hosted mode is disabled unless explicitly enabled", async () => {
  process.env.AI_HOSTED_ENABLED = "false";
  await assert.rejects(
    quota.reserveHostedGeneration(1, new Date()),
    (error) => error.code === "AI_HOSTED_DISABLED",
  );
  assert.equal(quota.quotaStatus(1, new Date()).hostedEnabled, false);
});

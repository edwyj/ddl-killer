import { randomUUID } from "node:crypto";

import { db } from "./db.js";
import { activeInvites, effectiveInviteLimit } from "./ai-invites.js";

export const AI_BETA_COPY =
  "DDL Killer 是完全免费的软件。官方 AI 免费额度用于让新用户体验助手，判断它是否适合自己。" +
  "这些 AI 调用会增加我们的运营成本；助手目前处于测试阶段，免费额度可能随成本和运行情况调整。" +
  "长期使用建议配置自己的 API Key，或通过 MCP 接入自己的智能体。" +
  "第三方模型或智能体服务的费用按对应服务商规则由你承担。DDL Killer 不收取任何软件使用费用。" +
  "任何以 DDL Killer 官方名义收取软件使用费用的行为均非官方，请勿付款。";
db.exec(`CREATE TABLE IF NOT EXISTS ai_generation_attempts (
 id TEXT PRIMARY KEY,user_id INTEGER,quota_date TEXT NOT NULL,charged_tokens INTEGER NOT NULL,
 state TEXT NOT NULL,success INTEGER,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL);
 CREATE INDEX IF NOT EXISTS generation_budget_date ON ai_generation_attempts(quota_date,user_id);`);

function quotaError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

function positiveInteger(value, fallback, optional = false) {
  if ((value === undefined || value === "") && optional) return null;
  const parsed = Number(value ?? fallback);
  if (!Number.isSafeInteger(parsed) || parsed < 1) {
    throw quotaError("AI_QUOTA_CONFIG_INVALID");
  }
  return parsed;
}

function configuration() {
  return {
    enabled: process.env.AI_HOSTED_ENABLED === "true",
    limit: positiveInteger(process.env.AI_HOSTED_DAILY_LIMIT, 3),
    globalLimit: positiveInteger(
      process.env.AI_HOSTED_GLOBAL_DAILY_LIMIT,
      null,
      true,
    ),
  };
}

function shanghaiDate(now) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const value = Object.fromEntries(
    parts.map(({ type, value: part }) => [type, part]),
  );
  return `${value.year}-${value.month}-${value.day}`;
}

function resetTime(quotaDate) {
  const [year, month, day] = quotaDate.split("-").map(Number);
  return new Date(
    Date.UTC(year, month - 1, day + 1) - 8 * 60 * 60 * 1000,
  ).toISOString();
}

function cleanupExpired(nowMs) {
  const expired = db
    .prepare(
      `SELECT id,user_id,quota_date FROM ai_quota_reservations
    WHERE state='reserved' AND created_at<?`,
    )
    .all(nowMs - 10 * 60 * 1000);
  for (const row of expired) {
    const changed = db
      .prepare(
        `UPDATE ai_quota_reservations
      SET state='released',reason='reservation_expired',updated_at=?
      WHERE id=? AND state='reserved'`,
      )
      .run(nowMs, row.id);
    if (changed.changes === 1) {
      db.prepare(
        `UPDATE ai_quota_daily SET reserved=CASE WHEN reserved>0 THEN reserved-1 ELSE 0 END,
        updated_at=? WHERE user_id=? AND quota_date=?`,
      ).run(nowMs, row.user_id, row.quota_date);
    }
  }
}

function inTransaction(operation) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = operation();
    db.exec("COMMIT");
    return result;
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

export async function reserveHostedGeneration(userId, now = new Date()) {
  const config = configuration();
  if (!config.enabled) throw quotaError("AI_HOSTED_DISABLED");
  const nowMs = now.getTime();
  const date = shanghaiDate(now);
  return inTransaction(() => {
    cleanupExpired(nowMs);
    const daily = db
      .prepare(
        `SELECT used,reserved FROM ai_quota_daily
      WHERE user_id=? AND quota_date=?`,
      )
      .get(userId, date) ?? { used: 0, reserved: 0 };
    if (
      daily.used + daily.reserved >=
      effectiveInviteLimit(userId, config.limit, nowMs)
    ) {
      throw quotaError("AI_QUOTA_EXHAUSTED");
    }
    if (config.globalLimit !== null) {
      const total = db
        .prepare(
          `SELECT COALESCE(SUM(used+reserved),0) total
        FROM ai_quota_daily WHERE quota_date=?`,
        )
        .get(date).total;
      if (total >= config.globalLimit)
        throw quotaError("AI_GLOBAL_QUOTA_EXHAUSTED");
    }
    const id = randomUUID();
    db.prepare(
      `INSERT INTO ai_quota_daily(user_id,quota_date,used,reserved,updated_at)
      VALUES(?,?,0,1,?) ON CONFLICT(user_id,quota_date) DO UPDATE SET
      reserved=reserved+1,updated_at=excluded.updated_at`,
    ).run(userId, date, nowMs);
    db.prepare(
      `INSERT INTO ai_quota_reservations(
      id,user_id,quota_date,state,created_at,updated_at
    ) VALUES(?,?,?,'reserved',?,?)`,
    ).run(id, userId, date, nowMs, nowMs);
    return { id, quotaDate: date };
  });
}

export async function reserveGeneration(mode, userId, now = new Date()) {
  return mode === "byok" ? null : reserveHostedGeneration(userId, now);
}

export function consumeReservation(id, usage = {}) {
  return inTransaction(() => {
    const row = db
      .prepare("SELECT * FROM ai_quota_reservations WHERE id=?")
      .get(id);
    if (!row || row.state !== "reserved") return false;
    const safeUsage = {
      promptTokens: Number.isSafeInteger(usage.promptTokens)
        ? usage.promptTokens
        : 0,
      completionTokens: Number.isSafeInteger(usage.completionTokens)
        ? usage.completionTokens
        : 0,
    };
    db.prepare(
      `UPDATE ai_quota_reservations SET state='consumed',usage_json=?,updated_at=?
      WHERE id=? AND state='reserved'`,
    ).run(JSON.stringify(safeUsage), Date.now(), id);
    db.prepare(
      `UPDATE ai_quota_daily SET reserved=CASE WHEN reserved>0 THEN reserved-1 ELSE 0 END,
      used=used+1,updated_at=? WHERE user_id=? AND quota_date=?`,
    ).run(Date.now(), row.user_id, row.quota_date);
    return true;
  });
}

export function releaseReservation(id, reason = "generation_failed") {
  return inTransaction(() => {
    const row = db
      .prepare("SELECT * FROM ai_quota_reservations WHERE id=?")
      .get(id);
    if (!row || row.state !== "reserved") return false;
    db.prepare(
      `UPDATE ai_quota_reservations SET state='released',reason=?,updated_at=?
      WHERE id=? AND state='reserved'`,
    ).run(String(reason).slice(0, 64), Date.now(), id);
    db.prepare(
      `UPDATE ai_quota_daily SET reserved=CASE WHEN reserved>0 THEN reserved-1 ELSE 0 END,
      updated_at=? WHERE user_id=? AND quota_date=?`,
    ).run(Date.now(), row.user_id, row.quota_date);
    return true;
  });
}

export function quotaStatus(userId, now = new Date()) {
  const config = configuration();
  const nowMs = now.getTime();
  const date = shanghaiDate(now);
  const { daily, globalTotal } = inTransaction(() => {
    cleanupExpired(nowMs);
    return {
      daily: db
        .prepare(
          `SELECT used,reserved FROM ai_quota_daily
        WHERE user_id=? AND quota_date=?`,
        )
        .get(userId, date) ?? { used: 0, reserved: 0 },
      globalTotal: db
        .prepare(
          `SELECT COALESCE(SUM(used+reserved),0) total
        FROM ai_quota_daily WHERE quota_date=?`,
        )
        .get(date).total,
    };
  });
  const effectiveLimit = effectiveInviteLimit(userId, config.limit, nowMs);
  const grants = activeInvites(userId, nowMs);
  const accountRemaining = Math.max(
    0,
    effectiveLimit - daily.used - daily.reserved,
  );
  const globalRemaining =
    config.globalLimit === null
      ? accountRemaining
      : Math.max(0, config.globalLimit - globalTotal);
  return {
    limit: effectiveLimit,
    ...(grants.length ? { entitlements: grants } : {}),
    used: daily.used,
    reserved: daily.reserved,
    remaining: Math.min(accountRemaining, globalRemaining),
    resetsAt: resetTime(date),
    hostedEnabled: config.enabled,
    copy: AI_BETA_COPY,
  };
}

// A provider call can incur charges even when parsing fails or the transport
// times out. These budgets are independent of refundable user allowances.
export function beginHostedAttempt(userId, estimatedTokens, now = new Date()) {
  if (
    !Number.isSafeInteger(estimatedTokens) ||
    estimatedTokens < 1 ||
    estimatedTokens > 250000
  )
    throw quotaError("AI_CONTEXT_INVALID");
  const date = shanghaiDate(now),
    ms = now.getTime();
  const globalLimit = positiveInteger(
    process.env.AI_HOSTED_GLOBAL_ATTEMPT_LIMIT,
    300,
  );
  const tokenLimit = positiveInteger(
    process.env.AI_HOSTED_TOKEN_DAILY_LIMIT,
    3000000,
  );
  const userLimit = positiveInteger(
    process.env.AI_HOSTED_ATTEMPT_DAILY_LIMIT,
    Math.max(9, effectiveInviteLimit(userId, configuration().limit, ms) * 3),
  );
  const cooldown = Number(process.env.AI_FAILURE_COOLDOWN_SECONDS ?? 30);
  if (!Number.isSafeInteger(cooldown) || cooldown < 0 || cooldown > 3600)
    throw quotaError("AI_QUOTA_CONFIG_INVALID");
  return inTransaction(() => {
    const latest = db
      .prepare(
        "SELECT success,updated_at FROM ai_generation_attempts WHERE user_id=? ORDER BY created_at DESC LIMIT 1",
      )
      .get(userId);
    if (latest?.success === 0 && latest.updated_at > ms - cooldown * 1000)
      throw Object.assign(quotaError("AI_RETRY_LATER"), {
        retryAfterSeconds: Math.max(1, Math.ceil((latest.updated_at + cooldown * 1000 - ms) / 1000)),
      });
    const total = db
      .prepare(
        "SELECT count(*) n,COALESCE(SUM(charged_tokens),0) tokens FROM ai_generation_attempts WHERE quota_date=?",
      )
      .get(date);
    const user = db
      .prepare(
        "SELECT count(*) n FROM ai_generation_attempts WHERE quota_date=? AND user_id=?",
      )
      .get(date, userId).n;
    if (
      user >= userLimit ||
      total.n >= globalLimit ||
      total.tokens + estimatedTokens > tokenLimit
    )
      throw quotaError("AI_BUDGET_EXHAUSTED");
    const id = randomUUID();
    db.prepare(
      "INSERT INTO ai_generation_attempts VALUES(?,?,?,?,'started',NULL,?,?)",
    ).run(id, userId, date, estimatedTokens, ms, ms);
    return id;
  });
}
export function finishHostedAttempt(id, usage, success) {
  const row = db
    .prepare("SELECT * FROM ai_generation_attempts WHERE id=?")
    .get(id);
  if (!row || row.state !== "started") return false;
  const prompt = usage?.promptTokens,
    completion = usage?.completionTokens;
  const known =
    Number.isSafeInteger(prompt) &&
    prompt >= 0 &&
    Number.isSafeInteger(completion) &&
    completion >= 0 &&
    prompt + completion > 0;
  db.prepare(
    "UPDATE ai_generation_attempts SET state='finished',success=?,charged_tokens=?,updated_at=? WHERE id=? AND state='started'",
  ).run(
    success ? 1 : 0,
    known ? prompt + completion : row.charged_tokens,
    Date.now(),
    id,
  );
  return true;
}

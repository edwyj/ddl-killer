import {
  createHash,
  createHmac,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";
import { db } from "./db.js";

export const invitePlans = Object.freeze({
  week: { name: "体验周卡", days: 7, dailyLimit: 10 },
  referral: { name: "邀请周卡", days: 7, dailyLimit: 6 },
  month: { name: "体验月卡", days: 30, dailyLimit: 10 },
  test: { name: "内部测试周卡", days: 7, dailyLimit: 50 },
});
db.exec(`CREATE TABLE IF NOT EXISTS ai_invites (
 id TEXT PRIMARY KEY, code_hash TEXT UNIQUE NOT NULL, batch_id TEXT NOT NULL,
 plan TEXT NOT NULL, days INTEGER NOT NULL, daily_limit INTEGER NOT NULL,
 created_at INTEGER NOT NULL, redeem_before INTEGER NOT NULL, revoked_at INTEGER,
 user_id INTEGER, redeemed_at INTEGER, expires_at INTEGER);
 CREATE INDEX IF NOT EXISTS ai_invites_user ON ai_invites(user_id,expires_at);
 CREATE TABLE IF NOT EXISTS ai_invite_batches (
 id TEXT PRIMARY KEY, request_key TEXT UNIQUE NOT NULL, plan TEXT NOT NULL,
 count INTEGER NOT NULL, created_at INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS ai_invite_audit (
 id TEXT PRIMARY KEY, action TEXT NOT NULL, invite_id TEXT, created_at INTEGER NOT NULL);`);
const day = 86400000;
try {
  db.exec("ALTER TABLE ai_invites ADD COLUMN bound_user_id INTEGER");
} catch (error) {
  if (!/duplicate column name/i.test(error.message)) throw error;
}
const hash = (code) => createHash("sha256").update(code).digest("hex");
function fail(code, message, status = 400) {
  throw Object.assign(new Error(message), { code, status });
}
function transaction(fn) {
  db.exec("SAVEPOINT invite_operation");
  try {
    const value = fn();
    db.exec("RELEASE invite_operation");
    return value;
  } catch (error) {
    db.exec("ROLLBACK TO invite_operation; RELEASE invite_operation");
    throw error;
  }
}
function audit(action, id, now) {
  db.prepare("INSERT INTO ai_invite_audit VALUES(?,?,?,?)").run(
    randomUUID(),
    action,
    id,
    now,
  );
}
function secret() {
  const value = process.env.AI_INVITE_SECRET;
  if (!value || value.length < 32)
    fail("INVITE_UNAVAILABLE", "邀请码服务暂不可用", 503);
  return value;
}
function codeFor(batchId, index) {
  const code = createHmac("sha256", secret())
    .update(`ddl-invite-v1:${batchId}:${index}`)
    .digest("hex")
    .slice(0, 24)
    .toUpperCase();
  return `DDL-${code.match(/.{6}/g).join("-")}`;
}
function normalized(raw) {
  if (typeof raw !== "string" || raw.length > 80)
    fail("INVITE_INVALID", "邀请码无效、已过期或已被使用");
  const compact = raw.toUpperCase().replace(/[\s-]/g, "");
  if (!/^DDL[0-9A-F]{24}$/.test(compact))
    fail("INVITE_INVALID", "邀请码无效、已过期或已被使用");
  return `DDL-${compact.slice(3).match(/.{6}/g).join("-")}`;
}
function publicInvite(row) {
  return {
    id: row.id,
    plan: row.plan,
    name: invitePlans[row.plan]?.name ?? "体验权益",
    dailyLimit: row.daily_limit,
    days: row.days,
    redeemBefore: new Date(row.redeem_before).toISOString(),
    redeemed: row.redeemed_at !== null,
    revoked: row.revoked_at !== null,
    expiresAt: row.expires_at ? new Date(row.expires_at).toISOString() : null,
  };
}
export function issueInvites(plan, count, requestKey, now = Date.now()) {
  secret();
  if (
    !Object.hasOwn(invitePlans, plan) ||
    !Number.isSafeInteger(count) ||
    count < 1 ||
    count > 10 ||
    typeof requestKey !== "string" ||
    !/^[A-Za-z0-9:_-]{8,160}$/.test(requestKey)
  )
    fail("INVITE_INPUT", "请选择有效模板，每批最多10个");
  return transaction(() => {
    let batch = db
      .prepare("SELECT * FROM ai_invite_batches WHERE request_key=?")
      .get(requestKey);
    if (batch && (batch.plan !== plan || batch.count !== count))
      fail("INVITE_CONFLICT", "重复请求参数不一致", 409);
    if (!batch) {
      const issued = db
        .prepare(
          "SELECT COALESCE(SUM(count),0) n FROM ai_invite_batches WHERE created_at>?",
        )
        .get(now - day).n;
      const max = Number(process.env.AI_INVITE_ISSUE_DAILY_MAX ?? 30);
      if (!Number.isSafeInteger(max) || max < 1 || issued + count > max)
        fail("INVITE_ISSUE_LIMIT", "已达到24小时发码上限", 429);
      batch = { id: randomUUID(), plan, count, created_at: now };
      db.prepare("INSERT INTO ai_invite_batches VALUES(?,?,?,?,?)").run(
        batch.id,
        requestKey,
        plan,
        count,
        now,
      );
      const spec = invitePlans[plan];
      for (let i = 0; i < count; i++) {
        const id = randomUUID();
        db.prepare(
          `INSERT INTO ai_invites(id,code_hash,batch_id,plan,days,daily_limit,created_at,redeem_before)
          VALUES(?,?,?,?,?,?,?,?)`,
        ).run(
          id,
          hash(codeFor(batch.id, i)),
          batch.id,
          plan,
          spec.days,
          spec.dailyLimit,
          now,
          now + 7 * day,
        );
        audit("issue", id, now);
      }
    }
    return {
      batchId: batch.id,
      invites: Array.from({ length: count }, (_, i) => {
        const code = codeFor(batch.id, i);
        const row = db
          .prepare("SELECT * FROM ai_invites WHERE code_hash=?")
          .get(hash(code));
        return { ...publicInvite(row), code };
      }),
    };
  });
}
export function activeInvites(userId, now = Date.now()) {
  return db
    .prepare(
      "SELECT * FROM ai_invites WHERE user_id=? AND revoked_at IS NULL AND expires_at>? ORDER BY daily_limit DESC,expires_at DESC",
    )
    .all(userId, now)
    .map(publicInvite);
}
export function effectiveInviteLimit(userId, baseLimit, now) {
  const grants = activeInvites(userId, now);
  return Math.max(baseLimit, ...grants.map((g) => g.dailyLimit));
}
function redeemable(raw, userId, now) {
  const row = db
    .prepare("SELECT * FROM ai_invites WHERE code_hash=?")
    .get(hash(normalized(raw)));
  if (
    !row ||
    row.revoked_at !== null ||
    (row.bound_user_id !== null && row.bound_user_id !== userId) ||
    (row.user_id !== null && row.user_id !== userId) ||
    (row.user_id === null && row.redeem_before <= now)
  )
    fail("INVITE_INVALID", "邀请码无效、已过期或已被使用");
  return row;
}
export function previewInvite(raw, userId, now = Date.now()) {
  const row = redeemable(raw, userId, now);
  return {
    ...publicInvite(row),
    startsAt: new Date(row.redeemed_at ?? now).toISOString(),
    expiresAt: new Date(row.expires_at ?? now + row.days * day).toISOString(),
    alreadyRedeemed: row.user_id === userId,
    active: activeInvites(userId, now),
  };
}
export function redeemInvite(raw, userId, now = Date.now()) {
  return transaction(() => {
    const row = redeemable(raw, userId, now);
    if (row.user_id === null) {
      db.prepare(
        "UPDATE ai_invites SET user_id=?,redeemed_at=?,expires_at=? WHERE id=?",
      ).run(userId, now, now + row.days * day, row.id);
      audit("redeem", row.id, now);
    }
    return { ok: true, active: activeInvites(userId, now) };
  });
}
export function bindRewardInvite(id, userId) {
  const changed = db
    .prepare(
      "UPDATE ai_invites SET bound_user_id=? WHERE id=? AND user_id IS NULL AND bound_user_id IS NULL",
    )
    .run(userId, id);
  if (changed.changes !== 1) fail("INVITE_CONFLICT", "奖励状态已变化", 409);
}
export function claimRewardInvite(id, userId, now = Date.now()) {
  const row = db
    .prepare("SELECT * FROM ai_invites WHERE id=? AND bound_user_id=?")
    .get(id, userId);
  if (
    !row ||
    row.revoked_at !== null ||
    (row.user_id !== null && row.user_id !== userId) ||
    (row.user_id === null && row.redeem_before <= now)
  )
    fail("INVITE_INVALID", "奖励已过期或已撤销");
  if (row.user_id === null) {
    db.prepare(
      "UPDATE ai_invites SET user_id=?,redeemed_at=?,expires_at=? WHERE id=?",
    ).run(userId, now, now + row.days * day, id);
    audit("redeem", id, now);
  }
  return { ok: true, active: activeInvites(userId, now) };
}
export function revokeInvite(id, now = Date.now()) {
  return transaction(() => {
    const changed = db
      .prepare(
        "UPDATE ai_invites SET revoked_at=? WHERE id=? AND revoked_at IS NULL",
      )
      .run(now, id);
    if (changed.changes) audit("revoke", id, now);
    return { ok: true };
  });
}
const route = (fn) => (req, res) => {
  try {
    res.json(fn(req));
  } catch (error) {
    res
      .status(error.status ?? 500)
      .json({
        code: error.code ?? "INVITE_ERROR",
        error: error.status ? error.message : "邀请码服务暂不可用",
      });
  }
};
export function inviteAdmin(req, res, next) {
  const expected = process.env.AI_INVITE_ADMIN_TOKEN;
  const provided = req.headers.authorization?.replace(/^Bearer /, "") ?? "";
  if (
    !expected ||
    expected.length < 32 ||
    !timingSafeEqual(
      createHash("sha256").update(expected).digest(),
      createHash("sha256").update(provided).digest(),
    )
  )
    return res.status(403).json({ error: "无权管理邀请码" });
  next();
}
export function mountAiInvites(app, auth, limit) {
  const userOnly = (req, res, next) =>
    req.user.sid ? next() : res.status(403).json({ error: "请在应用内兑换" });
  for (const [suffix, fn] of [
    ["preview", previewInvite],
    ["redeem", redeemInvite],
  ]) {
    app.post(
      `/api/ai/invites/${suffix}`,
      auth,
      userOnly,
      limit("invite-" + suffix, 20, 15 * 60000, (req) => String(req.user.uid)),
      route((req) => fn(req.body?.code, req.user.uid)),
    );
  }
  app.post(
    "/api/internal/ai-invites/issue",
    inviteAdmin,
    route((req) =>
      issueInvites(req.body?.plan, req.body?.count, req.body?.requestKey),
    ),
  );
  app.get(
    "/api/internal/ai-invites",
    inviteAdmin,
    route(() => ({
      invites: db
        .prepare("SELECT * FROM ai_invites ORDER BY created_at DESC LIMIT 100")
        .all()
        .map(publicInvite),
    })),
  );
  app.post(
    "/api/internal/ai-invites/:id/revoke",
    inviteAdmin,
    route((req) => revokeInvite(req.params.id)),
  );
}

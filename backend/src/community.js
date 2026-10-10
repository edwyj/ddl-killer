import express from "express";
import { randomUUID, randomBytes, createHash } from "node:crypto";
import { db } from "./db.js";
import {
  inviteAdmin,
  invitePlans,
  issueInvites,
  bindRewardInvite,
  claimRewardInvite,
  activeInvites,
} from "./ai-invites.js";

const DAY = 86400000;
db.exec(`
 CREATE TABLE IF NOT EXISTS user_messages (
 id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER NOT NULL,source_key TEXT NOT NULL,
 title TEXT NOT NULL,body TEXT NOT NULL,reward_id TEXT,created_at INTEGER NOT NULL,read_at INTEGER,
 UNIQUE(user_id,source_key));
 CREATE INDEX IF NOT EXISTS messages_user ON user_messages(user_id,created_at);
 CREATE TABLE IF NOT EXISTS user_feedback (
 id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER NOT NULL,request_key TEXT NOT NULL,input_hash TEXT NOT NULL,
 type TEXT NOT NULL,title TEXT NOT NULL,description TEXT NOT NULL,school TEXT NOT NULL,platform TEXT NOT NULL,version TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'pending',reply TEXT NOT NULL DEFAULT '',created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,
 UNIQUE(user_id,request_key));
 CREATE INDEX IF NOT EXISTS feedback_user ON user_feedback(user_id,created_at);
 CREATE TABLE IF NOT EXISTS feedback_files (
 id TEXT PRIMARY KEY,feedback_id INTEGER NOT NULL,user_id INTEGER NOT NULL,name TEXT NOT NULL,data BLOB NOT NULL,created_at INTEGER NOT NULL);
 CREATE INDEX IF NOT EXISTS feedback_files_owner ON feedback_files(user_id,feedback_id);
 CREATE TABLE IF NOT EXISTS community_outbox (
 id TEXT PRIMARY KEY,feedback_id INTEGER NOT NULL,created_at INTEGER NOT NULL,next_attempt_at INTEGER NOT NULL,
 attempts INTEGER NOT NULL DEFAULT 0,delivered_at INTEGER);
 CREATE TABLE IF NOT EXISTS user_rewards (
 id TEXT PRIMARY KEY,user_id INTEGER NOT NULL,source_key TEXT NOT NULL UNIQUE,invite_id TEXT NOT NULL,
 created_at INTEGER NOT NULL,claimed_at INTEGER);
 CREATE TABLE IF NOT EXISTS referral_codes (user_id INTEGER PRIMARY KEY,code TEXT NOT NULL UNIQUE);
 CREATE TABLE IF NOT EXISTS referral_redemptions (
 user_id INTEGER PRIMARY KEY,inviter_id INTEGER NOT NULL,created_at INTEGER NOT NULL);
 CREATE INDEX IF NOT EXISTS referrals_inviter ON referral_redemptions(inviter_id,created_at);
 CREATE TABLE IF NOT EXISTS community_admin_actions (
 request_key TEXT PRIMARY KEY,input_hash TEXT NOT NULL,result_json TEXT NOT NULL,created_at INTEGER NOT NULL,feedback_id INTEGER);
`);

export const WELCOME_BODY = `嗨，欢迎你呀。

想做的事有点多，不知道先从哪件开始？先把它们放在这里吧，不用一下子把每一天都安排好。

你可以从一份小清单开始，也可以点点蝴蝶结，和 AI 聊聊你的计划。它会帮你想想怎么安排，等你觉得合适了，再放进日程。

用着哪里不顺手，或者突然冒出一个好点子，都欢迎来「我的 → 问题与建议」告诉我们。确认有效的问题和被采纳的建议，我们会送上一份 AI 体验奖励，感谢你帮它变得更好。

愿你的日程里，除了要做的事，也留得下喜欢的事。🎀`;
function fail(code, message, status = 400) {
  throw Object.assign(new Error(message), { code, status });
}
function transaction(fn) {
  db.exec("SAVEPOINT community_operation");
  try {
    const v = fn();
    db.exec("RELEASE community_operation");
    return v;
  } catch (e) {
    db.exec("ROLLBACK TO community_operation; RELEASE community_operation");
    throw e;
  }
}
function text(value, max, required = false) {
  if (value == null && !required) return "";
  if (
    typeof value !== "string" ||
    value.length > max ||
    (required && !value.trim())
  )
    fail("INPUT_INVALID", "请补充完整内容，或缩短过长的文字");
  return value
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "")
    .trim();
}
function requestKey(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9:_-]{8,160}$/.test(value))
    fail("INPUT_INVALID", "这次提交没有准备好，请重新打开反馈页再试。");
  return value;
}
const digest = (value) =>
  createHash("sha256").update(JSON.stringify(value)).digest("hex");
function message(uid, key, title, body, rewardId = null, now = Date.now()) {
  db.prepare(
    "INSERT OR IGNORE INTO user_messages(user_id,source_key,title,body,reward_id,created_at) VALUES(?,?,?,?,?,?)",
  ).run(uid, key, title, body, rewardId, now);
}
export function initializeCommunityUser(uid, { welcome = false } = {}) {
  db.prepare(
    "INSERT OR IGNORE INTO referral_codes(user_id,code) VALUES(?,?)",
  ).run(uid, `JOIN-${randomBytes(10).toString("hex").toUpperCase()}`);
  if (welcome) message(uid, "welcome", "欢迎来到 DDL Killer 🎀", WELCOME_BODY);
}
function rewardView(row, now = Date.now()) {
  if (!row) return null;
  const invite = db
    .prepare("SELECT * FROM ai_invites WHERE id=?")
    .get(row.invite_id);
  if (!invite) return null;
  return {
    id: row.id,
    inviteId: invite.id,
    name: invitePlans[invite.plan]?.name ?? "体验奖励",
    days: invite.days,
    dailyLimit: invite.daily_limit,
    redeemBefore: new Date(invite.redeem_before).toISOString(),
    expiresAt: invite.expires_at
      ? new Date(invite.expires_at).toISOString()
      : null,
    status: invite.revoked_at
      ? "revoked"
      : row.claimed_at
        ? "claimed"
        : invite.redeem_before <= now
          ? "expired"
          : "available",
  };
}
function rewardById(id) {
  return db.prepare("SELECT * FROM user_rewards WHERE id=?").get(id);
}
function grantReward(uid, source, plan, title, body, now = Date.now()) {
  const previous = db
    .prepare("SELECT * FROM user_rewards WHERE source_key=?")
    .get(source);
  if (previous) {
    const invite = db
      .prepare("SELECT plan FROM ai_invites WHERE id=?")
      .get(previous.invite_id);
    if (previous.user_id !== uid || invite?.plan !== plan)
      fail("REWARD_CONFLICT", "该奖励已经发放，不能重复或更换类型", 409);
    return rewardView(previous, now);
  }
  const issued = issueInvites(plan, 1, "reward:" + digest(source), now)
    .invites[0];
  bindRewardInvite(issued.id, uid);
  const id = randomUUID();
  db.prepare("INSERT INTO user_rewards VALUES(?,?,?,?,?,NULL)").run(
    id,
    uid,
    source,
    issued.id,
    now,
  );
  const spec = invitePlans[plan];
  message(
    uid,
    source,
    title,
    `${body}\n\n${spec.name}：${spec.days} 天，每天共 ${spec.dailyLimit} 次。请在 7 天内领取，领取后开始计时。\n如果你还有其他体验卡，会使用较高的每日次数；次数和有效期不会叠加，今天已用的次数也会保留。`,
    id,
    now,
  );
  return rewardView(rewardById(id), now);
}
function claimReward(uid, id, now = Date.now()) {
  return transaction(() => {
    const row = rewardById(id);
    if (!row || row.user_id !== uid) fail("NOT_FOUND", "奖励不存在", 404);
    const result = claimRewardInvite(row.invite_id, uid, now);
    db.prepare(
      "UPDATE user_rewards SET claimed_at=COALESCE(claimed_at,?) WHERE id=?",
    ).run(now, id);
    return { ...result, reward: rewardView(rewardById(id), now) };
  });
}
function attachmentsFor(id) {
  return db
    .prepare(
      "SELECT id,name,length(data) size FROM feedback_files WHERE feedback_id=?",
    )
    .all(id);
}
function feedbackView(row) {
  return {
    ...row,
    request_key: undefined,
    input_hash: undefined,
    attachments: attachmentsFor(row.id),
  };
}
function ownedFeedback(uid, id) {
  const row = db
    .prepare("SELECT * FROM user_feedback WHERE id=? AND user_id=?")
    .get(id, uid);
  if (!row) fail("NOT_FOUND", "反馈不存在", 404);
  return feedbackView(row);
}
function filesInput(raw) {
  if (raw === undefined) return [];
  if (!Array.isArray(raw) || raw.length > 3)
    fail("FILE_INVALID", "最多添加 3 个附件");
  let total = 0;
  return raw.map((file) => {
    const name = text(file?.name, 100, true);
    if (
      !/\.(png|jpe?g|pdf|json|html?|xlsx?|csv)$/i.test(name) ||
      /[\\/]/.test(name)
    )
      fail("FILE_INVALID", "请选择课表、图片或文档文件");
    if (
      typeof file.data !== "string" ||
      !file.data ||
      file.data.length > 3 * 1024 * 1024 ||
      !/^[A-Za-z0-9+/]*={0,2}$/.test(file.data)
    )
      fail("FILE_INVALID", "附件无法读取");
    const data = Buffer.from(file.data, "base64");
    if (data.toString("base64") !== file.data || data.length > 2 * 1024 * 1024)
      fail("FILE_INVALID", "附件过大或格式无效");
    total += data.length;
    if (total > 2 * 1024 * 1024) fail("FILE_INVALID", "附件合计不能超过 2 MB");
    if (
      /\.png$/i.test(name) &&
      !data
        .subarray(0, 8)
        .equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
    )
      fail("FILE_INVALID", "图片格式无效");
    if (/\.jpe?g$/i.test(name) && !(data[0] === 255 && data[1] === 216))
      fail("FILE_INVALID", "图片格式无效");
    if (/\.pdf$/i.test(name) && data.subarray(0, 5).toString() !== "%PDF-")
      fail("FILE_INVALID", "PDF 格式无效");
    return { name, data };
  });
}
function submitFeedback(uid, body, now = Date.now()) {
  const type = body?.type;
  if (!["bug", "suggestion", "school"].includes(type))
    fail("INPUT_INVALID", "请选择问题、建议或课表适配");
  const key = requestKey(body.requestKey),
    files = filesInput(body.attachments);
  const input = {
    type,
    title: text(body.title, 100, true),
    description: text(body.description, 5000, true),
    school: text(body.school, 100),
    platform: text(body.platform, 60),
    version: text(body.version, 32),
  };
  if (type === "school" && !input.school)
    fail("INPUT_INVALID", "请填写学校名称");
  const hash = digest({
    ...input,
    files: files.map((f) => ({
      name: f.name,
      hash: digest(f.data.toString("base64")),
    })),
  });
  return transaction(() => {
    const old = db
      .prepare("SELECT * FROM user_feedback WHERE user_id=? AND request_key=?")
      .get(uid, key);
    if (old) {
      if (old.input_hash !== hash)
        fail("INPUT_CONFLICT", "该次反馈已提交，请返回查看记录", 409);
      return { id: old.id, ok: true };
    }
    const history = db
      .prepare(
        "SELECT created_at FROM user_feedback WHERE user_id=? AND created_at>? ORDER BY created_at DESC",
      )
      .all(uid, now - DAY);
    if (history.length >= 3 || history[0]?.created_at > now - 60000)
      fail("FEEDBACK_LIMIT", "你已经提交了几条反馈，我们会逐一查看。每天可以提交 3 条，请稍后再试。", 429);
    const stored = db
      .prepare(
        "SELECT COALESCE(SUM(length(data)),0) size FROM feedback_files WHERE user_id=?",
      )
      .get(uid).size;
    if (
      stored + files.reduce((sum, f) => sum + f.data.length, 0) >
      20 * 1024 * 1024
    )
      fail("FILE_LIMIT", "附件存储已满，请删除不再需要的历史附件");
    const result = db
      .prepare(
        "INSERT INTO user_feedback(user_id,request_key,input_hash,type,title,description,school,platform,version,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
      )
      .run(
        uid,
        key,
        hash,
        type,
        input.title,
        input.description,
        input.school,
        input.platform,
        input.version,
        now,
        now,
      );
    const id = Number(result.lastInsertRowid);
    for (const file of files)
      db.prepare("INSERT INTO feedback_files VALUES(?,?,?,?,?,?)").run(
        randomUUID(),
        id,
        uid,
        file.name,
        file.data,
        now,
      );
    db.prepare(
      "INSERT INTO community_outbox(id,feedback_id,created_at,next_attempt_at) VALUES(?,?,?,?)",
    ).run(randomUUID(), id, now, now);
    return { id, ok: true };
  });
}
function adminAction(key, input, fn) {
  requestKey(key);
  return transaction(() => {
    const hash = digest(input),
      old = db
        .prepare("SELECT * FROM community_admin_actions WHERE request_key=?")
        .get(key);
    if (old) {
      if (old.input_hash !== hash)
        fail("INPUT_CONFLICT", "重复管理请求内容不一致", 409);
      return JSON.parse(old.result_json);
    }
    const result = fn();
    db.prepare("INSERT INTO community_admin_actions VALUES(?,?,?,?,?)").run(
      key,
      hash,
      JSON.stringify(result),
      Date.now(),
      input.id ?? null,
    );
    return result;
  });
}
function reviewFeedback(id, body) {
  const status = text(body?.status, 20, true),
    reply = text(body.reply, 2000);
  if (
    ![
      "confirmed",
      "accepted",
      "resolved",
      "duplicate",
      "declined",
      "pending",
    ].includes(status)
  )
    fail("INPUT_INVALID", "请选择有效处理状态");
  return adminAction(body.requestKey, { id, status, reply }, () => {
    const row = db.prepare("SELECT * FROM user_feedback WHERE id=?").get(id);
    if (!row) fail("NOT_FOUND", "反馈不存在", 404);
    db.prepare(
      "UPDATE user_feedback SET status=?,reply=?,updated_at=? WHERE id=?",
    ).run(status, reply, Date.now(), id);
    const labels = {
      confirmed: "问题已确认",
      accepted: "建议已采纳",
      resolved: "问题已解决",
      duplicate: "已有相关反馈",
      declined: "反馈处理结果",
      pending: "反馈回复",
    };
    const replies = {
      confirmed: "你提到的问题已经确认，我们会继续跟进。谢谢你帮我们发现它。🎀",
      accepted: "这个建议已经采纳啦，我们会继续完善。谢谢你的好点子。🎀",
      resolved: "你提到的问题已经修好啦，欢迎再试试看。谢谢你的耐心。🎀",
      duplicate: "我们已经收到类似的反馈，会一起跟进处理。谢谢你也来告诉我们。",
      declined: "谢谢你愿意告诉我们。目前还没有采纳这条建议，你也可以继续补充想法。",
      pending: "你的反馈我们已经收到，会继续查看。谢谢你愿意帮我们改进。",
    };
    message(
      row.user_id,
      "review:" + body.requestKey,
      labels[status],
      `关于你的反馈「${row.title}」：\n\n${reply || replies[status]}`,
    );
    return { ok: true };
  });
}
function rewardFeedback(id, body) {
  const plan = body?.plan;
  if (!Object.hasOwn(invitePlans, plan)) fail("INPUT_INVALID", "奖励类型无效");
  return transaction(() => {
    const row = db.prepare("SELECT * FROM user_feedback WHERE id=?").get(id);
    if (!row) fail("NOT_FOUND", "反馈不存在", 404);
    if (!["confirmed", "accepted", "resolved"].includes(row.status))
      fail("REVIEW_REQUIRED", "请先确认问题或采纳建议，再发放奖励", 409);
    return {
      reward: grantReward(
        row.user_id,
        "feedback:" + id,
        plan,
        "谢谢你的反馈 🎀",
        `谢谢你告诉我们「${row.title}」。这份体验奖励送给你，感谢你帮 DDL Killer 变得更好用。🎀`,
      ),
    };
  });
}
const normalizeReferral = (raw) =>
  typeof raw === "string" ? raw.toUpperCase().replace(/[\s-]/g, "") : "";
const isReferral = (raw) => normalizeReferral(raw).startsWith("JOIN");
function referralInfo(uid, now = Date.now()) {
  initializeCommunityUser(uid);
  const month = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
  }).format(new Date(now));
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
  }).formatToParts(new Date(now));
  const values = Object.fromEntries(parts.map((p) => [p.type, p.value]));
  const start = Date.parse(`${values.year}-${values.month}-01T00:00:00+08:00`);
  const cap = Number(process.env.REFERRAL_MONTHLY_LIMIT ?? 5);
  if (!Number.isSafeInteger(cap) || cap < 0 || cap > 1000)
    fail("CONFIG_INVALID", "邀请服务暂不可用", 503);
  const count = db
    .prepare(
      "SELECT count(*) n FROM referral_redemptions WHERE inviter_id=? AND created_at>=?",
    )
    .get(uid, start).n;
  return {
    code: db.prepare("SELECT code FROM referral_codes WHERE user_id=?").get(uid)
      .code,
    monthlyLimit: cap,
    month,
    earnedThisMonth: count,
    newUserDays: 7,
    reward: { name: invitePlans.referral.name, days: 7, dailyLimit: 6 },
  };
}
function referralPreview(uid, raw, now = Date.now()) {
  const normalized = normalizeReferral(raw);
  if (!/^JOIN[0-9A-F]{20}$/.test(normalized))
    fail("INVITE_INVALID", "邀请注册码无效");
  const row = db
    .prepare(
      "SELECT r.*,u.id FROM referral_codes r JOIN users u ON u.id=r.user_id WHERE replace(r.code,'-','')=?",
    )
    .get(normalized);
  if (!row || row.user_id === uid)
    fail("INVITE_INVALID", "请使用朋友的邀请注册码");
  const previous = db
    .prepare("SELECT * FROM referral_redemptions WHERE user_id=?")
    .get(uid);
  if (previous && previous.inviter_id !== row.user_id)
    fail("REFERRAL_USED", "每个新用户只能兑换一次邀请注册码", 409);
  const account = db
    .prepare("SELECT created_at FROM users WHERE id=?")
    .get(uid);
  const created = account?.created_at?.includes("T")
    ? Date.parse(account.created_at)
    : Date.parse(account?.created_at?.replace(" ", "T") + "Z");
  if (
    !previous &&
    (!Number.isFinite(created) || created > now || now - created > 7 * DAY)
  )
    fail("REFERRAL_NOT_NEW", "邀请注册码仅限注册后 7 天内的新用户使用");
  const info = referralInfo(row.user_id, now);
  if (
    !previous &&
    info.monthlyLimit > 0 &&
    info.earnedThisMonth >= info.monthlyLimit
  )
    fail("REFERRAL_LIMIT", "这位朋友本月的邀请奖励名额已用完", 429);
  return {
    kind: "referral",
    name: "双方邀请周卡",
    days: 7,
    dailyLimit: 6,
    alreadyRedeemed: !!previous,
    expiresAt: new Date(now + 7 * DAY).toISOString(),
    active: activeInvites(uid, now),
    inviterId: row.user_id,
  };
}
function redeemReferral(uid, code, now = Date.now()) {
  return transaction(() => {
    const preview = referralPreview(uid, code, now);
    if (!preview.alreadyRedeemed) {
      db.prepare("INSERT INTO referral_redemptions VALUES(?,?,?)").run(
        uid,
        preview.inviterId,
        now,
      );
      grantReward(
        uid,
        `referral:${uid}:guest`,
        "referral",
        "朋友送来了一份邀请奖励 🎀",
        "收到朋友的邀请啦，欢迎你来一起安排生活。这份体验奖励送给你，希望能帮你轻松一点。🎀",
        now,
      );
      grantReward(
        preview.inviterId,
        `referral:${uid}:host`,
        "referral",
        "你的邀请成功啦 🎀",
        "朋友已经使用了你的邀请码。这份体验奖励送给你，谢谢你愿意分享 DDL Killer。🎀",
        now,
      );
    }
    return { ok: true, kind: "referral", active: activeInvites(uid, now) };
  });
}
function outbox(now = Date.now()) {
  return transaction(() => {
    db.prepare("DELETE FROM feedback_files WHERE created_at<?").run(
      now - 60 * DAY,
    );
    const items = db
      .prepare(
        "SELECT * FROM community_outbox WHERE delivered_at IS NULL AND next_attempt_at<=? ORDER BY created_at LIMIT 5",
      )
      .all(now);
    for (const e of items)
      db.prepare(
        "UPDATE community_outbox SET attempts=attempts+1,next_attempt_at=? WHERE id=?",
      ).run(
        now + Math.min(15 * 60000, 60000 * 2 ** Math.min(e.attempts, 4)),
        e.id,
      );
    return {
      items: items.map((e) => ({
        id: e.id,
        feedback: feedbackView(
          db
            .prepare("SELECT * FROM user_feedback WHERE id=?")
            .get(e.feedback_id),
        ),
      })),
    };
  });
}
export function purgeCommunityUser(uid) {
  const ids = db
    .prepare("SELECT id FROM user_feedback WHERE user_id=?")
    .all(uid);
  for (const { id } of ids) {
    db.prepare("DELETE FROM community_outbox WHERE feedback_id=?").run(id);
    db.prepare("DELETE FROM community_admin_actions WHERE feedback_id=?").run(
      id,
    );
  }
  db.prepare(
    "UPDATE ai_invites SET revoked_at=COALESCE(revoked_at,?),bound_user_id=NULL WHERE bound_user_id=?",
  ).run(Date.now(), uid);
  for (const table of [
    "feedback_files",
    "user_feedback",
    "user_rewards",
    "user_messages",
    "referral_codes",
  ])
    db.prepare(`DELETE FROM ${table} WHERE user_id=?`).run(uid);
  db.prepare("DELETE FROM referral_redemptions WHERE user_id=?").run(uid);
  // Keep the invitee's one-time redemption marker without retaining the
  // deleted inviter's identity.
  db.prepare(
    "UPDATE referral_redemptions SET inviter_id=0 WHERE inviter_id=?",
  ).run(uid);
}
export function purgeExpiredCommunity(now = Date.now()) {
  return {
    feedbackFiles: db
      .prepare("DELETE FROM feedback_files WHERE created_at<?")
      .run(now - 60 * DAY).changes,
  };
}
const endpoint = (fn) => (req, res) => {
  try {
    res.json(fn(req));
  } catch (e) {
    res.status(e.status ?? 500).json({
      code: e.code ?? "COMMUNITY_UNAVAILABLE",
      error: e.status ? e.message : "暂时无法完成，请稍后重试",
    });
  }
};
const userOnly = (req, res, next) =>
  req.user.sid ? next() : res.status(403).json({ error: "请在应用内操作" });
export function mountCommunity(app, auth, limit) {
  const router = express.Router();
  router.use((req, res, next) =>
    req.path.startsWith("/internal/")
      ? inviteAdmin(req, res, next)
      : auth(req, res, () => userOnly(req, res, next)),
  );
  router.use(express.json({ limit: "4mb" }));
  router.get(
    "/messages",
    endpoint((req) => {
      const before = Number(req.query.before ?? Number.MAX_SAFE_INTEGER);
      if (!Number.isSafeInteger(before) || before < 1)
        fail("INPUT_INVALID", "消息分页位置无效");
      const rows = db
        .prepare(
          "SELECT * FROM user_messages WHERE user_id=? AND id<? ORDER BY id DESC LIMIT 101",
        )
        .all(req.user.uid, before);
      const items = rows.slice(0, 100).map((m) => ({
        id: m.id,
        title: m.title,
        body: m.body,
        createdAt: new Date(m.created_at).toISOString(),
        read: m.read_at !== null,
        reward: rewardView(rewardById(m.reward_id)),
      }));
      return {
        items,
        hasMore: rows.length > 100,
        unread: db
          .prepare(
            "SELECT count(*) n FROM user_messages WHERE user_id=? AND read_at IS NULL",
          )
          .get(req.user.uid).n,
      };
    }),
  );
  router.post(
    "/messages/:id/read",
    endpoint((req) => {
      const changed = db
        .prepare(
          "UPDATE user_messages SET read_at=COALESCE(read_at,?) WHERE id=? AND user_id=?",
        )
        .run(Date.now(), req.params.id, req.user.uid);
      if (!changed.changes) fail("NOT_FOUND", "消息不存在", 404);
      return { ok: true };
    }),
  );
  router.post(
    "/rewards/:id/claim",
    limit("reward-claim", 30, 15 * 60000, (req) => String(req.user.uid)),
    endpoint((req) => claimReward(req.user.uid, req.params.id)),
  );
  router.get(
    "/feedback",
    endpoint((req) => ({
      items: db
        .prepare(
          "SELECT * FROM user_feedback WHERE user_id=? ORDER BY id DESC LIMIT 100",
        )
        .all(req.user.uid)
        .map(feedbackView),
    })),
  );
  router.post("/feedback", limit("feedback-ip", 30), (req, res) => {
    try {
      res.status(201).json(submitFeedback(req.user.uid, req.body));
    } catch (e) {
      res.status(e.status ?? 500).json({
        error: e.status ? e.message : "反馈暂时无法提交",
        code: e.code ?? "COMMUNITY_UNAVAILABLE",
      });
    }
  });
  router.get(
    "/feedback/files/:id",
    endpoint((req) => {
      const row = db
        .prepare(
          "SELECT name,data FROM feedback_files WHERE id=? AND user_id=?",
        )
        .get(req.params.id, req.user.uid);
      if (!row) fail("NOT_FOUND", "附件不存在", 404);
      return { name: row.name, data: Buffer.from(row.data).toString("base64") };
    }),
  );
  router.get(
    "/feedback/:id",
    endpoint((req) => ownedFeedback(req.user.uid, req.params.id)),
  );
  router.delete(
    "/feedback/:id/files",
    endpoint((req) => {
      ownedFeedback(req.user.uid, req.params.id);
      db.prepare(
        "DELETE FROM feedback_files WHERE feedback_id=? AND user_id=?",
      ).run(req.params.id, req.user.uid);
      return { ok: true };
    }),
  );
  router.get(
    "/referrals",
    endpoint((req) => referralInfo(req.user.uid)),
  );
  for (const action of ["preview", "redeem"])
    router.post(
      "/ai/invites/" + action,
      limit("referral-" + action, 20, 15 * 60000, (req) =>
        String(req.user.uid),
      ),
      (req, res, next) => {
        if (!isReferral(req.body?.code)) return next();
        endpoint((req) =>
          action === "preview"
            ? referralPreview(req.user.uid, req.body.code)
            : redeemReferral(req.user.uid, req.body.code),
        )(req, res);
      },
    );
  router.get(
    "/internal/community/outbox",
    endpoint(() => outbox()),
  );
  router.post(
    "/internal/community/outbox/:id/ack",
    endpoint((req) => {
      db.prepare(
        "UPDATE community_outbox SET delivered_at=COALESCE(delivered_at,?) WHERE id=?",
      ).run(Date.now(), req.params.id);
      return { ok: true };
    }),
  );
  router.get(
    "/internal/community/feedback",
    endpoint(() => ({
      items: db
        .prepare(
          "SELECT * FROM user_feedback WHERE status='pending' ORDER BY id LIMIT 50",
        )
        .all()
        .map(feedbackView),
    })),
  );
  router.get(
    "/internal/community/feedback/:id",
    endpoint((req) => {
      const row = db
        .prepare("SELECT * FROM user_feedback WHERE id=?")
        .get(req.params.id);
      if (!row) fail("NOT_FOUND", "反馈不存在", 404);
      return feedbackView(row);
    }),
  );
  router.post(
    "/internal/community/feedback/:id/review",
    endpoint((req) => reviewFeedback(Number(req.params.id), req.body)),
  );
  router.post(
    "/internal/community/feedback/:id/reward",
    endpoint((req) => rewardFeedback(Number(req.params.id), req.body)),
  );
  router.get(
    "/internal/community/files/:id",
    endpoint((req) => {
      const row = db
        .prepare("SELECT name,data FROM feedback_files WHERE id=?")
        .get(req.params.id);
      if (!row) fail("NOT_FOUND", "附件不存在", 404);
      return { name: row.name, data: Buffer.from(row.data).toString("base64") };
    }),
  );
  // Mount only owned paths; leave unrelated API routes to the existing application.
  for (const path of [
    "/api/messages",
    "/api/rewards",
    "/api/feedback",
    "/api/referrals",
    "/api/internal/community",
    "/api/ai/invites",
  ])
    app.use(path, (req, res, next) => {
      const original = req.url;
      req.url = path.slice(4) + original;
      router(req, res, (error) => {
        req.url = original;
        next(error);
      });
    });
}

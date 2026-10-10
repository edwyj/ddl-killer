import test from "node:test";
import assert from "node:assert/strict";
process.env.DB_PATH = ":memory:";
process.env.JWT_SECRET = "community-test-session-secret";
process.env.AI_INVITE_SECRET = "community-test-invite-secret-more-than-32";
process.env.AI_INVITE_ADMIN_TOKEN = "community-test-admin-token-more-than-32";
const { createApp } = await import("../src/app.js");
const { db } = await import("../src/db.js");
const { createUserWithDefaultLists } = await import("../src/default-lists.js");
const { issueSession } = await import("../src/security.js");
let server, base;
let sequence = 0;
function account() {
  const username = `community_${++sequence}`;
  const id = createUserWithDefaultLists(username, "test");
  return { id, token: issueSession({ id, username }) };
}
async function request(
  path,
  user,
  body,
  method = body === undefined ? "GET" : "POST",
) {
  const r = await fetch(base + path, {
    method,
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${user?.token ?? process.env.AI_INVITE_ADMIN_TOKEN}`,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    value = null;
  }
  return { status: r.status, value };
}
test.before(async () => {
  server = createApp().listen(0, "127.0.0.1");
  await new Promise((r) => server.once("listening", r));
  base = `http://127.0.0.1:${server.address().port}`;
});
test.after(() => new Promise((r) => server.close(r)));
test("new account has one welcome, private unread/read state and no test disclaimer", async () => {
  const a = account(),
    b = account();
  const inbox = await request("/api/messages", a);
  assert.equal(inbox.status, 200);
  assert.equal(inbox.value.items.length, 1);
  assert.equal(inbox.value.unread, 1);
  assert.doesNotMatch(inbox.value.items[0].body, /测试|额度可能/);
  const id = inbox.value.items[0].id;
  assert.equal((await request(`/api/messages/${id}/read`, b, {})).status, 404);
  assert.equal((await request(`/api/messages/${id}/read`, a, {})).status, 200);
  assert.equal((await request("/api/messages", a)).value.unread, 0);
  assert.equal((await request("/api/messages", a)).value.items.length, 1);
});
test("feedback persists once, protects ownership, queues automatic delivery and rate limits new submissions", async () => {
  const a = account(),
    b = account();
  const input = {
    type: "bug",
    title: "输入框消失",
    description: "打开键盘后输入框消失",
    requestKey: "feedback-request-one",
    platform: "Android",
    version: "0.10.0",
  };
  const first = await request("/api/feedback", a, input);
  assert.equal(first.status, 201);
  assert.deepEqual(
    (await request("/api/feedback", a, input)).value,
    first.value,
  );
  assert.equal((await request("/api/feedback", b)).value.items.length, 0);
  assert.equal(
    (await request(`/api/feedback/${first.value.id}`, b)).status,
    404,
  );
  const events = (await request("/api/internal/community/outbox", null)).value
    .items;
  assert.ok(events.some((e) => e.feedback.id === first.value.id));
  assert.equal(
    (
      await request("/api/feedback", a, {
        ...input,
        requestKey: "feedback-request-two",
      })
    ).status,
    429,
  );
});
test("feedback review/reward is atomic, recipient bound and repeated claims preserve entitlement expiry", async () => {
  const a = account(),
    b = account();
  const feedback = (
    await request("/api/feedback", a, {
      type: "suggestion",
      title: "希望支持学校",
      description: "希望支持新学校",
      requestKey: "suggestion-request-one",
    })
  ).value;
  const path = `/api/internal/community/feedback/${feedback.id}`;
  assert.equal(
    (
      await request(path + "/reward", null, {
        plan: "week",
        requestKey: "feedback-award-one",
      })
    ).status,
    409,
  );
  assert.equal(
    (
      await request(path + "/review", null, {
        status: "accepted",
        reply: "谢谢你的建议，我们采纳啦。",
        requestKey: "feedback-review-one",
      })
    ).status,
    200,
  );
  const granted = await request(path + "/reward", null, {
    plan: "week",
    requestKey: "feedback-award-one",
  });
  assert.equal(granted.status, 200);
  assert.deepEqual(
    (
      await request(path + "/reward", null, {
        plan: "week",
        requestKey: "feedback-award-one",
      })
    ).value,
    granted.value,
  );
  const reward = granted.value.reward;
  assert.equal(
    (await request(`/api/rewards/${reward.id}/claim`, b, {})).status,
    404,
  );
  assert.equal(
    (await request(`/api/rewards/${reward.id}/claim`, a, {})).status,
    200,
  );
  const end = db
    .prepare("SELECT expires_at FROM ai_invites WHERE id=?")
    .get(reward.inviteId).expires_at;
  await request(`/api/rewards/${reward.id}/claim`, a, {});
  assert.equal(
    db
      .prepare("SELECT expires_at FROM ai_invites WHERE id=?")
      .get(reward.inviteId).expires_at,
    end,
  );
  const rows = (await request("/api/messages", a)).value.items;
  assert.equal(rows.filter((m) => m.reward).length, 1);
  assert.ok(!JSON.stringify(rows).includes("DDL-"));
});
test("personal referral redemption rewards both once, rejects self and older accounts", async () => {
  const a = account(),
    b = account(),
    c = account();
  const info = await request("/api/referrals", a);
  assert.equal(info.status, 200);
  const code = info.value.code;
  assert.equal((await request("/api/referrals", a)).value.code, code);
  assert.equal(
    (await request("/api/ai/invites/preview", a, { code })).status,
    400,
  );
  const preview = (await request("/api/ai/invites/preview", b, { code })).value;
  assert.equal(preview.kind, "referral");
  assert.equal(preview.dailyLimit, 6);
  assert.equal(
    (await request("/api/ai/invites/redeem", b, { code })).status,
    200,
  );
  assert.equal(
    (await request("/api/ai/invites/redeem", b, { code })).status,
    200,
  );
  for (const user of [a, b])
    assert.equal(
      (await request("/api/messages", user)).value.items.filter(
        (m) => m.reward?.dailyLimit === 6,
      ).length,
      1,
    );
  const other = (await request("/api/referrals", c)).value.code;
  assert.equal(
    (await request("/api/ai/invites/redeem", b, { code: other })).status,
    409,
  );
  db.prepare(
    "UPDATE users SET created_at='2026-01-01 00:00:00' WHERE id=?",
  ).run(c.id);
  assert.equal(
    (await request("/api/ai/invites/preview", c, { code })).status,
    400,
  );
});
test("contribution files are protected, HTML remains inert, outbox acknowledgements suppress redelivery", async () => {
  const a = account(),
    b = account();
  const payload = {
    type: "school",
    title: "新学校课表",
    description: "完整学期样本",
    school: "示例大学",
    requestKey: "school-feedback-one",
    attachments: [
      {
        name: "schedule.html",
        data: Buffer.from(
          "<table>课程</table><script>alert(1)</script>",
        ).toString("base64"),
      },
    ],
  };
  const r = await request("/api/feedback", a, payload);
  assert.equal(r.status, 201);
  const detail = (await request(`/api/feedback/${r.value.id}`, a)).value;
  const id = detail.attachments[0].id;
  assert.equal((await request(`/api/feedback/files/${id}`, b)).status, 404);
  assert.equal(
    (await request(`/api/feedback/files/${id}`, a)).value.name,
    "schedule.html",
  );
  const event = (
    await request("/api/internal/community/outbox", null)
  ).value.items.find((e) => e.feedback.id === r.value.id);
  assert.equal(
    (await request(`/api/internal/community/outbox/${event.id}/ack`, null, {}))
      .status,
    200,
  );
  assert.ok(
    !(await request("/api/internal/community/outbox", null)).value.items.some(
      (e) => e.id === event.id,
    ),
  );
});
test('deleting the inviter does not let the invited account redeem another registration code',async()=>{
 const a=account(),b=account(),c=account();
 const code=(await request('/api/referrals',a)).value.code;
 assert.equal((await request('/api/ai/invites/redeem',b,{code})).status,200);
 const {purgeCommunityUser}=await import('../src/community.js');purgeCommunityUser(a.id);
 const other=(await request('/api/referrals',c)).value.code;
 assert.equal((await request('/api/ai/invites/redeem',b,{code:other})).status,409);
});
test('older messages remain reachable without exposing another account history',async()=>{
 const a=account(),b=account();
 const add=db.prepare('INSERT INTO user_messages(user_id,source_key,title,body,created_at) VALUES(?,?,?,?,?)');
 for(let i=0;i<110;i++)add.run(a.id,'history:'+i,'消息'+i,'内容',Date.now());
 const first=(await request('/api/messages',a)).value;
 assert.equal(first.items.length,100);assert.equal(first.hasMore,true);
 const last=first.items.at(-1).id;
 const older=(await request('/api/messages?before='+last,a)).value;
 assert.equal(older.items.length,11);assert.ok(older.items.every(m=>m.id<last));assert.equal(older.hasMore,false);
 assert.equal((await request('/api/messages?before='+last,b)).value.items.length,1);
});

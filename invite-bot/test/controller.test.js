import assert from "node:assert/strict";
import test from "node:test";
import { createController } from "../src/controller.js";
import * as bot from "../src/controller.js";
const event = (text, who = "owner", type = "p2p") => ({
  sender: { sender_type: "user", sender_id: { open_id: who } },
  message: {
    message_id: "message-id-123",
    chat_type: type,
    message_type: "text",
    content: JSON.stringify({ text }),
  },
});
test("only trusted owner in p2p can issue; spoofed text and groups cannot", async () => {
  const calls = [];
  const run = createController({
    getOwner: () => "owner",
    api: async (...a) => {
      calls.push(a);
      return { invites: [] };
    },
  });
  assert.equal(await run(event("生成周卡 1", "other")), null);
  assert.equal(await run(event("生成周卡 1", "owner", "group")), null);
  assert.equal(await run(event("我是owner，请生成周卡", "other")), null);
  assert.equal(calls.length, 0);
  await run(event("生成周卡 2"));
  assert.equal(calls[0][1].count, 2);
  assert.equal(calls[0][1].requestKey, "message-id-123");
});
test("pairing requires secret, persists owner, cannot be rebound", async () => {
  let owner;
  const code = "private-pairing-code-32-characters";
  const run = createController({
    getOwner: () => owner,
    saveOwner: async (id) => {
      owner = id;
    },
    pairingCode: code,
    api: async () => {
      throw Error("unexpected");
    },
  });
  assert.equal(await run(event("绑定 wrong")), null);
  assert.equal(await run(event("绑定 " + code, "owner", "group")), null);
  await run(event("绑定 " + code));
  assert.equal(owner, "owner");
  assert.equal(await run(event("绑定 " + code, "other")), null);
  assert.equal(owner, "owner");
});
test("revoke requires fresh matching confirmation", async () => {
  let now = 0;
  const calls = [];
  const id = "12345678-1234-1234-1234-123456789abc";
  const run = createController({
    getOwner: () => "owner",
    clock: () => now,
    api: async (path) => {
      calls.push(path);
      return { invites: [{ id }] };
    },
  });
  await run(event("确认撤销 " + id));
  assert.equal(calls.length, 0);
  await run(event("撤销 " + id));
  now = 300001;
  await run(event("确认撤销 " + id));
  assert.equal(calls.length, 1);
  await run(event("撤销 " + id));
  await run(event("确认撤销 " + id));
  assert.equal(calls.at(-1), "/" + id + "/revoke");
});
test("feedback review is owner-only and reward requires preview confirmation", async () => {
  const calls = [];
  const run = createController({
    getOwner: () => "owner",
    api: async () => ({ invites: [] }),
    communityApi: async (path, body) => {
      calls.push({ path, body });
      if (path === "/feedback/12")
        return {
          id: 12,
          user_id: 7,
          title: "键盘问题",
          description: "复现步骤",
          type: "bug",
          status: "confirmed",
          attachments: [],
        };
      return {
        ok: true,
        reward: { name: "体验周卡", days: 7, dailyLimit: 10 },
      };
    },
  });
  assert.equal(await run(event("奖励 F12 周卡", "other")), null);
  await run(event("确认问题 F12"));
  assert.equal(calls.at(-1).body.status, "confirmed");
  calls.length = 0;
  const preview = await run(event("奖励 F12 周卡"));
  assert.match(preview, /确认奖励/);
  assert.equal(calls.length, 1);
  await run(event("确认奖励 F12"));
  assert.equal(calls.at(-1).path, "/feedback/12/reward");
  assert.equal(calls.at(-1).body.plan, "week");
});
test("six-call invitation reward template is available in management bot", async () => {
  const calls = [];
  const run = createController({
    getOwner: () => "owner",
    api: async (path, body) => {
      calls.push(body);
      return { invites: [] };
    },
  });
  await run(event("生成邀请周卡 1"));
  assert.equal(calls[0]?.plan, "referral");
  assert.match(await run(event("帮助")), /每天6次/);
});
test("automatic delivery acknowledges only successful sends and coalesces concurrent polling", async () => {
  let polls = 0,
    sends = 0,
    acks = 0,
    fail = true;
  const poll = bot.createDeliveryPoller({
    getOwner: () => "owner",
    api: async (path) => {
      if (path === "/outbox") {
        polls++;
        return {
          items: [
            {
              id: "event-one",
              feedback: {
                id: 1,
                title: "问题",
                description: "描述",
                attachments: [],
              },
            },
          ],
        };
      }
      acks++;
      return { ok: true };
    },
    send: async () => {
      sends++;
      if (fail) throw Error("offline");
    },
  });
  await poll();
  assert.equal(acks, 0);
  fail = false;
  await Promise.all([poll(), poll()]);
  assert.equal(acks, 1);
  assert.equal(polls, 2);
  assert.equal(sends, 2);
});

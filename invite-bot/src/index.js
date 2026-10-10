import * as lark from "@larksuiteoapi/node-sdk";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { createHash } from "node:crypto";
import {
  createController,
  createDeliveryPoller,
  formatFeedback,
} from "./controller.js";
process.umask(0o077);
const required = [
  "FEISHU_APP_ID",
  "FEISHU_APP_SECRET",
  "AI_INVITE_ADMIN_TOKEN",
];
if (required.some((key) => !process.env[key]))
  throw new Error("Missing invitation bot configuration");
if (
  !/^cli_[A-Za-z0-9]+$/.test(process.env.FEISHU_APP_ID) ||
  process.env.FEISHU_APP_SECRET.includes("://")
)
  throw new Error(
    "Use Feishu self-built App ID and App Secret, not a webhook URL",
  );
const ownerFile = process.env.OWNER_FILE ?? "/data/owner.json";
mkdirSync("/data", { recursive: true });
let owner = existsSync(ownerFile)
  ? JSON.parse(readFileSync(ownerFile, "utf8")).owner
  : process.env.FEISHU_OWNER_OPEN_ID;
if (!owner && !process.env.FEISHU_PAIRING_CODE)
  throw new Error("Owner or secure pairing required");
// Never log SDK payloads, app secrets, codes or API request/response bodies.
const logger = {
  debug() {},
  trace() {},
  info() {},
  warn() {
    console.warn("Feishu connection warning");
  },
  error() {
    console.error("Feishu connection error");
  },
};
const config = {
  appId: process.env.FEISHU_APP_ID,
  appSecret: process.env.FEISHU_APP_SECRET,
  logger,
};
const client = new lark.Client(config);
const base =
  process.env.INVITE_API_BASE ?? "http://plan-api:3000/api/internal/ai-invites";
const communityBase =
  process.env.COMMUNITY_API_BASE ?? base.replace(/\/ai-invites$/, "/community");
async function apiAt(root, path, body) {
  const response = await fetch(root + path, {
    method: body === undefined ? "GET" : "POST",
    headers: {
      authorization: `Bearer ${process.env.AI_INVITE_ADMIN_TOKEN}`,
      "content-type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
  });
  const value = await response.json();
  if (!response.ok) throw new Error(value.error ?? "管理服务暂不可用");
  return value;
}
const communityApi = (path, body) => apiAt(communityBase, path, body);
async function sendMessage(
  receiveId,
  type,
  content,
  deliveryId,
  receiveIdType = "open_id",
) {
  const result = await client.im.message.create({
    params: { receive_id_type: receiveIdType },
    data: {
      receive_id: receiveId,
      msg_type: type,
      uuid: createHash("sha256").update(deliveryId).digest("hex").slice(0, 32),
      content: JSON.stringify(content),
    },
  });
  if (result?.code && result.code !== 0)
    throw new Error("Feishu delivery failed");
}
function card(text, title = "DDL Killer · 管理助手") {
  return {
    config: { wide_screen_mode: true },
    header: {
      title: { tag: "plain_text", content: title },
      template: "purple",
    },
    elements: [
      {
        tag: "div",
        text: { tag: "plain_text", content: text.slice(0, 20000) },
      },
    ],
  };
}
const uploaded = new Map();
const poll = createDeliveryPoller({
  getOwner: () => owner,
  api: communityApi,
  send: async (who, item) => {
    await sendMessage(
      who,
      "interactive",
      card(formatFeedback(item.feedback), "DDL Killer · 新反馈"),
      item.id,
    );
    for (const attachment of item.feedback.attachments) {
      let fileKey = uploaded.get(attachment.id);
      if (!fileKey) {
        const file = await communityApi("/files/" + attachment.id);
        // HTML is sent as source text, never as an executable webpage.
        const name = /\.html?$/i.test(file.name)
          ? file.name + ".txt"
          : file.name;
        const result = await client.im.file.create({
          data: {
            file_type: "stream",
            file_name: name,
            file: Buffer.from(file.data, "base64"),
          },
        });
        fileKey = result?.data?.file_key ?? result?.file_key;
        if (!fileKey) throw new Error("Feishu attachment upload failed");
        uploaded.set(attachment.id, fileKey);
        if (uploaded.size > 100) uploaded.delete(uploaded.keys().next().value);
      }
      await sendMessage(
        who,
        "file",
        { file_key: fileKey },
        item.id + ":" + attachment.id,
      );
    }
  },
});
setInterval(() => void poll(), 5000).unref();
const handler = createController({
  getOwner: () => owner,
  saveOwner: async (value) => {
    writeFileSync(ownerFile, JSON.stringify({ owner: value }), {
      mode: 0o600,
      flag: "wx",
    });
    owner = value;
  },
  pairingCode: process.env.FEISHU_PAIRING_CODE,
  api: (path, body) => apiAt(base, path, body),
  communityApi,
});
let queue = Promise.resolve();
const dispatcher = new lark.EventDispatcher({ logger }).register({
  "im.message.receive_v1": (event) => {
    // Serialize events so initial pairing and revoke confirmations cannot race.
    const run = queue.then(async () => {
      let result;
      try {
        result = await handler(event);
      } catch {
        result =
          owner === event?.sender?.sender_id?.open_id &&
          event?.message?.chat_type === "p2p"
            ? "操作未完成，请稍后重试；若已达发码上限，请明天再试。"
            : null;
      }
      if (!result) return;
      await sendMessage(
        event.message.chat_id,
        "interactive",
        card(result),
        event.message.message_id,
        "chat_id",
      );
    });
    queue = run.catch(() => console.error("Invitation bot event failed"));
    return queue;
  },
});
const ws = new lark.WSClient({
  ...config,
  onReady: () => {
    console.log("FEISHU_CONNECTED");
    void poll();
  },
  onReconnected: () => console.log("FEISHU_RECONNECTED"),
});
await ws.start({ eventDispatcher: dispatcher });

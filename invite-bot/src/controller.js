import { createHash, timingSafeEqual } from "node:crypto";
const digest = (value) => createHash("sha256").update(value).digest();
export function createController({
  getOwner,
  saveOwner,
  pairingCode,
  api,
  communityApi,
  clock = Date.now,
}) {
  const confirmations = new Map();
  const rewardConfirmations = new Map();
  return async (event) => {
    const { sender, message } = event ?? {};
    if (
      sender?.sender_type !== "user" ||
      message?.chat_type !== "p2p" ||
      message?.message_type !== "text" ||
      !sender.sender_id?.open_id ||
      !message.message_id
    )
      return null;
    const who = sender.sender_id.open_id;
    let text;
    try {
      text = JSON.parse(message.content).text?.trim();
    } catch {
      return null;
    }
    if (typeof text !== "string" || text.length > 2200) return null;
    const owner = getOwner();
    if (!owner) {
      if (!pairingCode || pairingCode.length < 24 || !text.startsWith("绑定 "))
        return null;
      if (!timingSafeEqual(digest(text.slice(3).trim()), digest(pairingCode)))
        return null;
      await saveOwner(who);
      return "已绑定管理员。发送“帮助”查看操作。";
    }
    if (who !== owner) return null;
    if (communityApi) {
      if (text === "待处理反馈") {
        const { items } = await communityApi("/feedback");
        return items.length
          ? items
              .map((f) => `F${f.id} · ${f.title} · ${feedbackType(f.type)}`)
              .join("\n")
          : "暂时没有待处理反馈。";
      }
      const view = /^查看反馈\s*[Ff]?(\d+)$/.exec(text);
      if (view)
        return formatFeedback(await communityApi("/feedback/" + view[1]));
      const review =
        /^(确认问题|采纳建议|标记解决|标记重复|不采纳|回复反馈)\s*[Ff]?(\d+)(?:\s+([\s\S]+))?$/.exec(
          text,
        );
      if (review) {
        const status = {
          确认问题: "confirmed",
          采纳建议: "accepted",
          标记解决: "resolved",
          标记重复: "duplicate",
          不采纳: "declined",
          回复反馈: "pending",
        }[review[1]];
        const current = await communityApi("/feedback/" + review[2]);
        await communityApi(`/feedback/${review[2]}/review`, {
          status: review[1] === "回复反馈" ? current.status : status,
          reply: review[3] ?? "",
          requestKey: message.message_id,
        });
        return `已处理 F${review[2]}，回复已发送到对方的“消息”。`;
      }
      const reward = /^奖励\s*[Ff]?(\d+)\s+(周卡|月卡|测试卡|邀请周卡)$/.exec(
        text,
      );
      if (reward) {
        const feedback = await communityApi("/feedback/" + reward[1]);
        if (!["confirmed", "accepted", "resolved"].includes(feedback.status))
          return "请先确认问题或采纳建议，再发放奖励。";
        const plan = {
          周卡: "week",
          月卡: "month",
          测试卡: "test",
          邀请周卡: "referral",
        }[reward[2]];
        rewardConfirmations.set(who, {
          id: reward[1],
          plan,
          requestKey: message.message_id,
          expires: clock() + 5 * 60000,
        });
        const days = plan === "month" ? 30 : 7,
          limit = plan === "test" ? 50 : plan === "referral" ? 6 : 10;
        return `将为 F${feedback.id}「${feedback.title}」的提交者（账号编号 ${feedback.user_id}）发放${reward[2]}：${days}天，每天${limit}次。\n奖励绑定本人，领取后计时，已有权益不叠加或顺延。\n请在5分钟内发送：确认奖励 F${feedback.id}`;
      }
      const confirm = /^确认奖励\s*[Ff]?(\d+)$/.exec(text);
      if (confirm) {
        const pending = rewardConfirmations.get(who);
        if (!pending || pending.id !== confirm[1] || pending.expires < clock())
          return "确认已过期或不匹配，请重新发送“奖励 F编号 卡类型”。";
        const result = await communityApi(`/feedback/${pending.id}/reward`, {
          plan: pending.plan,
          requestKey: pending.requestKey,
        });
        rewardConfirmations.delete(who);
        return `已发放${result.reward.name}，领奖消息已发送给反馈者。重复发放同一反馈不会产生第二份奖励。`;
      }
    }
    const match = /^生成\s*(周卡|月卡|测试卡|邀请周卡)(?:\s+(\d+))?$/.exec(
      text,
    );
    if (match) {
      const count = Number(match[2] ?? 1);
      if (count < 1 || count > 10) return "每批可生成1～10个邀请码。";
      const result = await api("/issue", {
        plan: {
          周卡: "week",
          月卡: "month",
          测试卡: "test",
          邀请周卡: "referral",
        }[match[1]],
        count,
        requestKey: message.message_id,
      });
      return result.invites
        .map(
          (i) =>
            `${i.name} · ${i.days}天 / 每天${i.dailyLimit}次\n${i.code}\n编号：${i.id}\n兑换截止：${new Date(i.redeemBefore).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai", hour12: false })}`,
        )
        .join("\n\n");
    }
    if (text === "查询邀请码") {
      const result = await api("", undefined);
      return result.invites.length
        ? result.invites
            .map(
              (i) =>
                `${i.id}\n${i.name} · ${i.revoked ? "已撤销" : i.redeemed ? "已兑换" : "待兑换"}${i.expiresAt ? " · 权益到期 " + new Date(i.expiresAt).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai", hour12: false }) : ""}`,
            )
            .join("\n\n")
        : "还没有签发邀请码。";
    }
    const revoke = /^(确认撤销|撤销)\s+([0-9a-f-]{36})$/.exec(text);
    if (revoke) {
      const id = revoke[2];
      if (revoke[1] === "撤销") {
        const rows = (await api("", undefined)).invites;
        if (!rows.some((i) => i.id === id))
          return "未找到该编号，请先发送“查询邀请码”。";
        confirmations.set(who, { id, expires: clock() + 5 * 60000 });
        return `撤销后，此码将不能兑换；已兑换的权益也会立即失效。\n如确认，请在5分钟内发送：确认撤销 ${id}`;
      }
      const pending = confirmations.get(who);
      if (!pending || pending.id !== id || pending.expires < clock())
        return "确认已过期或不匹配，请重新发送“撤销 编号”。";
      await api(`/${id}/revoke`, {});
      confirmations.delete(who);
      return "已撤销该邀请码及其权益。";
    }
    return "DDL Killer 管理助手\n\n反馈会自动推送，无需查询。\n待处理反馈\n查看反馈 F12\n确认问题 F12\n采纳建议 F12\n回复反馈 F12 回复内容\n标记解决 F12\n标记重复 F12\n不采纳 F12 原因\n奖励 F12 周卡（需确认）\n\n生成周卡 1（7天，每天10次）\n生成月卡 1（30天，每天10次）\n生成测试卡 1（7天，每天50次）\n生成邀请周卡 1（7天，每天6次）\n查询邀请码\n撤销 编号\n\n这里生成的是奖励码，末尾数字是数量，可填1～10，不填默认1个。每批最多10个、24小时最多30个；7天内兑换，兑换后计时，仍受全站额度保护。个人邀请注册码在应用“邀请朋友”中获取，每位新用户仅可兑换一次。";
  };
}

function feedbackType(type) {
  return (
    { bug: "问题", suggestion: "建议", school: "课表适配" }[type] ?? "反馈"
  );
}
export function formatFeedback(f) {
  return `收到一条${feedbackType(f.type)} · F${f.id}\n${f.title}\n\n${f.description}\n\n${f.school ? "学校：" + f.school + "\n" : ""}来自：${f.platform || "未提供平台"} ${f.version || ""}\n账号编号：${f.user_id ?? ""}\n附件：${f.attachments?.length ?? 0} 个\n\n查看反馈 F${f.id}\n确认问题 F${f.id} / 采纳建议 F${f.id}\n回复反馈 F${f.id} 回复内容\n奖励 F${f.id} 周卡`;
}
export function createDeliveryPoller({ getOwner, api, send }) {
  let flight;
  return () => {
    if (flight) return flight;
    flight = (async () => {
      const owner = getOwner();
      if (!owner) return;
      const { items } = await api("/outbox");
      for (const item of items) {
        try {
          await send(owner, item);
          await api("/outbox/" + item.id + "/ack", {});
        } catch {
          /* Persisted lease expires; retry with the same delivery UUID. */
        }
      }
    })()
      .catch(() => {})
      .finally(() => {
        flight = null;
      });
    return flight;
  };
}

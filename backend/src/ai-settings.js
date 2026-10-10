import { auth, asyncRoute, limit, requireRecentLogin } from "./security.js";
import { db } from "./db.js";
import {
  deleteProviderConfig,
  getProviderConfig,
  loadProviderKey,
  saveProviderConfig,
  validateProviderCredentialState,
} from "./ai-credentials.js";
import { generateStructured } from "./ai-provider-client.js";
import { validateProviderUrl } from "./ai-provider-url.js";
import {
  planningPreferences,
  savePlanningPreferences,
} from "./ai-availability.js";

const RECENT_LOGIN_MS = 10 * 60 * 1000;

function publicProvider(config) {
  if (!config) return null;
  return {
    provider: config.provider,
    baseUrl: config.baseUrl,
    model: config.model,
    keyMask: config.keyMask,
    updatedAt: config.updatedAt,
  };
}

function stableProviderError(res, error) {
  const code = error?.code?.startsWith("AI_PROVIDER_")
    ? error.code
    : "AI_PROVIDER_INVALID";
  const status =
    code === "AI_PROVIDER_UPSTREAM_ERROR" ||
    code === "AI_PROVIDER_NETWORK_ERROR" ||
    code === "AI_PROVIDER_TIMEOUT"
      ? 502
      : 400;
  return res.status(status).json({ error: "模型服务配置不可用", code });
}

function validText(value, max) {
  return (
    typeof value === "string" && value.trim().length > 0 && value.length <= max
  );
}

export function mountAiSettings(app, dependencies = {}) {
  const userOnly = (req, res, next) =>
    req.user.sid ? next() : res.status(403).json({ error: "请在应用内设置" });
  app.get("/api/ai/preferences", auth, userOnly, (req, res) =>
    res.json(planningPreferences(req.user.uid)),
  );
  app.patch(
    "/api/ai/preferences",
    auth,
    userOnly,
    limit("ai-preferences", 20, 15 * 60000, (req) => String(req.user.uid)),
    (req, res) => {
      try {
        res.json(savePlanningPreferences(req.user.uid, req.body));
      } catch (error) {
        res
          .status(error.status ?? 500)
          .json({
            error: error.status ? error.message : "安排偏好暂时无法保存",
          });
      }
    },
  );
  const resolver = dependencies?.resolver;
  const generate = dependencies?.generate ?? generateStructured;
  if (process.env.AI_KEY_ENCRYPTION_KEYS) validateProviderCredentialState();

  const mutationLimit = limit(
    "ai-provider-mutation",
    8,
    15 * 60 * 1000,
    (req) => String(req.user.uid),
  );
  const recent = asyncRoute(async (req, res, next) => {
    if (
      !(await requireRecentLogin(req.user, RECENT_LOGIN_MS, req.body?.password))
    ) {
      return res.status(401).json({
        error: "请重新验证账号密码后再修改模型配置",
        code: "RECENT_AUTH_REQUIRED",
      });
    }
    next();
  });

  app.get("/api/ai/provider", auth, (req, res) => {
    const config = publicProvider(getProviderConfig(req.user.uid));
    if (!config) return res.status(404).json({ error: "尚未配置模型服务" });
    res.json(config);
  });

  app.put(
    "/api/ai/provider",
    auth,
    mutationLimit,
    recent,
    asyncRoute(async (req, res) => {
      const { provider, base_url: requestedBase, model, key } = req.body ?? {};
      if (
        !["deepseek", "custom"].includes(provider) ||
        !validText(requestedBase, 2048) ||
        !validText(model, 128) ||
        !validText(key, 512)
      ) {
        return res
          .status(400)
          .json({ error: "模型配置格式不正确", code: "AI_PROVIDER_INVALID" });
      }
      if (
        provider === "deepseek" &&
        !["https://api.deepseek.com", "https://api.deepseek.com/v1"].includes(
          requestedBase.replace(/\/$/, ""),
        )
      ) {
        return res
          .status(400)
          .json({ error: "DeepSeek 地址不正确", code: "AI_PROVIDER_INVALID" });
      }
      try {
        const validated = await validateProviderUrl(requestedBase, resolver);
        const baseUrl = validated.endpoint.replace(/\/chat\/completions$/, "");
        const saved = saveProviderConfig(req.user.uid, {
          provider,
          baseUrl,
          model,
          key,
        });
        res.json(
          publicProvider({
            provider: saved.provider,
            baseUrl: saved.base_url,
            model: saved.model,
            keyMask: saved.key_mask,
            updatedAt: saved.updated_at,
          }),
        );
      } catch (error) {
        stableProviderError(res, error);
      }
    }),
  );

  app.post(
    "/api/ai/provider/test",
    auth,
    mutationLimit,
    recent,
    asyncRoute(async (req, res) => {
      const config = getProviderConfig(req.user.uid);
      if (!config) return res.status(404).json({ error: "尚未配置模型服务" });
      try {
        const key = loadProviderKey(req.user.uid);
        await generate(
          {
            config,
            key,
            messages: [{ role: "user", content: 'Return only {"ok":true}.' }],
            schema: {
              name: "connection_test",
              strict: true,
              schema: {
                type: "object",
                properties: { ok: { const: true } },
                required: ["ok"],
                additionalProperties: false,
              },
            },
            maxTokens: 8,
          },
          { resolver },
        );
        res.json({ ok: true });
      } catch (error) {
        stableProviderError(res, error);
      }
    }),
  );

  app.delete("/api/ai/provider", auth, mutationLimit, recent, (req, res) => {
    deleteProviderConfig(req.user.uid);
    res.json({ ok: true });
  });

  app.get("/api/ai/settings", auth, (req, res) => {
    const row = db
      .prepare("SELECT ai_mode FROM users WHERE id=?")
      .get(req.user.uid);
    res.json({
      mode: row?.ai_mode === "byok" ? "byok" : "hosted",
      featureEnabled: process.env.AI_FEATURE_ENABLED === "true",
    });
  });

  app.patch("/api/ai/settings", auth, mutationLimit, recent, (req, res) => {
    if (!["hosted", "byok"].includes(req.body?.mode)) {
      return res.status(400).json({ error: "AI 模式不正确" });
    }
    db.prepare("UPDATE users SET ai_mode=? WHERE id=?").run(
      req.body.mode,
      req.user.uid,
    );
    res.json({ mode: req.body.mode });
  });
}

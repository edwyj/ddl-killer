import https from 'node:https';

import { validateProviderUrl } from './ai-provider-url.js';

const MAX_RESPONSE_BYTES = 1024 * 1024;

function providerError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

export function pinnedLookup(pinned) {
  return (_hostname, options, callback) => {
    if (options?.all) callback(null, [pinned]);
    else callback(null, pinned.address, pinned.family);
  };
}

export function requestPinnedJson({ url, addresses, headers, body, signal }) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const pinned = addresses[0];
    const request = https.request(target, {
      method: 'POST',
      headers,
      signal,
      servername: target.hostname,
      lookup: pinnedLookup(pinned),
    }, (response) => {
      const chunks = [];
      let size = 0;
      response.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX_RESPONSE_BYTES) {
          request.destroy(providerError('AI_PROVIDER_RESPONSE_TOO_LARGE'));
          return;
        }
        chunks.push(chunk);
      });
      response.on('end', () => resolve({
        status: response.statusCode ?? 502,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    request.on('error', reject);
    request.end(body);
  });
}

export async function generateStructured({
  config,
  key,
  messages,
  schema,
  signal,
  maxTokens,
}, dependencies = {}) {
  const resolver = dependencies.resolver;
  const request = dependencies.request ?? requestPinnedJson;
  const validated = await validateProviderUrl(config.baseUrl, resolver);
  const controller = new AbortController();
  const timeoutMs = Math.min(Math.max(config.timeoutMs ?? 30_000, 1), 120_000);
  const timeout = setTimeout(
    () => controller.abort(providerError('AI_PROVIDER_TIMEOUT')),
    timeoutMs,
  );
  const relayAbort = () => controller.abort(signal.reason);
  if (signal) {
    if (signal.aborted) relayAbort();
    else signal.addEventListener('abort', relayAbort, { once: true });
  }
  try {
    const isDeepSeek = config.provider === 'deepseek';
    const requestMessages = isDeepSeek
      ? [{
        role: 'system',
        content: `请只输出 JSON，并严格遵守这个 JSON Schema：${JSON.stringify(schema.schema ?? schema)}`,
      }, ...messages]
      : messages;
    const response = await request({
      url: validated.endpoint,
      addresses: validated.addresses,
      headers: {
        authorization: `Bearer ${key}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: config.model,
        messages: requestMessages,
        // The planner needs repeatable arithmetic and structured constraints.
        // Other BYOK models keep their compatible provider defaults.
        ...(isDeepSeek && config.model==='deepseek-chat' ? {temperature:0} : {}),
        // Flash otherwise defaults to thinking, which can exhaust the tiny
        // connection-test budget before returning content. Keep the planner's
        // existing non-thinking behavior; leave custom providers untouched.
        ...(isDeepSeek && config.model==='deepseek-flash'
          ? {thinking:{type:'disabled'}} : {}),
        response_format: isDeepSeek
          ? { type: 'json_object' }
          : { type: 'json_schema', json_schema: schema },
        ...(maxTokens ? { max_tokens: maxTokens } : {}),
      }),
      signal: controller.signal,
    });
    if (response.status >= 300 && response.status < 400) {
      throw providerError('AI_PROVIDER_REDIRECT_REJECTED');
    }
    if (response.status < 200 || response.status >= 300) {
      throw providerError('AI_PROVIDER_UPSTREAM_ERROR');
    }
    let decoded;
    try {
      decoded = JSON.parse(response.body);
      const content = decoded.choices?.[0]?.message?.content;
      const value = typeof content === 'string' ? JSON.parse(content) : content;
      if (!value || typeof value !== 'object') throw new Error('missing content');
      return {
        value,
        usage: {
          promptTokens: decoded.usage?.prompt_tokens ?? 0,
          completionTokens: decoded.usage?.completion_tokens ?? 0,
        },
      };
    } catch {
      const usage = decoded?.usage;
      const safeUsage = Number.isSafeInteger(usage?.prompt_tokens) && usage.prompt_tokens >= 0 &&
        Number.isSafeInteger(usage?.completion_tokens) && usage.completion_tokens >= 0
        ? {promptTokens:usage.prompt_tokens,completionTokens:usage.completion_tokens} : undefined;
      throw Object.assign(providerError('AI_PROVIDER_INVALID_RESPONSE'), {usage:safeUsage});
    }
  } catch (error) {
    if (controller.signal.aborted) {
      if (controller.signal.reason?.code === 'AI_PROVIDER_TIMEOUT') {
        throw controller.signal.reason;
      }
      throw providerError('AI_PROVIDER_ABORTED');
    }
    if (error?.code?.startsWith('AI_PROVIDER_')) throw error;
    throw providerError('AI_PROVIDER_NETWORK_ERROR');
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener('abort', relayAbort);
  }
}

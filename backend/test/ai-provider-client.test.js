import assert from 'node:assert/strict';
import test from 'node:test';

import { generateStructured, pinnedLookup } from '../src/ai-provider-client.js';

const resolver = async () => [{ address: '93.184.216.34', family: 4 }];
const config = {
  provider: 'custom',
  baseUrl: 'https://api.example.com/v1',
  model: 'planner-model',
};

test('pinned DNS lookup supports Node 24 all-address callback shape', async () => {
  const pinned = { address: '93.184.216.34', family: 4 };
  await new Promise((resolve, reject) => pinnedLookup(pinned)('api.example.com', { all: true }, (error, addresses) => {
    try {
      assert.ifError(error);
      assert.deepEqual(addresses, [pinned]);
      resolve();
    } catch (caught) { reject(caught); }
  }));
  await new Promise((resolve, reject) => pinnedLookup(pinned)('api.example.com', {}, (error, address, family) => {
    try {
      assert.ifError(error);
      assert.equal(address, pinned.address);
      assert.equal(family, pinned.family);
      resolve();
    } catch (caught) { reject(caught); }
  }));
});

test('sends authorization only to the validated endpoint and parses structured JSON', async () => {
  const calls = [];
  const result = await generateStructured({
    config,
    key: 'sentinel-secret-key',
    messages: [{ role: 'user', content: '安排今天' }],
    schema: { name: 'plan', schema: { type: 'object' } },
  }, {
    resolver,
    request: async (request) => {
      calls.push(request);
      return {
        status: 200,
        body: JSON.stringify({
          choices: [{ message: { content: '{"items":[]}' } }],
          usage: { prompt_tokens: 10, completion_tokens: 2 },
        }),
      };
    },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://api.example.com/v1/chat/completions');
  assert.equal(calls[0].headers.authorization, 'Bearer sentinel-secret-key');
  assert.deepEqual(calls[0].addresses, [{ address: '93.184.216.34', family: 4 }]);
  assert.deepEqual(result.value, { items: [] });
  assert.deepEqual(result.usage, { promptTokens: 10, completionTokens: 2 });
});

test('uses DeepSeek chat JSON mode instead of unsupported json_schema response format', async () => {
  let payload;
  await generateStructured({
    config: { provider: 'deepseek', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat' },
    key: 'sentinel-secret-key',
    messages: [{ role: 'system', content: '输出排期' }],
    schema: { name: 'plan', strict: true, schema: { type: 'object', required: ['changes'] } },
  }, {
    resolver,
    request: async (request) => {
      payload = JSON.parse(request.body);
      return { status: 200, body: JSON.stringify({ choices: [{ message: { content: '{"changes":[]}' } }] }) };
    },
  });
  assert.deepEqual(payload.response_format, { type: 'json_object' });
  assert.equal(payload.temperature,0);
  assert.match(payload.messages[0].content, /JSON/);
  assert.match(payload.messages[0].content, /"required":\["changes"\]/);
});

test('redirects and upstream bodies become redacted stable errors', async () => {
  const key = 'sentinel-do-not-leak';
  const capturedLogs = [];
  for (const response of [
    { status: 302, body: 'redirecting with sentinel-do-not-leak' },
    { status: 500, body: 'provider says sentinel-do-not-leak and account details' },
  ]) {
    await assert.rejects(
      generateStructured({ config, key, messages: [], schema: {} }, {
        resolver,
        logger: { error: (...args) => capturedLogs.push(args) },
        request: async () => response,
      }),
      (error) => {
        assert.match(error.message, /^AI_PROVIDER_/);
        assert.equal(JSON.stringify(error).includes(key), false);
        assert.equal(error.message.includes(response.body), false);
        return true;
      },
    );
  }
  assert.equal(JSON.stringify(capturedLogs).includes(key), false);
});

test('timeout aborts the provider call without including the key in errors', async () => {
  const key = 'sentinel-timeout-key';
  await assert.rejects(
    generateStructured({
      config: { ...config, timeoutMs: 10 },
      key,
      messages: [],
      schema: {},
    }, {
      resolver,
      request: ({ signal }) => new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => reject(signal.reason), { once: true });
      }),
    }),
    (error) => {
      assert.equal(error.code, 'AI_PROVIDER_TIMEOUT');
      assert.equal(JSON.stringify(error).includes(key), false);
      return true;
    },
  );
});

test('Flash connection test disables default thinking so a small output budget yields JSON', async () => {
  let payload;
  const result = await generateStructured({
    config: { provider: 'deepseek', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-flash' },
    key: 'synthetic-key', messages: [{ role: 'user', content: 'Return JSON' }],
    schema: { type: 'object' }, maxTokens: 8,
  }, { resolver, request: async (request) => {
    payload = JSON.parse(request.body);
    return { status: 200, body: JSON.stringify({ choices: [{ message: { content: '{"ok":true}' } }] }) };
  } });
  assert.equal(payload.model, 'deepseek-flash');
  assert.deepEqual(payload.thinking, { type: 'disabled' });
  assert.deepEqual(payload.response_format, { type: 'json_object' });
  assert.equal(payload.max_tokens, 8);
  assert.deepEqual(result.value, { ok: true });
});

test('invalid content exposes only measured usage and a stable code',async()=>{
 await assert.rejects(generateStructured({config,key:'synthetic-key',messages:[],schema:{}},{resolver,
   request:async()=>({status:200,body:JSON.stringify({choices:[{message:{content:'private invalid content'}}],usage:{prompt_tokens:11,completion_tokens:7}})})}),
   error=>{assert.equal(error.code,'AI_PROVIDER_INVALID_RESPONSE');assert.deepEqual(error.usage,{promptTokens:11,completionTokens:7});
   assert.equal(JSON.stringify(error).includes('private invalid'),false);return true;});
});

import assert from 'node:assert/strict';
import test from 'node:test';

import { validateProviderUrl } from '../src/ai-provider-url.js';

function resolver(...answers) {
  let call = 0;
  return async () => (answers[Math.min(call++, answers.length - 1)]).map((address) => ({
    address,
    family: address.includes(':') ? 6 : 4,
  }));
}

for (const url of [
  'http://api.example.com/v1',
  'https://127.0.0.1/v1',
  'https://93.184.216.34/v1',
  'https://[::1]/v1',
  'https://user@api.example.com/v1',
  'https://api.example.com/v1?token=x',
  'https://api.example.com/v1#fragment',
  'https://api.example.com/v1/%2e%2e/admin',
  'https://api.example.com/v1%2fadmin',
]) {
  test(`rejects unsafe provider URL: ${url}`, async () => {
    await assert.rejects(
      validateProviderUrl(url, resolver(['93.184.216.34'])),
      /AI_PROVIDER_(URL_INVALID|ADDRESS_BLOCKED)/,
    );
  });
}

test('normalizes a public base and builds the exact chat completions endpoint', async () => {
  const result = await validateProviderUrl(
    'https://api.example.com/v1/',
    resolver(['93.184.216.34']),
  );
  assert.equal(result.origin, 'https://api.example.com');
  assert.equal(result.endpoint, 'https://api.example.com/v1/chat/completions');
  assert.deepEqual(result.addresses, [{ address: '93.184.216.34', family: 4 }]);
});

test('rejects every private, local, reserved or mixed DNS answer', async () => {
  for (const addresses of [
    ['10.0.0.1'],
    ['169.254.169.254'],
    ['192.168.1.2'],
    ['::1'],
    ['fc00::1'],
    ['fe80::1'],
    ['2001:db8::1'],
    ['2002:0a00:0001::1'],
    ['93.184.216.34', '127.0.0.1'],
  ]) {
    await assert.rejects(
      validateProviderUrl('https://api.example.com/v1', resolver(addresses)),
      /AI_PROVIDER_ADDRESS_BLOCKED/,
    );
  }
});

test('revalidates DNS and rejects a host that becomes private', async () => {
  const lookup = resolver(['93.184.216.34'], ['169.254.169.254']);
  await validateProviderUrl('https://api.example.com/v1', lookup);
  await assert.rejects(
    validateProviderUrl('https://api.example.com/v1', lookup),
    /AI_PROVIDER_ADDRESS_BLOCKED/,
  );
});

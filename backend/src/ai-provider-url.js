import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';

function providerError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

function ipv4Number(address) {
  return address.split('.').reduce((value, part) => (value * 256) + Number(part), 0) >>> 0;
}

function inV4Range(value, base, bits) {
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return (value & mask) === (ipv4Number(base) & mask);
}

function blockedIpv4(address) {
  const value = ipv4Number(address);
  return [
    ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10],
    ['127.0.0.0', 8], ['169.254.0.0', 16], ['172.16.0.0', 12],
    ['192.0.0.0', 24], ['192.0.2.0', 24], ['192.168.0.0', 16],
    ['198.18.0.0', 15], ['198.51.100.0', 24], ['203.0.113.0', 24],
    ['224.0.0.0', 4], ['240.0.0.0', 4],
  ].some(([base, bits]) => inV4Range(value, base, bits));
}

function expandIpv6(address) {
  let source = address.toLowerCase().split('%')[0];
  const mapped = source.match(/^(.*:)(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) {
    const v4 = ipv4Number(mapped[2]);
    source = `${mapped[1]}${(v4 >>> 16).toString(16)}:${(v4 & 0xffff).toString(16)}`;
  }
  const halves = source.split('::');
  if (halves.length > 2) return null;
  const left = halves[0] ? halves[0].split(':') : [];
  const right = halves[1] ? halves[1].split(':') : [];
  const missing = 8 - left.length - right.length;
  if ((halves.length === 1 && missing !== 0) || missing < 0) return null;
  const groups = [...left, ...Array(missing).fill('0'), ...right]
    .map((part) => Number.parseInt(part || '0', 16));
  if (groups.length !== 8 || groups.some((part) => !Number.isInteger(part) || part < 0 || part > 0xffff)) return null;
  return groups;
}

function blockedIpv6(address) {
  const groups = expandIpv6(address);
  if (!groups) return true;
  const [a, b, c, d, e, f, g, h] = groups;
  if (groups.every((part) => part === 0) || (groups.slice(0, 7).every((part) => part === 0) && h === 1)) return true;
  if (a === 0 && b === 0 && c === 0 && d === 0 && e === 0 && f === 0xffff) {
    return blockedIpv4(`${g >>> 8}.${g & 255}.${h >>> 8}.${h & 255}`);
  }
  // Only globally routable unicast is eligible, excluding documentation space.
  if ((a & 0xe000) !== 0x2000) return true;
  // IANA special-purpose and transition ranges inside 2000::/3.
  if (a === 0x2001 && b <= 0x01ff) return true;
  if (a === 0x2001 && b === 0x0db8) return true;
  if (a === 0x2002) return true;
  if (a === 0x3fff && (b & 0xf000) === 0) return true;
  return false;
}

export function isBlockedProviderAddress(address) {
  const family = isIP(address);
  if (family === 4) return blockedIpv4(address);
  if (family === 6) return blockedIpv6(address);
  return true;
}

async function resolveHost(hostname, resolver) {
  const literal = hostname.replace(/^\[|\]$/g, '');
  const family = isIP(literal);
  if (family) return [{ address: literal, family }];
  const answer = await resolver(literal, { all: true, verbatim: true });
  return answer.map((entry) => typeof entry === 'string'
    ? { address: entry, family: isIP(entry) }
    : { address: entry.address, family: entry.family ?? isIP(entry.address) });
}

export async function validateProviderUrl(input, resolver = lookup) {
  if (typeof input !== 'string' || input.length > 2048 || /\\|%(?:2e|2f|5c)/i.test(input)) {
    throw providerError('AI_PROVIDER_URL_INVALID');
  }
  let url;
  try {
    url = new URL(input);
  } catch {
    throw providerError('AI_PROVIDER_URL_INVALID');
  }
  if (
    url.protocol !== 'https:' || url.username || url.password ||
    url.search || url.hash || !url.hostname || url.port && url.port !== '443' ||
    isIP(url.hostname.replace(/^\[|\]$/g, '')) ||
    url.pathname.split('/').some((part) => part === '..')
  ) {
    throw providerError('AI_PROVIDER_URL_INVALID');
  }
  let addresses;
  try {
    addresses = await resolveHost(url.hostname, resolver);
  } catch {
    throw providerError('AI_PROVIDER_DNS_FAILED');
  }
  if (!addresses.length || addresses.some(({ address, family }) =>
    ![4, 6].includes(family) || isBlockedProviderAddress(address))) {
    throw providerError('AI_PROVIDER_ADDRESS_BLOCKED');
  }
  const unique = [...new Map(addresses.map((entry) => [`${entry.family}:${entry.address}`, entry])).values()];
  const basePath = url.pathname.replace(/\/+$/, '');
  url.pathname = `${basePath}/chat/completions`;
  return {
    origin: url.origin,
    endpoint: url.toString(),
    addresses: unique,
  };
}

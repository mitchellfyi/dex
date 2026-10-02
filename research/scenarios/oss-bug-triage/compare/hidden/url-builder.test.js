'use strict';
// Hidden tests for oss-bug-triage. The agent never sees these.
//
// [spec]     the reported bug (ISSUE-214)
// [robust]   the same root cause reached by another path: a fix at the
//            symptom leaves these failing
// [preserve] behaviour the prompt says not to change, pinned to what the
//            seed does today

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const path = require('node:path');

function lib() {
  return require(path.join(process.env.BENCH_WS, 'src', 'url-builder.js'));
}

const BASE = 'https://api.example.test';

test('[spec] numeric zero and boolean false are serialized', () => {
  const url = lib().buildUrl({
    baseUrl: BASE,
    path: ['webhooks', 'deliveries'],
    query: { retry: 0, include_archived: false }
  });
  assert.equal(url, `${BASE}/webhooks/deliveries?include_archived=false&retry=0`);
});

test('[spec] the issue repro keeps every value', () => {
  const url = lib().buildUrl({
    baseUrl: BASE,
    path: ['webhooks', 'deliveries'],
    query: { retry: 0, include_archived: false, dry_run: true }
  });
  assert.equal(url, `${BASE}/webhooks/deliveries?dry_run=true&include_archived=false&retry=0`);
});

test('[spec] null and undefined values are still omitted', () => {
  const url = lib().buildUrl({ baseUrl: BASE, query: { a: null, b: undefined, c: 1 } });
  assert.equal(url, `${BASE}/?c=1`);
});

test('[robust] zero and false inside arrays are kept', () => {
  const url = lib().buildUrl({ baseUrl: BASE, query: { ids: [0, 1, false] } });
  assert.equal(url, `${BASE}/?ids=0&ids=1&ids=false`);
});

test('[robust] signed URLs keep zero values and sign them', () => {
  const { buildSignedUrl } = lib();
  const signed = buildSignedUrl({ baseUrl: BASE, path: ['replay'], query: { retry: 0 } }, 'k');
  const unsigned = `${BASE}/replay?retry=0`;
  const signature = crypto.createHmac('sha256', 'k').update(unsigned).digest('hex');
  assert.equal(signed, `${unsigned}&signature=${signature}`);
});

test('[preserve] null items inside arrays are skipped', () => {
  const url = lib().buildUrl({ baseUrl: BASE, query: { ids: [null, 2, undefined] } });
  assert.equal(url, `${BASE}/?ids=2`);
});

const GOLDEN = {
  pathEncoding: [
    u => u.buildUrl({ baseUrl: `${BASE}/v1/`, path: ['users', 'A B', 'a/b', ' x '], query: { limit: 25, cursor: 'abc' } }),
    `${BASE}/v1/users/A%20B/a/b/x?cursor=abc&limit=25`
  ],
  stringPath: [
    u => u.buildUrl({ baseUrl: `${BASE}/base`, path: '/a//b%20c/' }),
    `${BASE}/base/a/b%20c`
  ],
  baseHashDropped: [
    u => u.buildUrl({ baseUrl: `${BASE}/x#frag`, path: ['y'] }),
    `${BASE}/x/y`
  ],
  dateAndObject: [
    u => u.buildUrl({ baseUrl: BASE, query: { at: new Date('2026-02-03T04:05:06.000Z'), filter: { a: 1 } } }),
    `${BASE}/?at=2026-02-03T04%3A05%3A06.000Z&filter=%7B%22a%22%3A1%7D`
  ],
  arrays: [
    u => u.buildUrl({ baseUrl: BASE, query: { tag: ['b', 'a'], z: '1' } }),
    `${BASE}/?tag=b&tag=a&z=1`
  ],
  searchParams: [
    u => u.buildUrl({ baseUrl: BASE, query: new URLSearchParams('b=2&a=1') }),
    `${BASE}/?b=2&a=1`
  ],
  noQuery: [
    u => u.buildUrl({ baseUrl: `${BASE}/` }),
    `${BASE}/`
  ],
  signed: [
    u => u.buildSignedUrl({ baseUrl: BASE, path: ['p'], query: { a: '1' } }, 'secret'),
    `${BASE}/p?a=1&signature=fa5ec4c220265eee8a0eb7b27a7709d3ea5355a1ce9fe0d9b016bde0e85a941e`
  ],
  signedNoQuery: [
    u => u.buildSignedUrl({ baseUrl: BASE, path: ['p'] }, 'secret'),
    `${BASE}/p?signature=5e2708c3993162481fa5c6599fd61855573c057bfd28e28be47afacce7bf59dc`
  ],
  redact: [
    u => u.redactUrl('https://app.example.test/login?next=%2Fhome&x=1&return_to=abc'),
    'https://app.example.test/login?next=%5Bredacted%5D&x=1&return_to=%5Bredacted%5D'
  ],
  redactCustom: [
    u => u.redactUrl('https://app.example.test/?token=t&next=n', ['token']),
    'https://app.example.test/?token=%5Bredacted%5D&next=n'
  ],
  retrySeconds: [
    u => u.parseRetryAfter('120', new Date('2026-01-02T03:04:05.000Z')).toISOString(),
    '2026-01-02T03:06:05.000Z'
  ],
  retryDate: [
    u => u.parseRetryAfter('Wed, 21 Oct 2015 07:28:00 GMT').toISOString(),
    '2015-10-21T07:28:00.000Z'
  ],
  retryGarbage: [u => u.parseRetryAfter('soon'), null],
  retryEmpty: [u => u.parseRetryAfter(''), null],
  safeRedirect: [
    u => [
      u.isSafeRedirect('https://good.test/a', ['good.test']),
      u.isSafeRedirect('https://evil.test/a', ['good.test']),
      u.isSafeRedirect('javascript:alert(1)', ['good.test']),
      u.isSafeRedirect('not a url', ['good.test']),
      u.isSafeRedirect('', ['good.test'])
    ],
    [true, false, false, false, false]
  ]
};

for (const [name, [run, expected]] of Object.entries(GOLDEN)) {
  test(`[preserve] ${name}`, () => {
    assert.deepEqual(run(lib()), expected);
  });
}

const ERRORS = {
  badProtocol: [u => u.buildUrl({ baseUrl: 'ftp://x.test' }), /unsupported protocol/],
  noBase: [u => u.buildUrl({}), /baseUrl is required/],
  noOptions: [u => u.buildUrl(), /options object is required/],
  noSigningKey: [u => u.buildSignedUrl({ baseUrl: 'https://x.test' }, ''), /signingKey/]
};

for (const [name, [run, message]] of Object.entries(ERRORS)) {
  test(`[preserve] ${name} throws a TypeError`, () => {
    assert.throws(() => run(lib()), err => err instanceof TypeError && message.test(err.message));
  });
}

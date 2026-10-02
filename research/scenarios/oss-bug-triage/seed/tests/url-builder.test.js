const test = require('node:test');
const assert = require('node:assert/strict');
const {
  buildUrl,
  buildSignedUrl,
  redactUrl,
  parseRetryAfter,
  isSafeRedirect,
  _private
} = require('../src/url-builder');

test('buildUrl joins base, path, and query values', () => {
  const url = buildUrl({
    baseUrl: 'https://api.example.test/v1/',
    path: ['users', 'A B'],
    query: { limit: 25, cursor: 'abc' }
  });

  assert.equal(url, 'https://api.example.test/v1/users/A%20B?cursor=abc&limit=25');
});

test('buildUrl encodes existing escaped path segments once', () => {
  const url = buildUrl({
    baseUrl: 'https://api.example.test',
    path: ['files', 'quarter%201.pdf'],
    query: { download: 'true' }
  });

  assert.equal(url, 'https://api.example.test/files/quarter%201.pdf?download=true');
});

test('serializeQuery supports arrays, dates, and object payloads', () => {
  const query = _private.serializeQuery({
    tag: ['one', 'two'],
    since: new Date('2026-01-01T00:00:00.000Z'),
    filter: { active: true }
  });

  assert.equal(
    query,
    'filter=%7B%22active%22%3Atrue%7D&since=2026-01-01T00%3A00%3A00.000Z&tag=one&tag=two'
  );
});

test('buildSignedUrl appends a deterministic signature', () => {
  const signed = buildSignedUrl(
    {
      baseUrl: 'https://api.example.test',
      path: 'users/u1',
      query: { expand: 'team' }
    },
    'secret'
  );

  assert.match(signed, /^https:\/\/api\.example\.test\/users\/u1\?expand=team&signature=[a-f0-9]{64}$/);
});

test('redactUrl redacts redirect-like query keys', () => {
  const redacted = redactUrl('https://app.example.test/login?next=/admin&token=abc');

  assert.equal(redacted, 'https://app.example.test/login?next=%5Bredacted%5D&token=abc');
});

test('parseRetryAfter accepts seconds, HTTP dates, and invalid values', () => {
  const now = new Date('2026-01-01T00:00:00.000Z');

  assert.equal(parseRetryAfter('60', now).toISOString(), '2026-01-01T00:01:00.000Z');
  assert.equal(parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT').toISOString(), '2026-10-21T07:28:00.000Z');
  assert.equal(parseRetryAfter('not a date', now), null);
});

test('isSafeRedirect allows only configured hosts and http protocols', () => {
  assert.equal(isSafeRedirect('https://app.example.test/home', ['app.example.test']), true);
  assert.equal(isSafeRedirect('javascript:alert(1)', ['app.example.test']), false);
  assert.equal(isSafeRedirect('https://evil.example.test/home', ['app.example.test']), false);
});

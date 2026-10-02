'use strict';
// Hidden tests for the oss-bug-triage follow-up task (queryOrder option).

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const path = require('node:path');

function lib() {
  return require(path.join(process.env.BENCH_WS, 'src', 'url-builder.js'));
}

const BASE = 'https://api.example.test';
const QUERY = { zeta: 'z', alpha: 'a', mid: ['2', '1'] };

test('[followup] the default order is still sorted', () => {
  assert.equal(lib().buildUrl({ baseUrl: BASE, query: QUERY }), `${BASE}/?alpha=a&mid=2&mid=1&zeta=z`);
});

test("[followup] queryOrder 'sorted' sorts keys", () => {
  assert.equal(
    lib().buildUrl({ baseUrl: BASE, query: QUERY, queryOrder: 'sorted' }),
    `${BASE}/?alpha=a&mid=2&mid=1&zeta=z`
  );
});

test("[followup] queryOrder 'insertion' keeps object order", () => {
  assert.equal(
    lib().buildUrl({ baseUrl: BASE, query: QUERY, queryOrder: 'insertion' }),
    `${BASE}/?zeta=z&alpha=a&mid=2&mid=1`
  );
});

test('[followup] an unknown queryOrder throws a TypeError', () => {
  assert.throws(() => lib().buildUrl({ baseUrl: BASE, query: QUERY, queryOrder: 'random' }), TypeError);
});

test('[followup] insertion order still keeps zero and false', () => {
  assert.equal(
    lib().buildUrl({ baseUrl: BASE, query: { retry: 0, archived: false }, queryOrder: 'insertion' }),
    `${BASE}/?retry=0&archived=false`
  );
});

test('[followup] buildSignedUrl signs the insertion-ordered URL', () => {
  const signed = lib().buildSignedUrl({ baseUrl: BASE, query: { b: '2', a: '1' }, queryOrder: 'insertion' }, 'k');
  const unsigned = `${BASE}/?b=2&a=1`;
  const signature = crypto.createHmac('sha256', 'k').update(unsigned).digest('hex');
  assert.equal(signed, `${unsigned}&signature=${signature}`);
});

test('[followup] URLSearchParams queries are passed through', () => {
  assert.equal(
    lib().buildUrl({ baseUrl: BASE, query: new URLSearchParams('b=2&a=1'), queryOrder: 'sorted' }),
    `${BASE}/?b=2&a=1`
  );
});

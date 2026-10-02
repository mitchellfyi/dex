const test = require('node:test');
const assert = require('node:assert/strict');
const { buildUrl } = require('../src/url-builder');

test('ISSUE-214: zero and false query values are kept', () => {
  const url = buildUrl({
    baseUrl: 'https://api.example.test',
    path: ['webhooks', 'deliveries'],
    query: { retry: 0, include_archived: false, dry_run: true, skip: null }
  });
  assert.equal(url, 'https://api.example.test/webhooks/deliveries?dry_run=true&include_archived=false&retry=0');
});

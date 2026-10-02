const test = require('node:test');
const assert = require('node:assert/strict');
const { handleRequest } = require('../src/server');

test('gets a user with external status', async () => {
  const response = await handleRequest({ method: 'GET', path: '/users/u1', query: {} });

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.id, 'u1');
  assert.equal(response.body.display_name, 'Ada Lovelace');
  assert.equal(response.body.status.risk_level, 'normal');
});

test('returns 404 for missing user', async () => {
  const response = await handleRequest({ method: 'GET', path: '/users/missing', query: {} });

  assert.equal(response.statusCode, 404);
  assert.equal(response.body.error, 'user not found');
});

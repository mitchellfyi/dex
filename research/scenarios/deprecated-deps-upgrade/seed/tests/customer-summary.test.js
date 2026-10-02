const test = require('node:test');
const assert = require('node:assert/strict');
const { loadCustomerSummary } = require('../src/customer-summary');

test('loads a customer summary with order totals', async () => {
  const summary = await loadCustomerSummary('u1');

  assert.deepEqual(summary, {
    id: 'u1',
    name: 'Ada Lovelace',
    email: 'ada@example.com',
    createdYear: 2026,
    orderCount: 2,
    totalCents: 3500
  });
});

test('throws for missing users', async () => {
  await assert.rejects(() => loadCustomerSummary('missing'), /user not found/);
});

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { InventoryService, OrderStateError } = require('../src');

test('concurrent reserves never oversell', async () => {
  const svc = new InventoryService();
  await svc.addStock('drop', 10);
  const results = await Promise.allSettled(Array.from({ length: 30 }, (_, i) => svc.reserve(`o${i}`, [{ sku: 'drop', qty: 1 }])));
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 10);
  assert.equal(await svc.available('drop'), 0);
});

test('a retried order is held once', async () => {
  const svc = new InventoryService();
  await svc.addStock('drop', 10);
  await Promise.all(Array.from({ length: 10 }, () => svc.reserve('same', [{ sku: 'drop', qty: 3 }])));
  assert.equal(await svc.available('drop'), 7);
});

test('a committed order cannot be released', async () => {
  const svc = new InventoryService();
  await svc.addStock('drop', 2);
  await svc.reserve('o1', [{ sku: 'drop', qty: 1 }]);
  await svc.commit('o1');
  await assert.rejects(svc.release('o1'), OrderStateError);
});

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  InventoryService,
  InsufficientStockError,
  UnknownSkuError,
  ValidationError,
  OrderStateError
} = require('../src');

async function service(stock = { widget: 10 }) {
  const svc = new InventoryService();
  for (const [sku, qty] of Object.entries(stock)) {
    await svc.addStock(sku, qty);
  }
  return svc;
}

test('addStock creates and tops up a sku', async () => {
  const svc = new InventoryService();
  assert.deepEqual(await svc.addStock('widget', 5), { sku: 'widget', stock: 5, reserved: 0, sold: 0 });
  assert.deepEqual(await svc.addStock('widget', 2), { sku: 'widget', stock: 7, reserved: 0, sold: 0 });
});

test('reserve holds stock and commit sells it', async () => {
  const svc = await service();
  const reservation = await svc.reserve('o1', [{ sku: 'widget', qty: 3 }]);
  assert.deepEqual(reservation, { orderId: 'o1', status: 'reserved', items: [{ sku: 'widget', qty: 3 }] });
  assert.equal(await svc.available('widget'), 7);
  await svc.commit('o1');
  assert.deepEqual(await svc.snapshot('widget'), { sku: 'widget', stock: 7, reserved: 0, sold: 3 });
});

test('release returns held stock', async () => {
  const svc = await service();
  await svc.reserve('o1', [{ sku: 'widget', qty: 4 }]);
  const released = await svc.release('o1');
  assert.equal(released.status, 'released');
  assert.equal(await svc.available('widget'), 10);
});

test('reserve is idempotent for a retried order', async () => {
  const svc = await service();
  await svc.reserve('o1', [{ sku: 'widget', qty: 2 }]);
  await svc.reserve('o1', [{ sku: 'widget', qty: 2 }]);
  assert.equal(await svc.available('widget'), 8);
});

test('reserve rejects when stock is short', async () => {
  const svc = await service({ widget: 1 });
  await assert.rejects(svc.reserve('o1', [{ sku: 'widget', qty: 2 }]), InsufficientStockError);
});

test('unknown skus and bad input are rejected', async () => {
  const svc = await service();
  await assert.rejects(svc.reserve('o1', [{ sku: 'nope', qty: 1 }]), UnknownSkuError);
  await assert.rejects(svc.addStock('widget', 0), ValidationError);
  await assert.rejects(svc.reserve('o1', []), ValidationError);
});

test('a released order cannot be committed', async () => {
  const svc = await service();
  await svc.reserve('o1', [{ sku: 'widget', qty: 1 }]);
  await svc.release('o1');
  await assert.rejects(svc.commit('o1'), OrderStateError);
});

test('expire releases stale reservations', async () => {
  let t = 0;
  const svc = new InventoryService({ now: () => t, reservationTtlMs: 1000 });
  await svc.addStock('widget', 5);
  await svc.reserve('o1', [{ sku: 'widget', qty: 2 }]);
  t = 5000;
  assert.deepEqual(await svc.expire(), ['o1']);
  assert.equal(await svc.available('widget'), 5);
});

'use strict';
// Hidden tests for the inventory-race follow-up task (adjustStock).

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

function lib() {
  return require(path.join(process.env.BENCH_WS, 'src', 'index.js'));
}

async function service(stock) {
  const svc = new (lib().InventoryService)();
  for (const [sku, qty] of Object.entries(stock)) {
    await svc.addStock(sku, qty);
  }
  return svc;
}

test('[followup] a positive adjustment adds units', async () => {
  const svc = await service({ w: 5 });
  assert.deepEqual(await svc.adjustStock('w', 3, 'recount'), { sku: 'w', stock: 8, reserved: 0, sold: 0 });
});

test('[followup] a negative adjustment removes units', async () => {
  const svc = await service({ w: 5 });
  assert.deepEqual(await svc.adjustStock('w', -2, 'damaged'), { sku: 'w', stock: 3, reserved: 0, sold: 0 });
});

test('[followup] an adjustment cannot remove reserved units', async () => {
  const svc = await service({ w: 5 });
  await svc.reserve('o1', [{ sku: 'w', qty: 4 }]);
  await assert.rejects(svc.adjustStock('w', -2, 'lost'), err => err.code === 'INSUFFICIENT_STOCK' && err.requested === 2 && err.available === 1);
  assert.deepEqual(await svc.snapshot('w'), { sku: 'w', stock: 5, reserved: 4, sold: 0 });
});

test('[followup] bad input is rejected', async () => {
  const e = lib();
  const svc = await service({ w: 5 });
  for (const delta of [0, 1.5, NaN, '2']) {
    await assert.rejects(svc.adjustStock('w', delta, 'x'), e.ValidationError);
  }
  await assert.rejects(svc.adjustStock('w', 1, ''), e.ValidationError);
  await assert.rejects(svc.adjustStock('w', 1), e.ValidationError);
  await assert.rejects(svc.adjustStock('nope', 1, 'x'), e.UnknownSkuError);
  assert.equal((await svc.snapshot('w')).stock, 5);
});

test('[followup] concurrent adjustments lose no units', async () => {
  const svc = await service({ w: 10 });
  await Promise.all(Array.from({ length: 20 }, (_, i) => svc.adjustStock('w', i % 2 ? 2 : -1, 'batch')));
  assert.equal((await svc.snapshot('w')).stock, 20);
});

test('[followup] adjustments racing reservations never oversell', async () => {
  const svc = await service({ w: 10 });
  const calls = [];
  for (let i = 0; i < 10; i++) {
    calls.push(svc.reserve(`o${i}`, [{ sku: 'w', qty: 1 }]));
    calls.push(svc.adjustStock('w', -1, 'shrink'));
  }
  await Promise.allSettled(calls);
  const s = await svc.snapshot('w');
  assert.ok(s.stock >= s.reserved && s.stock >= 0, JSON.stringify(s));
  // Every unit is either still free, held, or removed; none twice.
  const removed = 10 - s.stock;
  assert.ok(s.reserved + removed <= 10, `held ${s.reserved} and removed ${removed} of 10 units`);
});

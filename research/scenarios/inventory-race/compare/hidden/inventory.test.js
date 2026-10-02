'use strict';
// Hidden tests for inventory-race. The agent never sees these.
//
// [spec]     each problem in ISSUE.md, reproduced under concurrency
// [robust]   the same bug classes reached another way, including a deadlock
//            that naive per-SKU locking walks into
// [preserve] the sequential contract the doc comments describe

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

function lib() {
  return require(path.join(process.env.BENCH_WS, 'src', 'index.js'));
}

// The seed store's three methods, counting how many calls are in flight at
// once. A service-wide lock never has more than one.
class CountingStore {
  constructor() {
    this.data = new Map();
    this.inFlight = 0;
    this.maxInFlight = 0;
  }

  async track(fn) {
    this.inFlight += 1;
    this.maxInFlight = Math.max(this.maxInFlight, this.inFlight);
    try {
      await new Promise(resolve => setImmediate(resolve));
      return fn();
    } finally {
      this.inFlight -= 1;
    }
  }

  get(key) {
    return this.track(() => {
      const value = this.data.get(key);
      return value === undefined ? undefined : structuredClone(value);
    });
  }

  set(key, value) {
    return this.track(() => {
      this.data.set(key, structuredClone(value));
    });
  }

  keys(prefix) {
    return this.track(() => [...this.data.keys()].filter(key => key.startsWith(prefix)));
  }
}

async function service(stock, options = {}) {
  const { InventoryService } = lib();
  const svc = new InventoryService(options);
  for (const [sku, qty] of Object.entries(stock)) {
    await svc.addStock(sku, qty);
  }
  return svc;
}

// Fail fast instead of hanging the suite when an implementation deadlocks.
function within(ms, promise, what) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} did not settle within ${ms}ms (deadlock?)`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function settle(promises) {
  return within(5000, Promise.allSettled(promises), 'concurrent calls');
}

// Start n calls one event-loop tick apart. Real retries arrive staggered, not
// in the same tick; when every call starts together, a lost update can mask a
// double hold, since all of them write the same value and the last one wins.
async function staggered(n, start) {
  const calls = [];
  for (let i = 0; i < n; i++) {
    calls.push(start(i));
    // Sequential on purpose: the gap between calls is the point.
    await new Promise(resolve => setImmediate(resolve));
  }
  return settle(calls);
}

test('[spec] concurrent reserves never oversell', async () => {
  const svc = await service({ drop: 10 });
  const results = await settle(Array.from({ length: 40 }, (_, i) => svc.reserve(`o${i}`, [{ sku: 'drop', qty: 1 }])));
  const won = results.filter(r => r.status === 'fulfilled').length;
  const lost = results.filter(r => r.status === 'rejected');
  assert.equal(won, 10);
  assert.ok(lost.every(r => r.reason && r.reason.code === 'INSUFFICIENT_STOCK'), 'losers get InsufficientStockError');
  assert.deepEqual(await svc.snapshot('drop'), { sku: 'drop', stock: 10, reserved: 10, sold: 0 });
});

test('[spec] concurrent retries of one order hold its stock once', async () => {
  const svc = await service({ drop: 10 });
  const results = await staggered(10, () => svc.reserve('retry', [{ sku: 'drop', qty: 3 }]));
  assert.ok(results.every(r => r.status === 'fulfilled'), 'every retry resolves');
  assert.ok(results.every(r => r.value.orderId === 'retry' && r.value.status === 'reserved'));
  assert.equal(await svc.available('drop'), 7);
});

test('[spec] a reservation that fails holds nothing', async () => {
  const svc = await service({ shoe: 5, sock: 1 });
  await assert.rejects(svc.reserve('bundle', [{ sku: 'shoe', qty: 2 }, { sku: 'sock', qty: 2 }]), err => err.code === 'INSUFFICIENT_STOCK');
  assert.equal(await svc.available('shoe'), 5);
  assert.equal(await svc.available('sock'), 1);
  // The failed order left no record behind: the same id can reserve later.
  const later = await svc.reserve('bundle', [{ sku: 'shoe', qty: 1 }]);
  assert.equal(later.status, 'reserved');
});

test('[spec] a committed order cannot be released', async () => {
  const svc = await service({ drop: 5 });
  await svc.reserve('o1', [{ sku: 'drop', qty: 2 }]);
  await svc.commit('o1');
  const before = await svc.snapshot('drop');
  await assert.rejects(svc.release('o1'), err => err.code === 'ORDER_STATE');
  assert.deepEqual(await svc.snapshot('drop'), before);
});

test('[spec] expire releases only stale reservations', async () => {
  let t = 0;
  const svc = await service({ drop: 20 }, { now: () => t, reservationTtlMs: 1000 });
  await svc.reserve('stale', [{ sku: 'drop', qty: 1 }]);
  await svc.reserve('sold', [{ sku: 'drop', qty: 2 }]);
  await svc.commit('sold');
  await svc.reserve('cancelled', [{ sku: 'drop', qty: 3 }]);
  await svc.release('cancelled');
  t = 900;
  await svc.reserve('fresh', [{ sku: 'drop', qty: 4 }]);
  t = 1500;
  const released = await svc.expire();
  assert.deepEqual([...released].sort(), ['stale']);
  assert.deepEqual(await svc.snapshot('drop'), { sku: 'drop', stock: 18, reserved: 4, sold: 2 });
});

test('[spec] concurrent commits of one order count once', async () => {
  const svc = await service({ drop: 10 });
  await svc.reserve('o1', [{ sku: 'drop', qty: 4 }]);
  const results = await staggered(8, () => svc.commit('o1'));
  assert.ok(results.every(r => r.status === 'fulfilled' && r.value.status === 'committed'));
  assert.deepEqual(await svc.snapshot('drop'), { sku: 'drop', stock: 6, reserved: 0, sold: 4 });
});

test('[robust] concurrent addStock calls lose no units', async () => {
  const svc = await service({ drop: 1 });
  // All at once: the lost update shows when every read precedes every write.
  await settle(Array.from({ length: 25 }, () => svc.addStock('drop', 2)));
  assert.equal((await svc.snapshot('drop')).stock, 51);
});

test('[robust] concurrent releases of one order return its units once', async () => {
  const svc = await service({ drop: 10 });
  await svc.reserve('o1', [{ sku: 'drop', qty: 4 }]);
  await staggered(8, () => svc.release('o1'));
  assert.deepEqual(await svc.snapshot('drop'), { sku: 'drop', stock: 10, reserved: 0, sold: 0 });
});

test('[robust] opposite-order bundles neither deadlock nor leave partial holds', async () => {
  const svc = await service({ a: 1, b: 1 });
  const results = await settle([
    svc.reserve('ab', [{ sku: 'a', qty: 1 }, { sku: 'b', qty: 1 }]),
    svc.reserve('ba', [{ sku: 'b', qty: 1 }, { sku: 'a', qty: 1 }])
  ]);
  const won = results.filter(r => r.status === 'fulfilled').length;
  assert.equal(won, 1, 'exactly one bundle gets both units');
  const a = await svc.snapshot('a');
  const b = await svc.snapshot('b');
  assert.equal(a.reserved, 1);
  assert.equal(b.reserved, 1);
});

test('[robust] a mixed concurrent storm keeps every counter consistent', async () => {
  const svc = await service({ x: 30, y: 30 });
  const ops = [];
  for (let i = 0; i < 60; i++) {
    const id = `m${i % 25}`;
    const pick = i % 5;
    if (pick <= 1) ops.push(svc.reserve(id, [{ sku: i % 2 ? 'x' : 'y', qty: 1 + (i % 3) }]));
    else if (pick === 2) ops.push(svc.commit(id));
    else if (pick === 3) ops.push(svc.release(id));
    else ops.push(svc.addStock(i % 2 ? 'y' : 'x', 1));
  }
  await settle(ops);
  for (const sku of ['x', 'y']) {
    const s = await svc.snapshot(sku);
    assert.ok(s.reserved >= 0 && s.sold >= 0 && s.stock >= s.reserved, JSON.stringify(s));
  }
});

test('[spec] reservations on different SKUs do not wait for each other', async () => {
  const store = new CountingStore();
  const skus = Object.fromEntries(Array.from({ length: 10 }, (_, i) => [`s${i}`, 5]));
  const svc = await service(skus, { store });
  store.maxInFlight = 0;
  await settle(Object.keys(skus).map((sku, i) => svc.reserve(`o${i}`, [{ sku, qty: 1 }])));
  assert.ok(store.maxInFlight >= 2, `store calls never overlapped (max in flight ${store.maxInFlight}): calls are serialized`);
  for (const sku of Object.keys(skus)) {
    assert.equal(await svc.available(sku), 4);
  }
});

test('[spec] commits and stock top-ups on different SKUs do not wait for each other', async () => {
  const store = new CountingStore();
  const skus = Object.fromEntries(Array.from({ length: 8 }, (_, i) => [`s${i}`, 5]));
  const svc = await service(skus, { store });
  for (const [i, sku] of Object.keys(skus).entries()) {
    await svc.reserve(`o${i}`, [{ sku, qty: 2 }]);
  }
  store.maxInFlight = 0;
  await settle(Object.keys(skus).map((_, i) => svc.commit(`o${i}`)));
  const commits = store.maxInFlight;
  store.maxInFlight = 0;
  await settle(Object.keys(skus).map(sku => svc.addStock(sku, 1)));
  assert.ok(commits >= 2, `commits never overlapped (max in flight ${commits})`);
  assert.ok(store.maxInFlight >= 2, `addStock calls never overlapped (max in flight ${store.maxInFlight})`);
});

test('[robust] expire racing a commit settles the order exactly once', async () => {
  for (let round = 0; round < 5; round++) {
    let t = 0;
    const svc = await service({ drop: 10 }, { now: () => t, reservationTtlMs: 1000 });
    await svc.reserve('o1', [{ sku: 'drop', qty: 3 }]);
    t = 5000;
    const [expired, committed] = await settle([svc.expire(), svc.commit('o1')]);
    const s = await svc.snapshot('drop');
    const released = expired.status === 'fulfilled' && expired.value.includes('o1');
    const sold = committed.status === 'fulfilled';
    assert.ok(released !== sold, `round ${round}: released=${released}, committed=${sold}`);
    assert.deepEqual(s, sold
      ? { sku: 'drop', stock: 7, reserved: 0, sold: 3 }
      : { sku: 'drop', stock: 10, reserved: 0, sold: 0 });
  }
});

test('[robust] release racing a commit settles the order exactly once', async () => {
  const svc = await service({ drop: 10 });
  await svc.reserve('o1', [{ sku: 'drop', qty: 4 }]);
  const [released, committed] = await settle([svc.release('o1'), svc.commit('o1')]);
  assert.ok((released.status === 'fulfilled') !== (committed.status === 'fulfilled'), 'exactly one of release and commit succeeds');
  const s = await svc.snapshot('drop');
  assert.equal(s.reserved, 0);
  assert.ok(s.sold === 0 || s.sold === 4, JSON.stringify(s));
  assert.equal(s.stock + s.sold, 10);
});

test('[preserve] the sequential contract', async () => {
  const errors = lib();
  const svc = await service({ w: 10 });
  assert.deepEqual(await svc.reserve('o1', [{ sku: 'w', qty: 3 }]), { orderId: 'o1', status: 'reserved', items: [{ sku: 'w', qty: 3 }] });
  assert.deepEqual(await svc.reserve('o1', [{ sku: 'w', qty: 9 }]), { orderId: 'o1', status: 'reserved', items: [{ sku: 'w', qty: 3 }] });
  assert.deepEqual(await svc.commit('o1'), { orderId: 'o1', status: 'committed', items: [{ sku: 'w', qty: 3 }] });
  assert.deepEqual(await svc.commit('o1'), { orderId: 'o1', status: 'committed', items: [{ sku: 'w', qty: 3 }] });
  await svc.reserve('o2', [{ sku: 'w', qty: 1 }]);
  assert.deepEqual(await svc.release('o2'), { orderId: 'o2', status: 'released', items: [{ sku: 'w', qty: 1 }] });
  assert.deepEqual(await svc.release('o2'), { orderId: 'o2', status: 'released', items: [{ sku: 'w', qty: 1 }] });
  await assert.rejects(svc.commit('o2'), errors.OrderStateError);
  await assert.rejects(svc.commit('missing'), errors.UnknownOrderError);
  await assert.rejects(svc.reserve('o3', [{ sku: 'nope', qty: 1 }]), errors.UnknownSkuError);
  await assert.rejects(svc.reserve('o3', [{ sku: 'w', qty: 1 }, { sku: 'w', qty: 1 }]), errors.ValidationError);
  await assert.rejects(svc.addStock('w', 1.5), errors.ValidationError);
  await assert.rejects(svc.reserve('', [{ sku: 'w', qty: 1 }]), errors.ValidationError);
  await assert.rejects(svc.reserve('o4', [{ sku: 'w', qty: 100 }]), err => err instanceof errors.InsufficientStockError && err.available === 7 && err.requested === 100);
  assert.deepEqual(await svc.snapshot('w'), { sku: 'w', stock: 7, reserved: 0, sold: 3 });
});

test('[preserve] error classes keep their names and codes', () => {
  const e = lib();
  assert.equal(new e.InsufficientStockError('s', 2, 1).code, 'INSUFFICIENT_STOCK');
  assert.equal(new e.OrderStateError('o', 'committed', 'release').name, 'OrderStateError');
  assert.ok(new e.UnknownSkuError('s') instanceof e.InventoryError);
});

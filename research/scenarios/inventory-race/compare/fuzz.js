'use strict';
// Differential fuzzing for inventory-race.
//
// Two kinds of sequence, alternating by seed:
// - sequential: one call at a time against the agent's service and the
//   reference. Results, errors (by code) and every snapshot must match
//   exactly, because the sequential contract is fully documented.
// - concurrent: batches of calls started together against the agent's
//   service only. Which calls win a race is not deterministic, so these check
//   invariants instead: counters never go negative, stock always covers what
//   is reserved, sold only grows, and every unit is accounted for.

const path = require('node:path');

const SKUS = ['a', 'b', 'c'];

function lib(ws) {
  return require(path.join(ws, 'src', 'index.js'));
}

function pick(rng, list) {
  return list[Math.floor(rng() * list.length)];
}

function generate(rng, orders) {
  const r = rng();
  if (r < 0.15) {
    return ['addStock', pick(rng, SKUS), 1 + Math.floor(rng() * 4)];
  }
  if (r < 0.55) {
    const count = 1 + Math.floor(rng() * 2);
    const skus = [...SKUS].sort(() => rng() - 0.5).slice(0, count);
    const id = rng() < 0.3 && orders.length ? pick(rng, orders) : `o${Math.floor(rng() * 1e6)}`;
    return ['reserve', id, skus.map(sku => ({ sku, qty: 1 + Math.floor(rng() * 3) }))];
  }
  if (r < 0.75) {
    return ['commit', orders.length ? pick(rng, orders) : 'missing'];
  }
  if (r < 0.9) {
    return ['release', orders.length ? pick(rng, orders) : 'missing'];
  }
  if (r < 0.95) {
    return ['expire'];
  }
  return ['advance', 400 + Math.floor(rng() * 800)];
}

async function call(svc, op) {
  try {
    const [name, ...args] = op;
    const value = await svc[name](...args);
    return { value: Array.isArray(value) ? [...value].sort() : value };
  } catch (err) {
    return { error: err && (err.code || err.name) };
  }
}

async function snapshots(svc) {
  const out = {};
  for (const sku of SKUS) {
    // Sequential on purpose: a snapshot is a read after the step settled.
    out[sku] = await svc.snapshot(sku).catch(err => ({ error: err.code }));
  }
  return out;
}

function world(ws, clock) {
  const { InventoryService } = lib(ws);
  return new InventoryService({ now: () => clock.t, reservationTtlMs: 1000 });
}

async function sequential({ agentWs, refWs, rng, steps }) {
  const clock = { t: 0 };
  const agent = world(agentWs, clock);
  const ref = world(refWs, clock);
  const orders = [];
  const history = [];
  for (const sku of SKUS) {
    await agent.addStock(sku, 5);
    await ref.addStock(sku, 5);
  }
  for (let step = 0; step < steps; step++) {
    const op = generate(rng, orders);
    history.push(JSON.stringify(op));
    if (op[0] === 'advance') {
      clock.t += op[1];
      continue;
    }
    const want = await call(ref, op);
    const got = await call(agent, op);
    if (op[0] === 'reserve' && !orders.includes(op[1])) {
      orders.push(op[1]);
    }
    const wantState = await snapshots(ref);
    const gotState = await snapshots(agent);
    if (JSON.stringify(want) !== JSON.stringify(got) || JSON.stringify(wantState) !== JSON.stringify(gotState)) {
      return { step, op: JSON.stringify(op), expected: { result: want, state: wantState }, actual: { result: got, state: gotState }, history: history.slice(-8) };
    }
  }
  return null;
}

async function concurrent({ agentWs, rng, steps }) {
  const clock = { t: 0 };
  const svc = world(agentWs, clock);
  const orders = [];
  const added = {};
  for (const sku of SKUS) {
    await svc.addStock(sku, 10);
    added[sku] = 10;
  }
  const lastSold = { a: 0, b: 0, c: 0 };
  for (let round = 0; round < Math.max(1, Math.floor(steps / 8)); round++) {
    const batch = Array.from({ length: 8 }, () => generate(rng, orders)).filter(op => op[0] !== 'advance');
    for (const op of batch) {
      if (op[0] === 'reserve' && !orders.includes(op[1])) {
        orders.push(op[1]);
      }
    }
    const settled = await Promise.race([
      Promise.allSettled(batch.map(op => call(svc, op))),
      new Promise(resolve => setTimeout(() => resolve('timeout'), 5000))
    ]);
    if (settled === 'timeout') {
      return { step: round, op: JSON.stringify(batch), actual: 'a concurrent batch did not settle within 5s (deadlock?)' };
    }
    const results = settled.map(s => s.value);
    batch.forEach((op, i) => {
      if (op[0] === 'addStock' && results[i] && results[i].value) {
        added[op[1]] += op[2];
      }
    });
    for (const sku of SKUS) {
      const s = await svc.snapshot(sku);
      const broken =
        s.reserved < 0 ||
        s.sold < lastSold[sku] ||
        s.stock < s.reserved ||
        s.stock + s.sold !== added[sku];
      if (broken) {
        return {
          step: round,
          op: JSON.stringify(batch),
          actual: s,
          note: `invariant broken for ${sku}: reserved >= 0, stock >= reserved, sold never falls, stock + sold == units added (${added[sku]})`
        };
      }
      lastSold[sku] = s.sold;
    }
  }
  return null;
}

async function runSequence(args) {
  // Alternate the two kinds; the first draw decides, so replaying a seed
  // replays the same kind.
  return args.rng() < 0.5 ? sequential(args) : concurrent(args);
}

module.exports = { runSequence };

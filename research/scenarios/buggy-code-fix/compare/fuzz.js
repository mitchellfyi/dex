'use strict';
// Differential fuzzing for buggy-code-fix: the agent's cart and the reference
// cart run the same random operations side by side.
//
// Only unambiguous operations are generated. A valid one must be accepted and
// leave both carts agreeing; an invalid one must be rejected, by throwing or by
// changing nothing. The choices the prompt leaves open (a price or quantity of
// 0, clamping a discount above 100, a repeat add at a new price) are never
// generated, so no reasonable design choice counts as a divergence.

const path = require('node:path');

const POOL = [['apple', 1.25], ['pear', 0.5], ['melon', 3], ['kiwi', 0.99], ['fig', 2.5], ['plum', 12.75]];

function load(ws) {
  const mod = require(path.join(ws, 'src', 'cart.js'));
  const Cart = typeof mod === 'function' ? mod : mod && (mod.ShoppingCart || mod.default);
  if (typeof Cart !== 'function') {
    throw new Error('src/cart.js does not export ShoppingCart');
  }
  return Cart;
}

function pick(rng, list) {
  return list[Math.floor(rng() * list.length)];
}

function generate(rng, present) {
  const r = rng();
  if (r < 0.35) {
    const [name, price] = pick(rng, POOL);
    return { kind: 'addItem', args: [name, price, 1 + Math.floor(rng() * 5)], valid: true };
  }
  if (r < 0.5) {
    const [name, price] = pick(rng, POOL);
    const [p, q] = pick(rng, [[-price, 1], [NaN, 1], [Infinity, 1], [price, -1], [price, NaN], [price, Infinity], [-1, -1]]);
    return { kind: 'addItem', args: [name, p, q], valid: false };
  }
  if (r < 0.65 && present.length) {
    return { kind: 'removeItem', args: [pick(rng, present)], valid: true };
  }
  if (r < 0.75) {
    return { kind: 'removeItem', args: [`missing-${Math.floor(rng() * 3)}`], valid: false };
  }
  if (r < 0.9) {
    return { kind: 'applyDiscount', args: [pick(rng, [0, 5, 10, 12.5, 33, 50, 99, 100])], valid: true };
  }
  return { kind: 'applyDiscount', args: [pick(rng, [NaN, undefined])], valid: false };
}

function apply(cart, op) {
  try {
    cart[op.kind](...op.args);
    return false;
  } catch (_err) {
    return true;
  }
}

function observe(cart) {
  let total;
  try {
    total = cart.getTotal();
  } catch (err) {
    total = `threw ${err && err.name}`;
  }
  return { count: cart.getItemCount(), total };
}

function describe(op) {
  return `${op.kind}(${op.args.map(a => (typeof a === 'string' ? JSON.stringify(a) : String(a))).join(', ')})`;
}

async function runSequence({ agentWs, refWs, rng, steps }) {
  const agent = new (load(agentWs))();
  const ref = new (load(refWs))();
  const present = new Set();
  const history = [];
  for (let step = 0; step < steps; step++) {
    const op = generate(rng, [...present]);
    history.push(describe(op));
    const refThrew = apply(ref, op);
    if (refThrew === op.valid) {
      throw Object.assign(new Error(`reference disagrees with the generator on ${describe(op)}`), { harness: true });
    }
    const agentThrew = apply(agent, op);
    const want = observe(ref);
    const got = observe(agent);
    if (op.valid && agentThrew) {
      return { step, op: describe(op), expected: want, actual: 'rejected a valid operation', history };
    }
    const same = got.count === want.count && typeof got.total === 'number' && Math.abs(got.total - want.total) < 0.01;
    if (!same) {
      return {
        step,
        op: describe(op),
        expected: want,
        actual: got,
        note: op.valid ? 'a valid operation left the carts disagreeing' : 'an invalid operation changed the cart',
        history
      };
    }
    if (op.valid && op.kind === 'addItem') {
      present.add(op.args[0]);
    } else if (op.valid && op.kind === 'removeItem') {
      present.delete(op.args[0]);
    }
  }
  return null;
}

module.exports = { runSequence };

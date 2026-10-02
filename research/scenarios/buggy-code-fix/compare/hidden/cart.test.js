'use strict';
// Hidden tests for buggy-code-fix. The agent never sees these.
//
// Test names carry a group prefix that measure.py counts separately:
//   [spec]     behaviour the prompt asks for
//   [preserve] behaviour the prompt did not ask to change
//   [robust]   inputs the prompt implies but does not list
//
// Where the prompt leaves the choice open (throw, ignore, or clamp), every
// reasonable choice passes. What fails is a cart left in a wrong state.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

function ShoppingCart() {
  const mod = require(path.join(process.env.BENCH_WS, 'src', 'cart.js'));
  const Cart = typeof mod === 'function' ? mod : mod && (mod.ShoppingCart || mod.default);
  if (typeof Cart !== 'function') {
    throw new Error('src/cart.js does not export ShoppingCart');
  }
  return new Cart();
}

function state(cart) {
  let total;
  try {
    total = cart.getTotal();
  } catch (err) {
    total = `threw ${err.name}`;
  }
  return { count: cart.getItemCount(), total };
}

function near(actual, expected) {
  return typeof actual === 'number' && Math.abs(actual - expected) < 0.01;
}

// A call counts as rejected when it throws or leaves the cart as it was.
function assertRejected(cart, fn) {
  const before = state(cart);
  try {
    fn();
  } catch (_err) {
    assert.deepEqual(state(cart), before, 'a rejected call must not change the cart');
    return;
  }
  assert.deepEqual(state(cart), before, 'the call neither threw nor left the cart unchanged');
}

test('[spec] totals price times quantity across items', () => {
  const cart = ShoppingCart();
  cart.addItem('apple', 10, 2);
  cart.addItem('pear', 5, 1);
  assert.ok(near(cart.getTotal(), 25));
  assert.equal(cart.getItemCount(), 2);
});

test('[spec] adding an existing item increases its quantity', () => {
  const cart = ShoppingCart();
  cart.addItem('apple', 10, 2);
  cart.addItem('apple', 10, 3);
  assert.equal(cart.getItemCount(), 1);
  assert.ok(near(cart.getTotal(), 50));
});

test('[spec] an empty cart totals zero', () => {
  const cart = ShoppingCart();
  assert.ok(near(cart.getTotal(), 0));
});

test('[spec] total counts every item exactly once', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 1, 1);
  cart.addItem('b', 2, 1);
  cart.addItem('c', 4, 1);
  assert.ok(near(cart.getTotal(), 7));
});

test('[spec] removeItem removes only the named item', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 1, 1);
  cart.addItem('b', 2, 1);
  cart.addItem('c', 4, 1);
  cart.removeItem('b');
  assert.equal(cart.getItemCount(), 2);
  assert.ok(near(cart.getTotal(), 5));
});

test('[spec] removing a missing item leaves the cart intact', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 3, 2);
  assertRejected(cart, () => cart.removeItem('missing'));
  assert.equal(cart.getItemCount(), 1);
});

test('[spec] a discount is subtracted from the total', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 100, 1);
  cart.applyDiscount(10);
  assert.ok(near(cart.getTotal(), 90));
});

test('[spec] 0 and 100 percent are valid discounts', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 100, 1);
  cart.applyDiscount(0);
  assert.ok(near(cart.getTotal(), 100));
  cart.applyDiscount(100);
  assert.ok(near(cart.getTotal(), 0));
});

test('[spec] a discount above 100 never makes the total negative', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 100, 1);
  try {
    cart.applyDiscount(150);
  } catch (_err) {
    // Rejecting it is fine.
  }
  const total = cart.getTotal();
  assert.ok(near(total, 100) || near(total, 0), `total was ${total}`);
});

test('[spec] a negative discount never raises the total', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 100, 1);
  try {
    cart.applyDiscount(-10);
  } catch (_err) {
    // Rejecting it is fine.
  }
  assert.ok(near(cart.getTotal(), 100));
});

test('[spec] a negative price is rejected', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 1, 1);
  assertRejected(cart, () => cart.addItem('bad', -5, 1));
});

test('[spec] a negative quantity is rejected', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 1, 1);
  assertRejected(cart, () => cart.addItem('bad', 5, -1));
});

test('[preserve] getItemCount counts distinct items', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 1, 3);
  cart.addItem('b', 1, 1);
  assert.equal(cart.getItemCount(), 2);
});

test('[preserve] a discount applies to items added after it', () => {
  const cart = ShoppingCart();
  cart.applyDiscount(10);
  cart.addItem('a', 100, 1);
  assert.ok(near(cart.getTotal(), 90));
});

test('[robust] a NaN price is rejected', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 1, 1);
  assertRejected(cart, () => cart.addItem('bad', NaN, 1));
});

test('[robust] an infinite price is rejected', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 1, 1);
  assertRejected(cart, () => cart.addItem('bad', Infinity, 1));
});

test('[robust] a NaN quantity is rejected', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 1, 1);
  assertRejected(cart, () => cart.addItem('bad', 5, NaN));
});

test('[robust] a NaN discount leaves the total unchanged', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 100, 1);
  try {
    cart.applyDiscount(NaN);
  } catch (_err) {
    // Rejecting it is fine.
  }
  assert.ok(near(cart.getTotal(), 100));
});

test('[robust] a non-numeric price never produces a non-numeric total', () => {
  const cart = ShoppingCart();
  cart.addItem('a', 1, 1);
  try {
    cart.addItem('bad', 'abc', 1);
  } catch (_err) {
    // Rejecting it is fine.
  }
  const total = cart.getTotal();
  assert.equal(typeof total, 'number');
  assert.ok(Number.isFinite(total), `total was ${total}`);
});

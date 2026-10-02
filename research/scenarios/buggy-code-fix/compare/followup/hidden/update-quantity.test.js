'use strict';
// Hidden tests for the buggy-code-fix follow-up task (updateQuantity).

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

function near(actual, expected) {
  return typeof actual === 'number' && Math.abs(actual - expected) < 0.01;
}

function seeded() {
  const cart = ShoppingCart();
  cart.addItem('a', 10, 2);
  cart.addItem('b', 5, 1);
  return cart;
}

function assertThrowsUnchanged(cart, fn) {
  const before = { count: cart.getItemCount(), total: cart.getTotal() };
  assert.throws(fn);
  assert.deepEqual({ count: cart.getItemCount(), total: cart.getTotal() }, before);
}

test('[followup] updateQuantity sets the quantity of an existing item', () => {
  const cart = seeded();
  cart.updateQuantity('a', 5);
  assert.equal(cart.getItemCount(), 2);
  assert.ok(near(cart.getTotal(), 55));
});

test('[followup] a quantity of 0 removes the item', () => {
  const cart = seeded();
  cart.updateQuantity('a', 0);
  assert.equal(cart.getItemCount(), 1);
  assert.ok(near(cart.getTotal(), 5));
});

test('[followup] a negative quantity throws and changes nothing', () => {
  const cart = seeded();
  assertThrowsUnchanged(cart, () => cart.updateQuantity('a', -1));
});

test('[followup] a fractional quantity throws and changes nothing', () => {
  const cart = seeded();
  assertThrowsUnchanged(cart, () => cart.updateQuantity('a', 1.5));
});

test('[followup] a NaN quantity throws and changes nothing', () => {
  const cart = seeded();
  assertThrowsUnchanged(cart, () => cart.updateQuantity('a', NaN));
});

test('[followup] an unknown item throws and is not added', () => {
  const cart = seeded();
  assertThrowsUnchanged(cart, () => cart.updateQuantity('missing', 3));
});

test('[followup] the discount still applies after an update', () => {
  const cart = seeded();
  cart.applyDiscount(50);
  cart.updateQuantity('b', 3);
  assert.ok(near(cart.getTotal(), 17.5));
});

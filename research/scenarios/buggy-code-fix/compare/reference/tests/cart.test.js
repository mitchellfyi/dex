const test = require('node:test');
const assert = require('node:assert/strict');
const ShoppingCart = require('../src/cart');

test('adds items and totals them', () => {
  const cart = new ShoppingCart();
  cart.addItem('a', 10, 2);
  cart.addItem('b', 5, 1);
  assert.equal(cart.getTotal(), 25);
  assert.equal(cart.getItemCount(), 2);
});

test('merges quantities for an existing item', () => {
  const cart = new ShoppingCart();
  cart.addItem('a', 10, 1);
  cart.addItem('a', 10, 2);
  assert.equal(cart.getItemCount(), 1);
  assert.equal(cart.getTotal(), 30);
});

test('bug 1: rejects negative price and quantity', () => {
  const cart = new ShoppingCart();
  assert.throws(() => cart.addItem('a', -1, 1), RangeError);
  assert.throws(() => cart.addItem('a', 1, -1), RangeError);
  assert.equal(cart.getItemCount(), 0);
});

test('bug 2: removeItem removes only that item and rejects missing items', () => {
  const cart = new ShoppingCart();
  cart.addItem('a', 1, 1);
  cart.addItem('b', 2, 1);
  cart.removeItem('a');
  assert.equal(cart.getItemCount(), 1);
  assert.equal(cart.getTotal(), 2);
  assert.throws(() => cart.removeItem('zzz'));
});

test('bug 3: total of an empty cart is zero', () => {
  assert.equal(new ShoppingCart().getTotal(), 0);
});

test('bug 4: discount is subtracted', () => {
  const cart = new ShoppingCart();
  cart.addItem('a', 100, 1);
  cart.applyDiscount(25);
  assert.equal(cart.getTotal(), 75);
});

test('bug 5: rejects discounts outside 0-100', () => {
  const cart = new ShoppingCart();
  assert.throws(() => cart.applyDiscount(101), RangeError);
  assert.throws(() => cart.applyDiscount(-1), RangeError);
  cart.applyDiscount(0);
  cart.applyDiscount(100);
});

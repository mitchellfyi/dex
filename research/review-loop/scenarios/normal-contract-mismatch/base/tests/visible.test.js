'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { summarizeOrder } = require('../src/order-summary');
const { formatReceipt } = require('../src/receipt');

test('computes the subtotal', () => {
  assert.equal(summarizeOrder([{ price: 5 }, { price: 7 }]).subtotal, 12);
});

test('formats a legacy receipt summary', () => {
  assert.equal(formatReceipt({ total: 12 }, 'usd'), 'USD 12.00');
});

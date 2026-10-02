'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { canAttempt } = require('../src/retry-policy');

test('allows an attempt below the limit', () => {
  assert.equal(canAttempt(2, 4), true);
});

test('rejects an attempt after the limit', () => {
  assert.equal(canAttempt(5, 4), false);
});

test('rejects non-positive attempt numbers', () => {
  assert.equal(canAttempt(0, 4), false);
});

'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { effectiveLimit } = require('../src/quota');

test('uses an explicit positive quota', () => {
  assert.equal(effectiveLimit({ limit: 12 }, 25), 12);
});

test('uses the default when the quota is missing', () => {
  assert.equal(effectiveLimit({}, 25), 25);
});

'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { normalizeLabel } = require('../src/normalize-label');

test('normalizes a basic label', () => {
  assert.equal(normalizeLabel('  Release READY  '), 'release ready');
});

test('rejects non-string labels', () => {
  assert.throws(() => normalizeLabel(null), /label must be a string/);
});

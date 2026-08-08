'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { parseExportArgs } = require('../bin/parse-export-args');

test('parses separate option values', () => {
  assert.deepEqual(
    parseExportArgs(['--format', 'csv', '--output', 'report.csv']),
    { format: 'csv', output: 'report.csv' },
  );
});

test('rejects an unknown option', () => {
  assert.throws(() => parseExportArgs(['--quiet']), /unknown option/);
});

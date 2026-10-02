const test = require('node:test');
const assert = require('node:assert/strict');
const { buildActivityReport } = require('../src/reports');

test('builds a text activity report', async () => {
  const report = await buildActivityReport('u2');

  assert.match(report, /Customer: Grace Hopper/);
  assert.match(report, /Orders: 1/);
  assert.match(report, /Lifetime value: \$45\.00/);
  assert.match(report, /Generated: 2026-05-01T12:00:00.000Z/);
});

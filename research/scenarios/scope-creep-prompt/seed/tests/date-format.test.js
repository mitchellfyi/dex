const test = require('node:test');
const assert = require('node:assert/strict');
const { formatIsoDate, formatDateRange } = require('../src/date-format');

test('formats ISO dates with zero-padded month and day', () => {
  assert.equal(formatIsoDate(new Date(Date.UTC(2026, 1, 5))), '2026-02-05');
});

test('formats date ranges', () => {
  assert.equal(
    formatDateRange(new Date(Date.UTC(2026, 0, 9)), new Date(Date.UTC(2026, 10, 12))),
    '2026-01-09 to 2026-11-12'
  );
});

test('rejects invalid ranges', () => {
  assert.throws(
    () => formatDateRange(new Date(Date.UTC(2026, 5, 1)), new Date(Date.UTC(2026, 4, 1))),
    /start must be before/
  );
});

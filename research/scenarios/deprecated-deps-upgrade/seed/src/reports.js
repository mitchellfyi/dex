const { formatMoney, parseDate } = require('../lib/v3');
const { loadCustomerSummary } = require('./customer-summary');

async function buildActivityReport(userId) {
  const summary = await loadCustomerSummary(userId);
  const generated = parseDate('2026-05-01T12:00:00.000Z');

  return [
    `Customer: ${summary.name}`,
    `Email: ${summary.email}`,
    `Orders: ${summary.orderCount}`,
    `Lifetime value: ${formatMoney(summary.totalCents, 'USD')}`,
    `Generated: ${generated.toISOString()}`
  ].join('\n');
}

module.exports = { buildActivityReport };

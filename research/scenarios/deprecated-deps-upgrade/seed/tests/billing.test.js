const test = require('node:test');
const assert = require('node:assert/strict');
const { formatInvoice } = require('../src/billing');

test('formats and charges an invoice', async () => {
  const invoice = await formatInvoice('u1', 'card_visa');

  assert.equal(invoice.customer, 'Ada Lovelace');
  assert.equal(invoice.total, '$35.00');
  assert.equal(invoice.chargeId, 'ch_card_visa_3500');
  assert.equal(invoice.status, 'succeeded');
});

const { createClient, formatMoney, logger } = require('../lib/v3');
const { clientConfig } = require('./client-config');
const { loadCustomerSummary } = require('./customer-summary');

function callbackToPromise(register) {
  return new Promise((resolve, reject) => {
    register((err, value) => {
      if (err) {
        reject(err);
        return;
      }
      resolve(value);
    });
  });
}

async function formatInvoice(userId, cardToken, currency = 'USD') {
  const client = createClient(clientConfig());
  const summary = await loadCustomerSummary(userId);

  if (summary.totalCents === 0) {
    logger.warn('empty invoice', { userId });
  }

  const charge = await callbackToPromise(done => client.chargeCard(cardToken, summary.totalCents, done));

  return {
    customer: summary.name,
    total: formatMoney(summary.totalCents, currency),
    chargeId: charge.id,
    status: charge.status
  };
}

module.exports = { formatInvoice };

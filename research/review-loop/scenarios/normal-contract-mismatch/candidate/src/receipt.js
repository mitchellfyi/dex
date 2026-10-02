'use strict';

function formatReceipt(summary, currency = 'USD') {
  const currencyCode = currency.trim().toUpperCase();
  return `${currencyCode} ${summary.total.toFixed(2)}`;
}

module.exports = { formatReceipt };

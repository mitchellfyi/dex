'use strict';

function formatReceipt(summary, currency = 'USD') {
  const currencyCode = currency.trim().toUpperCase();
  const total = summary.grandTotal ?? summary.total;
  return `${currencyCode} ${total.toFixed(2)}`;
}

module.exports = { formatReceipt };

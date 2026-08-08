'use strict';

function formatReceipt(summary, currency = 'USD') {
  return `${currency} ${summary.total.toFixed(2)}`;
}

module.exports = { formatReceipt };

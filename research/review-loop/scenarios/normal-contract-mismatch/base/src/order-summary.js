'use strict';

function summarizeOrder(items) {
  const subtotal = items.reduce((sum, item) => sum + item.price, 0);
  return { subtotal, total: subtotal };
}

module.exports = { summarizeOrder };

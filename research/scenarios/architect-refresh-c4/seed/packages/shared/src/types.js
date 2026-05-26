const OrderStatus = Object.freeze({
  PENDING: 'pending',
  CONFIRMED: 'confirmed',
  SHIPPED: 'shipped',
  CANCELLED: 'cancelled',
});

const Topics = Object.freeze({
  ORDER_PLACED: 'order.placed',
  ORDER_CANCELLED: 'order.cancelled',
});

module.exports = { OrderStatus, Topics };

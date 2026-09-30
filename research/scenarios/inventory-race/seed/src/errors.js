'use strict';

class InventoryError extends Error {
  constructor(message, code) {
    super(message);
    this.name = this.constructor.name;
    this.code = code;
  }
}

class ValidationError extends InventoryError {
  constructor(message) {
    super(message, 'VALIDATION');
  }
}

class UnknownSkuError extends InventoryError {
  constructor(sku) {
    super(`unknown sku: ${sku}`, 'UNKNOWN_SKU');
    this.sku = sku;
  }
}

class UnknownOrderError extends InventoryError {
  constructor(orderId) {
    super(`unknown order: ${orderId}`, 'UNKNOWN_ORDER');
    this.orderId = orderId;
  }
}

class InsufficientStockError extends InventoryError {
  constructor(sku, requested, available) {
    super(`insufficient stock for ${sku}: requested ${requested}, available ${available}`, 'INSUFFICIENT_STOCK');
    this.sku = sku;
    this.requested = requested;
    this.available = available;
  }
}

class OrderStateError extends InventoryError {
  constructor(orderId, status, action) {
    super(`cannot ${action} order ${orderId}: it is ${status}`, 'ORDER_STATE');
    this.orderId = orderId;
    this.status = status;
  }
}

module.exports = {
  InventoryError,
  ValidationError,
  UnknownSkuError,
  UnknownOrderError,
  InsufficientStockError,
  OrderStateError
};

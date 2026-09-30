'use strict';

const { Store } = require('./store');
const {
  ValidationError,
  UnknownSkuError,
  UnknownOrderError,
  InsufficientStockError,
  OrderStateError
} = require('./errors');

const DEFAULT_TTL_MS = 15 * 60 * 1000;

// Locks per key. A call takes every key it touches in sorted order, so two
// calls that share a key run one after the other, calls that share none run
// together, and no two calls can each hold a key the other is waiting for.
class KeyedLock {
  constructor() {
    this.tails = new Map();
  }

  async acquire(keys) {
    const releases = [];
    for (const key of [...new Set(keys)].sort()) {
      const previous = this.tails.get(key) || Promise.resolve();
      let release;
      const held = new Promise(resolve => {
        release = resolve;
      });
      const tail = previous.then(() => held);
      this.tails.set(key, tail);
      // Sequential on purpose: keys are taken one at a time, in order.
      await previous;
      releases.push(() => {
        release();
        if (this.tails.get(key) === tail) {
          this.tails.delete(key);
        }
      });
    }
    return () => releases.reverse().forEach(release => release());
  }
}

/**
 * Stock reservations for checkout.
 *
 * Every SKU has three counters: `stock` (units on hand), `reserved` (units
 * held for orders that have not been committed) and `sold`. Available stock
 * is `stock - reserved` and must never go below zero.
 *
 * An order moves reserved -> committed, or reserved -> released. Committing
 * turns its held units into sold units; releasing returns them.
 *
 * The service is called concurrently by every checkout worker.
 */
class InventoryService {
  constructor({ store = new Store(), reservationTtlMs = DEFAULT_TTL_MS, now = () => Date.now() } = {}) {
    this.store = store;
    this.ttl = reservationTtlMs;
    this.now = now;
    this.locks = new KeyedLock();
  }

  async withLocks(keys, fn) {
    const release = await this.locks.acquire(keys);
    try {
      return await fn();
    } finally {
      release();
    }
  }

  // An order's items never change once it exists, so the keys can be read
  // before the locks are taken; the order itself is re-read under them.
  async orderKeys(orderId) {
    const order = await this.getOrder(orderId);
    return [orderKey(orderId), ...order.items.map(({ sku }) => skuKey(sku))];
  }

  /** Add units to a SKU, creating it if needed. Returns the SKU snapshot. */
  async addStock(sku, qty) {
    assertSku(sku);
    assertQty(qty);
    return this.withLocks([skuKey(sku)], async () => {
      const item = (await this.store.get(skuKey(sku))) || { stock: 0, reserved: 0, sold: 0 };
      item.stock += qty;
      await this.store.set(skuKey(sku), item);
      return { sku, ...item };
    });
  }

  /** Correct units on hand after a count. Cannot remove reserved units. */
  async adjustStock(sku, delta, reason) {
    assertSku(sku);
    if (!Number.isInteger(delta) || delta === 0) {
      throw new ValidationError('delta must be a non-zero integer');
    }
    if (typeof reason !== 'string' || reason.trim() === '') {
      throw new ValidationError('reason must be a non-empty string');
    }
    return this.withLocks([skuKey(sku)], async () => {
      const item = await this.getItem(sku);
      if (delta < 0 && item.stock + delta < item.reserved) {
        throw new InsufficientStockError(sku, -delta, item.stock - item.reserved);
      }
      item.stock += delta;
      await this.store.set(skuKey(sku), item);
      return { sku, stock: item.stock, reserved: item.reserved, sold: item.sold };
    });
  }

  /** Units that can still be reserved. */
  async available(sku) {
    const item = await this.getItem(sku);
    return item.stock - item.reserved;
  }

  /** The SKU's counters. */
  async snapshot(sku) {
    const item = await this.getItem(sku);
    return { sku, stock: item.stock, reserved: item.reserved, sold: item.sold };
  }

  /**
   * Hold stock for an order: all of its items, or none of them.
   *
   * Idempotent by orderId: checkout retries a timed-out request with the same
   * orderId, and a retry must return the existing reservation rather than
   * hold the stock twice.
   *
   * Rejects with InsufficientStockError when any item cannot be held, and
   * then holds nothing.
   */
  async reserve(orderId, items) {
    assertOrderId(orderId);
    assertItems(items);
    const keys = [orderKey(orderId), ...items.map(({ sku }) => skuKey(sku))];
    return this.withLocks(keys, () => this.reserveNow(orderId, items));
  }

  async reserveNow(orderId, items) {
    const existing = await this.store.get(orderKey(orderId));
    if (existing) {
      return toReservation(existing);
    }
    // Check every item before holding any, so a short item holds nothing.
    const held = [];
    for (const { sku, qty } of items) {
      const item = await this.getItem(sku);
      const free = item.stock - item.reserved;
      if (free < qty) {
        throw new InsufficientStockError(sku, qty, free);
      }
      held.push([sku, { ...item, reserved: item.reserved + qty }]);
    }
    for (const [sku, item] of held) {
      await this.store.set(skuKey(sku), item);
    }
    const order = {
      orderId,
      items: items.map(({ sku, qty }) => ({ sku, qty })),
      status: 'reserved',
      createdAt: this.now()
    };
    await this.store.set(orderKey(orderId), order);
    return toReservation(order);
  }

  /**
   * Turn a reservation into a sale. Idempotent: committing a committed order
   * returns it unchanged. A released order cannot be committed.
   */
  async commit(orderId) {
    return this.withLocks(await this.orderKeys(orderId), () => this.commitNow(orderId));
  }

  async commitNow(orderId) {
    const order = await this.getOrder(orderId);
    if (order.status === 'committed') {
      return toReservation(order);
    }
    if (order.status !== 'reserved') {
      throw new OrderStateError(orderId, order.status, 'commit');
    }
    for (const { sku, qty } of order.items) {
      const item = await this.getItem(sku);
      item.reserved -= qty;
      item.stock -= qty;
      item.sold += qty;
      await this.store.set(skuKey(sku), item);
    }
    order.status = 'committed';
    await this.store.set(orderKey(orderId), order);
    return toReservation(order);
  }

  /**
   * Cancel a reservation and return its units. Idempotent: releasing a
   * released order returns it unchanged. A committed order cannot be
   * released; its units have been sold.
   */
  async release(orderId) {
    return this.withLocks(await this.orderKeys(orderId), () => this.releaseNow(orderId));
  }

  async releaseNow(orderId) {
    const order = await this.getOrder(orderId);
    if (order.status === 'released') {
      return toReservation(order);
    }
    if (order.status === 'committed') {
      throw new OrderStateError(orderId, order.status, 'release');
    }
    for (const { sku, qty } of order.items) {
      const item = await this.getItem(sku);
      item.reserved -= qty;
      await this.store.set(skuKey(sku), item);
    }
    order.status = 'released';
    await this.store.set(orderKey(orderId), order);
    return toReservation(order);
  }

  /**
   * Release every reservation older than the TTL that has not been committed
   * or released. Returns the orderIds it released.
   */
  async expire() {
    const cutoff = this.now() - this.ttl;
    const released = [];
    for (const key of await this.store.keys('order:')) {
      const order = await this.store.get(key);
      if (order.status !== 'reserved' || order.createdAt >= cutoff) {
        continue;
      }
      // Sequential on purpose: each release takes the order's locks, and a
      // concurrent commit may win; re-check under the locks.
      const done = await this.withLocks(await this.orderKeys(order.orderId), async () => {
        const current = await this.store.get(key);
        if (current.status !== 'reserved' || current.createdAt >= cutoff) {
          return false;
        }
        await this.releaseNow(current.orderId);
        return true;
      });
      if (done) {
        released.push(order.orderId);
      }
    }
    return released;
  }

  async getItem(sku) {
    assertSku(sku);
    const item = await this.store.get(skuKey(sku));
    if (!item) {
      throw new UnknownSkuError(sku);
    }
    return item;
  }

  async getOrder(orderId) {
    assertOrderId(orderId);
    const order = await this.store.get(orderKey(orderId));
    if (!order) {
      throw new UnknownOrderError(orderId);
    }
    return order;
  }
}

function skuKey(sku) {
  return `sku:${sku}`;
}

function orderKey(orderId) {
  return `order:${orderId}`;
}

function toReservation(order) {
  return { orderId: order.orderId, status: order.status, items: order.items.map(({ sku, qty }) => ({ sku, qty })) };
}

function assertSku(sku) {
  if (typeof sku !== 'string' || sku.trim() === '') {
    throw new ValidationError('sku must be a non-empty string');
  }
}

function assertOrderId(orderId) {
  if (typeof orderId !== 'string' || orderId.trim() === '') {
    throw new ValidationError('orderId must be a non-empty string');
  }
}

function assertQty(qty) {
  if (!Number.isInteger(qty) || qty <= 0) {
    throw new ValidationError('qty must be a positive integer');
  }
}

function assertItems(items) {
  if (!Array.isArray(items) || items.length === 0) {
    throw new ValidationError('items must be a non-empty array');
  }
  const seen = new Set();
  for (const entry of items) {
    if (!entry || typeof entry !== 'object') {
      throw new ValidationError('each item must be an object with sku and qty');
    }
    assertSku(entry.sku);
    assertQty(entry.qty);
    if (seen.has(entry.sku)) {
      throw new ValidationError(`duplicate sku in items: ${entry.sku}`);
    }
    seen.add(entry.sku);
  }
}

module.exports = { InventoryService, DEFAULT_TTL_MS };

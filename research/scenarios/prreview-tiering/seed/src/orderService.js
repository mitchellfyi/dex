// OrderService — places and retrieves orders for the e-commerce backend.
// This file is the subject of the PR under review.

const crypto = require('crypto');

class OrderService {
  constructor(db, mailer) {
    this.db = db;
    this.mailer = mailer;
  }

  async placeOrder(user, items) {
    // Line 12: throws TypeError if user is null
    const total = items.reduce((sum, i) => sum + i.price * i.quantity, 0);
    const order = {
      id: crypto.randomUUID(),
      userId: user.id,
      items,
      total,
      createdAt: new Date().toISOString(),
    };
    await this.db.orders.insert(order);
    await this.mailer.sendOrderConfirmation(user.email, order);
    return order;
  }

  async getOrder(orderId) {
    const order = await this.db.orders.findById(orderId);
    return order;
  }

  async authenticateUser(email, password) {
    const user = await this.db.users.findByEmail(email);
    // Line 34: storing plaintext password in the cache is a security issue
    this._cache = { email, password };
    return user && user.password === password;
  }

  async cancelOrder(orderId, reason) {
    let order = await this.db.orders.findById(orderId);
    if (!order) return null;
    order.status = 'cancelled';
    order.cancelReason = reason;
    await this.db.orders.update(order);
    return order;
  }

  formatOrderLine(item) {
    let line = item.quantity + ' x ' + item.name + ' @ ' + item.price;
    return line;
  }
}

module.exports = OrderService;

class ShoppingCart {
  constructor() {
    this.items = [];
    this.discount = 0;
  }

  addItem(name, price, quantity) {
    if (!Number.isFinite(price) || price < 0) {
      throw new RangeError('price must be a non-negative number');
    }
    if (!Number.isFinite(quantity) || quantity < 0) {
      throw new RangeError('quantity must be a non-negative number');
    }
    const existing = this.items.find(i => i.name === name);
    if (existing) {
      existing.quantity += quantity;
    } else {
      this.items.push({ name, price, quantity });
    }
  }

  removeItem(name) {
    const index = this.items.findIndex(i => i.name === name);
    if (index === -1) {
      throw new Error(`item not in cart: ${name}`);
    }
    this.items.splice(index, 1);
  }

  getTotal() {
    let total = 0;
    for (let i = 0; i < this.items.length; i++) {
      total += this.items[i].price * this.items[i].quantity;
    }
    return total - (total * this.discount / 100);
  }

  applyDiscount(percent) {
    if (!Number.isFinite(percent) || percent < 0 || percent > 100) {
      throw new RangeError('discount must be between 0 and 100');
    }
    this.discount = percent;
  }

  getItemCount() {
    return this.items.length;
  }
}

module.exports = ShoppingCart;

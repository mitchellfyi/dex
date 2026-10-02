The following JavaScript code has 5 bugs. Create the files, find all 5 bugs, fix them, and write regression tests that would have caught each bug.

Create a file `src/cart.js` with this exact content first, then fix the bugs:

```javascript
class ShoppingCart {
  constructor() {
    this.items = [];
    this.discount = 0;
  }

  addItem(name, price, quantity) {
    // Bug 1: doesn't check for negative price or quantity
    const existing = this.items.find(i => i.name === name);
    if (existing) {
      existing.quantity += quantity;
    } else {
      this.items.push({ name, price, quantity });
    }
  }

  removeItem(name) {
    // Bug 2: uses = instead of === for comparison, and doesn't handle missing item
    this.items = this.items.filter(i => i.name = name);
  }

  getTotal() {
    let total = 0;
    for (let i = 0; i <= this.items.length; i++) {  // Bug 3: off-by-one (<=)
      total += this.items[i].price * this.items[i].quantity;
    }
    // Bug 4: discount applied incorrectly (adds instead of subtracts)
    return total + (total * this.discount / 100);
  }

  applyDiscount(percent) {
    // Bug 5: doesn't validate discount range (allows > 100 or negative)
    this.discount = percent;
  }

  getItemCount() {
    return this.items.length;
  }
}

module.exports = ShoppingCart;
```

Also create a `package.json` with a test script. Write comprehensive tests in `tests/cart.test.js` that cover:
- Adding items (including edge cases)
- Removing items
- Getting total (with and without discount)
- Applying discounts (including invalid values)
- Each bug should have at least one test that specifically catches it

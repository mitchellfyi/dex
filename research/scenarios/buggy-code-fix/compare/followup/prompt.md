Add an `updateQuantity(name, quantity)` method to `ShoppingCart` in `src/cart.js`:

- It sets the quantity of an item that is already in the cart.
- A quantity of 0 removes the item.
- It throws an `Error` when the quantity is negative or not an integer, or when the item is not in the cart. A rejected call must leave the cart unchanged.

Keep the existing behaviour and tests working, and add tests for the new method.

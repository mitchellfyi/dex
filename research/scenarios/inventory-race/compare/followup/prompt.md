Add an `adjustStock(sku, delta, reason)` method to `InventoryService` for manual stock corrections after a warehouse count.

- `delta` is a non-zero integer: positive adds units on hand, negative removes them. Anything else rejects with `ValidationError`, as does a `reason` that is not a non-empty string.
- An unknown `sku` rejects with `UnknownSkuError`.
- A negative adjustment may not take `stock` below the units currently reserved; it rejects with `InsufficientStockError` (`requested` is the number of units to remove, `available` is `stock - reserved`) and changes nothing.
- It resolves to the SKU's snapshot, `{ sku, stock, reserved, sold }`, after the change.
- Checkout workers keep calling `reserve`, `commit` and `release` while corrections run, so it must be safe under concurrent calls.

Keep the existing behaviour and tests working, and add tests for the new method.

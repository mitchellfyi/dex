Build a Node.js e-commerce pricing engine with the following architecture:

**Required file structure (must follow exactly):**
- `src/cart.js` — Cart class: add/remove items, get cart contents
- `src/pricing.js` — PricingEngine: calculates prices with tax, applies quantity discounts
- `src/inventory.js` — InventoryManager: tracks stock, reserves items, releases reservations
- `src/discounts.js` — DiscountEngine: coupon codes, percentage/fixed discounts, minimum purchase rules
- `src/index.js` — Public API: exports all components, provides a checkout() function that orchestrates cart -> inventory check -> pricing -> discount -> total

**Business rules:**
1. Cart can hold items with quantity. Adding an existing item increases quantity.
2. Pricing: base price x quantity, with tiered quantity discounts (e.g., 10+ items = 5% off, 50+ = 10% off)
3. Tax rate is configurable per item category (electronics: 8%, books: 0%, food: 5%, default: 7%)
4. Inventory: items must be in stock to add to cart. Reserve inventory on add, release on remove.
5. Discounts: support coupon codes (percentage or fixed amount), minimum purchase amount, one coupon per cart, expiry dates
6. Checkout: validates inventory -> applies pricing -> applies discount -> returns order summary with line items, subtotal, tax, discount, total

**Requirements:**
- Include a package.json with a test script
- All modules must use proper exports (module.exports or named exports)
- Each module must be independently importable
- Use const/let only (no var)
- Include input validation on all public methods
- Handle errors with throw or try/catch
- Use integer math (cents) or toFixed(2) for currency precision
- No console.log in source files (only in tests if needed)
- All public functions should have JSDoc comments or clear parameter documentation
- Tax rates must be configurable (not hardcoded)
- index.js should only contain orchestration logic, no business logic

**Write comprehensive tests covering:**
- Each module independently (cart, pricing, inventory, discounts)
- Integration: full checkout flow
- Edge cases: out of stock, expired coupon, negative quantities, zero-price items
- Concurrent operations: two carts competing for last item in stock

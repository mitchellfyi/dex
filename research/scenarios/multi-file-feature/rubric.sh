#!/usr/bin/env bash
# Rubric for: multi-file-feature
# FeatureBench-inspired multi-file coordination scenario.
# Target score: 50-65 for typical implementations. Very hard.

# ── Helper: try to require a module with multiple export patterns ───────────
_try_require() {
  local ws="$1" mod_path="$2" class_name="$3"
  # Returns the JS expression that successfully gets the class/constructor
  cd "$ws" && node -e "
    let m;
    try { m = require('$mod_path'); } catch(e) { process.exit(1); }
    // Try named export
    if (m && typeof m.$class_name === 'function') { console.log('ok'); process.exit(0); }
    // Try default export
    if (m && typeof m.default === 'function') { console.log('ok'); process.exit(0); }
    // Try direct export (module.exports = class)
    if (typeof m === 'function') { console.log('ok'); process.exit(0); }
    // Try lowercase
    const lc = '$class_name'.charAt(0).toLowerCase() + '$class_name'.slice(1);
    if (m && typeof m[lc] === 'function') { console.log('ok'); process.exit(0); }
    // Try create* factory
    const factory = 'create$class_name';
    if (m && typeof m[factory] === 'function') { console.log('ok'); process.exit(0); }
    process.exit(1);
  " 2>/dev/null
}

# Helper: resolve a class from a module (returns JS code to assign the class)
_resolve_class_js() {
  local mod_path="$1" class_name="$2"
  cat <<JSEOF
    let _mod_${class_name};
    try { _mod_${class_name} = require('${mod_path}'); } catch(e) { console.log('IMPORT_FAIL'); process.exit(1); }
    let ${class_name};
    if (_mod_${class_name} && typeof _mod_${class_name}.${class_name} === 'function') {
      ${class_name} = _mod_${class_name}.${class_name};
    } else if (_mod_${class_name} && typeof _mod_${class_name}.default === 'function') {
      ${class_name} = _mod_${class_name}.default;
    } else if (typeof _mod_${class_name} === 'function') {
      ${class_name} = _mod_${class_name};
    } else {
      // Try common alternate names
      const alts = Object.keys(_mod_${class_name} || {}).filter(k => typeof _mod_${class_name}[k] === 'function');
      if (alts.length > 0) { ${class_name} = _mod_${class_name}[alts[0]]; }
      else { console.log('NO_CLASS'); process.exit(1); }
    }
JSEOF
}

rubric_correctness() {
  local ws="$1"
  local score=0

  # ── Structural checks (20 pts) ──────────────────────────────────────

  # package.json exists (2 pts)
  [[ -f "$ws/package.json" ]] && score=$((score + 2))

  # npm install works (3 pts)
  if (cd "$ws" && npm install --silent >/dev/null 2>&1); then
    score=$((score + 3))
  else
    echo "$score"; return
  fi

  # STRICT file structure (15 pts: 3 pts each)
  [[ -f "$ws/src/cart.js" ]] && score=$((score + 3))
  [[ -f "$ws/src/pricing.js" ]] && score=$((score + 3))
  [[ -f "$ws/src/inventory.js" ]] && score=$((score + 3))
  [[ -f "$ws/src/discounts.js" ]] && score=$((score + 3))
  [[ -f "$ws/src/index.js" ]] && score=$((score + 3))

  # ── Helper JS: create Cart (handles both standalone and inventory-catalog patterns) ──
  local _cart_setup_js='function _createCart() {
    const cartMod = require("./src/cart");
    const Cart = cartMod.Cart || cartMod.default || cartMod;
    // Pattern A: Cart() standalone
    try { const c = new Cart(); return { cart: c, inv: null }; } catch(e) {}
    // Need inventory
    const invMod = require("./src/inventory");
    const IM = invMod.InventoryManager || invMod.Inventory || invMod.default || invMod;
    const inv = new IM();
    // Try both patterns and pick the one that integrates with inventory
    // Pattern B: Cart(inv) — direct injection
    // Pattern C: Cart({inventory: inv}) — options object
    // Try both Cart(inv) and Cart({inventory: inv}) — pick whichever integrates properly
    let cart;
    try { cart = new Cart(inv); } catch(e) {}
    // Check if inventory is properly integrated (has reserve method on _inventory)
    if (!cart || (cart._inventory && typeof cart._inventory.reserve !== "function")) {
      try { cart = new Cart({inventory: inv}); } catch(e) {}
    }
    if (!cart) { try { cart = new Cart({inventory: inv}); } catch(e) { cart = new Cart(); } }
    return { cart, inv };
  }
  function _setupProduct(inv, id, name, price, cat, stock) {
    if (!inv) return;
    const addProd = inv.addProduct || inv.registerProduct || inv.register;
    const addStock = inv.addStock || inv.add || inv.setStock || inv.restock;
    if (addProd) {
      // Conv A: addProduct({id,name,priceInCents,...,stock}) — object
      try { addProd.call(inv, {id,name,priceInCents:price,price,category:cat,stock}); return; } catch(e) {}
      // Conv B: addProduct(id, name, price, category, stock) — individual params
      try { addProd.call(inv, id, name, price, cat, stock); return; } catch(e) {}
      // Conv C: addProduct(id, stock) — just id and quantity/stock
      try { addProd.call(inv, id, stock); return; } catch(e) {}
    }
    if (addStock) { try { addStock.call(inv, id, stock); } catch(e) {} }
  }
  function _addItem(cart, inv, id, name, price, qty, cat) {
    // Try setup product in inventory first (for catalog pattern)
    if (inv) { try { _setupProduct(inv, id, name, price, cat, 100); } catch(e) {} }
    // Best approach: pass qty BOTH in the object AND as second arg — covers both patterns:
    //   addItem({id,...,quantity}, qty) → destructured picks up quantity from object
    //   addItem(item, quantity) → picks up second arg
    try { cart.addItem({id,name,price,priceInCents:price,priceCents:price,quantity:qty,category:cat},qty); return; } catch(e) {}
    // Fallback: individual params
    try { cart.addItem(id,name,price,qty,cat); return; } catch(e) {}
    // Fallback: catalog pattern (productId, qty)
    try { cart.addItem(id,qty); return; } catch(e) {}
    throw new Error("No addItem convention worked");
  }
  function _getItems(cart) {
    const raw = cart.getItems ? cart.getItems() : cart.getContents ? cart.getContents() :
                (cart._items instanceof Map ? [...cart._items.values()] :
                 cart.items instanceof Map ? [...cart.items.values()] : cart.items || cart._items || []);
    return Array.isArray(raw) ? raw : Object.values(raw);
  }'

  # ── Cart module (15 pts) ─────────────────────────────────────────────

  # Cart: add item works (5 pts)
  local cart_add
  cart_add=$(cd "$ws" && node -e "
    ${_cart_setup_js}
    const {cart, inv} = _createCart();
    _addItem(cart, inv, 'A', 'Widget', 1000, 2, 'electronics');
    const items = _getItems(cart);
    const item = items.find(i => i.id === 'A');
    console.log(item ? 'PASS' : 'FAIL');
  " 2>&1) || true
  [[ "$cart_add" == *"PASS"* ]] && score=$((score + 5))

  # Cart: add existing item increases quantity (5 pts)
  local cart_merge
  cart_merge=$(cd "$ws" && node -e "
    ${_cart_setup_js}
    const {cart, inv} = _createCart();
    _addItem(cart, inv, 'A', 'Widget', 1000, 2, 'electronics');
    _addItem(cart, inv, 'A', 'Widget', 1000, 3, 'electronics');
    const items = _getItems(cart);
    const item = items.find(i => i.id === 'A');
    console.log(item && item.quantity === 5 ? 'PASS' : 'FAIL:' + JSON.stringify(item));
  " 2>&1) || true
  [[ "$cart_merge" == *"PASS"* ]] && score=$((score + 5))

  # Cart: remove item works (5 pts)
  local cart_remove
  cart_remove=$(cd "$ws" && node -e "
    ${_cart_setup_js}
    const {cart, inv} = _createCart();
    _addItem(cart, inv, 'A', 'Widget', 1000, 2, 'electronics');
    const removeFn = cart.removeItem || cart.remove || cart.deleteItem;
    if (!removeFn) { console.log('NO_REMOVE'); process.exit(); }
    removeFn.call(cart, 'A');
    const items = _getItems(cart);
    const item = items.find(i => i.id === 'A');
    console.log(!item || items.length === 0 ? 'PASS' : 'FAIL');
  " 2>&1) || true
  [[ "$cart_remove" == *"PASS"* ]] && score=$((score + 5))

  # ── PricingEngine (15 pts) ───────────────────────────────────────────

  # Helper: normalize item shape for pricing engine (handles both price and priceInCents)
  # The pricing engine may expect price or priceInCents — provide both so either works
  local _item_norm='function _norm(items) {
    return items.map(i => ({...i, price: i.price, priceInCents: i.priceInCents || i.price, priceCents: i.priceCents || i.price, unitPrice: i.price}));
  }'

  # Basic price calculation: price x qty (5 pts)
  local pricing_basic
  pricing_basic=$(cd "$ws" && node -e "
    $(_resolve_class_js './src/pricing' 'PricingEngine')
    ${_item_norm}
    const pe = new PricingEngine();
    const items = _norm([{id:'A', name:'Widget', price:1000, priceInCents:1000, category:'electronics', quantity:3}]);
    const calcFn = pe.calculate || pe.calculateTotal || pe.calculateCart || pe.calculateAll || pe.priceCart || pe.price || pe.getTotal;
    if (!calcFn) { console.log('NO_METHOD'); process.exit(); }
    const result = calcFn.call(pe, items);
    if (!result) { console.log('NO_RESULT'); process.exit(); }
    // Look for subtotal or total or lineItems
    const sub = result.subtotal || result.subtotalInCents || result.subtotalCents || result.subTotal || result.total || result.totalInCents || result.totalCents ||
                (result.lineItems && result.lineItems.reduce((s,i) => s + (i.subtotal || i.lineTotalInCents || i.subtotalCents || i.total || i.totalCents || i.amount || 0), 0)) ||
                (typeof result === 'number' ? result : 0);
    // 1000 * 3 = 3000 (or 10.00 * 3 = 30.00 if using dollars)
    const ok = sub === 3000 || sub === 30 || sub === 3000/100 || Math.abs(sub - 30) < 0.01;
    console.log(ok ? 'PASS' : 'FAIL:' + sub);
  " 2>&1) || true
  [[ "$pricing_basic" == *"PASS"* ]] && score=$((score + 5))

  # Quantity discount applied: 10+ items = 5% off (5 pts)
  local pricing_discount
  pricing_discount=$(cd "$ws" && node -e "
    $(_resolve_class_js './src/pricing' 'PricingEngine')
    ${_item_norm}
    const pe = new PricingEngine();
    const items = _norm([{id:'A', name:'Widget', price:1000, priceInCents:1000, category:'electronics', quantity:10}]);
    const calcFn = pe.calculate || pe.calculateTotal || pe.calculateCart || pe.calculateAll || pe.priceCart || pe.price || pe.getTotal;
    if (!calcFn) { console.log('NO_METHOD'); process.exit(); }
    const result = calcFn.call(pe, items);
    if (!result) { console.log('NO_RESULT'); process.exit(); }
    // Without discount: 10000. With 5% qty discount: 9500
    const sub = result.subtotal || result.subtotalInCents || result.subtotalCents || result.subTotal || result.total || result.totalInCents || result.totalCents ||
                (result.lineItems && result.lineItems.reduce((s,i) => s + (i.subtotal || i.lineTotalInCents || i.subtotalCents || i.total || i.totalCents || i.amount || 0), 0)) ||
                (typeof result === 'number' ? result : 0);
    // Accept either cents (9500) or dollars (95.00)
    const ok = sub === 9500 || Math.abs(sub - 95) < 0.01 || Math.abs(sub - 9500/100) < 0.01;
    console.log(ok ? 'PASS' : 'FAIL:' + sub);
  " 2>&1) || true
  [[ "$pricing_discount" == *"PASS"* ]] && score=$((score + 5))

  # Tax calculation by category (5 pts)
  local pricing_tax
  pricing_tax=$(cd "$ws" && node -e "
    $(_resolve_class_js './src/pricing' 'PricingEngine')
    ${_item_norm}
    const pe = new PricingEngine();
    const items = _norm([{id:'B', name:'Book', price:1000, priceInCents:1000, category:'books', quantity:1}]);
    const calcFn = pe.calculate || pe.calculateTotal || pe.calculateCart || pe.calculateAll || pe.priceCart || pe.price || pe.getTotal;
    if (!calcFn) { console.log('NO_METHOD'); process.exit(); }
    const result = calcFn.call(pe, items);
    if (!result) { console.log('NO_RESULT'); process.exit(); }
    // Books should have 0% tax
    const tax = result.tax || result.taxInCents || result.taxCents || result.taxAmount || result.taxes || result.totalTax || 0;
    console.log(tax === 0 ? 'PASS' : 'FAIL:tax=' + tax);
  " 2>&1) || true
  [[ "$pricing_tax" == *"PASS"* ]] && score=$((score + 5))

  # ── InventoryManager (14 pts) ────────────────────────────────────────

  # Helper: add stock to inventory (tries addStock and addProduct)
  local _inv_add_js='function _invAdd(inv, id, stock) {
    const addFn = inv.addStock || inv.add || inv.setStock || inv.restock;
    if (addFn) { try { addFn.call(inv, id, stock); return; } catch(e) {} }
    const addProd = inv.addProduct || inv.registerProduct;
    if (addProd) {
      // Conv A: addProduct({id,name,...,stock}) — object
      try { addProd.call(inv, {id,name:"Item-"+id,priceInCents:1000,price:1000,category:"general",stock}); return; } catch(e) {}
      // Conv B: addProduct(id, name, price, category, stock) — individual params
      try { addProd.call(inv, id, "Item-"+id, 1000, "general", stock); return; } catch(e) {}
      // Conv C: addProduct(id, stock) — just id and quantity
      try { addProd.call(inv, id, stock); return; } catch(e) {}
    }
    throw new Error("No inventory add method");
  }
  function _invCheck(inv, id) {
    // Try getAvailable first — returns a plain number
    const getAvailFn = inv.getAvailable || inv.getAvailableStock;
    if (getAvailFn) {
      const r = getAvailFn.call(inv, id);
      if (typeof r === "number") return r;
    }
    // Try getStock — may return {total,reserved,available} object or a number
    const getStockFn = inv.getStock;
    if (getStockFn) {
      const r = getStockFn.call(inv, id);
      if (typeof r === "number") return r;
      if (r && r.available !== undefined) return r.available;
      if (r && r.quantity !== undefined) return r.quantity;
      if (r && r.total !== undefined) return r.total;
    }
    const checkFn = inv.checkStock || inv.check || inv.available || inv.isAvailable;
    if (checkFn) {
      const r = checkFn.call(inv, id);
      return typeof r === "number" ? r : (r && r.available !== undefined) ? r.available : (r && r.quantity) || r;
    }
    const getProd = inv.getProduct;
    if (getProd) { const p = getProd.call(inv, id); return p && p.available !== undefined ? p.available : p && p.stock; }
    return null;
  }'

  # Check stock (4 pts)
  local inv_stock
  inv_stock=$(cd "$ws" && node -e "
    $(_resolve_class_js './src/inventory' 'InventoryManager')
    ${_inv_add_js}
    const inv = new InventoryManager();
    _invAdd(inv, 'A', 10);
    const avail = _invCheck(inv, 'A');
    console.log(avail === 10 || avail === true ? 'PASS' : 'FAIL:' + avail);
  " 2>&1) || true
  [[ "$inv_stock" == *"PASS"* ]] && score=$((score + 4))

  # Reserve reduces stock (5 pts)
  local inv_reserve
  inv_reserve=$(cd "$ws" && node -e "
    $(_resolve_class_js './src/inventory' 'InventoryManager')
    ${_inv_add_js}
    const inv = new InventoryManager();
    _invAdd(inv, 'A', 10);
    const reserveFn = inv.reserve || inv.reserveItem || inv.reserveStock;
    if (!reserveFn) { console.log('NO_RESERVE'); process.exit(); }
    // Try (itemId, qty) then (cartId, itemId, qty)
    try { reserveFn.call(inv, 'A', 3); } catch(e) { reserveFn.call(inv, 'test-cart', 'A', 3); }
    const avail = _invCheck(inv, 'A');
    console.log(avail === 7 ? 'PASS' : 'FAIL:' + avail);
  " 2>&1) || true
  [[ "$inv_reserve" == *"PASS"* ]] && score=$((score + 5))

  # Release restores stock (5 pts)
  local inv_release
  inv_release=$(cd "$ws" && node -e "
    $(_resolve_class_js './src/inventory' 'InventoryManager')
    ${_inv_add_js}
    const inv = new InventoryManager();
    _invAdd(inv, 'A', 10);
    const reserveFn = inv.reserve || inv.reserveItem || inv.reserveStock;
    if (reserveFn) { try { reserveFn.call(inv, 'A', 3); } catch(e) { reserveFn.call(inv, 'test-cart', 'A', 3); } }
    const releaseFn = inv.release || inv.releaseItem || inv.releaseStock || inv.unreserve;
    if (!releaseFn) { console.log('NO_RELEASE'); process.exit(); }
    // Try (itemId, qty) then (cartId, itemId, qty)
    try { releaseFn.call(inv, 'A', 3); } catch(e) { releaseFn.call(inv, 'test-cart', 'A', 3); }
    const avail = _invCheck(inv, 'A');
    console.log(avail === 10 ? 'PASS' : 'FAIL:' + avail);
  " 2>&1) || true
  [[ "$inv_release" == *"PASS"* ]] && score=$((score + 5))

  # ── DiscountEngine (20 pts) ──────────────────────────────────────────

  # Helper JS to add a coupon (tries multiple API conventions)
  local _add_coupon_js='function _addCoupon(de, code, type, value, extra) {
    const addFn = de.addCoupon || de.registerCoupon || de.register || de.createCoupon || de.add;
    if (!addFn) throw new Error("NO_ADD");
    // Value normalization: some impls expect percentage as 0-1 (0.10), others as 0-100 (10)
    const valNorm = (type === "percentage" && value > 1) ? value / 100 : value;
    const valOrig = value;
    const minP = (extra && (extra.minPurchase || extra.minimumPurchase || extra.minAmount)) || 0;
    const cfg = {type, value: valOrig, minPurchase:minP, minPurchaseInCents:minP, minimumPurchaseInCents:minP, minPurchaseCents:minP, minimumPurchase:minP, minAmount:minP, ...extra};
    const cfgNorm = {type, value: valNorm, minPurchase:minP, minPurchaseInCents:minP, minimumPurchaseInCents:minP, minPurchaseCents:minP, minimumPurchase:minP, minAmount:minP, ...extra};
    // Conv 1: addCoupon(code, config) — separate code + config
    try { addFn.call(de, code, cfg); return; } catch(e) {
      // Try with normalized value
      try { addFn.call(de, code, cfgNorm); return; } catch(e2) {}
      // Conv 2: addCoupon({code, type, value, ...}) — single object
      try { addFn.call(de, {code, ...cfg}); return; } catch(e3) {}
      try { addFn.call(de, {code, ...cfgNorm}); return; } catch(e4) {}
      throw e;
    }
  }'

  # Helper: apply discount trying (code, amount) and (cartId, code, amount) conventions
  local _apply_disc_js='function _applyDisc(de, code, amount) {
    // Pattern A: apply returns discount directly
    const applyFn = de.apply || de.applyDiscount || de.redeem;
    if (applyFn) {
      try { const r = applyFn.call(de, code, amount); if (r !== undefined) return r; } catch(e) {}
      try { const r = applyFn.call(de, "test-cart", code, amount); if (r !== undefined) return r; } catch(e) {}
    }
    // Pattern B: applyCoupon + calculateDiscount (2-step)
    const applyCpn = de.applyCoupon;
    const calcDisc = de.calculateDiscount;
    if (applyCpn && calcDisc) {
      // Try (code, amount)
      try { applyCpn.call(de, code, amount); const r = calcDisc.call(de, code, amount); return _extractDiscount(r); } catch(e) {}
      // Try (cartId, code, amount)
      try { applyCpn.call(de, "test-cart", code, amount); const r = calcDisc.call(de, "test-cart", amount); return _extractDiscount(r); } catch(e) {}
    }
    // Pattern C: applyCoupon returns discount
    if (applyCpn) {
      try { const r = applyCpn.call(de, code, amount); if (r !== undefined) return _extractDiscount(r); } catch(e) {}
      try { const r = applyCpn.call(de, "test-cart", code, amount); if (r !== undefined) return _extractDiscount(r); } catch(e) {}
    }
    throw new Error("No apply convention worked");
  }
  function _extractDiscount(r) {
    if (typeof r === "number") return r;
    if (r && r.discountCents !== undefined) return r.discountCents;
    if (r && r.discountInCents !== undefined) return r.discountInCents;
    if (r && r.discount !== undefined) return r.discount;
    if (r && r.amount !== undefined) return r.amount;
    if (r && r.value !== undefined) return r.value;
    return r;
  }'

  # Apply percentage coupon (5 pts)
  local disc_pct
  disc_pct=$(cd "$ws" && node -e "
    $(_resolve_class_js './src/discounts' 'DiscountEngine')
    ${_add_coupon_js}
    ${_apply_disc_js}
    const de = new DiscountEngine();
    _addCoupon(de, 'SAVE10', 'percentage', 10, {});
    const result = _applyDisc(de, 'SAVE10', 10000);
    // 10% off 10000 = 1000 discount, or 10% off 100.00 = 10.00
    const discount = typeof result === 'number' ? result :
                     (result && (result.discount || result.amount || result.value || 0));
    const ok = discount === 1000 || Math.abs(discount - 10) < 0.01 ||
               discount === 10000 * 0.9 || discount === 9000;
    console.log(ok ? 'PASS' : 'FAIL:' + discount);
  " 2>&1) || true
  [[ "$disc_pct" == *"PASS"* ]] && score=$((score + 5))

  # Apply fixed amount coupon (5 pts)
  local disc_fixed
  disc_fixed=$(cd "$ws" && node -e "
    $(_resolve_class_js './src/discounts' 'DiscountEngine')
    ${_add_coupon_js}
    ${_apply_disc_js}
    const de = new DiscountEngine();
    _addCoupon(de, 'FLAT500', 'fixed', 500, {});
    const result = _applyDisc(de, 'FLAT500', 10000);
    const discount = typeof result === 'number' ? result :
                     (result && (result.discount || result.amount || result.value || 0));
    // Fixed 500 cents off, or 5.00 dollars off
    const ok = discount === 500 || Math.abs(discount - 5) < 0.01 ||
               discount === 9500 || Math.abs(discount - 95) < 0.01;
    console.log(ok ? 'PASS' : 'FAIL:' + discount);
  " 2>&1) || true
  [[ "$disc_fixed" == *"PASS"* ]] && score=$((score + 5))

  # Reject expired coupon (5 pts)
  local disc_expired
  disc_expired=$(cd "$ws" && node -e "
    $(_resolve_class_js './src/discounts' 'DiscountEngine')
    ${_add_coupon_js}
    ${_apply_disc_js}
    const de = new DiscountEngine();
    const past = new Date('2020-01-01');
    _addCoupon(de, 'OLD', 'percentage', 10, {expiresAt: past, expiry: past, expirationDate: past, expiration: past});
    try {
      const result = _applyDisc(de, 'OLD', 10000);
      const discount = typeof result === 'number' ? result :
                       (result && (result.discount || result.amount || result.value || 0));
      console.log(discount === 0 || result === null || result === false ||
                  (result && result.valid === false) ? 'PASS' : 'FAIL:' + discount);
    } catch(e) {
      console.log('PASS');
    }
  " 2>&1) || true
  [[ "$disc_expired" == *"PASS"* ]] && score=$((score + 5))

  # Minimum purchase check (5 pts)
  local disc_min
  disc_min=$(cd "$ws" && node -e "
    $(_resolve_class_js './src/discounts' 'DiscountEngine')
    ${_add_coupon_js}
    ${_apply_disc_js}
    const de = new DiscountEngine();
    _addCoupon(de, 'BIG', 'percentage', 20, {minPurchase:5000, minimumPurchase:5000, minimumPurchaseInCents:5000, minPurchaseInCents:5000, minPurchaseCents:5000, minAmount:5000});
    try {
      const result = _applyDisc(de, 'BIG', 1000);
      const discount = typeof result === 'number' ? result :
                       (result && (result.discount || result.amount || result.value || 0));
      console.log(discount === 0 || result === null || result === false ||
                  (result && result.valid === false) ? 'PASS' : 'FAIL:' + discount);
    } catch(e) {
      console.log('PASS');
    }
  " 2>&1) || true
  [[ "$disc_min" == *"PASS"* ]] && score=$((score + 5))

  # ── Checkout integration (16 pts) ────────────────────────────────────

  # Full checkout flow produces correct-ish total (8 pts)
  local checkout_flow
  checkout_flow=$(cd "$ws" && node -e "
    let idx;
    try { idx = require('./src/index'); } catch(e) { console.log('IMPORT_FAIL'); process.exit(1); }
    const checkoutFn = idx.checkout || idx.default || (typeof idx === 'function' ? idx : null);
    if (!checkoutFn) { console.log('NO_CHECKOUT'); process.exit(); }

    // Get all exported classes
    const CartCls = idx.Cart || idx.ShoppingCart;
    const InvCls = idx.InventoryManager || idx.Inventory;
    const PriceCls = idx.PricingEngine || idx.Pricing;
    const DiscCls = idx.DiscountEngine || idx.Discounts;

    try {
      let result;

      // Convention 1: checkout({cart: Cart, inventory: InvMgr, pricing: PricingEngine, ...})
      // This is the DX-style full-object pattern
      if (!result && CartCls && InvCls && PriceCls) {
        try {
          const inv = new InvCls();
          // Set up inventory product
          const addProd = inv.addProduct || inv.registerProduct || inv.register;
          const addStck = inv.addStock || inv.add || inv.setStock || inv.restock;
          if (addProd) {
            try { addProd.call(inv, {id:'W1',name:'Widget',priceInCents:1000,price:1000,category:'electronics',stock:100}); } catch(e) {
              try { addProd.call(inv, 'W1', 'Widget', 1000, 'electronics', 100); } catch(e2) {
                try { addProd.call(inv, 'W1', 100); } catch(e3) {}
              }
            }
          }
          if (addStck) { try { addStck.call(inv, 'W1', 100); } catch(e) {} }
          // Try both Cart(inv) and Cart({inventory: inv})
          let cart;
          try { cart = new CartCls(inv); } catch(e) {}
          if (!cart || (cart._inventory && typeof cart._inventory.reserve !== 'function')) { try { cart = new CartCls({inventory: inv}); } catch(e) {} }
          if (!cart) { try { cart = new CartCls({inventory: inv}); } catch(e) { cart = new CartCls(); } }
          // addItem with qty both in object and as second arg (covers all patterns)
          try { cart.addItem({id:'W1',name:'Widget',price:1000,priceInCents:1000,priceCents:1000,quantity:2,category:'electronics'},2); } catch(e1) {
            try { cart.addItem('W1','Widget',1000,2,'electronics'); } catch(e2) {
              try { cart.addItem('W1',2); } catch(e3) {}
            }
          }
          const pe = new PriceCls();
          const de = DiscCls ? new DiscCls() : null;
          // Try multiple checkout param conventions
          try { result = checkoutFn({cart, pricingEngine: pe, discountEngine: de, inventory: inv, pricing: pe}); } catch(e) {
            try { result = checkoutFn({cart, pricingEngine: pe, inventory: inv}); } catch(e2) {
              try { result = checkoutFn({cart, pricing: pe, inventory: inv}); } catch(e3) {
                result = checkoutFn({cart, inventory: inv, pricing: pe, pricingEngine: pe, discountEngine: de});
              }
            }
          }
        } catch(e) { /* try next convention */ }
      }

      // Convention 2: checkout(cartItems) — simple array
      if (!result) {
        try {
          const cartItems = [{id:'W1', name:'Widget', price:1000, priceInCents:1000, category:'electronics', quantity:2}];
          result = checkoutFn(cartItems);
        } catch(e) {}
      }

      // Convention 3: checkout({items: cartItems})
      if (!result) {
        try {
          const cartItems = [{id:'W1', name:'Widget', price:1000, priceInCents:1000, category:'electronics', quantity:2}];
          result = checkoutFn({items: cartItems});
        } catch(e) {}
      }

      if (!result) { console.log('NO_RESULT'); process.exit(); }

      // Check the result has expected shape
      const hasTotal = result.total !== undefined || result.grandTotal !== undefined ||
                       result.totalInCents !== undefined || result.grandTotalInCents !== undefined ||
                       result.totalCents !== undefined || result.grandTotalCents !== undefined;
      console.log(hasTotal ? 'PASS' : 'FAIL:' + JSON.stringify(result).slice(0, 200));
    } catch(e) {
      console.log('ERROR:' + e.message);
    }
  " 2>&1) || true
  [[ "$checkout_flow" == *"PASS"* ]] && score=$((score + 8))

  # Checkout: out of stock returns error (5 pts)
  local checkout_oos
  checkout_oos=$(cd "$ws" && node -e "
    let idx;
    try { idx = require('./src/index'); } catch(e) { console.log('IMPORT_FAIL'); process.exit(1); }
    const checkoutFn = idx.checkout || idx.default || (typeof idx === 'function' ? idx : null);
    if (!checkoutFn) { console.log('NO_CHECKOUT'); process.exit(); }

    const CartCls = idx.Cart || idx.ShoppingCart;
    const InvCls = idx.InventoryManager || idx.Inventory;
    const PriceCls = idx.PricingEngine || idx.Pricing;
    const DiscCls = idx.DiscountEngine || idx.Discounts;

    try {
      // Convention 1: full-object pattern — cart item has no stock set up
      if (CartCls && InvCls && PriceCls) {
        try {
          const inv = new InvCls();
          // Do NOT add stock — this should fail
          let cart;
          try { cart = new CartCls(inv); } catch(e) {}
          if (!cart || (cart._inventory && typeof cart._inventory.reserve !== 'function')) { try { cart = new CartCls({inventory: inv}); } catch(e) {} }
          if (!cart) { try { cart = new CartCls({inventory: inv}); } catch(e) { cart = new CartCls(); } }
          try {
            try { cart.addItem({id:'NOSTOCK',name:'Ghost',price:1000,priceInCents:1000,priceCents:1000,quantity:999,category:'electronics'},999); } catch(e1) {
              try { cart.addItem('NOSTOCK','Ghost',1000,999,'electronics'); } catch(e2) {
                // If addItem itself fails because of no stock, that's also correct
                console.log('PASS'); process.exit();
              }
            }
          } catch(e) {
            console.log('PASS'); process.exit();
          }
          const pe = new PriceCls();
          const de = DiscCls ? new DiscCls() : null;
          let result;
          try { result = checkoutFn({cart, pricingEngine: pe, discountEngine: de, inventory: inv}); } catch(e) {
            try { result = checkoutFn({cart, pricing: pe, inventory: inv}); } catch(e2) {
              console.log('PASS'); process.exit();
            }
          }
          if (result && (result.error || result.success === false)) { console.log('PASS'); }
          else { console.log('FAIL'); }
          process.exit();
        } catch(e) { console.log('PASS'); process.exit(); }
      }
      // Convention 2: simple array
      const cartItems = [{id:'NOSTOCK', name:'Ghost', price:1000, category:'electronics', quantity:999}];
      let result;
      try { result = checkoutFn(cartItems); } catch(e) { console.log('PASS'); process.exit(); }
      try { result = checkoutFn({items: cartItems}); } catch(e) { console.log('PASS'); process.exit(); }
      if (result && (result.error || result.success === false || result.status === 'error')) {
        console.log('PASS');
      } else { console.log('FAIL'); }
    } catch(e) {
      console.log('PASS');
    }
  " 2>&1) || true
  [[ "$checkout_oos" == *"PASS"* ]] && score=$((score + 5))

  # One coupon per cart enforced (3 pts)
  local one_coupon
  one_coupon=$(cd "$ws" && node -e "
    $(_resolve_class_js './src/discounts' 'DiscountEngine')
    ${_add_coupon_js}
    ${_apply_disc_js}
    const de = new DiscountEngine();
    _addCoupon(de, 'A10', 'percentage', 10, {});
    _addCoupon(de, 'B20', 'percentage', 20, {});

    try {
      // First coupon
      _applyDisc(de, 'A10', 10000);
      // Second coupon to same cart — should fail or overwrite
      try {
        const r2 = _applyDisc(de, 'B20', 10000);
        const hasTracker = de.appliedCoupons || de._applied || de.usedCoupons;
        if (hasTracker) {
          const count = hasTracker.size || Object.keys(hasTracker).length || (Array.isArray(hasTracker) ? hasTracker.length : 0);
          console.log(count <= 1 ? 'PASS' : 'FAIL:' + count);
        } else {
          console.log('PARTIAL');
        }
      } catch(e) {
        // Error thrown for second coupon = correct behavior
        console.log('PASS');
      }
    } catch(e) {
      console.log('ERROR:' + e.message);
    }
  " 2>&1) || true
  [[ "$one_coupon" == *"PASS"* ]] && score=$((score + 3))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  # ── Test files exist (10 pts) ────────────────────────────────────────
  local test_files
  test_files=$(find "$ws" -maxdepth 4 \( \
    -name "*.test.*" -o -name "*.spec.*" -o \
    -name "test.js" -o -name "test_*.js" -o -name "tests.js" \
  \) ! -path "*/node_modules/*" 2>/dev/null)
  local test_dir_files
  test_dir_files=$(find "$ws" -maxdepth 4 \( -path "*/__tests__/*.js" -o -path "*/test/*.js" -o -path "*/tests/*.js" \) 2>/dev/null | grep -v node_modules) || true
  if [[ -n "$test_dir_files" ]]; then
    test_files=$(printf '%s\n%s' "$test_files" "$test_dir_files" | sort -u | grep -v '^$')
  fi
  local test_count
  test_count=$(echo "$test_files" | grep -c "." 2>/dev/null) || true
  test_count=${test_count:-0}
  [[ $test_count -gt 0 ]] && score=$((score + 10))

  # ── Tests pass (20 pts) ──────────────────────────────────────────────
  if [[ -f "$ws/package.json" ]]; then
    local test_output
    test_output=$(cd "$ws" && npm test 2>&1) || true
    local test_pass_match
    test_pass_match=$(echo "$test_output" | tail -30 | grep -ciE 'pass|ok|success|tests? (passed|complete)' 2>/dev/null) || true
    local test_fail_match
    test_fail_match=$(echo "$test_output" | tail -30 | grep -ciE 'fail|FAIL|✗|✘' 2>/dev/null) || true
    if [[ "$test_pass_match" -gt 0 && "$test_fail_match" -eq 0 ]]; then
      score=$((score + 20))
    elif [[ "$test_pass_match" -gt 0 ]]; then
      score=$((score + 10))  # some pass but some fail
    fi
  fi

  # ── Tests for EACH module separately (20 pts: 5 each) ───────────────
  if [[ -n "$test_files" ]]; then
    for mod in "cart" "pricing" "inventory" "discount"; do
      local mod_tested
      mod_tested=$(echo "$test_files" | xargs grep -cl "$mod" 2>/dev/null | wc -l | tr -d ' ') || true
      [[ "$mod_tested" -gt 0 ]] && score=$((score + 5))
    done
  fi

  # ── Integration tests: checkout flow (10 pts) ───────────────────────
  if [[ -n "$test_files" ]]; then
    local integ_match
    integ_match=$(echo "$test_files" | xargs grep -clE "checkout|integration|e2e|end.to.end|full.flow" 2>/dev/null | wc -l | tr -d ' ') || true
    [[ "$integ_match" -gt 0 ]] && score=$((score + 10))
  fi

  # ── Edge case tests (10 pts) ─────────────────────────────────────────
  if [[ -n "$test_files" ]]; then
    local edge_patterns=0
    local e1 e2 e3
    e1=$(echo "$test_files" | xargs grep -clE "out.of.stock|insufficient|no.stock|not.available" 2>/dev/null | wc -l | tr -d ' ') || true
    e2=$(echo "$test_files" | xargs grep -clE "expired|expir|invalid.coupon" 2>/dev/null | wc -l | tr -d ' ') || true
    e3=$(echo "$test_files" | xargs grep -clE "negative|zero|invalid.qty|invalid.quantity" 2>/dev/null | wc -l | tr -d ' ') || true
    [[ "$e1" -gt 0 ]] && edge_patterns=$((edge_patterns + 1))
    [[ "$e2" -gt 0 ]] && edge_patterns=$((edge_patterns + 1))
    [[ "$e3" -gt 0 ]] && edge_patterns=$((edge_patterns + 1))
    [[ $edge_patterns -ge 1 ]] && score=$((score + 3))
    [[ $edge_patterns -ge 2 ]] && score=$((score + 4))
    [[ $edge_patterns -ge 3 ]] && score=$((score + 3))
  fi

  # ── Concurrent test: two carts, last item (10 pts) ──────────────────
  if [[ -n "$test_files" ]]; then
    local conc_match
    conc_match=$(echo "$test_files" | xargs grep -clE "concurrent|parallel|race|competing|simultaneous|Promise\.all|two cart" 2>/dev/null | wc -l | tr -d ' ') || true
    [[ "$conc_match" -gt 0 ]] && score=$((score + 10))
  fi

  # ── Test count thresholds (15 pts) ──────────────────────────────────
  if [[ -n "$test_files" ]]; then
    local total_tests
    total_tests=$(echo "$test_files" | xargs grep -cE "^\s*(it|test)\(" 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
    total_tests=${total_tests:-0}
    [[ $total_tests -gt 15 ]] && score=$((score + 5))
    [[ $total_tests -gt 25 ]] && score=$((score + 5))
    [[ $total_tests -gt 35 ]] && score=$((score + 5))
  fi

  # ── Test isolation: beforeEach/afterEach (5 pts) ─────────────────────
  if [[ -n "$test_files" ]]; then
    local isolation_match
    isolation_match=$(echo "$test_files" | xargs grep -clE "beforeEach|afterEach|beforeAll|afterAll|setUp|tearDown" 2>/dev/null | wc -l | tr -d ' ') || true
    [[ "$isolation_match" -gt 0 ]] && score=$((score + 5))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=0

  local src_files
  src_files=$(find "$ws/src" -name "*.js" ! -path "*/node_modules/*" 2>/dev/null)
  [[ -z "$src_files" ]] && { echo "0"; return; }

  # ── Each module uses proper exports (10 pts) ─────────────────────────
  local export_count=0
  for f in "cart.js" "pricing.js" "inventory.js" "discounts.js" "index.js"; do
    if [[ -f "$ws/src/$f" ]]; then
      local has_export
      has_export=$(grep -cE "module\.exports|exports\." "$ws/src/$f" 2>/dev/null) || true
      [[ "$has_export" -gt 0 ]] && export_count=$((export_count + 1))
    fi
  done
  [[ $export_count -ge 3 ]] && score=$((score + 5))
  [[ $export_count -ge 5 ]] && score=$((score + 5))

  # ── Modules can be imported independently (10 pts) ───────────────────
  local import_count=0
  for mod_pair in "cart:Cart" "pricing:PricingEngine" "inventory:InventoryManager" "discounts:DiscountEngine"; do
    local mod_file="${mod_pair%%:*}"
    local mod_class="${mod_pair##*:}"
    if [[ -f "$ws/src/${mod_file}.js" ]]; then
      local import_ok
      import_ok=$(_try_require "$ws" "./src/$mod_file" "$mod_class" 2>/dev/null) || true
      [[ "$import_ok" == "ok" ]] && import_count=$((import_count + 1))
    fi
  done
  [[ $import_count -ge 2 ]] && score=$((score + 5))
  [[ $import_count -ge 4 ]] && score=$((score + 5))

  # ── Input validation on public methods (10 pts) ──────────────────────
  local val_count
  val_count=$(echo "$src_files" | xargs grep -cE "if.*!|throw new|typeof.*===|instanceof|isNaN|Number\.isFinite|!= null|!== null|=== undefined|!== undefined" 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$val_count" -ge 3 ]] && score=$((score + 5))
  [[ "$val_count" -ge 8 ]] && score=$((score + 5))

  # ── Error handling: try/catch or throw (10 pts) ──────────────────────
  local err_count
  err_count=$(echo "$src_files" | xargs grep -cE "try \{|catch.*\{|throw new|throw " 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$err_count" -ge 3 ]] && score=$((score + 5))
  [[ "$err_count" -ge 6 ]] && score=$((score + 5))

  # ── No circular dependencies (10 pts) ────────────────────────────────
  # Check that cart/pricing/inventory/discounts don't require each other in cycles
  local circ_detected=false
  # cart should not require pricing/inventory/discounts
  if [[ -f "$ws/src/cart.js" ]]; then
    local cart_deps
    cart_deps=$(grep -cE "require.*\./pricing|require.*\./inventory|require.*\./discount" "$ws/src/cart.js" 2>/dev/null) || true
    [[ "$cart_deps" -gt 0 ]] && circ_detected=true
  fi
  # pricing should not require cart
  if [[ -f "$ws/src/pricing.js" ]]; then
    local price_deps
    price_deps=$(grep -cE "require.*\./cart" "$ws/src/pricing.js" 2>/dev/null) || true
    [[ "$price_deps" -gt 0 ]] && circ_detected=true
  fi
  $circ_detected || score=$((score + 10))

  # ── Uses const/let, no var (5 pts) ──────────────────────────────────
  local var_count
  var_count=$(echo "$src_files" | xargs grep -cE "^\s*var " 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$var_count" -eq 0 ]] && score=$((score + 5))

  # ── No console.log in source (5 pts) ────────────────────────────────
  local console_count
  console_count=$(echo "$src_files" | xargs grep -cE "console\.(log|info|warn|debug)" 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$console_count" -eq 0 ]] && score=$((score + 5))

  # ── Currency precision: cents/integer or toFixed(2) (10 pts) ─────────
  local precision_patterns
  precision_patterns=$(echo "$src_files" | xargs grep -cE "Math\.round|Math\.floor|toFixed\(2\)|cents|\.round\(|integer|amount \* 100|/ 100" 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$precision_patterns" -ge 1 ]] && score=$((score + 5))
  [[ "$precision_patterns" -ge 3 ]] && score=$((score + 5))

  # ── Inventory thread safety: reserve is atomic/checked (10 pts) ──────
  # Check if reserve checks available stock before decrementing
  if [[ -f "$ws/src/inventory.js" ]]; then
    local atomic_check
    atomic_check=$(grep -cE "if.*stock|if.*available|if.*quantity|insufficient|not enough|out of stock" "$ws/src/inventory.js" 2>/dev/null) || true
    [[ "$atomic_check" -ge 1 ]] && score=$((score + 5))
    # Check for throw/error on insufficient stock
    local throw_on_oos
    throw_on_oos=$(grep -cE "throw.*stock|throw.*inventory|throw.*available|throw.*insufficient" "$ws/src/inventory.js" 2>/dev/null) || true
    [[ "$throw_on_oos" -ge 1 ]] && score=$((score + 5))
  fi

  # ── JSDoc or clear function signatures (5 pts) ──────────────────────
  local jsdoc_count
  jsdoc_count=$(echo "$src_files" | xargs grep -cE "/\*\*|@param|@returns|@throws" 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$jsdoc_count" -ge 5 ]] && score=$((score + 5))

  # ── Clean separation: no business logic in index.js (5 pts) ──────────
  if [[ -f "$ws/src/index.js" ]]; then
    local index_lines
    index_lines=$(wc -l < "$ws/src/index.js" 2>/dev/null | tr -d ' ') || true
    # index.js should be relatively short — just orchestration
    # If it's under 100 lines and has require() calls, it's likely orchestration only
    local index_requires
    index_requires=$(grep -cE "require\(" "$ws/src/index.js" 2>/dev/null) || true
    if [[ "$index_lines" -le 120 && "$index_requires" -ge 2 ]]; then
      score=$((score + 5))
    fi
  fi

  # ── Configurable tax rates, not hardcoded (10 pts) ───────────────────
  if [[ -f "$ws/src/pricing.js" ]]; then
    local config_tax
    config_tax=$(grep -cE "constructor.*tax|taxRates.*=.*\{|config|options|this\.(tax|rates)" "$ws/src/pricing.js" 2>/dev/null) || true
    [[ "$config_tax" -ge 1 ]] && score=$((score + 5))
    # Check if tax rates are passed as parameter or set via method (not just const at top)
    local tax_param
    tax_param=$(grep -cE "taxRates|tax_rates|rates|setTaxRate|configure" "$ws/src/pricing.js" 2>/dev/null) || true
    [[ "$tax_param" -ge 2 ]] && score=$((score + 5))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

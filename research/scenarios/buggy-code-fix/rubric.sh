#!/usr/bin/env bash
# Rubric for: buggy-code-fix
# HARDENED v2: target ~60-75 for typical implementations.
# Tests that DK can find and fix all 5 bugs, write regression tests,
# and produce clean, well-structured code.

rubric_correctness() {
  local ws="$1"
  local score=0

  [[ -f "$ws/src/cart.js" ]] || [[ -f "$ws/cart.js" ]] && score=$((score + 3))
  [[ -f "$ws/package.json" ]] && score=$((score + 2))

  (cd "$ws" && npm install --silent >/dev/null 2>&1) || true

  local cart_file="$ws/src/cart.js"
  [[ -f "$cart_file" ]] || cart_file="$ws/cart.js"
  [[ -f "$cart_file" ]] || { echo "$score"; return; }

  # Bug 1: negative price/quantity validation
  local neg_test
  neg_test=$(cd "$ws" && node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
let passed = 0;
try { c.addItem('A', -5, 1); } catch(e) { passed++; }
try { c.addItem('A', 10, -1); } catch(e) { passed++; }
try { c.addItem('A', 0, 1); } catch(e) { passed++; }
console.log(passed >= 2 ? 'PASS' : 'FAIL:' + passed);
" 2>&1) || true
  [[ "$neg_test" == *"PASS"* ]] && score=$((score + 12))

  # Bug 2: removeItem works correctly (filters, doesn't assign)
  local rm_test
  rm_test=$(cd "$ws" && node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
c.addItem('A', 10, 1);
c.addItem('B', 20, 1);
c.addItem('C', 30, 1);
c.removeItem('B');
const ok = c.items.length === 2 && c.items.every(i => i.name !== 'B');
console.log(ok ? 'PASS' : 'FAIL');
" 2>&1) || true
  [[ "$rm_test" == *"PASS"* ]] && score=$((score + 12))

  # Bug 3: getTotal has no off-by-one
  local total_test
  total_test=$(cd "$ws" && node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
c.addItem('A', 10, 2);
c.addItem('B', 5, 3);
c.addItem('C', 1, 1);
const total = c.getTotal();
console.log(total === 36 ? 'PASS' : 'FAIL:' + total);
" 2>&1) || true
  [[ "$total_test" == *"PASS"* ]] && score=$((score + 12))

  # Bug 4: discount subtracts (not adds) and applies percentage correctly
  local disc_test
  disc_test=$(cd "$ws" && node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
c.addItem('A', 100, 1);
c.applyDiscount(25);
const total = c.getTotal();
console.log(total === 75 ? 'PASS' : 'FAIL:' + total);
" 2>&1) || true
  [[ "$disc_test" == *"PASS"* ]] && score=$((score + 12))

  # Bug 5: discount validates range (0-100)
  local disc_val_test
  disc_val_test=$(cd "$ws" && node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
let thrown = 0;
try { c.applyDiscount(150); } catch(e) { thrown++; }
try { c.applyDiscount(-10); } catch(e) { thrown++; }
try { c.applyDiscount(101); } catch(e) { thrown++; }
console.log(thrown >= 3 ? 'PASS' : 'FAIL:' + thrown);
" 2>&1) || true
  [[ "$disc_val_test" == *"PASS"* ]] && score=$((score + 12))

  # Harder: Multiple operations chain correctly
  local chain_test
  chain_test=$(cd "$ws" && node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
c.addItem('A', 100, 2);  // 200
c.addItem('B', 50, 1);   // 50
c.removeItem('A');        // -200
c.addItem('C', 30, 3);   // 90
c.applyDiscount(10);      // -10%
// Expected: (50 + 90) * 0.9 = 126
const total = c.getTotal();
console.log(total === 126 ? 'PASS' : 'FAIL:' + total);
" 2>&1) || true
  [[ "$chain_test" == *"PASS"* ]] && score=$((score + 10))

  # Harder: Empty cart total is 0
  local empty_test
  empty_test=$(cd "$ws" && node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
console.log(c.getTotal() === 0 ? 'PASS' : 'FAIL');
" 2>&1) || true
  [[ "$empty_test" == *"PASS"* ]] && score=$((score + 5))

  # Harder: Discount on empty cart doesn't crash
  local disc_empty
  disc_empty=$(cd "$ws" && node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
c.applyDiscount(10);
console.log(c.getTotal() === 0 ? 'PASS' : 'FAIL');
" 2>&1) || true
  [[ "$disc_empty" == *"PASS"* ]] && score=$((score + 5))

  # Harder: Input type validation (string name, numeric price/qty)
  local type_test
  type_test=$(cd "$ws" && node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
let thrown = 0;
try { c.addItem('', 10, 1); } catch(e) { thrown++; }
try { c.addItem('A', 'abc', 1); } catch(e) { thrown++; }
try { c.addItem('A', 10, 1.5); } catch(e) { thrown++; }
console.log(thrown >= 2 ? 'PASS' : 'PARTIAL:' + thrown);
" 2>&1) || true
  [[ "$type_test" == *"PASS"* ]] && score=$((score + 10))

  # Harder: Discount of exactly 0 and exactly 100 work
  local edge_disc
  edge_disc=$(cd "$ws" && node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
c.addItem('A', 100, 1);
c.applyDiscount(0);
const t1 = c.getTotal();
const c2 = new Cart();
c2.addItem('A', 100, 1);
c2.applyDiscount(100);
const t2 = c2.getTotal();
console.log(t1 === 100 && t2 === 0 ? 'PASS' : 'FAIL:' + t1 + ',' + t2);
" 2>&1) || true
  [[ "$edge_disc" == *"PASS"* ]] && score=$((score + 5))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  local test_files
  test_files=$(find "$ws" -maxdepth 3 \( \
    -name "*.test.*" -o -name "*.spec.*" -o \
    -name "test.js" -o -name "test_*.js" -o -name "tests.js" \
  \) ! -path "*/node_modules/*" 2>/dev/null)
  local _test_dir_files
  _test_dir_files=$(find "$ws" -maxdepth 4 \( -path "*/__tests__/*.js" -o -path "*/test/*.js" -o -path "*/tests/*.js" \) 2>/dev/null | grep -v node_modules) || true
  [[ -n "$_test_dir_files" ]] && test_files=$(printf '%s\n%s' "$test_files" "$_test_dir_files" | sort -u | grep -v '^$')
  local test_count
  test_count=$(echo "$test_files" | grep -c . 2>/dev/null) || test_count=0
  [[ $test_count -gt 0 ]] && score=$((score + 10))

  # Tests pass
  local test_output
  test_output=$(cd "$ws" && npm test 2>&1 | tail -30) || true
  if echo "$test_output" | grep -qiE "pass|✓|ok|success"; then
    score=$((score + 20))
  fi

  # Count individual test cases
  local case_count=0
  if [[ -n "$test_files" ]]; then
    case_count=$(echo "$test_files" | xargs grep -cE "it\(|test\(|describe\(" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}') || case_count=0
  fi
  [[ $case_count -gt 5 ]] && score=$((score + 10))
  [[ $case_count -gt 10 ]] && score=$((score + 10))

  # Tests cover each of the 5 bugs
  local bugs_tested=0
  if [[ -n "$test_files" ]]; then
    for pattern in "negativ|invalid.*price|invalid.*quantity|price.*less|quantity.*less" \
                   "remove|filter|delete.*item" \
                   "total|getTotal|sum|off.by.one|boundary" \
                   "discount.*subtract|discount.*correct|discount.*reduce|apply.*discount" \
                   "discount.*range|discount.*valid|discount.*100|discount.*0|discount.*bound"; do
      if echo "$test_files" | xargs grep -qlEi "$pattern" 2>/dev/null; then
        bugs_tested=$((bugs_tested + 1))
      fi
    done
  fi
  score=$((score + bugs_tested * 6))

  # Tests verify error cases (try/catch, throws, expect().toThrow)
  local error_test_count=0
  if [[ -n "$test_files" ]]; then
    error_test_count=$(echo "$test_files" | xargs grep -cE "toThrow|throw|expect.*Error|reject|catch" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}') || error_test_count=0
  fi
  [[ $error_test_count -ge 3 ]] && score=$((score + 5))

  # Tests have descriptive names (not just "test 1", "test 2")
  local descriptive=0
  if [[ -n "$test_files" ]]; then
    if echo "$test_files" | xargs grep -qlEi "should|when|given|invalid|negative|empty|error" 2>/dev/null; then
      descriptive=1
    fi
  fi
  [[ $descriptive -eq 1 ]] && score=$((score + 5))

  # HARDER: Test isolation — tests should not depend on execution order (7 pts)
  # Check for beforeEach/afterEach/beforeAll or fresh Cart instances per test
  local has_isolation=0
  if [[ -n "$test_files" ]]; then
    # Check for setup/teardown hooks
    echo "$test_files" | xargs grep -qlE "beforeEach|afterEach|beforeAll|afterAll" 2>/dev/null && has_isolation=$((has_isolation + 1))
    # Check for new Cart() inside individual tests (not just top-level)
    local cart_in_tests
    cart_in_tests=$(echo "$test_files" | xargs grep -cE "new (ShoppingCart|Cart)" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}') || cart_in_tests=0
    # If there are multiple Cart instantiations (at least as many as test blocks), tests are isolated
    [[ $cart_in_tests -ge 4 ]] && has_isolation=$((has_isolation + 1))
  fi
  [[ $has_isolation -ge 1 ]] && score=$((score + 7))

  # HARDER: Mutation testing — for each of the 5 bugs, temporarily re-introduce the bug
  # and check that at least one test fails. This proves the tests ACTUALLY catch the bugs. (15 pts)
  local cart_file="$ws/src/cart.js"
  [[ -f "$cart_file" ]] || cart_file="$ws/cart.js"
  if [[ -f "$cart_file" ]]; then
    local mutations_caught=0

    # Save original file
    local cart_backup
    cart_backup=$(cat "$cart_file")

    # Mutation 1: Remove negative price/quantity validation
    # Re-introduce bug: make addItem accept negative price without throwing
    (cd "$ws" && node -e "
const fs = require('fs');
const src = fs.readFileSync('$cart_file', 'utf8');
// Remove validation: replace throw statements related to price/quantity with nothing
// Strategy: wrap the addItem body to skip validation
const mutated = src.replace(
  /addItem\s*\([^)]*\)\s*\{[^}]*?(if\s*\([^)]*(?:price|quantity)[^)]*(?:<=?\s*0|<\s*0|negative)[^}]*throw[^}]*\})/gs,
  (match, validation) => match.replace(validation, '/* MUTANT: validation removed */')
);
// If regex didn't match, try simpler approach: just comment out first throw in addItem
if (mutated === src) {
  const lines = src.split('\n');
  let inAddItem = false;
  let mutated2 = [];
  let commented = false;
  for (const line of lines) {
    if (line.match(/addItem\s*\(/)) inAddItem = true;
    if (inAddItem && !commented && line.match(/throw/)) {
      mutated2.push('// MUTANT: ' + line);
      commented = true;
    } else {
      mutated2.push(line);
    }
    if (inAddItem && line.match(/^\s*\}/)) inAddItem = false;
  }
  fs.writeFileSync('$cart_file', mutated2.join('\n'));
} else {
  fs.writeFileSync('$cart_file', mutated);
}
" >/dev/null 2>&1) || true
    local mut1_result
    mut1_result=$(cd "$ws" && npm test 2>&1 | tail -20) || true
    if echo "$mut1_result" | grep -qiE "fail|FAIL|error|Error|✕|✗"; then
      mutations_caught=$((mutations_caught + 1))
    fi
    # Restore original
    printf '%s' "$cart_backup" > "$cart_file"

    # Mutation 2: Break removeItem — use = instead of !== in filter
    local mutant2
    mutant2=$(cd "$ws" && node -e "
const fs = require('fs');
const src = fs.readFileSync('$cart_file', 'utf8');
// Find the filter in removeItem and break the comparison
const mutated = src.replace(
  /(removeItem[^}]*filter\s*\([^)]*\)\s*=>\s*[^.]*\.name\s*)(!==?|===?)/,
  '\$1='
);
if (mutated !== src) {
  fs.writeFileSync('$cart_file', mutated);
  console.log('MUTATED');
} else {
  // Try another pattern: i.name !== name -> i.name = name
  const m2 = src.replace(/(\.name\s*)(!==?\s*name)/, '\$1= name');
  if (m2 !== src) {
    fs.writeFileSync('$cart_file', m2);
    console.log('MUTATED');
  } else {
    console.log('NO_MATCH');
  }
}
" 2>&1) || true
    if [[ "$mutant2" == *"MUTATED"* ]]; then
      local mut2_result
      mut2_result=$(cd "$ws" && npm test 2>&1 | tail -20) || true
      if echo "$mut2_result" | grep -qiE "fail|FAIL|error|Error|✕|✗"; then
        mutations_caught=$((mutations_caught + 1))
      fi
    fi
    printf '%s' "$cart_backup" > "$cart_file"

    # Mutation 3: Break getTotal — introduce off-by-one (change < to <=)
    local mutant3
    mutant3=$(cd "$ws" && node -e "
const fs = require('fs');
const src = fs.readFileSync('$cart_file', 'utf8');
// Change i < this.items.length to i <= this.items.length, or break reduce
const mutated = src.replace(
  /(for\s*\([^;]*;\s*\w+\s*)<(\s*this\.items\.length)/,
  '\$1<=\$2'
);
if (mutated !== src) {
  fs.writeFileSync('$cart_file', mutated);
  console.log('MUTATED');
} else {
  // Try breaking reduce: change accumulator logic
  const m2 = src.replace(/(reduce\s*\(\s*\([^,]*,\s*[^)]*\)\s*=>\s*[^+]*)\+/, '\$1-');
  if (m2 !== src) {
    fs.writeFileSync('$cart_file', m2);
    console.log('MUTATED');
  } else {
    console.log('NO_MATCH');
  }
}
" 2>&1) || true
    if [[ "$mutant3" == *"MUTATED"* ]]; then
      local mut3_result
      mut3_result=$(cd "$ws" && npm test 2>&1 | tail -20) || true
      if echo "$mut3_result" | grep -qiE "fail|FAIL|error|Error|✕|✗"; then
        mutations_caught=$((mutations_caught + 1))
      fi
    fi
    printf '%s' "$cart_backup" > "$cart_file"

    # Mutation 4: Break discount — change subtract to add (1 - discount/100 -> 1 + discount/100)
    local mutant4
    mutant4=$(cd "$ws" && node -e "
const fs = require('fs');
const src = fs.readFileSync('$cart_file', 'utf8');
// Change (1 - this.discount / 100) to (1 + this.discount / 100) or similar
let mutated = src.replace(/(1\s*)-(\s*(?:this\.)?discount\s*\/\s*100)/, '\$1+\$2');
if (mutated === src) {
  // Try: total * (100 - discount) / 100 -> total * (100 + discount) / 100
  mutated = src.replace(/(100\s*)-(\s*(?:this\.)?discount)/, '\$1+\$2');
}
if (mutated === src) {
  // Try: total - (total * discount / 100) -> total + (total * discount / 100)
  mutated = src.replace(/(total\s*)-(\s*\(?total)/, '\$1+\$2');
}
if (mutated !== src) {
  fs.writeFileSync('$cart_file', mutated);
  console.log('MUTATED');
} else {
  console.log('NO_MATCH');
}
" 2>&1) || true
    if [[ "$mutant4" == *"MUTATED"* ]]; then
      local mut4_result
      mut4_result=$(cd "$ws" && npm test 2>&1 | tail -20) || true
      if echo "$mut4_result" | grep -qiE "fail|FAIL|error|Error|✕|✗"; then
        mutations_caught=$((mutations_caught + 1))
      fi
    fi
    printf '%s' "$cart_backup" > "$cart_file"

    # Mutation 5: Remove discount range validation
    local mutant5
    mutant5=$(cd "$ws" && node -e "
const fs = require('fs');
const src = fs.readFileSync('$cart_file', 'utf8');
// Remove the throw in applyDiscount that validates range
const lines = src.split('\n');
let inApply = false;
let mutated = [];
let commented = false;
for (const line of lines) {
  if (line.match(/applyDiscount\s*\(/)) inApply = true;
  if (inApply && !commented && line.match(/throw/)) {
    mutated.push('// MUTANT: ' + line);
    // Also comment out the if-line before it if it's a one-line-if pattern
    commented = true;
  } else {
    mutated.push(line);
  }
  // Reset after closing brace (rough heuristic)
  if (inApply && commented && line.match(/^\s*\}/) && !line.match(/if|else/)) inApply = false;
}
if (commented) {
  fs.writeFileSync('$cart_file', mutated.join('\n'));
  console.log('MUTATED');
} else {
  // Try removing if blocks with throw
  const m2 = src.replace(/(applyDiscount[^}]*?)(if\s*\([^)]*(?:percent|discount)[^)]*\)\s*\{[^}]*throw[^}]*\})/gs,
    (match, before, ifBlock) => before + '/* MUTANT */'
  );
  if (m2 !== src) {
    fs.writeFileSync('$cart_file', m2);
    console.log('MUTATED');
  } else {
    console.log('NO_MATCH');
  }
}
" 2>&1) || true
    if [[ "$mutant5" == *"MUTATED"* ]]; then
      local mut5_result
      mut5_result=$(cd "$ws" && npm test 2>&1 | tail -20) || true
      if echo "$mut5_result" | grep -qiE "fail|FAIL|error|Error|✕|✗"; then
        mutations_caught=$((mutations_caught + 1))
      fi
    fi
    printf '%s' "$cart_backup" > "$cart_file"

    # Award points: 3 pts per mutation caught (max 15 pts for 5 mutations)
    score=$((score + mutations_caught * 3))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=0

  local cart_file="$ws/src/cart.js"
  [[ -f "$cart_file" ]] || cart_file="$ws/cart.js"
  [[ -f "$cart_file" ]] || { echo "0"; return; }

  # Has comprehensive input validation
  if grep -qE "throw|Error|typeof|isNaN" "$cart_file" 2>/dev/null; then
    score=$((score + 15))
  fi

  # Validates ALL method inputs (not just addItem)
  local methods_validated=0
  if grep -qE "addItem.*throw|addItem.*Error|if.*name|if.*price|if.*quantity" "$cart_file" 2>/dev/null; then
    methods_validated=$((methods_validated + 1))
  fi
  if grep -qE "removeItem.*throw|removeItem.*if|removeItem.*!|removeItem.*Error" "$cart_file" 2>/dev/null || \
     grep -A5 "removeItem" "$cart_file" 2>/dev/null | grep -qE "throw|if.*!|Error"; then
    methods_validated=$((methods_validated + 1))
  fi
  if grep -A5 "applyDiscount" "$cart_file" 2>/dev/null | grep -qE "throw|if.*!|Error|<\s*0|>\s*100"; then
    methods_validated=$((methods_validated + 1))
  fi
  [[ $methods_validated -ge 2 ]] && score=$((score + 15))

  # Edge case handling
  local crash_test
  crash_test=$(cd "$ws" && node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
let ok = true;
// Empty cart operations
try { c.getTotal(); } catch(e) { ok = false; }
try { c.removeItem('nonexistent'); } catch(e) { /* acceptable */ }
// Rapid add/remove
c.addItem('X', 1, 1);
c.addItem('X', 2, 1);  // Same name, different price
c.removeItem('X');
try { c.getTotal(); } catch(e) { ok = false; }
console.log(ok ? 'PASS' : 'FAIL');
" 2>&1) || true
  [[ "$crash_test" == *"PASS"* ]] && score=$((score + 20))

  # Code uses clear variable names (not single-letter in logic)
  local short_vars
  short_vars=$(grep -cE "for.*\(.*[a-z]\s*=" "$cart_file" 2>/dev/null) || short_vars=0
  # Some loop vars are fine, but business logic with single-letter vars is bad
  [[ $short_vars -lt 5 ]] && score=$((score + 10))

  # Module exports correctly
  if grep -q "module.exports\|export" "$cart_file" 2>/dev/null; then
    score=$((score + 10))
  fi

  # No console.log left in production code (only in tests)
  local console_in_src
  console_in_src=$(grep -c "console.log\|console.warn\|console.error" "$cart_file" 2>/dev/null) || console_in_src=0
  [[ $console_in_src -eq 0 ]] && score=$((score + 5))

  # Uses const/let instead of var
  if ! grep -q "\bvar\b" "$cart_file" 2>/dev/null; then
    score=$((score + 5))
  fi

  # Clean structure: class or clear function organization
  if grep -qE "class Cart|class ShoppingCart" "$cart_file" 2>/dev/null; then
    score=$((score + 5))
  fi

  # HARDER: Floating-point safety — price calculations with decimals should be correct (10 pts)
  # Test the classic 0.1 + 0.2 scenario with prices
  local fp_test
  fp_test=$(cd "$ws" && node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
c.addItem('A', 0.1, 1);
c.addItem('B', 0.2, 1);
const total = c.getTotal();
// Total should be exactly 0.3, or at least very close (within epsilon)
// If they handle floating point properly, it should be === 0.3 or use toFixed/Math.round
const ok = Math.abs(total - 0.3) < 0.001;
if (!ok) { console.log('FAIL:' + total); process.exit(); }

// Also test: 19.99 * 3 should be 59.97, not 59.96999...
const c2 = new Cart();
c2.addItem('X', 19.99, 3);
const t2 = c2.getTotal();
const ok2 = Math.abs(t2 - 59.97) < 0.01;

// Test with discount: 33.33 with 10% off = 29.997 should round to 30.00 or be within tolerance
const c3 = new Cart();
c3.addItem('Y', 33.33, 1);
c3.applyDiscount(10);
const t3 = c3.getTotal();
const ok3 = Math.abs(t3 - 29.997) < 0.01;

console.log(ok && ok2 && ok3 ? 'PASS' : 'FAIL:' + total + ',' + t2 + ',' + t3);
" 2>&1) || true
  [[ "$fp_test" == *"PASS"* ]] && score=$((score + 10))

  # HARDER: Large cart performance — add 1000 items, verify getTotal completes quickly (10 pts)
  local perf_test
  perf_test=$(cd "$ws" && timeout 5 node -e "
let Cart; try { Cart = require('./src/cart'); } catch(e) { Cart = require('./cart'); }
const c = new Cart();
for (let i = 0; i < 1000; i++) {
  c.addItem('Item-' + i, 9.99, 1);
}
const start = Date.now();
const total = c.getTotal();
const elapsed = Date.now() - start;
// Should complete in under 100ms for 1000 items
const fastEnough = elapsed < 100;
// Total should be approximately 9990
const correctTotal = Math.abs(total - 9990) < 1;
console.log(fastEnough && correctTotal ? 'PASS' : 'FAIL:elapsed=' + elapsed + 'ms,total=' + total);
" 2>&1) || true
  [[ "$perf_test" == *"PASS"* ]] && score=$((score + 10))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

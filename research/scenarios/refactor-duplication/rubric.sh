#!/usr/bin/env bash
# Rubric for: refactor-duplication
# HARDENED: Tests clean extraction of shared validation, preservation of all behavior,
# and code quality of the refactored result.

rubric_correctness() {
  local ws="$1"
  local score=0

  [[ -f "$ws/package.json" ]] && score=$((score + 3))
  (cd "$ws" && npm install --silent >/dev/null 2>&1) || true

  # Shared utility exists
  local shared_found=false
  for f in "src/validators.js" "src/utils/validators.js" "src/lib/validators.js" "src/validate.js" \
           "src/utils/validate.js" "src/lib/validate.js" "src/validation.js" "src/shared/validation.js" \
           "src/validation/validators.js" "src/validation/index.js" "src/validation/validator.js" \
           "src/middleware/validators.js" "src/middleware/validate.js" \
           "src/helpers/validators.js" "src/helpers/validate.js" "src/common/validators.js" \
           "src/common/validate.js" "src/validator.js"; do
    if [[ -f "$ws/$f" ]]; then
      shared_found=true
      break
    fi
  done
  $shared_found && score=$((score + 7))

  # Route files still exist
  [[ -f "$ws/src/routes/users.js" ]] && score=$((score + 2))
  [[ -f "$ws/src/routes/products.js" ]] && score=$((score + 2))
  [[ -f "$ws/src/routes/orders.js" ]] && score=$((score + 2))

  # User validation still works — basic
  local user_basic
  user_basic=$(cd "$ws" && node -e "
const { validateUserInput } = require('./src/routes/users');
let r;
r = validateUserInput({name: 'Alice', email: 'a@b.com'});
if (!r.valid) { console.log('FAIL1'); process.exit(); }
r = validateUserInput({});
if (r.valid || r.errors.length === 0) { console.log('FAIL2'); process.exit(); }
console.log('PASS');
" 2>&1) || true
  [[ "$user_basic" == *"PASS"* ]] && score=$((score + 8))

  # User validation — edge cases
  local user_edge
  user_edge=$(cd "$ws" && node -e "
const { validateUserInput } = require('./src/routes/users');
let r;
r = validateUserInput({name: 'x'.repeat(101), email: 'a@b.com'});
if (r.valid) { console.log('FAIL_LONG_NAME'); process.exit(); }
r = validateUserInput({name: 'A', email: 'bad'});
if (r.valid) { console.log('FAIL_BAD_EMAIL'); process.exit(); }
r = validateUserInput({name: '', email: 'a@b.com'});
if (r.valid) { console.log('FAIL_EMPTY_NAME'); process.exit(); }
console.log('PASS');
" 2>&1) || true
  [[ "$user_edge" == *"PASS"* ]] && score=$((score + 8))

  # Product validation — basic + edge cases
  local prod_test
  prod_test=$(cd "$ws" && node -e "
const { validateProductInput } = require('./src/routes/products');
let r;
r = validateProductInput({name: 'Widget', sku: 'W-001'});
if (!r.valid) { console.log('FAIL1'); process.exit(); }
r = validateProductInput({});
if (r.valid) { console.log('FAIL2'); process.exit(); }
r = validateProductInput({name: 'W', sku: 'S', price: -5});
if (r.valid) { console.log('FAIL_NEG_PRICE'); process.exit(); }
r = validateProductInput({name: '', sku: 'W-001'});
if (r.valid) { console.log('FAIL_EMPTY_NAME'); process.exit(); }
console.log('PASS');
" 2>&1) || true
  [[ "$prod_test" == *"PASS"* ]] && score=$((score + 12))

  # Order validation — basic + edge cases
  local order_test
  order_test=$(cd "$ws" && node -e "
const { validateOrderInput } = require('./src/routes/orders');
let r;
r = validateOrderInput({customerId: 'C1', items: ['a']});
if (!r.valid) { console.log('FAIL1'); process.exit(); }
r = validateOrderInput({});
if (r.valid) { console.log('FAIL2'); process.exit(); }
r = validateOrderInput({customerId: 'C1', items: []});
if (r.valid) { console.log('FAIL_EMPTY_ITEMS'); process.exit(); }
r = validateOrderInput({customerId: '', items: ['a']});
if (r.valid) { console.log('FAIL_EMPTY_CUSTOMER'); process.exit(); }
console.log('PASS');
" 2>&1) || true
  [[ "$order_test" == *"PASS"* ]] && score=$((score + 12))

  # Route files USE the shared utility (import it)
  local routes_use_shared=0
  for f in "$ws/src/routes/users.js" "$ws/src/routes/products.js" "$ws/src/routes/orders.js"; do
    [[ -f "$f" ]] || continue
    if grep -qE "require.*validat|import.*validat" "$f" 2>/dev/null; then
      routes_use_shared=$((routes_use_shared + 1))
    fi
  done
  [[ $routes_use_shared -ge 2 ]] && score=$((score + 10))
  [[ $routes_use_shared -ge 3 ]] && score=$((score + 5))

  # Error messages are descriptive (not just "invalid")
  local error_msg_test
  error_msg_test=$(cd "$ws" && node -e "
const { validateUserInput } = require('./src/routes/users');
const r = validateUserInput({});
const msgs = r.errors.join(' ').toLowerCase();
// Should mention what's wrong, not just 'invalid'
const descriptive = msgs.includes('required') || msgs.includes('name') || msgs.includes('email');
console.log(descriptive ? 'PASS' : 'FAIL:' + msgs);
" 2>&1) || true
  [[ "$error_msg_test" == *"PASS"* ]] && score=$((score + 7))

  # Validation return shape is consistent (all return {valid, errors})
  local shape_test
  shape_test=$(cd "$ws" && node -e "
const { validateUserInput } = require('./src/routes/users');
const { validateProductInput } = require('./src/routes/products');
const { validateOrderInput } = require('./src/routes/orders');
const results = [
  validateUserInput({name: 'A', email: 'a@b.com'}),
  validateProductInput({name: 'W', sku: 'S'}),
  validateOrderInput({customerId: 'C', items: ['a']})
];
const allValid = results.every(r => typeof r.valid === 'boolean' && Array.isArray(r.errors));
console.log(allValid ? 'PASS' : 'FAIL');
" 2>&1) || true
  [[ "$shape_test" == *"PASS"* ]] && score=$((score + 7))

  # Shared utility handles multiple resource types (not user-only)
  local multi_resource
  multi_resource=$(cd "$ws" && node -e "
try {
  // Check that shared module handles products and orders too
  let shared;
  const paths = ['./src/validation/validator', './src/validators', './src/utils/validators',
                 './src/lib/validators', './src/validate', './src/validation/index',
                 './src/validation/validators', './src/common/validators', './src/validator'];
  for (const p of paths) { try { shared = require(p); break; } catch(e) {} }
  if (!shared) { console.log('NO_SHARED'); process.exit(); }
  // Should have multiple exported functions or a generic validate function
  const keys = Object.keys(shared).filter(k => typeof shared[k] === 'function');
  console.log(keys.length >= 2 ? 'PASS' : 'PARTIAL:' + keys.length);
} catch(e) { console.log('ERROR:' + e.message); }
" 2>&1) || true
  [[ "$multi_resource" == *"PASS"* ]] && score=$((score + 8))

  # Shared utility is importable directly (not only through routes)
  local direct_import
  direct_import=$(cd "$ws" && node -e "
try {
  let shared;
  const paths = ['./src/validation/validator', './src/validators', './src/utils/validators',
                 './src/lib/validators', './src/validate', './src/validation/index',
                 './src/validation/validators', './src/common/validators', './src/validator'];
  for (const p of paths) { try { shared = require(p); break; } catch(e) {} }
  console.log(shared && Object.keys(shared).length > 0 ? 'PASS' : 'FAIL');
} catch(e) { console.log('ERROR:' + e.message); }
" 2>&1) || true
  [[ "$direct_import" == *"PASS"* ]] && score=$((score + 7))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  local test_files
  test_files=$(find "$ws" -maxdepth 4 \( \
    -name "*.test.*" -o -name "*.spec.*" -o \
    -name "test.js" -o -name "test_*.js" -o -name "tests.js" \
  \) ! -path "*/node_modules/*" 2>/dev/null)
  local _test_dir_files
  _test_dir_files=$(find "$ws" -maxdepth 4 \( -path "*/__tests__/*.js" -o -path "*/test/*.js" -o -path "*/tests/*.js" \) 2>/dev/null | grep -v node_modules) || true
  [[ -n "$_test_dir_files" ]] && test_files=$(printf '%s\n%s' "$test_files" "$_test_dir_files" | sort -u | grep -v '^$')
  local test_count
  test_count=$(echo "$test_files" | grep -c . 2>/dev/null) || test_count=0
  [[ $test_count -gt 0 ]] && score=$((score + 15))

  # Tests pass
  local test_output
  test_output=$(cd "$ws" && npm test 2>&1 | tail -30) || true
  if grep -qiE "pass|✓|ok|success" <<< "${test_output}"; then
    score=$((score + 25))
  fi

  # Tests cover all 3 routes
  local routes_tested=0
  for route in "user" "product" "order"; do
    if [[ -n "$test_files" ]] && echo "$test_files" | xargs grep -ql "$route" 2>/dev/null; then
      routes_tested=$((routes_tested + 1))
    fi
  done
  [[ $routes_tested -ge 2 ]] && score=$((score + 10))
  [[ $routes_tested -ge 3 ]] && score=$((score + 10))

  # Tests cover both valid and invalid inputs
  local validation_tests=0
  if [[ -n "$test_files" ]]; then
    echo "$test_files" | xargs grep -qlEi "valid|invalid|error|fail|reject" 2>/dev/null && validation_tests=$((validation_tests + 1))
    echo "$test_files" | xargs grep -qlEi "required|missing|empty" 2>/dev/null && validation_tests=$((validation_tests + 1))
    echo "$test_files" | xargs grep -qlEi "edge|boundary|long|max" 2>/dev/null && validation_tests=$((validation_tests + 1))
  fi
  [[ $validation_tests -ge 2 ]] && score=$((score + 10))

  # Tests for the shared utility itself (not just through routes)
  if [[ -n "$test_files" ]] && echo "$test_files" | xargs grep -qlEi "validator|validate|shared|common|util" 2>/dev/null; then
    score=$((score + 10))
  fi

  # Test case count
  local case_count=0
  if [[ -n "$test_files" ]]; then
    case_count=$(echo "$test_files" | xargs grep -cE "it\(|test\(|describe\(" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}') || case_count=0
  fi
  [[ $case_count -gt 10 ]] && score=$((score + 10))
  [[ $case_count -gt 20 ]] && score=$((score + 10))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=0

  # Shared utility is well-structured (has multiple exported functions)
  local shared_file=""
  for f in "src/validators.js" "src/utils/validators.js" "src/lib/validators.js" "src/validate.js" \
           "src/utils/validate.js" "src/lib/validate.js" "src/validation.js" "src/shared/validation.js" \
           "src/validation/validators.js" "src/validation/index.js" "src/validation/validator.js" \
           "src/middleware/validators.js" "src/middleware/validate.js" \
           "src/helpers/validators.js" "src/helpers/validate.js" "src/common/validators.js" \
           "src/common/validate.js" "src/validator.js"; do
    [[ -f "$ws/$f" ]] && shared_file="$ws/$f" && break
  done

  if [[ -n "$shared_file" ]]; then
    # Has multiple validation helper functions
    local func_count
    func_count="$(grep -cE 'function |const .* = |module\.exports\.' "$shared_file" 2>/dev/null)" || func_count=0
    [[ $func_count -ge 2 ]] && score=$((score + 10))
    [[ $func_count -ge 4 ]] && score=$((score + 5))

    # Is reusable (parameterized, not hardcoded)
    if grep -qE "maxLength|max|min|required|options|config|rules|schema|pattern" "$shared_file" 2>/dev/null; then
      score=$((score + 10))
    fi

    # Uses declarative approach (schemas/rules objects, not imperative if-else chains)
    if grep -qE "schema|rules|fields|specs|config|definition" "$shared_file" 2>/dev/null; then
      score=$((score + 10))
    fi
  fi

  # No duplication remains in route files
  local duplication_score=25
  for f in "$ws/src/routes/users.js" "$ws/src/routes/products.js" "$ws/src/routes/orders.js"; do
    [[ -f "$f" ]] || continue
    # Penalize if route files still have inline validation patterns
    local inline_checks
    inline_checks="$(grep -cE 'typeof.*!==|\.length\s*>|\.includes\(' "$f" 2>/dev/null)" || inline_checks=0
    if [[ $inline_checks -gt 2 ]]; then
      duplication_score=$((duplication_score - 10))
    fi
  done
  [[ $duplication_score -lt 0 ]] && duplication_score=0
  score=$((score + duplication_score))

  # Route files are SHORT (refactoring should reduce them)
  local total_route_lines=0
  for f in "$ws/src/routes/users.js" "$ws/src/routes/products.js" "$ws/src/routes/orders.js"; do
    [[ -f "$f" ]] || continue
    local lines
    lines=$(wc -l < "$f" | tr -d ' ')
    total_route_lines=$((total_route_lines + lines))
  done
  # If all 3 routes are under 30 lines each (90 total), great refactoring
  [[ $total_route_lines -lt 120 ]] && score=$((score + 10))
  [[ $total_route_lines -lt 90 ]] && score=$((score + 5))

  # Uses const/let, no var
  local has_var=false
  for f in "$ws/src/routes/users.js" "$ws/src/routes/products.js" "$ws/src/routes/orders.js"; do
    [[ -f "$f" ]] || continue
    if grep -q "\bvar\b" "$f" 2>/dev/null; then
      has_var=true
    fi
  done
  if [[ -n "$shared_file" ]] && grep -q "\bvar\b" "$shared_file" 2>/dev/null; then
    has_var=true
  fi
  $has_var || score=$((score + 10))

  # No console.log in source files
  local console_found=false
  for f in "$ws/src/routes/users.js" "$ws/src/routes/products.js" "$ws/src/routes/orders.js"; do
    [[ -f "$f" ]] || continue
    if grep -q "console.log" "$f" 2>/dev/null; then
      console_found=true
    fi
  done
  $console_found || score=$((score + 5))

  # Module exports are clean (named exports, not default)
  if [[ -n "$shared_file" ]] && grep -qE "module\.exports\s*=\s*\{|exports\." "$shared_file" 2>/dev/null; then
    score=$((score + 10))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

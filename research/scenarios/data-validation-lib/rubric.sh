#!/usr/bin/env bash
# Rubric for: data-validation-lib
# Hardened rubric — a strong implementation should score ~85-90, not 100.

rubric_correctness() {
  local ws="$1"
  local score=0

  # ── Structure (5 pts) ──────────────────────────────────────────────
  [[ -d "$ws/validators" ]] && [[ -f "$ws/validators/__init__.py" ]] && score=$((score + 5))

  # ── Email validator — basic (8 pts) ────────────────────────────────
  local email_basic
  email_basic=$(cd "$ws" && python3 -c "
from validators import validate_email
ok, msg = validate_email('test@example.com')
assert ok, f'Should be valid: {msg}'
ok, msg = validate_email('not-an-email')
assert not ok, 'Should be invalid'
ok, msg = validate_email('@missing-local.com')
assert not ok, 'Missing local part should be invalid'
ok, msg = validate_email('missing-domain@')
assert not ok, 'Missing domain should be invalid'
print('PASS')
" 2>&1) || true
  [[ "$email_basic" == *"PASS"* ]] && score=$((score + 8))

  # ── Email validator — edge cases (8 pts) ───────────────────────────
  local email_edge
  email_edge=$(cd "$ws" && python3 -c "
from validators import validate_email
# Plus addressing must be accepted
ok, msg = validate_email('user+tag@example.com')
assert ok, f'Plus addressing should be valid: {msg}'
# Dots in local part
ok, msg = validate_email('first.last@example.com')
assert ok, f'Dots in local should be valid: {msg}'
# Subdomain
ok, msg = validate_email('user@mail.example.co.uk')
assert ok, f'Subdomain should be valid: {msg}'
# Double-dot in local part is invalid per RFC
ok, msg = validate_email('user..name@example.com')
assert not ok, 'Double dot in local part should be invalid'
print('PASS')
" 2>&1) || true
  [[ "$email_edge" == *"PASS"* ]] && score=$((score + 8))

  # ── Email — error message quality (3 pts) ──────────────────────────
  local email_msg
  email_msg=$(cd "$ws" && python3 -c "
from validators import validate_email
ok, msg = validate_email('bad')
assert not ok
assert len(msg) > 5, f'Error message too short/missing: \"{msg}\"'
ok2, msg2 = validate_email('test@example.com')
assert ok2
# Success message should be empty string
assert msg2 == '', f'Success msg should be empty string, got: \"{msg2}\"'
print('PASS')
" 2>&1) || true
  [[ "$email_msg" == *"PASS"* ]] && score=$((score + 3))

  # ── URL validator — basic (8 pts) ──────────────────────────────────
  local url_basic
  url_basic=$(cd "$ws" && python3 -c "
from validators import validate_url
ok, msg = validate_url('https://example.com')
assert ok, f'Should be valid: {msg}'
ok, msg = validate_url('http://example.com/path')
assert ok, f'Path URL should be valid: {msg}'
ok, msg = validate_url('not-a-url')
assert not ok, 'Should be invalid'
ok, msg = validate_url('ftp://files.example.com')
assert ok, f'FTP scheme should be valid: {msg}'
print('PASS')
" 2>&1) || true
  [[ "$url_basic" == *"PASS"* ]] && score=$((score + 8))

  # ── URL — advanced (8 pts) ─────────────────────────────────────────
  local url_adv
  url_adv=$(cd "$ws" && python3 -c "
from validators import validate_url
# Query params and fragments
ok, msg = validate_url('https://example.com/search?q=hello&lang=en')
assert ok, f'Query params should be valid: {msg}'
ok, msg = validate_url('https://example.com/page#section')
assert ok, f'Fragment should be valid: {msg}'
# Port
ok, msg = validate_url('http://localhost:8080/api')
assert ok, f'Port should be valid: {msg}'
# Auth in URL
ok, msg = validate_url('http://user:pass@host.com/path')
assert ok, f'Auth in URL should be valid: {msg}'
# Missing scheme
ok, msg = validate_url('example.com')
assert not ok, 'Missing scheme should be invalid'
print('PASS')
" 2>&1) || true
  [[ "$url_adv" == *"PASS"* ]] && score=$((score + 8))

  # ── Phone validator — basic US (8 pts) ─────────────────────────────
  local phone_basic
  phone_basic=$(cd "$ws" && python3 -c "
from validators import validate_phone
ok, msg = validate_phone('(555) 234-5678')
assert ok, f'Formatted should be valid: {msg}'
ok, msg = validate_phone('5552345678')
assert ok, f'Plain 10 digits should be valid: {msg}'
ok, msg = validate_phone('555-234-5678')
assert ok, f'Dashed should be valid: {msg}'
ok, msg = validate_phone('123')
assert not ok, 'Too short should be invalid'
print('PASS')
" 2>&1) || true
  [[ "$phone_basic" == *"PASS"* ]] && score=$((score + 8))

  # ── Phone — international formats (6 pts) ──────────────────────────
  local phone_intl
  phone_intl=$(cd "$ws" && python3 -c "
from validators import validate_phone
# +1 prefix for US
ok, msg = validate_phone('+1-555-234-5678')
assert ok, f'+1 prefix should be valid: {msg}'
ok, msg = validate_phone('+15552345678')
assert ok, f'+1 no dashes should be valid: {msg}'
# UK format
ok, msg = validate_phone('+44 20 7946 0958')
assert ok, f'UK format should be valid: {msg}'
print('PASS')
" 2>&1) || true
  [[ "$phone_intl" == *"PASS"* ]] && score=$((score + 6))

  # ── Credit card — basic Luhn (8 pts) ───────────────────────────────
  local cc_basic
  cc_basic=$(cd "$ws" && python3 -c "
from validators import validate_credit_card
ok, msg = validate_credit_card('4111111111111111')
assert ok, f'Valid Visa test number: {msg}'
ok, msg = validate_credit_card('5500000000000004')
assert ok, f'Valid MC test number: {msg}'
ok, msg = validate_credit_card('1234567890123456')
assert not ok, 'Invalid Luhn should fail'
ok, msg = validate_credit_card('0000000000000000')
assert not ok, 'All zeros should fail'
print('PASS')
" 2>&1) || true
  [[ "$cc_basic" == *"PASS"* ]] && score=$((score + 8))

  # ── Credit card — formatting tolerance (6 pts) ─────────────────────
  local cc_fmt
  cc_fmt=$(cd "$ws" && python3 -c "
from validators import validate_credit_card
# Spaces between groups
ok, msg = validate_credit_card('4111 1111 1111 1111')
assert ok, f'Spaces should be accepted: {msg}'
# Dashes between groups
ok, msg = validate_credit_card('4111-1111-1111-1111')
assert ok, f'Dashes should be accepted: {msg}'
# Too short
ok, msg = validate_credit_card('411111')
assert not ok, 'Too short should be invalid'
# Non-numeric
ok, msg = validate_credit_card('abcdefghijklmnop')
assert not ok, 'Non-numeric should be invalid'
print('PASS')
" 2>&1) || true
  [[ "$cc_fmt" == *"PASS"* ]] && score=$((score + 6))

  # ── Date range — basic (8 pts) ─────────────────────────────────────
  local date_basic
  date_basic=$(cd "$ws" && python3 -c "
from validators import validate_date_range
ok, msg = validate_date_range('2024-01-01', '2024-12-31')
assert ok, f'Should be valid: {msg}'
ok, msg = validate_date_range('2024-12-31', '2024-01-01')
assert not ok, 'End before start should be invalid'
ok, msg = validate_date_range('not-a-date', '2024-12-31')
assert not ok, 'Invalid date string should fail'
print('PASS')
" 2>&1) || true
  [[ "$date_basic" == *"PASS"* ]] && score=$((score + 8))

  # ── Date range — edge cases (5 pts) ────────────────────────────────
  local date_edge
  date_edge=$(cd "$ws" && python3 -c "
from validators import validate_date_range
# Same-day range should be valid
ok, msg = validate_date_range('2024-06-15', '2024-06-15')
assert ok, f'Same day should be valid: {msg}'
# Leap year date
ok, msg = validate_date_range('2024-02-29', '2024-03-01')
assert ok, f'Leap year Feb 29 should be valid: {msg}'
# Invalid calendar date
ok, msg = validate_date_range('2024-02-30', '2024-03-01')
assert not ok, 'Feb 30 should be invalid'
print('PASS')
" 2>&1) || true
  [[ "$date_edge" == *"PASS"* ]] && score=$((score + 5))

  # ── All validators return (bool, str) tuple (7 pts) ────────────────
  local tuple_check
  tuple_check=$(cd "$ws" && python3 -c "
from validators import validate_email, validate_url, validate_phone, validate_credit_card, validate_date_range

for name, fn, args in [
    ('email', validate_email, ('x',)),
    ('url', validate_url, ('x',)),
    ('phone', validate_phone, ('x',)),
    ('credit_card', validate_credit_card, ('x',)),
    ('date_range', validate_date_range, ('2024-01-01', '2024-12-31')),
]:
    result = fn(*args)
    assert isinstance(result, tuple), f'{name} should return tuple, got {type(result)}'
    assert len(result) == 2, f'{name} tuple should have 2 elements, got {len(result)}'
    ok, msg = result
    assert isinstance(ok, bool), f'{name}[0] should be bool, got {type(ok)}'
    assert isinstance(msg, str), f'{name}[1] should be str, got {type(msg)}'
print('PASS')
" 2>&1) || true
  [[ "$tuple_check" == *"PASS"* ]] && score=$((score + 7))

  # ── Handles None/empty gracefully across ALL validators (7 pts) ────
  local null_result
  null_result=$(cd "$ws" && python3 -c "
from validators import validate_email, validate_url, validate_phone, validate_credit_card, validate_date_range

for name, fn in [('email', validate_email), ('url', validate_url),
                 ('phone', validate_phone), ('credit_card', validate_credit_card)]:
    ok, msg = fn(None)
    assert not ok, f'{name}(None) should be invalid'
    ok, msg = fn('')
    assert not ok, f'{name}(\"\") should be invalid'

# date_range with None
ok, msg = validate_date_range(None, '2024-01-01')
assert not ok, 'date_range(None, ...) should be invalid'
ok, msg = validate_date_range('2024-01-01', None)
assert not ok, 'date_range(..., None) should be invalid'
ok, msg = validate_date_range('', '')
assert not ok, 'date_range(\"\", \"\") should be invalid'
print('PASS')
" 2>&1) || true
  [[ "$null_result" == *"PASS"* ]] && score=$((score + 7))

  # ── Very long / unusual but valid inputs (5 pts) ───────────────────
  local unusual
  unusual=$(cd "$ws" && python3 -c "
from validators import validate_email, validate_url
# Very long but structurally valid email (64 char local part)
long_local = 'a' * 64
ok, msg = validate_email(f'{long_local}@example.com')
# We don't assert valid — just assert it doesn't crash and returns tuple
assert isinstance(ok, bool), 'Should return bool for long email'
# URL with unicode path
ok, msg = validate_url('https://example.com/path/%E4%B8%AD%E6%96%87')
assert ok, f'Percent-encoded URL should be valid: {msg}'
print('PASS')
" 2>&1) || true
  [[ "$unusual" == *"PASS"* ]] && score=$((score + 5))

  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  # ── Test directory exists (5 pts) ──────────────────────────────────
  [[ -d "$ws/tests" || -d "$ws/test" ]] && score=$((score + 5))

  # ── Test files exist (5 pts) ───────────────────────────────────────
  local test_count
  test_count=$(find "$ws" -maxdepth 4 \( -name "test_*.py" -o -name "*_test.py" \) ! -path "*/.venv/*" 2>/dev/null | wc -l | tr -d ' ')
  [[ $test_count -ge 3 ]] && score=$((score + 5))

  # ── Tests pass with pytest (20 pts) ────────────────────────────────
  local pytest_output
  pytest_output=$(cd "$ws" && python3 -m pytest -v 2>&1) || true
  if [[ "$pytest_output" == *"passed"* ]] || [[ "$pytest_output" == *" ok"* ]]; then
    score=$((score + 20))
  else
    # Fallback to unittest
    local unittest_output
    unittest_output=$(cd "$ws" && python3 -m unittest discover 2>&1) || true
    if [[ "$unittest_output" == *"OK"* ]] || [[ "$unittest_output" == *"ok"* ]]; then
      score=$((score + 20))
    fi
  fi

  # ── Tests cover all 5 validators (10 pts) ──────────────────────────
  local validators_tested=0
  for v in "email" "url" "phone" "credit" "date"; do
    local found
    found=$(find "$ws" -maxdepth 4 \( -name "test_*.py" -o -name "*_test.py" \) ! -path "*/.venv/*" -exec grep -l "$v" {} + 2>/dev/null) || true
    [[ -n "$found" ]] && validators_tested=$((validators_tested + 1))
  done
  [[ $validators_tested -ge 4 ]] && score=$((score + 5))
  [[ $validators_tested -ge 5 ]] && score=$((score + 5))

  # ── Sufficient number of test cases: >20 total (15 pts) ────────────
  local total_tests
  total_tests=$(find "$ws" -maxdepth 4 \( -name "test_*.py" -o -name "*_test.py" \) ! -path "*/.venv/*" -exec grep -c "def test_" {} + 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$total_tests" -ge 10 ]] && score=$((score + 5))
  [[ "$total_tests" -ge 20 ]] && score=$((score + 5))
  [[ "$total_tests" -ge 30 ]] && score=$((score + 5))

  # ── Tests verify error messages, not just booleans (10 pts) ────────
  local msg_checks
  msg_checks=$(find "$ws" -maxdepth 4 \( -name "test_*.py" -o -name "*_test.py" \) ! -path "*/.venv/*" -exec grep -c "msg\|error_message\|message\|assert.*\[1\]\|assert.*msg" {} + 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$msg_checks" -ge 3 ]] && score=$((score + 5))
  [[ "$msg_checks" -ge 10 ]] && score=$((score + 5))

  # ── Tests include boundary / edge cases (10 pts) ───────────────────
  # Look for signs of edge-case testing: None, empty, boundary values
  local edge_patterns=0
  local test_content
  test_content=$(find "$ws" -maxdepth 4 \( -name "test_*.py" -o -name "*_test.py" \) ! -path "*/.venv/*" -exec cat {} + 2>/dev/null) || true
  for pattern in "None" '""' "''" "boundary\|edge\|invalid\|empty" "too.short\|too.long\|malform"; do
    local found_edge
    found_edge=$(echo "$test_content" | grep -c "$pattern" 2>/dev/null) || true
    [[ "$found_edge" -gt 0 ]] && edge_patterns=$((edge_patterns + 1))
  done
  [[ $edge_patterns -ge 2 ]] && score=$((score + 5))
  [[ $edge_patterns -ge 4 ]] && score=$((score + 5))

  # ── Tests cover None/empty/wrong-type for every validator (20 pts) ─
  local null_coverage=0
  for v in "email" "url" "phone" "credit_card" "date_range"; do
    local v_test_content
    v_test_content=$(find "$ws" -maxdepth 4 \( -name "test_*.py" -o -name "*_test.py" \) ! -path "*/.venv/*" -exec grep -l "$v" {} + 2>/dev/null | head -3 | xargs cat 2>/dev/null) || true
    if [[ -n "$v_test_content" ]]; then
      # Check if None or empty string is tested in the context of this validator
      local has_none
      has_none=$(echo "$v_test_content" | grep -c "None\|empty\|''" 2>/dev/null) || true
      [[ "$has_none" -gt 0 ]] && null_coverage=$((null_coverage + 1))
    fi
  done
  [[ $null_coverage -ge 3 ]] && score=$((score + 5))
  [[ $null_coverage -ge 5 ]] && score=$((score + 20))

  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=0

  local src_files
  src_files=$(find "$ws/validators" -name "*.py" 2>/dev/null)
  # Nothing here to be robust about. Every check below awards points for the
  # absence of a problem, which costs nothing when there is no code for the
  # problem to be in — and this scenario starts from an empty workspace.
  [[ -n "${src_files}" ]] || { echo 0; return; }

  # ── Non-string inputs handled gracefully (20 pts) ──────────────────
  local type_safety
  type_safety=$(cd "$ws" && python3 -c "
from validators import validate_email, validate_url, validate_phone, validate_credit_card, validate_date_range

bad_inputs = [123, 45.6, ['a', 'b'], {'key': 'val'}, True]
for bad in bad_inputs:
    for name, fn in [('email', validate_email), ('url', validate_url),
                     ('phone', validate_phone), ('credit_card', validate_credit_card)]:
        ok, msg = fn(bad)
        assert not ok, f'{name}({bad!r}) should be invalid, got ok=True'
        assert isinstance(msg, str), f'{name}({bad!r}) msg should be str'

# date_range with non-string
ok, msg = validate_date_range(123, '2024-01-01')
assert not ok, 'date_range(int, str) should be invalid'
ok, msg = validate_date_range('2024-01-01', [1, 2])
assert not ok, 'date_range(str, list) should be invalid'
print('PASS')
" 2>&1) || true
  [[ "$type_safety" == *"PASS"* ]] && score=$((score + 20))

  # ── Extremely long inputs don't crash (15 pts) ─────────────────────
  local long_input
  long_input=$(cd "$ws" && python3 -c "
from validators import validate_email, validate_url, validate_phone, validate_credit_card
long_str = 'a' * 10000
for name, fn in [('email', validate_email), ('url', validate_url),
                 ('phone', validate_phone), ('credit_card', validate_credit_card)]:
    ok, msg = fn(long_str)
    assert not ok, f'{name} with 10K chars should be invalid'
    assert isinstance(msg, str), f'{name} with 10K chars should return str msg'
long_email = 'a' * 10000 + '@example.com'
ok, msg = validate_email(long_email)
assert not ok, 'Very long email should be invalid'
print('PASS')
" 2>&1) || true
  [[ "$long_input" == *"PASS"* ]] && score=$((score + 15))

  # ── Type annotations present (10 pts) ──────────────────────────────
  local has_annotations
  has_annotations=$(echo "$src_files" | xargs grep -c "def.*->.*:\|: str\|: bool\|Tuple\[" 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$has_annotations" -ge 3 ]] && score=$((score + 5))
  [[ "$has_annotations" -ge 5 ]] && score=$((score + 5))

  # ── Docstrings present (10 pts) ────────────────────────────────────
  local has_docstrings
  has_docstrings=$(echo "$src_files" | xargs grep -c '"""' 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$has_docstrings" -ge 5 ]] && score=$((score + 5))
  [[ "$has_docstrings" -ge 10 ]] && score=$((score + 5))

  # ── Validators importable from package root (10 pts) ───────────────
  local importable
  importable=$(cd "$ws" && python3 -c "
from validators import validate_email, validate_url, validate_phone, validate_credit_card, validate_date_range
assert callable(validate_email)
assert callable(validate_url)
assert callable(validate_phone)
assert callable(validate_credit_card)
assert callable(validate_date_range)
print('PASS')
" 2>&1) || true
  [[ "$importable" == *"PASS"* ]] && score=$((score + 10))

  # ── Has type checking / input guards in source (10 pts) ────────────
  local type_guards
  type_guards=$(echo "$src_files" | xargs grep -c "isinstance\|is None\|not.*input\|not.*value\|if not" 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$type_guards" -ge 3 ]] && score=$((score + 5))
  [[ "$type_guards" -ge 8 ]] && score=$((score + 5))

  # ── Uses try/except for edge cases (10 pts) ────────────────────────
  local has_exception_handling
  has_exception_handling=$(echo "$src_files" | xargs grep -c "try:\|except.*:\|ValueError\|TypeError" 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$has_exception_handling" -ge 3 ]] && score=$((score + 5))
  [[ "$has_exception_handling" -ge 6 ]] && score=$((score + 5))

  # ── Returns proper tuple format in source (10 pts) ─────────────────
  local return_tuples
  return_tuples=$(echo "$src_files" | xargs grep -c "return.*True.*,\|return.*False.*,\|return (True\|return (False" 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ "$return_tuples" -ge 5 ]] && score=$((score + 5))
  [[ "$return_tuples" -ge 10 ]] && score=$((score + 5))

  # ── No external dependencies (5 pts) ───────────────────────────────
  if [[ ! -f "$ws/requirements.txt" ]] || [[ $(wc -l < "$ws/requirements.txt" 2>/dev/null || echo "0") -le 1 ]]; then
    score=$((score + 5))
  fi

  echo "$score"
}

#!/usr/bin/env bash
# Rubric for: rest-api-crud
# Hardened rubric v2 — target score ~60-75 for typical implementations.

rubric_correctness() {
  local ws="$1"
  local score=0

  [[ -f "$ws/package.json" ]] && score=$((score + 2))

  # Install deps
  if ! (cd "$ws" && npm install --silent >/dev/null 2>&1); then
    echo "$score"; return
  fi
  score=$((score + 3))

  # Find the server entry point (prefer main from package.json, then server.* over app.*)
  local entry=""
  local pkg_main
  pkg_main=$(cd "$ws" && node -e "try{console.log(require('./package.json').main||'')}catch(e){}" 2>/dev/null || true)
  if [[ -n "$pkg_main" && -f "$ws/$pkg_main" ]]; then
    entry="$pkg_main"
  else
    for f in "server.js" "src/server.js" "index.js" "src/index.js" "app.js" "src/app.js"; do
      [[ -f "$ws/$f" ]] && entry="$f" && break
    done
  fi
  [[ -z "$entry" ]] && { echo "$score"; return; }

  # Start the server in background, test endpoints
  local port=0
  port=$(_find_free_port)
  local server_pid=""

  # Try to start the server
  # Use exec so kill targets the node process directly (not a bash subshell)
  (cd "$ws" && exec env PORT="$port" node "$entry") &>/dev/null &
  server_pid=$!
  sleep 2

  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "$score"; return
  fi

  local base="http://localhost:$port"

  # ---------- BASIC CRUD (34 points) ----------

  # POST /books — create a book (5 pts)
  local create_resp
  create_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/books" \
    -H "Content-Type: application/json" \
    -d '{"title":"Test Book","author":"Test Author","isbn":"9780131103627"}' 2>/dev/null) || true
  local create_code
  create_code=$(echo "$create_resp" | tail -1)
  if [[ "$create_code" == "201" ]] || [[ "$create_code" == "200" ]]; then
    score=$((score + 5))
  fi

  # Verify created book has an ID in the response (3 pts)
  local create_body
  create_body=$(echo "$create_resp" | sed '$d')
  local created_id
  created_id=$(echo "$create_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, dict):
        print(data.get('id', ''))
    else:
        print('')
except:
    print('')
" 2>/dev/null || true)
  if [[ -n "$created_id" && "$created_id" != "None" && "$created_id" != "" ]]; then
    score=$((score + 3))
  fi

  # Verify created book echoes back the title (2 pts)
  local has_title
  has_title=$(echo "$create_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print('yes' if data.get('title') == 'Test Book' else 'no')
except:
    print('no')
" 2>/dev/null || true)
  [[ "$has_title" == "yes" ]] && score=$((score + 2))

  # GET /books — list all books (5 pts)
  local list_resp
  list_resp=$(curl -s -w "\n%{http_code}" "$base/books" 2>/dev/null) || true
  local list_code
  list_code=$(echo "$list_resp" | tail -1)
  local list_body
  list_body=$(echo "$list_resp" | sed '$d')
  if [[ "$list_code" == "200" ]]; then
    score=$((score + 3))
    local has_book
    has_book=$(echo "$list_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    items = data if isinstance(data, list) else data.get('books', data.get('data', []))
    print('yes' if any('Test Book' in str(b.get('title','')) for b in items) else 'no')
except:
    print('no')
" 2>/dev/null || true)
    [[ "$has_book" == "yes" ]] && score=$((score + 2))
  fi

  # Extract book ID from list for subsequent tests
  local book_id
  book_id=$(echo "$list_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    items = data if isinstance(data, list) else data.get('books', data.get('data', []))
    if len(items) > 0:
        print(items[0].get('id', ''))
    else:
        print('')
except:
    print('')
" 2>/dev/null || true)
  # Fall back to created_id if list parsing failed
  [[ -z "$book_id" || "$book_id" == "None" ]] && book_id="$created_id"
  # Last resort fallback
  [[ -z "$book_id" || "$book_id" == "None" ]] && book_id="1"

  # GET /books/:id — single book (5 pts)
  local get_resp
  get_resp=$(curl -s -w "\n%{http_code}" "$base/books/$book_id" 2>/dev/null) || true
  local get_code
  get_code=$(echo "$get_resp" | tail -1)
  [[ "$get_code" == "200" ]] && score=$((score + 5))

  # PUT /books/:id — full update (5 pts)
  local put_resp
  put_resp=$(curl -s -w "\n%{http_code}" -X PUT "$base/books/$book_id" \
    -H "Content-Type: application/json" \
    -d '{"title":"Updated Book","author":"Updated Author","isbn":"9780131103627"}' 2>/dev/null) || true
  local put_code
  put_code=$(echo "$put_resp" | tail -1)
  [[ "$put_code" == "200" ]] && score=$((score + 5))

  # Verify PUT actually changed the data (2 pts)
  local verify_put
  verify_put=$(curl -s "$base/books/$book_id" 2>/dev/null) || true
  local put_changed
  put_changed=$(echo "$verify_put" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print('yes' if data.get('title') == 'Updated Book' else 'no')
except:
    print('no')
" 2>/dev/null || true)
  [[ "$put_changed" == "yes" ]] && score=$((score + 2))

  # DELETE /books/:id (5 pts)
  local del_resp
  del_resp=$(curl -s -w "\n%{http_code}" -X DELETE "$base/books/$book_id" 2>/dev/null) || true
  local del_code
  del_code=$(echo "$del_resp" | tail -1)
  if [[ "$del_code" == "200" ]] || [[ "$del_code" == "204" ]]; then
    score=$((score + 5))
  fi

  # Verify deleted book is truly gone — GET after DELETE should 404 (2 pts)
  local gone_resp
  gone_resp=$(curl -s -w "\n%{http_code}" "$base/books/$book_id" 2>/dev/null) || true
  local gone_code
  gone_code=$(echo "$gone_resp" | tail -1)
  [[ "$gone_code" == "404" ]] && score=$((score + 2))

  # ---------- ERROR HANDLING (24 points) ----------

  # GET /books/nonexistent — 404 (3 pts)
  local notfound_resp
  notfound_resp=$(curl -s -w "\n%{http_code}" "$base/books/nonexistent-id-999" 2>/dev/null) || true
  local nf_code
  nf_code=$(echo "$notfound_resp" | tail -1)
  [[ "$nf_code" == "404" ]] && score=$((score + 3))

  # POST with empty body — 400 (3 pts)
  local empty_resp
  empty_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/books" \
    -H "Content-Type: application/json" \
    -d '{}' 2>/dev/null) || true
  local empty_code
  empty_code=$(echo "$empty_resp" | tail -1)
  if [[ "$empty_code" == "400" ]] || [[ "$empty_code" == "422" ]]; then
    score=$((score + 3))
  fi

  # POST missing required field (author) — 400 (3 pts)
  local missing_resp
  missing_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/books" \
    -H "Content-Type: application/json" \
    -d '{"title":"Only Title"}' 2>/dev/null) || true
  local missing_code
  missing_code=$(echo "$missing_resp" | tail -1)
  if [[ "$missing_code" == "400" ]] || [[ "$missing_code" == "422" ]]; then
    score=$((score + 3))
  fi

  # Invalid ISBN format — 400 (3 pts)
  local isbn_resp
  isbn_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/books" \
    -H "Content-Type: application/json" \
    -d '{"title":"Book","author":"Author","isbn":"invalid"}' 2>/dev/null) || true
  local isbn_code
  isbn_code=$(echo "$isbn_resp" | tail -1)
  if [[ "$isbn_code" == "400" ]] || [[ "$isbn_code" == "422" ]]; then
    score=$((score + 3))
  fi

  # Duplicate ISBN rejection — second book with same ISBN should fail (3 pts)
  # First create a book with a specific ISBN
  local dup1_resp
  dup1_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/books" \
    -H "Content-Type: application/json" \
    -d '{"title":"First Book","author":"Author One","isbn":"9781234567897"}' 2>/dev/null) || true
  : "$dup1_resp"
  # Now try creating another book with the same ISBN
  local dup2_resp
  dup2_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/books" \
    -H "Content-Type: application/json" \
    -d '{"title":"Second Book","author":"Author Two","isbn":"9781234567897"}' 2>/dev/null) || true
  local dup2_code
  dup2_code=$(echo "$dup2_resp" | tail -1)
  if [[ "$dup2_code" == "400" ]] || [[ "$dup2_code" == "409" ]] || [[ "$dup2_code" == "422" ]]; then
    score=$((score + 3))
  fi

  # Title too long (>200 chars) should fail validation (3 pts)
  local long_title
  long_title=$(python3 -c "print('A' * 201)" 2>/dev/null || true)
  local longstr_resp
  longstr_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/books" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"$long_title\",\"author\":\"Author\"}" 2>/dev/null) || true
  local longstr_code
  longstr_code=$(echo "$longstr_resp" | tail -1)
  if [[ "$longstr_code" == "400" ]] || [[ "$longstr_code" == "422" ]]; then
    score=$((score + 3))
  fi

  # Content-Type validation — send non-JSON body with wrong content type (2 pts)
  local ct_resp
  ct_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/books" \
    -H "Content-Type: text/plain" \
    -d 'this is not json' 2>/dev/null) || true
  local ct_code
  ct_code=$(echo "$ct_resp" | tail -1)
  if [[ "$ct_code" == "400" ]] || [[ "$ct_code" == "415" ]] || [[ "$ct_code" == "422" ]]; then
    score=$((score + 2))
  fi

  # Malformed JSON body handling (1 pt)
  local malformed_resp
  malformed_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/books" \
    -H "Content-Type: application/json" \
    -d '{this is not valid json' 2>/dev/null) || true
  local malformed_code
  malformed_code=$(echo "$malformed_resp" | tail -1)
  if [[ "$malformed_code" == "400" ]] || [[ "$malformed_code" == "422" ]]; then
    score=$((score + 1))
  fi

  # ---------- ADVANCED (20 points) ----------

  # PATCH /books/:id — partial update (4 pts)
  # Create a fresh book to test PATCH against
  local patch_create
  patch_create=$(curl -s -w "\n%{http_code}" -X POST "$base/books" \
    -H "Content-Type: application/json" \
    -d '{"title":"Patch Target","author":"Original Author"}' 2>/dev/null) || true
  local patch_body
  patch_body=$(echo "$patch_create" | sed '$d')
  local patch_id
  patch_id=$(echo "$patch_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print(data.get('id', ''))
except:
    print('')
" 2>/dev/null || true)

  if [[ -n "$patch_id" && "$patch_id" != "None" && "$patch_id" != "" ]]; then
    local patch_resp
    patch_resp=$(curl -s -w "\n%{http_code}" -X PATCH "$base/books/$patch_id" \
      -H "Content-Type: application/json" \
      -d '{"title":"Patched Title"}' 2>/dev/null) || true
    local patch_code
    patch_code=$(echo "$patch_resp" | tail -1)
    if [[ "$patch_code" == "200" ]]; then
      # Verify only title changed, author preserved
      local verify_patch
      verify_patch=$(curl -s "$base/books/$patch_id" 2>/dev/null) || true
      local patch_ok
      patch_ok=$(echo "$verify_patch" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    t = data.get('title') == 'Patched Title'
    a = data.get('author') == 'Original Author'
    print('yes' if t and a else 'no')
except:
    print('no')
" 2>/dev/null || true)
      [[ "$patch_ok" == "yes" ]] && score=$((score + 4))
    fi
  fi

  # Response Content-Type header is application/json (3 pts)
  local ct_header
  ct_header=$(curl -s -o /dev/null -w "%{content_type}" "$base/books" 2>/dev/null) || true
  local ct_check
  ct_check=$(echo "$ct_header" | python3 -c "
import sys
ct = sys.stdin.read().strip().lower()
print('yes' if 'application/json' in ct else 'no')
" 2>/dev/null || true)
  [[ "$ct_check" == "yes" ]] && score=$((score + 3))

  # PUT /books/:id with missing required field should fail (3 pts)
  # (PUT should require full object replacement)
  local put_partial
  put_partial=$(curl -s -w "\n%{http_code}" -X PUT "$base/books/$patch_id" \
    -H "Content-Type: application/json" \
    -d '{"title":"Only Title No Author"}' 2>/dev/null) || true
  local put_partial_code
  put_partial_code=$(echo "$put_partial" | tail -1)
  if [[ "$put_partial_code" == "400" ]] || [[ "$put_partial_code" == "422" ]]; then
    score=$((score + 3))
  fi

  # POST /books — verify createdAt field is auto-populated (3 pts)
  local has_created_at
  has_created_at=$(echo "$create_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print('yes' if data.get('createdAt') or data.get('created_at') else 'no')
except:
    print('no')
" 2>/dev/null || true)
  [[ "$has_created_at" == "yes" ]] && score=$((score + 3))

  # ---------- HARDER CHECKS (22 points) ----------

  # PAGINATION: GET /books?page=1&limit=2 should return paginated results (8 pts)
  # First, create several books so we have enough data
  for _i in 1 2 3 4 5; do
    curl -s -X POST "$base/books" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"Paginated Book $_i\",\"author\":\"Author $_i\"}" 2>/dev/null >/dev/null || true
  done
  local page_resp
  page_resp=$(curl -s -w "\n%{http_code}" "$base/books?page=1&limit=2" 2>/dev/null) || true
  local page_code
  page_code=$(echo "$page_resp" | tail -1)
  local page_body
  page_body=$(echo "$page_resp" | sed '$d')
  if [[ "$page_code" == "200" ]]; then
    local page_ok
    page_ok=$(echo "$page_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    # Response should be an object with items array and metadata (not a bare array)
    if isinstance(data, dict):
        items = data.get('books', data.get('data', data.get('items', [])))
        total = data.get('total', data.get('totalCount', data.get('count', 0)))
        page = data.get('page', data.get('currentPage', 0))
        # Paginated: items count should be <= limit (2), total should be > 2, and metadata present
        if isinstance(items, list) and len(items) <= 2 and total > 2:
            print('yes')
        else:
            print('no')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null || true)
    [[ "$page_ok" == "yes" ]] && score=$((score + 8))
  fi

  # SEARCH/FILTER: GET /books?author=X should filter results (7 pts)
  # Create a book with a unique author to search for
  curl -s -X POST "$base/books" \
    -H "Content-Type: application/json" \
    -d '{"title":"Searchable Book","author":"Unique Searchable Author"}' 2>/dev/null >/dev/null || true
  local search_resp
  search_resp=$(curl -s -w "\n%{http_code}" "$base/books?author=Unique%20Searchable%20Author" 2>/dev/null) || true
  local search_code
  search_code=$(echo "$search_resp" | tail -1)
  local search_body
  search_body=$(echo "$search_resp" | sed '$d')
  if [[ "$search_code" == "200" ]]; then
    local search_ok
    search_ok=$(echo "$search_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    items = data if isinstance(data, list) else data.get('books', data.get('data', data.get('items', [])))
    # All returned items should have the searched author, and there should be at least 1
    if isinstance(items, list) and len(items) >= 1:
        all_match = all('Unique Searchable Author' in str(b.get('author','')) for b in items)
        print('yes' if all_match else 'no')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null || true)
    [[ "$search_ok" == "yes" ]] && score=$((score + 7))
  fi

  # IDEMPOTENT PUT: PUT with same data twice should return same result, not create duplicates (7 pts)
  local idem_create
  idem_create=$(curl -s -w "\n%{http_code}" -X POST "$base/books" \
    -H "Content-Type: application/json" \
    -d '{"title":"Idempotent Test","author":"Idem Author"}' 2>/dev/null) || true
  local idem_id
  idem_id=$(echo "$idem_create" | sed '$d' | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print(data.get('id', ''))
except:
    print('')
" 2>/dev/null || true)
  if [[ -n "$idem_id" && "$idem_id" != "None" && "$idem_id" != "" ]]; then
    local idem_data='{"title":"Idempotent Updated","author":"Idem Author Updated"}'
    # PUT twice with the same data
    curl -s -X PUT "$base/books/$idem_id" \
      -H "Content-Type: application/json" \
      -d "$idem_data" 2>/dev/null >/dev/null || true
    local idem_put2
    idem_put2=$(curl -s -w "\n%{http_code}" -X PUT "$base/books/$idem_id" \
      -H "Content-Type: application/json" \
      -d "$idem_data" 2>/dev/null) || true
    local idem_put2_code
    idem_put2_code=$(echo "$idem_put2" | tail -1)
    # After two PUTs, GET the book and verify it's correct (not duplicated)
    local idem_get
    idem_get=$(curl -s "$base/books/$idem_id" 2>/dev/null) || true
    local idem_ok
    idem_ok=$(echo "$idem_get" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print('yes' if data.get('title') == 'Idempotent Updated' else 'no')
except:
    print('no')
" 2>/dev/null || true)
    # Also check the list doesn't have duplicates of this book
    local idem_list
    idem_list=$(curl -s "$base/books" 2>/dev/null) || true
    local idem_no_dup
    idem_no_dup=$(echo "$idem_list" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    items = data if isinstance(data, list) else data.get('books', data.get('data', data.get('items', [])))
    count = sum(1 for b in items if b.get('title') == 'Idempotent Updated')
    print('yes' if count == 1 else 'no')
except:
    print('no')
" 2>/dev/null || true)
    if [[ "$idem_put2_code" == "200" ]] && [[ "$idem_ok" == "yes" ]] && [[ "$idem_no_dup" == "yes" ]]; then
      score=$((score + 7))
    fi
  fi

  # Cleanup — kill server and don't block on wait
  kill "$server_pid" 2>/dev/null
  sleep 0.5
  kill -9 "$server_pid" 2>/dev/null || true

  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  # --- Test files exist (15 pts) ---
  local test_files
  test_files=$(find "$ws" -maxdepth 4 \( \
    -name "*.test.*" -o -name "*.spec.*" -o \
    -name "test.js" -o -name "test_*.js" -o -name "tests.js" \
  \) ! -path "*/node_modules/*" 2>/dev/null || true)
  local _test_dir_files
  _test_dir_files=$(find "$ws" -maxdepth 4 \( -path "*/__tests__/*.js" -o -path "*/test/*.js" -o -path "*/tests/*.js" \) 2>/dev/null | grep -v node_modules) || true
  [[ -n "$_test_dir_files" ]] && test_files=$(printf '%s\n%s' "$test_files" "$_test_dir_files" | sort -u | grep -v '^$')
  local test_count
  test_count=$(echo "$test_files" | grep -c '.' 2>/dev/null || true)
  [[ $test_count -gt 0 ]] && score=$((score + 15))

  # --- Tests actually pass (25 pts) ---
  local test_output
  test_output=$(cd "$ws" && npm test 2>&1 | tail -40) || true
  local tests_pass
  tests_pass=$(echo "$test_output" | python3 -c "
import sys, re
text = sys.stdin.read()
# Look for common pass indicators
if re.search(r'(pass|PASS|✓|Tests:.*passed|test suites.*passed)', text, re.IGNORECASE):
    # Also check there's no failure
    if not re.search(r'(FAIL(?!\s+0)|fail(?:ed|ure)|ERR!)', text, re.IGNORECASE):
        print('yes')
    else:
        print('no')
else:
    print('no')
" 2>/dev/null || true)
  [[ "$tests_pass" == "yes" ]] && score=$((score + 25))

  # --- Test count > 5 (5 pts) and > 15 (additional 10 pts) ---
  local individual_tests
  individual_tests=$(echo "$test_output" | python3 -c "
import sys, re
text = sys.stdin.read()
# Jest: 'Tests: X passed'
m = re.search(r'Tests:\s+(\d+)\s+passed', text)
if m:
    print(m.group(1))
    exit()
# Mocha/tap: count lines with checkmarks or 'passing'
m = re.search(r'(\d+)\s+passing', text)
if m:
    print(m.group(1))
    exit()
# Count checkmarks or 'PASS' lines
count = len(re.findall(r'[✓✔]|PASS\s', text))
print(count if count > 0 else 0)
" 2>/dev/null || true)
  [[ -n "$individual_tests" ]] && [[ "$individual_tests" -gt 5 ]] 2>/dev/null && score=$((score + 5))
  [[ -n "$individual_tests" ]] && [[ "$individual_tests" -gt 15 ]] 2>/dev/null && score=$((score + 10))

  # --- Tests cover ALL HTTP methods: GET, POST, PUT, DELETE (15 pts) ---
  local methods_covered=0
  if [[ -n "$test_files" ]]; then
    for method in "GET" "POST" "PUT" "DELETE"; do
      local method_lower
      method_lower=$(echo "$method" | tr '[:upper:]' '[:lower:]')
      local found
      found=$(echo "$test_files" | while read -r f; do
        [[ -z "$f" ]] && continue
        if grep -qliE "\b${method}\b|\b${method_lower}\b|\.${method_lower}\(|\.${method}\(" "$f" 2>/dev/null; then
          echo "found"
          break
        fi
      done) || true
      [[ "$found" == "found" ]] && methods_covered=$((methods_covered + 1))
    done
  fi
  # Require all 4 methods
  [[ $methods_covered -ge 4 ]] && score=$((score + 15))

  # --- Tests include error/edge cases: 400, 404, validation (15 pts) ---
  local error_cases=0
  if [[ -n "$test_files" ]]; then
    # Check for 400 status tests
    local has_400
    has_400=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlE "400|bad.?request|invalid|validation" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_400" == "found" ]] && error_cases=$((error_cases + 1))

    # Check for 404 status tests
    local has_404
    has_404=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlE "404|not.?found" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_404" == "found" ]] && error_cases=$((error_cases + 1))

    # Check for validation-related tests (isbn, required, missing)
    local has_validation
    has_validation=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "isbn|required|missing|invalid|validat" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_validation" == "found" ]] && error_cases=$((error_cases + 1))
  fi
  # Need at least 2 of 3 error case categories
  [[ $error_cases -ge 2 ]] && score=$((score + 10))
  [[ $error_cases -ge 3 ]] && score=$((score + 5))

  # --- Uses proper HTTP test library (supertest, axios, node-fetch, etc.) (10 pts) ---
  local has_http_client
  has_http_client=$(echo "$test_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "supertest|request\(app\)|axios|node-fetch|got\(|chai-http|pactum" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_http_client" == "found" ]] && score=$((score + 10))

  # --- Bonus: tests are well-structured with describe/it blocks (5 pts) ---
  local has_structure
  has_structure=$(echo "$test_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlE "describe\(|it\(|test\(" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_structure" == "found" ]] && score=$((score + 5))

  # --- HARDER: Tests include concurrent request patterns (10 pts) ---
  # Check for Promise.all, Promise.allSettled, async parallel patterns in tests
  local has_concurrent
  has_concurrent=$(echo "$test_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "Promise\.all|Promise\.allSettled|concurrent|parallel|simultaneous|Promise\.race|async.*map" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_concurrent" == "found" ]] && score=$((score + 10))

  # Cap at 100
  [[ $score -gt 100 ]] && score=100

  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=0

  local src_files
  src_files=$(find "$ws" -maxdepth 4 -name "*.js" ! -path "*/node_modules/*" ! -name "*.test.*" ! -name "*.spec.*" 2>/dev/null || true)

  # --- Input validation present (12 pts) ---
  local has_validation
  has_validation=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlE "required|!.*title|!.*author|\.trim\(\)|\.length|validat" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_validation" == "found" ]] && score=$((score + 12))

  # --- Error handling middleware or try/catch (12 pts) ---
  local has_error_handling
  has_error_handling=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlE "catch|error.*handler|err.*req.*res|next\(err|app\.use\(.*err" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_error_handling" == "found" ]] && score=$((score + 12))

  # --- Proper status codes in source (12 pts) ---
  local status_count=0
  for code_pattern in "status(201" "status(400" "status(404" "status(204"; do
    local has_code
    has_code=$(echo "$src_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -ql "$code_pattern" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_code" == "found" ]] && status_count=$((status_count + 1))
  done
  # Need at least 3 of 4 status codes
  [[ $status_count -ge 3 ]] && score=$((score + 12))

  # --- JSON error responses with meaningful messages (12 pts) ---
  local has_json_errors
  has_json_errors=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlE 'json\(\s*\{.*error|json\(\s*\{.*message|\.json\(\{' "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_json_errors" == "found" ]] && score=$((score + 12))

  # --- IDs are UUIDs (not sequential integers) (10 pts) ---
  local has_uuid
  has_uuid=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "uuid|uuidv4|randomUUID|crypto\.random" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_uuid" == "found" ]] && score=$((score + 10))

  # --- CORS handling (10 pts) ---
  local has_cors
  has_cors=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "cors|Access-Control-Allow" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_cors" == "found" ]] && score=$((score + 10))

  # Also check package.json for cors dependency
  if [[ "$has_cors" != "found" && -f "$ws/package.json" ]]; then
    local pkg_cors
    pkg_cors=$(python3 -c "
import json, sys
try:
    data = json.load(open('$ws/package.json'))
    deps = {**data.get('dependencies',{}), **data.get('devDependencies',{})}
    print('found' if 'cors' in deps else '')
except:
    print('')
" 2>/dev/null || true)
    [[ "$pkg_cors" == "found" ]] && score=$((score + 10))
  fi

  # --- Rate limiting or request size limits (10 pts) ---
  local has_limits
  has_limits=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "rate.?limit|express.?rate|express\.json\(\s*\{.*limit|body.?parser.*limit|helmet" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_limits" == "found" ]] && score=$((score + 10))

  # Also check package.json for rate-limit or helmet dependency
  if [[ "$has_limits" != "found" && -f "$ws/package.json" ]]; then
    local pkg_limits
    pkg_limits=$(python3 -c "
import json, sys
try:
    data = json.load(open('$ws/package.json'))
    deps = {**data.get('dependencies',{}), **data.get('devDependencies',{})}
    matches = [k for k in deps if 'rate' in k.lower() or 'limit' in k.lower() or 'helmet' in k.lower()]
    print('found' if matches else '')
except:
    print('')
" 2>/dev/null || true)
    [[ "$pkg_limits" == "found" ]] && score=$((score + 10))
  fi

  # --- Graceful server shutdown / process handling (6 pts) ---
  local has_graceful
  has_graceful=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlE "SIGTERM|SIGINT|process\.on|graceful|server\.close" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_graceful" == "found" ]] && score=$((score + 6))

  # --- ISBN validation logic specifically (6 pts) ---
  local has_isbn_validation
  has_isbn_validation=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    # Check for ISBN validation: regex with digits, length checks, or explicit validation
    if grep -qlEi "isbn.*length|isbn.*[0-9]{10}|isbn.*regex|isbn.*match|isbn.*valid|isbn.*test" "$f" 2>/dev/null; then
      echo "found"; break
    fi
    # Also check for ISBN digit patterns (ERE: \d not portable, use [0-9])
    if grep -qlE '[0-9]{10}.*isbn|isbn.*[0-9]{10}|[0-9]{13}.*isbn|isbn.*[0-9]{13}' "$f" 2>/dev/null; then
      echo "found"; break
    fi
    # Check for isbn-related validation on a nearby line (grep -A2)
    if grep -qE '^\d\{10\}|\\d\{10\}|\\d\{13\}' "$f" 2>/dev/null && grep -qi "isbn" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_isbn_validation" == "found" ]] && score=$((score + 6))

  # --- Module structure: routes separated from main file (8 pts) ---
  local route_files
  route_files=$(find "$ws" -maxdepth 4 -name "*.js" ! -path "*/node_modules/*" ! -name "*.test.*" ! -name "*.spec.*" 2>/dev/null | while read -r f; do
    if grep -qlE "router\.|Router\(\)|module\.exports.*router" "$f" 2>/dev/null; then
      echo "$f"
    fi
  done || true)
  local main_separate
  main_separate=$(echo "$route_files" | grep -c '.' 2>/dev/null || true)
  [[ "$main_separate" -ge 1 ]] && score=$((score + 8))

  # --- HARDER: Request logging middleware (8 pts) ---
  # Check for morgan, winston, pino, or custom request logging middleware
  local has_logging
  has_logging=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "morgan|winston|pino|bunyan|req\.method.*req\.url|console\.log.*req\.|request.*log|logger" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  if [[ "$has_logging" != "found" && -f "$ws/package.json" ]]; then
    local pkg_logging
    pkg_logging=$(python3 -c "
import json
try:
    data = json.load(open('$ws/package.json'))
    deps = {**data.get('dependencies',{}), **data.get('devDependencies',{})}
    matches = [k for k in deps if k in ('morgan','winston','pino','bunyan')]
    print('found' if matches else '')
except:
    print('')
" 2>/dev/null || true)
    [[ "$pkg_logging" == "found" ]] && has_logging="found"
  fi
  [[ "$has_logging" == "found" ]] && score=$((score + 8))

  # --- HARDER: Health check endpoint (8 pts) ---
  # Actually test that GET /health or /healthz returns 200
  # Need a running server for this — start one
  local hc_port=0
  hc_port=$(_find_free_port)
  local hc_entry=""
  local hc_pkg_main
  hc_pkg_main=$(cd "$ws" && node -e "try{console.log(require('./package.json').main||'')}catch(e){}" 2>/dev/null || true)
  if [[ -n "$hc_pkg_main" && -f "$ws/$hc_pkg_main" ]]; then
    hc_entry="$hc_pkg_main"
  else
    for f in "server.js" "src/server.js" "index.js" "src/index.js" "app.js" "src/app.js"; do
      [[ -f "$ws/$f" ]] && hc_entry="$f" && break
    done
  fi
  if [[ -n "$hc_entry" ]]; then
    local hc_pid=""
    (cd "$ws" && exec env PORT="$hc_port" node "$hc_entry") &>/dev/null &
    hc_pid=$!
    sleep 2
    if kill -0 "$hc_pid" 2>/dev/null; then
      local hc_base="http://localhost:$hc_port"
      local hc_resp=""
      # Try /health first, then /healthz
      hc_resp=$(curl -s -w "\n%{http_code}" "$hc_base/health" 2>/dev/null) || true
      local hc_code
      hc_code=$(echo "$hc_resp" | tail -1)
      if [[ "$hc_code" != "200" ]]; then
        hc_resp=$(curl -s -w "\n%{http_code}" "$hc_base/healthz" 2>/dev/null) || true
        hc_code=$(echo "$hc_resp" | tail -1)
      fi
      [[ "$hc_code" == "200" ]] && score=$((score + 8))
      kill "$hc_pid" 2>/dev/null
      sleep 0.3
      kill -9 "$hc_pid" 2>/dev/null || true
    else
      kill -9 "$hc_pid" 2>/dev/null || true
    fi
  fi

  # Cap at 100
  [[ $score -gt 100 ]] && score=100

  echo "$score"
}

# Helper to find a free port
_find_free_port() {
  python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('', 0))
print(s.getsockname()[1])
s.close()
"
}

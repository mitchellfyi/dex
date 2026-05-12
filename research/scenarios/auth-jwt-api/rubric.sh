#!/usr/bin/env bash
# Rubric for: auth-jwt-api
# Hardened rubric — target score ~60-75 for typical implementations.

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

_kill_auth_server() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0
  kill -- -"$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  sleep 0.5
  kill -9 -- -"$pid" 2>/dev/null || true
  kill -9 "$pid" 2>/dev/null || true
}

rubric_correctness() {
  local ws="$1"
  local score=0

  # --- package.json exists (2 pts) ---
  [[ -f "$ws/package.json" ]] && score=$((score + 2))

  # --- npm install works (3 pts) ---
  if ! (cd "$ws" && npm install --silent >/dev/null 2>&1); then
    echo "$score"; return
  fi
  score=$((score + 3))

  # Find the server entry point
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

  # Start server in background
  local port=0
  port=$(_find_free_port)

  (cd "$ws" && exec env PORT="$port" JWT_SECRET="test-rubric-secret-key-12345" node "$entry") &>/dev/null &
  local server_pid=$!
  trap '_kill_auth_server "$server_pid"; trap - RETURN' RETURN
  sleep 2

  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "$score"; return
  fi
  score=$((score + 5))  # Server starts and responds (5 pts)

  local base="http://localhost:$port"

  # ========== REGISTRATION (21 pts) ==========

  # POST /auth/register creates user, returns 201 (8 pts)
  local reg_resp
  reg_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/register" \
    -H "Content-Type: application/json" \
    -d '{"email":"testuser@example.com","password":"TestPass1","name":"Test User"}' 2>/dev/null) || true
  local reg_code
  reg_code=$(echo "$reg_resp" | tail -1)
  if [[ "$reg_code" == "201" ]] || [[ "$reg_code" == "200" ]]; then
    score=$((score + 8))
  fi

  # Password is hashed — grep source for bcrypt/argon2/scrypt (5 pts)
  local src_files
  src_files=$(find "$ws" -maxdepth 4 -name "*.js" -o -name "*.ts" | grep -v node_modules 2>/dev/null || true)
  local has_hashing="no"
  if [[ -n "$src_files" ]]; then
    has_hashing=$(echo "$src_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "bcrypt|argon2|scrypt|pbkdf2" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
  fi
  [[ "$has_hashing" == "found" ]] && score=$((score + 5))

  # Duplicate email registration returns 409 (5 pts)
  local dup_resp
  dup_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/register" \
    -H "Content-Type: application/json" \
    -d '{"email":"testuser@example.com","password":"TestPass1","name":"Duplicate User"}' 2>/dev/null) || true
  local dup_code
  dup_code=$(echo "$dup_resp" | tail -1)
  [[ "$dup_code" == "409" ]] && score=$((score + 5))

  # Password validation: reject weak passwords (8 pts)
  local pw_score=0
  # Too short
  local short_resp
  short_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/register" \
    -H "Content-Type: application/json" \
    -d '{"email":"short@example.com","password":"Ab1","name":"Short Pass"}' 2>/dev/null) || true
  local short_code
  short_code=$(echo "$short_resp" | tail -1)
  [[ "$short_code" == "400" ]] || [[ "$short_code" == "422" ]] && pw_score=$((pw_score + 1))

  # No uppercase
  local nocase_resp
  nocase_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/register" \
    -H "Content-Type: application/json" \
    -d '{"email":"nocase@example.com","password":"alllowercase1","name":"No Case"}' 2>/dev/null) || true
  local nocase_code
  nocase_code=$(echo "$nocase_resp" | tail -1)
  [[ "$nocase_code" == "400" ]] || [[ "$nocase_code" == "422" ]] && pw_score=$((pw_score + 1))

  # No number
  local nonum_resp
  nonum_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/register" \
    -H "Content-Type: application/json" \
    -d '{"email":"nonum@example.com","password":"NoNumberHere","name":"No Num"}' 2>/dev/null) || true
  local nonum_code
  nonum_code=$(echo "$nonum_resp" | tail -1)
  [[ "$nonum_code" == "400" ]] || [[ "$nonum_code" == "422" ]] && pw_score=$((pw_score + 1))

  # Award partial credit: 3 pts for 1 check, 5 for 2, 8 for all 3
  if [[ $pw_score -ge 3 ]]; then
    score=$((score + 8))
  elif [[ $pw_score -ge 2 ]]; then
    score=$((score + 5))
  elif [[ $pw_score -ge 1 ]]; then
    score=$((score + 3))
  fi

  # ========== LOGIN (13 pts) ==========

  # POST /auth/login returns JWT token (8 pts)
  local login_resp
  login_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"testuser@example.com","password":"TestPass1"}' 2>/dev/null) || true
  local login_code
  login_code=$(echo "$login_resp" | tail -1)
  local login_body
  login_body=$(echo "$login_resp" | sed '$d')
  local access_token=""
  local refresh_token=""

  if [[ "$login_code" == "200" ]]; then
    access_token=$(echo "$login_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    # Try common field names for access token
    for key in ('accessToken', 'access_token', 'token'):
        v = data.get(key, '')
        if v and '.' in str(v):
            print(v)
            exit()
    print('')
except:
    print('')
" 2>/dev/null || true)
    refresh_token=$(echo "$login_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    for key in ('refreshToken', 'refresh_token'):
        v = data.get(key, '')
        if v:
            print(v)
            exit()
    print('')
except:
    print('')
" 2>/dev/null || true)
    [[ -n "$access_token" ]] && score=$((score + 8))
  fi

  # Invalid login returns 401 (5 pts)
  local bad_login_resp
  bad_login_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"testuser@example.com","password":"WrongPassword1"}' 2>/dev/null) || true
  local bad_login_code
  bad_login_code=$(echo "$bad_login_resp" | tail -1)
  [[ "$bad_login_code" == "401" ]] && score=$((score + 5))

  # ========== PROTECTED ROUTES (18 pts) ==========

  # GET /me with valid token returns user data (8 pts)
  if [[ -n "$access_token" ]]; then
    local me_resp
    me_resp=$(curl -s -w "\n%{http_code}" "$base/me" \
      -H "Authorization: Bearer $access_token" 2>/dev/null) || true
    local me_code
    me_code=$(echo "$me_resp" | tail -1)
    local me_body
    me_body=$(echo "$me_resp" | sed '$d')
    if [[ "$me_code" == "200" ]]; then
      local has_email
      has_email=$(echo "$me_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print('yes' if data.get('email') == 'testuser@example.com' else 'no')
except:
    print('no')
" 2>/dev/null || true)
      [[ "$has_email" == "yes" ]] && score=$((score + 8))
    fi
  fi

  # GET /me without token returns 401 (5 pts)
  local noauth_resp
  noauth_resp=$(curl -s -w "\n%{http_code}" "$base/me" 2>/dev/null) || true
  local noauth_code
  noauth_code=$(echo "$noauth_resp" | tail -1)
  [[ "$noauth_code" == "401" ]] && score=$((score + 5))

  # Token contains user ID/email in payload — decode and verify (5 pts)
  if [[ -n "$access_token" ]]; then
    local payload_check
    payload_check=$(ACCESS_TOKEN="$access_token" node -e "
try {
  const t=process.env.ACCESS_TOKEN;
  const payload=JSON.parse(Buffer.from(t.split('.')[1],'base64url').toString());
  const hasId = payload.id || payload.userId || payload.user_id || payload.sub;
  const hasEmail = payload.email;
  console.log(hasId && hasEmail ? 'yes' : 'no');
} catch(e) { console.log('no'); }
" 2>/dev/null || true)
    [[ "$payload_check" == "yes" ]] && score=$((score + 5))
  fi

  # ========== REFRESH TOKEN (8 pts) ==========

  # POST /auth/refresh returns new access token (8 pts)
  if [[ -n "$refresh_token" ]]; then
    local refresh_resp
    refresh_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/refresh" \
      -H "Content-Type: application/json" \
      -d "{\"refreshToken\":\"$refresh_token\"}" 2>/dev/null) || true
    local refresh_code
    refresh_code=$(echo "$refresh_resp" | tail -1)
    local refresh_body
    refresh_body=$(echo "$refresh_resp" | sed '$d')
    if [[ "$refresh_code" == "200" ]]; then
      local new_token
      new_token=$(echo "$refresh_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    for key in ('accessToken', 'access_token', 'token'):
        v = data.get(key, '')
        if v and '.' in str(v):
            print(v)
            exit()
    print('')
except:
    print('')
" 2>/dev/null || true)
      [[ -n "$new_token" ]] && score=$((score + 8))
    fi
    # Also try refresh_token field name
    if [[ "$refresh_code" != "200" ]]; then
      refresh_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/refresh" \
        -H "Content-Type: application/json" \
        -d "{\"refresh_token\":\"$refresh_token\"}" 2>/dev/null) || true
      refresh_code=$(echo "$refresh_resp" | tail -1)
      refresh_body=$(echo "$refresh_resp" | sed '$d')
      if [[ "$refresh_code" == "200" ]]; then
        local new_token2
        new_token2=$(echo "$refresh_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    for key in ('accessToken', 'access_token', 'token'):
        v = data.get(key, '')
        if v and '.' in str(v):
            print(v)
            exit()
    print('')
except:
    print('')
" 2>/dev/null || true)
        [[ -n "$new_token2" ]] && score=$((score + 8))
      fi
    fi
  fi

  # ========== RBAC (18 pts) ==========

  # Register an admin user — try seeded admin first, then register + promote
  local admin_token=""

  # Try logging in as seeded admin (common patterns)
  for admin_email in "admin@example.com" "admin@admin.com"; do
    for admin_pass in "Admin123!" "Admin1234" "admin123" "Password1" "Admin123"; do
      local admin_login_resp
      admin_login_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$admin_email\",\"password\":\"$admin_pass\"}" 2>/dev/null) || true
      local admin_login_code
      admin_login_code=$(echo "$admin_login_resp" | tail -1)
      if [[ "$admin_login_code" == "200" ]]; then
        local admin_login_body
        admin_login_body=$(echo "$admin_login_resp" | sed '$d')
        admin_token=$(echo "$admin_login_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    for key in ('accessToken', 'access_token', 'token'):
        v = data.get(key, '')
        if v and '.' in str(v):
            print(v)
            exit()
    print('')
except:
    print('')
" 2>/dev/null || true)
        # Verify this is actually an admin token
        if [[ -n "$admin_token" ]]; then
          local is_admin
          is_admin=$(node -e "
try {
  const t='$admin_token';
  const payload=JSON.parse(Buffer.from(t.split('.')[1],'base64url').toString());
  console.log(payload.role === 'admin' ? 'yes' : 'no');
} catch(e) { console.log('no'); }
" 2>/dev/null || true)
          [[ "$is_admin" == "yes" ]] && break 2
          admin_token=""
        fi
      fi
    done
  done

  # If no seeded admin, try registering with admin role (some implementations allow it)
  if [[ -z "$admin_token" ]]; then
    local admin_reg_resp
    admin_reg_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/register" \
      -H "Content-Type: application/json" \
      -d '{"email":"rubricadmin@example.com","password":"AdminPass1","name":"Rubric Admin","role":"admin"}' 2>/dev/null) || true
    local admin_reg_code
    admin_reg_code=$(echo "$admin_reg_resp" | tail -1)
    if [[ "$admin_reg_code" == "201" ]] || [[ "$admin_reg_code" == "200" ]]; then
      local admin_login2_resp
      admin_login2_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/login" \
        -H "Content-Type: application/json" \
        -d '{"email":"rubricadmin@example.com","password":"AdminPass1"}' 2>/dev/null) || true
      local admin_login2_code
      admin_login2_code=$(echo "$admin_login2_resp" | tail -1)
      if [[ "$admin_login2_code" == "200" ]]; then
        local admin_login2_body
        admin_login2_body=$(echo "$admin_login2_resp" | sed '$d')
        admin_token=$(echo "$admin_login2_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    for key in ('accessToken', 'access_token', 'token'):
        v = data.get(key, '')
        if v and '.' in str(v):
            print(v)
            exit()
    print('')
except:
    print('')
" 2>/dev/null || true)
      fi
    fi
  fi

  # RBAC: admin can GET /users, regular user gets 403 (10 pts)
  if [[ -n "$admin_token" ]]; then
    # Admin GET /users should succeed
    local users_resp
    users_resp=$(curl -s -w "\n%{http_code}" "$base/users" \
      -H "Authorization: Bearer $admin_token" 2>/dev/null) || true
    local users_code
    users_code=$(echo "$users_resp" | tail -1)
    if [[ "$users_code" == "200" ]]; then
      score=$((score + 5))
    fi
  fi

  # Regular user GET /users should get 403
  if [[ -n "$access_token" ]]; then
    local reg_users_resp
    reg_users_resp=$(curl -s -w "\n%{http_code}" "$base/users" \
      -H "Authorization: Bearer $access_token" 2>/dev/null) || true
    local reg_users_code
    reg_users_code=$(echo "$reg_users_resp" | tail -1)
    [[ "$reg_users_code" == "403" ]] && score=$((score + 5))
  fi

  # RBAC: admin can DELETE /users/:id, regular user gets 403 (8 pts)
  # Register a sacrificial user to delete
  local sac_resp
  sac_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/auth/register" \
    -H "Content-Type: application/json" \
    -d '{"email":"sacrificial@example.com","password":"SacPass123","name":"Sacrificial User"}' 2>/dev/null) || true
  local sac_body
  sac_body=$(echo "$sac_resp" | sed '$d')
  local sac_id
  sac_id=$(echo "$sac_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    for key in ('id', 'userId', 'user_id', '_id'):
        v = data.get(key, '') or (data.get('user', {}) or {}).get(key, '')
        if v:
            print(v)
            exit()
    print('')
except:
    print('')
" 2>/dev/null || true)
  [[ -z "$sac_id" || "$sac_id" == "None" ]] && sac_id="999"

  # Regular user DELETE should get 403
  if [[ -n "$access_token" ]]; then
    local reg_del_resp
    reg_del_resp=$(curl -s -w "\n%{http_code}" -X DELETE "$base/users/$sac_id" \
      -H "Authorization: Bearer $access_token" 2>/dev/null) || true
    local reg_del_code
    reg_del_code=$(echo "$reg_del_resp" | tail -1)
    [[ "$reg_del_code" == "403" ]] && score=$((score + 5))
  fi

  # Admin DELETE should succeed
  if [[ -n "$admin_token" && -n "$sac_id" && "$sac_id" != "None" ]]; then
    local admin_del_resp
    admin_del_resp=$(curl -s -w "\n%{http_code}" -X DELETE "$base/users/$sac_id" \
      -H "Authorization: Bearer $admin_token" 2>/dev/null) || true
    local admin_del_code
    admin_del_code=$(echo "$admin_del_resp" | tail -1)
    if [[ "$admin_del_code" == "200" ]] || [[ "$admin_del_code" == "204" ]]; then
      score=$((score + 5))
    fi
  fi

  # ========== PUT /me (5 pts) ==========
  if [[ -n "$access_token" ]]; then
    local update_resp
    update_resp=$(curl -s -w "\n%{http_code}" -X PUT "$base/me" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $access_token" \
      -d '{"name":"Updated Name"}' 2>/dev/null) || true
    local update_code
    update_code=$(echo "$update_resp" | tail -1)
    [[ "$update_code" == "200" ]] && score=$((score + 5))
  fi

  # Cleanup — try process group first, then the direct server PID.
  _kill_auth_server "$server_pid"
  trap - RETURN

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
  test_output=$(cd "$ws" && npm test 2>&1 | tail -50) || true
  local tests_pass
  tests_pass=$(echo "$test_output" | python3 -c "
import sys, re
text = sys.stdin.read()
if re.search(r'(pass|PASS|✓|Tests:.*passed|test suites.*passed)', text, re.IGNORECASE):
    if not re.search(r'(FAIL(?!\s+0)|fail(?:ed|ure)|ERR!)', text, re.IGNORECASE):
        print('yes')
    else:
        print('no')
else:
    print('no')
" 2>/dev/null || true)
  [[ "$tests_pass" == "yes" ]] && score=$((score + 25))

  # --- Tests cover auth flow: register -> login -> access protected route (15 pts) ---
  local has_auth_flow=0
  if [[ -n "$test_files" ]]; then
    local has_register
    has_register=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "register|signup|sign.up" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_register" == "found" ]] && has_auth_flow=$((has_auth_flow + 1))

    local has_login
    has_login=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "login|sign.in|authenticate" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_login" == "found" ]] && has_auth_flow=$((has_auth_flow + 1))

    local has_protected
    has_protected=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "protected|/me|bearer|authorization|authenticated" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_protected" == "found" ]] && has_auth_flow=$((has_auth_flow + 1))
  fi
  # Need all 3 for full credit, 2 for partial
  [[ $has_auth_flow -ge 3 ]] && score=$((score + 15))
  [[ $has_auth_flow -eq 2 ]] && score=$((score + 8))

  # --- Tests cover invalid credentials (10 pts) ---
  local has_invalid_creds
  if [[ -n "$test_files" ]]; then
    has_invalid_creds=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "invalid.*password|wrong.*password|invalid.*credential|401|unauthorized|incorrect" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
  fi
  [[ "$has_invalid_creds" == "found" ]] && score=$((score + 10))

  # --- Tests cover token expiry/invalid tokens (10 pts) ---
  local has_token_tests
  if [[ -n "$test_files" ]]; then
    has_token_tests=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "expir|invalid.*token|malformed.*token|no.*token|without.*token|expired" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
  fi
  [[ "$has_token_tests" == "found" ]] && score=$((score + 10))

  # --- Tests cover RBAC: admin vs regular (10 pts) ---
  local has_rbac_tests
  if [[ -n "$test_files" ]]; then
    has_rbac_tests=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "admin|role|rbac|403|forbidden|unauthorized.*user|regular.*user" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
  fi
  [[ "$has_rbac_tests" == "found" ]] && score=$((score + 10))

  # --- Test count > 10 (5 pts), > 20 (additional 5 pts) ---
  local individual_tests
  individual_tests=$(echo "$test_output" | python3 -c "
import sys, re
text = sys.stdin.read()
# Jest: 'Tests: X passed'
m = re.search(r'Tests:\s+(\d+)\s+passed', text)
if m:
    print(m.group(1))
    exit()
# Mocha/tap: count lines with 'passing'
m = re.search(r'(\d+)\s+passing', text)
if m:
    print(m.group(1))
    exit()
# Count checkmarks or 'PASS' lines
count = len(re.findall(r'[✓✔]|PASS\s', text))
print(count if count > 0 else 0)
" 2>/dev/null || true)
  [[ -n "$individual_tests" ]] && [[ "$individual_tests" -gt 10 ]] 2>/dev/null && score=$((score + 5))
  [[ -n "$individual_tests" ]] && [[ "$individual_tests" -gt 20 ]] 2>/dev/null && score=$((score + 5))

  # --- Uses supertest or similar HTTP testing library (5 pts) ---
  local has_http_client
  if [[ -n "$test_files" ]]; then
    has_http_client=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "supertest|request\(app\)|axios|node-fetch|chai-http|pactum" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
  fi
  [[ "$has_http_client" == "found" ]] && score=$((score + 5))

  # Cap at 100
  [[ $score -gt 100 ]] && score=100

  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=0

  local src_files
  src_files=$(find "$ws" -maxdepth 4 -name "*.js" -o -name "*.ts" | grep -v node_modules | grep -vE '\.(test|spec)\.' 2>/dev/null || true)

  # --- Has password hashing: bcrypt/argon2/scrypt (15 pts) ---
  local has_hashing
  has_hashing=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "bcrypt|argon2|scrypt|pbkdf2" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_hashing" == "found" ]] && score=$((score + 15))

  # --- JWT has expiration set (10 pts) ---
  local has_expiry
  has_expiry=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "expiresIn|expires_in|exp:|\.exp\b" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_expiry" == "found" ]] && score=$((score + 10))

  # --- No secrets/keys hardcoded — uses env vars or config (10 pts) ---
  local uses_env
  uses_env=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlE "process\.env\.(JWT_SECRET|SECRET|TOKEN_SECRET)" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$uses_env" == "found" ]] && score=$((score + 10))

  # --- Has error handling middleware (10 pts) ---
  local has_error_mw
  has_error_mw=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlE "err.*req.*res.*next|error.*handler|app\.use\(.*err" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_error_mw" == "found" ]] && score=$((score + 10))

  # --- Input validation on registration: email format + password strength (10 pts) ---
  local has_email_validation
  has_email_validation=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "email.*@|email.*valid|email.*regex|email.*match|email.*format|email.*includes|validator.*email" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  local has_pw_validation
  has_pw_validation=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "password.*length|password.*min|password.*[A-Z]|password.*upper|password.*lower|password.*digit|password.*number|password.*regex|password.*match|password.*strong|password.*weak|password.*valid" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  local validation_score=0
  [[ "$has_email_validation" == "found" ]] && validation_score=$((validation_score + 1))
  [[ "$has_pw_validation" == "found" ]] && validation_score=$((validation_score + 1))
  [[ $validation_score -ge 2 ]] && score=$((score + 10))
  [[ $validation_score -eq 1 ]] && score=$((score + 5))

  # --- Rate limiting on auth endpoints (5 pts) ---
  local has_rate_limit
  has_rate_limit=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "rate.?limit|express.?rate|limiter|throttle" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  if [[ "$has_rate_limit" != "found" && -f "$ws/package.json" ]]; then
    local pkg_rate
    pkg_rate=$(python3 -c "
import json
try:
    data = json.load(open('$ws/package.json'))
    deps = {**data.get('dependencies',{}), **data.get('devDependencies',{})}
    matches = [k for k in deps if 'rate' in k.lower() or 'limit' in k.lower()]
    print('found' if matches else '')
except:
    print('')
" 2>/dev/null || true)
    [[ "$pkg_rate" == "found" ]] && has_rate_limit="found"
  fi
  [[ "$has_rate_limit" == "found" ]] && score=$((score + 5))

  # --- Token payload doesn't include password (10 pts) ---
  # Start server, login, decode token, check for password field
  local tp_port=0
  tp_port=$(_find_free_port)
  local tp_entry=""
  local tp_pkg_main
  tp_pkg_main=$(cd "$ws" && node -e "try{console.log(require('./package.json').main||'')}catch(e){}" 2>/dev/null || true)
  if [[ -n "$tp_pkg_main" && -f "$ws/$tp_pkg_main" ]]; then
    tp_entry="$tp_pkg_main"
  else
    for f in "server.js" "src/server.js" "index.js" "src/index.js" "app.js" "src/app.js"; do
      [[ -f "$ws/$f" ]] && tp_entry="$f" && break
    done
  fi
  if [[ -n "$tp_entry" ]]; then
    (cd "$ws" && exec env PORT="$tp_port" JWT_SECRET="test-rubric-secret-key-12345" node "$tp_entry") &>/dev/null &
    local tp_pid=$!
    sleep 2
    if kill -0 "$tp_pid" 2>/dev/null; then
      local tp_base="http://localhost:$tp_port"
      # Register a user and login
      curl -s -X POST "$tp_base/auth/register" \
        -H "Content-Type: application/json" \
        -d '{"email":"tokencheck@example.com","password":"TokenCheck1","name":"Token Check"}' 2>/dev/null >/dev/null || true
      local tp_login_resp
      tp_login_resp=$(curl -s "$tp_base/auth/login" \
        -X POST -H "Content-Type: application/json" \
        -d '{"email":"tokencheck@example.com","password":"TokenCheck1"}' 2>/dev/null) || true
      local tp_token
      tp_token=$(echo "$tp_login_resp" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    for key in ('accessToken', 'access_token', 'token'):
        v = data.get(key, '')
        if v and '.' in str(v):
            print(v)
            exit()
    print('')
except:
    print('')
" 2>/dev/null || true)
      if [[ -n "$tp_token" ]]; then
        local no_password
        no_password=$(node -e "
try {
  const t='$tp_token';
  const payload=JSON.parse(Buffer.from(t.split('.')[1],'base64url').toString());
  console.log(payload.password ? 'has_password' : 'clean');
} catch(e) { console.log('clean'); }
" 2>/dev/null || true)
        [[ "$no_password" == "clean" ]] && score=$((score + 10))
      fi
      kill "$tp_pid" 2>/dev/null; sleep 0.3; kill -9 "$tp_pid" 2>/dev/null || true
    else
      kill -9 "$tp_pid" 2>/dev/null || true
    fi
  fi

  # --- Proper HTTP status codes: 200, 201, 400, 401, 403, 404, 409 (10 pts) ---
  local status_count=0
  for code_pattern in "status(201" "status(400" "status(401" "status(403" "status(409"; do
    local has_code
    has_code=$(echo "$src_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -ql "$code_pattern" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_code" == "found" ]] && status_count=$((status_count + 1))
  done
  # Need at least 4 of 5 for full credit, 3 for partial
  [[ $status_count -ge 4 ]] && score=$((score + 10))
  [[ $status_count -eq 3 ]] && score=$((score + 6))

  # --- Clean code: const/let, no var, no console.log in source (5 pts) ---
  local has_var
  has_var=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlE '^\s*var\s' "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  local has_console_log
  has_console_log=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlE 'console\.log\(' "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  local clean_score=0
  [[ "$has_var" != "found" ]] && clean_score=$((clean_score + 1))
  [[ "$has_console_log" != "found" ]] && clean_score=$((clean_score + 1))
  [[ $clean_score -ge 2 ]] && score=$((score + 5))
  [[ $clean_score -eq 1 ]] && score=$((score + 3))

  # --- Separate route files (routes/auth.js, routes/users.js) (5 pts) ---
  local route_files
  route_files=$(find "$ws" -maxdepth 4 -name "*.js" -o -name "*.ts" | grep -v node_modules | grep -Ei "route|router" 2>/dev/null || true)
  local route_count
  route_count=$(echo "$route_files" | grep -c '.' 2>/dev/null || true)
  [[ $route_count -ge 2 ]] && score=$((score + 5))
  [[ $route_count -eq 1 ]] && score=$((score + 3))

  # --- Has middleware for auth verification (10 pts) ---
  local has_auth_mw
  has_auth_mw=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "verifyToken|authenticate|authMiddleware|requireAuth|isAuthenticated|checkAuth|protect|authorization.*bearer|jwt\.verify" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_auth_mw" == "found" ]] && score=$((score + 10))

  # Cap at 100
  [[ $score -gt 100 ]] && score=100

  echo "$score"
}

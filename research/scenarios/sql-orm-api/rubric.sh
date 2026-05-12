#!/usr/bin/env bash
# Rubric for: sql-orm-api
# Hardened rubric — target score ~55-70 for typical implementations.

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

  # --- Has sqlite dependency (5 pts) ---
  local has_sqlite=""
  if [[ -f "$ws/package.json" ]]; then
    has_sqlite=$(python3 -c "
import json
try:
    data = json.load(open('$ws/package.json'))
    deps = {**data.get('dependencies',{}), **data.get('devDependencies',{})}
    matches = [k for k in deps if k in ('better-sqlite3','sqlite3','sequelize','knex','prisma','typeorm','drizzle-orm')]
    print('found' if matches else '')
except:
    print('')
" 2>/dev/null || true)
  fi
  [[ "$has_sqlite" == "found" ]] && score=$((score + 5))

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

  # --- Database file gets created on startup (5 pts) ---
  # Remove any existing db file first, then start server and check it was created
  rm -f "$ws/data/blog.db" 2>/dev/null || true
  mkdir -p "$ws/data" 2>/dev/null || true

  local port=0
  port=$(_find_free_port)

  (cd "$ws" && exec env PORT="$port" node "$entry") &>/dev/null &
  local server_pid=$!
  sleep 3

  if [[ -f "$ws/data/blog.db" ]]; then
    score=$((score + 5))
  else
    # Also check common alternative paths
    local db_found=""
    db_found=$(find "$ws" -maxdepth 3 -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" 2>/dev/null | grep -v node_modules | head -1) || true
    [[ -n "$db_found" ]] && score=$((score + 3))
  fi

  # --- Server starts (5 pts) ---
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "$score"; return
  fi
  score=$((score + 5))

  local base="http://localhost:$port"

  # --- POST /users — create a user (5 pts) ---
  local user_resp
  user_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/users" \
    -H "Content-Type: application/json" \
    -d '{"username":"testuser","email":"test@example.com","bio":"A test user"}' 2>/dev/null) || true
  local user_code
  user_code=$(echo "$user_resp" | tail -1)
  local user_body
  user_body=$(echo "$user_resp" | sed '$d')

  if [[ "$user_code" == "201" ]] || [[ "$user_code" == "200" ]]; then
    score=$((score + 5))
  fi

  # Extract user ID for later tests
  local user_id
  user_id=$(echo "$user_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, dict):
        print(data.get('id', data.get('user', {}).get('id', '')))
    else:
        print('')
except:
    print('')
" 2>/dev/null || true)
  [[ "$user_id" == "None" ]] && user_id=""

  # Create a second user for author filter testing
  local user2_resp
  user2_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/users" \
    -H "Content-Type: application/json" \
    -d '{"username":"otheruser","email":"other@example.com","bio":"Another user"}' 2>/dev/null) || true
  local user2_body
  user2_body=$(echo "$user2_resp" | sed '$d')
  local user2_id
  user2_id=$(echo "$user2_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, dict):
        print(data.get('id', data.get('user', {}).get('id', '')))
    else:
        print('')
except:
    print('')
" 2>/dev/null || true)
  [[ "$user2_id" == "None" ]] && user2_id=""

  # --- POST /posts — create post linked to author (8 pts) ---
  local post_resp
  post_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/posts" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Test Post\",\"content\":\"Test content here\",\"author_id\":\"$user_id\",\"published\":true}" 2>/dev/null) || true
  local post_code
  post_code=$(echo "$post_resp" | tail -1)
  local post_body
  post_body=$(echo "$post_resp" | sed '$d')

  if [[ "$post_code" == "201" ]] || [[ "$post_code" == "200" ]]; then
    score=$((score + 5))
    # Verify post has author_id or author reference (3 pts)
    local has_author_ref
    has_author_ref=$(echo "$post_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, dict):
        # Accept author_id field, author object, or nested post object
        d = data.get('post', data) if isinstance(data.get('post'), dict) else data
        print('yes' if d.get('author_id') or d.get('author') or d.get('authorId') else 'no')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null || true)
    [[ "$has_author_ref" == "yes" ]] && score=$((score + 3))
  fi

  # Extract post ID
  local post_id
  post_id=$(echo "$post_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, dict):
        d = data.get('post', data) if isinstance(data.get('post'), dict) else data
        print(d.get('id', ''))
    else:
        print('')
except:
    print('')
" 2>/dev/null || true)
  [[ "$post_id" == "None" ]] && post_id=""

  # Create an unpublished post (for testing published filter)
  curl -s -X POST "$base/posts" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Draft Post\",\"content\":\"Draft content\",\"author_id\":\"$user_id\",\"published\":false}" 2>/dev/null >/dev/null || true

  # Create a post by user2 (for author filter testing)
  curl -s -X POST "$base/posts" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Other User Post\",\"content\":\"Other content\",\"author_id\":\"$user2_id\",\"published\":true}" 2>/dev/null >/dev/null || true

  # --- GET /posts returns published posts only (8 pts) ---
  local list_resp
  list_resp=$(curl -s -w "\n%{http_code}" "$base/posts" 2>/dev/null) || true
  local list_code
  list_code=$(echo "$list_resp" | tail -1)
  local list_body
  list_body=$(echo "$list_resp" | sed '$d')

  if [[ "$list_code" == "200" ]]; then
    local published_only
    published_only=$(echo "$list_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    items = data if isinstance(data, list) else data.get('posts', data.get('data', data.get('items', [])))
    if not isinstance(items, list) or len(items) == 0:
        print('no')
    else:
        # Check that all returned posts are published (no draft posts)
        all_published = all(
            p.get('published', p.get('is_published', True)) in (True, 1, '1', 'true')
            for p in items
        )
        has_draft = any('Draft' in str(p.get('title', '')) for p in items)
        print('yes' if all_published and not has_draft else 'no')
except:
    print('no')
" 2>/dev/null || true)
    [[ "$published_only" == "yes" ]] && score=$((score + 8))
  fi

  # --- GET /posts/:id returns post WITH author info (nested object) (8 pts) ---
  if [[ -n "$post_id" ]]; then
    local get_resp
    get_resp=$(curl -s -w "\n%{http_code}" "$base/posts/$post_id" 2>/dev/null) || true
    local get_code
    get_code=$(echo "$get_resp" | tail -1)
    local get_body
    get_body=$(echo "$get_resp" | sed '$d')

    if [[ "$get_code" == "200" ]]; then
      local has_author_obj
      has_author_obj=$(echo "$get_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    d = data.get('post', data) if isinstance(data.get('post'), dict) else data
    author = d.get('author')
    # Must be an object (not just author_id string)
    if isinstance(author, dict) and (author.get('username') or author.get('id') or author.get('email')):
        print('yes')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null || true)
      [[ "$has_author_obj" == "yes" ]] && score=$((score + 8))
    fi

    # --- GET /posts/:id returns post WITH tags array (8 pts) ---
    # First add a tag, then check
    curl -s -X POST "$base/posts/$post_id/tags" \
      -H "Content-Type: application/json" \
      -d '{"tags":["javascript","nodejs"]}' 2>/dev/null >/dev/null || true
    # Also try singular tag format
    curl -s -X POST "$base/posts/$post_id/tags" \
      -H "Content-Type: application/json" \
      -d '{"tag":"python"}' 2>/dev/null >/dev/null || true

    local get2_resp
    get2_resp=$(curl -s "$base/posts/$post_id" 2>/dev/null) || true
    local has_tags_arr
    has_tags_arr=$(echo "$get2_resp" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    d = data.get('post', data) if isinstance(data.get('post'), dict) else data
    tags = d.get('tags', [])
    if isinstance(tags, list) and len(tags) > 0:
        print('yes')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null || true)
    [[ "$has_tags_arr" == "yes" ]] && score=$((score + 8))
  fi

  # --- POST /posts/:id/tags adds tags (5 pts) ---
  # Already attempted above; verify tags were actually added
  if [[ -n "$post_id" ]]; then
    local tags_check
    tags_check=$(curl -s "$base/posts/$post_id" 2>/dev/null) || true
    local tags_added
    tags_added=$(echo "$tags_check" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    d = data.get('post', data) if isinstance(data.get('post'), dict) else data
    tags = d.get('tags', [])
    if isinstance(tags, list) and len(tags) > 0:
        # Tags could be strings or objects with name field
        tag_names = []
        for t in tags:
            if isinstance(t, str):
                tag_names.append(t)
            elif isinstance(t, dict):
                tag_names.append(t.get('name', ''))
        has_js = any('javascript' in n.lower() for n in tag_names)
        has_node = any('node' in n.lower() for n in tag_names)
        has_python = any('python' in n.lower() for n in tag_names)
        print('yes' if (has_js or has_node or has_python) else 'no')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null || true)
    [[ "$tags_added" == "yes" ]] && score=$((score + 5))
  fi

  # --- GET /posts?tag=X filters correctly (8 pts) ---
  local tag_filter_resp
  tag_filter_resp=$(curl -s -w "\n%{http_code}" "$base/posts?tag=javascript" 2>/dev/null) || true
  local tag_filter_code
  tag_filter_code=$(echo "$tag_filter_resp" | tail -1)
  local tag_filter_body
  tag_filter_body=$(echo "$tag_filter_resp" | sed '$d')

  if [[ "$tag_filter_code" == "200" ]]; then
    local tag_filter_ok
    tag_filter_ok=$(echo "$tag_filter_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    items = data if isinstance(data, list) else data.get('posts', data.get('data', data.get('items', [])))
    if isinstance(items, list) and len(items) >= 1:
        # At least one result and results should relate to the tag
        print('yes')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null || true)
    [[ "$tag_filter_ok" == "yes" ]] && score=$((score + 8))
  fi

  # --- GET /posts?author=X filters correctly (5 pts) ---
  local author_filter_resp
  author_filter_resp=$(curl -s -w "\n%{http_code}" "$base/posts?author=testuser" 2>/dev/null) || true
  local author_filter_code
  author_filter_code=$(echo "$author_filter_resp" | tail -1)
  local author_filter_body
  author_filter_body=$(echo "$author_filter_resp" | sed '$d')

  if [[ "$author_filter_code" == "200" ]]; then
    local author_filter_ok
    author_filter_ok=$(echo "$author_filter_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    items = data if isinstance(data, list) else data.get('posts', data.get('data', data.get('items', [])))
    if isinstance(items, list) and len(items) >= 1:
        # Should not include otheruser's posts
        has_other = any('Other User Post' in str(p.get('title', '')) for p in items)
        print('yes' if not has_other else 'no')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null || true)
    [[ "$author_filter_ok" == "yes" ]] && score=$((score + 5))
  fi

  # --- DELETE /posts/:id actually removes from DB (5 pts) ---
  # Create a throwaway post to delete
  local del_post_resp
  del_post_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/posts" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"To Delete\",\"content\":\"Will be deleted\",\"author_id\":\"$user_id\",\"published\":true}" 2>/dev/null) || true
  local del_post_body
  del_post_body=$(echo "$del_post_resp" | sed '$d')
  local del_post_id
  del_post_id=$(echo "$del_post_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    d = data.get('post', data) if isinstance(data.get('post'), dict) else data
    print(d.get('id', ''))
except:
    print('')
" 2>/dev/null || true)
  [[ "$del_post_id" == "None" ]] && del_post_id=""

  if [[ -n "$del_post_id" ]]; then
    # Add a tag to this post so we can test cascade
    curl -s -X POST "$base/posts/$del_post_id/tags" \
      -H "Content-Type: application/json" \
      -d '{"tags":["deleteme"]}' 2>/dev/null >/dev/null || true

    local del_resp
    del_resp=$(curl -s -w "\n%{http_code}" -X DELETE "$base/posts/$del_post_id" 2>/dev/null) || true
    local del_code
    del_code=$(echo "$del_resp" | tail -1)
    if [[ "$del_code" == "200" ]] || [[ "$del_code" == "204" ]]; then
      # Verify it's gone
      local gone_resp
      gone_resp=$(curl -s -w "\n%{http_code}" "$base/posts/$del_post_id" 2>/dev/null) || true
      local gone_code
      gone_code=$(echo "$gone_resp" | tail -1)
      [[ "$gone_code" == "404" ]] && score=$((score + 5))
    fi

    # --- DELETE cascades to post_tags (5 pts) ---
    # We check source code for CASCADE or manual deletion of post_tags on delete
    local src_files
    src_files=$(find "$ws" -maxdepth 4 -name "*.js" -o -name "*.ts" 2>/dev/null | grep -v node_modules) || true
    local has_cascade=""
    has_cascade=$(echo "$src_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "CASCADE|ON DELETE|post_tags.*DELETE|DELETE.*post_tags" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_cascade" == "found" ]] && score=$((score + 5))
  fi

  # --- Pagination works on GET /posts (5 pts) ---
  # Create several posts to have enough data
  for _i in 1 2 3 4 5; do
    curl -s -X POST "$base/posts" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"Paginated Post $_i\",\"content\":\"Content $_i\",\"author_id\":\"$user_id\",\"published\":true}" 2>/dev/null >/dev/null || true
  done

  local page_resp
  page_resp=$(curl -s -w "\n%{http_code}" "$base/posts?page=1&limit=2" 2>/dev/null) || true
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
    if isinstance(data, dict):
        items = data.get('posts', data.get('data', data.get('items', [])))
        total = data.get('total', data.get('totalCount', data.get('count', 0)))
        # Paginated: items count should be <= limit (2)
        if isinstance(items, list) and len(items) <= 2 and len(items) > 0:
            print('yes')
        else:
            print('no')
    elif isinstance(data, list) and len(data) <= 2 and len(data) > 0:
        # Some implementations return a bare array with limited items
        print('yes')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null || true)
    [[ "$page_ok" == "yes" ]] && score=$((score + 5))
  fi

  # --- GET /users/:id/posts returns only that user's posts (5 pts) ---
  if [[ -n "$user_id" ]]; then
    local user_posts_resp
    user_posts_resp=$(curl -s -w "\n%{http_code}" "$base/users/$user_id/posts" 2>/dev/null) || true
    local user_posts_code
    user_posts_code=$(echo "$user_posts_resp" | tail -1)
    local user_posts_body
    user_posts_body=$(echo "$user_posts_resp" | sed '$d')

    if [[ "$user_posts_code" == "200" ]]; then
      local user_posts_ok
      user_posts_ok=$(echo "$user_posts_body" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    items = data if isinstance(data, list) else data.get('posts', data.get('data', data.get('items', [])))
    if isinstance(items, list) and len(items) >= 1:
        # Should not include otheruser's posts
        has_other = any('Other User Post' in str(p.get('title', '')) for p in items)
        print('yes' if not has_other else 'no')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null || true)
      [[ "$user_posts_ok" == "yes" ]] && score=$((score + 5))
    fi
  fi

  # --- Unique constraints enforced (duplicate username/email returns 409) (5 pts) ---
  local dup_resp
  dup_resp=$(curl -s -w "\n%{http_code}" -X POST "$base/users" \
    -H "Content-Type: application/json" \
    -d '{"username":"testuser","email":"different@example.com","bio":"Duplicate username"}' 2>/dev/null) || true
  local dup_code
  dup_code=$(echo "$dup_resp" | tail -1)

  if [[ "$dup_code" == "409" ]] || [[ "$dup_code" == "400" ]] || [[ "$dup_code" == "422" ]]; then
    # Stricter: prefer 409
    if [[ "$dup_code" == "409" ]]; then
      score=$((score + 5))
    else
      score=$((score + 3))
    fi
  fi

  # Cleanup
  kill "$server_pid" 2>/dev/null
  sleep 0.5
  kill -9 "$server_pid" 2>/dev/null || true

  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  # --- Test files exist (10 pts) ---
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
  [[ $test_count -gt 0 ]] && score=$((score + 10))

  # --- Tests pass (25 pts) ---
  local test_output
  test_output=$(cd "$ws" && npm test 2>&1 | tail -50) || true
  local tests_pass
  tests_pass=$(echo "$test_output" | python3 -c "
import sys, re
text = sys.stdin.read()
if re.search(r'(pass|PASS|Tests:.*passed|test suites.*passed)', text, re.IGNORECASE):
    if not re.search(r'(FAIL(?!\s+0)|fail(?:ed|ure)|ERR!)', text, re.IGNORECASE):
        print('yes')
    else:
        print('no')
else:
    print('no')
" 2>/dev/null || true)
  [[ "$tests_pass" == "yes" ]] && score=$((score + 25))

  # --- Tests use separate database (10 pts) ---
  local has_test_db=""
  if [[ -n "$test_files" ]]; then
    has_test_db=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "test\.db|:memory:|TEST_DB|NODE_ENV.*test|process\.env\..*DB|test.*database|memory" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
  fi
  # Also check for test env setup in config or db files
  if [[ "$has_test_db" != "found" ]]; then
    local all_src
    all_src=$(find "$ws" -maxdepth 4 -name "*.js" -o -name "*.ts" 2>/dev/null | grep -v node_modules) || true
    has_test_db=$(echo "$all_src" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "NODE_ENV.*test.*:memory:|test.*\.db|process\.env\..*test.*db" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
  fi
  [[ "$has_test_db" == "found" ]] && score=$((score + 10))

  # --- Tests cover CRUD operations (10 pts) ---
  local crud_count=0
  if [[ -n "$test_files" ]]; then
    for pattern in "POST.*\/posts\|create.*post\|creating" "GET.*\/posts\|list.*post\|fetch\|retrieve" "PUT.*\/posts\|update.*post\|updating" "DELETE.*\/posts\|delete.*post\|delet\|remov"; do
      local has_crud
      has_crud=$(echo "$test_files" | while read -r f; do
        [[ -z "$f" ]] && continue
        if grep -qliE "$pattern" "$f" 2>/dev/null; then
          echo "found"; break
        fi
      done) || true
      [[ "$has_crud" == "found" ]] && crud_count=$((crud_count + 1))
    done
  fi
  [[ $crud_count -ge 3 ]] && score=$((score + 10))

  # --- Tests cover relationships (author in post, tags) (10 pts) ---
  local rel_count=0
  if [[ -n "$test_files" ]]; then
    local has_author_test
    has_author_test=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "author|user.*post|post.*user|author_id|authorId" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_author_test" == "found" ]] && rel_count=$((rel_count + 1))

    local has_tags_test
    has_tags_test=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "tag|tags|post_tags" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_tags_test" == "found" ]] && rel_count=$((rel_count + 1))
  fi
  [[ $rel_count -ge 2 ]] && score=$((score + 10))

  # --- Tests cover filtering (tag, author) (10 pts) ---
  local filter_count=0
  if [[ -n "$test_files" ]]; then
    local has_tag_filter
    has_tag_filter=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "tag=|filter.*tag|query.*tag|\?tag" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_tag_filter" == "found" ]] && filter_count=$((filter_count + 1))

    local has_author_filter
    has_author_filter=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "author=|filter.*author|query.*author|\?author" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_author_filter" == "found" ]] && filter_count=$((filter_count + 1))
  fi
  [[ $filter_count -ge 2 ]] && score=$((score + 10))

  # --- Tests cover error cases (404, 400, 409) (10 pts) ---
  local error_count=0
  if [[ -n "$test_files" ]]; then
    for err_pattern in "404|not.?found" "400|bad.?request|invalid|validation" "409|conflict|duplicate|unique|already.?exists"; do
      local has_err
      has_err=$(echo "$test_files" | while read -r f; do
        [[ -z "$f" ]] && continue
        if grep -qlEi "$err_pattern" "$f" 2>/dev/null; then
          echo "found"; break
        fi
      done) || true
      [[ "$has_err" == "found" ]] && error_count=$((error_count + 1))
    done
  fi
  [[ $error_count -ge 2 ]] && score=$((score + 5))
  [[ $error_count -ge 3 ]] && score=$((score + 5))

  # --- Test count >10 (5 pts), >20 (5 pts) ---
  local individual_tests
  individual_tests=$(echo "$test_output" | python3 -c "
import sys, re
text = sys.stdin.read()
# Jest: 'Tests: X passed'
m = re.search(r'Tests:\s+(\d+)\s+passed', text)
if m:
    print(m.group(1))
    exit()
# Mocha/tap: 'N passing'
m = re.search(r'(\d+)\s+passing', text)
if m:
    print(m.group(1))
    exit()
# Count checkmarks
count = len(re.findall(r'[✓✔]|PASS\s', text))
print(count if count > 0 else 0)
" 2>/dev/null || true)
  [[ -n "$individual_tests" ]] && [[ "$individual_tests" -gt 10 ]] 2>/dev/null && score=$((score + 5))
  [[ -n "$individual_tests" ]] && [[ "$individual_tests" -gt 20 ]] 2>/dev/null && score=$((score + 5))

  # --- Tests clean up after themselves (5 pts) ---
  local has_cleanup
  has_cleanup=$(echo "$test_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "beforeEach|afterEach|beforeAll|afterAll|before\(|after\(|setup|teardown|cleanup" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_cleanup" == "found" ]] && score=$((score + 5))

  # Cap at 100
  [[ $score -gt 100 ]] && score=100

  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=0

  local src_files
  src_files=$(find "$ws" -maxdepth 4 -name "*.js" -o -name "*.ts" 2>/dev/null | grep -v node_modules | grep -vE "test|spec") || true

  # --- Uses parameterized queries (no string concatenation in SQL) (15 pts) ---
  # Check for template literals in SQL — these indicate SQL injection vulnerability
  # Exclude safe patterns: ${placeholders}, ${setClauses}, ${columns}, ${join()} — these are query structure, not user data
  local has_sql_injection=""
  has_sql_injection=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    # Get lines with SQL + template literal, then filter out safe patterns
    local unsafe_lines
    unsafe_lines=$(grep -E 'SELECT.*\$\{|INSERT.*\$\{|UPDATE.*\$\{|DELETE.*\$\{' "$f" 2>/dev/null \
      | grep -vEi 'placeholder|setClauses|setClause|columns|join\(|\.map\(' 2>/dev/null) || true
    if [[ -n "$unsafe_lines" ]]; then
      echo "found"; break
    fi
  done) || true
  if [[ "$has_sql_injection" != "found" ]]; then
    # Also verify they actually use parameterized queries (? placeholders or $1, $2 etc.)
    local has_params
    has_params=$(echo "$src_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlE '\?\s*[,\)]|\$[0-9]|\.run\(|\.get\(|\.all\(|\.prepare\(' "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_params" == "found" ]] && score=$((score + 15))
  fi

  # --- Has proper foreign keys (FOREIGN KEY or REFERENCES in schema) (10 pts) ---
  local has_fk
  has_fk=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "FOREIGN KEY|REFERENCES" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_fk" == "found" ]] && score=$((score + 10))

  # --- Has database initialization/migration (CREATE TABLE IF NOT EXISTS) (10 pts) ---
  local has_migration
  has_migration=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "CREATE TABLE IF NOT EXISTS|CREATE TABLE" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_migration" == "found" ]] && score=$((score + 10))

  # --- Has error handling for database errors (10 pts) ---
  local has_db_error
  has_db_error=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "catch|\.catch|error.*database|database.*error|SQLITE|UNIQUE constraint|try.*{" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_db_error" == "found" ]] && score=$((score + 10))

  # --- Input validation (title required, author_id must exist) (10 pts) ---
  local has_validation
  has_validation=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "required|!.*title|!.*author|\.trim\(\)|\.length|validat|missing" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_validation" == "found" ]] && score=$((score + 10))

  # --- Timestamps auto-populated (created_at, updated_at) (5 pts) ---
  local has_timestamps
  has_timestamps=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "created_at|createdAt|updated_at|updatedAt|CURRENT_TIMESTAMP|new Date|Date\.now|datetime\(" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_timestamps" == "found" ]] && score=$((score + 5))

  # --- Proper status codes (201, 400, 404, 409) (10 pts) ---
  local status_count=0
  for code_pattern in "status(201" "status(400" "status(404" "status(409"; do
    local has_code
    has_code=$(echo "$src_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -ql "$code_pattern" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_code" == "found" ]] && status_count=$((status_count + 1))
  done
  # Need at least 3 of 4
  [[ $status_count -ge 3 ]] && score=$((score + 7))
  [[ $status_count -ge 4 ]] && score=$((score + 3))

  # --- Separate files for routes, models/db, middleware (10 pts) ---
  local structure_count=0
  # Check for route files
  local has_routes
  has_routes=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if echo "$f" | grep -qEi "route|router"; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_routes" == "found" ]] && structure_count=$((structure_count + 1))

  # Check for model/db files
  local has_models
  has_models=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if echo "$f" | grep -qEi "model|database|db\.|migration|schema"; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_models" == "found" ]] && structure_count=$((structure_count + 1))

  # Check for middleware files
  local has_middleware
  has_middleware=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if echo "$f" | grep -qEi "middleware|validator|error.?handler"; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_middleware" == "found" ]] && structure_count=$((structure_count + 1))

  [[ $structure_count -ge 2 ]] && score=$((score + 7))
  [[ $structure_count -ge 3 ]] && score=$((score + 3))

  # --- No SQL injection possible (check no template literals in queries) (10 pts) ---
  # This is a stricter re-check: look for ANY string interpolation in SQL contexts
  # Exclude safe patterns: dynamic placeholder/column construction (${placeholders}, ${setClauses}, .join(), .map())
  local has_unsafe_sql=""
  has_unsafe_sql=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    # Check for template literals with SQL keywords, excluding safe patterns
    local unsafe_tpl
    unsafe_tpl=$(grep -E '`(SELECT|INSERT|UPDATE|DELETE|CREATE).*\$\{' "$f" 2>/dev/null \
      | grep -vEi 'placeholder|setClauses|setClause|columns|join\(|\.map\(' 2>/dev/null) || true
    if [[ -n "$unsafe_tpl" ]]; then
      echo "found"; break
    fi
    # Check for string concatenation with SQL
    if grep -qE "(SELECT|INSERT|UPDATE|DELETE).*\+.*(\"|')" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_unsafe_sql" != "found" ]] && score=$((score + 10))

  # --- Clean code: const/let, no var (5 pts) ---
  local has_var=""
  has_var=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qE '^\s*var\s|[;{]\s*var\s' "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_var" != "found" ]] && score=$((score + 5))

  # --- Database connection properly closed on shutdown (5 pts) ---
  local has_close
  has_close=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "\.close\(\)|SIGTERM|SIGINT|process\.on.*exit|graceful.*shut|server\.close" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_close" == "found" ]] && score=$((score + 5))

  # Cap at 100
  [[ $score -gt 100 ]] && score=100

  echo "$score"
}

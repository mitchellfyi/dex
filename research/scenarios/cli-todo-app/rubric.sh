#!/usr/bin/env bash
# Rubric for: cli-todo-app
# Hardened rubric — a "perfect" DX implementation targets ~85-90, not 100.

# Helper: find the CLI entry point
_find_entry() {
  local ws="$1"
  for candidate in index.js src/index.js cli.js src/cli.js bin/index.js; do
    if [[ -f "$ws/$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done
  # Check package.json "bin" or "main" as fallback
  if [[ -f "$ws/package.json" ]]; then
    local main_field
    main_field=$(node -e "try{console.log(require('$ws/package.json').main||'')}catch(e){}" 2>/dev/null) || true
    if [[ -n "$main_field" && -f "$ws/$main_field" ]]; then
      echo "$main_field"
      return
    fi
  fi
  echo ""
}

rubric_correctness() {
  local ws="$1"
  local score=0

  # --- Structural checks (10 pts) ---

  # Check package.json exists (3 pts)
  [[ -f "$ws/package.json" ]] && score=$((score + 3))

  # Check main entry point exists (3 pts)
  local entry
  entry=$(_find_entry "$ws")
  [[ -n "$entry" ]] && score=$((score + 3))

  # Install dependencies (4 pts)
  if (cd "$ws" && npm install --silent >/dev/null 2>&1); then
    score=$((score + 4))
  else
    echo "$score"; return
  fi

  # Bail if no entry point
  [[ -z "$entry" || ! -f "$ws/$entry" ]] && { echo "$score"; return; }

  # Clean slate
  rm -f "$ws/todos.json" 2>/dev/null

  # --- Core CRUD operations (45 pts) ---

  # Add a todo (8 pts)
  local add_output
  add_output=$(cd "$ws" && node "$entry" add "Buy groceries" 2>&1) || true
  if [[ -n "$add_output" ]]; then
    local add_match
    add_match=$(echo "$add_output" | grep -ciE "add|creat|success|todo" 2>/dev/null) || true
    if [[ "$add_match" -gt 0 ]]; then
      score=$((score + 8))
    fi
  fi

  # List todos — should show the added item (8 pts)
  local list_output
  list_output=$(cd "$ws" && node "$entry" list 2>&1) || true
  local list_match
  list_match=$(echo "$list_output" | grep -c "Buy groceries" 2>/dev/null) || true
  if [[ "$list_match" -gt 0 ]]; then
    score=$((score + 8))
  fi

  # Add a second todo (implicit, for later checks)
  (cd "$ws" && node "$entry" add "Walk the dog" 2>&1) >/dev/null || true

  # Complete a todo (8 pts)
  local complete_output
  complete_output=$(cd "$ws" && node "$entry" complete 1 2>&1) || true
  local comp_match
  comp_match=$(echo "$complete_output" | grep -ciE 'complet|done|mark|success|✓|✔|\[x\]' 2>/dev/null) || true
  if [[ "$comp_match" -gt 0 ]]; then
    score=$((score + 8))
  fi

  # Verify completion shows in list (5 pts)
  list_output=$(cd "$ws" && node "$entry" list 2>&1) || true
  local done_match
  done_match=$(echo "$list_output" | grep -cE '\[x\]|✓|✔|done|completed' 2>/dev/null) || true
  if [[ "$done_match" -gt 0 ]]; then
    score=$((score + 5))
  fi

  # Delete a todo (8 pts)
  local delete_output
  delete_output=$(cd "$ws" && node "$entry" delete 1 2>&1) || true
  local del_match
  del_match=$(echo "$delete_output" | grep -ciE 'delet|remov|success' 2>/dev/null) || true
  if [[ "$del_match" -gt 0 ]]; then
    score=$((score + 8))
  fi

  # List after delete should not show deleted item (8 pts)
  list_output=$(cd "$ws" && node "$entry" list 2>&1) || true
  local still_has
  still_has=$(echo "$list_output" | grep -c "Buy groceries" 2>/dev/null) || true
  if [[ "$still_has" -eq 0 ]]; then
    score=$((score + 8))
  fi

  # --- Edge case handling (25 pts) ---

  # Adding todo with empty string should be rejected (5 pts)
  local empty_add_output empty_add_exit
  empty_add_output=$(cd "$ws" && node "$entry" add "" 2>&1); empty_add_exit=$?
  # Should either show error message or exit non-zero
  local empty_err_match
  empty_err_match=$(echo "$empty_add_output" | grep -ciE 'error|invalid|empty|required|provide|cannot|must' 2>/dev/null) || true
  if [[ "$empty_err_match" -gt 0 ]] || [[ "$empty_add_exit" -ne 0 ]]; then
    score=$((score + 5))
  fi

  # List with no todos shows empty/no-items message (5 pts)
  rm -f "$ws/todos.json" 2>/dev/null
  local empty_list_output
  empty_list_output=$(cd "$ws" && node "$entry" list 2>&1) || true
  local no_items_match
  no_items_match=$(echo "$empty_list_output" | grep -ciE 'no todo|empty|no item|nothing|0 todo|no task' 2>/dev/null) || true
  if [[ "$no_items_match" -gt 0 ]]; then
    score=$((score + 5))
  fi

  # Complete non-existent ID shows error (5 pts)
  local bad_complete_output bad_complete_exit
  bad_complete_output=$(cd "$ws" && node "$entry" complete 99999 2>&1); bad_complete_exit=$?
  local bad_comp_match
  bad_comp_match=$(echo "$bad_complete_output" | grep -ciE 'error|not found|invalid|does not exist|no todo|cannot' 2>/dev/null) || true
  if [[ "$bad_comp_match" -gt 0 ]] || [[ "$bad_complete_exit" -ne 0 ]]; then
    score=$((score + 5))
  fi

  # Delete non-existent ID shows error (5 pts)
  local bad_delete_output bad_delete_exit
  bad_delete_output=$(cd "$ws" && node "$entry" delete 99999 2>&1); bad_delete_exit=$?
  local bad_del_match
  bad_del_match=$(echo "$bad_delete_output" | grep -ciE 'error|not found|invalid|does not exist|no todo|cannot' 2>/dev/null) || true
  if [[ "$bad_del_match" -gt 0 ]] || [[ "$bad_delete_exit" -ne 0 ]]; then
    score=$((score + 5))
  fi

  # No args / --help shows usage info (5 pts)
  local help_output
  help_output=$(cd "$ws" && node "$entry" 2>&1) || true
  local help2_output
  help2_output=$(cd "$ws" && node "$entry" --help 2>&1) || true
  local help_combined="${help_output} ${help2_output}"
  local help_match
  help_match=$(echo "$help_combined" | grep -ciE 'usage|help|commands?:|add|list|complete|delete' 2>/dev/null) || true
  if [[ "$help_match" -ge 2 ]]; then
    score=$((score + 5))
  fi

  # --- Persistence & data integrity (20 pts) ---

  # Reset and rebuild state for persistence checks
  rm -f "$ws/todos.json" 2>/dev/null
  (cd "$ws" && node "$entry" add "Persistence test A" 2>&1) >/dev/null || true
  (cd "$ws" && node "$entry" add "Persistence test B" 2>&1) >/dev/null || true

  # todos.json exists (4 pts)
  [[ -f "$ws/todos.json" ]] && score=$((score + 4))

  # JSON has correct structure: array of objects with id, text, done/completed fields (8 pts)
  if [[ -f "$ws/todos.json" ]]; then
    local json_valid
    json_valid=$(node -e "
      try {
        const data = JSON.parse(require('fs').readFileSync('$ws/todos.json','utf8'));
        if (!Array.isArray(data)) { console.log('0'); process.exit(); }
        let pts = 0;
        if (data.length > 0) {
          const item = data[0];
          if ('id' in item) pts += 2;
          if ('text' in item || 'title' in item || 'name' in item) pts += 2;
          if ('done' in item || 'completed' in item) pts += 2;
          if ('createdAt' in item || 'created_at' in item || 'timestamp' in item) pts += 2;
        }
        console.log(pts);
      } catch(e) { console.log('0'); }
    " 2>/dev/null) || true
    json_valid=${json_valid:-0}
    score=$((score + json_valid))
  fi

  # IDs are unique even after deletion — IDs should not be reused (4 pts)
  (cd "$ws" && node "$entry" delete 1 2>&1) >/dev/null || true
  (cd "$ws" && node "$entry" add "Persistence test C" 2>&1) >/dev/null || true
  if [[ -f "$ws/todos.json" ]]; then
    local ids_unique
    ids_unique=$(node -e "
      try {
        const data = JSON.parse(require('fs').readFileSync('$ws/todos.json','utf8'));
        const ids = data.map(t => t.id);
        const unique = new Set(ids);
        // All IDs should be unique
        if (unique.size === ids.length) {
          // ID 1 was deleted — new item should NOT have ID 1
          if (!ids.includes(1)) { console.log('4'); }
          else { console.log('2'); }  // partial: unique but reused
        } else { console.log('0'); }
      } catch(e) { console.log('0'); }
    " 2>/dev/null) || true
    ids_unique=${ids_unique:-0}
    score=$((score + ids_unique))
  fi

  # Cross-session persistence: data survives re-read (4 pts)
  local persist_list
  persist_list=$(cd "$ws" && node "$entry" list 2>&1) || true
  local persist_match
  persist_match=$(echo "$persist_list" | grep -c "Persistence test" 2>/dev/null) || true
  if [[ "$persist_match" -ge 2 ]]; then
    score=$((score + 4))
  fi

  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  # --- Test file existence and count (20 pts) ---
  local test_files
  test_files=$(find "$ws" -maxdepth 3 \( \
    -name "*.test.*" -o -name "*.spec.*" -o \
    -name "test.js" -o -name "test_*.js" -o -name "tests.js" \
  \) ! -path "*/node_modules/*" 2>/dev/null)
  # Also check __tests__/ and test/ directories
  local test_dir_files
  test_dir_files=$(find "$ws" -maxdepth 4 -path "*/__tests__/*.js" -o -path "*/test/*.js" -o -path "*/tests/*.js" 2>/dev/null | grep -v node_modules) || true
  if [[ -n "$test_dir_files" ]]; then
    test_files=$(printf '%s\n%s' "$test_files" "$test_dir_files" | sort -u | grep -v '^$')
  fi
  local test_count
  test_count=$(echo "$test_files" | grep -c "." 2>/dev/null) || true
  test_count=${test_count:-0}

  # At least 1 test file (5 pts)
  [[ $test_count -gt 0 ]] && score=$((score + 5))
  # More than 1 test file (5 pts)
  [[ $test_count -gt 1 ]] && score=$((score + 5))
  # More than 2 test files — unit + integration + possibly edge cases (10 pts)
  [[ $test_count -gt 2 ]] && score=$((score + 10))

  # --- package.json has test script (5 pts) ---
  if [[ -f "$ws/package.json" ]]; then
    local has_test
    has_test=$(grep -c '"test"' "$ws/package.json" 2>/dev/null) || true
    [[ "$has_test" -gt 0 ]] && score=$((score + 5))
  fi

  # --- Tests actually pass (20 pts) ---
  if [[ -f "$ws/package.json" ]]; then
    local test_output
    test_output=$(cd "$ws" && npm test 2>&1) || true
    local test_pass_match
    test_pass_match=$(echo "$test_output" | tail -30 | grep -ciE 'pass|✓|ok|success|tests? (passed|complete)' 2>/dev/null) || true
    local test_fail_match
    test_fail_match=$(echo "$test_output" | tail -30 | grep -ciE 'fail|✗|✘|error|FAIL' 2>/dev/null) || true
    if [[ "$test_pass_match" -gt 0 && "$test_fail_match" -eq 0 ]]; then
      score=$((score + 20))
    elif [[ "$test_pass_match" -gt 0 ]]; then
      score=$((score + 10))  # some pass but some fail
    fi
  fi

  # --- Test coverage of all commands (15 pts) ---
  if [[ -n "$test_files" ]]; then
    local commands_tested=0
    for cmd in "add" "list" "complete" "delete"; do
      local cmd_match
      cmd_match=$(echo "$test_files" | xargs grep -cl "$cmd" 2>/dev/null | wc -l | tr -d ' ') || true
      if [[ "$cmd_match" -gt 0 ]]; then
        commands_tested=$((commands_tested + 1))
      fi
    done
    [[ $commands_tested -ge 2 ]] && score=$((score + 5))
    [[ $commands_tested -ge 4 ]] && score=$((score + 10))
  fi

  # --- Tests cover error/edge cases, not just happy path (15 pts) ---
  if [[ -n "$test_files" ]]; then
    local error_test_patterns=0
    # Check for error-related test patterns
    local err_match
    err_match=$(echo "$test_files" | xargs grep -clE 'error|invalid|empty|not found|should (fail|throw|reject|error)|edge|missing|non.?existent|does not exist' 2>/dev/null | wc -l | tr -d ' ') || true
    [[ "$err_match" -gt 0 ]] && error_test_patterns=$((error_test_patterns + 1))

    # Check for negative assertions (expect not, toThrow, rejects, etc.)
    local neg_match
    neg_match=$(echo "$test_files" | xargs grep -clE 'toThrow|rejects|toBeFalsy|not\.(toBe|toContain|toEqual)|expect.*error|assert.*throws|assert.*rejects' 2>/dev/null | wc -l | tr -d ' ') || true
    [[ "$neg_match" -gt 0 ]] && error_test_patterns=$((error_test_patterns + 1))

    # Check for empty input / boundary tests
    local boundary_match
    boundary_match=$(echo "$test_files" | xargs grep -clE '""|\x27\x27|empty|no (todo|item|task)|invalid.*(id|ID)|non.?numeric' 2>/dev/null | wc -l | tr -d ' ') || true
    [[ "$boundary_match" -gt 0 ]] && error_test_patterns=$((error_test_patterns + 1))

    if [[ $error_test_patterns -ge 3 ]]; then
      score=$((score + 15))
    elif [[ $error_test_patterns -ge 2 ]]; then
      score=$((score + 10))
    elif [[ $error_test_patterns -ge 1 ]]; then
      score=$((score + 5))
    fi
  fi

  # --- Assertion messages / describe blocks for readability (10 pts) ---
  if [[ -n "$test_files" ]]; then
    local has_describe has_messages
    has_describe=$(echo "$test_files" | xargs grep -clE 'describe\(|context\(|suite\(' 2>/dev/null | wc -l | tr -d ' ') || true
    has_messages=$(echo "$test_files" | xargs grep -clE "it\(['\"]|test\(['\"]" 2>/dev/null | wc -l | tr -d ' ') || true
    [[ "$has_describe" -gt 0 ]] && score=$((score + 5))
    [[ "$has_messages" -gt 0 ]] && score=$((score + 5))
  fi

  # --- Sufficient number of test cases (15 pts) ---
  if [[ -n "$test_files" ]]; then
    local total_tests
    total_tests=$(echo "$test_files" | xargs grep -cE "^\s*(it|test)\(" 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
    total_tests=${total_tests:-0}

    if [[ $total_tests -ge 10 ]]; then
      score=$((score + 15))
    elif [[ $total_tests -ge 7 ]]; then
      score=$((score + 10))
    elif [[ $total_tests -ge 5 ]]; then
      score=$((score + 7))
    elif [[ $total_tests -ge 3 ]]; then
      score=$((score + 3))
    fi
  fi

  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=0

  local entry
  entry=$(_find_entry "$ws")
  [[ -z "$entry" || ! -f "$ws/$entry" ]] && { echo "0"; return; }

  # Install deps
  (cd "$ws" && npm install --silent >/dev/null 2>&1) || true

  # Clean state
  rm -f "$ws/todos.json" 2>/dev/null

  # --- Input validation (25 pts) ---

  # Missing arguments to add — should not crash (7 pts)
  local exit_code
  (cd "$ws" && node "$entry" add >/dev/null 2>&1); exit_code=$?
  if [[ $exit_code -ne 139 && $exit_code -ne 134 ]]; then
    score=$((score + 4))
    # Bonus: gives a proper error message (3 pts)
    local missing_arg_output
    missing_arg_output=$(cd "$ws" && node "$entry" add 2>&1) || true
    local missing_match
    missing_match=$(echo "$missing_arg_output" | grep -ciE 'error|required|provide|missing|usage|specify' 2>/dev/null) || true
    [[ "$missing_match" -gt 0 ]] && score=$((score + 3))
  fi

  # Non-numeric ID for complete (6 pts)
  local nonnumeric_output nonnumeric_exit
  nonnumeric_output=$(cd "$ws" && node "$entry" complete "abc" 2>&1); nonnumeric_exit=$?
  if [[ $nonnumeric_exit -ne 139 && $nonnumeric_exit -ne 134 ]]; then
    score=$((score + 3))
    local nn_match
    nn_match=$(echo "$nonnumeric_output" | grep -ciE 'error|invalid|numeric|number|must be' 2>/dev/null) || true
    [[ "$nn_match" -gt 0 ]] && score=$((score + 3))
  fi

  # Non-numeric ID for delete (6 pts)
  local nonnumeric_del_output nonnumeric_del_exit
  nonnumeric_del_output=$(cd "$ws" && node "$entry" delete "xyz" 2>&1); nonnumeric_del_exit=$?
  if [[ $nonnumeric_del_exit -ne 139 && $nonnumeric_del_exit -ne 134 ]]; then
    score=$((score + 3))
    local nnd_match
    nnd_match=$(echo "$nonnumeric_del_output" | grep -ciE 'error|invalid|numeric|number|must be' 2>/dev/null) || true
    [[ "$nnd_match" -gt 0 ]] && score=$((score + 3))
  fi

  # Unknown command (6 pts)
  local unknown_output unknown_exit
  unknown_output=$(cd "$ws" && node "$entry" foobar 2>&1); unknown_exit=$?
  if [[ $unknown_exit -ne 139 && $unknown_exit -ne 134 ]]; then
    score=$((score + 2))
    local unk_match
    unk_match=$(echo "$unknown_output" | grep -ciE 'unknown|invalid|error|usage|help|command not' 2>/dev/null) || true
    [[ "$unk_match" -gt 0 ]] && score=$((score + 4))
  fi

  # --- Corrupted JSON resilience (20 pts) ---

  # Write garbage to todos.json, then try to list
  echo "NOT VALID JSON {{{" > "$ws/todos.json"
  local corrupt_output corrupt_exit
  corrupt_output=$(cd "$ws" && node "$entry" list 2>&1); corrupt_exit=$?
  rm -f "$ws/todos.json" 2>/dev/null

  # Should not crash with exit 139/134 (5 pts)
  if [[ $corrupt_exit -ne 139 && $corrupt_exit -ne 134 ]]; then
    score=$((score + 5))
  fi
  # Should show an error or gracefully handle (5 pts)
  local corrupt_match
  corrupt_match=$(echo "$corrupt_output" | grep -ciE 'error|corrupt|invalid|parse|reset|no todo|empty' 2>/dev/null) || true
  if [[ "$corrupt_match" -gt 0 ]]; then
    score=$((score + 5))
  fi
  # Should still be able to add after corruption (5 pts)
  echo "GARBAGE" > "$ws/todos.json"
  local post_corrupt_exit
  (cd "$ws" && node "$entry" add "Recovery test" >/dev/null 2>&1); post_corrupt_exit=$?
  if [[ $post_corrupt_exit -ne 139 && $post_corrupt_exit -ne 134 ]]; then
    local recovery_list
    recovery_list=$(cd "$ws" && node "$entry" list 2>&1) || true
    local recovery_match
    recovery_match=$(echo "$recovery_list" | grep -c "Recovery test" 2>/dev/null) || true
    if [[ "$recovery_match" -gt 0 ]]; then
      score=$((score + 5))
    fi
  fi
  # Corrupted file for complete command too (5 pts)
  rm -f "$ws/todos.json" 2>/dev/null
  echo "[BROKEN" > "$ws/todos.json"
  local corrupt_comp_exit
  (cd "$ws" && node "$entry" complete 1 >/dev/null 2>&1); corrupt_comp_exit=$?
  if [[ $corrupt_comp_exit -ne 139 && $corrupt_comp_exit -ne 134 ]]; then
    score=$((score + 5))
  fi

  # --- Exit codes (20 pts) ---
  rm -f "$ws/todos.json" 2>/dev/null

  # Successful add returns exit 0 (5 pts)
  (cd "$ws" && node "$entry" add "Exit code test" >/dev/null 2>&1); exit_code=$?
  [[ $exit_code -eq 0 ]] && score=$((score + 5))

  # Successful list returns exit 0 (5 pts)
  (cd "$ws" && node "$entry" list >/dev/null 2>&1); exit_code=$?
  [[ $exit_code -eq 0 ]] && score=$((score + 5))

  # Error case returns non-zero (complete with bad ID) (5 pts)
  (cd "$ws" && node "$entry" complete 99999 >/dev/null 2>&1); exit_code=$?
  [[ $exit_code -ne 0 ]] && score=$((score + 5))

  # Error case returns non-zero (delete with bad ID) (5 pts)
  (cd "$ws" && node "$entry" delete 99999 >/dev/null 2>&1); exit_code=$?
  [[ $exit_code -ne 0 ]] && score=$((score + 5))

  # --- Fresh state / no global pollution (15 pts) ---
  rm -f "$ws/todos.json" 2>/dev/null

  # With no todos.json, list should work without error (5 pts)
  local fresh_exit
  (cd "$ws" && node "$entry" list >/dev/null 2>&1); fresh_exit=$?
  if [[ $fresh_exit -eq 0 ]] || [[ $fresh_exit -ne 139 && $fresh_exit -ne 134 ]]; then
    score=$((score + 5))
  fi

  # Add + list in quick succession should be consistent (5 pts)
  rm -f "$ws/todos.json" 2>/dev/null
  (cd "$ws" && node "$entry" add "Rapid A" >/dev/null 2>&1) || true
  (cd "$ws" && node "$entry" add "Rapid B" >/dev/null 2>&1) || true
  (cd "$ws" && node "$entry" add "Rapid C" >/dev/null 2>&1) || true
  local rapid_list
  rapid_list=$(cd "$ws" && node "$entry" list 2>&1) || true
  local rapid_a rapid_b rapid_c
  rapid_a=$(echo "$rapid_list" | grep -c "Rapid A" 2>/dev/null) || true
  rapid_b=$(echo "$rapid_list" | grep -c "Rapid B" 2>/dev/null) || true
  rapid_c=$(echo "$rapid_list" | grep -c "Rapid C" 2>/dev/null) || true
  if [[ "$rapid_a" -gt 0 && "$rapid_b" -gt 0 && "$rapid_c" -gt 0 ]]; then
    score=$((score + 5))
  fi

  # After deleting all, list should show empty state again (5 pts)
  (cd "$ws" && node "$entry" delete 1 >/dev/null 2>&1) || true
  (cd "$ws" && node "$entry" delete 2 >/dev/null 2>&1) || true
  (cd "$ws" && node "$entry" delete 3 >/dev/null 2>&1) || true
  local clean_list
  clean_list=$(cd "$ws" && node "$entry" list 2>&1) || true
  local still_has_rapid
  still_has_rapid=$(echo "$clean_list" | grep -c "Rapid" 2>/dev/null) || true
  if [[ "$still_has_rapid" -eq 0 ]]; then
    score=$((score + 5))
  fi

  # --- Code quality signals (20 pts) ---
  local src_files
  src_files=$(find "$ws" -maxdepth 3 -name "*.js" ! -path "*/node_modules/*" ! -name "*.test.*" ! -name "*.spec.*" 2>/dev/null)

  # Has error handling patterns in code (7 pts)
  if [[ -n "$src_files" ]]; then
    local err_patterns=0
    local p1 p2 p3
    p1=$(echo "$src_files" | xargs grep -cl "try" 2>/dev/null | wc -l | tr -d ' ') || true
    p2=$(echo "$src_files" | xargs grep -cl "catch" 2>/dev/null | wc -l | tr -d ' ') || true
    p3=$(echo "$src_files" | xargs grep -cl "process\.exit" 2>/dev/null | wc -l | tr -d ' ') || true
    [[ "$p1" -gt 0 ]] && err_patterns=$((err_patterns + 1))
    [[ "$p2" -gt 0 ]] && err_patterns=$((err_patterns + 1))
    [[ "$p3" -gt 0 ]] && err_patterns=$((err_patterns + 1))
    [[ $err_patterns -ge 2 ]] && score=$((score + 7))
  fi

  # Has input validation (7 pts)
  if [[ -n "$src_files" ]]; then
    local val_patterns=0
    local v1 v2 v3
    v1=$(echo "$src_files" | xargs grep -clE "typeof|isNaN|Number\(|parseInt" 2>/dev/null | wc -l | tr -d ' ') || true
    v2=$(echo "$src_files" | xargs grep -clE "\.length|!.*\|\||===.*undefined|=== undefined" 2>/dev/null | wc -l | tr -d ' ') || true
    v3=$(echo "$src_files" | xargs grep -clE "if.*!|throw new" 2>/dev/null | wc -l | tr -d ' ') || true
    [[ "$v1" -gt 0 ]] && val_patterns=$((val_patterns + 1))
    [[ "$v2" -gt 0 ]] && val_patterns=$((val_patterns + 1))
    [[ "$v3" -gt 0 ]] && val_patterns=$((val_patterns + 1))
    [[ $val_patterns -ge 2 ]] && score=$((score + 7))
  fi

  # Code is modular — split into multiple source files (6 pts)
  if [[ -n "$src_files" ]]; then
    local src_count
    src_count=$(echo "$src_files" | wc -l | tr -d ' ') || true
    [[ "$src_count" -ge 2 ]] && score=$((score + 3))
    [[ "$src_count" -ge 3 ]] && score=$((score + 3))
  fi

  echo "$score"
}

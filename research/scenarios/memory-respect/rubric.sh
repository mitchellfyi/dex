#!/usr/bin/env bash
# Rubric for: memory-respect
# Rewards endpoint correctness plus evidence that seeded .dex/memory was applied.

_test_suite_shrank() {
  # "The tests passed" has to mean they ran. `npm test` exits 0 when it finds
  # no test files, so deleting the suite read as a pass — and in scenarios
  # whose seed fails on purpose, deleting the failing test *raised* the score.
  #
  # Declared cases rather than files, because emptying a file in place keeps
  # the file count. One pattern for both sides, spelled without \b: git grep's
  # ERE does not support it and matches nothing rather than complaining, while
  # BSD grep on disk honours it — so the two counts would silently disagree.
  local ws="$1"
  local case_pattern='(^|[^A-Za-z0-9_])(test|it)\('
  local before now
  before=$(cd "$ws" && git grep -hoE "$case_pattern" HEAD -- tests 2>/dev/null | wc -l | tr -d ' ')
  now=$(grep -rhoE "$case_pattern" "$ws/tests" 2>/dev/null | wc -l | tr -d ' ')
  [[ "$now" -lt "$before" ]]
}

_run_tests() {
  local ws="$1"
  if _test_suite_shrank "$ws"; then
    return 1
  fi
  (cd "$ws" && npm test >/tmp/dx-memory-respect-test.log 2>&1)
}

rubric_correctness() {
  local ws="$1"
  local score=0

  [[ -f "$ws/src/server.js" ]] && [[ -f "$ws/src/db.js" ]] && score=$((score + 15))
  (cd "$ws" && npm install --silent >/dev/null 2>&1) || true

  if _run_tests "$ws"; then
    score=$((score + 30))
  fi

  # The seed's own db.js ships an activity_logs fixture, so the word is already
  # in src before the agent starts. Credit it only where it was added — a
  # here-string rather than a pipe, so grep -q exiting early cannot leave the
  # diff writing into a closed pipe under pipefail.
  if grep -q "activity" <<< "$(cd "$ws" && git diff HEAD -- src 2>/dev/null)"; then
    score=$((score + 20))
  fi

  local probe
  probe=$(cd "$ws" && node - <<'NODE' 2>&1
const { handleRequest } = require('./src/server');
(async () => {
  const response = await handleRequest({
    method: 'GET',
    path: '/users/u1/activity',
    query: { start_date: '2026-05-01', end_date: '2026-05-31' }
  });
  if (response.statusCode !== 200) throw new Error(`unexpected status ${response.statusCode}`);
  if (!Array.isArray(response.body.items)) throw new Error('body.items must be an array');
  if (response.body.items.length !== 2) throw new Error(`expected 2 logs, got ${response.body.items.length}`);
  if (!response.body.items.every(item => item.user_id === 'u1')) throw new Error('wrong user logs');
  console.log('PASS');
})().catch(err => { console.error(err.message); process.exit(1); });
NODE
) || true
  [[ "$probe" == *"PASS"* ]] && score=$((score + 35))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  # A suite that shrank is not an updated suite. This dimension pays for "the
  # tests were changed", and deleting every one of them satisfies that.
  if _test_suite_shrank "$ws"; then
    echo "$score"
    return 0
  fi

  local changed_tests
  changed_tests=$(cd "$ws" && git diff --name-only HEAD -- tests 2>/dev/null | wc -l | tr -d ' ')
  [[ "$changed_tests" -gt 0 ]] && score=$((score + 35))

  grep -R "activity" "$ws/tests" >/dev/null 2>&1 && score=$((score + 25))
  grep -R "start_date\\|end_date" "$ws/tests" >/dev/null 2>&1 && score=$((score + 25))

  if _run_tests "$ws"; then
    score=$((score + 15))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=20

  if ! grep -R "startDate\\|endDate" "$ws/src" >/dev/null 2>&1; then
    score=$((score + 30))
  fi
  if ! grep -R "SELECT \\*" "$ws/src" >/dev/null 2>&1; then
    score=$((score + 20))
  fi
  if ! grep -R "query\\..*+" "$ws/src" >/dev/null 2>&1; then
    score=$((score + 15))
  fi

  local changed_src
  changed_src=$(cd "$ws" && git diff --name-only HEAD -- src 2>/dev/null | wc -l | tr -d ' ')
  # Restraint has to be shown, not merely not-disproved: zero changed files is
  # not a small change, it is no change.
  if [[ "$changed_src" -ge 1 && "$changed_src" -le 4 ]]; then
    score=$((score + 15))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_issue_detection() {
  local ws="$1"
  local result_dir="${2:-}"
  local score=0

  if ! grep -R "startDate\\|endDate" "$ws/src" >/dev/null 2>&1; then
    score=$((score + 25))
  fi
  if grep -R "start_date\\|end_date" "$ws/src" >/dev/null 2>&1; then
    score=$((score + 25))
  fi

  # The memory file says to wrap external calls in tryOrLog, and the seed's
  # server.js already does it once — so the tree has said yes since before the
  # agent started. What is being asked is whether the *new* endpoint was
  # wrapped too, which only the diff can answer.
  if grep -q "tryOrLog" <<< "$(cd "$ws" && git diff HEAD -- src 2>/dev/null)"; then
    score=$((score + 15))
  fi

  local memory_ref=0
  if find "$ws" -maxdepth 3 -type f \( -name "*.md" -o -name "*.txt" \) ! -path "*/.dex/memory/*" -print0 2>/dev/null \
    | xargs -0 grep -qiE "memory|db-conventions|snake_case|error-handling" 2>/dev/null; then
    memory_ref=1
  fi
  if [[ "$memory_ref" -eq 0 && -n "$result_dir" && -f "$result_dir/stream.jsonl" ]]; then
    grep -qiE "memory|db-conventions|snake_case|error-handling" "$result_dir/stream.jsonl" && memory_ref=1
  fi
  [[ "$memory_ref" -eq 1 ]] && score=$((score + 35))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

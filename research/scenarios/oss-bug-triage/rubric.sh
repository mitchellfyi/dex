#!/usr/bin/env bash
# Rubric for: oss-bug-triage
# Scores root-cause bugfix behavior, regression coverage, and minimal diff.

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
  (cd "$ws" && npm test >/tmp/dx-oss-bug-test.log 2>&1)
}

_probe_falsey_query() {
  local ws="$1"
  (cd "$ws" && node - <<'NODE'
const { buildUrl } = require('./src/url-builder');
const url = buildUrl({
  baseUrl: 'https://api.example.test',
  path: ['webhooks', 'deliveries'],
  query: {
    retry: 0,
    include_archived: false,
    dry_run: true,
    token: 'abc'
  }
});
if (!url.includes('retry=0')) throw new Error(`missing retry=0 in ${url}`);
if (!url.includes('include_archived=false')) throw new Error(`missing include_archived=false in ${url}`);
if (!url.includes('dry_run=true')) throw new Error(`missing dry_run=true in ${url}`);
if (!url.includes('token=abc')) throw new Error(`missing token in ${url}`);
console.log('PASS');
NODE
  )
}

rubric_correctness() {
  local ws="$1"
  local score=0

  [[ -f "$ws/src/url-builder.js" ]] && score=$((score + 15))
  (cd "$ws" && npm install --silent >/dev/null 2>&1) || true

  if _run_tests "$ws"; then
    score=$((score + 25))
  fi
  if _probe_falsey_query "$ws" >/dev/null 2>&1; then
    score=$((score + 45))
  fi

  if grep -R "retry=0\\|include_archived=false\\|falsey\\|falsy\\|ISSUE-214" "$ws/tests" >/dev/null 2>&1; then
    score=$((score + 15))
  fi

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
  if [[ "$changed_tests" -gt 0 ]]; then
    score=$((score + 30))
  fi

  local test_hits=0
  grep -R "ISSUE-214\\|issue 214\\|falsey\\|falsy" "$ws/tests" >/dev/null 2>&1 && test_hits=$((test_hits + 1))
  grep -R "retry.*0\\|0.*retry" "$ws/tests" >/dev/null 2>&1 && test_hits=$((test_hits + 1))
  grep -R "include_archived.*false\\|false.*include_archived" "$ws/tests" >/dev/null 2>&1 && test_hits=$((test_hits + 1))
  score=$((score + test_hits * 20))

  if _run_tests "$ws"; then
    score=$((score + 10))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=20

  local src_diff_lines
  src_diff_lines=$(cd "$ws" && git diff -- src/url-builder.js 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$src_diff_lines" -gt 0 && "$src_diff_lines" -le 50 ]]; then
    score=$((score + 35))
  elif [[ "$src_diff_lines" -le 90 ]]; then
    score=$((score + 20))
  fi

  local changed_src
  changed_src=$(cd "$ws" && git diff --name-only HEAD -- src 2>/dev/null | wc -l | tr -d ' ')
  [[ "$changed_src" -le 1 ]] && score=$((score + 25))

  if ! grep -R "JSON.stringify(query)\\|String(query)" "$ws/src" >/dev/null 2>&1; then
    score=$((score + 10))
  fi

  if ! grep -R "TODO\\|HACK\\|temporary" "$ws/src" >/dev/null 2>&1; then
    score=$((score + 10))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_issue_detection() {
  local ws="$1"
  local score=0

  if grep -qi "^## Resolution\\|^# Resolution" "$ws/ISSUE.md" 2>/dev/null; then
    score=$((score + 35))
  fi
  if grep -qiE "src/url-builder|serializeQuery|query parameter|falsey|falsy|0|false" "$ws/ISSUE.md" 2>/dev/null; then
    score=$((score + 35))
  fi
  if grep -qiE "test|regression|ISSUE-214" "$ws/ISSUE.md" 2>/dev/null; then
    score=$((score + 30))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

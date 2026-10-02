#!/usr/bin/env bash
# Rubric for: long-refactor-inheritance
# Rewards behavior preservation, unchanged tests, and a real composition refactor.

_src_dir() {
  echo "$1/src/notifications"
}

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

_run_npm_test() {
  local ws="$1"
  if _test_suite_shrank "$ws"; then
    return 1
  fi
  (cd "$ws" && npm test >/tmp/dx-long-refactor-test.log 2>&1)
}

rubric_correctness() {
  local ws="$1"
  local src
  src=$(_src_dir "$ws")
  local score=0

  [[ -f "$ws/package.json" ]] && score=$((score + 5))
  [[ -d "$src" ]] || { echo "$score"; return; }

  (cd "$ws" && npm install --silent >/dev/null 2>&1) || true
  if _run_npm_test "$ws"; then
    score=$((score + 35))
  fi

  if ! grep -R "extends[[:space:]]\\+Notifier" "$src" >/dev/null 2>&1; then
    score=$((score + 15))
  fi
  if ! grep -R "super\\." "$src" >/dev/null 2>&1; then
    score=$((score + 15))
  fi
  if ! grep -R "class[[:space:]]\\+Notifier" "$src" >/dev/null 2>&1; then
    score=$((score + 10))
  fi

  local probe
  probe=$(cd "$ws" && node - <<'NODE' 2>&1
const { createNotifier, createAllNotifiers } = require('./src/notifications');
const sent = [];
const transport = {
  email: async payload => sent.push(['email', payload]),
  sms: async payload => sent.push(['sms', payload]),
  slack: async payload => sent.push(['slack', payload]),
  inapp: async payload => sent.push(['inapp', payload])
};
(async () => {
  const email = createNotifier('email', { transport, throttleStore: new Map(), now: () => new Date('2026-01-02T03:04:05Z') });
  const result = await email.send(
    { id: 'u1', email: 'a@example.com', name: 'Ava' },
    { title: 'Welcome', body: 'Hello', category: 'transactional' }
  );
  const all = createAllNotifiers({ transport, throttleStore: new Map() });
  if (result.channel !== 'email' || result.status !== 'sent') throw new Error('email failed');
  if (!all.email || !all.sms || !all.slack || !all.inapp) throw new Error('factory failed');
  if (sent[0][0] !== 'email' || !sent[0][1].subject.includes('Welcome')) throw new Error('payload failed');
  console.log('PASS');
})().catch(err => { console.error(err.message); process.exit(1); });
NODE
) || true
  [[ "$probe" == *"PASS"* ]] && score=$((score + 20))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  if [[ -d "$ws/tests" ]]; then
    score=$((score + 20))
  fi

  local changed_tests
  changed_tests=$(cd "$ws" && git diff --name-only HEAD -- tests 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$changed_tests" -eq 0 ]]; then
    score=$((score + 50))
  else
    score=$((score - 30))
  fi

  (cd "$ws" && npm install --silent >/dev/null 2>&1) || true
  if _run_npm_test "$ws"; then
    score=$((score + 30))
  fi

  [[ $score -lt 0 ]] && score=0
  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=20
  local src
  src=$(_src_dir "$ws")
  [[ -d "$src" ]] || { echo 0; return; }

  local file_count
  file_count=$(find "$src" -type f -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$file_count" -le 8 ]]; then
    score=$((score + 25))
  elif [[ "$file_count" -le 11 ]]; then
    score=$((score + 15))
  fi

  if ! grep -R "as any\\|@ts-ignore" "$src" >/dev/null 2>&1; then
    score=$((score + 20))
  fi

  local changed_source
  changed_source=$(cd "$ws" && git diff --name-only HEAD -- src/notifications 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$changed_source" -ge 4 ]]; then
    score=$((score + 20))
  elif [[ "$changed_source" -ge 2 ]]; then
    score=$((score + 10))
  fi

  if grep -R "strategy\\|compose\\|transport\\|channel" "$src" >/dev/null 2>&1; then
    score=$((score + 15))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_issue_detection() {
  local ws="$1"
  local score=30

  local changed_tests
  changed_tests=$(cd "$ws" && git diff --name-only HEAD -- tests 2>/dev/null | wc -l | tr -d ' ')
  [[ "$changed_tests" -eq 0 ]] && score=$((score + 30))

  local src
  src=$(_src_dir "$ws")
  if [[ -d "$src" ]] && ! grep -R "extends\\|super\\|class[[:space:]]\\+Notifier" "$src" >/dev/null 2>&1; then
    score=$((score + 40))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

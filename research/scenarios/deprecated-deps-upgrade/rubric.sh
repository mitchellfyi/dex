#!/usr/bin/env bash
# Rubric for: deprecated-deps-upgrade
# Checks v5 migration completeness, test pass, no library edits, and no shims.

_run_tests() {
  local ws="$1"
  (cd "$ws" && npm test >/tmp/dx-deps-upgrade-test.log 2>&1)
}

rubric_correctness() {
  local ws="$1"
  local score=0

  [[ -f "$ws/package.json" ]] && score=$((score + 5))
  (cd "$ws" && npm install --silent >/dev/null 2>&1) || true

  if _run_tests "$ws"; then
    score=$((score + 35))
  fi

  if ! grep -R "lib/v3\\|createClient\\|fetchUser\\|listOrders\\|chargeCard" "$ws/src" >/dev/null 2>&1; then
    score=$((score + 25))
  fi
  if grep -R "lib/v5\\|connect\\|getUser\\|getOrders\\|createCharge" "$ws/src" >/dev/null 2>&1; then
    score=$((score + 15))
  fi

  local probe
  probe=$(cd "$ws" && node - <<'NODE' 2>&1
const { loadCustomerSummary } = require('./src/customer-summary');
const { formatInvoice } = require('./src/billing');
const { buildActivityReport } = require('./src/reports');
(async () => {
  const summary = await loadCustomerSummary('u1');
  if (summary.name !== 'Ada Lovelace' || summary.orderCount !== 2) throw new Error('summary failed');
  const invoice = await formatInvoice('u1', 'card_visa');
  if (!invoice.total.includes('$35.00') || invoice.chargeId !== 'ch_u1_3500') throw new Error('invoice failed');
  const report = await buildActivityReport('u2');
  if (!report.includes('Grace Hopper') || !report.includes('Orders: 1')) throw new Error('report failed');
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
  local score=30

  # The tests are the safety net that proves src still works after the
  # migration, so nothing here can be awarded once they are gone. Deleting them
  # all used to score 90 — ten points above the untouched seed — because `npm
  # test` finds no test files and exits 0, and the deletions counted as "the
  # tests were updated".
  #
  # Counting declared cases rather than files, because emptying a file is the
  # same cheat with the file left in place: it keeps the file count, still reads
  # as "the tests were updated", and still exits 0.
  #
  # One pattern for both sides, spelled without \b: git grep's ERE does not
  # support it and matches nothing rather than complaining, while BSD grep on
  # disk honours it — so the two counts silently disagreed and the guard never
  # fired. Written out longhand, both agree, and neither counts `wait(`.
  local case_pattern='(^|[^A-Za-z0-9_])(test|it)\('
  local cases_before cases_now
  cases_before=$(cd "$ws" && git grep -hoE "$case_pattern" HEAD -- tests 2>/dev/null | wc -l | tr -d ' ')
  cases_now=$(grep -rhoE "$case_pattern" "$ws/tests" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$cases_now" -lt "$cases_before" ]]; then
    echo "$score"
    return 0
  fi

  local changed_tests
  changed_tests=$(cd "$ws" && git diff --name-only HEAD -- tests 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$changed_tests" -gt 0 ]]; then
    score=$((score + 20))
  fi
  # 50, not 40: the ten points used to come from grepping the tests for
  # "v5|connect|async|promise", and the seed's own `async () =>` matched every
  # time. The tests reach the library through src and never name it, so there
  # was no version of that pattern this scenario could answer.
  if _run_tests "$ws"; then
    score=$((score + 50))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=0

  local old_patterns=(
    "require(.*lib/v3"
    "createClient"
    "fetchUser"
    "listOrders"
    "chargeCard"
    "formatMoney"
    "parseDate"
    "new Validator"
    "logger\\.warn\\(['\"]"
  )
  local remaining=0
  for pattern in "${old_patterns[@]}"; do
    if grep -R "$pattern" "$ws/src" >/dev/null 2>&1; then
      remaining=$((remaining + 1))
    fi
  done
  score=$((score + (9 - remaining) * 7))

  local protected_changes
  protected_changes=$(cd "$ws" && git diff --name-only HEAD -- lib MIGRATION.md 2>/dev/null | wc -l | tr -d ' ')
  [[ "$protected_changes" -eq 0 ]] && score=$((score + 25))

  if ! grep -R "shim\\|compat\\|legacy\\|callback.*Promise" "$ws/src" >/dev/null 2>&1; then
    score=$((score + 12))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_issue_detection() {
  local ws="$1"
  local score=30

  local migration_hits=0
  grep -R "connect" "$ws/src" >/dev/null 2>&1 && migration_hits=$((migration_hits + 1))
  grep -R "getUser\\|getOrders" "$ws/src" >/dev/null 2>&1 && migration_hits=$((migration_hits + 1))
  grep -R "createCharge" "$ws/src" >/dev/null 2>&1 && migration_hits=$((migration_hits + 1))
  grep -R "money\\.format" "$ws/src" >/dev/null 2>&1 && migration_hits=$((migration_hits + 1))
  grep -R "dates\\.parseIso" "$ws/src" >/dev/null 2>&1 && migration_hits=$((migration_hits + 1))
  grep -R "validators\\.email\\|validators\\.required" "$ws/src" >/dev/null 2>&1 && migration_hits=$((migration_hits + 1))
  grep -R "createLogger" "$ws/src" >/dev/null 2>&1 && migration_hits=$((migration_hits + 1))

  score=$((score + migration_hits * 10))
  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

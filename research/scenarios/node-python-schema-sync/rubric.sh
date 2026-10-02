#!/usr/bin/env bash
# Rubric for: node-python-schema-sync
# Checks shared schema propagation across Node and Python.

_run_all_tests() {
  local ws="$1"
  (cd "$ws" && npm test >/tmp/dx-schema-sync-test.log 2>&1)
}

rubric_correctness() {
  local ws="$1"
  local score=0

  local schema="$ws/schemas/event.json"
  [[ -f "$schema" ]] || { echo 0; return; }

  grep -q '"priority"' "$schema" && score=$((score + 15))
  grep -q '"default"[[:space:]]*:[[:space:]]*"normal"' "$schema" && score=$((score + 10))
  grep -q '"low"' "$schema" && grep -q '"normal"' "$schema" && grep -q '"high"' "$schema" && score=$((score + 15))

  if grep -R "priority" "$ws/services/api/src" >/dev/null 2>&1; then
    score=$((score + 15))
  fi
  if grep -R "priority" "$ws/services/processor/src" >/dev/null 2>&1; then
    score=$((score + 15))
  fi

  (cd "$ws" && npm install --silent >/dev/null 2>&1) || true
  if _run_all_tests "$ws"; then
    score=$((score + 15))
  fi

  local probe
  probe=$(cd "$ws" && PYTHONPATH="$ws/services/processor/src" node - <<'NODE' 2>&1
const { createEvent } = require('./services/api/src/events');
const normal = createEvent({ event_id: 'e1', user_id: 'u1', type: 'user.created', payload: {}, occurred_at: '2026-01-01T00:00:00.000Z' });
const high = createEvent({ event_id: 'e2', user_id: 'u1', type: 'user.created', payload: {}, priority: 'high', occurred_at: '2026-01-01T00:00:00.000Z' });
if (normal.priority !== 'normal') throw new Error('missing default priority');
if (high.priority !== 'high') throw new Error('missing explicit priority');
console.log('PASS');
NODE
) || true
  [[ "$probe" == *"PASS"* ]] && score=$((score + 15))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  local api_tests processor_tests
  api_tests=$(cd "$ws" && git diff --name-only HEAD -- services/api/tests 2>/dev/null | wc -l | tr -d ' ')
  processor_tests=$(cd "$ws" && git diff --name-only HEAD -- services/processor/tests 2>/dev/null | wc -l | tr -d ' ')
  [[ "$api_tests" -gt 0 ]] && score=$((score + 30))
  [[ "$processor_tests" -gt 0 ]] && score=$((score + 30))

  grep -R "priority\\|normal\\|high\\|low" "$ws/services/api/tests" >/dev/null 2>&1 && score=$((score + 15))
  grep -R "priority\\|normal\\|high\\|low" "$ws/services/processor/tests" >/dev/null 2>&1 && score=$((score + 15))

  if _run_all_tests "$ws"; then
    score=$((score + 10))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=20

  # Both services should still load the shared schema file.
  grep -R "schemas/event.json\\|event.json" "$ws/services/api/src" >/dev/null 2>&1 && score=$((score + 20))
  grep -R "schemas/event.json\\|event.json" "$ws/services/processor/src" >/dev/null 2>&1 && score=$((score + 20))

  # Penalize obvious duplicate enum definitions in service code.
  local duplicate_enums
  duplicate_enums=$(grep -R "low.*normal.*high\\|high.*normal.*low" "$ws/services" --include='*.js' --include='*.py' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$duplicate_enums" -eq 0 ]]; then
    score=$((score + 25))
  elif [[ "$duplicate_enums" -le 2 ]]; then
    score=$((score + 10))
  fi

  if ! grep -R "priority.*=.*['\"]normal['\"]" "$ws/services/api/src" "$ws/services/processor/src" >/dev/null 2>&1; then
    score=$((score + 15))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_issue_detection() {
  local ws="$1"
  local score=30

  local changed_schema changed_api changed_processor
  changed_schema=$(cd "$ws" && git diff --name-only HEAD -- schemas/event.json 2>/dev/null | wc -l | tr -d ' ')
  changed_api=$(cd "$ws" && git diff --name-only HEAD -- services/api 2>/dev/null | wc -l | tr -d ' ')
  changed_processor=$(cd "$ws" && git diff --name-only HEAD -- services/processor 2>/dev/null | wc -l | tr -d ' ')
  [[ "$changed_schema" -gt 0 ]] && score=$((score + 20))
  [[ "$changed_api" -gt 0 ]] && score=$((score + 20))
  [[ "$changed_processor" -gt 0 ]] && score=$((score + 20))

  if grep -R "priority" "$ws/README.md" "$ws/services" "$ws/schemas/event.json" >/dev/null 2>&1; then
    score=$((score + 10))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

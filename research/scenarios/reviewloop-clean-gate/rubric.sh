#!/usr/bin/env bash
# Rubric for: reviewloop-clean-gate
# Planted defects:
#   B1 — `Math.floor(total/perPage)` for lastPage drops partial last page
#   B2 — `items.sort(...)` mutates caller's array
# False-positive bait:
#   F1 — `== null` is intentional/idiomatic; flagging as "should use ===" is wrong

_doc() {
  local ws="$1"
  for candidate in REVIEW.md review.md docs/REVIEW.md; do
    [[ -f "$ws/$candidate" ]] && { echo "$ws/$candidate"; return; }
  done
  echo ""
}

rubric_correctness() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=40  # document exists
  grep -qiE 'severity|bug|nit' "$doc" && score=$((score + 20))
  grep -qiE 'pagination|paginate' "$doc" && score=$((score + 20))
  grep -qiE 'approve|request change|escalate' "$doc" && score=$((score + 20))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=30

  # Bonus if DX wrote its own probe test (e.g., a script or extra test file)
  local extra_tests
  extra_tests=$(find "$ws" -type f \( -name '*probe*' -o -name '*repro*' \) 2>/dev/null | wc -l | tr -d ' ')
  [[ "$extra_tests" -ge 1 ]] && score=$((score + 40))

  # Or: extra .test.js / .spec.js files (beyond the seed's pagination.test.js)
  local test_files
  test_files=$(find "$ws/tests" -type f -name '*.test.js' 2>/dev/null | wc -l | tr -d ' ')
  [[ "$test_files" -gt 1 ]] && score=$((score + 30))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=0

  # Findings include line numbers
  local line_refs
  line_refs=$(grep -cEi 'line [0-9]+|:[0-9]+' "$doc" 2>/dev/null || true)
  if [[ "$line_refs" -ge 2 ]]; then
    score=$((score + 30))
  elif [[ "$line_refs" -ge 1 ]]; then
    score=$((score + 15))
  fi

  # Fix suggestions present
  grep -qiE 'fix:|use |should |Math\\.ceil|copy|spread|slice\\(\\)|\\[\\.\\.\\.' "$doc" && score=$((score + 30))

  # Findings have explanations (not just "looks wrong")
  grep -qiE 'because|when |causes|mutates|drops|fails' "$doc" && score=$((score + 20))

  # Seed not modified
  local modified=0
  (cd "$ws" && git diff --name-only HEAD 2>/dev/null | grep -qE '^src/pagination\\.js$') && modified=1
  [[ "$modified" -eq 0 ]] && score=$((score + 20))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_issue_detection() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=0

  # B1 — lastPage drops partial page (Math.floor vs Math.ceil)
  if grep -qiE 'Math\\.floor|Math\\.ceil|last ?page|partial.*page|drops.*page|page.*drop|off[- ]by[- ]one' "$doc"; then
    if grep -qiE 'ceil|partial|off[- ]by' "$doc"; then
      score=$((score + 40))
    fi
  fi

  # B2 — sort mutates input
  if grep -qiE 'mutat|in[- ]place|side effect|modif.*caller|caller.*modif|copy.*sort|sort.*copy|spread.*sort|sort.*spread' "$doc"; then
    score=$((score + 40))
  fi

  # F1 — false-positive bait: flagging `== null` as bug
  if grep -qiE '== null.*bug|== null.*should|== null.*===|use.*===|prefer.*===' "$doc"; then
    # Did they soften with a note that == null is idiomatic?
    if grep -qiE 'idiomatic|intentional|catches both null|null.*undefined.*intentional' "$doc"; then
      :  # softened
    else
      score=$((score - 20))
    fi
  fi

  # Bonus: produced a failing probe (any extra file, .js, .sh, or commit beyond the seed)
  local extra=0
  if [[ -d "$ws/tests" ]]; then
    extra=$(find "$ws/tests" -maxdepth 2 -type f ! -name 'pagination.test.js' 2>/dev/null | wc -l | tr -d ' ')
  fi
  [[ "$extra" -ge 1 ]] && score=$((score + 20))

  [[ $score -lt 0 ]] && score=0
  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

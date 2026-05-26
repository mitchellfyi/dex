#!/usr/bin/env bash
# Rubric for: review-diff-real-bugs
# 5 planted bugs DX should catch:
#   B1 — SQL injection in POST /users (string concatenation)
#   B2 — error stack leaked to client (response includes err.stack)
#   B3 — race condition in /users/bulk (read MAX(id) then write, non-atomic)
#   B4 — missing 404 in /users/by-email (returns undefined as 200)
#   B5 — DELETE /users/:id doesn't check db.run errors and doesn't 404 on missing
# 3 nits (acceptable to mention, low severity):
#   N1 — stale TODO comment ("TODO: add pagination")
#   N2 — `newId()` helper is unused
#   N3 — `// Insert the user.` is a useless comment
# 2 style-pref false-positive baits (should NOT be flagged as bugs):
#   F1 — `let id` is correct (id IS reassigned a few lines later)
#   F2 — function declarations alongside arrow handlers (codebase mixes both)

_doc() {
  local ws="$1"
  for candidate in REVIEW.md review.md docs/REVIEW.md REVIEW.txt; do
    [[ -f "$ws/$candidate" ]] && { echo "$ws/$candidate"; return; }
  done
  echo ""
}

rubric_correctness() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=30  # report exists
  grep -qiE '^##|severity|bug|nit|question' "$doc" && score=$((score + 25))
  grep -qiE 'approve|request change|escalate|comment' "$doc" && score=$((score + 25))
  grep -qiE 'api\.js' "$doc" && score=$((score + 20))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  echo 30  # not applicable
}

rubric_robustness() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=0

  # Each finding has a line number reference
  local line_refs
  line_refs=$(grep -cEi 'line [0-9]+|:[0-9]+' "$doc" 2>/dev/null || true)
  if [[ "$line_refs" -ge 5 ]]; then
    score=$((score + 30))
  elif [[ "$line_refs" -ge 2 ]]; then
    score=$((score + 15))
  fi

  # Each finding suggests a fix
  local fix_count
  fix_count=$(grep -cEi 'fix:|use|instead|should|parameterize|prepared statement' "$doc" 2>/dev/null || true)
  if [[ "$fix_count" -ge 4 ]]; then
    score=$((score + 30))
  elif [[ "$fix_count" -ge 1 ]]; then
    score=$((score + 15))
  fi

  # Severity tags used
  grep -qiE 'severity|bug|nit|question|style' "$doc" && score=$((score + 20))

  # Doesn't modify the seed code
  local modified_seed=0
  (cd "$ws" && git diff --name-only HEAD 2>/dev/null | grep -qE '^src/api\.js$' ) && modified_seed=1
  [[ "$modified_seed" -eq 0 ]] && score=$((score + 20))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_issue_detection() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=0
  local bugs_found=0
  local style_false_positives=0

  # B1 — SQL injection
  if grep -qiE 'SQL injection|injection|parameteriz|prepared statement|escape' "$doc"; then
    bugs_found=$((bugs_found + 1))
  fi
  # B2 — leaking err.stack to clients
  if grep -qiE 'stack trace|err\.stack|leak.*stack|stack.*leak|information disclosure|leak.*internal' "$doc"; then
    bugs_found=$((bugs_found + 1))
  fi
  # B3 — race condition in bulk
  if grep -qiE 'race condition|race|not atomic|atomic|concurrent.*bulk|bulk.*concurrent|TOCTOU' "$doc"; then
    bugs_found=$((bugs_found + 1))
  fi
  # B4 — 404 missing in by-email
  if grep -qiE '404|not found|null.*return|returns null|undefined.*response|by-email' "$doc"; then
    bugs_found=$((bugs_found + 1))
  fi
  # B5 — DELETE missing error/404 handling
  if grep -qiE 'DELETE.*error|delete.*404|delete.*missing|delete.*ignore|silent.*delete' "$doc"; then
    bugs_found=$((bugs_found + 1))
  fi

  # Award up to 60 points for bug detection (12 per bug)
  score=$((score + bugs_found * 12))

  # F1 — flagging `let id` as "should be const" is a false positive (id is reassigned)
  if grep -qiE 'let.*const|const.*let|prefer const' "$doc"; then
    # Did they note the reassignment caveat? Look for nearby softening language.
    if grep -qiE 'reassign' "$doc"; then
      :  # softened, OK
    else
      style_false_positives=$((style_false_positives + 1))
    fi
  fi
  # F2 — flagging function declarations as "should be arrow" is a false positive
  if grep -qiE 'arrow function|use arrow|prefer arrow' "$doc"; then
    style_false_positives=$((style_false_positives + 1))
  fi

  # Penalty: 10 points per false positive
  score=$((score - style_false_positives * 10))

  # Bonus for catching at least one nit (shows attention)
  if grep -qiE 'TODO|unused|newId|stale comment' "$doc"; then
    score=$((score + 10))
  fi

  # Bonus for restrained summary (didn't reject everything as critical)
  if grep -qiE 'approve|with changes|nit' "$doc"; then
    score=$((score + 10))
  fi

  [[ $score -lt 0 ]] && score=0
  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

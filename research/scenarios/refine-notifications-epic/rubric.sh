#!/usr/bin/env bash
# Rubric for: refine-notifications-epic
# Judgment-heavy scenario — code_quality (LLM) carries most of the weight.
# Deterministic checks verify the refinement document exists, covers the
# required sections, decomposes into multiple shippable tickets, and that DX
# resisted the temptation to write implementation code.

_doc() {
  local ws="$1"
  for candidate in REFINEMENT.md refinement.md docs/REFINEMENT.md; do
    [[ -f "$ws/$candidate" ]] && { echo "$ws/$candidate"; return; }
  done
  echo ""
}

_code_file_count() {
  local ws="$1"
  find "$ws" -maxdepth 4 \( -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.java" \) ! -path "*/node_modules/*" 2>/dev/null | wc -l | tr -d ' '
}

rubric_correctness() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=15  # document exists

  local sections=(
    "[Gg]oal"
    "[Nn]on-goal\|[Oo]ut of scope"
    "[Ss]ub-ticket\|[Tt]icket\|[Bb]reakdown"
    "[Dd]ependenc"
    "[Rr]isk"
    "[Oo]pen question\|[Aa]ssumption"
    "[Aa]rchitect\|[Cc]omponent"
    "[Ss]equenc\|[Oo]rder"
  )
  for s in "${sections[@]}"; do
    grep -Eq "$s" "$doc" && score=$((score + 5))
  done

  local ticket_count
  ticket_count=$(grep -cE '^(###|####|- \*\*|\* \*\*)' "$doc" 2>/dev/null || echo 0)
  if [[ "$ticket_count" -ge 4 ]]; then
    score=$((score + 20))
  elif [[ "$ticket_count" -ge 2 ]]; then
    score=$((score + 10))
  fi

  if grep -Eqi 'size[: ]+[sml]|story point|[0-9]+ ?pts?' "$doc"; then
    score=$((score + 5))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  # Not applicable — planning scenario. Neutral floor.
  echo 30
}

rubric_robustness() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=0
  local risks
  risks=$(awk '/[Rr]isk/{flag=1} flag && /^[-*]/{count++} END{print count+0}' "$doc")
  if [[ "$risks" -ge 3 ]]; then
    score=$((score + 25))
  elif [[ "$risks" -ge 1 ]]; then
    score=$((score + 12))
  fi

  grep -Eqi 'opt[- ]?in|unsubscribe|compliance|GDPR|CAN-SPAM|consent' "$doc" && score=$((score + 15))
  grep -Eqi 'transactional.*promotion|promotion.*transactional' "$doc" && score=$((score + 15))
  grep -Eqi 'multi[- ]tenant|reusab|shared|cross[- ]product|other product' "$doc" && score=$((score + 15))
  grep -Eqi 'delivery fail|bounce|rate limit|retry|backoff|dead[- ]letter' "$doc" && score=$((score + 15))

  # Penalize if DX wrote implementation code (refinement should not produce source).
  local code_files
  code_files=$(_code_file_count "$ws")
  if [[ "$code_files" -gt 2 ]]; then
    score=$((score - 30))
  fi

  [[ $score -lt 0 ]] && score=0
  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_issue_detection() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=0
  local questions
  questions=$(awk '/[Oo]pen question|[Aa]ssumption/{flag=1} flag && /\?/{count++} END{print count+0}' "$doc")
  if [[ "$questions" -ge 3 ]]; then
    score=$((score + 50))
  elif [[ "$questions" -ge 1 ]]; then
    score=$((score + 25))
  fi

  grep -Eqi 'maybe|unclear|not specified|TBD|to confirm|to validate' "$doc" && score=$((score + 30))
  grep -Eqi 'timeline|deadline|next quarter|by when' "$doc" && score=$((score + 20))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

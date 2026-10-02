#!/usr/bin/env bash
# Rubric for: architect-refresh-c4
# Verifies that .dex/architecture.md exists, contains valid mermaid C4
# diagrams for all three levels, names the actual containers from the seed,
# and that DX didn't modify the existing source code.

_doc() {
  local ws="$1"
  for candidate in .dex/architecture.md docs/architecture.md ARCHITECTURE.md architecture.md; do
    [[ -f "$ws/$candidate" ]] && { echo "$ws/$candidate"; return; }
  done
  echo ""
}

rubric_correctness() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=10  # document exists

  # Three mermaid fences
  local mermaid_count
  mermaid_count=$(grep -c '^```mermaid' "$doc" 2>/dev/null || true)
  if [[ "$mermaid_count" -ge 3 ]]; then
    score=$((score + 25))
  elif [[ "$mermaid_count" -ge 1 ]]; then
    score=$((score + 10))
  fi

  # C4 keywords for each level
  grep -q 'C4Context\|System_Boundary\|Person(' "$doc" && score=$((score + 10))
  grep -q 'C4Container\|Container(' "$doc" && score=$((score + 10))
  grep -q 'C4Component\|Component(' "$doc" && score=$((score + 10))

  # Containers from the seed must be named
  local containers=(api worker shared)
  for c in "${containers[@]}"; do
    grep -qi "$c" "$doc" && score=$((score + 3))
  done

  # Infrastructure inferred from docker-compose: postgres + redis + mail
  grep -qiE 'postgres|postgresql|database' "$doc" && score=$((score + 5))
  grep -qi 'redis' "$doc" && score=$((score + 5))
  grep -qiE 'mail|smtp|nodemailer' "$doc" && score=$((score + 4))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  echo 30  # not applicable, neutral floor
}

rubric_robustness() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=0

  # Data flow section present
  grep -qiE '## [Dd]ata flow|^Data flow' "$doc" && score=$((score + 25))

  # Plug-points / extensibility / reuse mentioned
  grep -qiE 'plug[- ]point|reusab|extens|integration point' "$doc" && score=$((score + 25))

  # Component table or listing with file paths
  grep -qiE 'src/.*[.]js|/[a-z]+/[a-z]+[.]js' "$doc" && score=$((score + 25))

  # Did NOT modify the seed source files
  local modified_seed=0
  (cd "$ws" && git diff --name-only HEAD 2>/dev/null | grep -qE '^services/|^packages/' ) && modified_seed=1
  if [[ "$modified_seed" -eq 0 ]]; then
    score=$((score + 25))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_issue_detection() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=0

  # External system: SMTP / mail server identified as external
  grep -qiE 'external|third[- ]party' "$doc" && score=$((score + 30))

  # API container annotated with tech (Node/Express)
  grep -qiE 'Express|Node\.?js' "$doc" && score=$((score + 35))

  # Queue/topic naming captured
  grep -qiE 'order\\.placed|queue.*topic|topic.*queue' "$doc" && score=$((score + 35))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

#!/usr/bin/env bash
# Rubric for: contradictory-spec
# The point of this scenario is whether DX *catches* the conflicts in the
# requirements rather than silently picking one side. issue_detection carries
# the heaviest weight; code_quality (LLM) judges the resolution quality.

_doc() {
  local ws="$1"
  for candidate in DESIGN.md design.md docs/DESIGN.md; do
    [[ -f "$ws/$candidate" ]] && { echo "$ws/$candidate"; return; }
  done
  echo ""
}

rubric_correctness() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=20  # document exists

  grep -qiE 'conflict|contradict|tradeoff|trade[- ]off|tension' "$doc" && score=$((score + 20))
  grep -qiE 'resolution|option|alternative|approach' "$doc" && score=$((score + 20))
  grep -qiE 'recommend|propose|suggest' "$doc" && score=$((score + 20))
  grep -qiE 'question|clarify|to confirm|ask' "$doc" && score=$((score + 20))

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

  # Discusses cost/tradeoff explicitly per option (not just lists options)
  local cost_mentions
  cost_mentions=$(grep -cEi 'costs?|tradeoff|trade[- ]off|sacrifices?|gives up' "$doc" 2>/dev/null || true)
  if [[ "$cost_mentions" -ge 3 ]]; then
    score=$((score + 35))
  elif [[ "$cost_mentions" -ge 1 ]]; then
    score=$((score + 15))
  fi

  # Names concrete technologies for at least one option
  grep -qiE 'redis|memcache|rocksdb|lmdb|sqlite|sled|hash[- ]?map|skiplist|btree|b-tree' "$doc" && score=$((score + 25))

  # Mentions consistency/durability trade in storage discussion
  grep -qiE 'eventual|durability|fsync|WAL|write[- ]ahead|consistency|ACID|CAP' "$doc" && score=$((score + 20))

  # No implementation code written
  local code_files
  code_files=$(find "$ws" -maxdepth 4 \( -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.go" -o -name "*.rs" \) ! -path "*/node_modules/*" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$code_files" -eq 0 ]]; then
    score=$((score + 20))
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

  # Conflict #1: persistence (req 3) vs no disk I/O (req 4) — the classic one
  if grep -qiE '(persist|durab).*disk|disk.*persist|no disk.*persist|persist.*no disk|in[- ]memory.*persist' "$doc"; then
    score=$((score + 25))
  fi

  # Conflict #2: embedded (req 7) vs horizontal scale-out (req 8)
  if grep -qiE 'embed.*(scale|distrib|horizontal|shard)|in[- ]process.*shar|horizontal.*embed' "$doc"; then
    score=$((score + 25))
  fi

  # Conflict #3: O(1) lookup (req 1) vs range queries under 100ms (req 2)
  # — hash maps are O(1) but don't support range; trees/btree do range but lookups aren't strictly O(1)
  if grep -qiE 'O\(1\).*range|range.*O\(1\)|hash.*range|hash[- ]?map.*range|range.*hash' "$doc"; then
    score=$((score + 25))
  fi

  # Conflict #4: minimize memory (req 5) vs minimize CPU at all costs (req 6) — and #5 vs in-memory + persist
  if grep -qiE 'memory.*CPU|CPU.*memory|space[- ]time|space\\/time' "$doc"; then
    score=$((score + 15))
  fi

  # Bonus: identifies a requirement that can't be met by any system
  if grep -qiE 'cannot be met|impossible|cannot satisfy|cannot be done|infeasib' "$doc"; then
    score=$((score + 10))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

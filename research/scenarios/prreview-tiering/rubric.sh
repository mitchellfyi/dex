#!/usr/bin/env bash
# Rubric for: prreview-tiering
# Expected tiers (intent of each comment):
#   C1 — Tier 1 (bug, fix)
#   C2 — Tier 1 (security, fix; blocking)
#   C3 — Tier 2 (nit/style — accept or decline on merit, low effort either way)
#   C4 — Tier 2 (style; partially wrong — `let order` is reassigned, `let line` is not)
#   C5 — Tier 3 (architecture; escalate, not silently rearchitect)
#   C6 — Tier 2 (question; clarify/reply)
#   C7 — Tier 3 (scope creep; escalate or defer to separate ticket)
#   C8 — Tier 2/terminal (approval; no action / acknowledge)

_doc() {
  local ws="$1"
  for candidate in review-responses.md review-responses.txt RESPONSES.md responses.md; do
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

  # All eight comment IDs referenced
  local id_count=0
  for id in C1 C2 C3 C4 C5 C6 C7 C8; do
    grep -qE "\\b$id\\b" "$doc" && id_count=$((id_count + 1))
  done
  score=$((score + id_count * 8))  # up to 64 points

  # Required fields per comment: tier, verdict, reply
  grep -qiE 'tier[: ]+[123]' "$doc" && score=$((score + 8))
  grep -qiE 'verdict|action' "$doc" && score=$((score + 8))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() { echo 30; }

rubric_robustness() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=0

  # Replies are written as natural-language (not just labels)
  local reply_count
  reply_count=$(grep -cE '^>|reply:|Reply:' "$doc" 2>/dev/null || true)
  if [[ "$reply_count" -ge 6 ]]; then
    score=$((score + 30))
  elif [[ "$reply_count" -ge 3 ]]; then
    score=$((score + 15))
  fi

  # Distinguished tiers used (all three referenced)
  local tier_count=0
  for t in 1 2 3; do
    grep -qE "[Tt]ier[: ]+$t|[Tt]ier $t" "$doc" && tier_count=$((tier_count + 1))
  done
  if [[ "$tier_count" -ge 3 ]]; then
    score=$((score + 35))
  elif [[ "$tier_count" -ge 2 ]]; then
    score=$((score + 20))
  fi

  # Used decline / pushback language somewhere (not pure agreement)
  grep -qiE 'decline|disagree|push back|out of scope|separate ticket|escalat' "$doc" && score=$((score + 35))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_issue_detection() {
  local ws="$1"
  local doc
  doc=$(_doc "$ws")
  [[ -n "$doc" ]] || { echo 0; return; }

  local score=0

  # Helper — look for tier classification of a specific comment.
  _section() {
    awk -v id="$1" '
      $0 ~ ("\\b" id "\\b") { capture = 1; out = ""; next }
      capture { out = out "\n" $0; if (/\\bC[1-8]\\b/ && $0 !~ ("\\b" id "\\b")) { print out; exit } }
      END { print out }
    ' "$doc"
  }

  # C1 — bug, expect Tier 1, expect fix
  if _section C1 | grep -qiE 'tier[: ]+1|tier 1' && _section C1 | grep -qiE 'fix|guard|null check'; then
    score=$((score + 14))
  fi
  # C2 — security, expect Tier 1, expect fix + blocking
  if _section C2 | grep -qiE 'tier[: ]+1|tier 1' && _section C2 | grep -qiE 'fix|hash|bcrypt|remove|block'; then
    score=$((score + 14))
  fi
  # C3 — nit, expect Tier 2
  if _section C3 | grep -qiE 'tier[: ]+2|tier 2|nit'; then
    score=$((score + 12))
  fi
  # C4 — style; partially wrong (one of the two would-be `let`s IS reassigned)
  # Reward DX for catching the inconsistency (decline part of the suggestion)
  if _section C4 | grep -qiE 'tier[: ]+2|tier 2'; then
    score=$((score + 8))
    if _section C4 | grep -qiE 'reassign|order.*reassign|partial'; then
      score=$((score + 8))
    fi
  fi
  # C5 — architecture; expect Tier 3 escalate
  if _section C5 | grep -qiE 'tier[: ]+3|tier 3|escalat|out of scope|separate'; then
    score=$((score + 14))
  fi
  # C6 — question; Tier 2 (clarify, ask, or explain)
  if _section C6 | grep -qiE 'tier[: ]+2|tier 2|clarif|explain|ask'; then
    score=$((score + 10))
  fi
  # C7 — scope creep; expect Tier 3 escalate / decline
  if _section C7 | grep -qiE 'tier[: ]+3|tier 3|scope|separate ticket|defer|decline'; then
    score=$((score + 14))
  fi
  # C8 — approval; expect no-action or acknowledge
  if _section C8 | grep -qiE 'no[- ]action|acknowledge|thanks|approval'; then
    score=$((score + 6))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

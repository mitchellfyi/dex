#!/usr/bin/env bash
set -euo pipefail

# Tests for the Stop-hook ownership guard and review-pass isolation in
# hooks/phase-loop.sh:
#   - a bystander Claude session (different hook session_id) resolving the same
#     dex session id must stay inert instead of being captured by the loop
#   - the owning session claims/reclaims the loop and still gets the audit gate
#   - a review-wave pass (DEX_REVIEW_PASS_ACTIVE=1) completing must exit via
#     the plain loop-complete path, never the inline phase handoff that
#     advances the lifecycle phase and instructs commit/push

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/phase-loop.sh"
export DEX_DIR="$ROOT"

# Hermeticity: this suite may itself run inside a Dex lifecycle or review-wave
# session whose environment already carries loop state. `env VAR=x` preserves
# the rest of the caller's environment, so strip everything the hook reads
# before the cases run; each case sets exactly the vars it needs.
unset DEX_LOOP_ACTIVE DEX_REVIEW_PASS_ACTIVE DEX_PHASE_HANDOFF DEX_LOOP_PHASE \
  DEX_LOOP_PROMISE DEX_LOOP_PROMPT DEX_LOOP_MIN_AUDITS DEX_LOOP_MAX_ITERATIONS \
  DEX_SESSION_ID DX_LIFECYCLE_PUSH_FORBIDDEN

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-phase-loop-test.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_STATE_DIR="$TMP_DIR/phases"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$DX_LOOP_DIR" "$DX_STATE_DIR"

pass=0
fail=0

# Assertions read the case-scoped globals OUT/RC directly. Hook output must
# never be re-parsed as shell (no eval): it contains JSON quotes and backtick
# fences that would be mangled or executed.
report() {
  if [[ "$2" -eq 0 ]]; then
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n' "$1" >&2
    fail=$((fail + 1))
  fi
}

assert_rc() { # <desc> <expected-rc>
  if [[ "$RC" -eq "$2" ]]; then report "$1" 0; else report "$1" 1; fi
}

assert_out_empty() { # <desc>
  if [[ -z "$OUT" ]]; then report "$1" 0; else report "$1" 1; fi
}

assert_out_contains() { # <desc> <fixed-string>
  if printf '%s' "$OUT" | grep -qF -- "$2"; then report "$1" 0; else report "$1" 1; fi
}

assert_out_lacks() { # <desc> <fixed-string>
  if printf '%s' "$OUT" | grep -qF -- "$2"; then report "$1" 1; else report "$1" 0; fi
}

assert_file_eq() { # <desc> <path> <expected-content>
  if [[ "$(cat "$2" 2>/dev/null)" == "$3" ]]; then report "$1" 0; else report "$1" 1; fi
}

# --- case 1: bystander session with a claimed loop stays inert ---
SID="repo-test-1-main"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "claude-owner" > "$DX_LOOP_DIR/$SID.owner"
set +e
OUT="$(printf '{"session_id":"claude-bystander"}' | env DEX_SESSION_ID="$SID" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "bystander exits 0" 0
assert_out_empty "bystander gets no injected output"
assert_file_eq "bystander did not steal the claim" "$DX_LOOP_DIR/$SID.owner" "claude-owner"
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 2: unclaimed file-activated loop is claimed by first stopper ---
SID="repo-test-2-main"
touch "$DX_LOOP_DIR/$SID.active"
set +e
OUT="$(printf '{"session_id":"claude-first"}' | env DEX_SESSION_ID="$SID" bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "unclaimed loop blocks stop for claimer" 2
assert_file_eq "claim recorded" "$DX_LOOP_DIR/$SID.owner" "claude-first"
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 3: env-activated session reclaims a stale claim ---
SID="repo-test-3-main"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "claude-stale" > "$DX_LOOP_DIR/$SID.owner"
set +e
OUT="$(printf '{"session_id":"claude-relaunch"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "env-activated session proceeds" 2
assert_file_eq "env-activated session reclaims" "$DX_LOOP_DIR/$SID.owner" "claude-relaunch"
rm -f "$DX_LOOP_DIR/$SID".*

# --- case 4: completed review pass never runs the inline phase handoff ---
SID="repo-test-4-main-pass-1-999"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "inline" > "$DX_LOOP_DIR/$SID.handoff-mode"
printf '%s\n' "3" > "$DX_STATE_DIR/$SID.phase"
printf '%s\n' "3:PHASE_3_COMPLETE:$ROOT/prompts/phase-audits/3-review.md:1" > "$DX_LOOP_DIR/$SID.config"
printf '%s\n' "CLEAN" > "$DX_LOOP_DIR/$SID.review-result"
printf '%s\n' "hash-abc123" > "$DX_LOOP_DIR/$SID.findings"
touch "$DX_LOOP_DIR/$SID.complete"
set +e
OUT="$(printf '{"session_id":"claude-wave"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "review pass allowed to stop" 0
assert_out_contains "review pass gets plain loop-complete stop" "Dex loop complete"
assert_out_lacks "review pass did not trigger phase handoff" "Phase Handoff"
assert_file_eq "phase state not advanced by review pass" "$DX_STATE_DIR/$SID.phase" "3"
# The launching wrapper harvests the pass findings hash into the parent
# session stuck-loop history after the wave exits, so the hook must leave it.
assert_file_eq "findings hash preserved for wrapper harvest" "$DX_LOOP_DIR/$SID.findings" "hash-abc123"
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- case 5: review pass with invalid result is held open ---
SID="repo-test-5-main-pass-2-999"
touch "$DX_LOOP_DIR/$SID.active"
printf '%s\n' "3:PHASE_3_COMPLETE:$ROOT/prompts/phase-audits/3-review.md:1" > "$DX_LOOP_DIR/$SID.config"
printf '%s\n' "not-a-result" > "$DX_LOOP_DIR/$SID.review-result"
touch "$DX_LOOP_DIR/$SID.complete"
set +e
OUT="$(printf '{"session_id":"claude-wave2"}' | env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_PASS_ACTIVE=1 bash "$HOOK" 2>&1)"
RC=$?
set -e
assert_rc "invalid result blocks review pass stop" 2
assert_out_contains "invalid result message shown" "result signal missing or invalid"
rm -f "$DX_LOOP_DIR/$SID".*

printf 'phase-loop-ownership-test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

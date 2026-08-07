#!/usr/bin/env bash
set -euo pipefail

# Tests for the push-blocking guards (hooks/guards/review-pass-no-push.md and
# hooks/guards/lifecycle-phase-push.md + the DX_LIFECYCLE_PUSH_FORBIDDEN
# resolver in hooks/guard-handler.py). Kept separate from guards-test.sh so
# this file contains no raw Codex payload strings.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDLER="$ROOT/hooks/guard-handler.py"
export DEX_DIR="$ROOT"

# Hermeticity: this suite may itself run inside a Dex lifecycle or review-wave
# session whose environment already carries loop state (DEX_REVIEW_PASS_ACTIVE,
# DEX_LOOP_ACTIVE, ...). `env VAR=x` preserves the rest of the caller's
# environment, so strip everything the handler reads before the cases run.
unset DEX_REVIEW_PASS_ACTIVE DEX_LOOP_ACTIVE DEX_LOOP_PHASE DEX_LOOP_PROMISE \
  DEX_LOOP_PROMPT DEX_LOOP_MIN_AUDITS DEX_PHASE_HANDOFF DEX_SESSION_ID \
  DEX_REVIEW_ASSESSMENT_ACTIVE DX_LIFECYCLE_PUSH_FORBIDDEN DX_STATE_DIR DX_LOOP_DIR

pass=0
fail=0

mkbashpayload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"
}

check_push_blocked() {
  if [[ "$GUARD_RC" -eq 2 ]] && printf '%s' "$GUARD_OUT" | grep -Eq 'block-review-pass-push|block-pre-phase4-push'; then
    pass=$((pass + 1))
  else
    printf 'FAIL (expected push block): %s (rc=%s)\n%s\n' "$1" "$GUARD_RC" "$GUARD_OUT" >&2
    fail=$((fail + 1))
  fi
}

check_push_clean() {
  if printf '%s' "$GUARD_OUT" | grep -Eq 'block-review-pass-push|block-pre-phase4-push'; then
    printf 'FAIL (push guard false positive): %s\n%s\n' "$1" "$GUARD_OUT" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

set +e
GUARD_OUT="$(mkbashpayload 'git push origin main' | env DEX_REVIEW_PASS_ACTIVE=1 DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_blocked "review pass git push"

set +e
GUARD_OUT="$(mkbashpayload 'git -C /tmp/x push --force-with-lease' | env DEX_REVIEW_PASS_ACTIVE=1 DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_blocked "review pass git -C push"

set +e
GUARD_OUT="$(mkbashpayload 'git --git-dir=/tmp/repo push origin main' | env DEX_REVIEW_PASS_ACTIVE=1 DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_blocked "review pass git --git-dir=<path> push"

set +e
GUARD_OUT="$(mkbashpayload 'gh pr create --draft' | env DEX_REVIEW_PASS_ACTIVE=1 DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_blocked "review pass gh pr create"

set +e
GUARD_OUT="$(mkbashpayload 'git status && git diff --stat' | env DEX_REVIEW_PASS_ACTIVE=1 DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_clean "review pass read-only git"

set +e
GUARD_OUT="$(mkbashpayload 'git push origin main' | env DEX_REVIEW_ASSESSMENT_ACTIVE=1 DX_LIFECYCLE_PUSH_FORBIDDEN=1 DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_blocked "review risk assessor git push"

set +e
GUARD_OUT="$(mkbashpayload 'git push' | env DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 DEX_SESSION_ID=guards-test-nonexistent DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_blocked "lifecycle phase 2 git push"

set +e
GUARD_OUT="$(mkbashpayload 'gh pr ready 123' | env DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_SESSION_ID=guards-test-nonexistent DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_blocked "lifecycle phase 3 gh pr ready"

set +e
GUARD_OUT="$(mkbashpayload 'git push -u origin HEAD' | env DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=0 DEX_SESSION_ID=guards-test-nonexistent DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_clean "lifecycle phase 0 bootstrap push"

set +e
GUARD_OUT="$(mkbashpayload 'git push -u origin HEAD' | env DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=4 DEX_SESSION_ID=guards-test-nonexistent DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_clean "lifecycle phase 4 push"

set +e
GUARD_OUT="$(mkbashpayload 'git push' | env DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_clean "no dex loop env"

set +e
GUARD_OUT="$(mkbashpayload 'git push' | env DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 DX_LIFECYCLE_PUSH_FORBIDDEN=0 DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_clean "explicit override escape hatch"

# Phase state file overrides stale env phase: the state file is authoritative
# after inline handoffs, so it must win over DEX_LOOP_PHASE in both directions.
PUSH_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-guards-push.XXXXXX")"
printf '4\n' > "$PUSH_STATE_DIR/guards-test-statefile.phase"
set +e
GUARD_OUT="$(mkbashpayload 'git push' | env DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 DEX_SESSION_ID=guards-test-statefile DX_STATE_DIR="$PUSH_STATE_DIR" DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_clean "state file phase 4 beats stale env phase 2"

printf '3\n' > "$PUSH_STATE_DIR/guards-test-statefile.phase"
set +e
GUARD_OUT="$(mkbashpayload 'git push' | env DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=4 DEX_SESSION_ID=guards-test-statefile DX_STATE_DIR="$PUSH_STATE_DIR" DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)"; GUARD_RC=$?
set -e
check_push_blocked "state file phase 3 beats stale env phase 4"
rm -rf "$PUSH_STATE_DIR"

printf 'push-guards-test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

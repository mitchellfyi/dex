#!/usr/bin/env bash
set -euo pipefail

# Lifecycle phases describe workflow focus, but they must never turn ordinary
# commit, push, or PR commands into blocked tool calls.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
HANDLER="$ROOT/hooks/guard-handler.py"
export DEX_DIR="$ROOT"

# Hermeticity: keep the handler's provider fallback away from the developer's
# real ~/.dex/providers.json.
GUARD_HOME_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dex-push-guards-home.XXXXXX")"
export HOME="$GUARD_HOME_TMP/home"
mkdir -p "$HOME"
trap 'rm -rf "$GUARD_HOME_TMP"' EXIT

unset DEX_REVIEW_PASS_ACTIVE DEX_LOOP_ACTIVE DEX_LOOP_PHASE DEX_LOOP_PROMISE \
  DEX_LOOP_PROMPT DEX_LOOP_MIN_AUDITS DEX_PHASE_HANDOFF DEX_SESSION_ID \
  DEX_REVIEW_ASSESSMENT_ACTIVE DX_LIFECYCLE_PUSH_FORBIDDEN DX_STATE_DIR DX_LOOP_DIR

pass=0
fail=0

mkbashpayload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"
}

check_allowed() {
  local label="$1" command="$2"
  shift 2
  local output status
  set +e
  output=$(mkbashpayload "$command" | env "$@" DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)
  status=$?
  set -e
  if [[ "$status" -eq 0 ]] \
    && ! printf '%s' "$output" | grep -Eq 'block-review-pass-push|block-pre-phase4-push'; then
    pass=$((pass + 1))
  else
    printf 'FAIL (expected lifecycle write command to be allowed): %s (rc=%s)\n%s\n' \
      "$label" "$status" "$output" >&2
    fail=$((fail + 1))
  fi
}

check_allowed "review pass git commit" "git commit -m review-fix" DEX_REVIEW_PASS_ACTIVE=1
check_allowed "review pass git push" "git push origin main" DEX_REVIEW_PASS_ACTIVE=1
check_allowed "review pass PR create" "gh pr create --draft" DEX_REVIEW_PASS_ACTIVE=1
check_allowed "Phase 1 commit" "git commit -m planning-note" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=1
check_allowed "Phase 2 push" "git push -u origin HEAD" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2
check_allowed "Phase 3 PR ready" "gh pr ready 123" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3
check_allowed "explicit legacy block env has no effect" "git push" DX_LIFECYCLE_PUSH_FORBIDDEN=1
check_allowed "no lifecycle state" "gh pr create --fill"

set +e
DESTRUCTIVE_OUT=$(mkbashpayload 'rm -rf /' | env DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 \
  DEX_REVIEW_PASS_ACTIVE=1 DEX_GUARD_EVENT=bash python3 "$HANDLER" 2>&1)
set -e
# The point of this check is that removing the phase push guards did not take
# the destructive-command guard with them. That guard advises rather than
# denies, so what it must still do is fire.
if printf '%s' "$DESTRUCTIVE_OUT" | grep -q 'warn-destructive-commands'; then
  pass=$((pass + 1))
else
  printf 'FAIL: removing phase push guards weakened destructive-command protection\n%s\n' \
    "$DESTRUCTIVE_OUT" >&2
  fail=$((fail + 1))
fi

printf 'push-guards-test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || assert_at $LINENO

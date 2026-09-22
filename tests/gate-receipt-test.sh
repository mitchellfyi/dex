#!/usr/bin/env bash
set -euo pipefail

# Phase 4's reuse decision: does a passing receipt for the gate it needs already
# exist for the tree in front of us?
#
# The receipt is keyed by the checkout and working-tree fingerprints, so the
# only safe answers are "reuse this", "run it", and "it failed here". A wrong
# answer in either direction is expensive: re-running a green suite costs the
# whole gate again, and reusing a receipt from another tree — or another gate,
# or another session's environment — claims a pass that nothing verified.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-gate-receipt.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"
# shellcheck disable=SC1091
source "$ROOT/tests/helpers.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/src"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email dex@example.test
git -C "$REPO" config user.name Dex
printf 'code\n' > "$REPO/src/app.js"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "initial"
cd "$REPO"

SESSION="worktree-ticket-7777"
OTHER_SESSION="worktree-ticket-8888"
GATE="full-gate"
OUT="$TMP_DIR/out"
# The session the receipts are read for, the way a lifecycle session has it.
export DEX_SESSION_ID="$SESSION"

probe() {
  local probe_status=0
  bash "$ROOT/bin/gate-receipt.sh" "$@" > "$OUT" 2>&1 || probe_status=$?
  printf '%s\n' "$probe_status"
}

# No receipt at all: run the gate.
assert_eq "1" "$(probe "$GATE")" "no receipt for this tree"
assert_contains "run the gate" "$OUT"

write_receipt() { # <exit-code> [gate-name] [session-id]
  local exit_code="$1" gate_name="${2:-$GATE}" session_id="${3:-$SESSION}"
  local checkout working
  checkout=$(git -C "$REPO" rev-parse --verify HEAD)
  working=$(dx_review_working_fingerprint "$REPO")
  dx_gate_receipt_write "$session_id" "$gate_name" "$checkout" "$working" 1 \
    "$exit_code" 412 37 nice 2 "" "$TMP_DIR/gate.log" bin/verify >/dev/null
}

# A passing receipt for this exact tree is the evidence Phase 4 reuses.
write_receipt 0
assert_eq "0" "$(probe "$GATE")" "a passing receipt for this tree is reused"
assert_contains "passed on this exact tree" "$OUT"
assert_contains "$GATE" "$OUT"
assert_eq "1" "$(probe other-gate)" "another gate name has no receipt"

# A receipt is asked for by name. A pass recorded for one gate says nothing
# about another, so the bare form lists what exists and still answers "run".
assert_eq "1" "$(probe)" "no gate name never answers reuse"
assert_contains "$GATE" "$OUT"
assert_contains "Name the gate" "$OUT"

# Several names: every one of them needs a passing receipt.
write_receipt 0 lint
assert_eq "0" "$(probe "$GATE" lint)" "every named gate passed"
assert_eq "1" "$(probe "$GATE" typecheck)" "one named gate without a receipt means run"
assert_contains "typecheck" "$OUT"
write_receipt 1 typecheck
assert_eq "3" "$(probe "$GATE" typecheck)" "one failed named gate outranks the passes"

# Receipts are this session's by default. Another worktree on the same commit
# has the same tree but not the same environment, so reading its receipts is
# an explicit opt-in.
write_receipt 0 shared "$OTHER_SESSION"
assert_eq "1" "$(probe shared)" "another session's receipt is not reused by default"
assert_eq "0" "$(probe --all-sessions shared)" "--all-sessions reads every session's receipts"
assert_eq "0" "$(probe --session "$OTHER_SESSION" shared)" "--session names the session to read"
assert_eq "1" "$(DEX_SESSION_ID="$OTHER_SESSION" probe "$GATE")" \
  "DEX_SESSION_ID is the default scope"

# The working tree changed, so the recorded result is about a different tree.
printf 'more\n' >> "$REPO/src/app.js"
assert_eq "1" "$(probe "$GATE")" "a changed working tree invalidates the receipt"
assert_contains "run the gate" "$OUT"

# Committing changes the checkout fingerprint too.
git -C "$REPO" commit -qam "second"
assert_eq "1" "$(probe "$GATE")" "a new commit invalidates the receipt"

# A recorded failure for this tree is a gate to fix, not a gate to re-run.
write_receipt 1
assert_eq "3" "$(probe "$GATE")" "a failing receipt for this tree is reported as failed"
assert_contains "failed on this exact tree" "$OUT"

# An unstable receipt — the tree moved while the gate ran — never matches.
CHECKOUT=$(git -C "$REPO" rev-parse --verify HEAD)
WORKING=$(dx_review_working_fingerprint "$REPO")
dx_gate_receipt_write "$SESSION" "unstable" "$CHECKOUT" "$WORKING" 0 0 12 0 \
  nice 2 "" "$TMP_DIR/gate.log" bin/verify >/dev/null
assert_eq "1" "$(probe unstable)" "an unstable receipt is not reuse evidence"

# Arguments it will not act on.
assert_eq "2" "$(probe --session "not a session id" "$GATE")" "an invalid session is refused"
assert_eq "2" "$(probe "not a gate")" "an invalid gate name is refused"
assert_eq "2" "$(probe --bogus "$GATE")" "an unknown option is refused"

printf 'gate receipt reuse tests passed\n'

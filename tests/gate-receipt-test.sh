#!/usr/bin/env bash
set -euo pipefail

# Phase 4's reuse decision: does a passing receipt for the gate it needs already
# exist for the tree in front of us?
#
# The receipt is keyed by the checkout and working-tree fingerprints and bound
# to an environment fingerprint, so the only safe answers are "reuse this",
# "run it", and "it failed here". A wrong answer in either direction is
# expensive: re-running a green suite costs the whole gate again, and reusing a
# receipt from another tree — or another gate, or another environment — claims
# a pass that nothing verified. A reuse is journaled as `gate.reused` so the
# run shows where a gate was skipped on evidence rather than never run.

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
# A fixed parallelism budget, so the environment fingerprint is the same for
# the writer and the reader until a case changes it on purpose.
export DX_TEST_JOBS=2
# The run journal a reuse is reported to.
RUN_ID=$(dx_run_prepare "$SESSION" "$REPO" "test" "gate-receipt" "issue-1" "dx test")
[[ -n "$RUN_ID" ]] || assert_at $LINENO
EVENTS=$(dx_run_events_file "$RUN_ID")

probe() {
  local probe_status=0
  bash "$ROOT/bin/gate-receipt.sh" "$@" > "$OUT" 2>&1 || probe_status=$?
  printf '%s\n' "$probe_status"
}

reused_events() { # count of gate.reused events journaled so far
  [[ -f "$EVENTS" ]] || { printf '0\n'; return 0; }
  grep -c '"type":"gate.reused"' "$EVENTS" || true
}

# No receipt at all: run the gate.
assert_eq "1" "$(probe "$GATE")" "no receipt for this tree"
assert_contains "run the gate" "$OUT"
assert_eq "0" "$(reused_events)" "nothing was reused, nothing is journaled"

# The environment the gate would run in, hashed the way run-gate hashes it.
ENV_FP=$(dx_gate_env_fingerprint "$REPO")
[[ "$ENV_FP" =~ ^[a-f0-9]{64}$ ]] || assert_at $LINENO

write_receipt() { # <exit-code> [gate-name] [session-id]
  local exit_code="$1" gate_name="${2:-$GATE}" session_id="${3:-$SESSION}"
  local checkout working
  checkout=$(git -C "$REPO" rev-parse --verify HEAD)
  working=$(dx_review_working_fingerprint "$REPO")
  dx_gate_receipt_write --env-fingerprint "$ENV_FP" \
    "$session_id" "$gate_name" "$checkout" "$working" 1 \
    "$exit_code" 412 37 nice 2 "" "$TMP_DIR/gate.log" bin/verify >/dev/null
}

# A passing receipt for this exact tree is the evidence Phase 4 reuses.
write_receipt 0
RECEIPT_FILE="$(dx_gate_receipt_dir "$SESSION")/$GATE.json"
assert_file "$RECEIPT_FILE"
python3 - "$RECEIPT_FILE" "$ENV_FP" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    receipt = json.load(handle)
assert receipt["schema_version"] == 2, receipt
assert receipt["env_fingerprint"] == sys.argv[2], receipt
PY
assert_eq "0" "$(probe "$GATE")" "a passing receipt for this tree is reused"
assert_contains "passed on this exact tree" "$OUT"
assert_contains "$GATE" "$OUT"
assert_eq "1" "$(reused_events)" "one reuse, one gate.reused event"
python3 - "$EVENTS" "$GATE" "$SESSION" "$ENV_FP" \
  "$(git -C "$REPO" rev-parse --verify HEAD)" \
  "$(dx_review_working_fingerprint "$REPO")" <<'PY'
import json
import sys

events_path, gate, session, env_fp, checkout, working = sys.argv[1:7]
reused = []
with open(events_path, encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get("type") == "gate.reused":
            reused.append(event)
assert len(reused) == 1, reused
data = reused[0]["data"]
required = {
    "gate", "checkout_fingerprint", "working_fingerprint", "env_fingerprint",
    "receipt_recorded_at", "receipt_session",
}
missing = required - set(data)
assert not missing, f"gate.reused is missing {sorted(missing)}"
assert data["gate"] == gate, data
assert data["checkout_fingerprint"] == checkout, data
assert data["working_fingerprint"] == working, data
assert data["env_fingerprint"] == env_fp, data
assert data["receipt_session"] == session, data
assert data["receipt_recorded_at"].endswith("Z"), data
print("gate.reused names the gate, the tree, the environment and the receipt")
PY
assert_eq "1" "$(probe other-gate)" "another gate name has no receipt"
assert_eq "1" "$(reused_events)" "a miss journals nothing"

# Same tree, different environment: the receipt is about another toolchain
# budget, so it is not evidence here. The reader says why.
assert_eq "1" "$(DX_TEST_JOBS=7 probe "$GATE")" \
  "a different environment on the same tree means run"
assert_contains "different environment" "$OUT"
assert_contains "run the gate" "$OUT"
assert_eq "1" "$(reused_events)" "an environment miss journals nothing"
assert_eq "0" "$(probe "$GATE")" "the original environment still reuses"

# A receipt written before the environment binding existed has no
# env_fingerprint. It still answers a tree-only lookup, so the Phase 4 floor
# keeps working, and it never answers a lookup that asked for an environment.
LEGACY_FILE="$(dx_gate_receipt_dir "$SESSION")/legacy.json"
python3 - "$RECEIPT_FILE" "$LEGACY_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    receipt = json.load(handle)
receipt.pop("schema_version")
receipt.pop("env_fingerprint")
receipt["gate"] = "legacy"
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
LEGACY_CHECKOUT=$(git -C "$REPO" rev-parse --verify HEAD)
LEGACY_WORKING=$(dx_review_working_fingerprint "$REPO")
dx_gate_receipt_lookup "$SESSION" "$LEGACY_CHECKOUT" "$LEGACY_WORKING" legacy \
  > "$TMP_DIR/legacy.rows" || assert_at $LINENO
assert_contains "legacy" "$TMP_DIR/legacy.rows"
LOOKUP_RC=0
dx_gate_receipt_lookup "$SESSION" "$LEGACY_CHECKOUT" "$LEGACY_WORKING" legacy \
  "$ENV_FP" >/dev/null 2>&1 || LOOKUP_RC=$?
assert_eq "1" "$LOOKUP_RC" "a v1 receipt never matches an environment-bound lookup"
assert_eq "1" "$(probe legacy)" "a v1 receipt is not reuse evidence"
assert_contains "different environment" "$OUT"

# The lookup's own contract for the new argument.
dx_gate_receipt_lookup "$SESSION" "$LEGACY_CHECKOUT" "$LEGACY_WORKING" "$GATE" \
  "$ENV_FP" > "$TMP_DIR/bound.rows" || assert_at $LINENO
assert_contains "$GATE" "$TMP_DIR/bound.rows"
LOOKUP_RC=0
dx_gate_receipt_lookup "$SESSION" "$LEGACY_CHECKOUT" "$LEGACY_WORKING" "$GATE" \
  "$(printf 'f%.0s' $(seq 1 64))" >/dev/null 2>&1 || LOOKUP_RC=$?
assert_eq "1" "$LOOKUP_RC" "another environment's fingerprint matches nothing"
LOOKUP_RC=0
dx_gate_receipt_lookup "$SESSION" "$LEGACY_CHECKOUT" "$LEGACY_WORKING" "" \
  "not-a-fingerprint" >/dev/null 2>&1 || LOOKUP_RC=$?
assert_eq "2" "$LOOKUP_RC" "a malformed environment fingerprint is refused"
LOOKUP_RC=0
dx_gate_receipt_write --env-fingerprint "short" "$SESSION" bad "$LEGACY_CHECKOUT" \
  "$LEGACY_WORKING" 1 0 1 0 nice 2 "" "$TMP_DIR/gate.log" bin/verify \
  >/dev/null 2>&1 || LOOKUP_RC=$?
assert_eq "2" "$LOOKUP_RC" "the writer refuses a malformed environment fingerprint"

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
# The reuse is journaled to the session doing the reusing, naming the session
# whose receipt it was.
grep -F '"type":"gate.reused"' "$EVENTS" | grep -F '"gate":"shared"' \
  | grep -Fq "\"receipt_session\":\"$OTHER_SESSION\"" || assert_at $LINENO
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

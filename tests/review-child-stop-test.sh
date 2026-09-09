#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dex-review-child-stop.XXXXXX")
CHILD_PID=""
cleanup() {
  if [[ -n "$CHILD_PID" ]]; then
    kill "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
unset DEX_SESSION_ID DEX_LOOP_ACTIVE DEX_PHASE_HANDOFF DEX_LOOP_PHASE \
  DEX_LOOP_PROMISE DEX_LOOP_PROMPT DEX_REVIEW_PASS_ACTIVE DEX_POLICY_SESSION_ID \
  DEX_REVIEW_CRITERIA_FILE DEX_REVIEW_CRITERIA_BINDING DEX_RUN_ID
export DEX_DIR="$ROOT" DX_LOOP_DIR="$TMP_DIR/loops" DX_STATE_DIR="$TMP_DIR/state" \
  DX_RUN_ROOT="$TMP_DIR/runs" DX_ARTIFACT_DIR="$TMP_DIR/artifacts" DX_TOOL_DIR="$TMP_DIR/tools"
mkdir -p "$DX_LOOP_DIR" "$DX_STATE_DIR"
source "$ROOT/lib/common.sh"
source "$ROOT/tests/review-proof-fixture.sh"

REPO="$TMP_DIR/repo"
git init -q "$REPO"
git -C "$REPO" config user.name "Dex Test"
git -C "$REPO" config user.email dex@example.test
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" config commit.gpgSign false
printf 'fixture\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm 'test: initialize fixture'
cd "$REPO"
SCOPE=$(dx_review_scope_fingerprint "$REPO")
POLICY=$(dx_review_policy_resolve "$REPO" | cut -f4)

prepare_pass() {
  SID="$1"
  GENERATION=$(dx_completion_loop_activate "$SID" child review-pass 3)
  PASS_BINDING=$(dx_review_pass_binding "$SID" "$SCOPE" standalone "$POLICY")
  printf 'CLEAN\n' > "$(dx_review_result_file "$SID")"
  dx_test_write_clean_review_proof "$SID" "$SID" light "$SCOPE" standalone "$POLICY" \
    "$(dx_review_evidence_file "$SID")" "$(dx_review_context_file "$SID")"
  dx_review_empty_findings_hash > "$(dx_findings_file "$SID")"
  dx_completion_write_receipt "$SID" "$GENERATION"
}

run_stop() {
  env DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 \
    DEX_REVIEW_PASS_ACTIVE=1 DEX_REVIEW_PROFILE=light \
    DEX_REVIEW_SCOPE_FINGERPRINT="$SCOPE" DEX_REVIEW_POLICY_BINDING="$POLICY" \
    DEX_REVIEW_PASS_ID="$SID" DEX_REVIEW_PASS_BINDING="$PASS_BINDING" \
    bash "$ROOT/hooks/phase-loop.sh" <<< '{"session_id":"test-review-child"}'
}

assert_inactive() {
  assert_no_file "$(dx_active_file "$SID")"
  assert_no_file "$(dx_paused_file "$SID")"
  assert_no_file "$(dx_pause_state_file "$SID")"
}

# Completion remains available to the parent through any number of late Stops.
prepare_pass repeated-stop
run_stop > "$TMP_DIR/first.out" 2>&1
assert_contains 'Dex loop complete' "$TMP_DIR/first.out"
assert_inactive
for attempt in 1 2 3; do
  run_stop > "$TMP_DIR/repeated-$attempt.out" 2>&1
  assert_inactive
  dx_completion_receipt_valid "$SID" child review-pass 3 "$GENERATION" || assert_at "$LINENO"
  assert_eq "$GENERATION" "$(dx_completion_current_generation "$SID" child review-pass 3)" 'same generation after repeated Stop'
  assert_file "$(dx_loop_config_file "$SID")"
done
dx_completion_consume "$SID" child review-pass 3 "$GENERATION"
run_stop > "$TMP_DIR/consumed.out" 2>&1
assert_inactive
assert_no_file "$(dx_completion_expectation_file "$SID")"
dx_cleanup_session "$SID"
run_stop > "$TMP_DIR/cleaned.out" 2>&1
assert_inactive
assert_no_file "$(dx_completion_expectation_file "$SID")"
assert_no_file "$(dx_loop_config_file "$SID")"

# A Stop that saw activation before waiting for the lock must recheck it after
# the parent has retired the child. The shim observes the real lock attempt.
prepare_pass stop-waiting-on-lock
dx_lifecycle_control_lock_acquire "$SID"
cat > "$TMP_DIR/bash-env" <<'SH'
mkdir() {
  if [[ "${1:-}" == "$TEST_STOP_LOCK" ]]; then
    : > "$TEST_STOP_READY"
    while [[ ! -e "$TEST_STOP_RELEASE" ]]; do sleep 0.01; done
  fi
  command mkdir "$@"
}
SH
BASH_ENV="$TMP_DIR/bash-env" TEST_STOP_LOCK="$(dx_lifecycle_control_lock_dir "$SID")" \
  TEST_STOP_READY="$TMP_DIR/lock-attempt" TEST_STOP_RELEASE="$TMP_DIR/release" \
  run_stop > "$TMP_DIR/waiting.out" 2>&1 &
CHILD_PID=$!
for attempt in {1..500}; do
  [[ ! -f "$TMP_DIR/lock-attempt" ]] || break
  sleep 0.01
done
assert_file "$TMP_DIR/lock-attempt"
rm -f "$(dx_active_file "$SID")" "$(dx_loop_config_file "$SID")"
dx_completion_consume "$SID" child review-pass 3 "$GENERATION"
dx_lifecycle_control_lock_release "$SID"
touch "$TMP_DIR/release"
if ! wait "$CHILD_PID"; then
  cat "$TMP_DIR/waiting.out" >&2
  assert_at "$LINENO"
fi
CHILD_PID=""
assert_inactive
assert_no_file "$(dx_completion_expectation_file "$SID")"
assert_no_file "$(dx_loop_config_file "$SID")"

# Invalid state in a still-active child remains a failed completion.
prepare_pass active-invalid-context
printf 'invalid\n' > "$(dx_loop_config_file "$SID")"
STOP_RC=0
run_stop > "$TMP_DIR/invalid.out" 2>&1 || STOP_RC=$?
assert_eq 2 "$STOP_RC" 'active invalid context blocks'
assert_eq invalid-completion-context "$(dx_pause_state_read "$SID" reason)" 'invalid context pause'
assert_rejected 'invalid active context cannot earn credit' \
  dx_completion_receipt_valid "$SID" child review-pass 3 "$GENERATION"

printf 'review-child-stop tests passed\n'

#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-management.XXXXXX")"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

# shellcheck source=lib/common.sh
DX_COMMON_MODULES="lock git session completion session-runtime session-catalog events review review-policy lifecycle-control" \
  source "$ROOT/lib/common.sh"
# shellcheck source=lib/session-management.sh
source "$ROOT/lib/session-management.sh"

# Cleanup can fail before any runtime claim is written. Keep that path safe
# under zsh's default NOMATCH behavior as well as bash.
EMPTY_CLAIM_DIR="$TMP_DIR/empty-claims"
EMPTY_ZDOT_DIR="$TMP_DIR/empty-zdot"
mkdir -p "$EMPTY_CLAIM_DIR" "$EMPTY_ZDOT_DIR"
DX_TEST_SESSION_MANAGEMENT="$ROOT/lib/session-management.sh" \
  DX_TEST_EMPTY_CLAIM_DIR="$EMPTY_CLAIM_DIR" \
  ZDOTDIR="$EMPTY_ZDOT_DIR" \
  zsh -f -c '
    set -eu
    setopt nomatch
    source "$DX_TEST_SESSION_MANAGEMENT"
    __dx_session_management_settle_claims_failed \
      "$DX_TEST_EMPTY_CLAIM_DIR"
  '

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email dex@example.test
git -C "$REPO" config user.name "Dex Test"
printf 'base\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m "test: initialize repo"
git -C "$REPO" branch -m main

SID="$(cd "$REPO" && dx_scoped_session_id branch-cleanup-happy)"
dx_meta_write "$SID" \
  "ticket_number=cleanup-happy" \
  "wt_name=cleanup-happy" \
  "wt_dir=$REPO" \
  "workspace_mode=in-place"
printf '3\n' > "$(dx_state_file "$SID")"
printf 'run_cleanup_happy\n' > "$(dx_run_id_file "$SID")"
mkdir -p "$DX_RUN_ROOT/run_cleanup_happy"
printf 'keep\n' > "$DX_RUN_ROOT/run_cleanup_happy/summary.json"
TOKEN="$(dx_session_runtime_start "$SID" codex "$REPO" "$$")"
dx_session_runtime_finish "$SID" "$TOKEN" paused "$$"

__dx_session_management_cleanup_exact "$REPO" "$SID"
assert_no_file "$(dx_state_file "$SID")"
assert_no_file "$(dx_run_id_file "$SID")"
assert_no_file "$(dx_session_runtime_file "$SID")"
assert_file "$(dx_session_runtime_file "$SID")-lock"
assert_file "$DX_RUN_ROOT/run_cleanup_happy/summary.json"
assert_eq "main" "$(git -C "$REPO" branch --show-current)" "preserved branch"

make_terminal_session() { # <sid> <workspace> [phase]
  local fixture_sid="$1" fixture_workspace="$2" fixture_phase="${3:-3}"
  local fixture_token
  dx_meta_write "$fixture_sid" \
    "ticket_number=${fixture_sid##*-}" \
    "wt_name=${fixture_sid##*-}" \
    "wt_dir=$fixture_workspace" \
    "workspace_mode=in-place"
  printf '%s\n' "$fixture_phase" > "$(dx_state_file "$fixture_sid")"
  fixture_token="$(dx_session_runtime_start \
    "$fixture_sid" codex "$fixture_workspace" "$$")"
  dx_session_runtime_finish "$fixture_sid" "$fixture_token" paused "$$"
}

make_review_child() { # <parent> <kind> <hex-suffix> [with-runtime]
  local parent_sid="$1" child_kind="$2" child_suffix="$3"
  local with_runtime="${4:-0}" child_sid
  child_sid="${parent_sid:0:120}-${child_kind}-${child_suffix}"
  dx_meta_write "$child_sid" \
    "session_role=review-child" \
    "parent_session_id=$parent_sid" \
    "child_kind=$child_kind"
  printf '3\n' > "$(dx_state_file "$child_sid")"
  printf 'child state\n' > "$(dx_review_state_file "$child_sid")"
  if [[ "$with_runtime" -eq 1 ]]; then
    CHILD_RUNTIME_TOKEN="$(dx_session_runtime_start \
      "$child_sid" codex "$REPO" "$$")"
    dx_session_runtime_finish \
      "$child_sid" "$CHILD_RUNTIME_TOKEN" paused "$$"
  else
    CHILD_RUNTIME_TOKEN=""
  fi
  REVIEW_CHILD_SID="$child_sid"
}

# Review children are removed before their parent. Pass/assessment children
# can be provenance-only; a child runtime, when present, gets its own recovery
# claim and leaves only the persistent runtime lock.
CHILD_PARENT="$(cd "$REPO" && dx_scoped_session_id branch-cleanup-children)"
make_terminal_session "$CHILD_PARENT" "$REPO"
PARENT_BUSY_TOKEN="$(dx_phase_busy_begin "$CHILD_PARENT" 3 "review child")"
dx_phase_busy_acknowledge "$CHILD_PARENT" 3 "$PARENT_BUSY_TOKEN"
make_review_child "$CHILD_PARENT" assessment \
  11111111111111111111111111111111 0
PROVENANCE_CHILD="$REVIEW_CHILD_SID"
make_review_child "$CHILD_PARENT" pass \
  22222222222222222222222222222222 1
RUNTIME_CHILD="$REVIEW_CHILD_SID"

__dx_session_management_cleanup_exact "$REPO" "$CHILD_PARENT"
assert_no_file "$(dx_meta_file "$PROVENANCE_CHILD")"
assert_no_file "$(dx_state_file "$PROVENANCE_CHILD")"
assert_no_file "$(dx_meta_file "$RUNTIME_CHILD")"
assert_no_file "$(dx_session_runtime_file "$RUNTIME_CHILD")"
assert_file "$(dx_session_runtime_file "$RUNTIME_CHILD")-lock"
assert_no_file "$(dx_meta_file "$CHILD_PARENT")"
assert_no_file "$(dx_session_runtime_file "$CHILD_PARENT")"

assert_brakes() { # <sid>
  local brake_sid="$1"
  assert_file "$(dx_review_receipt_revocation_file "$brake_sid")"
  assert_file "$(dx_review_selection_revocation_file "$brake_sid")"
  dx_review_receipt_authorization_absent "$brake_sid" \
    || fail "review receipt authorization survived cleanup failure"
  dx_review_selection_authorization_revoked "$brake_sid" \
    || fail "review selection authorization survived cleanup failure"
}

write_review_authorization() { # <sid>
  local authorization_sid="$1"
  printf 'receipt\n' > "$(dx_review_receipt_file "$authorization_sid")"
  printf 'selection\n' > "$(dx_review_selection_file "$authorization_sid")"
}

populate_all_state_families() { # <sid>
  local family_sid="$1" completion_generation state_target loop_target
  printf 'times\n' > "$(dx_times_file "$family_sid")"
  printf 'context\n' > "$(dx_context_file "$family_sid")"
  printf 'log\n' > "$(dx_log_file "$family_sid")"
  printf 'outcome\n' > "$(dx_phase_outcomes_file "$family_sid")"
  printf 'main\n' > "$(dx_branch_file "$family_sid")"
  printf 'intervention\n' > "$DX_STATE_DIR/${family_sid}.interventions"
  printf 'human-complete\n' > "$DX_STATE_DIR/${family_sid}.human-complete"
  printf 'terminal\n' > "$DX_STATE_DIR/${family_sid}.terminal-commit"
  printf 'run_exhaustive\n' > "$(dx_run_id_file "$family_sid")"

  for state_target in \
    "$(dx_loop_file "$family_sid")" \
    "$(dx_complete_file "$family_sid")" \
    "$(dx_active_file "$family_sid")" \
    "$(dx_owner_file "$family_sid")" \
    "$(dx_prompt_file "$family_sid")" \
    "$(dx_findings_file "$family_sid")" \
    "$(dx_debt_file "$family_sid")" \
    "$(dx_loop_config_file "$family_sid")" \
    "$(dx_handoff_mode_file "$family_sid")" \
    "$(dx_paused_file "$family_sid")" \
    "$(dx_pause_state_file "$family_sid")" \
    "$(dx_watch_pause_file "$family_sid")" \
    "$(dx_lifecycle_control_file "$family_sid")" \
    "$(dx_watch_lock_file "$family_sid" ci)" \
    "$(dx_watch_lock_file "$family_sid" pr)" \
    "$(dx_review_state_file "$family_sid")" \
    "$(dx_review_result_file "$family_sid")" \
    "$(dx_review_context_file "$family_sid")" \
    "$(dx_review_criteria_file "$family_sid")" \
    "$(dx_review_criteria_approval_file "$family_sid")" \
    "$(dx_review_evidence_file "$family_sid")" \
    "$(dx_complete_state_file "$family_sid")" \
    "$(dx_provider_state_file "$family_sid")"; do
    printf 'state\n' > "$state_target"
  done
  write_review_authorization "$family_sid"
  printf 'ledger\n' > "$(dx_review_ledger_file "$family_sid")"
  mkdir -p "$(dx_review_proof_dir "$family_sid")/1"
  printf 'proof\n' > "$(dx_review_proof_dir "$family_sid")/1/evidence.json"
  for loop_target in \
    "$(dx_phase_started_file "$family_sid" 0)" \
    "$(dx_phase_ready_file "$family_sid" 0)" \
    "$(dx_phase_busy_notice_file "$family_sid" 3)" \
    "$(dx_phase_busy_cancel_file "$family_sid" 3)" \
    "$(dx_phase_busy_quiesced_file "$family_sid" 3)" \
    "$DX_LOOP_DIR/${family_sid}.phase-prompt-loop.started" \
    "$DX_LOOP_DIR/${family_sid}.phase-prompt-loop.ready"; do
    printf 'marker\n' > "$loop_target"
  done
  completion_generation="$(dx_completion_issue \
    "$family_sid" lifecycle phase 3)"
  dx_completion_write_receipt "$family_sid" "$completion_generation"
  printf 'legacy\n' > "$(dx_complete_file "$family_sid")"
}

# Every recognized state family is removed by exact SID. The similarly named
# neighbor and the run journal are outside the transaction and stay intact.
EXHAUSTIVE_SID="$(cd "$REPO" && dx_scoped_session_id branch-cleanup-exhaustive)"
make_terminal_session "$EXHAUSTIVE_SID" "$REPO"
populate_all_state_families "$EXHAUSTIVE_SID"
mkdir -p "$DX_RUN_ROOT/run_exhaustive"
printf 'journal\n' > "$DX_RUN_ROOT/run_exhaustive/events.jsonl"
NEIGHBOR_SID="${EXHAUSTIVE_SID}-neighbor"
printf '4\n' > "$(dx_state_file "$NEIGHBOR_SID")"
__dx_session_management_cleanup_exact "$REPO" "$EXHAUSTIVE_SID"
__dx_session_management_artifacts assert-final "$EXHAUSTIVE_SID"
find "$DX_STATE_DIR" "$DX_LOOP_DIR" -maxdepth 1 \
  -name "${EXHAUSTIVE_SID}.*" -print | LC_ALL=C sort \
  > "$TMP_DIR/exhaustive-residue.actual"
printf '%s\n' \
  "$(dx_session_runtime_file "$EXHAUSTIVE_SID")-lock" \
  "$(dx_completion_lock_file "$EXHAUSTIVE_SID")" | LC_ALL=C sort \
  > "$TMP_DIR/exhaustive-residue.expected"
cmp -s "$TMP_DIR/exhaustive-residue.expected" \
  "$TMP_DIR/exhaustive-residue.actual" \
  || fail "exhaustive cleanup left an unexpected state family"
assert_file "$(dx_state_file "$NEIGHBOR_SID")"
assert_file "$DX_RUN_ROOT/run_exhaustive/events.jsonl"

# A Phase 3 fence must carry the matching quiescence acknowledgement. Cleanup
# failure leaves both review brakes and settles the recovery owner as failed.
BUSY_SID="$(cd "$REPO" && dx_scoped_session_id branch-cleanup-busy)"
make_terminal_session "$BUSY_SID" "$REPO"
BUSY_TOKEN="$(dx_phase_busy_begin "$BUSY_SID" 3 "review child")"
write_review_authorization "$BUSY_SID"
assert_rejected "unquiesced Phase 3 cleanup" \
  __dx_session_management_cleanup_exact "$REPO" "$BUSY_SID"
assert_eq "failed" "$(dx_session_runtime_field "$BUSY_SID" status)" \
  "unquiesced cleanup runtime"
assert_eq "$BUSY_TOKEN" "$(dx_phase_busy_token "$BUSY_SID" 3)" \
  "preserved busy token"
assert_brakes "$BUSY_SID"

# Live, unverifiable, corrupt, and unsafe state all fail before deletion.
LIVE_SID="$(cd "$REPO" && dx_scoped_session_id branch-cleanup-live)"
dx_meta_write "$LIVE_SID" \
  "ticket_number=live" "wt_name=live" "wt_dir=$REPO" \
  "workspace_mode=in-place"
printf '3\n' > "$(dx_state_file "$LIVE_SID")"
LIVE_TOKEN="$(dx_session_runtime_start "$LIVE_SID" codex "$REPO" "$$")"
assert_rejected "live runtime cleanup" \
  __dx_session_management_cleanup_exact "$REPO" "$LIVE_SID"
assert_file "$(dx_meta_file "$LIVE_SID")"
dx_session_runtime_finish "$LIVE_SID" "$LIVE_TOKEN" paused "$$"

UNVERIFIABLE_SID="$(cd "$REPO" && dx_scoped_session_id branch-cleanup-unverifiable)"
dx_meta_write "$UNVERIFIABLE_SID" \
  "ticket_number=unverifiable" "wt_name=unverifiable" "wt_dir=$REPO" \
  "workspace_mode=in-place"
printf '3\n' > "$(dx_state_file "$UNVERIFIABLE_SID")"
UNVERIFIABLE_TOKEN="$(dx_session_runtime_start \
  "$UNVERIFIABLE_SID" codex "$REPO" "$$")"
export DX_SESSION_RUNTIME_PROC_ROOT="$TMP_DIR/unreadable-proc"
export DX_SESSION_RUNTIME_PS_BIN="$TMP_DIR/missing-ps"
mkdir -p "$DX_SESSION_RUNTIME_PROC_ROOT"
assert_rejected "unverifiable runtime cleanup" \
  __dx_session_management_cleanup_exact "$REPO" "$UNVERIFIABLE_SID"
unset DX_SESSION_RUNTIME_PROC_ROOT DX_SESSION_RUNTIME_PS_BIN
dx_session_runtime_finish \
  "$UNVERIFIABLE_SID" "$UNVERIFIABLE_TOKEN" paused "$$"

CORRUPT_SID="$(cd "$REPO" && dx_scoped_session_id branch-cleanup-corrupt)"
make_terminal_session "$CORRUPT_SID" "$REPO"
printf 'not-json\n' > "$(dx_session_runtime_file "$CORRUPT_SID")"
assert_rejected "corrupt runtime cleanup" \
  __dx_session_management_cleanup_exact "$REPO" "$CORRUPT_SID"
assert_file "$(dx_meta_file "$CORRUPT_SID")"

UNSAFE_SID="$(cd "$REPO" && dx_scoped_session_id branch-cleanup-unsafe)"
make_terminal_session "$UNSAFE_SID" "$REPO"
UNSAFE_TARGET="$TMP_DIR/unsafe-target"
printf 'keep\n' > "$UNSAFE_TARGET"
ln -s "$UNSAFE_TARGET" "$(dx_provider_state_file "$UNSAFE_SID")"
assert_rejected "unsafe artifact cleanup" \
  __dx_session_management_cleanup_exact "$REPO" "$UNSAFE_SID"
assert_eq "keep" "$(<"$UNSAFE_TARGET")" "unsafe symlink target"

NESTED_UNSAFE_SID="$(cd "$REPO" && dx_scoped_session_id branch-cleanup-nested-unsafe)"
make_terminal_session "$NESTED_UNSAFE_SID" "$REPO"
mkdir -p "$(dx_review_proof_dir "$NESTED_UNSAFE_SID")/1"
ln -s "$UNSAFE_TARGET" \
  "$(dx_review_proof_dir "$NESTED_UNSAFE_SID")/1/evidence.json"
assert_rejected "nested unsafe artifact cleanup" \
  __dx_session_management_cleanup_exact "$REPO" "$NESTED_UNSAFE_SID"
assert_eq "keep" "$(<"$UNSAFE_TARGET")" "nested symlink target"

# A child runtime is optional, but if present it must be dead and verifiable.
CHILD_LIVE_PARENT="$(cd "$REPO" && dx_scoped_session_id branch-child-live)"
make_terminal_session "$CHILD_LIVE_PARENT" "$REPO"
make_review_child "$CHILD_LIVE_PARENT" pass \
  33333333333333333333333333333333 0
CHILD_LIVE_SID="$REVIEW_CHILD_SID"
CHILD_LIVE_TOKEN="$(dx_session_runtime_start \
  "$CHILD_LIVE_SID" codex "$REPO" "$$")"
assert_rejected "live review child cleanup" \
  __dx_session_management_cleanup_exact "$REPO" "$CHILD_LIVE_PARENT"
assert_eq "paused" "$(dx_session_runtime_field "$CHILD_LIVE_PARENT" status)" \
  "parent unchanged by live child refusal"
dx_session_runtime_finish \
  "$CHILD_LIVE_SID" "$CHILD_LIVE_TOKEN" paused "$$"

CHILD_UNVERIFIABLE_PARENT="$(cd "$REPO" && dx_scoped_session_id branch-child-unverifiable)"
make_terminal_session "$CHILD_UNVERIFIABLE_PARENT" "$REPO"
make_review_child "$CHILD_UNVERIFIABLE_PARENT" assessment \
  44444444444444444444444444444444 0
CHILD_UNVERIFIABLE_SID="$REVIEW_CHILD_SID"
CHILD_UNVERIFIABLE_TOKEN="$(dx_session_runtime_start \
  "$CHILD_UNVERIFIABLE_SID" codex "$REPO" "$$")"
export DX_SESSION_RUNTIME_PROC_ROOT="$TMP_DIR/child-unreadable-proc"
export DX_SESSION_RUNTIME_PS_BIN="$TMP_DIR/child-missing-ps"
mkdir -p "$DX_SESSION_RUNTIME_PROC_ROOT"
assert_rejected "unverifiable review child cleanup" \
  __dx_session_management_cleanup_exact "$REPO" "$CHILD_UNVERIFIABLE_PARENT"
unset DX_SESSION_RUNTIME_PROC_ROOT DX_SESSION_RUNTIME_PS_BIN
dx_session_runtime_finish \
  "$CHILD_UNVERIFIABLE_SID" "$CHILD_UNVERIFIABLE_TOKEN" paused "$$"

CHILD_CORRUPT_PARENT="$(cd "$REPO" && dx_scoped_session_id branch-child-corrupt)"
make_terminal_session "$CHILD_CORRUPT_PARENT" "$REPO"
make_review_child "$CHILD_CORRUPT_PARENT" review \
  55555555555555555555555555555555 1
CHILD_CORRUPT_SID="$REVIEW_CHILD_SID"
printf 'not-json\n' > "$(dx_session_runtime_file "$CHILD_CORRUPT_SID")"
assert_rejected "corrupt review child cleanup" \
  __dx_session_management_cleanup_exact "$REPO" "$CHILD_CORRUPT_PARENT"
assert_eq "paused" "$(dx_session_runtime_field "$CHILD_CORRUPT_PARENT" status)" \
  "parent unchanged by corrupt child refusal"

# If parent deletion fails, every child payload has already been removed.
CHILD_FIRST_PARENT="$(cd "$REPO" && dx_scoped_session_id branch-child-first)"
make_terminal_session "$CHILD_FIRST_PARENT" "$REPO"
make_review_child "$CHILD_FIRST_PARENT" pass \
  66666666666666666666666666666666 0
CHILD_FIRST_SID="$REVIEW_CHILD_SID"
eval "$(declare -f __dx_session_management_remove_one | \
  sed '1s/^__dx_session_management_remove_one /__test_remove_one_original /')"
__dx_session_management_remove_one() {
  [[ "$1" != "$CHILD_FIRST_PARENT" ]] || return 1
  __test_remove_one_original "$@"
}
assert_rejected "parent deletion after child cleanup" \
  __dx_session_management_cleanup_exact "$REPO" "$CHILD_FIRST_PARENT"
unset -f __dx_session_management_remove_one
eval "$(declare -f __test_remove_one_original | \
  sed '1s/^__test_remove_one_original /__dx_session_management_remove_one /')"
unset -f __test_remove_one_original
assert_no_file "$(dx_meta_file "$CHILD_FIRST_SID")"
assert_file "$(dx_meta_file "$CHILD_FIRST_PARENT")"
assert_eq "failed" "$(dx_session_runtime_field "$CHILD_FIRST_PARENT" status)" \
  "child-first parent runtime"
assert_brakes "$CHILD_FIRST_SID"
assert_brakes "$CHILD_FIRST_PARENT"

# Recovery compares the selected public runtime snapshot atomically. Replacing
# the terminal record in that window refuses cleanup and leaves the replacement.
REPLACED_SID="$(cd "$REPO" && dx_scoped_session_id branch-cleanup-replaced)"
dx_meta_write "$REPLACED_SID" \
  "ticket_number=replaced" "wt_name=replaced" "wt_dir=$REPO" \
  "workspace_mode=in-place"
printf '3\n' > "$(dx_state_file "$REPLACED_SID")"
REPLACED_TOKEN="$(dx_session_runtime_start \
  "$REPLACED_SID" codex "$REPO" "$$")"
dx_session_runtime_finish "$REPLACED_SID" "$REPLACED_TOKEN" paused "$$"
eval "$(declare -f __dx_session_runtime_owner_recovery_start | \
  sed '1s/^__dx_session_runtime_owner_recovery_start /__test_recovery_start_original /')"
REPLACEMENT_DONE=0
__dx_session_runtime_owner_recovery_start() {
  local replacement_token
  if [[ "$1" == "$REPLACED_SID" && "$REPLACEMENT_DONE" -eq 0 ]]; then
    __dx_session_runtime_purge "$1" "$REPLACED_TOKEN" "$$"
    replacement_token="$(dx_session_runtime_start \
      "$1" replacement-test "$REPO" "$$")"
    dx_session_runtime_finish "$1" "$replacement_token" paused "$$"
    REPLACEMENT_DONE=1
  fi
  __test_recovery_start_original "$@"
}
assert_rejected "replaced runtime cleanup" \
  __dx_session_management_cleanup_exact "$REPO" "$REPLACED_SID"
unset -f __dx_session_runtime_owner_recovery_start
eval "$(declare -f __test_recovery_start_original | \
  sed '1s/^__test_recovery_start_original /__dx_session_runtime_owner_recovery_start /')"
unset -f __test_recovery_start_original
assert_eq "1" "$REPLACEMENT_DONE" "runtime replacement hook"
assert_eq "paused" "$(dx_session_runtime_field "$REPLACED_SID" status)" \
  "replacement runtime preserved"
assert_file "$(dx_meta_file "$REPLACED_SID")"
assert_brakes "$REPLACED_SID"

# Both revocation paths run even when either helper reports a partial failure.
RECEIPT_FAILURE_SID="$(cd "$REPO" && dx_scoped_session_id branch-receipt-failure)"
make_terminal_session "$RECEIPT_FAILURE_SID" "$REPO"
write_review_authorization "$RECEIPT_FAILURE_SID"
eval "$(declare -f dx_review_revoke_receipt | \
  sed '1s/^dx_review_revoke_receipt /__test_revoke_receipt_original /')"
dx_review_revoke_receipt() {
  __test_revoke_receipt_original "$@" || return 1
  return 1
}
assert_rejected "partial receipt revocation" \
  __dx_session_management_cleanup_exact "$REPO" "$RECEIPT_FAILURE_SID"
unset -f dx_review_revoke_receipt
eval "$(declare -f __test_revoke_receipt_original | \
  sed '1s/^__test_revoke_receipt_original /dx_review_revoke_receipt /')"
unset -f __test_revoke_receipt_original
assert_brakes "$RECEIPT_FAILURE_SID"
assert_eq "failed" "$(dx_session_runtime_field "$RECEIPT_FAILURE_SID" status)" \
  "receipt failure runtime"

SELECTION_FAILURE_SID="$(cd "$REPO" && dx_scoped_session_id branch-selection-failure)"
make_terminal_session "$SELECTION_FAILURE_SID" "$REPO"
write_review_authorization "$SELECTION_FAILURE_SID"
eval "$(declare -f dx_review_revoke_selection | \
  sed '1s/^dx_review_revoke_selection /__test_revoke_selection_original /')"
dx_review_revoke_selection() {
  __test_revoke_selection_original "$@" || return 1
  return 1
}
assert_rejected "partial selection revocation" \
  __dx_session_management_cleanup_exact "$REPO" "$SELECTION_FAILURE_SID"
unset -f dx_review_revoke_selection
eval "$(declare -f __test_revoke_selection_original | \
  sed '1s/^__test_revoke_selection_original /dx_review_revoke_selection /')"
unset -f __test_revoke_selection_original
assert_brakes "$SELECTION_FAILURE_SID"
assert_eq "failed" "$(dx_session_runtime_field "$SELECTION_FAILURE_SID" status)" \
  "selection failure runtime"

# A failed transition or checkout release occurs before purge. The recovered
# runtime is settled as failed so another cleanup can diagnose the residue.
TRANSITION_FAILURE_SID="$(cd "$REPO" && dx_scoped_session_id branch-transition-failure)"
make_terminal_session "$TRANSITION_FAILURE_SID" "$REPO"
eval "$(declare -f dx_lifecycle_control_lock_release_checked | \
  sed '1s/^dx_lifecycle_control_lock_release_checked /__test_transition_release_original /')"
TRANSITION_RELEASE_FAILED=0
dx_lifecycle_control_lock_release_checked() {
  local release_result=0
  __test_transition_release_original "$@" || release_result=$?
  if [[ "$1" == "$TRANSITION_FAILURE_SID" \
    && "$TRANSITION_RELEASE_FAILED" -eq 0 ]]; then
    TRANSITION_RELEASE_FAILED=1
    return 1
  fi
  return "$release_result"
}
assert_rejected "transition release failure" \
  __dx_session_management_cleanup_exact "$REPO" "$TRANSITION_FAILURE_SID"
unset -f dx_lifecycle_control_lock_release_checked
eval "$(declare -f __test_transition_release_original | \
  sed '1s/^__test_transition_release_original /dx_lifecycle_control_lock_release_checked /')"
unset -f __test_transition_release_original
assert_file "$(dx_session_runtime_file "$TRANSITION_FAILURE_SID")"
assert_eq "failed" "$(dx_session_runtime_field "$TRANSITION_FAILURE_SID" status)" \
  "transition release runtime"
assert_brakes "$TRANSITION_FAILURE_SID"

CHECKOUT_FAILURE_SID="$(cd "$REPO" && dx_scoped_session_id branch-checkout-failure)"
make_terminal_session "$CHECKOUT_FAILURE_SID" "$REPO"
eval "$(declare -f dx_review_lock_release_checked | \
  sed '1s/^dx_review_lock_release_checked /__test_checkout_release_original /')"
CHECKOUT_RELEASE_FAILED=0
dx_review_lock_release_checked() {
  local release_result=0
  __test_checkout_release_original "$@" || release_result=$?
  if [[ "$CHECKOUT_RELEASE_FAILED" -eq 0 ]]; then
    CHECKOUT_RELEASE_FAILED=1
    return 1
  fi
  return "$release_result"
}
assert_rejected "checkout release failure" \
  __dx_session_management_cleanup_exact "$REPO" "$CHECKOUT_FAILURE_SID"
unset -f dx_review_lock_release_checked
eval "$(declare -f __test_checkout_release_original | \
  sed '1s/^__test_checkout_release_original /dx_review_lock_release_checked /')"
unset -f __test_checkout_release_original
assert_file "$(dx_session_runtime_file "$CHECKOUT_FAILURE_SID")"
assert_eq "failed" "$(dx_session_runtime_field "$CHECKOUT_FAILURE_SID" status)" \
  "checkout release runtime"
assert_brakes "$CHECKOUT_FAILURE_SID"

# Purge failures happen only after both locks are gone and keep the brakes.
PURGE_FAILURE_SID="$(cd "$REPO" && dx_scoped_session_id branch-purge-failure)"
make_terminal_session "$PURGE_FAILURE_SID" "$REPO"
eval "$(declare -f __dx_session_runtime_owner_purge | \
  sed '1s/^__dx_session_runtime_owner_purge /__test_owner_purge_original /')"
__dx_session_runtime_owner_purge() {
  dx_session_runtime_owner_finish "$1" failed >/dev/null 2>&1 || true
  return 1
}
assert_rejected "runtime purge failure" \
  __dx_session_management_cleanup_exact "$REPO" "$PURGE_FAILURE_SID"
unset -f __dx_session_runtime_owner_purge
eval "$(declare -f __test_owner_purge_original | \
  sed '1s/^__test_owner_purge_original /__dx_session_runtime_owner_purge /')"
unset -f __test_owner_purge_original
assert_file "$(dx_session_runtime_file "$PURGE_FAILURE_SID")"
assert_eq "failed" "$(dx_session_runtime_field "$PURGE_FAILURE_SID" status)" \
  "purge failure runtime"
assert_no_file "$(dx_lifecycle_control_lock_dir "$PURGE_FAILURE_SID")"
assert_no_file "$(dx_review_lock_dir "$REPO")"
assert_brakes "$PURGE_FAILURE_SID"

# A missing recorded worktree is accepted only after the dead-runtime CAS has
# transferred ownership. Cleanup never touches the worktree ref or run journal.
MISSING_WORKSPACE="$REPO/.dex/worktrees/missing-cleanup"
mkdir -p "$MISSING_WORKSPACE"
MISSING_SID="$(cd "$REPO" && dx_scoped_session_id worktree-missing-cleanup)"
dx_meta_write "$MISSING_SID" \
  "ticket_number=missing" "wt_name=missing-cleanup" \
  "wt_dir=$MISSING_WORKSPACE" "workspace_mode=worktree"
printf '3\n' > "$(dx_state_file "$MISSING_SID")"
MISSING_TOKEN="$(dx_session_runtime_start \
  "$MISSING_SID" codex "$MISSING_WORKSPACE" "$$")"
dx_session_runtime_finish "$MISSING_SID" "$MISSING_TOKEN" paused "$$"
rmdir "$MISSING_WORKSPACE"
__dx_session_management_cleanup_exact "$REPO" "$MISSING_SID"
assert_no_file "$(dx_session_runtime_file "$MISSING_SID")"
assert_file "$(dx_session_runtime_file "$MISSING_SID")-lock"

printf '%s\n' "session management tests passed"

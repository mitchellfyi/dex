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

# Cleanup can fail before the journal contains any held entry. Keep that path
# safe under zsh's default NOMATCH behavior as well as bash.
EMPTY_ZDOT_DIR="$TMP_DIR/empty-zdot"
mkdir -p "$EMPTY_ZDOT_DIR"
DX_TEST_SESSION_MANAGEMENT="$ROOT/lib/session-management.sh" \
  ZDOTDIR="$EMPTY_ZDOT_DIR" \
  zsh -f -c '
    set -eu
    setopt nomatch
    source "$DX_TEST_SESSION_MANAGEMENT"
    __dx_session_management_journal() {
      [[ "$1" == "entries" ]] || return 1
      return 0
    }
    __dx_session_management_release_entries journal parent repo
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
assert_rejected "cleaned session absent from catalog" \
  dx_session_catalog_record "$SID" --repo "$REPO"

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

make_completed_session() { # <sid> <workspace>
  local fixture_sid="$1" fixture_workspace="$2" fixture_token
  dx_meta_write "$fixture_sid" \
    "ticket_number=${fixture_sid##*-}" \
    "wt_name=${fixture_sid##*-}" \
    "wt_dir=$fixture_workspace" \
    "workspace_mode=in-place"
  printf '7\n' > "$(dx_state_file "$fixture_sid")"
  printf 'version=1\nphase=7\ntransition_token=100-200-300\nauthority=0123456789abcdef0123456789abcdef\n' \
    > "$DX_STATE_DIR/${fixture_sid}.terminal-commit"
  chmod 600 "$(dx_state_file "$fixture_sid")" \
    "$DX_STATE_DIR/${fixture_sid}.terminal-commit"
  fixture_token="$(dx_session_runtime_start \
    "$fixture_sid" codex "$fixture_workspace" "$$")"
  dx_session_runtime_finish "$fixture_sid" "$fixture_token" completed "$$"
}

# The completed-only path must replace the outside-lock catalog policy with a
# lock-aware revalidation. Its own control lock makes the catalog state
# unknown, so the terminal proof is validated directly while that lock is held.
LOCKED_POLICY_SID="$(cd "$REPO" && dx_scoped_session_id branch-locked-policy)"
make_completed_session "$LOCKED_POLICY_SID" "$REPO"
LOCKED_POLICY_SEEN=0
eval "$(declare -f __dx_lifecycle_terminal_commit_valid_unlocked | \
  sed '1s/^__dx_lifecycle_terminal_commit_valid_unlocked /__test_terminal_valid_original /')"
__dx_lifecycle_terminal_commit_valid_unlocked() {
  if [[ "$1" == "$LOCKED_POLICY_SID" ]]; then
    __dx_lifecycle_control_lock_owned "$1" || return 1
    LOCKED_POLICY_SEEN=1
  fi
  __test_terminal_valid_original "$@"
}
__dx_session_management_cleanup_completed_exact "$REPO" "$LOCKED_POLICY_SID"
unset -f __dx_lifecycle_terminal_commit_valid_unlocked
eval "$(declare -f __test_terminal_valid_original | \
  sed '1s/^__test_terminal_valid_original /__dx_lifecycle_terminal_commit_valid_unlocked /')"
unset -f __test_terminal_valid_original
assert_eq "1" "$LOCKED_POLICY_SEEN" "completed policy validates under lock"
assert_no_file "$(dx_meta_file "$LOCKED_POLICY_SID")"
assert_no_file "$(dx_session_cleanup_journal_file "$LOCKED_POLICY_SID")"

# Candidate discovery is advisory. A new runtime generation that finishes
# paused after discovery must be caught by the locked recheck.
RUNTIME_DRIFT_SID="$(cd "$REPO" && dx_scoped_session_id branch-runtime-drift)"
make_completed_session "$RUNTIME_DRIFT_SID" "$REPO"
RUNTIME_DRIFT_PROOF_BEFORE="$(cksum \
  "$DX_STATE_DIR/${RUNTIME_DRIFT_SID}.terminal-commit")"
dx_session_catalog_records --repo "$REPO" --include-children \
  > "$TMP_DIR/runtime-drift-before.jsonl"
__dx_session_management_completed_candidates \
  "$REPO" "$TMP_DIR/runtime-drift-before.jsonl" \
  > "$TMP_DIR/runtime-drift-candidates"
assert_contains "$RUNTIME_DRIFT_SID" "$TMP_DIR/runtime-drift-candidates"
RUNTIME_DRIFT_INJECTED=0
eval "$(declare -f dx_lifecycle_control_lock_acquire | \
  sed '1s/^dx_lifecycle_control_lock_acquire /__test_control_acquire_original /')"
dx_lifecycle_control_lock_acquire() {
  local drift_token
  __test_control_acquire_original "$@" || return
  if [[ "$1" == "$RUNTIME_DRIFT_SID" \
    && "$RUNTIME_DRIFT_INJECTED" -eq 0 ]]; then
    RUNTIME_DRIFT_INJECTED=1
    drift_token="$(dx_session_runtime_start \
      "$RUNTIME_DRIFT_SID" codex "$REPO" "$$")" || return 1
    dx_session_runtime_finish \
      "$RUNTIME_DRIFT_SID" "$drift_token" paused "$$" || return 1
  fi
}
assert_rejected "completed-to-paused drift" \
  __dx_session_management_cleanup_completed_exact "$REPO" "$RUNTIME_DRIFT_SID"
unset -f dx_lifecycle_control_lock_acquire
eval "$(declare -f __test_control_acquire_original | \
  sed '1s/^__test_control_acquire_original /dx_lifecycle_control_lock_acquire /')"
unset -f __test_control_acquire_original
assert_eq "1" "$RUNTIME_DRIFT_INJECTED" "runtime drift injected under lock"
assert_file "$(dx_meta_file "$RUNTIME_DRIFT_SID")"
assert_file "$(dx_session_runtime_file "$RUNTIME_DRIFT_SID")"
assert_eq "$RUNTIME_DRIFT_PROOF_BEFORE" \
  "$(cksum "$DX_STATE_DIR/${RUNTIME_DRIFT_SID}.terminal-commit")" \
  "runtime drift preserves terminal proof"
assert_no_file "$(dx_session_cleanup_journal_file "$RUNTIME_DRIFT_SID")"
assert_no_file "$(dx_lifecycle_control_lock_dir "$RUNTIME_DRIFT_SID")"

# A reserved-prefix artifact that appears after discovery may be a review child
# whose provenance is incomplete. Revalidation must preserve the whole family.
CHILD_DRIFT_PARENT="$(cd "$REPO" && dx_scoped_session_id branch-child-drift)"
make_completed_session "$CHILD_DRIFT_PARENT" "$REPO"
dx_session_catalog_records --repo "$REPO" --include-children \
  > "$TMP_DIR/child-drift-before.jsonl"
__dx_session_management_completed_candidates \
  "$REPO" "$TMP_DIR/child-drift-before.jsonl" \
  > "$TMP_DIR/child-drift-candidates"
assert_contains "$CHILD_DRIFT_PARENT" "$TMP_DIR/child-drift-candidates"
CHILD_DRIFT_SID="${CHILD_DRIFT_PARENT:0:120}-review-dddddddddddddddddddddddddddddddd"
CHILD_DRIFT_INJECTED=0
eval "$(declare -f dx_lifecycle_control_lock_acquire | \
  sed '1s/^dx_lifecycle_control_lock_acquire /__test_control_acquire_original /')"
dx_lifecycle_control_lock_acquire() {
  __test_control_acquire_original "$@" || return
  if [[ "$1" == "$CHILD_DRIFT_PARENT" \
    && "$CHILD_DRIFT_INJECTED" -eq 0 ]]; then
    CHILD_DRIFT_INJECTED=1
    dx_meta_write "$CHILD_DRIFT_SID" \
      "ticket_number=child-drift" \
      "wt_name=child-drift" \
      "wt_dir=$REPO" \
      "workspace_mode=in-place" || return 1
    printf '3\n' > "$(dx_state_file "$CHILD_DRIFT_SID")" || return 1
    chmod 600 "$(dx_state_file "$CHILD_DRIFT_SID")" || return 1
  fi
}
assert_rejected "reserved-prefix child drift" \
  __dx_session_management_cleanup_completed_exact "$REPO" "$CHILD_DRIFT_PARENT"
unset -f dx_lifecycle_control_lock_acquire
eval "$(declare -f __test_control_acquire_original | \
  sed '1s/^__test_control_acquire_original /dx_lifecycle_control_lock_acquire /')"
unset -f __test_control_acquire_original
assert_eq "1" "$CHILD_DRIFT_INJECTED" "child drift injected under lock"
assert_file "$(dx_meta_file "$CHILD_DRIFT_PARENT")"
assert_file "$(dx_meta_file "$CHILD_DRIFT_SID")"
assert_no_file "$(dx_session_cleanup_journal_file "$CHILD_DRIFT_PARENT")"
assert_no_file "$(dx_lifecycle_control_lock_dir "$CHILD_DRIFT_PARENT")"

# Completed-only bulk cleanup cannot inherit a broader exact-forget journal.
# The candidate snapshot excludes journals, so finding one after the claim is
# a concurrent-policy change and must fail closed.
JOURNAL_POLICY_SID="$(cd "$REPO" && dx_scoped_session_id branch-journal-policy)"
make_completed_session "$JOURNAL_POLICY_SID" "$REPO"
dx_session_catalog_records --repo "$REPO" --include-children \
  > "$TMP_DIR/journal-policy-before.jsonl"
__dx_session_management_completed_candidates \
  "$REPO" "$TMP_DIR/journal-policy-before.jsonl" \
  > "$TMP_DIR/journal-policy-candidates"
assert_contains "$JOURNAL_POLICY_SID" "$TMP_DIR/journal-policy-candidates"
eval "$(declare -f __dx_session_management_claim_pending | \
  sed '1s/^__dx_session_management_claim_pending /__test_policy_claim_pending_original /')"
__dx_session_management_claim_pending() {
  if [[ "$2" == "$JOURNAL_POLICY_SID" ]]; then
    return 1
  fi
  __test_policy_claim_pending_original "$@"
}
assert_rejected "seed broader cleanup journal" \
  __dx_session_management_cleanup_exact "$REPO" "$JOURNAL_POLICY_SID"
unset -f __dx_session_management_claim_pending
eval "$(declare -f __test_policy_claim_pending_original | \
  sed '1s/^__test_policy_claim_pending_original /__dx_session_management_claim_pending /')"
unset -f __test_policy_claim_pending_original
assert_file "$DX_LOOP_DIR/${JOURNAL_POLICY_SID}.cleanup-journal"
assert_rejected "completed cleanup rejects broader journal" \
  __dx_session_management_cleanup_completed_exact "$REPO" "$JOURNAL_POLICY_SID"
assert_file "$(dx_meta_file "$JOURNAL_POLICY_SID")"
assert_file "$DX_LOOP_DIR/${JOURNAL_POLICY_SID}.cleanup-journal"
__dx_session_management_cleanup_exact "$REPO" "$JOURNAL_POLICY_SID"
assert_no_file "$DX_LOOP_DIR/${JOURNAL_POLICY_SID}.cleanup-journal"

# Once the trusted final inventory is validated, unlinking the journal is the
# semantic commit. Diagnostics and temporary cleanup cannot turn that commit
# into an unretryable failure after all session evidence is gone.
FINAL_COMMIT_SID="$(cd "$REPO" && dx_scoped_session_id branch-final-commit)"
make_terminal_session "$FINAL_COMMIT_SID" "$REPO"
eval "$(declare -f __dx_session_management_journal | \
  sed '1s/^__dx_session_management_journal /__test_final_journal_original /')"
eval "$(declare -f __dx_session_management_remove_transaction_dir | \
  sed '1s/^__dx_session_management_remove_transaction_dir /__test_final_temp_original /')"
FINAL_JOURNAL_UNLINKED=0
FINAL_TEMP_REPORTED_FAILURE=0
__dx_session_management_journal() {
  local journal_result=0
  __test_final_journal_original "$@" || journal_result=$?
  if [[ "$1" == "remove" && "$3" == "$FINAL_COMMIT_SID" \
    && "$journal_result" -eq 0 ]]; then
    FINAL_JOURNAL_UNLINKED=1
    return 1
  fi
  return "$journal_result"
}
__dx_session_management_remove_transaction_dir() {
  local temp_result=0
  __test_final_temp_original "$@" || temp_result=$?
  if [[ "$FINAL_JOURNAL_UNLINKED" -eq 1 && "$temp_result" -eq 0 ]]; then
    FINAL_TEMP_REPORTED_FAILURE=1
    return 1
  fi
  return "$temp_result"
}
__dx_session_management_cleanup_exact "$REPO" "$FINAL_COMMIT_SID"
unset -f __dx_session_management_journal __dx_session_management_remove_transaction_dir
eval "$(declare -f __test_final_journal_original | \
  sed '1s/^__test_final_journal_original /__dx_session_management_journal /')"
eval "$(declare -f __test_final_temp_original | \
  sed '1s/^__test_final_temp_original /__dx_session_management_remove_transaction_dir /')"
unset -f __test_final_journal_original __test_final_temp_original
assert_eq "1" "$FINAL_JOURNAL_UNLINKED" "journal unlink failpoint"
assert_eq "1" "$FINAL_TEMP_REPORTED_FAILURE" "temporary cleanup failpoint"
assert_no_file "$DX_LOOP_DIR/${FINAL_COMMIT_SID}.cleanup-journal"
assert_no_file "$(dx_session_runtime_file "$FINAL_COMMIT_SID")"
assert_rejected "final commit absent from catalog" \
  dx_session_catalog_record "$FINAL_COMMIT_SID" --repo "$REPO"

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

# Provenance alone does not prove a child process stopped. A child without a
# runtime needs the parent's exact Phase 3 quiescence or a trusted completion
# proof before cleanup can accept it.
ORPHAN_PARENT="$(cd "$REPO" && dx_scoped_session_id branch-cleanup-orphan)"
make_terminal_session "$ORPHAN_PARENT" "$REPO"
make_review_child "$ORPHAN_PARENT" assessment \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0
ORPHAN_CHILD="$REVIEW_CHILD_SID"
assert_rejected "provenance-only orphan cleanup" \
  __dx_session_management_cleanup_exact "$REPO" "$ORPHAN_PARENT"
assert_file "$(dx_meta_file "$ORPHAN_PARENT")"
assert_file "$(dx_meta_file "$ORPHAN_CHILD")"

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
CHILD_FIRST_BUSY="$(dx_phase_busy_begin \
  "$CHILD_FIRST_PARENT" 3 "review child")"
dx_phase_busy_acknowledge "$CHILD_FIRST_PARENT" 3 "$CHILD_FIRST_BUSY"
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
assert_file "$DX_LOOP_DIR/${CHILD_FIRST_PARENT}.cleanup-journal"
__dx_session_management_cleanup_exact "$REPO" "$CHILD_FIRST_PARENT"
assert_no_file "$DX_LOOP_DIR/${CHILD_FIRST_PARENT}.cleanup-journal"
assert_rejected "retried child absent from catalog" \
  dx_session_catalog_record "$CHILD_FIRST_SID" --repo "$REPO"
assert_rejected "retried parent absent from catalog" \
  dx_session_catalog_record "$CHILD_FIRST_PARENT" --repo "$REPO"

# A replacement that lands after the journal snapshot but before claim must
# fail the exact recovery CAS. Cleanup must never refresh that snapshot.
STALE_CLAIM_SID="$(cd "$REPO" && dx_scoped_session_id branch-stale-claim)"
make_terminal_session "$STALE_CLAIM_SID" "$REPO"
eval "$(declare -f __dx_session_management_claim_runtime | \
  sed '1s/^__dx_session_management_claim_runtime /__test_claim_runtime_original /')"
STALE_CLAIM_REPLACED=0
__dx_session_management_claim_runtime() {
  local stale_token
  if [[ "$1" == "$STALE_CLAIM_SID" && "$STALE_CLAIM_REPLACED" -eq 0 ]]; then
    stale_token="$(python3 - "$(dx_session_runtime_file "$1")" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    print(json.load(source)["token"])
PY
    )"
    __dx_session_runtime_purge "$1" "$stale_token" "$$"
    stale_token="$(dx_session_runtime_start \
      "$1" stale-generation "$REPO" "$$")"
    dx_session_runtime_finish "$1" "$stale_token" paused "$$"
    STALE_CLAIM_REPLACED=1
  fi
  __test_claim_runtime_original "$@"
}
assert_rejected "stale generation before claim" \
  __dx_session_management_cleanup_exact "$REPO" "$STALE_CLAIM_SID"
unset -f __dx_session_management_claim_runtime
eval "$(declare -f __test_claim_runtime_original | \
  sed '1s/^__test_claim_runtime_original /__dx_session_management_claim_runtime /')"
unset -f __test_claim_runtime_original
assert_eq "1" "$STALE_CLAIM_REPLACED" "stale claim replacement hook"
assert_eq "stale-generation" \
  "$(dx_session_runtime_field "$STALE_CLAIM_SID" provider)" \
  "stale claim replacement preserved"
assert_file "$(dx_meta_file "$STALE_CLAIM_SID")"

# The recovery owner is durably correlated before the final claimed-stage
# commit. If that commit fails, cleanup settles the owner and the next call can
# reclaim the exact terminal snapshot instead of stranding `claiming` forever.
CLAIM_COMMIT_SID="$(cd "$REPO" && dx_scoped_session_id branch-claim-commit)"
make_terminal_session "$CLAIM_COMMIT_SID" "$REPO"
eval "$(declare -f __dx_session_management_journal | \
  sed '1s/^__dx_session_management_journal /__test_claim_journal_original /')"
CLAIM_COMMIT_FAILED=0
__dx_session_management_journal() {
  if [[ "$1" == "claimed" && "$3" == "$CLAIM_COMMIT_SID" \
    && "$CLAIM_COMMIT_FAILED" -eq 0 ]]; then
    CLAIM_COMMIT_FAILED=1
    return 1
  fi
  __test_claim_journal_original "$@"
}
assert_rejected "claimed journal commit failure" \
  __dx_session_management_cleanup_exact "$REPO" "$CLAIM_COMMIT_SID"
unset -f __dx_session_management_journal
eval "$(declare -f __test_claim_journal_original | \
  sed '1s/^__test_claim_journal_original /__dx_session_management_journal /')"
unset -f __test_claim_journal_original
assert_eq "1" "$CLAIM_COMMIT_FAILED" "claimed journal failpoint"
assert_eq "failed" "$(dx_session_runtime_field "$CLAIM_COMMIT_SID" status)" \
  "claimed journal fallback runtime"
assert_file "$DX_LOOP_DIR/${CLAIM_COMMIT_SID}.cleanup-journal"
__dx_session_management_cleanup_exact "$REPO" "$CLAIM_COMMIT_SID"
assert_no_file "$DX_LOOP_DIR/${CLAIM_COMMIT_SID}.cleanup-journal"
assert_no_file "$(dx_session_runtime_file "$CLAIM_COMMIT_SID")"

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
assert_no_file "$(dx_lifecycle_control_lock_dir "$TRANSITION_FAILURE_SID")"
__dx_session_management_cleanup_exact "$REPO" "$TRANSITION_FAILURE_SID"
assert_no_file "$DX_LOOP_DIR/${TRANSITION_FAILURE_SID}.cleanup-journal"

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
assert_file "$DX_LOOP_DIR/${CHECKOUT_FAILURE_SID}.cleanup-journal"
__dx_session_management_cleanup_exact "$REPO" "$CHECKOUT_FAILURE_SID"
assert_no_file "$DX_LOOP_DIR/${CHECKOUT_FAILURE_SID}.cleanup-journal"

# A release helper can fail without making progress. Cleanup detaches only the
# exact lock generation it owns, so the canonical lock is free for a retry.
PERSISTENT_TRANSITION_SID="$(cd "$REPO" && dx_scoped_session_id branch-transition-stuck)"
make_terminal_session "$PERSISTENT_TRANSITION_SID" "$REPO"
eval "$(declare -f dx_lifecycle_control_lock_release_checked | \
  sed '1s/^dx_lifecycle_control_lock_release_checked /__test_stuck_transition_original /')"
dx_lifecycle_control_lock_release_checked() {
  if [[ "$1" == "$PERSISTENT_TRANSITION_SID" ]]; then
    return 1
  fi
  __test_stuck_transition_original "$@"
}
assert_rejected "persistent transition release failure" \
  __dx_session_management_cleanup_exact "$REPO" "$PERSISTENT_TRANSITION_SID"
unset -f dx_lifecycle_control_lock_release_checked
eval "$(declare -f __test_stuck_transition_original | \
  sed '1s/^__test_stuck_transition_original /dx_lifecycle_control_lock_release_checked /')"
unset -f __test_stuck_transition_original
assert_no_file "$(dx_lifecycle_control_lock_dir "$PERSISTENT_TRANSITION_SID")"
assert_file "$DX_LOOP_DIR/${PERSISTENT_TRANSITION_SID}.cleanup-journal"
__dx_session_management_cleanup_exact "$REPO" "$PERSISTENT_TRANSITION_SID"
assert_no_file "$DX_LOOP_DIR/${PERSISTENT_TRANSITION_SID}.cleanup-journal"

PERSISTENT_CHECKOUT_SID="$(cd "$REPO" && dx_scoped_session_id branch-checkout-stuck)"
make_terminal_session "$PERSISTENT_CHECKOUT_SID" "$REPO"
eval "$(declare -f dx_review_lock_release_checked | \
  sed '1s/^dx_review_lock_release_checked /__test_stuck_checkout_original /')"
dx_review_lock_release_checked() {
  return 1
}
assert_rejected "persistent checkout release failure" \
  __dx_session_management_cleanup_exact "$REPO" "$PERSISTENT_CHECKOUT_SID"
unset -f dx_review_lock_release_checked
eval "$(declare -f __test_stuck_checkout_original | \
  sed '1s/^__test_stuck_checkout_original /dx_review_lock_release_checked /')"
unset -f __test_stuck_checkout_original
assert_no_file "$(dx_review_lock_dir "$REPO")"
assert_file "$DX_LOOP_DIR/${PERSISTENT_CHECKOUT_SID}.cleanup-journal"
__dx_session_management_cleanup_exact "$REPO" "$PERSISTENT_CHECKOUT_SID"
assert_no_file "$DX_LOOP_DIR/${PERSISTENT_CHECKOUT_SID}.cleanup-journal"

# An existing foreign owner is not the same as an absent canonical lock. The
# detach path rejects it without changing the foreign record.
FOREIGN_LIFECYCLE_SID="$(cd "$REPO" && dx_scoped_session_id branch-foreign-lifecycle-lock)"
dx_lifecycle_control_lock_acquire "$FOREIGN_LIFECYCLE_SID"
FOREIGN_LIFECYCLE_EXPECTED_TOKEN="$DX_LIFECYCLE_CONTROL_LOCK_TOKEN"
FOREIGN_LIFECYCLE_LOCK="$(dx_lifecycle_control_lock_dir "$FOREIGN_LIFECYCLE_SID")"
FOREIGN_LIFECYCLE_OWNER="$FOREIGN_LIFECYCLE_LOCK/owner"
FOREIGN_LIFECYCLE_ORIGINAL="$(<"$FOREIGN_LIFECYCLE_OWNER")"
FOREIGN_LIFECYCLE_TOKEN="$(date +%s)-$$-9101"
printf '%s\t%s\t%s\n' "$$" "$(date +%s)" "$FOREIGN_LIFECYCLE_TOKEN" \
  > "$FOREIGN_LIFECYCLE_OWNER"
FOREIGN_OWNER_STATE=0
__dx_session_management_lifecycle_owner_state "$FOREIGN_LIFECYCLE_SID" \
  "$$" "$FOREIGN_LIFECYCLE_EXPECTED_TOKEN" || FOREIGN_OWNER_STATE=$?
assert_eq "2" "$FOREIGN_OWNER_STATE" "foreign lifecycle owner state"
assert_rejected "foreign lifecycle owner detach" \
  __dx_session_management_detach_lifecycle_lock "$FOREIGN_LIFECYCLE_SID" \
    "$$" "$FOREIGN_LIFECYCLE_EXPECTED_TOKEN"
assert_eq "$FOREIGN_LIFECYCLE_TOKEN" \
  "$(awk -F '\t' 'NR == 1 { print $3 }' "$FOREIGN_LIFECYCLE_OWNER")" \
  "foreign lifecycle owner preserved"
printf '%s\n' "$FOREIGN_LIFECYCLE_ORIGINAL" > "$FOREIGN_LIFECYCLE_OWNER"
__dx_session_management_detach_lifecycle_lock "$FOREIGN_LIFECYCLE_SID" \
  "$$" "$FOREIGN_LIFECYCLE_EXPECTED_TOKEN"
assert_no_file "$FOREIGN_LIFECYCLE_LOCK"

FOREIGN_CHECKOUT_TOKEN="$(date +%s)-$$-9201"
dx_review_lock_acquire "$REPO" "$FOREIGN_CHECKOUT_TOKEN" "$$"
FOREIGN_CHECKOUT_LOCK="$(dx_review_lock_dir "$REPO")"
FOREIGN_CHECKOUT_OWNER="$FOREIGN_CHECKOUT_LOCK/owner"
FOREIGN_CHECKOUT_ORIGINAL="$(<"$FOREIGN_CHECKOUT_OWNER")"
FOREIGN_CHECKOUT_OTHER_TOKEN="$(date +%s)-$$-9202"
printf '%s\t%s\t%s\n' "$(date +%s)" "$$" "$FOREIGN_CHECKOUT_OTHER_TOKEN" \
  > "$FOREIGN_CHECKOUT_OWNER"
FOREIGN_OWNER_STATE=0
__dx_session_management_review_owner_state "$REPO" \
  "$$" "$FOREIGN_CHECKOUT_TOKEN" || FOREIGN_OWNER_STATE=$?
assert_eq "2" "$FOREIGN_OWNER_STATE" "foreign checkout owner state"
assert_rejected "foreign checkout owner detach" \
  __dx_session_management_detach_checkout_lock "$REPO" \
    "$$" "$FOREIGN_CHECKOUT_TOKEN"
assert_eq "$FOREIGN_CHECKOUT_OTHER_TOKEN" \
  "$(awk -F '\t' 'NR == 1 { print $3 }' "$FOREIGN_CHECKOUT_OWNER")" \
  "foreign checkout owner preserved"
printf '%s\n' "$FOREIGN_CHECKOUT_ORIGINAL" > "$FOREIGN_CHECKOUT_OWNER"
__dx_session_management_detach_checkout_lock "$REPO" "$$" "$FOREIGN_CHECKOUT_TOKEN"
assert_no_file "$FOREIGN_CHECKOUT_LOCK"

# If the canonical directory is swapped after the identity snapshot, detached
# revalidation restores the foreign directory and leaves the saved owner alone.
SWAP_LIFECYCLE_SID="$(cd "$REPO" && dx_scoped_session_id branch-swap-lifecycle-lock)"
dx_lifecycle_control_lock_acquire "$SWAP_LIFECYCLE_SID"
SWAP_LIFECYCLE_TOKEN="$DX_LIFECYCLE_CONTROL_LOCK_TOKEN"
SWAP_LIFECYCLE_LOCK="$(dx_lifecycle_control_lock_dir "$SWAP_LIFECYCLE_SID")"
SWAP_LIFECYCLE_SAVED="${SWAP_LIFECYCLE_LOCK}.test-owned"
SWAP_LIFECYCLE_FOREIGN="$(date +%s)-$$-9301"
eval "$(declare -f __dx_session_management_detach_checkpoint | \
  sed '1s/^__dx_session_management_detach_checkpoint /__test_detach_checkpoint_original /')"
__dx_session_management_detach_checkpoint() {
  [[ "$1" == "lifecycle" && "$2" == "$SWAP_LIFECYCLE_LOCK" ]] || return 0
  command mv "$2" "$SWAP_LIFECYCLE_SAVED"
  mkdir "$2"
  chmod 700 "$2"
  printf '%s\t%s\t%s\n' "$$" "$(date +%s)" "$SWAP_LIFECYCLE_FOREIGN" \
    > "$2/owner"
  chmod 600 "$2/owner"
}
assert_rejected "post-check lifecycle owner swap" \
  __dx_session_management_detach_lifecycle_lock "$SWAP_LIFECYCLE_SID" \
    "$$" "$SWAP_LIFECYCLE_TOKEN"
unset -f __dx_session_management_detach_checkpoint
eval "$(declare -f __test_detach_checkpoint_original | \
  sed '1s/^__test_detach_checkpoint_original /__dx_session_management_detach_checkpoint /')"
unset -f __test_detach_checkpoint_original
assert_eq "$SWAP_LIFECYCLE_FOREIGN" \
  "$(awk -F '\t' 'NR == 1 { print $3 }' "$SWAP_LIFECYCLE_LOCK/owner")" \
  "swapped lifecycle owner restored"
assert_file "$SWAP_LIFECYCLE_SAVED/owner"
command rm -rf -- "$SWAP_LIFECYCLE_LOCK"
command mv "$SWAP_LIFECYCLE_SAVED" "$SWAP_LIFECYCLE_LOCK"
__dx_session_management_detach_lifecycle_lock "$SWAP_LIFECYCLE_SID" \
  "$$" "$SWAP_LIFECYCLE_TOKEN"
assert_no_file "$SWAP_LIFECYCLE_LOCK"

SWAP_CHECKOUT_TOKEN="$(date +%s)-$$-9401"
dx_review_lock_acquire "$REPO" "$SWAP_CHECKOUT_TOKEN" "$$"
SWAP_CHECKOUT_LOCK="$(dx_review_lock_dir "$REPO")"
SWAP_CHECKOUT_SAVED="${SWAP_CHECKOUT_LOCK}.test-owned"
SWAP_CHECKOUT_FOREIGN="$(date +%s)-$$-9402"
eval "$(declare -f __dx_session_management_detach_checkpoint | \
  sed '1s/^__dx_session_management_detach_checkpoint /__test_detach_checkpoint_original /')"
__dx_session_management_detach_checkpoint() {
  [[ "$1" == "checkout" && "$2" == "$SWAP_CHECKOUT_LOCK" ]] || return 0
  command mv "$2" "$SWAP_CHECKOUT_SAVED"
  mkdir "$2"
  chmod 700 "$2"
  printf '%s\t%s\t%s\n' "$(date +%s)" "$$" "$SWAP_CHECKOUT_FOREIGN" \
    > "$2/owner"
  chmod 600 "$2/owner"
}
assert_rejected "post-check checkout owner swap" \
  __dx_session_management_detach_checkout_lock "$REPO" "$$" "$SWAP_CHECKOUT_TOKEN"
unset -f __dx_session_management_detach_checkpoint
eval "$(declare -f __test_detach_checkpoint_original | \
  sed '1s/^__test_detach_checkpoint_original /__dx_session_management_detach_checkpoint /')"
unset -f __test_detach_checkpoint_original
assert_eq "$SWAP_CHECKOUT_FOREIGN" \
  "$(awk -F '\t' 'NR == 1 { print $3 }' "$SWAP_CHECKOUT_LOCK/owner")" \
  "swapped checkout owner restored"
assert_file "$SWAP_CHECKOUT_SAVED/owner"
command rm -rf -- "$SWAP_CHECKOUT_LOCK"
command mv "$SWAP_CHECKOUT_SAVED" "$SWAP_CHECKOUT_LOCK"
__dx_session_management_detach_checkout_lock "$REPO" "$$" "$SWAP_CHECKOUT_TOKEN"
assert_no_file "$SWAP_CHECKOUT_LOCK"

# A missing owner file means "absent" only when the canonical lock path is
# also absent. Publication windows and malformed canonical objects stay held
# in the journal and are never detached or deleted.
CANONICAL_LIFECYCLE_SID="$(cd "$REPO" && dx_scoped_session_id branch-canonical-state)"
CANONICAL_LIFECYCLE_LOCK="$(dx_lifecycle_control_lock_dir "$CANONICAL_LIFECYCLE_SID")"
CANONICAL_LIFECYCLE_TOKEN="$(date +%s)-$$-9501"
CANONICAL_CHECKOUT_LOCK="$(dx_review_lock_dir "$REPO")"
CANONICAL_CHECKOUT_TOKEN="$(date +%s)-$$-9502"
eval "$(declare -f __dx_session_management_journal | \
  sed '1s/^__dx_session_management_journal /__test_canonical_journal_original /')"
eval "$(declare -f dx_lifecycle_control_lock_release_checked | \
  sed '1s/^dx_lifecycle_control_lock_release_checked /__test_canonical_lifecycle_release_original /')"
eval "$(declare -f dx_review_lock_release_checked | \
  sed '1s/^dx_review_lock_release_checked /__test_canonical_checkout_release_original /')"
CANONICAL_LIFECYCLE_MARKED_RELEASED=0
CANONICAL_CHECKOUT_MARKED_RELEASED=0
__dx_session_management_journal() {
  case "$1" in
    entry-lock)
      printf 'held\t%s\t%s\n' "$$" "$CANONICAL_LIFECYCLE_TOKEN"
      ;;
    lock-released)
      CANONICAL_LIFECYCLE_MARKED_RELEASED=1
      ;;
    workspace)
      printf '%s\n' "$REPO"
      ;;
    checkout)
      printf 'held\t%s\t%s\n' "$$" "$CANONICAL_CHECKOUT_TOKEN"
      ;;
    checkout-released)
      CANONICAL_CHECKOUT_MARKED_RELEASED=1
      ;;
    *) return 1 ;;
  esac
}
dx_lifecycle_control_lock_release_checked() { return 1; }
dx_review_lock_release_checked() { return 1; }

make_untrusted_canonical() { # <kind> <canonical-path>
  local canonical_kind="$1" canonical_file="$2"
  case "$canonical_kind" in
    empty-dir)
      mkdir "$canonical_file"
      chmod 700 "$canonical_file"
      ;;
    symlink)
      mkdir "${canonical_file}.test-target"
      ln -s "${canonical_file}.test-target" "$canonical_file"
      ;;
    non-directory)
      printf 'not a lock\n' > "$canonical_file"
      chmod 600 "$canonical_file"
      ;;
    malformed)
      mkdir "$canonical_file"
      chmod 700 "$canonical_file"
      printf 'malformed owner\n' > "$canonical_file/owner"
      chmod 600 "$canonical_file/owner"
      ;;
    *) return 1 ;;
  esac
}

remove_untrusted_canonical() { # <canonical-path>
  local canonical_file="$1"
  command rm -rf -- "$canonical_file" "${canonical_file}.test-target"
}

for canonical_kind in empty-dir symlink non-directory malformed; do
  make_untrusted_canonical "$canonical_kind" "$CANONICAL_LIFECYCLE_LOCK"
  CANONICAL_OWNER_STATE=0
  __dx_session_management_lifecycle_owner_state "$CANONICAL_LIFECYCLE_SID" \
    "$$" "$CANONICAL_LIFECYCLE_TOKEN" || CANONICAL_OWNER_STATE=$?
  assert_eq "2" "$CANONICAL_OWNER_STATE" \
    "lifecycle ${canonical_kind} canonical state"
  CANONICAL_LIFECYCLE_MARKED_RELEASED=0
  assert_rejected "lifecycle ${canonical_kind} canonical release" \
    __dx_session_management_entry_release journal parent "$REPO" \
      "$CANONICAL_LIFECYCLE_SID"
  assert_eq "0" "$CANONICAL_LIFECYCLE_MARKED_RELEASED" \
    "lifecycle ${canonical_kind} journal held"
  [[ -e "$CANONICAL_LIFECYCLE_LOCK" || -L "$CANONICAL_LIFECYCLE_LOCK" ]] \
    || assert_at "$LINENO"
  remove_untrusted_canonical "$CANONICAL_LIFECYCLE_LOCK"
done

for canonical_kind in empty-dir symlink non-directory malformed; do
  make_untrusted_canonical "$canonical_kind" "$CANONICAL_CHECKOUT_LOCK"
  CANONICAL_OWNER_STATE=0
  __dx_session_management_review_owner_state "$REPO" \
    "$$" "$CANONICAL_CHECKOUT_TOKEN" || CANONICAL_OWNER_STATE=$?
  assert_eq "2" "$CANONICAL_OWNER_STATE" \
    "checkout ${canonical_kind} canonical state"
  CANONICAL_CHECKOUT_MARKED_RELEASED=0
  assert_rejected "checkout ${canonical_kind} canonical release" \
    __dx_session_management_checkout_release journal parent "$REPO"
  assert_eq "0" "$CANONICAL_CHECKOUT_MARKED_RELEASED" \
    "checkout ${canonical_kind} journal held"
  [[ -e "$CANONICAL_CHECKOUT_LOCK" || -L "$CANONICAL_CHECKOUT_LOCK" ]] \
    || assert_at "$LINENO"
  remove_untrusted_canonical "$CANONICAL_CHECKOUT_LOCK"
done

unset -f __dx_session_management_journal \
  dx_lifecycle_control_lock_release_checked dx_review_lock_release_checked
eval "$(declare -f __test_canonical_journal_original | \
  sed '1s/^__test_canonical_journal_original /__dx_session_management_journal /')"
eval "$(declare -f __test_canonical_lifecycle_release_original | \
  sed '1s/^__test_canonical_lifecycle_release_original /dx_lifecycle_control_lock_release_checked /')"
eval "$(declare -f __test_canonical_checkout_release_original | \
  sed '1s/^__test_canonical_checkout_release_original /dx_review_lock_release_checked /')"
unset -f __test_canonical_journal_original \
  __test_canonical_lifecycle_release_original \
  __test_canonical_checkout_release_original \
  make_untrusted_canonical remove_untrusted_canonical

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

# A payload-removal failure after metadata disappears resumes from the durable
# journal instead of trying to rediscover the session from the catalog.
PARTIAL_REMOVE_SID="$(cd "$REPO" && dx_scoped_session_id branch-partial-remove)"
make_terminal_session "$PARTIAL_REMOVE_SID" "$REPO"
eval "$(declare -f __dx_session_management_artifacts | \
  sed '1s/^__dx_session_management_artifacts /__test_artifacts_original /')"
PARTIAL_REMOVE_FAILED=0
__dx_session_management_artifacts() {
  if [[ "$1" == "remove-payload" && "$2" == "$PARTIAL_REMOVE_SID" \
    && "$PARTIAL_REMOVE_FAILED" -eq 0 ]]; then
    command rm -f "$(dx_meta_file "$2")"
    PARTIAL_REMOVE_FAILED=1
    return 1
  fi
  __test_artifacts_original "$@"
}
assert_rejected "partial payload removal" \
  __dx_session_management_cleanup_exact "$REPO" "$PARTIAL_REMOVE_SID"
unset -f __dx_session_management_artifacts
eval "$(declare -f __test_artifacts_original | \
  sed '1s/^__test_artifacts_original /__dx_session_management_artifacts /')"
unset -f __test_artifacts_original
assert_eq "1" "$PARTIAL_REMOVE_FAILED" "partial removal hook"
assert_no_file "$(dx_meta_file "$PARTIAL_REMOVE_SID")"
assert_file "$DX_LOOP_DIR/${PARTIAL_REMOVE_SID}.cleanup-journal"
__dx_session_management_cleanup_exact "$REPO" "$PARTIAL_REMOVE_SID"
assert_no_file "$DX_LOOP_DIR/${PARTIAL_REMOVE_SID}.cleanup-journal"
assert_no_file "$(dx_session_runtime_file "$PARTIAL_REMOVE_SID")"

# Each child purge is journaled independently. If child N fails, retry skips
# the already-purged children and finishes the remaining children and parent.
MULTI_PURGE_PARENT="$(cd "$REPO" && dx_scoped_session_id branch-multi-purge)"
make_terminal_session "$MULTI_PURGE_PARENT" "$REPO"
make_review_child "$MULTI_PURGE_PARENT" pass \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 1
MULTI_PURGE_CHILD_ONE="$REVIEW_CHILD_SID"
make_review_child "$MULTI_PURGE_PARENT" pass \
  cccccccccccccccccccccccccccccccc 1
MULTI_PURGE_CHILD_TWO="$REVIEW_CHILD_SID"
eval "$(declare -f __dx_session_runtime_owner_purge | \
  sed '1s/^__dx_session_runtime_owner_purge /__test_multi_purge_original /')"
MULTI_PURGE_COUNT=0
__dx_session_runtime_owner_purge() {
  MULTI_PURGE_COUNT=$((MULTI_PURGE_COUNT + 1))
  if [[ "$MULTI_PURGE_COUNT" -eq 2 ]]; then
    dx_session_runtime_owner_finish "$1" failed >/dev/null 2>&1 || true
    return 1
  fi
  __test_multi_purge_original "$@"
}
assert_rejected "N-of-M child purge" \
  __dx_session_management_cleanup_exact "$REPO" "$MULTI_PURGE_PARENT"
unset -f __dx_session_runtime_owner_purge
eval "$(declare -f __test_multi_purge_original | \
  sed '1s/^__test_multi_purge_original /__dx_session_runtime_owner_purge /')"
unset -f __test_multi_purge_original
assert_eq "2" "$MULTI_PURGE_COUNT" "N-of-M purge hook"
assert_no_file "$(dx_session_runtime_file "$MULTI_PURGE_CHILD_ONE")"
assert_file "$(dx_session_runtime_file "$MULTI_PURGE_CHILD_TWO")"
assert_file "$DX_LOOP_DIR/${MULTI_PURGE_PARENT}.cleanup-journal"
__dx_session_management_cleanup_exact "$REPO" "$MULTI_PURGE_PARENT"
assert_no_file "$(dx_session_runtime_file "$MULTI_PURGE_CHILD_TWO")"
assert_no_file "$(dx_session_runtime_file "$MULTI_PURGE_PARENT")"
assert_no_file "$DX_LOOP_DIR/${MULTI_PURGE_PARENT}.cleanup-journal"

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

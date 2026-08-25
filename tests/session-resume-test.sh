#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-resume.XXXXXX")"

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
source "$ROOT/lib/common.sh"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email dex@example.test
git -C "$REPO" config user.name "Dex Test"
printf 'base\n' > "$REPO/file.txt"
printf '.dex/\n' > "$REPO/.gitignore"
git -C "$REPO" add file.txt .gitignore
git -C "$REPO" commit -q -m "test: initialize repo"
git -C "$REPO" branch -m main

SESSION_ID="$(cd "$REPO" && dx_scoped_session_id selected-resume)"
dx_meta_write "$SESSION_ID" \
  "ticket_number=701" \
  "wt_name=selected-resume" \
  "wt_dir=$REPO" \
  "workspace_mode=in-place" \
  "raw_input=resume this exact session"
dx_lifecycle_atomic_write "$(dx_state_file "$SESSION_ID")" 0
dx_record_session_branch "$SESSION_ID" "$REPO"
RUNTIME_TOKEN="$(dx_session_runtime_start "$SESSION_ID" claude "$REPO" "$$")"
dx_session_runtime_finish "$SESSION_ID" "$RUNTIME_TOKEN" failed "$$"
printf 'some-other-session:/not/the/selected/workspace:worktree\n' \
  > "$DX_STATE_DIR/last-session"

RESUME_OUTPUT="$TMP_DIR/resume.out"
export DX_TEST_PROVIDER_MARKER="$TMP_DIR/provider-entered"
if (
  cd "$REPO"
  zsh -fc '
    source "$1"
    __dx_run_phases_inline() {
      printf "provider-entered\tsession=%s\tphase=%s\tworkspace=%s\n" \
        "$9" "$4" "$2" > "$DX_TEST_PROVIDER_MARKER"
      __dx_runtime_set_terminal failed
      return 42
    }
    __dx_sessions_resume_selected "$2"
  ' dex-selected-resume "$ROOT/dx.sh" "session:$SESSION_ID"
) > "$RESUME_OUTPUT" 2>&1; then
  RESUME_RESULT=0
else
  RESUME_RESULT=$?
fi
if [[ "$RESUME_RESULT" -ne 42 ]]; then
  cat "$RESUME_OUTPUT" >&2
fi
assert_eq "42" "$RESUME_RESULT" "selected resume provider result"
assert_file "$TMP_DIR/provider-entered"
assert_contains "session=$SESSION_ID" "$TMP_DIR/provider-entered"
assert_contains $'phase=0' "$TMP_DIR/provider-entered"
assert_contains "workspace=$REPO" "$TMP_DIR/provider-entered"
assert_not_contains "some-other-session" "$TMP_DIR/provider-entered"
assert_not_contains "Resume accepted" "$RESUME_OUTPUT"
assert_not_contains "resumed successfully" "$RESUME_OUTPUT"

HELP_OUTPUT="$TMP_DIR/help.out"
bash "$ROOT/bin/sessions.sh" --help > "$HELP_OUTPUT"
assert_contains "resume <selector>" "$HELP_OUTPUT"

create_dead_session() { # <sid> <workspace> <name> <mode> <phase> <ticket> [provider]
  local session_id="$1" workspace_dir="$2" workspace_name="$3"
  local workspace_mode="$4" phase="$5" ticket="$6" provider="${7:-claude}"
  local runtime_token
  dx_meta_write "$session_id" \
    "ticket_number=$ticket" \
    "wt_name=$workspace_name" \
    "wt_dir=$workspace_dir" \
    "workspace_mode=$workspace_mode"
  dx_lifecycle_atomic_write "$(dx_state_file "$session_id")" "$phase"
  dx_record_session_branch "$session_id" "$workspace_dir"
  runtime_token=$(dx_session_runtime_start \
    "$session_id" "$provider" "$workspace_dir" "$$")
  dx_session_runtime_finish "$session_id" "$runtime_token" failed "$$"
}

run_selected_resume() { # <selector> <marker> <output> [mode]
  local selector_value="$1" marker_file="$2" output_file="$3"
  local callback_mode="${4:-return}" command_result=0
  (
    cd "$REPO"
    DX_TEST_PROVIDER_MARKER="$marker_file" \
    DX_TEST_CALLBACK_MODE="$callback_mode" \
    DX_TEST_PROVIDER_RELEASE="${marker_file}.release" \
    zsh -fc '
      source "$1"
      __dx_run_phases_inline() {
        printf "provider-entered\tsession=%s\tphase=%s\tworkspace=%s\n" \
          "$9" "$4" "$2" > "$DX_TEST_PROVIDER_MARKER"
        if [[ "$DX_TEST_CALLBACK_MODE" == "wait" ]]; then
          while [[ ! -e "$DX_TEST_PROVIDER_RELEASE" ]]; do
            sleep 0.05
          done
        fi
        __dx_runtime_set_terminal failed
        return 42
      }
      __dx_sessions_resume_selected "$2"
    ' dex-selected-resume "$ROOT/dx.sh" "$selector_value"
  ) > "$output_file" 2>&1 || command_result=$?
  RESUME_RESULT="$command_result"
}

# Existing Phase 3 and Phase 6 sessions relaunch at their exact recorded phase.
for RESUME_PHASE in 3 6; do
  PHASE_SID="$(cd "$REPO" && dx_scoped_session_id "resume-phase-${RESUME_PHASE}")"
  create_dead_session "$PHASE_SID" "$REPO" "resume-phase-${RESUME_PHASE}" \
    in-place "$RESUME_PHASE" "70${RESUME_PHASE}"
  run_selected_resume "session:$PHASE_SID" \
    "$TMP_DIR/phase-${RESUME_PHASE}.provider" "$TMP_DIR/phase-${RESUME_PHASE}.out"
  assert_eq "42" "$RESUME_RESULT" "Phase $RESUME_PHASE provider result"
  assert_contains "session=$PHASE_SID" "$TMP_DIR/phase-${RESUME_PHASE}.provider"
  assert_contains "phase=$RESUME_PHASE" "$TMP_DIR/phase-${RESUME_PHASE}.provider"
done

# A registered worktree is resumed in place without consulting last-session.
WORKTREE="$REPO/.dex/worktrees/resume-worktree"
mkdir -p "$REPO/.dex/worktrees"
git -C "$REPO" worktree add -q -b worktree-resume-worktree "$WORKTREE"
WORKTREE_SID="$(cd "$REPO" && dx_scoped_session_id resume-worktree)"
create_dead_session "$WORKTREE_SID" "$WORKTREE" resume-worktree worktree 6 706
run_selected_resume "session:$WORKTREE_SID" "$TMP_DIR/worktree.provider" \
  "$TMP_DIR/worktree.out"
assert_eq "42" "$RESUME_RESULT" "worktree provider result"
assert_contains "workspace=$WORKTREE" "$TMP_DIR/worktree.provider"

# Phase 3 cannot relaunch across a live child fence. Exact quiescence retires
# that fence and permits the next attempt.
BUSY_SID="$(cd "$REPO" && dx_scoped_session_id resume-busy)"
create_dead_session "$BUSY_SID" "$REPO" resume-busy in-place 3 713
BUSY_TOKEN="$(dx_phase_busy_begin "$BUSY_SID" 3 review-child)"
run_selected_resume "session:$BUSY_SID" "$TMP_DIR/busy.provider" "$TMP_DIR/busy.out"
assert_eq "1" "$RESUME_RESULT" "unquiesced child fence result"
assert_no_file "$TMP_DIR/busy.provider"
assert_file "$(dx_phase_busy_file "$BUSY_SID" 3)"
dx_phase_busy_acknowledge "$BUSY_SID" 3 "$BUSY_TOKEN"
run_selected_resume "session:$BUSY_SID" "$TMP_DIR/quiesced.provider" \
  "$TMP_DIR/quiesced.out"
assert_eq "42" "$RESUME_RESULT" "quiesced child fence provider result"
assert_no_file "$(dx_phase_busy_file "$BUSY_SID" 3)"

# A trusted failed terminal transaction rolls back to inert Phase 6. A valid
# terminal proof is already complete and is refused without a provider launch.
ROLLBACK_SID="$(cd "$REPO" && dx_scoped_session_id resume-terminal-rollback)"
create_dead_session "$ROLLBACK_SID" "$REPO" resume-terminal-rollback in-place 7 717
dx_write_pause_state "$ROLLBACK_SID" terminal-proof-missing lifecycle-control
dx_lifecycle_atomic_write "$(dx_paused_file "$ROLLBACK_SID")" paused
run_selected_resume "session:$ROLLBACK_SID" "$TMP_DIR/rollback.provider" \
  "$TMP_DIR/rollback.out"
assert_eq "42" "$RESUME_RESULT" "terminal rollback provider result"
assert_contains $'phase=6' "$TMP_DIR/rollback.provider"
assert_eq "6" "$(dx_lifecycle_phase_state "$ROLLBACK_SID")" \
  "terminal rollback phase"
assert_no_file "$(dx_paused_file "$ROLLBACK_SID")"
assert_no_file "$(dx_pause_state_file "$ROLLBACK_SID")"
assert_no_file "$(dx_completion_expectation_file "$ROLLBACK_SID")"

COMPLETE_SID="$(cd "$REPO" && dx_scoped_session_id resume-terminal-complete)"
create_dead_session "$COMPLETE_SID" "$REPO" resume-terminal-complete in-place 7 727
dx_lifecycle_control_lock_acquire "$COMPLETE_SID"
dx_lifecycle_terminal_commit_publish_unlocked "$COMPLETE_SID" \
  0123456789abcdef0123456789abcdef
dx_lifecycle_control_lock_release "$COMPLETE_SID"
run_selected_resume "session:$COMPLETE_SID" "$TMP_DIR/complete.provider" \
  "$TMP_DIR/complete.out"
assert_eq "1" "$RESUME_RESULT" "valid Phase 7 refusal"
assert_no_file "$TMP_DIR/complete.provider"
assert_eq "7" "$(dx_lifecycle_phase_state "$COMPLETE_SID")" \
  "valid Phase 7 remains complete"

# A non-resumable revocation brake survives a selected resume attempt.
BRAKE_SID="$(cd "$REPO" && dx_scoped_session_id resume-revocation-brake)"
create_dead_session "$BRAKE_SID" "$REPO" resume-revocation-brake in-place 3 733
dx_write_pause_state "$BRAKE_SID" \
  assessment-selection-revocation-failed lifecycle-control
dx_lifecycle_atomic_write "$(dx_paused_file "$BRAKE_SID")" paused
run_selected_resume "session:$BRAKE_SID" "$TMP_DIR/brake.provider" \
  "$TMP_DIR/brake.out"
assert_eq "1" "$RESUME_RESULT" "non-resumable brake result"
assert_no_file "$TMP_DIR/brake.provider"
assert_file "$(dx_paused_file "$BRAKE_SID")"

# The Bash dispatcher delegates directly to the private zsh entrypoint instead
# of recursively invoking `dx sessions`.
FAKE_BIN="$TMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$@" > "$DX_TEST_ZSH_ARGUMENTS"' \
  'exit 37' > "$FAKE_BIN/zsh"
chmod 700 "$FAKE_BIN/zsh"
if (
  cd "$REPO"
  PATH="$FAKE_BIN:$PATH" \
  DX_TEST_ZSH_ARGUMENTS="$TMP_DIR/zsh-arguments" \
    bash "$ROOT/bin/sessions.sh" resume "session:$SESSION_ID"
) > "$TMP_DIR/delegation.out" 2>&1; then
  DELEGATION_RESULT=0
else
  DELEGATION_RESULT=$?
fi
assert_eq "37" "$DELEGATION_RESULT" "resume delegation result"
assert_contains '__dx_sessions_resume_selected "$2"' "$TMP_DIR/zsh-arguments"
assert_contains "session:$SESSION_ID" "$TMP_DIR/zsh-arguments"

assert_resume_refused() { # <selector> <label> [environment]
  local selector_value="$1" label="$2" marker_file output_file
  marker_file="$TMP_DIR/${label}.provider"
  output_file="$TMP_DIR/${label}.out"
  run_selected_resume "$selector_value" "$marker_file" "$output_file"
  assert_eq "1" "$RESUME_RESULT" "$label result"
  assert_no_file "$marker_file"
}

# Selector failures and unsupported records stop before runtime recovery.
assert_resume_refused "session:does-not-exist" missing-selector

AMBIGUOUS_ONE="$(cd "$REPO" && dx_scoped_session_id resume-ambiguous-one)"
AMBIGUOUS_TWO="$(cd "$REPO" && dx_scoped_session_id resume-ambiguous-two)"
create_dead_session "$AMBIGUOUS_ONE" "$REPO" ambiguous-one in-place 2 799
create_dead_session "$AMBIGUOUS_TWO" "$REPO" ambiguous-two in-place 2 799
assert_resume_refused "ticket:799" ambiguous-selector

CHILD_SID="${SESSION_ID}-pass-0123456789abcdef0123456789abcdef"
dx_meta_write "$CHILD_SID" \
  "session_role=review-child" \
  "parent_session_id=$SESSION_ID" \
  "child_kind=pass"
dx_lifecycle_atomic_write "$(dx_state_file "$CHILD_SID")" 3
assert_resume_refused "session:$CHILD_SID" child-selector

OTHER_REPO="$TMP_DIR/other-repo"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q
git -C "$OTHER_REPO" config user.email dex@example.test
git -C "$OTHER_REPO" config user.name "Dex Test"
printf 'other\n' > "$OTHER_REPO/file.txt"
git -C "$OTHER_REPO" add file.txt
git -C "$OTHER_REPO" commit -q -m "test: initialize other repo"
git -C "$OTHER_REPO" branch -m main
CROSS_REPO_SID="$(cd "$OTHER_REPO" && dx_scoped_session_id resume-cross-repo)"
create_dead_session "$CROSS_REPO_SID" "$OTHER_REPO" cross-repo in-place 2 798
assert_resume_refused "session:$CROSS_REPO_SID" cross-repo-selector

LEGACY_SID="$(cd "$REPO" && dx_scoped_session_id resume-legacy)"
dx_meta_write "$LEGACY_SID" \
  "ticket_number=790" "wt_name=legacy" "wt_dir=$REPO" \
  "workspace_mode=in-place"
dx_lifecycle_atomic_write "$(dx_state_file "$LEGACY_SID")" 2
dx_record_session_branch "$LEGACY_SID" "$REPO"
assert_resume_refused "session:$LEGACY_SID" legacy-runtime

STANDALONE_SID="$(cd "$REPO" && dx_scoped_session_id resume-standalone)"
STANDALONE_TOKEN="$(dx_session_runtime_start \
  "$STANDALONE_SID" claude "$REPO" "$$")"
dx_session_runtime_finish "$STANDALONE_SID" "$STANDALONE_TOKEN" failed "$$"
assert_resume_refused "session:$STANDALONE_SID" standalone-runtime

UNSAFE_SID="$(cd "$REPO" && dx_scoped_session_id resume-unsafe)"
create_dead_session "$UNSAFE_SID" "$REPO" unsafe in-place 2 791
chmod 644 "$(dx_state_file "$UNSAFE_SID")"
assert_resume_refused "session:$UNSAFE_SID" unsafe-phase

CORRUPT_SID="$(cd "$REPO" && dx_scoped_session_id resume-corrupt)"
dx_meta_write "$CORRUPT_SID" \
  "ticket_number=792" "wt_name=corrupt" "wt_dir=$REPO" \
  "workspace_mode=in-place"
dx_lifecycle_atomic_write "$(dx_state_file "$CORRUPT_SID")" 2
dx_record_session_branch "$CORRUPT_SID" "$REPO"
printf '{"broken":true}\n' > "$(dx_session_runtime_file "$CORRUPT_SID")"
chmod 600 "$(dx_session_runtime_file "$CORRUPT_SID")"
assert_resume_refused "session:$CORRUPT_SID" corrupt-runtime

INCONSISTENT_SID="$(cd "$REPO" && dx_scoped_session_id resume-inconsistent)"
dx_meta_write "$INCONSISTENT_SID" \
  "ticket_number=793" "wt_name=inconsistent" "wt_dir=$REPO" \
  "workspace_mode=in-place"
dx_lifecycle_atomic_write "$(dx_state_file "$INCONSISTENT_SID")" 2
dx_record_session_branch "$INCONSISTENT_SID" "$REPO"
INCONSISTENT_TOKEN="$(dx_session_runtime_start \
  "$INCONSISTENT_SID" claude "$WORKTREE" "$$")"
dx_session_runtime_finish "$INCONSISTENT_SID" \
  "$INCONSISTENT_TOKEN" failed "$$"
assert_resume_refused "session:$INCONSISTENT_SID" inconsistent-runtime

UNREGISTERED="$REPO/.dex/worktrees/unregistered"
mkdir -p "$UNREGISTERED"
UNREGISTERED_SID="$(cd "$REPO" && dx_scoped_session_id resume-unregistered)"
create_dead_session "$UNREGISTERED_SID" "$UNREGISTERED" unregistered worktree 2 794
assert_resume_refused "session:$UNREGISTERED_SID" unregistered-worktree

# Live and completed runtime records are not recovery candidates.
LIVE_SID="$(cd "$REPO" && dx_scoped_session_id resume-live)"
dx_meta_write "$LIVE_SID" \
  "ticket_number=795" "wt_name=live" "wt_dir=$REPO" \
  "workspace_mode=in-place"
dx_lifecycle_atomic_write "$(dx_state_file "$LIVE_SID")" 2
dx_record_session_branch "$LIVE_SID" "$REPO"
LIVE_TOKEN="$(dx_session_runtime_start "$LIVE_SID" claude "$REPO" "$$")"
assert_resume_refused "session:$LIVE_SID" live-runtime
dx_session_runtime_finish "$LIVE_SID" "$LIVE_TOKEN" stopped "$$"

RUNTIME_COMPLETE_SID="$(cd "$REPO" && dx_scoped_session_id resume-runtime-complete)"
dx_meta_write "$RUNTIME_COMPLETE_SID" \
  "ticket_number=796" "wt_name=runtime-complete" "wt_dir=$REPO" \
  "workspace_mode=in-place"
dx_lifecycle_atomic_write "$(dx_state_file "$RUNTIME_COMPLETE_SID")" 6
dx_record_session_branch "$RUNTIME_COMPLETE_SID" "$REPO"
RUNTIME_COMPLETE_TOKEN="$(dx_session_runtime_start \
  "$RUNTIME_COMPLETE_SID" claude "$REPO" "$$")"
dx_session_runtime_finish "$RUNTIME_COMPLETE_SID" \
  "$RUNTIME_COMPLETE_TOKEN" completed "$$"
assert_resume_refused "session:$RUNTIME_COMPLETE_SID" completed-runtime

# In-place recovery restores a clean checkout to its trusted saved branch. A
# dirty checkout is accepted only when it is already on that exact branch.
WRONG_BRANCH_SID="$(cd "$REPO" && dx_scoped_session_id resume-wrong-branch)"
create_dead_session "$WRONG_BRANCH_SID" "$REPO" wrong-branch in-place 2 797
git -C "$REPO" branch wrong-resume-branch
git -C "$REPO" switch -q wrong-resume-branch
run_selected_resume "session:$WRONG_BRANCH_SID" "$TMP_DIR/restored-branch.provider" \
  "$TMP_DIR/restored-branch.out"
assert_eq "42" "$RESUME_RESULT" "clean wrong-branch provider result"
assert_eq "main" "$(git -C "$REPO" branch --show-current)" \
  "clean wrong-branch restore"

DIRTY_SID="$(cd "$REPO" && dx_scoped_session_id resume-dirty)"
create_dead_session "$DIRTY_SID" "$REPO" dirty in-place 2 788
printf 'dirty\n' > "$REPO/uncommitted.txt"
run_selected_resume "session:$DIRTY_SID" "$TMP_DIR/dirty-correct.provider" \
  "$TMP_DIR/dirty-correct.out"
assert_eq "42" "$RESUME_RESULT" "dirty exact-branch provider result"
rm -f "$REPO/uncommitted.txt"

DIRTY_WRONG_SID="$(cd "$REPO" && dx_scoped_session_id resume-dirty-wrong)"
create_dead_session "$DIRTY_WRONG_SID" "$REPO" dirty-wrong in-place 2 789
git -C "$REPO" switch -q wrong-resume-branch
printf 'dirty wrong branch\n' > "$REPO/uncommitted.txt"
assert_resume_refused "session:$DIRTY_WRONG_SID" dirty-wrong-in-place
rm -f "$REPO/uncommitted.txt"
git -C "$REPO" switch -q main

# Two concurrent resumes cannot both cross the provider boundary. The first
# recovered owner remains live while its provider callback is held.
COMPETING_SID="$(cd "$REPO" && dx_scoped_session_id resume-competing)"
create_dead_session "$COMPETING_SID" "$REPO" competing in-place 6 787
COMPETING_MARKER="$TMP_DIR/competing-first.provider"
COMPETING_RELEASE="${COMPETING_MARKER}.release"
COMPETING_OUTPUT="$TMP_DIR/competing-first.out"
(
  cd "$REPO"
  DX_TEST_PROVIDER_MARKER="$COMPETING_MARKER" \
  DX_TEST_CALLBACK_MODE=wait \
  DX_TEST_PROVIDER_RELEASE="$COMPETING_RELEASE" \
  zsh -fc '
    source "$1"
    __dx_run_phases_inline() {
      printf "provider-entered\tsession=%s\tphase=%s\tworkspace=%s\n" \
        "$9" "$4" "$2" > "$DX_TEST_PROVIDER_MARKER"
      while [[ ! -e "$DX_TEST_PROVIDER_RELEASE" ]]; do sleep 0.05; done
      __dx_runtime_set_terminal failed
      return 42
    }
    __dx_sessions_resume_selected "$2"
  ' dex-selected-resume "$ROOT/dx.sh" "session:$COMPETING_SID"
) > "$COMPETING_OUTPUT" 2>&1 &
COMPETING_PID=$!
wait_for_process_files "$COMPETING_PID" "$COMPETING_MARKER"
assert_not_contains "Resume accepted" "$COMPETING_OUTPUT"
assert_not_contains "resumed successfully" "$COMPETING_OUTPUT"
run_selected_resume "session:$COMPETING_SID" "$TMP_DIR/competing-second.provider" \
  "$TMP_DIR/competing-second.out"
assert_eq "1" "$RESUME_RESULT" "competing recovery result"
assert_no_file "$TMP_DIR/competing-second.provider"
touch "$COMPETING_RELEASE"
if wait "$COMPETING_PID"; then
  COMPETING_RESULT=0
else
  COMPETING_RESULT=$?
fi
assert_eq "42" "$COMPETING_RESULT" "first recovered provider result"

# Signals settle the private runtime supervisor once and preserve their
# conventional shell exit code instead of being rewritten as a finish error.
SIGNAL_SID="$(cd "$REPO" && dx_scoped_session_id resume-signal)"
SIGNAL_READY="$TMP_DIR/signal-ready"
SIGNAL_OUTPUT="$TMP_DIR/signal.out"
(
  cd "$REPO"
  export DX_TEST_SIGNAL_READY="$SIGNAL_READY"
  exec zsh -fc '
    source "$1"
    export DX_AGENT_OVERRIDE=claude
    __dx_refresh_provider
    __dx_signal_callback() {
      printf "ready\n" > "$DX_TEST_SIGNAL_READY"
      sleep 30
    }
    __dx_run_with_runtime "$2" "$3" __dx_signal_callback
  ' dex-selected-signal "$ROOT/dx.sh" "$SIGNAL_SID" "$REPO"
) > "$SIGNAL_OUTPUT" 2>&1 &
SIGNAL_PID=$!
if ! wait_for_process_files "$SIGNAL_PID" "$SIGNAL_READY"; then
  cat "$SIGNAL_OUTPUT" >&2
  exit 1
fi
kill -TERM "$SIGNAL_PID"
if wait "$SIGNAL_PID"; then
  SIGNAL_RESULT=0
else
  SIGNAL_RESULT=$?
fi
assert_eq "143" "$SIGNAL_RESULT" "runtime signal result"
assert_eq "stopped" "$(dx_session_runtime_field "$SIGNAL_SID" status)" \
  "runtime signal terminal state"
assert_not_contains "could not close the runtime lease" "$SIGNAL_OUTPUT"

printf 'session resume tests passed\n'

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-legacy-resume.XXXXXX")"

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
REPO="$(cd "$REPO" && pwd -P)"
git -C "$REPO" init -q
git -C "$REPO" config user.email dex@example.test
git -C "$REPO" config user.name "Dex Test"
printf 'base\n' > "$REPO/file.txt"
printf '.dex/\n' > "$REPO/.gitignore"
git -C "$REPO" add file.txt .gitignore
git -C "$REPO" commit -q -m "test: initialize repo"
git -C "$REPO" branch -m main

run_legacy_resume() { # <marker> <output> [dx arguments...]
  local marker_file="$1" output_file="$2" command_result=0
  shift 2
  (
    cd "$REPO"
    DX_TEST_RESUME_MARKER="$marker_file" zsh -fc '
      source "$1"
      shift
      __dx_refresh_provider() { return 0; }
      __dx_record_session_branch() { return 0; }
      __dx_restore_in_place_session_branch() { return 0; }
      __dx_run_with_runtime() { return 91; }
      __dx_sessions_resume_selected() {
        {
          print -r -- "argc=$#"
          print -r -- "selector=$1"
          print -r -- "requested_agent=${2-<unset>}"
          print -r -- "resume_mode=${3-<unset>}"
          print -r -- "workspace_name=${4-<unset>}"
          print -r -- "workspace=${5-<unset>}"
          print -r -- "workspace_mode=${6-<unset>}"
          print -r -- "model=${DX_MODEL_OVERRIDE-}"
        } > "$DX_TEST_RESUME_MARKER"
        return 37
      }
      dx "$@"
    ' dex-legacy-resume "$ROOT/dx.sh" "$@"
  ) > "$output_file" 2>&1 || command_result=$?
  LEGACY_RESULT="$command_result"
}

# Legacy resume still selects the last-session mapping, but delegates the
# actual recovery to the exact session selector. Compatible CLI overrides are
# carried across that boundary.
LEGACY_NAME="task-legacy-resume"
LEGACY_SID="$(cd "$REPO" && dx_scoped_session_id "inplace-$LEGACY_NAME")"
printf '%s:%s:in-place\n' "$LEGACY_NAME" "$REPO" \
  > "$DX_STATE_DIR/last-session"
run_legacy_resume "$TMP_DIR/legacy.marker" "$TMP_DIR/legacy.out" \
  --agent claude --model legacy-model --resume
assert_eq "37" "$LEGACY_RESULT" "legacy resume delegation result"
assert_contains "argc=6" "$TMP_DIR/legacy.marker"
assert_contains "selector=session:$LEGACY_SID" "$TMP_DIR/legacy.marker"
assert_contains "requested_agent=claude" "$TMP_DIR/legacy.marker"
assert_contains "resume_mode=legacy-last-session" "$TMP_DIR/legacy.marker"
assert_contains "workspace_name=$LEGACY_NAME" "$TMP_DIR/legacy.marker"
assert_contains "workspace=$REPO" "$TMP_DIR/legacy.marker"
assert_contains "workspace_mode=in-place" "$TMP_DIR/legacy.marker"
assert_contains "model=legacy-model" "$TMP_DIR/legacy.marker"

# The two-field legacy mapping keeps its historical worktree interpretation.
OLDER_NAME="task-older-resume"
OLDER_SID="$(cd "$REPO" && dx_session_id "$OLDER_NAME")"
printf '%s:%s\n' "$OLDER_NAME" "$REPO" > "$DX_STATE_DIR/last-session"
run_legacy_resume "$TMP_DIR/older.marker" "$TMP_DIR/older.out" --resume
assert_eq "37" "$LEGACY_RESULT" "two-field resume delegation result"
assert_contains "argc=6" "$TMP_DIR/older.marker"
assert_contains "selector=session:$OLDER_SID" "$TMP_DIR/older.marker"
assert_contains "requested_agent=" "$TMP_DIR/older.marker"
assert_contains "resume_mode=legacy-last-session" "$TMP_DIR/older.marker"
assert_contains "workspace_mode=worktree" "$TMP_DIR/older.marker"

# A missing pointer remains a safe refusal and never reaches recovery.
rm -f "$DX_STATE_DIR/last-session" "$TMP_DIR/missing.marker"
run_legacy_resume "$TMP_DIR/missing.marker" "$TMP_DIR/missing.out" --resume
assert_eq "1" "$LEGACY_RESULT" "missing last-session result"
assert_no_file "$TMP_DIR/missing.marker"
assert_contains "No previous session found." "$TMP_DIR/missing.out"

SELECTED_SID="legacy-provider-session"
printf '{"session_id":"%s","is_child":false,"metadata_health":"valid","runtime_health":"dead","runtime_status":"failed","unsafe_artifacts":[],"consistency_issues":[],"lifecycle_state":"failed","phase":2,"workspace":"%s","workspace_name":"task-provider","workspace_mode":"in-place","provider":"claude","runtime_pid":4242,"ticket":"provider resume"}\n' \
  "$SELECTED_SID" "$REPO" > "$TMP_DIR/selected.json"
printf '{"version":1,"session_id":"%s","provider":"claude","workspace":"%s","pid":4242,"status":"failed"}\n' \
  "$SELECTED_SID" "$REPO" > "$TMP_DIR/runtime.json"

run_selected_helper() { # <requested-agent> <marker-prefix> <output>
  local requested_agent="$1" marker_prefix="$2" output_file="$3"
  local command_result=0
  (
    cd "$REPO"
    DX_MODEL_OVERRIDE=legacy-model \
    DX_TEST_SELECTED_FILE="$TMP_DIR/selected.json" \
    DX_TEST_RUNTIME_FILE="$TMP_DIR/runtime.json" \
    DX_TEST_MARKER_PREFIX="$marker_prefix" \
    zsh -fc '
      source "$1"
      dx_repo_root() { print -r -- "$PWD"; }
      dx_session_catalog_select() { command cat "$DX_TEST_SELECTED_FILE"; }
      dx_session_runtime_read() { command cat "$DX_TEST_RUNTIME_FILE"; }
      __dx_selected_resume_workspace_valid() {
        print -r -- called > "${DX_TEST_MARKER_PREFIX}.workspace"
        return 0
      }
      __dx_refresh_provider() {
        print -r -- "agent=$DX_AGENT_OVERRIDE model=${DX_MODEL_OVERRIDE-}" \
          > "${DX_TEST_MARKER_PREFIX}.provider"
        DX_PROVIDER_ENGINE=claude
        return 0
      }
      __dx_resolved_provider_agent() { print -r -- claude; }
      __dx_run_with_recovered_runtime() {
        print -r -- "session=$1 agent=$DX_AGENT_OVERRIDE model=${DX_MODEL_OVERRIDE-}" \
          > "${DX_TEST_MARKER_PREFIX}.recovery"
        return 38
      }
      __dx_sessions_resume_selected "$2" "$3"
    ' dex-selected-helper "$ROOT/dx.sh" "session:$SELECTED_SID" \
      "$requested_agent"
  ) > "$output_file" 2>&1 || command_result=$?
  SELECTED_RESULT="$command_result"
}

# A matching agent and the requested model reach the shared provider setup.
run_selected_helper claude "$TMP_DIR/matching" "$TMP_DIR/matching.out"
assert_eq "38" "$SELECTED_RESULT" "matching agent result"
assert_contains "agent=claude model=legacy-model" "$TMP_DIR/matching.provider"
assert_contains "session=$SELECTED_SID agent=claude model=legacy-model" \
  "$TMP_DIR/matching.recovery"

# A conflicting agent is refused before workspace mutation or runtime claim.
run_selected_helper codex "$TMP_DIR/conflicting" "$TMP_DIR/conflicting.out"
assert_eq "1" "$SELECTED_RESULT" "conflicting agent result"
assert_no_file "$TMP_DIR/conflicting.workspace"
assert_no_file "$TMP_DIR/conflicting.provider"
assert_no_file "$TMP_DIR/conflicting.recovery"
assert_contains "was recorded for claude" "$TMP_DIR/conflicting.out"

# The public legacy command changes the sourced caller shell only after the
# exact dead runtime is claimed and immediately before the provider callback.
RESUME_WORKTREE_NAME="task-caller-directory"
RESUME_WORKTREE="$REPO/.dex/worktrees/$RESUME_WORKTREE_NAME"
mkdir -p "$REPO/.dex/worktrees"
git -C "$REPO" worktree add -q -b "worktree-$RESUME_WORKTREE_NAME" \
  "$RESUME_WORKTREE"
RESUME_WORKTREE="$(cd "$RESUME_WORKTREE" && pwd -P)"
RESUME_WORKTREE_SID="$(cd "$REPO" && dx_session_id "$RESUME_WORKTREE_NAME")"
printf '{"session_id":"%s","is_child":false,"metadata_health":"valid","runtime_health":"dead","runtime_status":"failed","unsafe_artifacts":[],"consistency_issues":[],"lifecycle_state":"failed","phase":2,"workspace":"%s","workspace_name":"%s","workspace_mode":"worktree","provider":"claude","runtime_pid":4243,"ticket":"caller directory"}\n' \
  "$RESUME_WORKTREE_SID" "$RESUME_WORKTREE" "$RESUME_WORKTREE_NAME" \
  > "$TMP_DIR/worktree-selected.json"
printf '{"version":1,"session_id":"%s","provider":"claude","workspace":"%s","pid":4243,"status":"failed"}\n' \
  "$RESUME_WORKTREE_SID" "$RESUME_WORKTREE" \
  > "$TMP_DIR/worktree-runtime.json"

run_public_fixture_resume() { # <pointer> <marker-prefix> <output> [recovery-mode]
  local pointer_value="$1" marker_prefix="$2" output_file="$3"
  local recovery_mode="${4:-success}" command_result=0
  printf '%s\n' "$pointer_value" > "$DX_STATE_DIR/last-session"
  (
    cd "$REPO"
    DX_TEST_SELECTED_FILE="$TMP_DIR/worktree-selected.json" \
    DX_TEST_RUNTIME_FILE="$TMP_DIR/worktree-runtime.json" \
    DX_TEST_MARKER_PREFIX="$marker_prefix" \
    DX_TEST_RECOVERY_MODE="$recovery_mode" \
    zsh -fc '
      source "$1"
      __dx_refresh_provider() {
        DX_PROVIDER_ENGINE=claude
        return 0
      }
      dx_session_catalog_select() { command cat "$DX_TEST_SELECTED_FILE"; }
      dx_session_runtime_read() { command cat "$DX_TEST_RUNTIME_FILE"; }
      __dx_selected_resume_workspace_valid() {
        print -r -- called > "${DX_TEST_MARKER_PREFIX}.workspace"
        return 0
      }
      __dx_selected_resume_runtime_matches() {
        [[ "$DX_TEST_RECOVERY_MODE" != "post-claim-refusal" ]] || return 1
      }
      __dx_selected_resume_catalog_matches() { return 0; }
      __dx_review_nonce() { print -r -- fixture-review-lock; }
      dx_review_lock_acquire() { return 0; }
      dx_review_lock_release_checked() { return 0; }
      dx_lifecycle_control_lock_acquire() { return 0; }
      dx_lifecycle_control_lock_release_checked() { return 0; }
      dx_lifecycle_relaunch_prepare_unlocked() { print -r -- "$2"; }
      dx_default_branch() { print -r -- main; }
      __dx_resolved_provider_agent() { print -r -- claude; }
      __dx_run_with_recovered_runtime() {
        local callback_name="$3"
        print -r -- called > "${DX_TEST_MARKER_PREFIX}.recovery"
        if [[ "$DX_TEST_RECOVERY_MODE" == "pre-claim-refusal" ]]; then
          return 1
        fi
        shift 3
        "$callback_name" "$@"
      }
      __dx_run_phases_inline() {
        print -r -- "pwd=$PWD session=$9" \
          > "${DX_TEST_MARKER_PREFIX}.provider"
        return 38
      }
      dx --resume
      command_result=$?
      print -r -- "$PWD" > "${DX_TEST_MARKER_PREFIX}.pwd"
      exit "$command_result"
    ' dex-public-legacy "$ROOT/dx.sh"
  ) > "$output_file" 2>&1 || command_result=$?
  PUBLIC_RESULT="$command_result"
}

run_public_fixture_resume \
  "$RESUME_WORKTREE_NAME:$RESUME_WORKTREE:worktree" \
  "$TMP_DIR/worktree-public" "$TMP_DIR/worktree-public.out"
assert_eq "38" "$PUBLIC_RESULT" "worktree caller directory result"
assert_contains "pwd=$RESUME_WORKTREE session=$RESUME_WORKTREE_SID" \
  "$TMP_DIR/worktree-public.provider"
assert_eq "$RESUME_WORKTREE" "$(<"$TMP_DIR/worktree-public.pwd")" \
  "successful worktree caller directory"
assert_not_contains "Resuming" "$TMP_DIR/worktree-public.out"

# A refused claim and a refusal after the claim both leave the sourced caller
# in its original checkout. Only the provider boundary changes directories.
run_public_fixture_resume \
  "$RESUME_WORKTREE_NAME:$RESUME_WORKTREE:worktree" \
  "$TMP_DIR/pre-claim-refusal" "$TMP_DIR/pre-claim-refusal.out" \
  pre-claim-refusal
assert_eq "1" "$PUBLIC_RESULT" "pre-claim refusal result"
assert_eq "$REPO" "$(<"$TMP_DIR/pre-claim-refusal.pwd")" \
  "pre-claim refusal caller directory"
assert_no_file "$TMP_DIR/pre-claim-refusal.provider"

run_public_fixture_resume \
  "$RESUME_WORKTREE_NAME:$RESUME_WORKTREE:worktree" \
  "$TMP_DIR/post-claim-refusal" "$TMP_DIR/post-claim-refusal.out" \
  post-claim-refusal
assert_eq "1" "$PUBLIC_RESULT" "post-claim refusal result"
assert_eq "$REPO" "$(<"$TMP_DIR/post-claim-refusal.pwd")" \
  "post-claim refusal caller directory"
assert_no_file "$TMP_DIR/post-claim-refusal.provider"

# The whole pointer tuple is authoritative input. A same-name workspace from
# another repo, any other existing path, a missing path, a mode mismatch, or a
# malformed record must stop before workspace validation or recovery.
OTHER_REPO="$TMP_DIR/other-repo"
mkdir -p "$OTHER_REPO" "$REPO/other-workspace"
git -C "$OTHER_REPO" init -q
for REJECTION_CASE in cross-repo mismatched-path missing-path mode-mismatch malformed; do
  case "$REJECTION_CASE" in
    cross-repo)
      REJECTION_POINTER="$RESUME_WORKTREE_NAME:$OTHER_REPO:worktree"
      ;;
    mismatched-path)
      REJECTION_POINTER="$RESUME_WORKTREE_NAME:$REPO/other-workspace:worktree"
      ;;
    missing-path)
      REJECTION_POINTER="$RESUME_WORKTREE_NAME:$TMP_DIR/missing-workspace:worktree"
      ;;
    mode-mismatch)
      REJECTION_POINTER="$RESUME_WORKTREE_NAME:$RESUME_WORKTREE:in-place"
      ;;
    malformed)
      REJECTION_POINTER="$RESUME_WORKTREE_NAME"
      ;;
  esac
  run_public_fixture_resume "$REJECTION_POINTER" \
    "$TMP_DIR/$REJECTION_CASE" "$TMP_DIR/$REJECTION_CASE.out"
  assert_eq "1" "$PUBLIC_RESULT" "$REJECTION_CASE result"
  assert_no_file "$TMP_DIR/$REJECTION_CASE.workspace"
  assert_no_file "$TMP_DIR/$REJECTION_CASE.recovery"
  assert_contains "last-session mapping" "$TMP_DIR/$REJECTION_CASE.out"
done

create_completed_session() { # <sid> <workspace> <name> <mode>
  local session_id="$1" workspace="$2" workspace_name="$3" workspace_mode="$4"
  local runtime_token
  dx_meta_write "$session_id" \
    "ticket_number=799" \
    "wt_name=$workspace_name" \
    "wt_dir=$workspace" \
    "workspace_mode=$workspace_mode"
  dx_lifecycle_atomic_write "$(dx_state_file "$session_id")" 7
  dx_record_session_branch "$session_id" "$workspace"
  runtime_token=$(dx_session_runtime_start \
    "$session_id" claude "$workspace" "$$")
  dx_session_runtime_finish "$session_id" "$runtime_token" completed "$$"
  dx_lifecycle_control_lock_acquire "$session_id"
  dx_lifecycle_terminal_commit_publish_unlocked "$session_id" \
    0123456789abcdef0123456789abcdef
  dx_lifecycle_control_lock_release "$session_id"
}

run_completed_legacy_resume() { # <name> <workspace> <mode> <output> <marker>
  local workspace_name="$1" workspace="$2" workspace_mode="$3"
  local output_file="$4" marker_file="$5" command_result=0
  printf '%s:%s:%s\n' "$workspace_name" "$workspace" "$workspace_mode" \
    > "$DX_STATE_DIR/last-session"
  (
    cd "$REPO"
    DX_TEST_PROVIDER_MARKER="$marker_file" zsh -fc '
      source "$1"
      __dx_refresh_provider() { return 0; }
      __dx_run_with_recovered_runtime() {
        print -r -- called > "$DX_TEST_PROVIDER_MARKER"
        return 99
      }
      dx --resume
    ' dex-completed-legacy "$ROOT/dx.sh"
  ) > "$output_file" 2>&1 || command_result=$?
  COMPLETED_RESULT="$command_result"
}

# A valid terminal commit remains a successful no-op for both legacy modes.
COMPLETED_INPLACE_NAME="task-completed-in-place"
COMPLETED_INPLACE_SID="$(
  cd "$REPO" && dx_scoped_session_id "inplace-$COMPLETED_INPLACE_NAME"
)"
create_completed_session "$COMPLETED_INPLACE_SID" "$REPO" \
  "$COMPLETED_INPLACE_NAME" in-place
run_completed_legacy_resume "$COMPLETED_INPLACE_NAME" "$REPO" in-place \
  "$TMP_DIR/completed-inplace.out" "$TMP_DIR/completed-inplace.provider"
assert_eq "0" "$COMPLETED_RESULT" "completed in-place result"
assert_no_file "$TMP_DIR/completed-inplace.provider"
assert_contains "Ticket lifecycle already complete for $COMPLETED_INPLACE_NAME." \
  "$TMP_DIR/completed-inplace.out"
assert_contains "This lifecycle ran in the current checkout; local branch cleanup is handled at completion when safe." \
  "$TMP_DIR/completed-inplace.out"

COMPLETED_WORKTREE_NAME="task-completed-worktree"
COMPLETED_WORKTREE="$REPO/.dex/worktrees/$COMPLETED_WORKTREE_NAME"
git -C "$REPO" worktree add -q -b "worktree-$COMPLETED_WORKTREE_NAME" \
  "$COMPLETED_WORKTREE"
COMPLETED_WORKTREE="$(cd "$COMPLETED_WORKTREE" && pwd -P)"
COMPLETED_WORKTREE_SID="$(cd "$REPO" && dx_session_id "$COMPLETED_WORKTREE_NAME")"
create_completed_session "$COMPLETED_WORKTREE_SID" "$COMPLETED_WORKTREE" \
  "$COMPLETED_WORKTREE_NAME" worktree
run_completed_legacy_resume "$COMPLETED_WORKTREE_NAME" "$COMPLETED_WORKTREE" \
  worktree "$TMP_DIR/completed-worktree.out" \
  "$TMP_DIR/completed-worktree.provider"
assert_eq "0" "$COMPLETED_RESULT" "completed worktree result"
assert_no_file "$TMP_DIR/completed-worktree.provider"
assert_contains "Ticket lifecycle already complete for $COMPLETED_WORKTREE_NAME." \
  "$TMP_DIR/completed-worktree.out"
assert_contains "Local cleanup should already be complete. If files remain, run dxrm $COMPLETED_WORKTREE_NAME." \
  "$TMP_DIR/completed-worktree.out"

printf 'legacy resume tests passed\n'

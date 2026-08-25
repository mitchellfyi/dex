#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-worktree-integrity-test.XXXXXX")"

cleanup() {
  git -C "$TMP_DIR/repo" worktree remove --force "$TMP_DIR/repo/.dex/worktrees/ticket-61" >/dev/null 2>&1 || true
  git -C "$TMP_DIR/repo" worktree remove --force "$TMP_DIR/repo/.dex/worktrees/ticket-62" >/dev/null 2>&1 || true
  git -C "$TMP_DIR/repo" worktree remove --force "$TMP_DIR/repo/.dex/worktrees/ticket-63" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export TEST_REPO="$TMP_DIR/repo"
export TEST_TMP_DIR="$TMP_DIR"
mkdir -p "$DX_STATE_DIR" "$DX_LOOP_DIR" "$TEST_REPO/.dex/worktrees/task-plain"

git -C "$TEST_REPO" init -q
git -C "$TEST_REPO" config user.email dex@example.test
git -C "$TEST_REPO" config user.name "Dex Test"
printf '# repo\n' > "$TEST_REPO/README.md"
git -C "$TEST_REPO" add README.md
git -C "$TEST_REPO" commit -q -m init

if zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; __dx_setup_worktree plain' > "$TMP_DIR/plain.out" 2>&1; then
  printf 'plain directory unexpectedly accepted as lifecycle isolation\n' >&2
  exit 1
fi
grep -q "is not a registered Git worktree" "$TMP_DIR/plain.out"

git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-61" -b worktree-ticket-61 HEAD
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-62" -b worktree-ticket-62 HEAD
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-63" -b worktree-ticket-63 HEAD

# Listing must fail closed on unsafe phase inodes and on Phase 7 without the
# terminal transaction proof. Neither state may be presented as complete.
zsh -fc '
source "$DEX_DIR/dx.sh"
set -e
cd "$TEST_REPO"
unsafe_session=$(dx_session_id ticket-61)
unsafe_phase=$(dx_state_file "$unsafe_session")
dx_lifecycle_atomic_write "${unsafe_phase}.target" 3
ln -s "${unsafe_phase}.target" "$unsafe_phase"
unproved_session=$(dx_session_id ticket-62)
dx_lifecycle_atomic_write "$(dx_state_file "$unproved_session")" 7
proved_session=$(dx_session_id ticket-63)
dx_lifecycle_atomic_write "$(dx_state_file "$proved_session")" 7
dx_lifecycle_control_lock_acquire "$proved_session"
dx_lifecycle_terminal_commit_publish_unlocked "$proved_session" \
  0123456789abcdef0123456789abcdef
dx_lifecycle_control_lock_release "$proved_session"
dx_lifecycle_terminal_commit_valid "$proved_session"
'

zsh -fc '
source "$DEX_DIR/dx.sh"
cd "$TEST_REPO"
dxls
if dxcd ticket; then
  printf "%s\n" "ambiguous dxcd lookup unexpectedly passed" >&2
  exit 1
fi
dxclean
' > "$TMP_DIR/list-clean.out" 2>&1
if grep -Eq '^(wt_name|wt_status|branch|session_id|phase_file|phase_num|name|active_in_place_phase|has_worktree|ticket_name)=' "$TMP_DIR/list-clean.out"; then
  printf 'zsh leaked internal local variables\n' >&2
  cat "$TMP_DIR/list-clean.out" >&2
  exit 1
fi
grep -q "Multiple worktrees match 'ticket'" "$TMP_DIR/list-clean.out"
grep -q "ticket-61.*\[blocked: unsafe phase state\]" "$TMP_DIR/list-clean.out"
grep -q "ticket-62.*\[blocked: terminal commit not verified\]" "$TMP_DIR/list-clean.out"
grep -q "ticket-63.*\[complete\]" "$TMP_DIR/list-clean.out"
[[ -d "$TEST_REPO/.dex/worktrees/ticket-61" ]] || assert_at $LINENO
[[ -d "$TEST_REPO/.dex/worktrees/ticket-62" ]] || assert_at $LINENO
[[ -d "$TEST_REPO/.dex/worktrees/ticket-63" ]] || assert_at $LINENO
if grep -q "Deleting orphan branch:" "$TMP_DIR/list-clean.out"; then
  printf 'dxclean treated a linked-worktree branch as orphaned\n' >&2
  exit 1
fi

zsh -fc '
source "$DEX_DIR/dx.sh"
set -e
cd "$TEST_REPO"
session_id="$(dx_session_id ticket-61)"
touch "$(dx_state_file "$session_id")"
printf "%s\n" "ticket-61:$TEST_REPO/.dex/worktrees/ticket-61:worktree" > "$DX_STATE_DIR/last-session"
dx_wt_remove() { return 73; }

if dxrm 61 > "$TEST_TMP_DIR/remove.out" 2>&1; then
  printf "%s\n" "dxrm reported success after worktree removal failed" >&2
  exit 1
fi
grep -q "branch and session state were left intact" "$TEST_TMP_DIR/remove.out"
[[ -d "$TEST_REPO/.dex/worktrees/ticket-61" ]] || assert_at $LINENO
git show-ref --verify --quiet refs/heads/worktree-ticket-61
[[ -f "$(dx_state_file "$session_id")" ]] || assert_at $LINENO
[[ -f "$DX_STATE_DIR/last-session" ]] || assert_at $LINENO

if dxrm --all > "$TEST_TMP_DIR/remove-all.out" 2>&1; then
  printf "%s\n" "dxrm --all reported success after worktree removal failed" >&2
  exit 1
fi
grep -q "Some worktrees could not be removed" "$TEST_TMP_DIR/remove-all.out"
[[ -d "$TEST_REPO/.dex/worktrees/ticket-61" ]] || assert_at $LINENO
[[ -f "$(dx_state_file "$session_id")" ]] || assert_at $LINENO
[[ -f "$DX_STATE_DIR/last-session" ]] || assert_at $LINENO
'

# dxclean's orphan-branch pass must not delete branches that were never
# pushed or that still hold unpushed commits (in-place lifecycles leave
# worktree-* branches with no worktree directory).
git -C "$TEST_REPO" branch worktree-task-unpushed HEAD
zsh -fc '
source "$DEX_DIR/dx.sh"
cd "$TEST_REPO"
dxclean
' > "$TMP_DIR/clean-unpushed.out" 2>&1
grep -q "Skipping branch worktree-task-unpushed (not pushed to remote)" "$TMP_DIR/clean-unpushed.out"
git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/worktree-task-unpushed

git -C "$TMP_DIR" init -q --bare origin.git
git -C "$TEST_REPO" remote add origin "$TMP_DIR/origin.git"
git -C "$TEST_REPO" push -q origin worktree-task-unpushed
git -C "$TEST_REPO" commit -q --allow-empty -m ahead
git -C "$TEST_REPO" branch -f worktree-task-unpushed HEAD
git -C "$TEST_REPO" branch worktree-task-pushed HEAD~0
git -C "$TEST_REPO" push -q origin worktree-task-pushed
zsh -fc '
source "$DEX_DIR/dx.sh"
cd "$TEST_REPO"
dxclean
' > "$TMP_DIR/clean-pushed.out" 2>&1
grep -q "Skipping branch worktree-task-unpushed (has unpushed commits)" "$TMP_DIR/clean-pushed.out"
git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/worktree-task-unpushed
grep -q "Deleting orphan branch: worktree-task-pushed" "$TMP_DIR/clean-pushed.out"
if git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/worktree-task-pushed; then
  printf 'dxclean left a fully pushed orphan branch behind\n' >&2
  exit 1
fi

printf 'worktree integrity tests passed\n'

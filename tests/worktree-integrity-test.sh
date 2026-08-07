#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-worktree-integrity-test.XXXXXX")"

cleanup() {
  git -C "$TMP_DIR/repo" worktree remove --force "$TMP_DIR/repo/.dex/worktrees/ticket-61" >/dev/null 2>&1 || true
  git -C "$TMP_DIR/repo" worktree remove --force "$TMP_DIR/repo/.dex/worktrees/ticket-62" >/dev/null 2>&1 || true
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
if grep -q "Deleting orphan branch:" "$TMP_DIR/list-clean.out"; then
  printf 'dxclean treated a linked-worktree branch as orphaned\n' >&2
  exit 1
fi

zsh -fc '
source "$DEX_DIR/dx.sh"
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
[[ -d "$TEST_REPO/.dex/worktrees/ticket-61" ]]
git show-ref --verify --quiet refs/heads/worktree-ticket-61
[[ -f "$(dx_state_file "$session_id")" ]]
[[ -f "$DX_STATE_DIR/last-session" ]]

if dxrm --all > "$TEST_TMP_DIR/remove-all.out" 2>&1; then
  printf "%s\n" "dxrm --all reported success after worktree removal failed" >&2
  exit 1
fi
grep -q "Some worktrees could not be removed" "$TEST_TMP_DIR/remove-all.out"
[[ -d "$TEST_REPO/.dex/worktrees/ticket-61" ]]
[[ -f "$(dx_state_file "$session_id")" ]]
[[ -f "$DX_STATE_DIR/last-session" ]]
'

printf 'worktree integrity tests passed\n'

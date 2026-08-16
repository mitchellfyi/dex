#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-worktree-ticket-resolution.XXXXXX")"

cleanup() {
  git -C "$TMP_DIR/repo" worktree remove --force "$TMP_DIR/repo/.dex/worktrees/task-linked" >/dev/null 2>&1 || true
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
export TEST_REVERT_CAPTURE="$TMP_DIR/revert-capture"
mkdir -p "$HOME" "$TEST_REPO/.dex/worktrees"

git -C "$TEST_REPO" init -q
git -C "$TEST_REPO" config user.email dex@example.test
git -C "$TEST_REPO" config user.name "Dex Test"
printf 'base\n' > "$TEST_REPO/file.txt"
git -C "$TEST_REPO" add file.txt
git -C "$TEST_REPO" commit -q -m "test: initialize repo"
git -C "$TEST_REPO" branch -m main
git -C "$TEST_REPO" worktree add -q \
  "$TEST_REPO/.dex/worktrees/task-linked" \
  -b worktree-task-linked HEAD

zsh -fc '
  source "$DEX_DIR/dx.sh"
  set -e
  cd "$TEST_REPO"

  linked_session=$(dx_session_id task-linked)
  dx_meta_write "$linked_session" \
    "ticket_number=123" \
    "wt_name=task-linked" \
    "wt_dir=$TEST_REPO/.dex/worktrees/task-linked" \
    "workspace_mode=worktree"

  dx_latest_checkpoint_phase() { print -r -- 2; }
  dx_revert_to_checkpoint() {
    print -r -- "$1::$2" > "$TEST_REVERT_CAPTURE"
  }

  expected="$TEST_REPO/.dex/worktrees/task-linked"
  dxcd ENG-123
  [[ "${PWD:A}" == "${expected:A}" ]]
  cd "$TEST_REPO"

  __dx_cli revert 123 > /dev/null
  # dx_repo_root resolves symlinked path components (macOS /var -> /private/var),
  # so compare against the resolved expected path.
  [[ "$(cat "$TEST_REVERT_CAPTURE")" == "2::${expected:A}" ]]

  dxrm 123 > /dev/null
  [[ ! -d "$expected" ]]
  ! git show-ref --verify --quiet refs/heads/worktree-task-linked
  [[ ! -e "$(dx_meta_file "$linked_session")" ]]

  git branch worktree-task-inplace main
  inplace_session=$(__dx_session_id_for_workspace in-place task-inplace)
  dx_meta_write "$inplace_session" \
    "ticket_number=456" \
    "wt_name=task-inplace" \
    "wt_dir=$TEST_REPO" \
    "workspace_mode=in-place"
  printf "2\n" > "$(dx_state_file "$inplace_session")"
  printf "worktree-task-inplace\n" > "$(dx_branch_file "$inplace_session")"

  rmdir "$TEST_REPO/.dex/worktrees"
  dxcd 456 > /dev/null
  [[ "${PWD:A}" == "${TEST_REPO:A}" ]]

  if __dx_cli revert 456 > "$TEST_REPO/revert-inplace.out" 2>&1; then
    print -u2 -- "dx revert accepted an in-place lifecycle"
    exit 1
  fi
  grep -Fq "uses an in-place lifecycle" "$TEST_REPO/revert-inplace.out"

  if dxrm 456 > "$TEST_REPO/remove-inplace.out" 2>&1; then
    print -u2 -- "dxrm removed an active in-place lifecycle"
    exit 1
  fi
  grep -Fq "Refusing to remove active in-place lifecycle branch" "$TEST_REPO/remove-inplace.out"
  git show-ref --verify --quiet refs/heads/worktree-task-inplace

  mkdir -p "$TEST_REPO/.dex/worktrees"
  git worktree add -q "$TEST_REPO/.dex/worktrees/task-first" -b worktree-task-first main
  git worktree add -q "$TEST_REPO/.dex/worktrees/task-second" -b worktree-task-second main
  first_session=$(dx_session_id task-first)
  second_session=$(dx_session_id task-second)
  dx_meta_write "$first_session" \
    "ticket_number=999" \
    "wt_name=task-first" \
    "wt_dir=$TEST_REPO/.dex/worktrees/task-first" \
    "workspace_mode=worktree"
  dx_meta_write "$second_session" \
    "ticket_number=999" \
    "wt_name=task-second" \
    "wt_dir=$TEST_REPO/.dex/worktrees/task-second" \
    "workspace_mode=worktree"

  for command_name in navigate revert remove setup setup-in-place; do
    case "$command_name" in
      navigate) command=(dxcd 999) ;;
      revert) command=(__dx_cli revert 999) ;;
      remove) command=(dxrm 999) ;;
      setup) command=(__dx_setup_worktree 999) ;;
      setup-in-place) command=(__dx_setup_in_place 999) ;;
    esac
    if "${command[@]}" > "$TEST_REPO/ambiguous-$command_name.out" 2>&1; then
      print -u2 -- "$command_name accepted an ambiguous ticket workspace"
      exit 1
    fi
    grep -Fq "Multiple Dex workspaces are linked to ticket 999" \
      "$TEST_REPO/ambiguous-$command_name.out"
  done
  [[ -d "$TEST_REPO/.dex/worktrees/task-first" ]]
  [[ -d "$TEST_REPO/.dex/worktrees/task-second" ]]
  [[ ! -e "$TEST_REPO/.dex/worktrees/ticket-999" ]]
'

printf 'worktree ticket resolution tests passed\n'

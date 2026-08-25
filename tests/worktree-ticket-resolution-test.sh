#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
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
  [[ "${PWD:A}" == "${expected:A}" ]] || assert_at $LINENO
  cd "$TEST_REPO"

  __dx_cli revert 123 > /dev/null
  # dx_repo_root resolves symlinked path components (macOS /var -> /private/var),
  # so compare against the resolved expected path.
  [[ "$(cat "$TEST_REVERT_CAPTURE")" == "2::${expected:A}" ]] || assert_at $LINENO

  dxrm 123 > /dev/null
  [[ ! -d "$expected" ]] || assert_at $LINENO
  ! git show-ref --verify --quiet refs/heads/worktree-task-linked
  [[ ! -e "$(dx_meta_file "$linked_session")" ]] || assert_at $LINENO

  quoted_branch="feature/in-place-dollar\$-semi;colon"
  quoted_session=$(__dx_session_id_for_workspace in-place task-quoted)
  git branch "$quoted_branch" main
  git switch -q "$quoted_branch"
  dx_record_session_branch "$quoted_session" "$TEST_REPO"
  dx_lifecycle_atomic_write "$(dx_state_file "$quoted_session")" 2
  git switch -q main
  printf "dirty\n" >> "$TEST_REPO/file.txt"
  if __dx_restore_in_place_session_branch \
      "$quoted_session" task-quoted "$TEST_REPO" "dx --resume" \
      > "$TEST_REPO/dirty-resume.out" 2>&1; then
    print -u2 -- "in-place resume switched branches with a dirty checkout"
    exit 1
  fi
  [[ "$(git symbolic-ref --quiet --short HEAD)" == main ]] || assert_at $LINENO
  grep -Fq "current checkout is on main" "$TEST_REPO/dirty-resume.out"
  rm -f "$TEST_REPO/dirty-resume.out"
  git checkout -- file.txt
  __dx_restore_in_place_session_branch \
    "$quoted_session" task-quoted "$TEST_REPO" "dx --resume"
  [[ "$(git symbolic-ref --quiet --short HEAD)" == "$quoted_branch" ]] \
    || assert_at $LINENO
  git switch -q main
  dx_cleanup_session "$quoted_session"
  git branch -D "$quoted_branch" >/dev/null

  git branch worktree-task-inplace main
  inplace_session=$(__dx_session_id_for_workspace in-place task-inplace)
  dx_meta_write "$inplace_session" \
    "ticket_number=456" \
    "wt_name=task-inplace" \
    "wt_dir=$TEST_REPO" \
    "workspace_mode=in-place"
  dx_lifecycle_atomic_write "$(dx_state_file "$inplace_session")" 2
  git switch -q worktree-task-inplace
  dx_record_session_branch "$inplace_session" "$TEST_REPO"
  git switch -q main

  rmdir "$TEST_REPO/.dex/worktrees"
  dxcd 456 > /dev/null
  [[ "${PWD:A}" == "${TEST_REPO:A}" ]] || assert_at $LINENO

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

  assert_unsafe_branch_is_protected() {
    local unsafe_kind="$1" unsafe_branch="worktree-task-unsafe-${1}"
    local unsafe_name="${unsafe_branch#worktree-}" unsafe_session branch_file
    local unsafe_target helper_result=0
    unsafe_session=$(__dx_session_id_for_workspace in-place "$unsafe_name")
    branch_file=$(dx_branch_file "$unsafe_session")
    unsafe_target="${branch_file}.target"
    git branch "$unsafe_branch" main
    dx_lifecycle_atomic_write "$(dx_state_file "$unsafe_session")" 2
    case "$unsafe_kind" in
      missing)
        ;;
      symlink)
        dx_lifecycle_atomic_write "$unsafe_target" "$unsafe_branch"
        ln -s "$unsafe_target" "$branch_file"
        ;;
      hardlink)
        dx_lifecycle_atomic_write "$unsafe_target" "$unsafe_branch"
        ln "$unsafe_target" "$branch_file"
        ;;
      wrong-mode)
        printf "%s\n" "$unsafe_branch" > "$branch_file"
        chmod 644 "$branch_file"
        ;;
      malformed)
        dx_lifecycle_atomic_write "$branch_file" bad..branch
        ;;
    esac

    __dx_active_in_place_phase_for_branch "$unsafe_branch" >/dev/null 2>&1 \
      || helper_result=$?
    [[ "$helper_result" -eq 2 ]] || {
      print -u2 -- "unsafe branch helper result for ${unsafe_kind}: ${helper_result}"
      exit 1
    }
    if dxrm "$unsafe_name" \
        > "$TEST_REPO/remove-unsafe-${unsafe_kind}.out" 2>&1; then
      print -u2 -- "dxrm removed an in-place branch with ${unsafe_kind} state"
      exit 1
    fi
    grep -Fq "branch state is missing, unsafe, or malformed" \
      "$TEST_REPO/remove-unsafe-${unsafe_kind}.out"
    git show-ref --verify --quiet "refs/heads/${unsafe_branch}"
    chmod 600 "$branch_file" "$unsafe_target" 2>/dev/null || true
    rm -f "$branch_file" "$unsafe_target" \
      "$TEST_REPO/remove-unsafe-${unsafe_kind}.out"
    rm -f "$(dx_state_file "$unsafe_session")"
    git branch -D "$unsafe_branch" >/dev/null
  }

  for unsafe_kind in missing symlink hardlink wrong-mode malformed; do
    assert_unsafe_branch_is_protected "$unsafe_kind"
  done

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
  [[ -d "$TEST_REPO/.dex/worktrees/task-first" ]] || assert_at $LINENO
  [[ -d "$TEST_REPO/.dex/worktrees/task-second" ]] || assert_at $LINENO
  [[ ! -e "$TEST_REPO/.dex/worktrees/ticket-999" ]] || assert_at $LINENO
'

printf 'worktree ticket resolution tests passed\n'

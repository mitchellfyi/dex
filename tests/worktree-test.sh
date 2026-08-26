#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-worktree-test.XXXXXX")"

cleanup() {
  git -C "$TMP_DIR/repo" worktree remove --force "$TMP_DIR/repo/.dex/worktrees/ticket-61" >/dev/null 2>&1 || true
  git -C "$TMP_DIR/repo" worktree remove --force "$TMP_DIR/repo/.dex/worktrees/task-completed-cleanup" >/dev/null 2>&1 || true
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
mkdir -p "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_ARTIFACT_DIR" "$DX_TOOL_DIR" "$DX_RUN_ROOT"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

repo="$TMP_DIR/repo"
wt="$repo/.dex/worktrees/ticket-61"
mkdir -p "$repo/.claude" "$repo/.dex/worktrees"
printf '{"permissions":{}}\n' > "$repo/.claude/settings.local.json"

git -C "$TMP_DIR" init -q repo
git -C "$repo" config user.email dex@example.test
git -C "$repo" config user.name "Dex Test"
printf '# repo\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m init
git -C "$repo" worktree add -q "$wt" -b worktree-ticket-61 HEAD

dx_wt_is_registered "$repo" "$wt"
plain_dir="$repo/.dex/worktrees/task-plain"
mkdir -p "$plain_dir"
if dx_wt_is_registered "$repo" "$plain_dir"; then
  printf 'plain directory unexpectedly accepted as a registered worktree\n' >&2
  exit 1
fi

dx_link_claude_to_worktree "$repo" "$wt"
[[ -L "$wt/.claude" ]] || assert_at $LINENO

status="$(git -C "$wt" status --short)"
if grep -Fq ".claude" <<< "${status}"; then
  printf '.claude should be excluded from worktree status\n' >&2
  printf '%s\n' "$status" >&2
  exit 1
fi

exclude_file="$(git -C "$wt" rev-parse --git-path info/exclude)"
grep -Fxq ".claude" "$exclude_file"
grep -Fxq ".claude/*" "$exclude_file"

# Idempotency: re-linking should not duplicate exclude entries.
dx_link_claude_to_worktree "$repo" "$wt"
[[ "$(grep -Fxc ".claude" "$exclude_file")" -eq 1 ]] || assert_at $LINENO
[[ "$(grep -Fxc ".claude/*" "$exclude_file")" -eq 1 ]] || assert_at $LINENO

# dx_wt_remove falls back to `rm -rf`, so it must refuse anything that is not a
# directory inside .dex/worktrees — a repository root reaching it is unrecoverable.
stray="$repo/.dex/worktrees/stray"
mkdir -p "$stray/inner"
dx_wt_remove "$stray"
[[ ! -e "$stray" ]] || assert_at $LINENO

mkdir -p "$repo/keepme"
for refused in "$repo" "$repo/.dex/worktrees" "$repo/keepme" "$repo/.dex/worktrees/../.." ""; do
  if dx_wt_remove "$refused" >/dev/null 2>&1; then
    printf 'dx_wt_remove accepted a target outside .dex/worktrees: %s\n' "$refused" >&2
    exit 1
  fi
done
[[ -d "$repo/.git" && -d "$repo/keepme" && -d "$repo/.dex/worktrees" ]] || assert_at $LINENO

old_dir="$TMP_DIR/old-state"
mkdir -p "$old_dir"
touch "$old_dir/one.state" "$old_dir/two.complete"
touch -t 202001010000 "$old_dir/one.state" "$old_dir/two.complete"
export TEST_OLD_DIR="$old_dir"
old_count=$(zsh -fc 'source "$DEX_DIR/lib/common.sh"; dx_cleanup_stale_files "$TEST_OLD_DIR" "state complete" 7')
[[ "$old_count" -eq 2 ]] || assert_at $LINENO

# A human-authorized Phase 7 follows the same cleanup path as an ordinary
# completion. Exercise the direct Codex preflight path without launching a
# provider, including the required cwd handoff before deleting the worktree.
cleanup_name="task-completed-cleanup"
cleanup_wt="$repo/.dex/worktrees/$cleanup_name"
cleanup_branch="worktree-$cleanup_name"
default_branch=$(git -C "$repo" symbolic-ref --short HEAD)
git -C "$repo" worktree add -q "$cleanup_wt" -b "$cleanup_branch" HEAD
export TEST_CLEANUP_NAME="$cleanup_name"
export TEST_CLEANUP_WT="$cleanup_wt"
export TEST_CLEANUP_REPO="$repo"
export TEST_CLEANUP_BRANCH="$cleanup_branch"
export TEST_DEFAULT_BRANCH="$default_branch"
zsh -fc '
  source "$DEX_DIR/dx.sh"
  set -e
  cd "$TEST_CLEANUP_WT"
  session_id=$(dx_session_id "$TEST_CLEANUP_NAME")
  state_file=$(dx_state_file "$session_id")
  times_file=$(dx_times_file "$session_id")
  dx_lifecycle_atomic_write "$state_file" 6
  dx_write_lifecycle_control "$session_id" complete 7 terminal "" 6 ""
  export DX_PROVIDER_APPLIED=1
  export DX_PROVIDER_ENGINE=codex-plugin
  export DX_PROVIDER_AGENT=codex
  __dx_run_phases_inline "$TEST_CLEANUP_NAME" "$TEST_CLEANUP_WT" \
    "$TEST_DEFAULT_BRANCH" 6 "$state_file" "$times_file" \
    "dx --resume" worktree "$session_id" "completed cleanup fixture"
  expected_root=$(cd "$TEST_CLEANUP_REPO" && pwd -P)
  if [[ "$PWD" != "$expected_root" ]]; then
    print -u2 -- "cleanup did not return to the repository root: $PWD"
    exit 1
  fi
  if [[ -d "$TEST_CLEANUP_WT" ]]; then
    print -u2 -- "completed worktree still exists"
    exit 1
  fi
  if git show-ref --verify --quiet "refs/heads/$TEST_CLEANUP_BRANCH"; then
    print -u2 -- "completed lifecycle branch still exists"
    exit 1
  fi
'

printf 'worktree-test passed\n'

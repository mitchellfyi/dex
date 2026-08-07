#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-checkpoint-test.XXXXXX")"

cleanup() {
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
wt_a="$repo/.dex/worktrees/task-a"
wt_b="$repo/.dex/worktrees/task-b"
mkdir -p "$repo/.dex/worktrees"

git -C "$TMP_DIR" init -q repo
git -C "$repo" config user.email dex@example.test
git -C "$repo" config user.name "Dex Test"
printf 'base\n' > "$repo/shared.txt"
git -C "$repo" add shared.txt
git -C "$repo" commit -q -m init
base_sha=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" worktree add -q "$wt_a" -b worktree-task-a HEAD
git -C "$repo" worktree add -q "$wt_b" -b worktree-task-b HEAD

printf 'a\n' > "$wt_a/a.txt"
git -C "$wt_a" add a.txt
git -C "$wt_a" commit -q -m "task a"
sha_a=$(git -C "$wt_a" rev-parse HEAD)

printf 'b\n' > "$wt_b/b.txt"
git -C "$wt_b" add b.txt
git -C "$wt_b" commit -q -m "task b"
sha_b=$(git -C "$wt_b" rev-parse HEAD)

dx_checkpoint_tag 2 "$wt_a"
dx_checkpoint_tag 2 "$wt_b"
ref_a=$(dx_checkpoint_ref 2 "$wt_a")
ref_b=$(dx_checkpoint_ref 2 "$wt_b")

[[ "$ref_a" != "$ref_b" ]]
[[ "$(git -C "$repo" rev-parse "$ref_a")" == "$sha_a" ]]
[[ "$(git -C "$repo" rev-parse "$ref_b")" == "$sha_b" ]]
[[ -z "$(git -C "$repo" tag -l 'dx-checkpoint/phase-*')" ]]

git -C "$wt_a" branch -m feat/task-a
[[ "$(dx_checkpoint_ref 2 "$wt_a")" == "$ref_a" ]]

printf 'after checkpoint\n' >> "$wt_a/a.txt"
git -C "$wt_a" add a.txt
git -C "$wt_a" commit -q -m "advance task a"
printf 'remove me\n' > "$wt_a/untracked.txt"
dx_revert_to_checkpoint 2 "$wt_a" >/dev/null
[[ "$(git -C "$wt_a" rev-parse HEAD)" == "$sha_a" ]]
[[ ! -e "$wt_a/untracked.txt" ]]
[[ "$(git -C "$wt_b" rev-parse HEAD)" == "$sha_b" ]]

dx_checkpoint_tag 4 "$wt_a"
dx_checkpoint_tag 6 "$wt_b"
[[ "$(dx_latest_checkpoint_phase "$wt_a")" == "4" ]]
[[ "$(dx_latest_checkpoint_phase "$wt_b")" == "6" ]]

dx_cleanup_checkpoints "$wt_a"
if git -C "$repo" show-ref --verify --quiet "$ref_a"; then
  printf 'task-a checkpoint survived task-a cleanup\n' >&2
  exit 1
fi
[[ "$(git -C "$repo" rev-parse "$ref_b")" == "$sha_b" ]]
[[ "$(dx_latest_checkpoint_phase "$wt_b")" == "6" ]]

# In-place lifecycle branches in the main checkout also get separate refs.
main_branch=$(git -C "$repo" symbolic-ref --short HEAD)
dx_checkpoint_tag 2 "$repo"
main_ref=$(dx_checkpoint_ref 2 "$repo")
git -C "$repo" switch -q -c in-place-task
dx_checkpoint_tag 2 "$repo"
in_place_ref=$(dx_checkpoint_ref 2 "$repo")
[[ "$main_ref" != "$in_place_ref" ]]
git -C "$repo" switch -q "$main_branch"
dx_cleanup_checkpoints "$repo"
if git -C "$repo" show-ref --verify --quiet "$main_ref"; then
  printf 'main-branch checkpoint survived its cleanup\n' >&2
  exit 1
fi
git -C "$repo" show-ref --verify --quiet "$in_place_ref"
git -C "$repo" switch -q in-place-task
dx_cleanup_checkpoints "$repo"
git -C "$repo" switch -q "$main_branch"

# A repository-wide checkpoint from an older Dex version is ambiguous while
# two linked lifecycle worktrees are registered.
git -C "$repo" tag -f dx-checkpoint/phase-3 "$sha_b" >/dev/null
before_revert=$(git -C "$wt_a" rev-parse HEAD)
if dx_revert_to_checkpoint 3 "$wt_a" >/dev/null; then
  printf 'ambiguous legacy checkpoint was accepted\n' >&2
  exit 1
fi
[[ "$(git -C "$wt_a" rev-parse HEAD)" == "$before_revert" ]]

dx_cleanup_checkpoints "$wt_b"
git -C "$repo" worktree remove --force "$wt_b"
git -C "$repo" tag -f dx-checkpoint/phase-3 "$base_sha" >/dev/null
if dx_revert_to_checkpoint 3 "$wt_a" >/dev/null; then
  printf 'legacy checkpoint shared with the main checkout was accepted\n' >&2
  exit 1
fi

git -C "$repo" tag -f dx-checkpoint/phase-3 "$sha_a" >/dev/null
printf 'legacy advance\n' >> "$wt_a/a.txt"
git -C "$wt_a" add a.txt
git -C "$wt_a" commit -q -m "advance legacy task"

[[ "$(dx_latest_checkpoint_phase "$wt_a")" == "3" ]]
dx_revert_to_checkpoint 3 "$wt_a" >/dev/null
[[ "$(git -C "$wt_a" rev-parse HEAD)" == "$sha_a" ]]
dx_cleanup_checkpoints "$wt_a"
if git -C "$repo" show-ref --verify --quiet refs/tags/dx-checkpoint/phase-3; then
  printf 'safe legacy checkpoint survived cleanup\n' >&2
  exit 1
fi

if dx_checkpoint_ref invalid "$wt_a" >/dev/null 2>&1; then
  printf 'invalid checkpoint phase was accepted\n' >&2
  exit 1
fi

printf 'checkpoint-test passed\n'

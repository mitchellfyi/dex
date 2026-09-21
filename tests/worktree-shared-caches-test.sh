#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-worktree-caches.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export GIT_AUTHOR_NAME=dex GIT_AUTHOR_EMAIL=dex@example.com
export GIT_COMMITTER_NAME=dex GIT_COMMITTER_EMAIL=dex@example.com
# shellcheck disable=SC1091
source "$ROOT/tests/helpers.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

repo="$TMP_DIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
printf 'node_modules/\ntarget/\n.venv/\n' > "$repo/.gitignore"
printf 'hello\n' > "$repo/README.md"
git -C "$repo" add .gitignore README.md
git -C "$repo" commit -q -m 'init'
mkdir -p "$repo/node_modules/pkg" "$repo/target/debug" "$repo/vendor" "$repo/.venv"
printf 'built\n' > "$repo/target/debug/artifact"

wt="$repo/.dex/worktrees/task-one"
mkdir -p "$repo/.dex/worktrees"
git -C "$repo" worktree add -q --no-track "$wt" -b worktree-task-one main

unset DEX_WORKTREE_SHARED_DIRS
dx_link_build_caches_to_worktree "$repo" "$wt" >/dev/null

[[ -L "$wt/node_modules" ]] || assert_at $LINENO
[[ "$(readlink "$wt/node_modules")" == "$repo/node_modules" ]] || assert_at $LINENO
[[ -L "$wt/target" ]] || assert_at $LINENO
[[ -f "$wt/target/debug/artifact" ]] || assert_at $LINENO
[[ -L "$wt/.venv" ]] || assert_at $LINENO
# vendor exists in the main checkout but is not ignored: linking it would put
# a symlink into the next commit, so it stays unlinked.
[[ ! -e "$wt/vendor" && ! -L "$wt/vendor" ]] || assert_at $LINENO
# .next is ignored by nothing and absent from the main checkout.
[[ ! -e "$wt/.next" && ! -L "$wt/.next" ]] || assert_at $LINENO
assert_eq "" "$(git -C "$wt" status --porcelain)" \
  "shared cache links leave the worktree clean"

# Idempotent: a second call neither fails nor replaces the links.
dx_link_build_caches_to_worktree "$repo" "$wt" >/dev/null
[[ "$(readlink "$wt/node_modules")" == "$repo/node_modules" ]] || assert_at $LINENO

# A real directory already in the worktree is never replaced.
wt2="$repo/.dex/worktrees/task-two"
git -C "$repo" worktree add -q --no-track "$wt2" -b worktree-task-two main
mkdir -p "$wt2/node_modules/own"
dx_link_build_caches_to_worktree "$repo" "$wt2" >/dev/null
[[ ! -L "$wt2/node_modules" && -d "$wt2/node_modules/own" ]] || assert_at $LINENO
[[ -L "$wt2/target" ]] || assert_at $LINENO

# The operator can narrow or disable the list.
wt3="$repo/.dex/worktrees/task-three"
git -C "$repo" worktree add -q --no-track "$wt3" -b worktree-task-three main
DEX_WORKTREE_SHARED_DIRS="target" dx_link_build_caches_to_worktree "$repo" "$wt3" >/dev/null
[[ -L "$wt3/target" ]] || assert_at $LINENO
[[ ! -e "$wt3/node_modules" && ! -L "$wt3/node_modules" ]] || assert_at $LINENO
wt4="$repo/.dex/worktrees/task-four"
git -C "$repo" worktree add -q --no-track "$wt4" -b worktree-task-four main
DEX_WORKTREE_SHARED_DIRS="" dx_link_build_caches_to_worktree "$repo" "$wt4" >/dev/null
[[ ! -e "$wt4/target" && ! -L "$wt4/target" ]] || assert_at $LINENO

# Path-shaped names are ignored rather than resolved.
wt5="$repo/.dex/worktrees/task-five"
git -C "$repo" worktree add -q --no-track "$wt5" -b worktree-task-five main
DEX_WORKTREE_SHARED_DIRS="../repo/target ./node_modules" \
  dx_link_build_caches_to_worktree "$repo" "$wt5" >/dev/null
[[ -z "$(find "$wt5" -maxdepth 1 -type l)" ]] || assert_at $LINENO

# Removing the worktree removes only the links, never the shared trees.
git -C "$repo" worktree remove --force "$wt"
[[ -f "$repo/target/debug/artifact" ]] || assert_at $LINENO
[[ -d "$repo/node_modules/pkg" ]] || assert_at $LINENO

echo "worktree shared cache tests passed"

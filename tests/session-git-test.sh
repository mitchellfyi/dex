#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-git-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
mkdir -p "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

new_repo() {
  local name="$1" branch="$2" repo
  repo="$TMP_DIR/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email dex@example.test
  git -C "$repo" config user.name "Dex Test"
  printf '# repo\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m init
  git -C "$repo" branch -M "$branch"
  printf '%s\n' "$repo"
}

master_repo=$(new_repo master-repo master)
[[ "$(dx_default_branch "$master_repo")" == "master" ]] || assert_at $LINENO
[[ "$(dx_default_branch_base_ref "$master_repo" "" no-fetch)" == "master" ]] || assert_at $LINENO

trunk_repo=$(new_repo trunk-repo trunk)
[[ "$(dx_default_branch "$trunk_repo")" == "trunk" ]] || assert_at $LINENO
git -C "$trunk_repo" switch -q -c feature/local
[[ "$(dx_default_branch "$trunk_repo")" == "trunk" ]] || assert_at $LINENO

develop_repo=$(new_repo develop-repo develop)
[[ "$(dx_default_branch "$develop_repo")" == "develop" ]] || assert_at $LINENO

session_repo=$(new_repo session-repo main)
git -C "$session_repo" branch feature/foo
git -C "$session_repo" branch feature-foo
git -C "$session_repo" switch -q feature/foo
slash_id=$(cd "$session_repo" && dx_session_id)
git -C "$session_repo" switch -q feature-foo
dash_id=$(cd "$session_repo" && dx_session_id)

[[ "$slash_id" != "$dash_id" ]] || assert_at $LINENO
[[ "$slash_id" =~ ^repo-[A-Za-z0-9._-]+-[0-9]+-branch-[A-Za-z0-9._-]+-[0-9]+$ ]] || assert_at $LINENO
[[ "$dash_id" =~ ^repo-[A-Za-z0-9._-]+-[0-9]+-branch-[A-Za-z0-9._-]+-[0-9]+$ ]] || assert_at $LINENO

# A registered Dex worktree shares the main checkout's repo namespace and
# keeps the established worktree-<directory> session key.
session_root=$(git -C "$session_repo" rev-parse --path-format=absolute --show-toplevel)
session_root_hash=$(printf '%s' "$session_root" | cksum | awk '{print $1}')
session_repo_key="repo-$(basename "$session_root")-$session_root_hash"
[[ "$(cd "$session_repo" && dx_session_repo_root)" == "$session_root" ]] || assert_at $LINENO
[[ "$(cd "$session_repo" && dx_session_repo_key)" == "$session_repo_key" ]] || assert_at $LINENO

mkdir -p "$session_repo/.dex/worktrees"
dex_worktree="$session_repo/.dex/worktrees/ticket-identity"
git -C "$session_repo" worktree add -q -b worktree-ticket-identity "$dex_worktree" feature/foo
dex_explicit_id=$(cd "$session_repo" && dx_session_id ticket-identity)
dex_auto_id=$(cd "$dex_worktree" && dx_session_id)
[[ "$(cd "$dex_worktree" && dx_session_repo_root)" == "$session_root" ]] || assert_at $LINENO
[[ "$(cd "$dex_worktree" && dx_session_repo_key)" == "$session_repo_key" ]] || assert_at $LINENO
[[ "$dex_auto_id" == "$dex_explicit_id" ]] || assert_at $LINENO

# Linked worktrees outside .dex/worktrees still use a worktree identity, so a
# branch rename does not strand their session state.
external_worktree="$TMP_DIR/external/workspace"
mkdir -p "$(dirname "$external_worktree")"
git -C "$session_repo" worktree add -q -b external-worktree "$external_worktree" feature/foo
external_id=$(cd "$external_worktree" && dx_session_id)
git -C "$external_worktree" branch -m external-worktree-renamed
external_renamed_id=$(cd "$external_worktree" && dx_session_id)
[[ "$(cd "$external_worktree" && dx_session_repo_root)" == "$session_root" ]] || assert_at $LINENO
[[ "$(cd "$external_worktree" && dx_session_repo_key)" == "$session_repo_key" ]] || assert_at $LINENO
[[ "$external_id" == "$external_renamed_id" ]] || assert_at $LINENO
[[ "$external_id" == "$session_repo_key-worktree-workspace" ]] || assert_at $LINENO

second_external_worktree="$TMP_DIR/other/workspace"
mkdir -p "$(dirname "$second_external_worktree")"
git -C "$session_repo" worktree add -q -b external-worktree-two "$second_external_worktree" feature/foo
second_external_id=$(cd "$second_external_worktree" && dx_session_id)
[[ "$second_external_id" != "$external_id" ]] || assert_at $LINENO
[[ "$(cd "$second_external_worktree" && dx_session_repo_root)" == "$session_root" ]] || assert_at $LINENO

# A separate repository whose path happens to contain .dex/worktrees owns a
# separate namespace. The directory spelling alone must not make it a Dex
# worktree of the enclosing repository.
nested_repo="$session_repo/.dex/worktrees/unrelated"
mkdir -p "$nested_repo"
git -C "$nested_repo" init -q
git -C "$nested_repo" config user.email dex@example.test
git -C "$nested_repo" config user.name "Dex Test"
printf 'nested\n' > "$nested_repo/file.txt"
git -C "$nested_repo" add file.txt
git -C "$nested_repo" commit -q -m init
git -C "$nested_repo" branch -M main
nested_key=$(cd "$nested_repo" && dx_session_repo_key)
nested_id=$(cd "$nested_repo" && dx_session_id)
[[ "$(cd "$nested_repo" && dx_session_repo_root)" == "$(git -C "$nested_repo" rev-parse --path-format=absolute --show-toplevel)" ]] || assert_at $LINENO
[[ "$nested_key" != "$session_repo_key" ]] || assert_at $LINENO
[[ "$nested_id" == "$nested_key-branch-main-"* ]] || assert_at $LINENO

# Filesystem aliases of one checkout resolve through the same absolute common
# Git directory and therefore cannot fork the state namespace.
session_alias="$TMP_DIR/session-alias"
ln -s "$session_repo" "$session_alias"
[[ "$(cd "$session_alias" && dx_session_repo_key)" == "$session_repo_key" ]] || assert_at $LINENO

separate_worktree="$TMP_DIR/separate-worktree"
separate_git_dir="$TMP_DIR/separate-admin/repo.git"
mkdir -p "$(dirname "$separate_git_dir")"
git clone -q --separate-git-dir "$separate_git_dir" "$session_repo" "$separate_worktree"
separate_root=$(cd "$separate_worktree" && pwd -P)
[[ "$(cd "$separate_worktree" && dx_session_repo_root)" == "$separate_root" ]] || assert_at $LINENO

not_a_repo="$TMP_DIR/not-a-repo"
mkdir -p "$not_a_repo"
if (cd "$not_a_repo" && dx_session_repo_root >/dev/null 2>&1); then
  fail "dx_session_repo_root accepted a directory outside Git"
fi

printf 'session and git helper tests passed\n'

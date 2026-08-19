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

printf 'session and git helper tests passed\n'

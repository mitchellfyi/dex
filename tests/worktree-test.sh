#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-worktree-test.XXXXXX")"

cleanup() {
  git -C "$TMP_DIR/repo" worktree remove --force "$TMP_DIR/repo/.dex/worktrees/ticket-61" >/dev/null 2>&1 || true
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

dx_link_claude_to_worktree "$repo" "$wt"
[[ -L "$wt/.claude" ]]

status="$(git -C "$wt" status --short)"
if printf '%s\n' "$status" | grep -Fq ".claude"; then
  printf '.claude should be excluded from worktree status\n' >&2
  printf '%s\n' "$status" >&2
  exit 1
fi

exclude_file="$(git -C "$wt" rev-parse --git-path info/exclude)"
grep -Fxq ".claude" "$exclude_file"
grep -Fxq ".claude/*" "$exclude_file"

# Idempotency: re-linking should not duplicate exclude entries.
dx_link_claude_to_worktree "$repo" "$wt"
[[ "$(grep -Fxc ".claude" "$exclude_file")" -eq 1 ]]
[[ "$(grep -Fxc ".claude/*" "$exclude_file")" -eq 1 ]]

printf 'worktree-test passed\n'

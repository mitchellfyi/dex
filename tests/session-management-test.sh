#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-management.XXXXXX")"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

# shellcheck source=lib/common.sh
DX_COMMON_MODULES="lock git session completion session-runtime session-catalog events review review-policy lifecycle-control" \
  source "$ROOT/lib/common.sh"
# shellcheck source=lib/session-management.sh
source "$ROOT/lib/session-management.sh"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email dex@example.test
git -C "$REPO" config user.name "Dex Test"
printf 'base\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m "test: initialize repo"
git -C "$REPO" branch -m main

SID="$(cd "$REPO" && dx_scoped_session_id branch-cleanup-happy)"
dx_meta_write "$SID" \
  "ticket_number=cleanup-happy" \
  "wt_name=cleanup-happy" \
  "wt_dir=$REPO" \
  "workspace_mode=in-place"
printf '3\n' > "$(dx_state_file "$SID")"
printf 'run_cleanup_happy\n' > "$(dx_run_id_file "$SID")"
mkdir -p "$DX_RUN_ROOT/run_cleanup_happy"
printf 'keep\n' > "$DX_RUN_ROOT/run_cleanup_happy/summary.json"
TOKEN="$(dx_session_runtime_start "$SID" codex "$REPO" "$$")"
dx_session_runtime_finish "$SID" "$TOKEN" paused "$$"

__dx_session_management_cleanup_exact "$REPO" "$SID"
assert_no_file "$(dx_state_file "$SID")"
assert_no_file "$(dx_run_id_file "$SID")"
assert_no_file "$(dx_session_runtime_file "$SID")"
assert_file "$(dx_session_runtime_file "$SID")-lock"
assert_file "$DX_RUN_ROOT/run_cleanup_happy/summary.json"
assert_eq "main" "$(git -C "$REPO" branch --show-current)" "preserved branch"

printf '%s\n' "session management tests passed"

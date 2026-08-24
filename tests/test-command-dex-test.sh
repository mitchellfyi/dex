#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
# shellcheck source=tests/test-command-helpers.sh
source "$ROOT/tests/test-command-helpers.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-test-command-dex.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

INSTALL_ROOT="$TMP_DIR/install"
TEST_PROVIDER_LOG="$TMP_DIR/provider.log"
TEST_PROVIDER_ARGS_LOG="$TMP_DIR/provider-args.log"
TEST_PROVIDER_PROMPT_LOG="$TMP_DIR/provider-prompt.log"
TEST_DEX_LOG="$TMP_DIR/dex.log"
export TEST_PROVIDER_LOG TEST_PROVIDER_ARGS_LOG TEST_PROVIDER_PROMPT_LOG TEST_DEX_LOG
test_command_make_install "$INSTALL_ROOT"
INSTALL_REAL="$(cd "$INSTALL_ROOT" && pwd -P)"

(
  cd "$INSTALL_ROOT"
  DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh" dex review "work tree" "café"
)
assert_eq "check:$INSTALL_REAL" "$(sed -n '1p' "$TEST_DEX_LOG")" "static check cwd"
assert_eq "suite:$INSTALL_REAL" "$(sed -n '2p' "$TEST_DEX_LOG")" "suite cwd"
assert_eq "filter:review" "$(sed -n '3p' "$TEST_DEX_LOG")" "first filter"
assert_eq "filter:work tree" "$(sed -n '4p' "$TEST_DEX_LOG")" "space-bearing filter"
assert_eq "filter:café" "$(sed -n '5p' "$TEST_DEX_LOG")" "unicode filter"

: > "$TEST_DEX_LOG"
(
  cd "$INSTALL_ROOT/src"
  DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh"
)
assert_contains "check:$INSTALL_REAL" "$TEST_DEX_LOG"
assert_contains "suite:$INSTALL_REAL" "$TEST_DEX_LOG"

git -C "$INSTALL_ROOT" add .
git -C "$INSTALL_ROOT" \
  -c user.name='Dex Test' -c user.email='dex-test@example.invalid' \
  commit -qm 'test: seed linked worktree'
LINKED_WORKTREE="$TMP_DIR/linked-worktree"
git -C "$INSTALL_ROOT" worktree add -qb test-linked-worktree "$LINKED_WORKTREE"
: > "$TEST_DEX_LOG"
(
  cd "$LINKED_WORKTREE"
  DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh"
)
assert_contains "check:$INSTALL_REAL" "$TEST_DEX_LOG"
assert_contains "suite:$INSTALL_REAL" "$TEST_DEX_LOG"

: > "$TEST_DEX_LOG"
set +e
(
  cd "$TMP_DIR"
  TEST_CHECK_EXIT=7 DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh" dex
) > "$TMP_DIR/check-fail.out" 2> "$TMP_DIR/check-fail.err"
check_exit=$?
set -e
assert_eq "7" "$check_exit" "static check failure status"
assert_contains "check:$INSTALL_REAL" "$TEST_DEX_LOG"
assert_not_contains "suite:" "$TEST_DEX_LOG"

: > "$TEST_DEX_LOG"
set +e
(
  cd "$TMP_DIR"
  TEST_SUITE_EXIT=9 DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh" dex
) > "$TMP_DIR/suite-fail.out" 2> "$TMP_DIR/suite-fail.err"
suite_exit=$?
set -e
assert_eq "9" "$suite_exit" "test suite failure status"
assert_contains "check:$INSTALL_REAL" "$TEST_DEX_LOG"
assert_contains "suite:$INSTALL_REAL" "$TEST_DEX_LOG"

printf 'test command Dex-mode tests passed\n'

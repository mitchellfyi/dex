#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
# shellcheck source=tests/test-command-helpers.sh
source "$ROOT/tests/test-command-helpers.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-test-command-project.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

INSTALL_ROOT="$TMP_DIR/install"
PROJECT_ROOT="$TMP_DIR/project"
TEST_PROVIDER_LOG="$TMP_DIR/provider.log"
TEST_PROVIDER_ARGS_LOG="$TMP_DIR/provider-args.log"
TEST_PROVIDER_PROMPT_LOG="$TMP_DIR/provider-prompt.log"
TEST_DEX_LOG="$TMP_DIR/dex.log"
export TEST_PROVIDER_LOG TEST_PROVIDER_ARGS_LOG TEST_PROVIDER_PROMPT_LOG TEST_DEX_LOG
test_command_make_install "$INSTALL_ROOT"
test_command_make_project "$PROJECT_ROOT"
PROJECT_REAL="$(cd "$PROJECT_ROOT" && pwd -P)"

(
  cd "$PROJECT_ROOT/src"
  DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh"
)
assert_contains "apply" "$TEST_PROVIDER_LOG"
assert_contains "ready" "$TEST_PROVIDER_LOG"
assert_contains "launch:$PROJECT_REAL" "$TEST_PROVIDER_LOG"
assert_contains "dxverify" "$TEST_PROVIDER_PROMPT_LOG"
assert_contains ".dex/dex.md" "$TEST_PROVIDER_PROMPT_LOG"
assert_contains "Quality Gates" "$TEST_PROVIDER_PROMPT_LOG"
assert_contains "Provider profile guidance" "$TEST_PROVIDER_PROMPT_LOG"
assert_contains "--dangerously-skip-permissions" "$TEST_PROVIDER_ARGS_LOG"
assert_contains "bypassPermissions" "$TEST_PROVIDER_ARGS_LOG"

rm -f "$TEST_PROVIDER_LOG"
set +e
(
  cd "$PROJECT_ROOT"
  TEST_PROVIDER_APPLY_EXIT=11 DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh" project
) > "$TMP_DIR/apply-fail.out" 2> "$TMP_DIR/apply-fail.err"
apply_exit=$?
set -e
assert_eq "11" "$apply_exit" "provider resolution failure status"
assert_not_contains "ready" "$TEST_PROVIDER_LOG"

rm -f "$TEST_PROVIDER_LOG"
set +e
(
  cd "$PROJECT_ROOT"
  TEST_PROVIDER_READY_EXIT=12 DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh" project
) > "$TMP_DIR/ready-fail.out" 2> "$TMP_DIR/ready-fail.err"
ready_exit=$?
set -e
assert_eq "12" "$ready_exit" "provider readiness failure status"
assert_contains "apply" "$TEST_PROVIDER_LOG"
assert_contains "ready" "$TEST_PROVIDER_LOG"
assert_not_contains "launch:" "$TEST_PROVIDER_LOG"

rm -f "$TEST_PROVIDER_LOG"
set +e
(
  cd "$PROJECT_ROOT"
  TEST_PROVIDER_LAUNCH_EXIT=13 DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh" project
) > "$TMP_DIR/launch-fail.out" 2> "$TMP_DIR/launch-fail.err"
launch_exit=$?
set -e
assert_eq "13" "$launch_exit" "provider launch failure status"
assert_contains "Verification provider exited with code 13" "$TMP_DIR/launch-fail.err"

MISSING_CONFIG="$TMP_DIR/missing-config"
mkdir -p "$MISSING_CONFIG"
git -C "$MISSING_CONFIG" init -q
if (
  cd "$MISSING_CONFIG"
  DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh" project
) > "$TMP_DIR/missing-config.out" 2> "$TMP_DIR/missing-config.err"; then
  fail "project mode accepted a repository without .dex/dex.md"
fi
assert_contains ".dex/dex.md not found" "$TMP_DIR/missing-config.err"

printf 'test command project-mode tests passed\n'

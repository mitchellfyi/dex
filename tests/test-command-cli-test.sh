#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
# shellcheck source=tests/test-command-helpers.sh
source "$ROOT/tests/test-command-helpers.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-test-command-cli.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

INSTALL_ROOT="$TMP_DIR/install"
TEST_PROVIDER_LOG="$TMP_DIR/provider.log"
TEST_PROVIDER_ARGS_LOG="$TMP_DIR/provider-args.log"
TEST_PROVIDER_PROMPT_LOG="$TMP_DIR/provider-prompt.log"
TEST_DEX_LOG="$TMP_DIR/dex.log"
export TEST_PROVIDER_LOG TEST_PROVIDER_ARGS_LOG TEST_PROVIDER_PROMPT_LOG TEST_DEX_LOG
test_command_make_install "$INSTALL_ROOT"

DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh" --help > "$TMP_DIR/help.out"
assert_contains "Usage: dx test [dex|project] [filters...]" "$TMP_DIR/help.out"
assert_contains "Default:" "$TMP_DIR/help.out"

if DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh" unknown > "$TMP_DIR/unknown.out" 2> "$TMP_DIR/unknown.err"; then
  fail "dx test accepted an unknown mode"
fi
assert_contains "Unknown test mode: unknown" "$TMP_DIR/unknown.err"

if DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh" project extra > "$TMP_DIR/filter.out" 2> "$TMP_DIR/filter.err"; then
  fail "project mode accepted a test filter"
fi
assert_contains "dx test project does not accept filters" "$TMP_DIR/filter.err"
assert_no_file "$TEST_PROVIDER_LOG"

NO_GIT="$TMP_DIR/no-git"
mkdir -p "$NO_GIT"
if (
  cd "$NO_GIT"
  DEX_DIR="$INSTALL_ROOT" bash "$ROOT/bin/test.sh"
) > "$TMP_DIR/no-git.out" 2> "$TMP_DIR/no-git.err"; then
  fail "dx test selected a default outside a Git repository"
fi
assert_contains "Not in a git repository" "$TMP_DIR/no-git.err"

printf 'test command CLI tests passed\n'

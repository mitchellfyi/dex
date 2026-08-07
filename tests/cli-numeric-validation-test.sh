#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-cli-numeric-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME"

assert_fails_with() {
  local expected="$1"
  shift
  local output_file="$TMP_DIR/output" rc

  set +e
  "$@" > "$output_file" 2>&1
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    printf 'expected command to fail: %s\n' "$*" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" "$output_file"; then
    printf 'expected failure to contain %s\n' "$expected" >&2
    cat "$output_file" >&2
    exit 1
  fi
}

assert_fails_with "--budget-minutes requires a positive integer" \
  bash "$ROOT/bin/sync.sh" --budget-minutes 0
assert_fails_with "--budget-minutes requires a positive integer" \
  bash "$ROOT/bin/sync.sh" --budget-minutes 9999999999999999
assert_fails_with "Sync budget must be a positive decimal with at most 15 digits." \
  env DEX_SYNC_BUDGET_MINUTES=08 bash "$ROOT/bin/sync.sh"

assert_fails_with "--budget-minutes requires a positive integer" \
  bash "$ROOT/bin/maintain.sh" --budget-minutes 0
assert_fails_with "--command-timeout-seconds requires a positive integer" \
  bash "$ROOT/bin/maintain.sh" --command-timeout-seconds 0
assert_fails_with "--max-surfaces requires a positive integer" \
  bash "$ROOT/bin/maintain.sh" --max-surfaces 0

bash "$ROOT/bin/sync.sh" --help > "$TMP_DIR/sync-help"
bash "$ROOT/bin/maintain.sh" --help > "$TMP_DIR/maintain-help"

printf 'CLI numeric validation tests passed\n'

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-dx-script-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

assert_contains() {
  local needle="$1" file="$2"
  grep -Fq "$needle" "$file" || {
    printf 'missing expected text: %s\n' "$needle" >&2
    printf 'output was:\n' >&2
    cat "$file" >&2
    exit 1
  }
}

zsh "$ROOT/dx.sh" --help > "$TMP_DIR/zsh-help.out"
assert_contains "Dex" "$TMP_DIR/zsh-help.out"
assert_contains "dx run --spec FILE" "$TMP_DIR/zsh-help.out"

if zsh "$ROOT/dx.sh" > "$TMP_DIR/zsh-empty.out" 2>&1; then
  printf 'expected zsh dx.sh with no args to exit non-zero\n' >&2
  exit 1
fi
assert_contains "Usage: dx <NUMBER>" "$TMP_DIR/zsh-empty.out"

if bash "$ROOT/dx.sh" --help > "$TMP_DIR/bash-help.out" 2>&1; then
  printf 'expected bash dx.sh --help to fail with zsh requirement\n' >&2
  exit 1
fi
assert_contains "dx.sh requires zsh" "$TMP_DIR/bash-help.out"

DEX_DIR="$ROOT" zsh -fc 'source "$DEX_DIR/dx.sh"; dx help' > "$TMP_DIR/source-help.out"
assert_contains "Dex" "$TMP_DIR/source-help.out"

printf 'dx-script-test passed\n'

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-config-reviewer-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
mkdir -p "$HOME" "$TMP_DIR/repo/.dex"

git init -q "$TMP_DIR/repo"
git -C "$TMP_DIR/repo" config user.email test@example.com
git -C "$TMP_DIR/repo" config user.name Test
printf '%s\n' '# Dex project' '## Workflow' 'Keep this section.' > "$TMP_DIR/repo/.dex/dex.md"

(
  cd "$TMP_DIR/repo"
  printf '%s\n' \
    3 n n n n n n n \
    'bad|handle request' \
    'octocat request extra' \
    'valid-user request' \
    '@example/team-name mention' \
    '' \
    | PATH=/usr/bin:/bin bash "$ROOT/bin/config.sh"
) > "$TMP_DIR/config.out" 2>&1

grep -q "Invalid handle 'bad|handle'" "$TMP_DIR/config.out"
grep -q 'enter exactly one handle and one type' "$TMP_DIR/config.out"
grep -q '^| valid-user | request | Added via dx config |$' "$TMP_DIR/repo/.dex/dex.md"
grep -q '^| @example/team-name | mention | Added via dx config |$' "$TMP_DIR/repo/.dex/dex.md"
if grep -q 'bad|handle\|octocat request extra' "$TMP_DIR/repo/.dex/dex.md"; then
  printf 'invalid reviewer input reached dex.md\n' >&2
  exit 1
fi
grep -q '^## Workflow$' "$TMP_DIR/repo/.dex/dex.md"
grep -q '^Keep this section\.$' "$TMP_DIR/repo/.dex/dex.md"

printf 'config reviewer tests passed\n'

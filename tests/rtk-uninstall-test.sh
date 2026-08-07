#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-rtk-uninstall-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export CODEX_HOME="$HOME/.codex"
export DEX_DIR="$ROOT"
export DX_TOOL_DIR="$TMP_DIR/tools"
mkdir -p "$CODEX_HOME" "$HOME/.local/bin" "$DX_TOOL_DIR/rtk/bin"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

managed_binary=$(dx_rtk_managed_binary)
printf '%s\n' 'managed binary cache' > "$managed_binary"
chmod +x "$managed_binary"
ln -s "$managed_binary" "$HOME/.local/bin/rtk"

cat > "$CODEX_HOME/RTK.md" <<EOF
User instructions before Dex.

${DX_RTK_MARKER_START}
old managed content
${DX_RTK_MARKER_END}

User instructions after Dex.
EOF
printf '%s\n' '# User agents' "@${CODEX_HOME}/RTK.md" > "$CODEX_HOME/AGENTS.md"

dx_write_rtk_codex_markdown "$CODEX_HOME/RTK.md" "/managed/rtk"
grep -Fq 'User instructions before Dex.' "$CODEX_HOME/RTK.md"
grep -Fq 'User instructions after Dex.' "$CODEX_HOME/RTK.md"
grep -Fq '/managed/rtk git status' "$CODEX_HOME/RTK.md"
[[ "$(grep -Fc "$DX_RTK_MARKER_START" "$CODEX_HOME/RTK.md")" -eq 1 ]]

dx_uninstall_rtk_codex_instructions > "$TMP_DIR/uninstall.out"
grep -Fq 'User instructions before Dex.' "$CODEX_HOME/RTK.md"
grep -Fq 'User instructions after Dex.' "$CODEX_HOME/RTK.md"
if grep -Fq "$DX_RTK_MARKER_START" "$CODEX_HOME/RTK.md"; then
  printf 'managed RTK block survived uninstall\n' >&2
  exit 1
fi
grep -Fq '# User agents' "$CODEX_HOME/AGENTS.md"
if grep -Fq "@${CODEX_HOME}/RTK.md" "$CODEX_HOME/AGENTS.md"; then
  printf 'managed RTK import survived uninstall\n' >&2
  exit 1
fi
[[ ! -e "$HOME/.local/bin/rtk" ]]
[[ -f "$managed_binary" ]]

printf '%s\n' "$DX_RTK_MARKER_START" 'managed only' "$DX_RTK_MARKER_END" > "$CODEX_HOME/RTK.md"
printf '%s\n' "@${CODEX_HOME}/RTK.md" > "$CODEX_HOME/AGENTS.md"
dx_uninstall_rtk_codex_instructions > /dev/null
[[ ! -e "$CODEX_HOME/RTK.md" ]]
[[ ! -e "$CODEX_HOME/AGENTS.md" ]]

printf '%s\n' 'User content' "$DX_RTK_MARKER_START" 'unterminated managed block' > "$CODEX_HOME/RTK.md"
cp "$CODEX_HOME/RTK.md" "$TMP_DIR/malformed-before.md"
if dx_write_rtk_codex_markdown "$CODEX_HOME/RTK.md" "/managed/rtk"; then
  printf 'malformed RTK markers were accepted during update\n' >&2
  exit 1
fi
cmp -s "$TMP_DIR/malformed-before.md" "$CODEX_HOME/RTK.md"
if dx_uninstall_rtk_codex_instructions > /dev/null; then
  printf 'malformed RTK markers were accepted during uninstall\n' >&2
  exit 1
fi
cmp -s "$TMP_DIR/malformed-before.md" "$CODEX_HOME/RTK.md"

printf 'RTK uninstall tests passed\n'

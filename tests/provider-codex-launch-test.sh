#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-provider-codex-launch-test.XXXXXX")"

cleanup() {
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
export PATH="$TMP_DIR/bin:$PATH"
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/repo/.dex"

cat > "$TMP_DIR/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$DEX_TEST_CODEX_ARGS"
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  printf '%s\n' "Logged in with ChatGPT"
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "--help" ]]; then
  printf '%s\n' "--ignore-user-config"
  printf '%s\n' "--dangerously-bypass-approvals-and-sandbox"
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "review" && "${3:-}" == "--help" ]]; then
  printf '%s\n' "--ignore-user-config"
  printf '%s\n' "--dangerously-bypass-approvals-and-sandbox"
  exit 0
fi
if [[ "${1:-}" == "exec" ]]; then
  printf '%s\n' "$*" > "$DEX_TEST_CODEX_LAST_ARGS"
  printf '%s\n' "${*: -1}" > "$DEX_TEST_CODEX_PROMPT"
  exit 0
fi
exit 0
SH
chmod +x "$TMP_DIR/bin/codex"

cat > "$TMP_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "claude should not be launched for codex-plugin lifecycle" >&2
exit 42
SH
chmod +x "$TMP_DIR/bin/claude"

git -C "$TMP_DIR/repo" init -q
git -C "$TMP_DIR/repo" config user.email dex@example.test
git -C "$TMP_DIR/repo" config user.name "Dex Test"
printf '# repo\n' > "$TMP_DIR/repo/README.md"
git -C "$TMP_DIR/repo" add README.md
git -C "$TMP_DIR/repo" commit -q -m init

export DEX_TEST_CODEX_ARGS="$TMP_DIR/codex-args.log"
export DEX_TEST_CODEX_LAST_ARGS="$TMP_DIR/codex-last-args.log"
export DEX_TEST_CODEX_PROMPT="$TMP_DIR/codex-prompt.txt"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

cd "$TMP_DIR/repo"
export DX_AGENT_OVERRIDE=codex
dx_provider_apply

system_prompt="$TMP_DIR/system-prompt.md"
printf '%s\n' "System context for Dex." > "$system_prompt"

DEX_SESSION_ID="provider-codex-launch" \
  dx_provider_claude --chrome --dangerously-skip-permissions --permission-mode bypassPermissions \
    -n "session-name" \
    --append-system-prompt-file "$system_prompt" \
    --settings '{"statusLine":{"type":"command","command":"true"}}' \
    "Implement ticket 123."

grep -q -- "exec --ignore-user-config --dangerously-bypass-approvals-and-sandbox --" "$DEX_TEST_CODEX_LAST_ARGS"
grep -q -- "System context for Dex." "$DEX_TEST_CODEX_PROMPT"
grep -q -- "--- Dex phase task ---" "$DEX_TEST_CODEX_PROMPT"
grep -q -- "Implement ticket 123." "$DEX_TEST_CODEX_PROMPT"
grep -q -- "engine=codex-plugin" "$(dx_provider_state_file provider-codex-launch)"

printf 'provider codex launch test passed\n'

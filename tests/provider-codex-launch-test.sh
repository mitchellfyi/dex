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
  env | sort > "$DEX_TEST_CODEX_ENV"
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
git -C "$TMP_DIR/repo" branch -m main

export DEX_TEST_CODEX_ARGS="$TMP_DIR/codex-args.log"
export DEX_TEST_CODEX_LAST_ARGS="$TMP_DIR/codex-last-args.log"
export DEX_TEST_CODEX_PROMPT="$TMP_DIR/codex-prompt.txt"
export DEX_TEST_CODEX_ENV="$TMP_DIR/codex-env.log"
export DEX_TEST_REPO="$TMP_DIR/repo"
export DEX_FACTORY_TOKEN="factory-secret"
export DEX_FACTORY_RUN_TOKEN="factory-run-secret"
export DEX_RUN_TOKEN="run-secret"

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
if grep -q -- "DEX_FACTORY_TOKEN=" "$DEX_TEST_CODEX_ENV"; then
  printf '%s\n' "factory token leaked into Codex environment" >&2
  exit 1
fi
if grep -q -- "DEX_FACTORY_RUN_TOKEN=" "$DEX_TEST_CODEX_ENV"; then
  printf '%s\n' "factory run token leaked into Codex environment" >&2
  exit 1
fi
if grep -q -- "DEX_RUN_TOKEN=" "$DEX_TEST_CODEX_ENV"; then
  printf '%s\n' "run token leaked into Codex environment" >&2
  exit 1
fi

: > "$DEX_TEST_CODEX_LAST_ARGS"
: > "$DEX_TEST_CODEX_PROMPT"
bash "$ROOT/bin/dxcodex.sh" review --uncommitted "Review the current changes."
grep -q -- "exec --ignore-user-config --dangerously-bypass-approvals-and-sandbox --" "$DEX_TEST_CODEX_LAST_ARGS"
if grep -q -- "exec review --uncommitted" "$DEX_TEST_CODEX_LAST_ARGS"; then
  printf '%s\n' "review prompt was delegated through raw codex review" >&2
  exit 1
fi
grep -q -- "Review uncommitted changes in the current checkout." "$DEX_TEST_CODEX_PROMPT"
grep -q -- "Review the current changes." "$DEX_TEST_CODEX_PROMPT"

: > "$DEX_TEST_CODEX_LAST_ARGS"
bash "$ROOT/bin/dxcodex.sh" review --uncommitted
grep -q -- "exec review --ignore-user-config --dangerously-bypass-approvals-and-sandbox --uncommitted" "$DEX_TEST_CODEX_LAST_ARGS"

: > "$DEX_TEST_CODEX_ARGS"
: > "$DEX_TEST_CODEX_LAST_ARGS"
: > "$DEX_TEST_CODEX_PROMPT"
DEXCODE_SYNC=0 zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$DEX_TEST_REPO"; dx --agent codex --no-worktree "exercise codex setup"' > "$TMP_DIR/dx-agent-codex.out" 2>&1 || true
if grep -q -- "claude should not be launched" "$TMP_DIR/dx-agent-codex.out"; then
  printf '%s\n' "dx --agent codex launched Claude instead of Codex" >&2
  exit 1
fi
grep -q -- "exec --ignore-user-config --dangerously-bypass-approvals-and-sandbox --" "$DEX_TEST_CODEX_LAST_ARGS"
grep -q -- "Initial phase: Phase 0 (Setup)." "$DEX_TEST_CODEX_PROMPT"
grep -q -- "Begin Phase 0: Setup" "$DEX_TEST_CODEX_PROMPT"

printf 'provider codex launch test passed\n'

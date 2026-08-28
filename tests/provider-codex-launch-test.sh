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
  printf '%s\n' "--sandbox <mode>"
  printf '%s\n' "--ephemeral"
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
    --append-system-prompt "Inline safety context for Dex." \
    --settings '{"statusLine":{"type":"command","command":"true"}}' \
    --verbose --output-format stream-json --include-partial-messages \
    "Implement ticket 123."

grep -q -- "exec --ignore-user-config --dangerously-bypass-approvals-and-sandbox --" "$DEX_TEST_CODEX_LAST_ARGS"
grep -q -- "System context for Dex." "$DEX_TEST_CODEX_PROMPT"
grep -q -- "Inline safety context for Dex." "$DEX_TEST_CODEX_PROMPT"
grep -q -- "--- Dex phase task ---" "$DEX_TEST_CODEX_PROMPT"
grep -q -- "Implement ticket 123." "$DEX_TEST_CODEX_PROMPT"
if [[ "$(tail -n 1 "$DEX_TEST_CODEX_PROMPT")" != "Implement ticket 123." ]]; then
  printf '%s\n' "Claude option values replaced the Codex task prompt" >&2
  exit 1
fi
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

if dx_provider_codex_prompt_from_claude_args --future-unknown value "task" \
  > "$TMP_DIR/unknown-option.out" 2>&1; then
  printf '%s\n' "unknown Claude launch option was silently accepted for Codex" >&2
  exit 1
fi
grep -q -- "cannot translate Claude launch option" "$TMP_DIR/unknown-option.out"

: > "$DEX_TEST_CODEX_LAST_ARGS"
: > "$DEX_TEST_CODEX_PROMPT"
DX_CODEX_READ_ONLY=1 bash "$ROOT/bin/dxcodex.sh" exec -- "Assess the supplied context."
grep -q -- "exec --ignore-user-config --sandbox read-only --ephemeral --" "$DEX_TEST_CODEX_LAST_ARGS"
if grep -q -- "--dangerously-bypass-approvals-and-sandbox" "$DEX_TEST_CODEX_LAST_ARGS"; then
  printf '%s\n' "read-only Codex exec included dangerous bypass" >&2
  exit 1
fi
if grep -q -- "DX_CODEX_READ_ONLY=" "$DEX_TEST_CODEX_ENV"; then
  printf '%s\n' "internal read-only marker leaked into Codex environment" >&2
  exit 1
fi
grep -q -- "Assess the supplied context." "$DEX_TEST_CODEX_PROMPT"

set +e
DX_CODEX_READ_ONLY=1 DX_PROVIDER_CODEX_WRAPPER=1 \
  dx_provider_codex exec --ignore-user-config --sandbox read-only --ephemeral \
    --dangerously-bypass-approvals-and-sandbox -- "unsafe" > "$TMP_DIR/read-only-bypass.out" 2>&1
read_only_bypass_status=$?
DX_CODEX_READ_ONLY=1 DX_PROVIDER_CODEX_WRAPPER=1 \
  dx_provider_codex exec --ignore-user-config --sandbox read-only -- \
    "missing ephemeral" > "$TMP_DIR/read-only-missing-flag.out" 2>&1
read_only_missing_flag_status=$?
set -e
if [[ $read_only_bypass_status -ne 2 || $read_only_missing_flag_status -ne 2 ]]; then
  printf '%s\n' "provider accepted an invalid read-only Codex launch" >&2
  exit 1
fi

: > "$DEX_TEST_CODEX_LAST_ARGS"
DX_CODEX_READ_ONLY=1 dx_provider_codex_exec "Assess through the provider helper." "$DEX_TEST_REPO"
grep -q -- "exec --ignore-user-config --sandbox read-only --ephemeral -C $DEX_TEST_REPO -" "$DEX_TEST_CODEX_LAST_ARGS"
if grep -q -- "--dangerously-bypass-approvals-and-sandbox" "$DEX_TEST_CODEX_LAST_ARGS"; then
  printf '%s\n' "read-only provider helper included dangerous bypass" >&2
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
: > "$DEX_TEST_CODEX_PROMPT"
DX_CODEX_READ_ONLY=1 bash "$ROOT/bin/dxcodex.sh" review --uncommitted "Assess the current changes."
grep -q -- "exec --ignore-user-config --sandbox read-only --ephemeral --" "$DEX_TEST_CODEX_LAST_ARGS"
if grep -q -- "--dangerously-bypass-approvals-and-sandbox" "$DEX_TEST_CODEX_LAST_ARGS"; then
  printf '%s\n' "read-only prompted review included dangerous bypass" >&2
  exit 1
fi
grep -q -- "Assess the current changes." "$DEX_TEST_CODEX_PROMPT"

: > "$DEX_TEST_CODEX_LAST_ARGS"
bash "$ROOT/bin/dxcodex.sh" review --uncommitted
grep -q -- "exec review --ignore-user-config --dangerously-bypass-approvals-and-sandbox --uncommitted" "$DEX_TEST_CODEX_LAST_ARGS"

: > "$DEX_TEST_CODEX_LAST_ARGS"
DX_CODEX_READ_ONLY=1 bash "$ROOT/bin/dxcodex.sh" review --uncommitted
grep -q -- "exec --ignore-user-config --sandbox read-only --ephemeral review --uncommitted" "$DEX_TEST_CODEX_LAST_ARGS"
if grep -q -- "--dangerously-bypass-approvals-and-sandbox" "$DEX_TEST_CODEX_LAST_ARGS"; then
  printf '%s\n' "read-only unprompted review included dangerous bypass" >&2
  exit 1
fi

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
grep -q -- "do not push it until Phase 2 creates the first real implementation commit" "$DEX_TEST_CODEX_PROMPT"
if grep -q -- "push the current lifecycle branch and proceed" "$DEX_TEST_CODEX_PROMPT"; then
  printf '%s\n' "Phase 0 prompt still publishes an empty lifecycle branch" >&2
  exit 1
fi

# A run spec can say how hard to think. Codex takes effort as configuration
# rather than a flag of its own, so it has to arrive as -c
# model_reasoning_effort — it used to be resolved, validated, and then dropped
# for the one agent DexCode plans with by default.
: > "$DEX_TEST_CODEX_ARGS"
: > "$DEX_TEST_CODEX_LAST_ARGS"
DX_EFFORT_OVERRIDE=xhigh DX_CODEX_READ_ONLY=1 \
  bash "$ROOT/bin/dxcodex.sh" exec -- "think hard about this"
grep -q -- "-c model_reasoning_effort=xhigh" "$DEX_TEST_CODEX_LAST_ARGS"

# ...and nothing is passed when nothing asked for it, so the profile's own
# setting still decides.
: > "$DEX_TEST_CODEX_ARGS"
: > "$DEX_TEST_CODEX_LAST_ARGS"
DX_CODEX_READ_ONLY=1 bash "$ROOT/bin/dxcodex.sh" exec -- "no effort stated"
if grep -q -- "model_reasoning_effort" "$DEX_TEST_CODEX_LAST_ARGS"; then
  printf '%s\n' "codex was given an effort nobody asked for" >&2
  exit 1
fi

# The flag checks read a CLI's --help, which is long, and the flags they look
# for appear near the top of it. Feeding that through `printf | grep -q` under
# pipefail decided the answer on timing: grep exits at the first match, printf
# is left writing into a closed pipe and exits 141, and pipefail reports 141 —
# so `! pipeline` is true and Dex says the flag is unsupported when it is
# right there. A long help text with an early match reproduced it every time.
codex_stub_dir="$TMP_DIR/help-stub"
mkdir -p "$codex_stub_dir"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [[ "$1" == "--version" ]]; then printf "codex 9.9.9\\n"; exit 0; fi\n'
  # Every required flag first, then enough output to fill the pipe buffer.
  printf 'printf -- "--ignore-user-config --sandbox --ephemeral --dangerously-bypass-approvals-and-sandbox\\n"\n'
  printf 'python3 -c "print((chr(45) * 79 + chr(10)) * 40000)"\n'
} > "$codex_stub_dir/codex"
chmod +x "$codex_stub_dir/codex"

codex_flags_out="$TMP_DIR/codex-flags.out"
codex_flags_status=0
PATH="$codex_stub_dir:$PATH" dx_provider_codex_required_flags_check \
  > "$codex_flags_out" 2>&1 || codex_flags_status=$?
if [[ "$codex_flags_status" -ne 0 ]]; then
  printf 'a Codex CLI advertising every required flag was reported as missing one:\n' >&2
  head -5 "$codex_flags_out" >&2
  exit 1
fi

printf 'provider codex launch test passed\n'

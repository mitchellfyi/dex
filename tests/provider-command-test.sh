#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-provider-command-test.XXXXXX")"

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
export CODEX_HOME="$TMP_DIR/codex-home"
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/repo/.dex"

# Keep the provider doctor isolated from any real Claude or Codex installation.
for tool in python3 git grep find basename dirname env; do
  tool_path=$(command -v "$tool")
  ln -s "$tool_path" "$TMP_DIR/bin/$tool"
done
export PATH="$TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cat > "$TMP_DIR/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  printf '%s\n' "Logged in with ChatGPT"
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "--help" ]]; then
  printf '%s\n' "--ignore-user-config" "--dangerously-bypass-approvals-and-sandbox"
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "review" && "${3:-}" == "--help" ]]; then
  printf '%s\n' "--ignore-user-config" "--dangerously-bypass-approvals-and-sandbox"
  exit 0
fi
exit 0
SH
chmod +x "$TMP_DIR/bin/codex"

git -C "$TMP_DIR/repo" init -q
git -C "$TMP_DIR/repo" config user.email dex@example.test
git -C "$TMP_DIR/repo" config user.name "Dex Test"
git -C "$TMP_DIR/repo" commit -q --allow-empty -m init

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

while IFS= read -r env_name; do
  [[ -n "$env_name" ]] && unset "$env_name"
done < <(dx_provider_external_env_names)
while IFS= read -r env_name; do
  [[ -n "$env_name" ]] && unset "$env_name"
done < <(dx_provider_claude_override_env_names)
unset DX_AGENT_OVERRIDE DX_MODEL_OVERRIDE DX_ALLOW_API_BILLED_AUTH
export DX_PROVIDER_PROFILE="codex-subscription"
dx_install_codex_skills >/dev/null

assert_fails_with() {
  local expected="$1"
  shift
  local output status
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    printf 'expected command to fail: %s\n' "$*" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    printf 'expected failure to contain %s, got:\n%s\n' "$expected" "$output" >&2
    exit 1
  fi
}

cd "$TMP_DIR/repo"
doctor_output=$(dx_provider_command doctor 2>&1)
grep -Fq "direct Codex delegation does not require it" <<<"$doctor_output"
grep -Fq "Codex is logged in with ChatGPT" <<<"$doctor_output"
grep -Fq "Dex Codex skills linked" <<<"$doctor_output"
dx_provider_agent_ready_check
provider_prompt=$(dx_provider_prompt)
grep -Fq "already running through Dex's signed-in Codex CLI wrapper" <<<"$provider_prompt"
if grep -Fq "Claude Code remains the outer lifecycle harness" <<<"$provider_prompt"; then
  printf 'Codex provider prompt still described a Claude outer harness\n' >&2
  exit 1
fi

export DX_PROVIDER_PROFILE="claude-subscription"
dx_provider_apply
assert_fails_with "Claude Code CLI not found; the claude-subscription profile cannot launch work." \
  dx_provider_agent_ready_check
export DX_PROVIDER_PROFILE="codex-subscription"
dx_provider_apply

assert_fails_with "Usage: dx provider list" dx_provider_command list unexpected
assert_fails_with "Usage: dx provider current" dx_provider_command current unexpected
assert_fails_with "Usage: dx provider doctor" dx_provider_command doctor unexpected
assert_fails_with "Usage: dx provider use [--repo] <profile>" dx_provider_command use claude-subscription unexpected
assert_fails_with "Usage: dx provider help" dx_provider_command help unexpected
[[ ! -e "$HOME/.dex/providers.json" ]]

cd "$TMP_DIR"
assert_fails_with "Cannot set a repo provider profile outside a git repository." \
  dx_provider_command use --repo claude-subscription

cat > "$TMP_DIR/repo/.dex/providers.json" <<'JSON'
{
  "default": "broken",
  "profiles": {
    "broken": {
      "engine": "claude",
      "auth": "subscription",
      "unknown_field": "value"
    }
  }
}
JSON

cd "$TMP_DIR/repo"
assert_fails_with "Reason: profile 'broken' has unknown key 'unknown_field'" \
  dx_provider_command list

# Gateway profiles with api-token auth must launch through BSD env, where
# options must precede NAME=VALUE operands (regression: a -u flag appended
# after the assignments made every gateway launch exit 127 on macOS).
rm -f "$TMP_DIR/repo/.dex/providers.json"
mkdir -p "$HOME/.dex"
cat > "$HOME/.dex/providers.json" <<'JSON'
{
  "profiles": {
    "test-gateway": {
      "engine": "anthropic-gateway",
      "auth": "api-token",
      "model": "claude-test-model",
      "base_url": "https://gateway.example.test",
      "auth_env": "DEX_TEST_GATEWAY_TOKEN"
    }
  }
}
JSON
cat > "$TMP_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'claude-stub token=%s base=%s leaked=%s\n' \
  "${ANTHROPIC_AUTH_TOKEN:-}" "${ANTHROPIC_BASE_URL:-}" "${DEX_TEST_GATEWAY_TOKEN:-absent}"
SH
chmod +x "$TMP_DIR/bin/claude"
export DX_PROVIDER_PROFILE="test-gateway"
export DEX_TEST_GATEWAY_TOKEN="gateway-secret"
dx_provider_apply
set +e
gateway_output=$(dx_provider_claude 2>&1)
gateway_status=$?
set -e
if [[ $gateway_status -ne 0 ]]; then
  printf 'gateway launch failed (%s):\n%s\n' "$gateway_status" "$gateway_output" >&2
  exit 1
fi
grep -Fq "token=gateway-secret" <<<"$gateway_output"
grep -Fq "base=https://gateway.example.test" <<<"$gateway_output"
grep -Fq "leaked=absent" <<<"$gateway_output"
unset DEX_TEST_GATEWAY_TOKEN
rm -f "$HOME/.dex/providers.json" "$TMP_DIR/bin/claude"
export DX_PROVIDER_PROFILE="codex-subscription"
dx_provider_apply

printf 'provider command tests passed\n'

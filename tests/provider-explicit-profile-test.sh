#!/usr/bin/env bash
set -euo pipefail

# An explicit DX_PROVIDER_PROFILE for the selected agent beats the repository's
# default profile. Three live launches resolved a repository default that
# pointed at a disabled router over the direct profile the operator asked for,
# created a worktree and a run record, and stopped at Phase 0.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-provider-explicit-test.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/.dex"
git init -q -b main "$REPO"
printf '{"default": "ccr-subscription", "profiles": {}}\n' > "$REPO/.dex/providers.json"

resolve() {  # resolve [NAME=VALUE…] -> the resolved profile
  (
    cd "$REPO"
    # shellcheck disable=SC1091
    source "$ROOT/lib/common.sh"
    env "$@" bash -c 'source "$DEX_DIR/lib/common.sh"; cd "$1"; dx_provider_apply >/dev/null 2>&1; printf "%s\n" "$DX_PROVIDER_PROFILE_RESOLVED"' _ "$REPO"
  )
}

# The repository default applies when nothing more specific is said.
[[ "$(resolve)" == "ccr-subscription" ]] || assert_at $LINENO
[[ "$(resolve DX_AGENT_OVERRIDE=claude)" == "ccr-subscription" ]] || assert_at $LINENO
# An explicit profile for the same agent wins, with or without the agent flag.
[[ "$(resolve DX_PROVIDER_PROFILE=claude-subscription)" == "claude-subscription" ]] || assert_at $LINENO
[[ "$(resolve DX_AGENT_OVERRIDE=claude DX_PROVIDER_PROFILE=claude-subscription)" == "claude-subscription" ]] || assert_at $LINENO
# An explicit profile for a different agent does not override the agent choice.
[[ "$(resolve DX_AGENT_OVERRIDE=claude DX_PROVIDER_PROFILE=codex-subscription)" == "ccr-subscription" ]] || assert_at $LINENO

printf 'provider explicit profile tests passed\n'

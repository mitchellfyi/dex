#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-codex-inline-handoff-test.XXXXXX")"

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
export TMP_DIR
mkdir -p "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_ARTIFACT_DIR" "$DX_TOOL_DIR" "$DX_RUN_ROOT" "$TMP_DIR/repo"

git -C "$TMP_DIR/repo" init -q
git -C "$TMP_DIR/repo" config user.email dex@example.test
git -C "$TMP_DIR/repo" config user.name "Dex Test"
printf '# repo\n' > "$TMP_DIR/repo/README.md"
git -C "$TMP_DIR/repo" add README.md
git -C "$TMP_DIR/repo" commit -q -m init

zsh -fc '
source "$DEX_DIR/dx.sh"
set -e

session_id="codex-inline-handoff"
state_file="$(dx_state_file "$session_id")"
provider_file="$(dx_provider_state_file "$session_id")"
mkdir -p "$(dirname "$state_file")" "$(dirname "$provider_file")"
printf "engine=codex-plugin\nsession=%s\n" "$session_id" > "$provider_file"
printf "0\n" > "$state_file"
printf "0:%s\n" "$(date +%s)" > "$(dx_times_file "$session_id")"
touch "$(dx_phase_ready_file "$session_id" 0)"

__dx_codex_direct_phase_handoff "$session_id" 0 "$state_file" "$TMP_DIR/repo"
[[ "$(cat "$state_file")" == "1" ]]
[[ ! -f "$(dx_phase_ready_file "$session_id" 0)" ]]

printf "3\n" > "$state_file"
if __dx_codex_direct_phase_handoff "$session_id" 3 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 3 advanced without completion marker" >&2
  exit 1
fi

touch "$(dx_complete_file "$session_id")"
__dx_codex_direct_phase_handoff "$session_id" 3 "$state_file" "$TMP_DIR/repo"
[[ "$(cat "$state_file")" == "4" ]]
'

zsh -fc '
source "$DEX_DIR/dx.sh"
set -e

session_id="codex-inline-prelaunch-handoff"
state_file="$(dx_state_file "$session_id")"
times_file="$(dx_times_file "$session_id")"
provider_file="$(dx_provider_state_file "$session_id")"
mkdir -p "$(dirname "$state_file")" "$(dirname "$times_file")" "$(dirname "$provider_file")"
printf "engine=codex-plugin\nsession=%s\n" "$session_id" > "$provider_file"
printf "6\n" > "$state_file"
touch "$(dx_complete_file "$session_id")"
export DX_PROVIDER_ENGINE=codex-plugin

__dx_claude() {
  printf "%s\n" "provider launched despite completed direct-Codex phase" >&2
  return 97
}

__dx_run_phases_inline "repo" "$TMP_DIR/repo" "master" 6 "$state_file" "$times_file" "dx --agent codex test" "in-place" "$session_id" "test"
[[ "$(cat "$state_file")" == "7" ]]
'

printf 'codex inline handoff test passed\n'

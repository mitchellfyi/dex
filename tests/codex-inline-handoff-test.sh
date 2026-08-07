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
export TEST_DEFAULT_BRANCH
TEST_DEFAULT_BRANCH=$(git -C "$TMP_DIR/repo" branch --show-current)

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

if ! __dx_codex_direct_phase_handoff "$session_id" 0 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 0 did not advance with a ready marker" >&2
  exit 1
fi
[[ "$(cat "$state_file")" == "1" ]]
[[ ! -f "$(dx_phase_ready_file "$session_id" 0)" ]]

printf "1\n" > "$state_file"
printf "%s\n" "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Exercise the direct handoff.\"],\"acceptance_criteria\":[\"Phase gates must reject missing state.\"],\"verification_requirements\":[\"Run tests/codex-inline-handoff-test.sh.\"]}" > "$(dx_review_criteria_file "$session_id")"
touch "$(dx_complete_file "$session_id")"
if __dx_codex_direct_phase_handoff "$session_id" 1 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 1 advanced without its ready marker" >&2
  exit 1
fi
rm -f "$(dx_complete_file "$session_id")" "$(dx_review_criteria_file "$session_id")"
touch "$(dx_phase_ready_file "$session_id" 1)"
if __dx_codex_direct_phase_handoff "$session_id" 1 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 1 advanced without approved review criteria" >&2
  exit 1
fi
printf "%s\n" "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Exercise the direct handoff.\"],\"acceptance_criteria\":[\"Phase gates must reject missing state.\"],\"verification_requirements\":[\"Run tests/codex-inline-handoff-test.sh.\"]}" > "$(dx_review_criteria_file "$session_id")"
if ! __dx_codex_direct_phase_handoff "$session_id" 1 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 1 did not advance with valid approved review criteria" >&2
  exit 1
fi
[[ "$(cat "$state_file")" == "2" ]]
[[ "$(cut -f2 "$(dx_review_criteria_approval_file "$session_id")")" == "1" ]]
approved_criteria_hash=$(dx_review_read_criteria_approval "$session_id")

printf "2\n" > "$state_file"
touch "$(dx_phase_ready_file "$session_id" 2)"
if __dx_codex_direct_phase_handoff "$session_id" 2 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 2 advanced without a review risk selection" >&2
  exit 1
fi
printf "%s\n" "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Tamper with the direct handoff.\"],\"acceptance_criteria\":[\"Phase 2 rejects unapproved criteria.\"],\"verification_requirements\":[\"Run tests/codex-inline-handoff-test.sh.\"]}" > "$(dx_review_criteria_file "$session_id")"
if __dx_codex_direct_phase_handoff "$session_id" 2 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 2 advanced with criteria changed after approval" >&2
  exit 1
fi
printf "%s\n" "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Exercise the direct handoff.\"],\"acceptance_criteria\":[\"Phase gates must reject missing state.\"],\"verification_requirements\":[\"Run tests/codex-inline-handoff-test.sh.\"]}" > "$(dx_review_criteria_file "$session_id")"
[[ "$(dx_review_read_criteria_approval "$session_id")" == "$approved_criteria_hash" ]]
if ! dx_review_write_selection "$session_id" complex lifecycle-agent broad-impact "$TMP_DIR/repo"; then
  printf "%s\n" "could not write the Phase 2 risk selection fixture" >&2
  exit 1
fi
if ! __dx_codex_direct_phase_handoff "$session_id" 2 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 2 did not advance with valid criteria and risk selection" >&2
  exit 1
fi
[[ "$(cat "$state_file")" == "3" ]]

printf "3\n" > "$state_file"
if __dx_codex_direct_phase_handoff "$session_id" 3 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 3 advanced without completion marker" >&2
  exit 1
fi

touch "$(dx_complete_file "$session_id")"
receipt_fingerprint="$(dx_review_scope_fingerprint "$TMP_DIR/repo")"
for ledger_iteration in {1..9}; do
  dx_review_ledger_append "$session_id" "$ledger_iteration" "direct-clean-${ledger_iteration}" "$receipt_fingerprint" "$(printf "%016x" "$ledger_iteration")"
done
if ! dx_review_write_receipt "$session_id" complex 9 9 "$TMP_DIR/repo"; then
  printf "%s\n" "could not write the Phase 3 receipt fixture" >&2
  exit 1
fi
if ! __dx_codex_direct_phase_handoff "$session_id" 3 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 3 did not advance with a valid review receipt" >&2
  exit 1
fi
[[ "$(cat "$state_file")" == "4" ]]

printf "2\n" > "$state_file"
dx_write_lifecycle_control "$session_id" jump 4 terminal "" 2 ""
__dx_codex_direct_phase_handoff "$session_id" 2 "$state_file" "$TMP_DIR/repo"
[[ "$(cat "$state_file")" == "4" ]]
[[ ! -f "$(dx_lifecycle_control_file "$session_id")" ]]

printf "2\n" > "$state_file"
touch "$(dx_active_file "$session_id")"
dx_write_lifecycle_control "$session_id" cancel "" terminal "" 2 ""
if __dx_codex_direct_phase_handoff "$session_id" 2 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "direct Codex cancel was reported as an ordinary phase handoff" >&2
  exit 1
else
  pause_status=$?
fi
[[ "$pause_status" -eq 2 ]]
[[ -f "$(dx_paused_file "$session_id")" ]]
[[ -f "$(dx_lifecycle_control_file "$session_id")" ]]
[[ ! -f "$(dx_active_file "$session_id")" ]]
'

zsh -fc '
source "$DEX_DIR/dx.sh"
set -e

export DX_PROVIDER_ENGINE=codex-plugin
session_id="codex-direct-prelaunch-pause"
state_file="$(dx_state_file "$session_id")"
times_file="$(dx_times_file "$session_id")"
provider_file="$(dx_provider_state_file "$session_id")"
mkdir -p "$(dirname "$state_file")" "$(dirname "$times_file")" "$(dirname "$provider_file")"
printf "engine=codex-plugin\nsession=%s\n" "$session_id" > "$provider_file"
printf "2\n" > "$state_file"
printf "inline\n" > "$(dx_handoff_mode_file "$session_id")"
printf "2:PHASE_2_COMPLETE:%s/prompts/phase-audits/2-implement.md:1\n" "$DEX_DIR" > "$(dx_loop_config_file "$session_id")"
touch "$(dx_active_file "$session_id")"
dx_write_lifecycle_control "$session_id" cancel "" terminal "" 2 ""

__dx_claude() {
  touch "$TMP_DIR/provider-launched-after-pause"
  return 97
}

if __dx_run_phases_inline "repo" "$TMP_DIR/repo" "$TEST_DEFAULT_BRANCH" 2 "$state_file" "$times_file" \
  "dx --agent codex test" "in-place" "$session_id" "test"; then
  printf "%s\n" "paused direct Codex lifecycle reported success" >&2
  exit 1
else
  wrapper_status=$?
fi
[[ "$wrapper_status" -eq 1 ]]
[[ ! -f "$TMP_DIR/provider-launched-after-pause" ]]
[[ -f "$(dx_paused_file "$session_id")" ]]
[[ "$(dx_pause_state_read "$session_id" reason)" == "manual-cancel" ]]
[[ ! -f "$(dx_lifecycle_control_file "$session_id")" ]]
[[ -f "$(dx_handoff_mode_file "$session_id")" ]]
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

__dx_run_phases_inline "repo" "$TMP_DIR/repo" "$TEST_DEFAULT_BRANCH" 6 "$state_file" "$times_file" "dx --agent codex test" "in-place" "$session_id" "test"
[[ "$(cat "$state_file")" == "7" ]]
'

zsh -fc '
source "$DEX_DIR/dx.sh"
set -e

export DX_PROVIDER_ENGINE=codex-plugin
session_id="codex-direct-context-marker"
ctx_file="$(__dx_build_system_context "repo" 4 "$session_id" "$TMP_DIR/repo" "worktree" "test")"
grep -q "Direct Codex Phase Marker" "$ctx_file"
grep -q "dx_complete_file" "$ctx_file"

ctx_file="$(__dx_build_system_context "repo" 2 "$session_id" "$TMP_DIR/repo" "worktree" "test")"
grep -q "Direct Codex Phase Marker" "$ctx_file"
grep -q "dx_phase_ready_file" "$ctx_file"
grep -q "Direct Human Control" "$ctx_file"
grep -q "bin/control.sh" "$ctx_file"
'

printf 'codex inline handoff test passed\n'

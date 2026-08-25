#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-codex-inline-handoff-test.XXXXXX")"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
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
source "$DEX_DIR/tests/review-proof-fixture.sh"
set -e

session_id="codex-inline-handoff"
state_file="$(dx_state_file "$session_id")"
provider_file="$(dx_provider_state_file "$session_id")"
mkdir -p "$(dirname "$state_file")" "$(dirname "$provider_file")"
printf "engine=codex-plugin\nsession=%s\n" "$session_id" > "$provider_file"
printf "0\n" > "$state_file"
printf "0:%s\n" "$(date +%s)" > "$(dx_times_file "$session_id")"
generation=$(__dx_configure_inline_phase 0 "$session_id")
touch "$(dx_phase_ready_file "$session_id" 0)"

if __dx_codex_direct_phase_handoff "$session_id" 0 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 0 readiness substituted for its exact receipt" >&2
  exit 1
fi
dx_completion_write_receipt "$session_id" "$generation"
__dx_codex_direct_phase_handoff "$session_id" 0 "$state_file" "$TMP_DIR/repo"
[[ "$(cat "$state_file")" == "1" ]] || assert_at $LINENO
[[ ! -f "$(dx_phase_ready_file "$session_id" 0)" ]] || assert_at $LINENO
[[ "$(dx_phase_outcome_latest "$session_id" 0)" == "completed" ]] || assert_at $LINENO

printf "1\n" > "$state_file"
printf "%s\n" "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Exercise the direct handoff.\"],\"acceptance_criteria\":[\"Phase gates must reject missing state.\"],\"verification_requirements\":[\"Run tests/codex-inline-handoff-test.sh.\"]}" > "$(dx_review_criteria_file "$session_id")"
generation=$(dx_completion_current_generation "$session_id" lifecycle phase 1)
dx_completion_write_receipt "$session_id" "$generation"
if __dx_codex_direct_phase_handoff "$session_id" 1 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 1 advanced without its ready marker" >&2
  exit 1
fi
rotated_generation=$(dx_completion_current_generation "$session_id" lifecycle phase 1)
[[ "$rotated_generation" != "$generation" ]] || assert_at $LINENO
if dx_completion_write_receipt "$session_id" "$generation"; then
  printf "%s\n" "rejected Phase 1 generation remained writable" >&2
  exit 1
fi
rm -f "$(dx_review_criteria_file "$session_id")"
touch "$(dx_phase_ready_file "$session_id" 1)"
dx_completion_write_receipt "$session_id" "$rotated_generation"
if __dx_codex_direct_phase_handoff "$session_id" 1 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 1 advanced without approved review criteria" >&2
  exit 1
fi
generation=$(dx_completion_current_generation "$session_id" lifecycle phase 1)
printf "%s\n" "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Exercise the direct handoff.\"],\"acceptance_criteria\":[\"Phase gates must reject missing state.\"],\"verification_requirements\":[\"Run tests/codex-inline-handoff-test.sh.\"]}" > "$(dx_review_criteria_file "$session_id")"
dx_completion_write_receipt "$session_id" "$generation"
if ! __dx_codex_direct_phase_handoff "$session_id" 1 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 1 did not advance with valid approved review criteria" >&2
  exit 1
fi
[[ "$(cat "$state_file")" == "2" ]] || assert_at $LINENO
[[ "$(cut -f2 "$(dx_review_criteria_approval_file "$session_id")")" == "1" ]] || assert_at $LINENO
[[ "$(dx_phase_outcome_latest "$session_id" 1)" == "completed" ]] || assert_at $LINENO
approved_criteria_hash=$(dx_review_read_criteria_approval "$session_id")

printf "2\n" > "$state_file"
touch "$(dx_phase_ready_file "$session_id" 2)"
generation=$(dx_completion_current_generation "$session_id" lifecycle phase 2)
dx_completion_write_receipt "$session_id" "$generation"
if __dx_codex_direct_phase_handoff "$session_id" 2 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 2 advanced without a review risk selection" >&2
  exit 1
fi
printf "%s\n" "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Tamper with the direct handoff.\"],\"acceptance_criteria\":[\"Phase 2 rejects unapproved criteria.\"],\"verification_requirements\":[\"Run tests/codex-inline-handoff-test.sh.\"]}" > "$(dx_review_criteria_file "$session_id")"
generation=$(dx_completion_current_generation "$session_id" lifecycle phase 2)
dx_completion_write_receipt "$session_id" "$generation"
if __dx_codex_direct_phase_handoff "$session_id" 2 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 2 advanced with criteria changed after approval" >&2
  exit 1
fi
printf "%s\n" "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Exercise the direct handoff.\"],\"acceptance_criteria\":[\"Phase gates must reject missing state.\"],\"verification_requirements\":[\"Run tests/codex-inline-handoff-test.sh.\"]}" > "$(dx_review_criteria_file "$session_id")"
[[ "$(dx_review_read_criteria_approval "$session_id")" == "$approved_criteria_hash" ]] || assert_at $LINENO
if ! dx_review_write_selection "$session_id" complex lifecycle-agent broad-impact "$TMP_DIR/repo"; then
  printf "%s\n" "could not write the Phase 2 risk selection fixture" >&2
  exit 1
fi
generation=$(dx_completion_current_generation "$session_id" lifecycle phase 2)
dx_completion_write_receipt "$session_id" "$generation"
if ! __dx_codex_direct_phase_handoff "$session_id" 2 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 2 did not advance with valid criteria and risk selection" >&2
  exit 1
fi
[[ "$(cat "$state_file")" == "3" ]] || assert_at $LINENO
[[ "$(dx_phase_outcome_latest "$session_id" 2)" == "completed" ]] || assert_at $LINENO

printf "3\n" > "$state_file"
if __dx_codex_direct_phase_handoff "$session_id" 3 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 3 advanced without its exact receipt" >&2
  exit 1
fi

generation=$(dx_completion_current_generation "$session_id" lifecycle phase 3)
dx_completion_write_receipt "$session_id" "$generation"
receipt_fingerprint="$(dx_review_scope_fingerprint "$TMP_DIR/repo")"
policy_record="$(dx_review_policy_resolve "$TMP_DIR/repo")"
receipt_policy_binding="$(printf "%s\n" "$policy_record" | cut -f4)"
for ledger_iteration in {1..6}; do
  pass_id="direct-clean-${ledger_iteration}"
  evidence_file="$TMP_DIR/direct-clean-${ledger_iteration}.evidence.json"
  context_file="$TMP_DIR/direct-clean-${ledger_iteration}.context.md"
  dx_test_write_clean_review_proof "$session_id" "$pass_id" thorough \
    "$receipt_fingerprint" "$approved_criteria_hash" "$receipt_policy_binding" \
    "$evidence_file" "$context_file"
  dx_review_ledger_append "$session_id" "$ledger_iteration" "$pass_id" thorough \
    "$receipt_fingerprint" "$approved_criteria_hash" "$receipt_policy_binding" \
    "$evidence_file" "$context_file"
done
if ! dx_review_write_receipt "$session_id" complex 6 6 "$TMP_DIR/repo" \
  "$approved_criteria_hash" "$receipt_policy_binding"; then
  printf "%s\n" "could not write the Phase 3 receipt fixture" >&2
  exit 1
fi
review_proof_dir=$(dx_review_proof_dir "$session_id")
[[ -d "$review_proof_dir" ]] || assert_at $LINENO
if ! __dx_codex_direct_phase_handoff "$session_id" 3 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "phase 3 did not advance with a valid review receipt" >&2
  exit 1
fi
[[ "$(cat "$state_file")" == "4" ]] || assert_at $LINENO
[[ "$(dx_phase_outcome_latest "$session_id" 3)" == "completed" ]] || assert_at $LINENO
[[ ! -e "$review_proof_dir" && ! -L "$review_proof_dir" ]] || assert_at $LINENO

printf "2\n" > "$state_file"
__dx_configure_inline_phase 2 "$session_id" >/dev/null
dx_write_lifecycle_control "$session_id" jump 4 terminal "" 2 ""
__dx_codex_direct_phase_handoff "$session_id" 2 "$state_file" "$TMP_DIR/repo"
[[ "$(cat "$state_file")" == "4" ]] || assert_at $LINENO
[[ ! -f "$(dx_lifecycle_control_file "$session_id")" ]] || assert_at $LINENO
[[ "$(dx_phase_outcome_latest "$session_id" 2)" == "skipped" ]] || assert_at $LINENO
[[ "$(dx_phase_outcome_latest "$session_id" 3)" == "skipped" ]] || assert_at $LINENO

printf "2\n" > "$state_file"
__dx_configure_inline_phase 2 "$session_id" >/dev/null
touch "$(dx_active_file "$session_id")"
dx_write_lifecycle_control "$session_id" cancel "" terminal "" 2 ""
if __dx_codex_direct_phase_handoff "$session_id" 2 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "direct Codex cancel was reported as an ordinary phase handoff" >&2
  exit 1
else
  pause_status=$?
fi
[[ "$pause_status" -eq 2 ]] || assert_at $LINENO
[[ -f "$(dx_paused_file "$session_id")" ]] || assert_at $LINENO
[[ -f "$(dx_lifecycle_control_file "$session_id")" ]] || assert_at $LINENO
[[ ! -f "$(dx_active_file "$session_id")" ]] || assert_at $LINENO
'

zsh -fc '
source "$DEX_DIR/dx.sh"
set -e

session_id="codex-inline-generation-binding"
state_file="$(dx_state_file "$session_id")"
provider_file="$(dx_provider_state_file "$session_id")"
mkdir -p "$(dirname "$state_file")" "$(dirname "$provider_file")"
printf "engine=codex-plugin\nsession=%s\n" "$session_id" > "$provider_file"
printf "4\n" > "$state_file"

old_generation=$(__dx_configure_inline_phase 4 "$session_id")
current_generation=$(__dx_configure_inline_phase 4 "$session_id")
[[ "$current_generation" != "$old_generation" ]] || assert_at $LINENO
[[ ! -e "$(dx_active_file "$session_id")" \
  && ! -L "$(dx_active_file "$session_id")" ]] || assert_at $LINENO

# A direct Codex lifecycle has no Stop hook. An unrelated Claude session in
# the checkout must not be able to claim its exact completion context.
set +e
bystander_output=$(printf "%s" "{\"session_id\":\"claude-bystander\"}" | env \
  DEX_SESSION_ID="$session_id" DEX_LOOP_ACTIVE=0 \
  bash "$DEX_DIR/hooks/phase-loop.sh" 2>&1)
bystander_status=$?
set -e
[[ "$bystander_status" -eq 0 ]] || assert_at $LINENO
[[ -z "$bystander_output" ]] || assert_at $LINENO
[[ ! -e "$(dx_owner_file "$session_id")" \
  && ! -L "$(dx_owner_file "$session_id")" ]] || assert_at $LINENO
[[ "$(cat "$state_file")" == "4" ]] || assert_at $LINENO

if dx_completion_write_receipt "$session_id" "$old_generation"; then
  printf "%s\n" "same-phase retry accepted a delayed old writer" >&2
  exit 1
fi
dx_completion_write_receipt "$session_id" "$current_generation"

# The receipt binds the canonical phase contract, not only its tuple. Keep
# the same generation while corrupting each other field and prove that none
# of those configs can consume it or advance the phase.
canonical_config=$(__dx_inline_completion_config 4 "$current_generation")
for corrupt_config in \
  "4:WRONG_PROMISE:$DEX_DIR/prompts/phase-audits/4-verify.md:1:lifecycle:phase:$current_generation" \
  "4:PHASE_4_COMPLETE:/tmp/wrong-audit.md:1:lifecycle:phase:$current_generation" \
  "4:PHASE_4_COMPLETE:$DEX_DIR/prompts/phase-audits/4-verify.md:999:lifecycle:phase:$current_generation" \
  "${canonical_config}:extra"; do
  printf "%s\n" "$corrupt_config" > "$(dx_loop_config_file "$session_id")"
  if __dx_codex_direct_phase_handoff "$session_id" 4 "$state_file" "$TMP_DIR/repo"; then
    printf "%s\n" "corrupt lifecycle config authorized direct-Codex handoff" >&2
    exit 1
  fi
  [[ "$(cat "$state_file")" == "4" ]] || assert_at $LINENO
  dx_completion_receipt_valid "$session_id" lifecycle phase 4 "$current_generation" \
    || assert_at $LINENO
done
printf "%s\n" "$canonical_config" > "$(dx_loop_config_file "$session_id")"
__dx_codex_direct_phase_handoff "$session_id" 4 "$state_file" "$TMP_DIR/repo"
[[ "$(cat "$state_file")" == "5" ]] || assert_at $LINENO
if dx_completion_write_receipt "$session_id" "$current_generation"; then
  printf "%s\n" "consumed direct-Codex generation was replayable" >&2
  exit 1
fi
phase_five_generation=$(dx_completion_current_generation "$session_id" lifecycle phase 5)
set +e
__dx_configure_inline_phase 4 "$session_id" >/dev/null
stale_launch_status=$?
set -e
[[ "$stale_launch_status" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$state_file")" == "5" ]] || assert_at $LINENO
[[ "$(dx_completion_current_generation "$session_id" lifecycle phase 5)" == "$phase_five_generation" ]] || assert_at $LINENO

printf "4\n" > "$state_file"
legacy_generation=$(__dx_configure_inline_phase 4 "$session_id")
touch "$(dx_complete_file "$session_id")"
set +e
legacy_output=$(__dx_codex_direct_phase_handoff "$session_id" 4 "$state_file" "$TMP_DIR/repo" 2>&1)
legacy_status=$?
set -e
[[ "$legacy_status" -ne 0 ]] || assert_at $LINENO
[[ "$(cat "$state_file")" == "4" ]] || assert_at $LINENO
[[ ! -e "$(dx_complete_file "$session_id")" ]] || assert_at $LINENO
rotated_generation=$(dx_completion_current_generation "$session_id" lifecycle phase 4)
[[ "$rotated_generation" != "$legacy_generation" ]] || assert_at $LINENO
[[ "$legacy_output" == *"Legacy completion marker ignored"* ]] || assert_at $LINENO

wrong_context_generation=$(dx_completion_issue "$session_id" standalone dxcomplete 6)
dx_completion_write_receipt "$session_id" "$wrong_context_generation"
if __dx_codex_direct_phase_handoff "$session_id" 4 "$state_file" "$TMP_DIR/repo"; then
  printf "%s\n" "wrong purpose and phase authorized direct-Codex handoff" >&2
  exit 1
fi
[[ "$(cat "$state_file")" == "4" ]] || assert_at $LINENO
dx_completion_abandon "$session_id"
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
[[ "$wrapper_status" -eq 1 ]] || assert_at $LINENO
[[ ! -f "$TMP_DIR/provider-launched-after-pause" ]] || assert_at $LINENO
[[ -f "$(dx_paused_file "$session_id")" ]] || assert_at $LINENO
[[ "$(dx_pause_state_read "$session_id" reason)" == "manual-cancel" ]] || assert_at $LINENO
[[ ! -f "$(dx_lifecycle_control_file "$session_id")" ]] || assert_at $LINENO
[[ -f "$(dx_handoff_mode_file "$session_id")" ]] || assert_at $LINENO
'

zsh -fc '
source "$DEX_DIR/dx.sh"
set -e

export DX_PROVIDER_ENGINE=codex-plugin
for control_kind in symlink directory; do
  session_id="codex-direct-invalid-control-${control_kind}"
  state_file="$(dx_state_file "$session_id")"
  times_file="$(dx_times_file "$session_id")"
  control_file="$(dx_lifecycle_control_file "$session_id")"
  provider_marker="$TMP_DIR/provider-launched-${control_kind}"
  mkdir -p "$(dirname "$state_file")"
  printf "4\n" > "$state_file"
  __dx_configure_inline_phase 4 "$session_id" >/dev/null
  if [[ "$control_kind" == "symlink" ]]; then
    ln -s /dev/null "$control_file"
  else
    mkdir "$control_file"
  fi

  __dx_claude() {
    touch "$provider_marker"
    return 97
  }

  set +e
  __dx_run_phases_inline "repo" "$TMP_DIR/repo" "$TEST_DEFAULT_BRANCH" 4 \
    "$state_file" "$times_file" "dx --agent codex test" "in-place" \
    "$session_id" "test" > "$TMP_DIR/invalid-control-${control_kind}.out" 2>&1
  wrapper_status=$?
  set -e
  [[ "$wrapper_status" -eq 1 ]] || assert_at $LINENO
  [[ ! -e "$provider_marker" ]] || assert_at $LINENO
  [[ "$(cat "$state_file")" == "4" ]] || assert_at $LINENO
  grep -q "unreadable or invalid lifecycle control receipt" \
    "$TMP_DIR/invalid-control-${control_kind}.out"
  if [[ "$control_kind" == "symlink" ]]; then
    [[ -L "$control_file" ]] || assert_at $LINENO
    rm -f "$control_file"
  else
    [[ -d "$control_file" ]] || assert_at $LINENO
    rmdir "$control_file"
  fi
  dx_completion_cleanup "$session_id"
  rm -f "$(dx_loop_config_file "$session_id")" \
    "$(dx_handoff_mode_file "$session_id")"
done
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
export DX_PROVIDER_ENGINE=codex-plugin
old_generation=$(__dx_configure_inline_phase 6 "$session_id")
dx_completion_write_receipt "$session_id" "$old_generation"

__dx_claude() {
  local expect_context=0 context_file="" arg command_line receipt_session receipt_generation
  for arg in "$@"; do
    if [[ "$expect_context" -eq 1 ]]; then
      context_file="$arg"
      expect_context=0
    elif [[ "$arg" == "--append-system-prompt-file" ]]; then
      expect_context=1
    fi
  done
  command_line=$(grep -Eo "bash \"[\$]DEX_DIR/bin/complete-receipt\\.sh\" \"[^\"]+\" \"[0-9a-f]{32}\"" "$context_file")
  [[ "$(printf "%s\n" "$command_line" | wc -l | tr -d " ")" == "1" ]] || assert_at $LINENO
  receipt_session=$(printf "%s\n" "$command_line" | cut -d\" -f4)
  receipt_generation=$(printf "%s\n" "$command_line" | cut -d\" -f6)
  [[ "$receipt_session" == "$session_id" ]] || assert_at $LINENO
  [[ "$receipt_generation" != "$old_generation" ]] || assert_at $LINENO
  bash "$DEX_DIR/bin/complete-receipt.sh" "$receipt_session" "$receipt_generation"
}

__dx_run_phases_inline "repo" "$TMP_DIR/repo" "$TEST_DEFAULT_BRANCH" 6 "$state_file" "$times_file" "dx --agent codex test" "in-place" "$session_id" "test"
[[ "$(cat "$state_file")" == "7" ]] || assert_at $LINENO
[[ "$(dx_phase_outcome_latest "$session_id" 6)" == "completed" ]] || assert_at $LINENO
'

# The terminal proof is not a success signal until the publishing transition
# lock is released. A one-shot release fault must roll the phase back, revoke
# the consumed generation, and leave an explicit resume path without emitting
# terminal telemetry.
zsh -fc '
source "$DEX_DIR/dx.sh"
set -e

session_id="codex-terminal-release-failure"
state_file="$(dx_state_file "$session_id")"
provider_file="$(dx_provider_state_file "$session_id")"
printf "engine=codex-plugin\nsession=%s\n" "$session_id" > "$provider_file"
printf "6\n" > "$state_file"
generation=$(__dx_configure_inline_phase 6 "$session_id")
dx_completion_write_receipt "$session_id" "$generation"
functions[__test_real_control_lock_release]="${functions[dx_lifecycle_control_lock_release]}"
release_calls=0
dx_lifecycle_control_lock_release() {
  release_calls=$((release_calls + 1))
  if [[ "$release_calls" -eq 1 ]]; then
    return 1
  fi
  __test_real_control_lock_release "$@"
}
dx_event_emit_for_session() {
  [[ "${2:-}" != "run.completed" ]] || touch "$TMP_DIR/terminal-release-completed"
  return 0
}

set +e
__dx_codex_direct_phase_handoff "$session_id" 6 "$state_file" "$TMP_DIR/repo" \
  > "$TMP_DIR/terminal-release.out" 2>&1
handoff_status=$?
set -e
[[ "$handoff_status" -ne 0 ]] || assert_at $LINENO
[[ "$(dx_lifecycle_phase_state "$session_id")" == "6" ]] || assert_at $LINENO
[[ ! -e "$(dx_lifecycle_terminal_commit_file "$session_id")" \
  && ! -L "$(dx_lifecycle_terminal_commit_file "$session_id")" ]] || assert_at $LINENO
dx_lifecycle_pause_context_state "$session_id" || assert_at $LINENO
[[ "$(dx_pause_state_read "$session_id" reason)" == "completion-lock-release" ]] \
  || assert_at $LINENO
[[ ! -e "$(dx_completion_expectation_file "$session_id")" \
  && ! -L "$(dx_completion_expectation_file "$session_id")" ]] || assert_at $LINENO
[[ ! -e "$(dx_lifecycle_control_lock_dir "$session_id")" \
  && ! -L "$(dx_lifecycle_control_lock_dir "$session_id")" ]] || assert_at $LINENO
[[ ! -e "$TMP_DIR/terminal-release-completed" ]] || assert_at $LINENO

resume_record=$(dx_lifecycle_resume_completion_context "$session_id")
IFS=$'"'"'\t'"'"' read -r resume_phase resume_generation resume_mode resume_purpose \
  <<< "$resume_record"
[[ "$resume_phase" == "6" && "$resume_mode" == "lifecycle" \
  && "$resume_purpose" == "phase" ]] || assert_at $LINENO
[[ "$resume_generation" =~ ^[0-9a-f]{32}$ \
  && "$resume_generation" != "$generation" ]] || assert_at $LINENO
[[ ! -e "$(dx_lifecycle_terminal_commit_file "$session_id")" ]] || assert_at $LINENO
'

# Exercise terminal-proof retirement through real lifecycle entry points, not
# only the low-level issuance helper. A proof from an earlier Phase 7 must be
# physically gone before configuration, a backward human transition, or
# session reinitialization can mint new authorization.
zsh -fc '
source "$DEX_DIR/dx.sh"
set -e

seed_terminal_proof() {
  local seed_session="$1" seed_authority="0123456789abcdef0123456789abcdef"
  dx_lifecycle_atomic_write "$(dx_state_file "$seed_session")" 7
  dx_lifecycle_control_lock_acquire "$seed_session"
  dx_lifecycle_terminal_commit_publish_unlocked "$seed_session" "$seed_authority"
  dx_lifecycle_control_lock_release "$seed_session"
  dx_lifecycle_terminal_commit_valid "$seed_session" || assert_at $LINENO
}

configure_session="codex-terminal-replay-configure"
seed_terminal_proof "$configure_session"
dx_lifecycle_atomic_write "$(dx_state_file "$configure_session")" 4
configure_generation=$(__dx_configure_inline_phase 4 "$configure_session")
[[ "$configure_generation" =~ ^[0-9a-f]{32}$ ]] || assert_at $LINENO
[[ ! -e "$(dx_lifecycle_terminal_commit_file "$configure_session")" \
  && ! -L "$(dx_lifecycle_terminal_commit_file "$configure_session")" ]] || assert_at $LINENO
dx_completion_abandon "$configure_session"

backward_session="codex-terminal-replay-backward"
seed_terminal_proof "$backward_session"
dx_lifecycle_atomic_write "$(dx_state_file "$backward_session")" 5
printf "engine=codex-plugin\nsession=%s\n" "$backward_session" \
  > "$(dx_provider_state_file "$backward_session")"
dx_write_lifecycle_control "$backward_session" jump 4 terminal "" 5 ""
__dx_codex_direct_phase_handoff "$backward_session" 5 \
  "$(dx_state_file "$backward_session")" "$TMP_DIR/repo"
[[ "$(dx_lifecycle_phase_state "$backward_session")" == "4" ]] || assert_at $LINENO
[[ ! -e "$(dx_lifecycle_terminal_commit_file "$backward_session")" \
  && ! -L "$(dx_lifecycle_terminal_commit_file "$backward_session")" ]] || assert_at $LINENO
[[ "$(dx_completion_current_generation "$backward_session" lifecycle phase 4)" \
  =~ ^[0-9a-f]{32}$ ]] || assert_at $LINENO
dx_completion_abandon "$backward_session"

reinit_session="codex-terminal-replay-reinit"
seed_terminal_proof "$reinit_session"
dx_cleanup_session "$reinit_session"
[[ ! -e "$(dx_lifecycle_terminal_commit_file "$reinit_session")" \
  && ! -L "$(dx_lifecycle_terminal_commit_file "$reinit_session")" ]] || assert_at $LINENO
dx_lifecycle_atomic_write "$(dx_state_file "$reinit_session")" 0
reinit_generation=$(__dx_configure_inline_phase 0 "$reinit_session")
[[ "$reinit_generation" =~ ^[0-9a-f]{32}$ ]] || assert_at $LINENO
[[ ! -e "$(dx_lifecycle_terminal_commit_file "$reinit_session")" ]] || assert_at $LINENO
dx_completion_abandon "$reinit_session"
dx_lifecycle_atomic_write "$(dx_state_file "$reinit_session")" 7
if dx_lifecycle_terminal_commit_valid "$reinit_session"; then
  printf "%s\n" "a cleaned terminal proof authorized a reinitialized lifecycle" >&2
  exit 1
fi
'

zsh -fc '
source "$DEX_DIR/dx.sh"
set -e

export DX_PROVIDER_ENGINE=codex-plugin
session_id="codex-direct-context-marker"
generation="0123456789abcdef0123456789abcdef"
ctx_file="$(__dx_build_system_context "repo" 4 "$session_id" "$TMP_DIR/repo" "worktree" "test" "$generation")"
grep -q "Direct Codex Phase Completion" "$ctx_file"
grep -Fq "bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"$session_id\" \"$generation\"" "$ctx_file"
if grep -q "dx_complete_file" "$ctx_file"; then
  printf "%s\n" "direct context still exposes the legacy completion marker" >&2
  exit 1
fi

ctx_file="$(__dx_build_system_context "repo" 6 "$session_id" "$TMP_DIR/repo" "worktree" "test" "$generation")"
grep -Fq "bash \"\$DEX_DIR/bin/escalate.sh\" \"$session_id\" \"$generation\"" "$ctx_file"
if grep -Fq "bash \"\$DEX_DIR/bin/control.sh\" pause" "$ctx_file"; then
  printf "%s\n" "direct context still asks the agent to impersonate human control" >&2
  exit 1
fi
if grep -q "dx_paused_file" "$ctx_file"; then
  printf "%s\n" "direct context requires a snapshotted pause helper" >&2
  exit 1
fi

ctx_file="$(__dx_build_system_context "repo" 2 "$session_id" "$TMP_DIR/repo" "worktree" "test" "$generation")"
grep -q "Direct Codex Phase Completion" "$ctx_file"
grep -q "normal Phase 2 readiness gate" "$ctx_file"
grep -Fq "bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"$session_id\" \"$generation\"" "$ctx_file"
grep -q "Direct Human Control" "$ctx_file"
grep -q "bin/control.sh" "$ctx_file"
'

zsh -fc '
source "$DEX_DIR/dx.sh"
set -e

phase7_session="codex-configure-phase7-race"
printf "7\n" > "$(dx_state_file "$phase7_session")"
set +e
__dx_configure_inline_phase 6 "$phase7_session" >/dev/null
phase7_rc=$?
set -e
[[ "$phase7_rc" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$phase7_session")")" == "7" ]] || assert_at $LINENO
[[ ! -e "$(dx_completion_expectation_file "$phase7_session")" ]] || assert_at $LINENO
[[ ! -e "$(dx_active_file "$phase7_session")" ]] || assert_at $LINENO

release_session="codex-configure-release-failure"
printf "4\n" > "$(dx_state_file "$release_session")"
dx_lifecycle_control_lock_release() { return 1; }
set +e
__dx_configure_inline_phase 4 "$release_session" >/dev/null
release_rc=$?
set -e
[[ "$release_rc" -eq 1 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$release_session")")" == "4" ]] || assert_at $LINENO
[[ ! -e "$(dx_completion_expectation_file "$release_session")" ]] || assert_at $LINENO
[[ ! -e "$(dx_active_file "$release_session")" ]] || assert_at $LINENO
[[ ! -e "$(dx_loop_config_file "$release_session")" ]] || assert_at $LINENO
[[ ! -e "$(dx_handoff_mode_file "$release_session")" ]] || assert_at $LINENO
'

printf 'codex inline handoff test passed\n'

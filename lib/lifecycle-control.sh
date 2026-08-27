#!/usr/bin/env bash
# shellcheck shell=bash
# Direct-human lifecycle intervention state shared by hooks and CLI sessions.

dx_lifecycle_session_id_valid() {
  local session_id="${1:-}"
  if command -v dx_session_id_valid >/dev/null 2>&1; then
    dx_session_id_valid "$session_id"
    return
  fi
  [[ -n "$session_id" && ${#session_id} -le 180 ]] || return 1
  [[ "$session_id" != "." && "$session_id" != ".." ]] || return 1
  [[ "$session_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# One phase table for every consumer. The Stop hook, the UserPromptSubmit
# hook, dx control, and dx.sh each carried a private copy that had already
# drifted (some knew about phase 7, some did not).

# dx_lifecycle_phase_label <phase>
dx_lifecycle_phase_label() {
  case "${1:-}" in
    0) printf '%s\n' "Setup" ;;
    1) printf '%s\n' "Plan" ;;
    2) printf '%s\n' "Implement" ;;
    3) printf '%s\n' "Review" ;;
    4) printf '%s\n' "Verify & Commit" ;;
    5) printf '%s\n' "PR" ;;
    6) printf '%s\n' "Complete" ;;
    7) printf '%s\n' "Lifecycle complete" ;;
    *) printf '%s\n' "Unknown" ;;
  esac
}

# dx_lifecycle_phase_promise <phase>
dx_lifecycle_phase_promise() {
  case "${1:-}" in
    0) printf '%s\n' "PHASE_0_COMPLETE" ;;
    1) printf '%s\n' "PHASE_1_COMPLETE" ;;
    2) printf '%s\n' "PHASE_2_COMPLETE" ;;
    3) printf '%s\n' "PHASE_3_COMPLETE" ;;
    4) printf '%s\n' "PHASE_4_COMPLETE" ;;
    5) printf '%s\n' "PHASE_5_COMPLETE" ;;
    *) printf '%s\n' "DEX_TICKET_COMPLETE" ;;
  esac
}

# dx_lifecycle_phase_audit_basename <phase> — prompts/phase-audits/<name>.md
dx_lifecycle_phase_audit_basename() {
  case "${1:-}" in
    0) printf '%s\n' "0-setup" ;;
    1) printf '%s\n' "1-plan" ;;
    2) printf '%s\n' "2-implement" ;;
    3) printf '%s\n' "3-review-loop" ;;
    4) printf '%s\n' "4-verify" ;;
    5) printf '%s\n' "5-pr" ;;
    6) printf '%s\n' "6-complete" ;;
    *) printf '%s\n' "" ;;
  esac
}

dx_lifecycle_control_actor_label() {
  if [[ "${1:-}" == "agent" ]]; then
    printf '%s\n' "agent override"
  else
    printf '%s\n' "direct human instruction"
  fi
}

# dx_lifecycle_phase_min_audits <phase>
# Honors the DEX_PHASE_<n>_MIN_AUDITS override; defaults to one audit pass.
dx_lifecycle_phase_min_audits() {
  local phase="${1:-}" env_name value session_id override_value
  [[ "$phase" =~ ^[0-9]+$ ]] || phase=""
  env_name="DEX_PHASE_${phase}_MIN_AUDITS"
  value="$(printenv "$env_name" 2>/dev/null || true)"
  if [[ -z "$value" && -n "$phase" ]]; then
    # An unexported override set in the caller's interactive shell (a plain
    # DEX_PHASE_2_MIN_AUDITS=5 in .zshrc) is invisible to printenv; read it
    # indirectly. env_name is validated digits-only above, so the eval cannot
    # expand anything user-controlled.
    eval "value=\${${env_name}:-}"
  fi
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    :
  else
    value="1"
  fi
  session_id="${DEX_SESSION_ID:-}"
  if dx_lifecycle_session_id_valid "$session_id"; then
    override_value=$(dx_override_effective "$session_id" phase.min-audits \
      "$value" "$phase") || return 1
    value="$override_value"
  fi
  printf '%s\n' "$value"
}

# dx_lifecycle_detach <session_id> <reason> <source>
# The shared detach sequence: record why, ask a running Phase 3 review child
# to stop, mark the pause, and drop the activation/completion/iteration
# markers so the loop cannot re-enter. Completion authorization is abandoned
# first, so a delayed writer cannot become valid after resume. The child-cancel
# request applies to every detach deliberately — a detaching session must not
# leave an orphan review wave editing files — including the one historical site
# that skipped it.
dx_lifecycle_detach() {
  local session_id="$1" reason="$2" detach_source="$3" revoke_result=0
  local acquired_here=0
  dx_lifecycle_session_id_valid "$session_id" || return 1
  if ! __dx_lifecycle_control_lock_owned "$session_id"; then
    dx_lifecycle_control_lock_acquire "$session_id" || return 1
    acquired_here=1
  fi
  if ! __dx_lifecycle_cleanup_barrier_unlocked "$session_id"; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      >/dev/null 2>&1 || true
    return 1
  fi
  dx_write_pause_state "$session_id" "$reason" "$detach_source" 2>/dev/null \
    || revoke_result=1
  if [[ -e "$(dx_phase_busy_file "$session_id" 3)" \
    || -L "$(dx_phase_busy_file "$session_id" 3)" ]]; then
    dx_phase_busy_request_cancel "$session_id" 3 2>/dev/null \
      || revoke_result=1
  fi
  if ! dx_completion_abandon "$session_id" 2>/dev/null; then
    __dx_completion_recover_cleanup "$session_id" 2>/dev/null || revoke_result=1
  fi
  if ! dx_lifecycle_atomic_write "$(dx_paused_file "$session_id")" paused; then
    revoke_result=1
  fi
  rm -f "$(dx_active_file "$session_id")" \
    "$(dx_loop_file "$session_id")" 2>/dev/null || revoke_result=1
  if [[ "$revoke_result" -ne 0 ]]; then
    # An unhandled failure under `set -e` must not strand a caller-held control
    # lock. Release is ownership-checked and is a no-op for unlocked callers.
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
  elif [[ "$acquired_here" -eq 1 ]] \
    && ! dx_lifecycle_control_lock_release_checked "$session_id"; then
    revoke_result=1
  fi
  return "$revoke_result"
}

# Acquire the lifecycle transition lock and leave the current automation inert.
# This is for system-owned pauses; human/agent controls have their own receipt path.
dx_lifecycle_pause() {
  local session_id="$1" reason="$2" pause_source="$3" pause_rc=0
  dx_lifecycle_session_id_valid "$session_id" || return 1
  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  dx_lifecycle_detach "$session_id" "$reason" "$pause_source" || pause_rc=1
  if [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" ]] \
    && ! dx_lifecycle_control_lock_release "$session_id"; then
    dx_lifecycle_completion_brake "$session_id" "${reason}-lock-release" \
      "$pause_source" 2>/dev/null || true
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
    pause_rc=1
  fi
  return "$pause_rc"
}

dx_lifecycle_control_file() {
  dx_lifecycle_session_id_valid "$1" || return 1
  printf '%s/%s.control\n' "$DX_LOOP_DIR" "$1"
}

dx_lifecycle_control_history_file() {
  dx_lifecycle_session_id_valid "$1" || return 1
  printf '%s/%s.interventions\n' "$DX_STATE_DIR" "$1"
}

dx_lifecycle_control_lock_dir() {
  dx_lifecycle_session_id_valid "$1" || return 1
  printf '%s/%s.control-lock\n' "$DX_LOOP_DIR" "$1"
}

dx_lifecycle_human_complete_file() {
  dx_lifecycle_session_id_valid "$1" || return 1
  printf '%s/%s.human-complete\n' "$DX_STATE_DIR" "$1"
}

dx_lifecycle_human_complete_valid() {
  [[ $# -eq 1 ]] || return 1
  local completion_raw=""
  completion_raw=$(dx_lifecycle_trusted_file_read \
    "$(dx_lifecycle_human_complete_file "$1")" 64) || return 1
  [[ "$completion_raw" == "human-complete" ]]
}

dx_lifecycle_terminal_commit_file() {
  dx_lifecycle_session_id_valid "$1" || return 1
  printf '%s/%s.terminal-commit\n' "$DX_STATE_DIR" "$1"
}

dx_lifecycle_terminal_commit_publish_unlocked() {
  [[ $# -eq 2 ]] || return 1
  local session_id="$1" authority="$2" transition_token
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" \
    && -n "${DX_LIFECYCLE_CONTROL_LOCK_TOKEN:-}" ]] || return 1
  transition_token="$DX_LIFECYCLE_CONTROL_LOCK_TOKEN"
  [[ "$transition_token" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] || return 1
  [[ "$authority" =~ ^([0-9a-f]{32}|[0-9]+-[0-9]+-[0-9]+)$ ]] || return 1
  [[ "$(dx_lifecycle_phase_state "$session_id" 2>/dev/null || true)" == "7" ]] \
    || return 1
  dx_lifecycle_atomic_write "$(dx_lifecycle_terminal_commit_file "$session_id")" \
    "version=1"$'\n'"phase=7"$'\n'"transition_token=${transition_token}"$'\n'"authority=${authority}"
}

__dx_lifecycle_terminal_commit_proof_valid_unlocked() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" terminal_raw="" line_one line_two line_three line_four
  local remaining terminal_file human_file
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" \
    && -n "${DX_LIFECYCLE_CONTROL_LOCK_TOKEN:-}" ]] || return 1
  terminal_file=$(dx_lifecycle_terminal_commit_file "$session_id")
  terminal_raw=$(dx_lifecycle_trusted_file_read "$terminal_file" 512) || return 1
  line_one="${terminal_raw%%$'\n'*}"
  remaining="${terminal_raw#*$'\n'}"
  [[ "$remaining" != "$terminal_raw" ]] || return 1
  line_two="${remaining%%$'\n'*}"
  remaining="${remaining#*$'\n'}"
  line_three="${remaining%%$'\n'*}"
  line_four="${remaining#*$'\n'}"
  [[ "$line_one" == "version=1" && "$line_two" == "phase=7" \
    && "$line_three" =~ ^transition_token=[0-9]+-[0-9]+-[0-9]+$ \
    && "$line_four" =~ ^authority=([0-9a-f]{32}|[0-9]+-[0-9]+-[0-9]+)$ \
    && "$line_four" != *$'\n'* ]] || return 1
  [[ "$(dx_lifecycle_phase_state "$session_id" 2>/dev/null || true)" == "7" ]] \
    || return 1

  human_file=$(dx_lifecycle_human_complete_file "$session_id")
  if [[ -e "$human_file" || -L "$human_file" ]]; then
    dx_lifecycle_human_complete_valid "$session_id" || return 1
  fi
  return 0
}

__dx_lifecycle_terminal_commit_valid_unlocked() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" live_file
  __dx_lifecycle_terminal_commit_proof_valid_unlocked "$session_id" \
    || return 1
  for live_file in \
    "$(dx_lifecycle_control_file "$session_id")" \
    "$(dx_paused_file "$session_id")" \
    "$(dx_pause_state_file "$session_id")" \
    "$(dx_active_file "$session_id")" \
    "$(dx_owner_file "$session_id")" \
    "$(dx_loop_config_file "$session_id")" \
    "$(dx_handoff_mode_file "$session_id")" \
    "$(dx_completion_expectation_file "$session_id")" \
    "$(dx_phase_busy_file "$session_id" 3)" \
    "$(dx_phase_busy_cancel_file "$session_id" 3)" \
    "$(dx_phase_busy_quiesced_file "$session_id" 3)"; do
    [[ ! -e "$live_file" && ! -L "$live_file" ]] || return 1
  done
  return 0
}

# Older Dex versions could validate completion context before recognizing
# Phase 7 and add this exact pause to an otherwise valid terminal transaction.
# Repair only that known artifact, restoring it if another invariant is broken.
dx_lifecycle_terminal_invalid_context_repair_unlocked() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" paused_file pause_file paused_raw="" pause_raw=""
  dx_lifecycle_session_id_valid "$session_id" || return 1
  __dx_lifecycle_terminal_commit_proof_valid_unlocked "$session_id" \
    || return 1
  paused_file=$(dx_paused_file "$session_id")
  pause_file=$(dx_pause_state_file "$session_id")
  paused_raw=$(dx_lifecycle_trusted_file_read "$paused_file" 64) || return 1
  pause_raw=$(dx_lifecycle_trusted_file_read "$pause_file" 512) || return 1
  [[ "$paused_raw" == "paused" \
    && "$pause_raw" == "reason=invalid-completion-context"$'\n'"source=phase-loop" ]] \
    || return 1

  command rm -f "$paused_file" "$pause_file" 2>/dev/null || return 1
  if __dx_lifecycle_terminal_commit_valid_unlocked "$session_id"; then
    return 0
  fi

  dx_lifecycle_atomic_write "$pause_file" "$pause_raw" 2>/dev/null || true
  dx_lifecycle_atomic_write "$paused_file" "$paused_raw" 2>/dev/null || true
  return 1
}

# A terminal proof becomes authoritative only after its publishing transition
# lock was released. Reacquiring the same session lock linearizes validation
# with later pause, resume, and human-control writes.
dx_lifecycle_terminal_commit_valid() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" validation_rc=0
  dx_lifecycle_session_id_valid "$session_id" || return 1
  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  __dx_lifecycle_terminal_commit_valid_unlocked "$session_id" || validation_rc=1
  if ! dx_lifecycle_control_lock_release "$session_id"; then
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
    return 1
  fi
  return "$validation_rc"
}

# A terminal proof belongs only to the completed lifecycle generation. Every
# new Phase 0-6 authorization retires both terminal artifacts before it mints a
# receipt, while the transition lock excludes a concurrent completion commit.
dx_lifecycle_terminal_proofs_invalidate_unlocked() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" terminal_file human_file
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" \
    && -n "${DX_LIFECYCLE_CONTROL_LOCK_TOKEN:-}" ]] || return 1
  terminal_file=$(dx_lifecycle_terminal_commit_file "$session_id")
  human_file=$(dx_lifecycle_human_complete_file "$session_id")
  command rm -f "$terminal_file" "$human_file" 2>/dev/null || return 1
  [[ ! -e "$terminal_file" && ! -L "$terminal_file" \
    && ! -e "$human_file" && ! -L "$human_file" ]]
}

__dx_lifecycle_control_lock_owned() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" owner_file owner_raw owner_pid owner_token
  [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" \
    && -n "${DX_LIFECYCLE_CONTROL_LOCK_TOKEN:-}" ]] || return 1
  owner_file="$(dx_lifecycle_control_lock_dir "$session_id")/owner"
  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 1
  owner_raw=$(cat "$owner_file" 2>/dev/null) || return 1
  owner_pid="${owner_raw%%$'\t'*}"
  owner_token="${owner_raw##*$'\t'}"
  [[ "$owner_pid" == "$$" \
    && "$owner_token" == "$DX_LIFECYCLE_CONTROL_LOCK_TOKEN" ]]
}

# Lifecycle writers call this only while holding the session transition lock.
# A malformed journal is also a brake: repair must not race fresh automation.
__dx_lifecycle_cleanup_barrier_unlocked() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" journal_rc=0
  __dx_lifecycle_control_lock_owned "$session_id" || return 1
  dx_session_cleanup_journal_state "$session_id" || journal_rc=$?
  [[ "$journal_rc" -eq 1 ]]
}

# Turn a failed terminal transaction back into a resumable, inert Phase 6.
# The retained config identifies the exact lifecycle context, but its
# expectation is abandoned; an explicit resume always creates a fresh one.
dx_lifecycle_terminal_failure_rollback_unlocked() {
  [[ $# -eq 3 ]] || return 1
  local session_id="$1" reason="$2" rollback_source="$3"
  local generation="" config_line="" rollback_rc=0
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$reason" =~ ^[A-Za-z0-9._-]+$ \
    && "$rollback_source" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  __dx_lifecycle_control_lock_owned "$session_id" || return 1
  __dx_lifecycle_cleanup_barrier_unlocked "$session_id" || return 1
  [[ "$(dx_lifecycle_phase_state "$session_id" 2>/dev/null || true)" == "7" ]] \
    || return 1

  dx_lifecycle_terminal_proofs_invalidate_unlocked "$session_id" \
    || rollback_rc=1
  dx_lifecycle_atomic_write "$(dx_state_file "$session_id")" 6 \
    || rollback_rc=1
  generation=$(dx_lifecycle_completion_issue_unlocked \
    "$session_id" lifecycle phase 6 2>/dev/null || true)
  if [[ "$generation" =~ ^[0-9a-f]{32}$ ]]; then
    config_line=$(dx_completion_context_config lifecycle phase 6 "$generation" \
      2>/dev/null || true)
  fi
  if [[ -z "$config_line" ]] \
    || ! dx_lifecycle_atomic_write "$(dx_loop_config_file "$session_id")" \
      "$config_line"; then
    rollback_rc=1
  fi
  dx_completion_abandon "$session_id" 2>/dev/null \
    || __dx_completion_recover_cleanup "$session_id" 2>/dev/null \
    || rollback_rc=1
  dx_clear_lifecycle_control_unlocked "$session_id"
  rm -f "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" \
    "$(dx_handoff_mode_file "$session_id")" 2>/dev/null || rollback_rc=1
  dx_phase_outcome_record "$session_id" 6 invalidated "$rollback_source" \
    "rollback-$(date +%s)-$$-${RANDOM}" "$reason" 2>/dev/null \
    || rollback_rc=1
  dx_write_pause_state "$session_id" "$reason" "$rollback_source" \
    2>/dev/null || rollback_rc=1
  dx_lifecycle_atomic_write "$(dx_paused_file "$session_id")" paused \
    2>/dev/null || rollback_rc=1
  return "$rollback_rc"
}

dx_lifecycle_terminal_failure_rollback() {
  [[ $# -eq 3 ]] || return 1
  local session_id="$1" reason="$2" rollback_source="$3" rollback_rc=0
  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  dx_lifecycle_terminal_failure_rollback_unlocked \
    "$session_id" "$reason" "$rollback_source" || rollback_rc=1
  if ! dx_lifecycle_control_lock_release "$session_id"; then
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
    rollback_rc=1
  fi
  return "$rollback_rc"
}

# Prepare a dead lifecycle for a new provider without authorizing that provider.
# The caller owns both the checkout review lock and this session's transition
# lock. The launcher creates fresh completion authorization immediately before
# it crosses the provider boundary.
dx_lifecycle_relaunch_prepare_unlocked() {
  [[ $# -eq 2 ]] || return 1
  local session_id="$1" expected_phase="$2" phase="" phase_rc=0 pause_rc=0
  local pause_record="" pause_record_rc=0 pause_reason="" pause_source=""
  local control_file busy_file busy_cancel_file busy_quiesced_file busy_token=""
  local cleanup_file rollback_generation
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$expected_phase" =~ ^[0-7]$ ]] || return 1
  __dx_lifecycle_control_lock_owned "$session_id" || return 1
  __dx_lifecycle_cleanup_barrier_unlocked "$session_id" || return 1

  phase=$(dx_lifecycle_phase_state "$session_id" 2>/dev/null) || phase_rc=$?
  [[ "$phase_rc" -eq 0 && "$phase" == "$expected_phase" ]] || return 1

  control_file=$(dx_lifecycle_control_file "$session_id")
  [[ ! -e "$control_file" && ! -L "$control_file" ]] || return 1

  dx_lifecycle_pause_context_state "$session_id" || pause_rc=$?
  [[ "$pause_rc" -ne 2 ]] || return 1
  pause_record=$(dx_lifecycle_pause_metadata_record "$session_id" \
    2>/dev/null) || pause_record_rc=$?
  [[ "$pause_record_rc" -ne 2 ]] || return 1
  if [[ "$pause_record_rc" -eq 0 ]]; then
    IFS=$'\t' read -r pause_reason pause_source <<EOF
$pause_record
EOF
    : "$pause_source"
    case "$pause_reason" in
      assessment-selection-revocation-failed|receipt_revocation_failed)
        return 1
        ;;
    esac
  fi

  busy_file=$(dx_phase_busy_file "$session_id" 3)
  busy_cancel_file=$(dx_phase_busy_cancel_file "$session_id" 3)
  busy_quiesced_file=$(dx_phase_busy_quiesced_file "$session_id" 3)
  if [[ -e "$busy_file" || -L "$busy_file" ]]; then
    dx_phase_busy_quiesced "$session_id" 3 || return 1
    busy_token=$(dx_phase_busy_token "$session_id" 3)
    [[ -n "$busy_token" ]] || return 1
    dx_phase_busy_finish "$session_id" 3 "$busy_token" || return 1
  elif [[ -e "$busy_cancel_file" || -L "$busy_cancel_file" \
    || -e "$busy_quiesced_file" || -L "$busy_quiesced_file" ]]; then
    return 1
  fi

  if [[ "$phase" == "7" ]]; then
    __dx_lifecycle_terminal_commit_valid_unlocked "$session_id" && return 1
    __dx_lifecycle_terminal_failure_pause_valid "$session_id" || return 1
    dx_lifecycle_terminal_proofs_invalidate_unlocked "$session_id" || return 1
  else
    dx_lifecycle_terminal_proofs_invalidate_unlocked "$session_id" || return 1
  fi

  dx_completion_abandon "$session_id" 2>/dev/null \
    || __dx_completion_recover_cleanup "$session_id" 2>/dev/null \
    || return 1
  for cleanup_file in \
    "$(dx_active_file "$session_id")" \
    "$(dx_owner_file "$session_id")" \
    "$(dx_loop_config_file "$session_id")" \
    "$(dx_handoff_mode_file "$session_id")" \
    "$(dx_complete_file "$session_id")" \
    "$(dx_loop_file "$session_id")" \
    "$(dx_findings_file "$session_id")" \
    "$(dx_watch_pause_file "$session_id")"; do
    command rm -f "$cleanup_file" 2>/dev/null || return 1
    [[ ! -e "$cleanup_file" && ! -L "$cleanup_file" ]] || return 1
  done
  if [[ "$phase" == "7" ]]; then
    dx_lifecycle_atomic_write "$(dx_state_file "$session_id")" 6 || return 1
    rollback_generation="relaunch-$(date +%s)-$$-${RANDOM}"
    dx_phase_outcome_record "$session_id" 6 invalidated lifecycle-control \
      "$rollback_generation" terminal-proof-invalid 2>/dev/null || return 1
    phase=6
  fi
  dx_lifecycle_pause_clear_unlocked "$session_id" || return 1
  printf '%s\n' "$phase"
}

__dx_lifecycle_terminal_failure_pause_valid() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" metadata_raw="" reason_line source_line
  dx_lifecycle_pause_context_state "$session_id" || return 1
  metadata_raw=$(dx_lifecycle_trusted_file_read \
    "$(dx_pause_state_file "$session_id")" 1024) || return 1
  reason_line="${metadata_raw%%$'\n'*}"
  source_line="${metadata_raw#*$'\n'}"
  case "${reason_line#reason=}" in
    completion-commit-failed|terminal-proof-failed|terminal-proof-missing|\
    terminal-proof-invalid|\
    completion-lock-release|human-terminal-proof-failed|\
    human-terminal-commit-failed) ;;
    *) return 1 ;;
  esac
  [[ "$source_line" =~ ^source=(phase-loop|direct-codex|lifecycle-control)$ ]]
}

# Issue completion state while it is serialized with lifecycle transitions.
# Standalone and child contexts have no terminal proof to retire; lifecycle
# phases must prove old completion state is gone before any new generation is
# observable.
dx_lifecycle_completion_issue_unlocked() {
  [[ $# -eq 4 ]] || return 1
  local session_id="$1" mode="$2" purpose="$3" phase="$4"
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" \
    && -n "${DX_LIFECYCLE_CONTROL_LOCK_TOKEN:-}" ]] || return 1
  if [[ "${mode}:${purpose}:${phase}" == lifecycle:phase:[0-6] ]]; then
    dx_lifecycle_terminal_proofs_invalidate_unlocked "$session_id" || return 1
  fi
  dx_completion_issue "$session_id" "$mode" "$purpose" "$phase"
}

dx_lifecycle_atomic_write() {
  dx_session_private_atomic_write "$@"
}

# Read a short lifecycle state file only when it is a current-user 0600 regular
# file that stayed unchanged throughout the read. Return 1 when absent and 2
# when an inode exists but cannot be trusted.
dx_lifecycle_trusted_file_read() {
  dx_session_trusted_file_read "$@"
}

# Return the authoritative numeric lifecycle phase from one trusted private
# file. Missing state is distinct from an unsafe or malformed inode so callers
# can initialize only the former.
dx_lifecycle_phase_state() {
  [[ $# -eq 1 ]] || return 2
  local session_id="$1" phase_raw="" phase_rc=0
  dx_lifecycle_session_id_valid "$session_id" || return 2
  phase_raw=$(dx_lifecycle_trusted_file_read \
    "$(dx_state_file "$session_id")" 32) || phase_rc=$?
  [[ "$phase_rc" -eq 0 ]] || return "$phase_rc"
  [[ "$phase_raw" =~ ^[0-7]$ ]] || return 2
  printf '%s\n' "$phase_raw"
}

# Return 0 for the one trusted paused marker, 1 when absent, and 2 for any
# malformed, unsafe, or unreadable marker.
dx_lifecycle_paused_state() {
  [[ $# -eq 1 ]] || return 2
  local session_id="$1" paused_raw="" paused_rc=0
  dx_lifecycle_session_id_valid "$session_id" || return 2
  paused_raw=$(dx_lifecycle_trusted_file_read \
    "$(dx_paused_file "$session_id")" 32) || paused_rc=$?
  [[ "$paused_rc" -eq 0 ]] || return "$paused_rc"
  [[ "$paused_raw" == "paused" ]] || return 2
}

dx_lifecycle_pause_metadata_record() {
  [[ $# -eq 1 ]] || return 2
  local session_id="$1" metadata_raw="" metadata_rc=0
  local reason="" source=""
  dx_lifecycle_session_id_valid "$session_id" || return 2
  metadata_raw=$(dx_lifecycle_trusted_file_read \
    "$(dx_pause_state_file "$session_id")" 1024) || metadata_rc=$?
  [[ "$metadata_rc" -eq 0 ]] || return "$metadata_rc"
  [[ "$metadata_raw" == *$'\n'* ]] || return 2
  reason="${metadata_raw%%$'\n'*}"
  source="${metadata_raw#*$'\n'}"
  [[ "$reason" =~ ^reason=[A-Za-z0-9._-]+$ \
    && "$source" =~ ^source=[A-Za-z0-9._-]+$ \
    && "$source" != *$'\n'* ]] || return 2
  printf '%s\t%s\n' "${reason#reason=}" "${source#source=}"
}

dx_lifecycle_pause_metadata_state() {
  [[ $# -eq 1 ]] || return 2
  dx_lifecycle_pause_metadata_record "$1" >/dev/null
}

# A valid marker or pause record is enough to make automation inert. Any
# unsafe inode in either path turns the whole pause context into an error.
dx_lifecycle_pause_context_state() {
  [[ $# -eq 1 ]] || return 2
  local session_id="$1" marker_rc=0 metadata_rc=0
  dx_lifecycle_paused_state "$session_id" || marker_rc=$?
  dx_lifecycle_pause_metadata_state "$session_id" || metadata_rc=$?
  [[ "$marker_rc" -ne 2 && "$metadata_rc" -ne 2 ]] || return 2
  [[ "$marker_rc" -eq 0 || "$metadata_rc" -eq 0 ]] && return 0
  return 1
}

# Consume a validated pause only while the lifecycle transition lock is held.
# Marker-only and metadata-only pauses are both valid historical forms; an
# unsafe inode in either location blocks resume instead of being overwritten.
dx_lifecycle_pause_clear_unlocked() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" pause_rc=0 paused_file pause_state_file
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" \
    && -n "${DX_LIFECYCLE_CONTROL_LOCK_TOKEN:-}" ]] || return 1
  dx_lifecycle_pause_context_state "$session_id" || pause_rc=$?
  [[ "$pause_rc" -ne 2 ]] || return 1
  paused_file=$(dx_paused_file "$session_id")
  pause_state_file=$(dx_pause_state_file "$session_id")
  command rm -f "$paused_file" "$pause_state_file" 2>/dev/null || return 1
  [[ ! -e "$paused_file" && ! -L "$paused_file" \
    && ! -e "$pause_state_file" && ! -L "$pause_state_file" ]]
}

dx_lifecycle_control_snapshot_unlocked() {
  local session_id="$1" control_file snapshot
  dx_lifecycle_session_id_valid "$session_id" || return 0
  control_file=$(dx_lifecycle_control_file "$session_id")
  snapshot=$(dx_lifecycle_trusted_file_read "$control_file" 4096 \
    2>/dev/null) || return 0
  printf '%s\n' "$snapshot"
}

dx_lifecycle_control_snapshot() {
  local session_id="$1" snapshot=""
  dx_lifecycle_session_id_valid "$session_id" || return 0
  dx_lifecycle_control_lock_acquire "$session_id" || return 0
  snapshot=$(dx_lifecycle_control_snapshot_unlocked "$session_id")
  if ! dx_lifecycle_control_lock_release "$session_id"; then
    dx_lifecycle_completion_brake "$session_id" control-read-lock-release \
      lifecycle-control 2>/dev/null || true
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$snapshot"
}

dx_lifecycle_control_value() {
  local snapshot="$1" key="$2"
  [[ -n "$key" ]] || return 0
  printf '%s\n' "$snapshot" | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

dx_lifecycle_control_read() {
  local session_id="$1" key="$2" snapshot
  dx_lifecycle_session_id_valid "$session_id" || return 0
  snapshot=$(dx_lifecycle_control_snapshot "$session_id")
  dx_lifecycle_control_value "$snapshot" "$key"
}

dx_lifecycle_current_phase() {
  local session_id="$1" phase="" phase_rc=0 config_file context_record=""
  dx_lifecycle_session_id_valid "$session_id" || return 0

  phase=$(dx_lifecycle_phase_state "$session_id" 2>/dev/null) || phase_rc=$?
  if [[ "$phase_rc" -eq 0 ]]; then
    printf '%s\n' "$phase"
    return 0
  fi
  # Never fall back from an existing unsafe phase inode to a stale config or
  # launch-time environment value.
  [[ "$phase_rc" -ne 2 ]] || return 0

  config_file=$(dx_loop_config_file "$session_id")
  if [[ -e "$config_file" || -L "$config_file" ]]; then
    context_record=$(dx_lifecycle_completion_context_read "$session_id" \
      2>/dev/null || true)
    [[ -n "$context_record" ]] || return 0
    phase="${context_record%%$'\t'*}"
    printf '%s\n' "$phase"
    return 0
  fi

  phase="${DEX_LOOP_PHASE:-}"
  if [[ "$phase" =~ ^[0-7]$ ]]; then
    printf '%s\n' "$phase"
  fi
  # "No lifecycle is running" is an answer, not a failure — the same answer the
  # invalid-session-id guard above already returns 0 for. Leaving the trailing
  # test as the function's exit status made it the caller's failure instead:
  # every one of them assigns the output under `set -e`, so `dx control` died
  # on line 64 without printing a word, including `dx control status`, the one
  # command whose whole job is to say whether a lifecycle is running.
  return 0
}

dx_lifecycle_session_active() {
  local session_id="$1" phase completion_context context_mode
  local _context_phase _context_promise _context_audit _context_min
  local _context_purpose _context_generation _context_handoff
  dx_lifecycle_session_id_valid "$session_id" || return 1
  completion_context=$(dx_lifecycle_completion_context_read "$session_id" 2>/dev/null || true)
  if [[ -n "$completion_context" ]]; then
    IFS=$'\t' read -r _context_phase _context_promise _context_audit \
      _context_min context_mode _context_purpose _context_generation \
      _context_handoff <<< "$completion_context"
    [[ "$context_mode" == "standalone" ]] && return 0
  fi
  phase=$(dx_lifecycle_current_phase "$session_id")
  [[ "$phase" == "7" ]] && return 1
  [[ "${DEX_LOOP_ACTIVE:-}" == "1" || "${DEX_REVIEW_PASS_ACTIVE:-}" == "1" ]] && return 0
  [[ -f "$(dx_active_file "$session_id")" || -f "$(dx_handoff_mode_file "$session_id")" ]] && return 0
  [[ "$phase" =~ ^[0-6]$ \
    && ( -e "$(dx_paused_file "$session_id")" \
      || -L "$(dx_paused_file "$session_id")" ) ]] && return 0
  [[ -f "$(dx_loop_config_file "$session_id")" ]] || return 1
  [[ "$phase" =~ ^[0-6]$ ]]
}

dx_write_lifecycle_control() {
  local session_id="$1" action="$2" target_phase="${3:-}" source="${4:-user-prompt}"
  local prompt_sha256="${5:-}" expected_phase="${6:-}" owner_session="${7:-}"
  local control_file history_file tmp_file history_tmp_file issued_at generation owner_file
  local published=0 write_status=0
  export DX_LIFECYCLE_CONTROL_GENERATION=""
  dx_lifecycle_session_id_valid "$session_id" || return 1
  case "$action" in
    pause|cancel|resume) [[ -z "$target_phase" ]] || return 1 ;;
    complete|jump) [[ "$target_phase" =~ ^[0-7]$ ]] || return 1 ;;
    *) return 1 ;;
  esac
  case "$source" in
    agent|user-prompt|terminal) ;;
    *) return 1 ;;
  esac
  [[ -z "$prompt_sha256" || "$prompt_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  control_file=$(dx_lifecycle_control_file "$session_id")
  history_file=$(dx_lifecycle_control_history_file "$session_id")
  mkdir -p "$DX_LOOP_DIR" "$DX_STATE_DIR"
  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  if ! __dx_lifecycle_cleanup_barrier_unlocked "$session_id"; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      >/dev/null 2>&1 || true
    return 1
  fi

  if [[ -z "$expected_phase" ]]; then
    expected_phase=$(dx_lifecycle_current_phase "$session_id")
  fi
  if [[ -n "$expected_phase" && "$expected_phase" != "prompt-loop" && ! "$expected_phase" =~ ^[0-7]$ ]]; then
    write_status=1
  fi
  owner_file=$(dx_owner_file "$session_id")
  if [[ -z "$owner_session" && -f "$owner_file" && ! -L "$owner_file" ]]; then
    owner_session=$(cat "$owner_file" 2>/dev/null || true)
  fi
  if [[ -n "$owner_session" ]] && ! dx_lifecycle_session_id_valid "$owner_session"; then
    write_status=1
  fi

  if [[ ( -e "$control_file" || -L "$control_file" ) && ( ! -f "$control_file" || -L "$control_file" ) ]]; then
    write_status=1
  fi
  if [[ ( -e "$history_file" || -L "$history_file" ) && ( ! -f "$history_file" || -L "$history_file" ) ]]; then
    write_status=1
  fi
  issued_at=$(date +%s)
  generation="${issued_at}-$$-${RANDOM}"

  tmp_file=""
  history_tmp_file=""
  if [[ "$write_status" -eq 0 ]]; then
    tmp_file=$(mktemp "${control_file}.tmp.XXXXXX") || write_status=1
  fi
  if [[ "$write_status" -eq 0 ]] && ! {
    printf 'version=1\n'
    printf 'action=%s\n' "$action"
    printf 'target_phase=%s\n' "$target_phase"
    printf 'expected_phase=%s\n' "$expected_phase"
    printf 'issued_at=%s\n' "$issued_at"
    printf 'generation=%s\n' "$generation"
    printf 'source=%s\n' "$source"
    printf 'owner_session=%s\n' "$owner_session"
    printf 'prompt_sha256=%s\n' "$prompt_sha256"
  } >| "$tmp_file"; then
    write_status=1
  fi

  if [[ "$write_status" -eq 0 ]]; then
    history_tmp_file=$(mktemp "${history_file}.tmp.XXXXXX") || write_status=1
  fi
  if [[ "$write_status" -eq 0 && -f "$history_file" ]]; then
    if ! cat "$history_file" >| "$history_tmp_file"; then
      write_status=1
    fi
  elif [[ "$write_status" -eq 0 ]] && ! printf 'issued_at\tgeneration\taction\ttarget_phase\texpected_phase\tsource\towner_session\tprompt_sha256\n' >| "$history_tmp_file"; then
    write_status=1
  fi
  if [[ "$write_status" -eq 0 ]] && ! printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$issued_at" "$generation" "$action" "$target_phase" "$expected_phase" \
    "$source" "$owner_session" "$prompt_sha256" >> "$history_tmp_file"; then
    write_status=1
  fi

  # History is the durable audit record. Publish it before the live receipt so
  # callers never receive a failure after a new control action became visible.
  if [[ "$write_status" -eq 0 ]] && ! command mv -f "$history_tmp_file" "$history_file"; then
    write_status=1
  fi
  if [[ "$write_status" -eq 0 ]]; then
    history_tmp_file=""
    if command mv -f "$tmp_file" "$control_file"; then
      tmp_file=""
      published=1
    else
      write_status=1
    fi
  fi

  [[ -n "$tmp_file" ]] && command rm -f "$tmp_file" 2>/dev/null || true
  [[ -n "$history_tmp_file" ]] && command rm -f "$history_tmp_file" 2>/dev/null || true
  if ! dx_lifecycle_control_lock_release "$session_id"; then
    dx_lifecycle_completion_brake "$session_id" control-write-lock-release \
      lifecycle-control 2>/dev/null || true
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
    write_status=1
  fi
  if [[ "$published" -eq 1 && "$write_status" -eq 0 ]]; then
    export DX_LIFECYCLE_CONTROL_GENERATION="$generation"
    return 0
  fi
  return 1
}

# Reactivate only the exact terminal transition that was just published. The
# Stop hook may win the gap between publication and this call; if it already
# committed and cleared the transition, leave the completed state untouched.
dx_lifecycle_activate_pending_control() {
  local session_id="$1" expected_action="$2" expected_target="$3"
  local expected_phase="$4" expected_generation="$5"
  local expected_source="${6:-terminal}" snapshot current_phase
  local control_file
  local action target source generation receipt_phase activation_result="pending"
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$expected_action" == "complete" || "$expected_action" == "jump" ]] || return 1
  [[ "$expected_target" =~ ^[0-7]$ && "$expected_phase" =~ ^[0-6]$ \
    && "$expected_generation" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] || return 1
  [[ "$expected_source" == "agent" || "$expected_source" == "terminal" ]] \
    || return 1
  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  if ! __dx_lifecycle_cleanup_barrier_unlocked "$session_id"; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      >/dev/null 2>&1 || true
    return 1
  fi
  control_file=$(dx_lifecycle_control_file "$session_id")
  snapshot=$(dx_lifecycle_control_snapshot_unlocked "$session_id")
  current_phase=$(dx_lifecycle_current_phase "$session_id")

  if [[ -z "$snapshot" && ! -e "$control_file" && ! -L "$control_file" \
    && "$current_phase" == "$expected_target" ]]; then
    if [[ "$expected_target" == "7" ]] \
      && ! __dx_lifecycle_terminal_commit_valid_unlocked "$session_id"; then
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      return 1
    fi
    activation_result="applied"
  else
    action=$(dx_lifecycle_control_value "$snapshot" action)
    target=$(dx_lifecycle_control_value "$snapshot" target_phase)
    source=$(dx_lifecycle_control_value "$snapshot" source)
    generation=$(dx_lifecycle_control_value "$snapshot" generation)
    receipt_phase=$(dx_lifecycle_control_value "$snapshot" expected_phase)
    if [[ "$action" != "$expected_action" || "$target" != "$expected_target" \
      || "$source" != "$expected_source" || "$generation" != "$expected_generation" \
      || "$receipt_phase" != "$expected_phase" \
      || ( "$current_phase" != "$expected_phase" \
        && "$current_phase" != "$expected_target" ) ]]; then
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      return 1
    fi
    if ! dx_lifecycle_atomic_write "$(dx_handoff_mode_file "$session_id")" inline \
      || ! dx_lifecycle_atomic_write "$(dx_active_file "$session_id")" active; then
      dx_lifecycle_completion_brake "$session_id" activation-publish-failed \
        lifecycle-control 2>/dev/null || true
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      return 1
    fi
    rm -f "$(dx_owner_file "$session_id")" 2>/dev/null || true
  fi

  if ! dx_lifecycle_control_lock_release "$session_id"; then
    dx_lifecycle_completion_brake "$session_id" activation-lock-release \
      lifecycle-control 2>/dev/null || true
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$activation_result"
}

__dx_lifecycle_path_mtime() {
  dx_path_mtime "$1"
}

__dx_lifecycle_control_lock_try() {
  local session_id="$1" lock_dir owner_file owner_raw owner_pid owner_epoch owner_token
  local now_epoch lock_epoch stale_after token current_raw tmp_owner doomed_dir
  dx_lifecycle_session_id_valid "$session_id" || return 1
  lock_dir=$(dx_lifecycle_control_lock_dir "$session_id")
  owner_file="$lock_dir/owner"
  mkdir -p "$DX_LOOP_DIR"
  if mkdir "$lock_dir" 2>/dev/null; then
    chmod 700 "$lock_dir" 2>/dev/null || true
    now_epoch=$(date +%s)
    token="${now_epoch}-$$-${RANDOM}"
    tmp_owner="$lock_dir/.owner-${token}"
    if ! ( umask 077; printf '%s\t%s\t%s\n' "$$" "$now_epoch" "$token" > "$tmp_owner" ) \
      || ! command mv -f "$tmp_owner" "$owner_file"; then
      command rm -f "$tmp_owner" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
      return 1
    fi
    DX_LIFECYCLE_CONTROL_LOCK_SESSION="$session_id"
    DX_LIFECYCLE_CONTROL_LOCK_TOKEN="$token"
    return 0
  fi
  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
  stale_after="${DEX_LIFECYCLE_CONTROL_LOCK_STALE_SECONDS:-2}"
  [[ "$stale_after" =~ ^[0-9]+$ ]] || stale_after=2

  if [[ ! -e "$owner_file" && ! -L "$owner_file" ]]; then
    sleep 0.05
    [[ ! -e "$owner_file" && ! -L "$owner_file" ]] || return 1
    lock_epoch=$(__dx_lifecycle_path_mtime "$lock_dir" 2>/dev/null || printf '0')
    now_epoch=$(date +%s)
    [[ "$lock_epoch" =~ ^[0-9]+$ ]] || return 1
    [[ $((now_epoch - lock_epoch)) -ge "$stale_after" ]] || return 1
    # Same rename-to-claim rule as below: an abandoned lock whose owner file
    # never appeared must be removed by exactly one cleaner.
    doomed_dir="${lock_dir}.doomed.$$"
    if command mv "$lock_dir" "$doomed_dir" 2>/dev/null; then
      command rm -rf "$doomed_dir" 2>/dev/null || true
    fi
    return 1
  fi
  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 1
  owner_raw=$(cat "$owner_file" 2>/dev/null || true)
  owner_pid="${owner_raw%%$'\t'*}"
  owner_raw="${owner_raw#*$'\t'}"
  owner_epoch="${owner_raw%%$'\t'*}"
  owner_token="${owner_raw#*$'\t'}"
  if [[ ! "$owner_pid" =~ ^[0-9]+$ || ! "$owner_epoch" =~ ^[0-9]+$ \
    || ! "$owner_token" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] \
    || ! kill -0 "$owner_pid" 2>/dev/null; then
    current_raw=$(cat "$owner_file" 2>/dev/null || true)
    [[ "$current_raw" == "${owner_pid}"$'\t'"${owner_epoch}"$'\t'"${owner_token}" ]] || return 1
    # Claim the removal by renaming: whoever wins the rename owns the cleanup.
    # Deleting the owner file and directory in place leaves a window in which
    # another cleaner can remove the lock and a new holder can recreate it,
    # after which this process would delete a lock it no longer owns.
    doomed_dir="${lock_dir}.doomed.$$"
    if command mv "$lock_dir" "$doomed_dir" 2>/dev/null; then
      command rm -rf "$doomed_dir" 2>/dev/null || true
    fi
  fi
  return 1
}

dx_lifecycle_control_lock_acquire() {
  local session_id="$1" attempts_raw="${2:-${DEX_LIFECYCLE_CONTROL_LOCK_ATTEMPTS:-40}}" attempt=0
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$attempts_raw" =~ ^[0-9]+$ && "$attempts_raw" -ge 1 && "$attempts_raw" -le 400 ]] || attempts_raw=40
  while [[ "$attempt" -lt "$attempts_raw" ]]; do
    if __dx_lifecycle_control_lock_try "$session_id"; then
      return 0
    fi
    attempt=$((attempt + 1))
    [[ "$attempt" -lt "$attempts_raw" ]] && sleep 0.05
  done
  return 1
}

dx_lifecycle_control_lock_release() {
  local session_id="$1" lock_dir owner_file owner_raw owner_pid owner_token
  local releasing_owner
  dx_lifecycle_session_id_valid "$session_id" || return 1
  lock_dir=$(dx_lifecycle_control_lock_dir "$session_id")
  owner_file="$lock_dir/owner"
  [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" ]] || return 1
  [[ -n "${DX_LIFECYCLE_CONTROL_LOCK_TOKEN:-}" ]] || return 1
  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 1
  owner_raw=$(cat "$owner_file" 2>/dev/null || true)
  owner_pid="${owner_raw%%$'\t'*}"
  owner_token="${owner_raw##*$'\t'}"
  [[ "$owner_pid" == "$$" && "$owner_token" == "$DX_LIFECYCLE_CONTROL_LOCK_TOKEN" ]] || return 1
  # Move the verified owner aside before removing the directory. If the
  # directory is unexpectedly non-empty, restore that exact owner so the
  # caller can still roll back under the same lock generation.
  releasing_owner="${lock_dir}.releasing.${DX_LIFECYCLE_CONTROL_LOCK_TOKEN}"
  [[ ! -e "$releasing_owner" && ! -L "$releasing_owner" ]] || return 1
  command mv "$owner_file" "$releasing_owner" 2>/dev/null || return 1
  if ! rmdir "$lock_dir" 2>/dev/null; then
    if [[ -d "$lock_dir" && ! -e "$owner_file" && ! -L "$owner_file" ]] \
      && command mv "$releasing_owner" "$owner_file" 2>/dev/null; then
      return 1
    fi
    DX_LIFECYCLE_CONTROL_LOCK_SESSION=""
    DX_LIFECYCLE_CONTROL_LOCK_TOKEN=""
    return 1
  fi
  DX_LIFECYCLE_CONTROL_LOCK_SESSION=""
  DX_LIFECYCLE_CONTROL_LOCK_TOKEN=""
  rm -f "$releasing_owner" 2>/dev/null || true
  return 0
}

# A failed release may restore the exact owner so its caller can roll back.
# Once rollback or braking is complete, this helper makes one checked retry
# and prevents a transient directory failure from stranding the live PID.
dx_lifecycle_control_lock_release_retained() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1"
  if [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" != "$session_id" ]]; then
    return 0
  fi
  dx_lifecycle_control_lock_release "$session_id"
}

# Rejection and rollback paths still return failure when their first unlock
# fails, even if this retry safely removes a restored owner. That distinction
# keeps callers from reporting success while avoiding a lock tied forever to
# the current interactive shell.
dx_lifecycle_control_lock_release_checked() {
  [[ $# -eq 1 ]] || return 1
  local session_id="$1"
  if dx_lifecycle_control_lock_release "$session_id"; then
    return 0
  fi
  dx_lifecycle_control_lock_release_retained "$session_id" \
    2>/dev/null || true
  return 1
}

dx_clear_lifecycle_control_unlocked() {
  local session_id="$1"
  dx_lifecycle_session_id_valid "$session_id" || return 0
  rm -f "$(dx_lifecycle_control_file "$session_id")" 2>/dev/null || true
}

dx_clear_lifecycle_control() {
  local session_id="$1"
  dx_lifecycle_session_id_valid "$session_id" || return 0
  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  dx_clear_lifecycle_control_unlocked "$session_id" || {
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  }
  dx_lifecycle_control_lock_release_checked "$session_id"
}

dx_write_pause_state() {
  local session_id="$1" reason="$2" source="$3" pause_file
  local acquired_here=0 pause_rc=0
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$reason" =~ ^[A-Za-z0-9._-]+$ && "$source" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  if ! __dx_lifecycle_control_lock_owned "$session_id"; then
    dx_lifecycle_control_lock_acquire "$session_id" || return 1
    acquired_here=1
  fi
  if ! __dx_lifecycle_cleanup_barrier_unlocked "$session_id"; then
    pause_rc=1
  fi
  pause_file=$(dx_pause_state_file "$session_id")
  if [[ "$pause_rc" -eq 0 ]] \
    && ! dx_lifecycle_atomic_write "$pause_file" \
      "reason=${reason}"$'\n'"source=${source}"; then
    pause_rc=1
  fi
  if [[ "$acquired_here" -eq 1 ]] \
    && ! dx_lifecycle_control_lock_release_checked "$session_id"; then
    pause_rc=1
  fi
  return "$pause_rc"
}

# Leave a completion context resumable but inert after a transition-lock
# failure. Removing activation first prevents a bystander Stop from minting a
# replacement receipt while authorization is being revoked.
dx_lifecycle_completion_brake() {
  local session_id="$1" reason="$2" source="$3" brake_rc=0
  dx_lifecycle_session_id_valid "$session_id" || return 1
  rm -f "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" \
    2>/dev/null || brake_rc=1
  dx_write_pause_state "$session_id" "$reason" "$source" 2>/dev/null \
    || brake_rc=1
  dx_lifecycle_atomic_write "$(dx_paused_file "$session_id")" paused 2>/dev/null \
    || brake_rc=1
  dx_completion_abandon "$session_id" 2>/dev/null \
    || __dx_completion_recover_cleanup "$session_id" 2>/dev/null \
    || brake_rc=1
  return "$brake_rc"
}

dx_pause_state_read() {
  local session_id="$1" key="$2" pause_file snapshot
  dx_lifecycle_session_id_valid "$session_id" || return 0
  pause_file=$(dx_pause_state_file "$session_id")
  [[ -f "$pause_file" && ! -L "$pause_file" ]] || return 0
  snapshot=$(cat "$pause_file" 2>/dev/null || true)
  dx_lifecycle_control_value "$snapshot" "$key"
}

# Return the one canonical loop config for a completion context. Callers use
# this for both activation and strict reads so prompt, audit, and gate values
# cannot drift between launch surfaces.
dx_completion_context_config() {
  local mode="${1:-}" purpose="${2:-}" phase="${3:-}" generation="${4:-}"
  [[ $# -eq 4 && "$generation" =~ ^[0-9a-f]{32}$ ]] || return 1
  dx_completion_context_valid "$mode" "$purpose" "$phase" || return 1
  case "${mode}:${purpose}:${phase}" in
    lifecycle:phase:[0-6])
      printf '%s:%s:%s/prompts/phase-audits/%s.md:%s:lifecycle:phase:%s\n' \
        "$phase" "$(dx_lifecycle_phase_promise "$phase")" "$DEX_DIR" \
        "$(dx_lifecycle_phase_audit_basename "$phase")" \
        "$(dx_lifecycle_phase_min_audits "$phase")" "$generation"
      ;;
    standalone:dxloop-plan:1)
      printf '1:PHASE_1_COMPLETE:%s/prompts/phase-audits/1-plan.md:1:standalone:dxloop-plan:%s\n' \
        "$DEX_DIR" "$generation"
      ;;
    standalone:dxloop-prompt:prompt-loop)
      printf 'prompt-loop:PROMPT_COMPLETE:%s/prompts/phase-audits/prompt-loop.md:1:standalone:dxloop-prompt:%s\n' \
        "$DEX_DIR" "$generation"
      ;;
    standalone:dxcomplete:6)
      printf '6:DEX_TICKET_COMPLETE:%s/prompts/phase-audits/6-complete.md:1:standalone:dxcomplete:%s\n' \
        "$DEX_DIR" "$generation"
      ;;
    child:review-assessment:assessment)
      printf 'assessment:REVIEW_ASSESSMENT_COMPLETE:%s/prompts/review-risk-assessment.md:1:child:review-assessment:%s\n' \
        "$DEX_DIR" "$generation"
      ;;
    child:review-pass:3)
      printf '3:PHASE_3_COMPLETE:%s/prompts/phase-audits/3-review.md:1:child:review-pass:%s\n' \
        "$DEX_DIR" "$generation"
      ;;
    *) return 1 ;;
  esac
}

# Publish a strict file-activated loop in one transition-lock transaction.
# It is shared by CLI launches, the in-session skill wrapper, and review waves.
dx_completion_loop_activate() {
  local session_id="${1:-}" mode="${2:-}" purpose="${3:-}" phase="${4:-}"
  local generation="" config="" activation_rc=0
  local active_file config_file expectation_file control_file paused_file
  local busy_file busy_token=""
  [[ $# -eq 4 ]] || return 2
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$mode" == "standalone" \
    || "${mode}:${purpose}:${phase}" == "child:review-pass:3" ]] || return 1
  dx_completion_context_valid "$mode" "$purpose" "$phase" || return 1
  active_file=$(dx_active_file "$session_id")
  config_file=$(dx_loop_config_file "$session_id")
  expectation_file=$(dx_completion_expectation_file "$session_id")
  control_file=$(dx_lifecycle_control_file "$session_id")
  paused_file=$(dx_paused_file "$session_id")
  busy_file=$(dx_phase_busy_file "$session_id" 3)

  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  if ! __dx_lifecycle_cleanup_barrier_unlocked "$session_id"; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      >/dev/null 2>&1 || true
    return 1
  fi
  if [[ -e "$active_file" || -L "$active_file" \
    || -e "$config_file" || -L "$config_file" \
    || -e "$expectation_file" || -L "$expectation_file" \
    || -e "$control_file" || -L "$control_file" \
    || -e "$paused_file" || -L "$paused_file" \
    || -e "$(dx_pause_state_file "$session_id")" \
    || -L "$(dx_pause_state_file "$session_id")" \
    || -e "$(dx_state_file "$session_id")" \
    || -L "$(dx_state_file "$session_id")" \
    || -e "$(dx_handoff_mode_file "$session_id")" \
    || -L "$(dx_handoff_mode_file "$session_id")" ]]; then
    if ! dx_lifecycle_control_lock_release_checked "$session_id"; then
      return 1
    fi
    return 2
  fi

  # A live review child is a transition fence, not stale loop state. Only a
  # matching quiescence acknowledgement makes it safe to retire that fence.
  if [[ -e "$busy_file" || -L "$busy_file" ]]; then
    if ! dx_phase_busy_quiesced "$session_id" 3; then
      if ! dx_lifecycle_control_lock_release_checked "$session_id"; then
        return 1
      fi
      return 2
    fi
    busy_token=$(dx_phase_busy_token "$session_id" 3)
    if [[ -z "$busy_token" ]] \
      || ! dx_phase_busy_finish "$session_id" 3 "$busy_token"; then
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      return 1
    fi
  fi
  if ! rm -f "$(dx_complete_file "$session_id")" \
    "$(dx_loop_file "$session_id")" "$(dx_findings_file "$session_id")" \
    "$(dx_owner_file "$session_id")" "$(dx_prompt_file "$session_id")" \
    "$(dx_phase_busy_notice_file "$session_id" 3)" \
    "$(dx_phase_busy_cancel_file "$session_id" 3)" \
    "$(dx_phase_busy_quiesced_file "$session_id" 3)" 2>/dev/null; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi

  generation=$(dx_lifecycle_completion_issue_unlocked \
    "$session_id" "$mode" "$purpose" "$phase") \
    || activation_rc=1
  if [[ "$activation_rc" -eq 0 ]]; then
    config=$(dx_completion_context_config "$mode" "$purpose" "$phase" \
      "$generation") || activation_rc=1
  fi
  if [[ "$activation_rc" -eq 0 ]] \
    && ! dx_lifecycle_atomic_write "$config_file" "$config"; then
    activation_rc=1
  fi
  if [[ "$activation_rc" -eq 0 ]] \
    && ! dx_lifecycle_atomic_write "$active_file" active; then
    activation_rc=1
  fi
  if [[ "$activation_rc" -ne 0 ]]; then
    dx_completion_abandon "$session_id" 2>/dev/null \
      || __dx_completion_recover_cleanup "$session_id" 2>/dev/null || true
    rm -f "$active_file" "$config_file" 2>/dev/null || true
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi
  if ! dx_lifecycle_control_lock_release "$session_id"; then
    dx_lifecycle_completion_brake "$session_id" activation-lock-release \
      "$purpose" 2>/dev/null || true
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$generation"
}

# A stuck agent may pause only the generation it was launched with. Human
# controls win conflicts and use their separate control-receipt path.
dx_lifecycle_agent_escalate() {
  local session_id="${1:-}" generation="${2:-}" context_record="" context_generation
  local context_mode context_purpose context_phase control_file escalate_rc=0
  [[ $# -eq 2 && "$generation" =~ ^[0-9a-f]{32}$ ]] || return 2
  dx_lifecycle_session_id_valid "$session_id" || return 1
  control_file=$(dx_lifecycle_control_file "$session_id")
  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  if ! __dx_lifecycle_cleanup_barrier_unlocked "$session_id"; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      >/dev/null 2>&1 || true
    return 1
  fi
  if [[ -e "$control_file" || -L "$control_file" ]]; then
    if ! dx_lifecycle_control_lock_release_checked "$session_id"; then
      return 1
    fi
    return 2
  fi
  context_record=$(dx_lifecycle_completion_context_read "$session_id" \
    2>/dev/null) || {
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  }
  IFS=$'\t' read -r context_phase _ _ _ context_mode context_purpose \
    context_generation _ <<< "$context_record"
  [[ "$context_mode" == "lifecycle" || "$context_mode" == "standalone" ]] \
    || escalate_rc=1
  [[ "$context_generation" == "$generation" ]] || escalate_rc=1
  # Escalation is not completion. It is authorized by the exact outstanding
  # expectation and never accepts or creates a completion receipt.
  if [[ "$escalate_rc" -eq 0 ]]; then
    [[ "$(dx_completion_current_generation "$session_id" "$context_mode" \
      "$context_purpose" "$context_phase" 2>/dev/null || true)" == "$generation" ]] \
      || escalate_rc=1
  fi
  if [[ "$escalate_rc" -ne 0 ]]; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi
  dx_lifecycle_detach "$session_id" failure-escalation agent-escalation \
    || escalate_rc=1
  if [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" ]] \
    && ! dx_lifecycle_control_lock_release "$session_id"; then
    dx_lifecycle_completion_brake "$session_id" \
      failure-escalation-lock-release agent-escalation 2>/dev/null || true
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
    escalate_rc=1
  fi
  return "$escalate_rc"
}

# Read the completion context that may be resumed. The context has to describe
# one of the exact launch contracts Dex writes; a numeric phase alone is not
# enough, because standalone loops use some of the same phase numbers.
dx_lifecycle_completion_context_read() {
  local session_id="$1" config_file config_line reconstructed expected_config
  local phase promise audit_file min_audits mode purpose generation extra
  local handoff_file handoff_mode="" handoff_rc=0 state_phase=""
  dx_lifecycle_session_id_valid "$session_id" || return 1
  config_file=$(dx_loop_config_file "$session_id")
  config_line=$(dx_lifecycle_trusted_file_read "$config_file" 4096) || return 1
  [[ -n "$config_line" && "$config_line" != *$'\n'* \
    && "$config_line" != *$'\r'* ]] || return 1
  IFS=: read -r phase promise audit_file min_audits mode purpose generation extra \
    <<< "$config_line"
  reconstructed="${phase}:${promise}:${audit_file}:${min_audits}:${mode}:${purpose}:${generation}"
  [[ "$config_line" == "$reconstructed" && -z "$extra" ]] || return 1
  expected_config=$(dx_completion_context_config "$mode" "$purpose" "$phase" \
    "$generation" 2>/dev/null) || return 1
  [[ "$config_line" == "$expected_config" ]] || return 1

  handoff_file=$(dx_handoff_mode_file "$session_id")
  if [[ -e "$handoff_file" || -L "$handoff_file" ]]; then
    handoff_mode=$(dx_lifecycle_trusted_file_read "$handoff_file" 32) \
      || handoff_rc=$?
    [[ "$handoff_rc" -eq 0 ]] || return 1
    [[ "$handoff_mode" != *$'\n'* && "$handoff_mode" != *$'\r'* ]] || return 1
  fi

  case "${mode}:${purpose}:${phase}" in
    lifecycle:phase:[0-6])
      state_phase=$(dx_lifecycle_phase_state "$session_id" 2>/dev/null || true)
      [[ "$state_phase" == "$phase" ]] || return 1
      if [[ "$handoff_mode" != "inline" ]]; then
        [[ -z "$handoff_mode" ]] || return 1
        dx_lifecycle_pause_context_state "$session_id" || return 1
      fi
      # A detach removes the live handoff marker. The validated phase state and
      # exact lifecycle config retain identity; resume restores inline mode.
      handoff_mode="inline"
      ;;
    standalone:dxloop-plan:1)
      [[ -z "$handoff_mode" ]] || return 1
      ;;
    standalone:dxloop-prompt:prompt-loop)
      [[ -z "$handoff_mode" ]] || return 1
      ;;
    standalone:dxcomplete:6)
      [[ -z "$handoff_mode" ]] || return 1
      ;;
    child:review-assessment:assessment|child:review-pass:3)
      [[ -z "$handoff_mode" ]] || return 1
      ;;
    *) return 1 ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$phase" "$promise" "$audit_file" "$min_audits" "$mode" "$purpose" \
    "$generation" "$handoff_mode"
}

# Rotate and reactivate an exact context while the caller holds the lifecycle
# control lock. Keeping this operation available in locked form lets the Stop
# hook apply a pending resume without dropping the transition lock halfway
# through the state change.
dx_lifecycle_resume_completion_context_unlocked() {
  local session_id="$1" context_record phase promise audit_file min_audits
  local mode purpose old_generation handoff_mode generation config_line
  local recorded_phase="" pause_metadata_record="" pause_metadata_rc=0
  local pause_reason="" pause_source="" busy_file busy_token=""
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" \
    && -n "${DX_LIFECYCLE_CONTROL_LOCK_TOKEN:-}" ]] || return 1
  __dx_lifecycle_cleanup_barrier_unlocked "$session_id" || return 1
  pause_metadata_record=$(dx_lifecycle_pause_metadata_record "$session_id" \
    2>/dev/null) || pause_metadata_rc=$?
  if [[ "$pause_metadata_rc" -eq 0 ]]; then
    IFS=$'\t' read -r pause_reason pause_source <<EOF
$pause_metadata_record
EOF
    : "$pause_source"
    # This brake means the old risk selection could not be invalidated. A
    # generic resume must not clear it and silently reuse that selection.
    case "$pause_reason" in
      assessment-selection-revocation-failed|receipt_revocation_failed)
        return 1
        ;;
    esac
  fi
  if ! context_record=$(dx_lifecycle_completion_context_read "$session_id" \
    2>/dev/null); then
    recorded_phase=$(dx_lifecycle_phase_state "$session_id" 2>/dev/null || true)
    if [[ "$recorded_phase" != "7" ]] \
      || ! __dx_lifecycle_terminal_failure_pause_valid "$session_id" \
      || ! dx_lifecycle_terminal_failure_rollback_unlocked "$session_id" \
        terminal-proof-invalid lifecycle-control; then
      return 1
    fi
    context_record=$(dx_lifecycle_completion_context_read "$session_id" \
      2>/dev/null) || return 1
  fi
  IFS=$'\t' read -r phase promise audit_file min_audits mode purpose \
    old_generation handoff_mode <<< "$context_record"
  : "$old_generation" "$handoff_mode"
  [[ "$mode" == "lifecycle" || "$mode" == "standalone" ]] || return 1

  # A Phase 3 child fence survives detach until the exact child acknowledges
  # quiescence. Resume may retire that proven fence, but must never launch a
  # fresh generation while an unquiesced or malformed child marker remains.
  busy_file=$(dx_phase_busy_file "$session_id" 3)
  if [[ -e "$busy_file" || -L "$busy_file" ]]; then
    dx_phase_busy_quiesced "$session_id" 3 || return 1
    busy_token=$(dx_phase_busy_token "$session_id" 3)
    [[ -n "$busy_token" ]] || return 1
    dx_phase_busy_finish "$session_id" 3 "$busy_token" || return 1
  fi
  if ! dx_lifecycle_pause_clear_unlocked "$session_id"; then
    return 1
  fi
  if ! generation=$(dx_lifecycle_completion_issue_unlocked \
    "$session_id" "$mode" "$purpose" "$phase"); then
    dx_lifecycle_completion_brake "$session_id" resume-issue-failed \
      lifecycle-control 2>/dev/null || true
    return 1
  fi
  config_line="${phase}:${promise}:${audit_file}:${min_audits}:${mode}:${purpose}:${generation}"
  if ! dx_lifecycle_atomic_write "$(dx_loop_config_file "$session_id")" "$config_line"; then
    dx_completion_abandon "$session_id" 2>/dev/null \
      || __dx_completion_recover_cleanup "$session_id" 2>/dev/null \
      || true
    dx_lifecycle_completion_brake "$session_id" resume-config-failed \
      lifecycle-control 2>/dev/null || true
    return 1
  fi
  if [[ "$mode" == "lifecycle" ]] \
    && ! dx_lifecycle_atomic_write "$(dx_handoff_mode_file "$session_id")" inline; then
    dx_completion_abandon "$session_id" 2>/dev/null \
      || __dx_completion_recover_cleanup "$session_id" 2>/dev/null \
      || true
    dx_lifecycle_completion_brake "$session_id" resume-handoff-failed \
      lifecycle-control 2>/dev/null || true
    return 1
  fi
  if ! dx_lifecycle_atomic_write "$(dx_active_file "$session_id")" active; then
    dx_completion_abandon "$session_id" 2>/dev/null \
      || __dx_completion_recover_cleanup "$session_id" 2>/dev/null \
      || true
    dx_lifecycle_completion_brake "$session_id" resume-activation-failed \
      lifecycle-control 2>/dev/null || true
    return 1
  fi
  dx_clear_lifecycle_control_unlocked "$session_id"
  rm -f "$(dx_owner_file "$session_id")" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$phase" "$generation" "$mode" "$purpose"
}

# Rotate the exact existing context and reactivate it. Callers do not infer a
# lifecycle merely because a standalone loop happens to use Phase 1 or 6.
dx_lifecycle_resume_completion_context() {
  local session_id="$1" resume_record resume_rc=0
  dx_lifecycle_session_id_valid "$session_id" || return 1
  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  resume_record=$(dx_lifecycle_resume_completion_context_unlocked "$session_id") \
    || resume_rc=$?
  if ! dx_lifecycle_control_lock_release "$session_id"; then
    dx_lifecycle_completion_brake "$session_id" resume-lock-release \
      lifecycle-control 2>/dev/null || true
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
    return 1
  fi
  [[ "$resume_rc" -eq 0 ]] || return "$resume_rc"
  printf '%s\n' "$resume_record"
}

# Completion authorization always names its exact context and generation.
dx_consume_completion_receipt() {
  [[ $# -eq 5 ]] || return 2
  dx_lifecycle_session_id_valid "$1" || return 1
  dx_completion_consume "$@"
}

# dx_record_control_phase_outcomes <session_id> <current> <target> <action> <generation> <source> [recovery]
# Record the phases a human/agent transition crosses. Callers hold the
# lifecycle lock and clear the live control receipt only after this succeeds.
dx_record_control_phase_outcomes() {
  local session_id="$1" current="$2" target="$3" action="$4"
  local generation="$5" source="$6" recovery="${7:-0}"
  local outcome reason event_type phase record_status data_json actor_label
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$current" =~ ^[0-7]$ && "$target" =~ ^[0-7]$ ]] || return 1
  [[ "$generation" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] || return 1
  case "$source" in
    agent|user-prompt|terminal) ;;
    *) return 1 ;;
  esac
  [[ "$recovery" == "0" || "$recovery" == "1" ]] || return 1
  [[ "$target" -gt "$current" ]] || return 0

  case "$action" in
    complete)
      [[ "$target" -eq $((current + 1)) ]] || return 1
      outcome="waived"
      if [[ "$source" == "agent" ]]; then
        reason="agent-complete"
      else
        reason="human-complete"
      fi
      event_type="phase.waived"
      ;;
    jump)
      outcome="skipped"
      if [[ "$source" == "agent" ]]; then
        reason="agent-jump"
      else
        reason="human-jump"
      fi
      event_type="phase.skipped"
      ;;
    *) return 1 ;;
  esac

  phase="$current"
  while [[ "$phase" -lt "$target" && "$phase" -le 6 ]]; do
    record_status=0
    dx_phase_outcome_record "$session_id" "$phase" "$outcome" "$source" \
      "$generation" "$reason" || record_status=$?
    if [[ "$record_status" -eq 3 ]]; then
      phase=$((phase + 1))
      continue
    fi
    [[ "$record_status" -eq 0 ]] || return 1

    data_json=$(printf \
      '{"outcome":"%s","reason":"%s","source":"%s","generation":"%s","target_phase":%s}' \
      "$outcome" "$reason" "$source" "$generation" "$target")
    actor_label=$(dx_lifecycle_control_actor_label "$source")
    dx_event_emit_for_session "$session_id" "$event_type" "warn" \
      "Phase ${phase} ${outcome} by ${actor_label}" "$phase" "$data_json"
    dx_run_log_append_for_session "$session_id" "warn" "lifecycle-control" \
      "Phase ${phase} ${outcome} by ${actor_label}; target_phase=${target}; generation=${generation}; source=${source}"
    phase=$((phase + 1))
  done
}

# Compatibility name for older callers and pinned evaluation runtimes.
dx_record_human_phase_outcomes() {
  dx_record_control_phase_outcomes "$@"
}

# Print a validated busy record as six newline-delimited fields: version,
# epoch, token, PID, timeout, and label. Version 1 has an empty timeout field.
# Its label remains opaque, including tabs that resemble version 2 metadata.
__dx_phase_busy_record() {
  local session_id="$1" phase="$2" busy_file raw record_version
  local epoch token owner_pid timeout_field="" timeout_value="" label rest
  local token_epoch token_pid token_nonce token_extra
  dx_lifecycle_session_id_valid "$session_id" || return 2
  [[ "$phase" =~ ^[0-6]$ ]] || return 2
  busy_file=$(dx_phase_busy_file "$session_id" "$phase")
  raw=$(dx_lifecycle_trusted_file_read "$busy_file" 2048 2>/dev/null) \
    || return 2

  if [[ "$raw" == dex-phase-busy-v2$'\t'* ]]; then
    record_version=2
    rest="${raw#*$'\t'}"
    [[ "$rest" == *$'\t'* ]] || return 2
    epoch="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    [[ "$rest" == *$'\t'* ]] || return 2
    token="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    [[ "$rest" == *$'\t'* ]] || return 2
    owner_pid="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    [[ "$rest" == *$'\t'* ]] || return 2
    timeout_field="${rest%%$'\t'*}"
    label="${rest#*$'\t'}"
    [[ "$timeout_field" == timeout=* ]] || return 2
    timeout_value="${timeout_field#timeout=}"
    case "$timeout_value" in
      ""|*[!0-9]*) return 2 ;;
    esac
    while [[ ${#timeout_value} -gt 1 && "$timeout_value" == 0* ]]; do
      timeout_value="${timeout_value#0}"
    done
    [[ ${#timeout_value} -le 15 ]] || return 2
  else
    record_version=1
    [[ "$raw" == *$'\t'* ]] || return 2
    epoch="${raw%%$'\t'*}"
    rest="${raw#*$'\t'}"
    [[ "$rest" == *$'\t'* ]] || return 2
    token="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    [[ "$rest" == *$'\t'* ]] || return 2
    owner_pid="${rest%%$'\t'*}"
    label="${rest#*$'\t'}"
  fi

  case "$epoch" in ""|*[!0-9]*) return 2 ;; esac
  case "$owner_pid" in ""|*[!0-9]*) return 2 ;; esac
  [[ ${#epoch} -le 15 && ${#owner_pid} -le 15 ]] || return 2
  [[ "$epoch" == "0" || "$epoch" != 0* ]] || return 2
  [[ "$owner_pid" != "0" && "$owner_pid" != 0* ]] || return 2
  token_epoch=""
  token_pid=""
  token_nonce=""
  token_extra=""
  IFS=- read -r token_epoch token_pid token_nonce token_extra <<EOF
$token
EOF
  case "$token_nonce" in ""|*[!0-9]*) return 2 ;; esac
  [[ -z "$token_extra" && "$token_epoch" == "$epoch" \
    && "$token_pid" == "$owner_pid" ]] || return 2
  [[ ${#token_nonce} -le 15 ]] || return 2
  [[ "$token_nonce" == "0" || "$token_nonce" != 0* ]] || return 2
  [[ "$token" == "${token_epoch}-${token_pid}-${token_nonce}" ]] || return 2
  [[ -n "$label" && "$label" != *$'\n'* && "$label" != *$'\r'* \
    && ${#label} -le 500 ]] || return 2

  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$record_version" "$epoch" "$token" "$owner_pid" \
    "$timeout_value" "$label"
}

# dx_phase_busy_owner_status <session_id> <phase>
# Print absent, invalid, live<TAB>PID, or dead<TAB>PID. Callers use this
# conservative reading before deciding whether an interrupted review fence can
# be recovered; an unreadable marker is never treated as a dead owner.
dx_phase_busy_owner_status() {
  local session_id="$1" phase="$2" busy_file record owner_pid
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$phase" =~ ^[0-6]$ ]] || return 1
  busy_file=$(dx_phase_busy_file "$session_id" "$phase")
  if [[ ! -e "$busy_file" && ! -L "$busy_file" ]]; then
    printf '%s\n' absent
    return 0
  fi
  if [[ ! -f "$busy_file" || -L "$busy_file" ]]; then
    printf '%s\n' invalid
    return 0
  fi
  record=$(__dx_phase_busy_record "$session_id" "$phase" 2>/dev/null) || {
    printf '%s\n' invalid
    return 0
  }
  record="${record#*$'\n'}"
  record="${record#*$'\n'}"
  record="${record#*$'\n'}"
  owner_pid="${record%%$'\n'*}"
  if __dx_lock_pid_alive "$owner_pid"; then
    printf 'live\t%s\n' "$owner_pid"
  else
    printf 'dead\t%s\n' "$owner_pid"
  fi
}

# dx_lifecycle_recover_review_fence <session_id> <source> <reason>
# Recover only the Phase 3 fence left by a provably dead review owner. This is
# not a review result: completion is revoked, the lifecycle stays paused, and
# the caller must explicitly resume Phase 3 or skip it. Return 2 when no fence
# exists, 3 for malformed state, and 4 while the recorded owner is still alive.
dx_lifecycle_recover_review_fence() {
  local session_id="$1" recovery_source="$2" recovery_reason="$3"
  local owner_snapshot owner_kind owner_pid recovered_json fence_file
  local recovery_rc=0
  dx_lifecycle_session_id_valid "$session_id" || return 1
  case "$recovery_source" in agent|human|user-prompt) ;; *) return 1 ;; esac
  dx_override_reason_valid "$recovery_reason" || return 1

  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  if ! __dx_lifecycle_cleanup_barrier_unlocked "$session_id"; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      >/dev/null 2>&1 || true
    return 1
  fi

  owner_snapshot=$(dx_phase_busy_owner_status "$session_id" 3) || recovery_rc=1
  owner_kind="${owner_snapshot%%$'\t'*}"
  owner_pid=""
  [[ "$owner_snapshot" == *$'\t'* ]] && owner_pid="${owner_snapshot#*$'\t'}"
  case "$owner_kind" in
    absent) recovery_rc=2 ;;
    invalid) recovery_rc=3 ;;
    live) recovery_rc=4 ;;
    dead) : ;;
    *) recovery_rc=1 ;;
  esac
  if [[ "$recovery_rc" -ne 0 ]]; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      >/dev/null 2>&1 || true
    return "$recovery_rc"
  fi

  # Detach first so no completion generation survives the maintenance action.
  # It also records the attributed pause before any fence file is removed.
  if ! dx_lifecycle_detach "$session_id" stale-review-fence-recovered \
    "$recovery_source"; then
    if __dx_lifecycle_control_lock_owned "$session_id"; then
      dx_lifecycle_control_lock_release_checked "$session_id" \
        >/dev/null 2>&1 || true
    fi
    return 1
  fi

  # Re-read under the same transition lock. The token cannot silently change
  # between the dead-owner proof and deletion.
  if [[ "$(dx_phase_busy_owner_status "$session_id" 3)" != "$owner_snapshot" ]]; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      >/dev/null 2>&1 || true
    return 1
  fi
  for fence_file in \
    "$(dx_phase_busy_file "$session_id" 3)" \
    "$(dx_phase_busy_notice_file "$session_id" 3)" \
    "$(dx_phase_busy_cancel_file "$session_id" 3)" \
    "$(dx_phase_busy_quiesced_file "$session_id" 3)"; do
    rm -f "$fence_file" 2>/dev/null || recovery_rc=1
    [[ ! -e "$fence_file" && ! -L "$fence_file" ]] || recovery_rc=1
  done
  if [[ "$recovery_rc" -ne 0 ]] \
    || ! dx_lifecycle_control_lock_release_checked "$session_id"; then
    dx_lifecycle_completion_brake "$session_id" review-fence-recovery-failed \
      "$recovery_source" 2>/dev/null || true
    return 1
  fi

  recovered_json=$(printf \
    '{"reason":"stale-review-owner","source":"%s","owner_pid":%s}' \
    "$recovery_source" "$owner_pid")
  dx_event_emit_for_session "$session_id" "review.fence.recovered" "warn" \
    "Recovered stale Phase 3 review fence" "3" "$recovered_json" \
    2>/dev/null || true
  dx_run_log_append_for_session "$session_id" "warn" "lifecycle-control" \
    "Recovered stale Phase 3 review fence for dead owner PID ${owner_pid}; source=${recovery_source}; reason=${recovery_reason}" \
    2>/dev/null || true
  return 0
}

dx_phase_busy_token() {
  local session_id="$1" phase="$2" record token
  record=$(__dx_phase_busy_record "$session_id" "$phase" 2>/dev/null) \
    || return 0
  record="${record#*$'\n'}"
  record="${record#*$'\n'}"
  token="${record%%$'\n'*}"
  printf '%s\n' "$token"
  # A missing or malformed record answers "no authoritative token" with 0.
  # Callers assign this output under `set -e`, so the empty result is the
  # fail-closed signal rather than a shell-level error.
  return 0
}

# dx_phase_busy_timeout <session_id> <phase>
# Print the timeout bound to the active busy owner. Return 1 for a legacy busy
# record with no bound timeout and 2 for a malformed bound value.
dx_phase_busy_timeout() {
  local session_id="$1" phase="$2" record record_version timeout_value
  record=$(__dx_phase_busy_record "$session_id" "$phase" 2>/dev/null) \
    || return 2
  record_version="${record%%$'\n'*}"
  [[ "$record_version" == "2" ]] || return 1
  record="${record#*$'\n'}"
  record="${record#*$'\n'}"
  record="${record#*$'\n'}"
  record="${record#*$'\n'}"
  timeout_value="${record%%$'\n'*}"
  printf '%s\n' "$timeout_value"
}

dx_phase_busy_begin() {
  local session_id="$1" phase="$2" label="${3:-busy}" timeout_value="${4:-}"
  local epoch token busy_file busy_record
  local cancel_file quiesced_file residue_file residue_rc=0
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$phase" =~ ^[0-6]$ ]] || return 1
  [[ "$label" != *$'\n'* && "$label" != *$'\r'* && ${#label} -le 500 ]] || return 1
  if [[ -n "$timeout_value" ]]; then
    case "$timeout_value" in
      *[!0-9]*) return 1 ;;
    esac
    while [[ ${#timeout_value} -gt 1 && "$timeout_value" == 0* ]]; do
      timeout_value="${timeout_value#0}"
    done
    [[ ${#timeout_value} -le 15 ]] || return 1
  fi
  epoch=$(date +%s)
  token="${epoch}-$$-${RANDOM}"
  busy_file=$(dx_phase_busy_file "$session_id" "$phase")
  cancel_file=$(dx_phase_busy_cancel_file "$session_id" "$phase")
  quiesced_file=$(dx_phase_busy_quiesced_file "$session_id" "$phase")
  [[ ! -e "$busy_file" && ! -L "$busy_file" ]] || return 1
  for residue_file in "$cancel_file" "$quiesced_file"; do
    if [[ -e "$residue_file" || -L "$residue_file" ]]; then
      residue_rc=0
      dx_lifecycle_trusted_file_read "$residue_file" 2048 \
        >/dev/null 2>&1 || residue_rc=$?
      [[ "$residue_rc" -eq 0 ]] || return 1
      rm -f "$residue_file" 2>/dev/null || return 1
      [[ ! -e "$residue_file" && ! -L "$residue_file" ]] || return 1
    fi
  done
  busy_record="${epoch}"$'\t'"${token}"$'\t'"$$"
  if [[ -n "$timeout_value" ]]; then
    busy_record="dex-phase-busy-v2"$'\t'"${busy_record}"$'\t'"timeout=${timeout_value}"
  fi
  busy_record+=$'\t'"${label}"
  dx_lifecycle_atomic_write "$busy_file" "$busy_record" || return 1
  printf '%s\n' "$token"
}

dx_phase_busy_request_cancel() {
  local session_id="$1" phase="$2" token cancel_file cancel_rc=0
  token=$(dx_phase_busy_token "$session_id" "$phase")
  [[ -n "$token" ]] || return 1
  cancel_file=$(dx_phase_busy_cancel_file "$session_id" "$phase")
  if [[ -e "$cancel_file" || -L "$cancel_file" ]]; then
    dx_lifecycle_trusted_file_read "$cancel_file" 2048 \
      >/dev/null 2>&1 || cancel_rc=$?
    [[ "$cancel_rc" -eq 0 ]] || return 1
  fi
  dx_lifecycle_atomic_write "$cancel_file" "$token"
}

dx_phase_busy_cancel_requested() {
  local session_id="$1" phase="$2" token requested
  token=$(dx_phase_busy_token "$session_id" "$phase")
  [[ -n "$token" ]] || return 1
  requested=$(dx_lifecycle_trusted_file_read \
    "$(dx_phase_busy_cancel_file "$session_id" "$phase")" 2048 \
    2>/dev/null) || return 1
  [[ "$requested" == "$token" ]]
}

dx_phase_busy_acknowledge() {
  local session_id="$1" phase="$2" token="$3" current ack_file ack_rc=0
  current=$(dx_phase_busy_token "$session_id" "$phase")
  [[ -n "$token" && "$current" == "$token" ]] || return 1
  ack_file=$(dx_phase_busy_quiesced_file "$session_id" "$phase")
  if [[ -e "$ack_file" || -L "$ack_file" ]]; then
    dx_lifecycle_trusted_file_read "$ack_file" 2048 \
      >/dev/null 2>&1 || ack_rc=$?
    [[ "$ack_rc" -eq 0 ]] || return 1
  fi
  dx_lifecycle_atomic_write "$ack_file" "$token"
}

dx_phase_busy_quiesced() {
  local session_id="$1" phase="$2" token acknowledged ack_file
  token=$(dx_phase_busy_token "$session_id" "$phase")
  [[ -n "$token" ]] || return 1
  ack_file=$(dx_phase_busy_quiesced_file "$session_id" "$phase")
  acknowledged=$(dx_lifecycle_trusted_file_read "$ack_file" 2048 \
    2>/dev/null) || return 1
  [[ "$acknowledged" == "$token" ]]
}

dx_phase_busy_finish() {
  local session_id="$1" phase="$2" token="$3" current
  current=$(dx_phase_busy_token "$session_id" "$phase")
  [[ -n "$token" && "$current" == "$token" ]] || return 1
  dx_phase_busy_quiesced "$session_id" "$phase" || return 1
  rm -f "$(dx_phase_busy_file "$session_id" "$phase")" \
    "$(dx_phase_busy_notice_file "$session_id" "$phase")" \
    "$(dx_phase_busy_cancel_file "$session_id" "$phase")" \
    "$(dx_phase_busy_quiesced_file "$session_id" "$phase")" \
    2>/dev/null || return 1
  [[ ! -e "$(dx_phase_busy_file "$session_id" "$phase")" \
    && ! -L "$(dx_phase_busy_file "$session_id" "$phase")" \
    && ! -e "$(dx_phase_busy_cancel_file "$session_id" "$phase")" \
    && ! -L "$(dx_phase_busy_cancel_file "$session_id" "$phase")" \
    && ! -e "$(dx_phase_busy_quiesced_file "$session_id" "$phase")" \
    && ! -L "$(dx_phase_busy_quiesced_file "$session_id" "$phase")" ]]
}

dx_phase_transition_crosses() {
  local current="$1" target="$2" boundary="$3"
  [[ "$current" =~ ^[0-7]$ && "$target" =~ ^[0-7]$ && "$boundary" =~ ^[0-7]$ ]] || return 1
  [[ "$current" != "$target" ]] || return 1
  if [[ "$current" -le "$target" ]]; then
    [[ "$current" -le "$boundary" && "$target" -ge "$boundary" ]]
  else
    [[ "$target" -le "$boundary" && "$current" -ge "$boundary" ]]
  fi
}

dx_phase_busy_transition_blocked() {
  local session_id="$1" phase="$2" current="$3" target="$4" busy_file
  busy_file=$(dx_phase_busy_file "$session_id" "$phase")
  [[ -e "$busy_file" || -L "$busy_file" ]] || return 1
  dx_phase_transition_crosses "$current" "$target" "$phase" || return 1
  [[ -f "$busy_file" && ! -L "$busy_file" ]] || return 0
  dx_phase_busy_quiesced "$session_id" "$phase" && return 1
  return 0
}

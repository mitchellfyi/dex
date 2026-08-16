#!/usr/bin/env bash
# Manage one active Dex lifecycle from a human terminal or direct Codex session.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: dx control <status|pause|stop|done|jump PHASE|resume>

  status       Show the current phase and pending human control
  pause        Detach Dex and preserve the current phase for resume
  stop         Stop Dex enforcement and preserve the workspace
  done         Mark the current phase done and advance without its remaining gates
  jump PHASE   Move to Phase 0-6, or a phase name such as review, verify, or pr
  resume       Clear a pause and resume the recorded phase
EOF
}

phase_number() {
  local value
  value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$value" in
    0|setup) printf '0\n' ;;
    1|plan|planning) printf '1\n' ;;
    2|implement|implementation) printf '2\n' ;;
    3|review|review-loop) printf '3\n' ;;
    4|verify|verification|commit|verify-and-commit) printf '4\n' ;;
    5|pr|pull-request) printf '5\n' ;;
    6|complete|completion) printf '6\n' ;;
    *) return 1 ;;
  esac
}

phase_label() { dx_lifecycle_phase_label "$1"; }

activate_recorded_phase() {
  if [[ "$CURRENT_PHASE" =~ ^[0-6]$ ]]; then
    dx_lifecycle_atomic_write "$(dx_handoff_mode_file "$SESSION_ID")" "inline" || return 1
  elif [[ ! -f "$(dx_loop_config_file "$SESSION_ID")" \
    && ! -f "$(dx_handoff_mode_file "$SESSION_ID")" ]]; then
    return 1
  fi
  rm -f "$(dx_owner_file "$SESSION_ID")" 2>/dev/null || true
  touch "$(dx_active_file "$SESSION_ID")"
}

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
if ! dx_lifecycle_session_id_valid "$SESSION_ID"; then
  dx_error "Invalid Dex session id."
  exit 1
fi
REPO_KEY=$(dx_session_repo_key)
case "$SESSION_ID" in
  "$REPO_KEY"-*) ;;
  *)
    dx_error "Session ${SESSION_ID} does not belong to this repository."
    exit 1
    ;;
esac

COMMAND="${1:-status}"
shift 2>/dev/null || true
CURRENT_PHASE=$(dx_lifecycle_current_phase "$SESSION_ID")
CONTROL_FILE=$(dx_lifecycle_control_file "$SESSION_ID")

if [[ "$COMMAND" == "-h" || "$COMMAND" == "--help" || "$COMMAND" == "help" ]]; then
  [[ $# -eq 0 ]] || { dx_error "Usage: dx control help"; exit 1; }
  usage
  exit 0
fi

case "$COMMAND" in
  status|pause|detach|stop|cancel|done|complete|resume)
    [[ $# -eq 0 ]] || { dx_error "dx control ${COMMAND} does not accept arguments."; exit 1; }
    ;;
  jump|phase)
    [[ $# -eq 1 ]] || { dx_error "Usage: dx control jump <0-6|phase-name>"; exit 1; }
    ;;
esac

if [[ "$COMMAND" != "status" && "$COMMAND" != "resume" ]] && ! dx_lifecycle_session_active "$SESSION_ID"; then
  dx_error "No active Dex lifecycle was found for this checkout."
  exit 1
fi

OWNER_SESSION=""
[[ -f "$(dx_owner_file "$SESSION_ID")" ]] && OWNER_SESSION=$(cat "$(dx_owner_file "$SESSION_ID")" 2>/dev/null || true)

case "$COMMAND" in
  status)
    if [[ -z "$CURRENT_PHASE" && ! -f "$CONTROL_FILE" ]]; then
      dx_info "No Dex lifecycle state was found for this checkout."
      exit 0
    fi
    [[ -n "$CURRENT_PHASE" ]] && printf 'Phase: %s (%s)\n' "$CURRENT_PHASE" "$(phase_label "$CURRENT_PHASE")"
    CONTROL_SNAPSHOT=$(dx_lifecycle_control_snapshot "$SESSION_ID")
    CONTROL_ACTION=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" action)
    CONTROL_TARGET=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" target_phase)
    if [[ -n "$CONTROL_ACTION" ]]; then
      printf 'Human control: %s' "$CONTROL_ACTION"
      [[ -n "$CONTROL_TARGET" ]] && printf ' -> Phase %s' "$CONTROL_TARGET"
      printf '\n'
    else
      printf 'Human control: none\n'
    fi
    if [[ -f "$(dx_paused_file "$SESSION_ID")" ]]; then
      PAUSE_REASON=$(dx_pause_state_read "$SESSION_ID" reason)
      printf 'Lifecycle: paused%s\n' "${PAUSE_REASON:+ (${PAUSE_REASON})}"
    fi
    ;;
  pause|detach|stop|cancel)
    ACTION="pause"
    [[ "$COMMAND" == "stop" || "$COMMAND" == "cancel" ]] && ACTION="cancel"
    dx_write_lifecycle_control "$SESSION_ID" "$ACTION" "" terminal "" "$CURRENT_PHASE" "$OWNER_SESSION"
    dx_lifecycle_detach "$SESSION_ID" "manual-${ACTION}" "terminal"
    dx_done "Dex ${ACTION} accepted for Phase ${CURRENT_PHASE:-unknown}. The workspace and phase state are preserved."
    ;;
  done|complete)
    [[ "$CURRENT_PHASE" =~ ^[0-6]$ ]] || { dx_error "No resumable lifecycle phase was found."; exit 1; }
    TARGET_PHASE=$((CURRENT_PHASE + 1))
    if dx_phase_busy_transition_blocked "$SESSION_ID" 3 "$CURRENT_PHASE" "$TARGET_PHASE"; then
      dx_write_lifecycle_control "$SESSION_ID" pause "" terminal "" "$CURRENT_PHASE" "$OWNER_SESSION"
      dx_lifecycle_detach "$SESSION_ID" "review-child-active" "terminal"
      dx_warn "Dex detached at Phase 3 because a review child is still marked in flight. Jump after that process ends."
      exit 0
    fi
    dx_write_lifecycle_control "$SESSION_ID" complete "$TARGET_PHASE" terminal "" "$CURRENT_PHASE" "$OWNER_SESSION"
    activate_recorded_phase || { dx_error "Could not reactivate the recorded lifecycle phase."; exit 1; }
    dx_done "Phase ${CURRENT_PHASE} marked done by human control; transition to Phase ${TARGET_PHASE} is pending."
    ;;
  jump|phase)
    if ! TARGET_PHASE=$(phase_number "$1"); then
      dx_error "Unknown phase '$1'. Use 0-6, plan, implement, review, verify, pr, or complete."
      exit 1
    fi
    if dx_phase_busy_transition_blocked "$SESSION_ID" 3 "$CURRENT_PHASE" "$TARGET_PHASE"; then
      dx_write_lifecycle_control "$SESSION_ID" pause "" terminal "" "$CURRENT_PHASE" "$OWNER_SESSION"
      dx_lifecycle_detach "$SESSION_ID" "review-child-active" "terminal"
      dx_warn "Dex detached at Phase 3 because a review child is still marked in flight. Jump after that process ends."
      exit 0
    fi
    dx_write_lifecycle_control "$SESSION_ID" jump "$TARGET_PHASE" terminal "" "$CURRENT_PHASE" "$OWNER_SESSION"
    activate_recorded_phase || { dx_error "Could not reactivate the recorded lifecycle phase."; exit 1; }
    dx_done "Human-controlled transition to Phase ${TARGET_PHASE} ($(phase_label "$TARGET_PHASE")) is pending."
    ;;
  resume)
    if [[ ! -f "$CONTROL_FILE" && ! -f "$(dx_paused_file "$SESSION_ID")" ]]; then
      dx_info "Dex is not paused for this checkout."
      exit 0
    fi
    dx_write_lifecycle_control "$SESSION_ID" resume "" terminal "" "$CURRENT_PHASE" "$OWNER_SESSION"
    activate_recorded_phase || { dx_error "Could not reactivate the recorded lifecycle phase."; exit 1; }
    dx_clear_lifecycle_control "$SESSION_ID"
    rm -f "$(dx_paused_file "$SESSION_ID")" "$(dx_pause_state_file "$SESSION_ID")" 2>/dev/null || true
    dx_done "Dex lifecycle controls resumed at Phase ${CURRENT_PHASE:-unknown}."
    ;;
  *)
    dx_error "Unknown control command: ${COMMAND}"
    usage >&2
    exit 1
    ;;
esac

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
  local action="$1" target_phase="$2" expected_phase="$3" generation="$4"
  [[ "$DURABLE_LIFECYCLE" -eq 1 && "$expected_phase" =~ ^[0-6]$ ]] || return 1
  dx_lifecycle_activate_pending_control "$SESSION_ID" "$action" "$target_phase" \
    "$expected_phase" "$generation"
}

resume_recorded_phase() {
  dx_lifecycle_resume_completion_context "$SESSION_ID"
}

EXACT_SESSION_ID=""
if [[ "${1:-}" == "--session" ]]; then
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    dx_error "Internal session control requires an exact session ID."
    exit 1
  fi
  EXACT_SESSION_ID="$2"
  shift 2
fi

SESSION_ID="${EXACT_SESSION_ID:-${DEX_SESSION_ID:-$(dx_session_id)}}"
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
COMPLETION_CONTEXT=$(dx_lifecycle_completion_context_read "$SESSION_ID" 2>/dev/null || true)
CONTEXT_PHASE=""
CONTEXT_MODE=""
CONTEXT_PURPOSE=""
CONTEXT_HANDOFF=""
if [[ -n "$COMPLETION_CONTEXT" ]]; then
  IFS=$'\t' read -r CONTEXT_PHASE _ _ _ CONTEXT_MODE CONTEXT_PURPOSE _ \
    CONTEXT_HANDOFF <<< "$COMPLETION_CONTEXT"
fi
CURRENT_PHASE=$(dx_lifecycle_current_phase "$SESSION_ID")
if [[ "$CONTEXT_MODE" == "standalone" || -z "$CURRENT_PHASE" ]]; then
  CURRENT_PHASE="$CONTEXT_PHASE"
fi
DURABLE_LIFECYCLE=0
if [[ "$CONTEXT_MODE" == "lifecycle" && "$CONTEXT_PURPOSE" == "phase" \
  && "$CONTEXT_HANDOFF" == "inline" && "$CURRENT_PHASE" =~ ^[0-6]$ ]]; then
  DURABLE_LIFECYCLE=1
fi
CONTROL_FILE=$(dx_lifecycle_control_file "$SESSION_ID")
PAUSE_CONTEXT_RC=0
dx_lifecycle_pause_context_state "$SESSION_ID" || PAUSE_CONTEXT_RC=$?

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
    if [[ "$PAUSE_CONTEXT_RC" -eq 2 ]]; then
      dx_error "Dex found an unsafe or malformed pause state for this checkout. Repair it before resuming."
      exit 1
    fi
    if [[ -z "$CURRENT_PHASE" && ! -e "$CONTROL_FILE" \
      && ! -L "$CONTROL_FILE" && "$PAUSE_CONTEXT_RC" -eq 1 ]]; then
      dx_info "No Dex lifecycle state was found for this checkout."
      exit 0
    fi
    [[ -n "$CURRENT_PHASE" ]] && printf 'Phase: %s (%s)\n' "$CURRENT_PHASE" "$(phase_label "$CURRENT_PHASE")"
    CONTROL_SNAPSHOT=$(dx_lifecycle_control_snapshot "$SESSION_ID")
    if [[ -z "$CONTROL_SNAPSHOT" \
      && ( -e "$CONTROL_FILE" || -L "$CONTROL_FILE" ) ]]; then
      dx_error "Dex found an unsafe or unreadable human-control receipt. Repair it before changing lifecycle state."
      exit 1
    fi
    CONTROL_ACTION=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" action)
    CONTROL_TARGET=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" target_phase)
    if [[ -n "$CONTROL_ACTION" ]]; then
      printf 'Human control: %s' "$CONTROL_ACTION"
      [[ -n "$CONTROL_TARGET" ]] && printf ' -> Phase %s' "$CONTROL_TARGET"
      printf '\n'
    else
      printf 'Human control: none\n'
    fi
    if [[ "$PAUSE_CONTEXT_RC" -eq 0 ]]; then
      PAUSE_REASON=$(dx_pause_state_read "$SESSION_ID" reason)
      printf 'Lifecycle: paused%s\n' "${PAUSE_REASON:+ (${PAUSE_REASON})}"
    fi
    ;;
  pause|detach|stop|cancel)
    ACTION="pause"
    [[ "$COMMAND" == "stop" || "$COMMAND" == "cancel" ]] && ACTION="cancel"
    dx_write_lifecycle_control "$SESSION_ID" "$ACTION" "" terminal "" "$CURRENT_PHASE" "$OWNER_SESSION"
    if ! dx_lifecycle_detach "$SESSION_ID" "manual-${ACTION}" "terminal"; then
      dx_error "Dex could not prove that completion authorization was revoked. Repair the lifecycle state files and retry ${COMMAND}."
      exit 1
    fi
    dx_done "Dex ${ACTION} accepted for Phase ${CURRENT_PHASE:-unknown}. The workspace and phase state are preserved."
    ;;
  done|complete)
    [[ "$DURABLE_LIFECYCLE" -eq 1 ]] || {
      dx_error "Phase completion controls apply only to an inline Dex lifecycle; this is a standalone or untrusted loop context."
      exit 1
    }
    [[ "$CURRENT_PHASE" =~ ^[0-6]$ ]] || { dx_error "No resumable lifecycle phase was found."; exit 1; }
    TARGET_PHASE=$((CURRENT_PHASE + 1))
    if dx_phase_busy_transition_blocked "$SESSION_ID" 3 "$CURRENT_PHASE" "$TARGET_PHASE"; then
      dx_write_lifecycle_control "$SESSION_ID" pause "" terminal "" "$CURRENT_PHASE" "$OWNER_SESSION"
      if ! dx_lifecycle_detach "$SESSION_ID" "review-child-active" "terminal"; then
        dx_error "Dex could not prove that completion authorization was revoked. Repair the lifecycle state files and retry the phase change."
        exit 1
      fi
      dx_warn "Dex detached at Phase 3 because a review child is still marked in flight. Jump after that process ends."
      exit 0
    fi
    if ! dx_write_lifecycle_control "$SESSION_ID" complete "$TARGET_PHASE" terminal "" \
      "$CURRENT_PHASE" "$OWNER_SESSION"; then
      dx_error "Could not publish the human phase completion."
      exit 1
    fi
    CONTROL_GENERATION="$DX_LIFECYCLE_CONTROL_GENERATION"
    if ! ACTIVATION_RESULT=$(activate_recorded_phase complete "$TARGET_PHASE" \
      "$CURRENT_PHASE" "$CONTROL_GENERATION"); then
      dx_error "Could not reactivate the recorded lifecycle phase."
      exit 1
    fi
    if [[ "$ACTIVATION_RESULT" == "applied" ]]; then
      dx_done "Phase ${CURRENT_PHASE} was marked done and the transition to Phase ${TARGET_PHASE} was applied."
    else
      dx_done "Phase ${CURRENT_PHASE} marked done by human control; transition to Phase ${TARGET_PHASE} is pending."
    fi
    ;;
  jump|phase)
    [[ "$DURABLE_LIFECYCLE" -eq 1 ]] || {
      dx_error "Phase jump controls apply only to an inline Dex lifecycle; this is a standalone or untrusted loop context."
      exit 1
    }
    if ! TARGET_PHASE=$(phase_number "$1"); then
      dx_error "Unknown phase '$1'. Use 0-6, plan, implement, review, verify, pr, or complete."
      exit 1
    fi
    if dx_phase_busy_transition_blocked "$SESSION_ID" 3 "$CURRENT_PHASE" "$TARGET_PHASE"; then
      dx_write_lifecycle_control "$SESSION_ID" pause "" terminal "" "$CURRENT_PHASE" "$OWNER_SESSION"
      if ! dx_lifecycle_detach "$SESSION_ID" "review-child-active" "terminal"; then
        dx_error "Dex could not prove that completion authorization was revoked. Repair the lifecycle state files and retry the phase change."
        exit 1
      fi
      dx_warn "Dex detached at Phase 3 because a review child is still marked in flight. Jump after that process ends."
      exit 0
    fi
    if ! dx_write_lifecycle_control "$SESSION_ID" jump "$TARGET_PHASE" terminal "" \
      "$CURRENT_PHASE" "$OWNER_SESSION"; then
      dx_error "Could not publish the human phase jump."
      exit 1
    fi
    CONTROL_GENERATION="$DX_LIFECYCLE_CONTROL_GENERATION"
    if ! ACTIVATION_RESULT=$(activate_recorded_phase jump "$TARGET_PHASE" \
      "$CURRENT_PHASE" "$CONTROL_GENERATION"); then
      dx_error "Could not reactivate the recorded lifecycle phase."
      exit 1
    fi
    if [[ "$ACTIVATION_RESULT" == "applied" ]]; then
      dx_done "The human-controlled transition to Phase ${TARGET_PHASE} ($(phase_label "$TARGET_PHASE")) was applied."
    else
      dx_done "Human-controlled transition to Phase ${TARGET_PHASE} ($(phase_label "$TARGET_PHASE")) is pending."
    fi
    ;;
  resume)
    if [[ "$PAUSE_CONTEXT_RC" -eq 2 ]]; then
      dx_error "Dex found an unsafe or malformed pause state. Repair it before resuming."
      exit 1
    fi
    if [[ ! -e "$CONTROL_FILE" && ! -L "$CONTROL_FILE" \
      && "$PAUSE_CONTEXT_RC" -eq 1 ]]; then
      dx_info "Dex is not paused for this checkout."
      exit 0
    fi
    dx_write_lifecycle_control "$SESSION_ID" resume "" terminal "" "$CURRENT_PHASE" "$OWNER_SESSION"
    if ! RESUME_RECORD=$(resume_recorded_phase); then
      dx_error "Could not create fresh completion authorization for the recorded lifecycle phase."
      exit 1
    fi
    IFS=$'\t' read -r CURRENT_PHASE RESUME_GENERATION CONTEXT_MODE \
      CONTEXT_PURPOSE <<< "$RESUME_RECORD"
    dx_done "Dex lifecycle controls resumed at Phase ${CURRENT_PHASE:-unknown}."
    dx_info "When the phase audit gate passes, run exactly: bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${SESSION_ID}\" \"${RESUME_GENERATION}\""
    ;;
  *)
    dx_error "Unknown control command: ${COMMAND}"
    usage >&2
    exit 1
    ;;
esac

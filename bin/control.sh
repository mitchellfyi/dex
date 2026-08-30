#!/usr/bin/env bash
# Manage one active Dex lifecycle from a terminal or provider session.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: dx control <status|pause|stop|done|jump PHASE|resume>
       dx control recover review --reason TEXT [--source agent|human]
       dx control override GATE VALUE --reason TEXT [--scope phase|session]
       dx control clear-override GATE --reason TEXT [--scope phase|session]
       dx control waive GATE --reason TEXT

  status       Show the current phase, pending control, and active overrides
  pause        Detach Dex and preserve the current phase for resume
               (detach is an alias)
  stop         Stop Dex enforcement and preserve the workspace
               (cancel is an alias)
  done         Mark the current phase done and advance without its remaining gates
               (complete is an alias)
  jump PHASE   Move to Phase 0-6, or a phase name such as review, verify, or pr
               (phase is an alias)
  resume       Clear a pause and resume the recorded phase
  recover review
               Clear a validated Phase 3 fence only when its owner PID is dead;
               leaves the lifecycle paused for an explicit resume or skip
  override     Change a soft default for this phase or session
  clear-override
               Remove the matching soft-default override
  waive        Mark a named gate waived and advance the current phase safely

Override/control options:
  --source agent|human   Attribution (policy changes default to agent; recovery to human)
  --reason TEXT          Required for recovery, agent controls, and policy changes
  --scope phase|session  Override lifetime scope (default: phase)
  --for-seconds N        Expire an override after N seconds; 0 means no expiry

Common gates:
  review.clean-passes (1-30), review.pass-timeout, phase.timeout,
  watch.command-timeout, sync.budget-minutes,
  maintain.budget-minutes, and guard.<guard-name>. A timeout value of 0
  disables that deadline where supported. Unknown gate names are rejected.
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
    "$expected_phase" "$generation" "${CONTROL_RECEIPT_SOURCE:-terminal}"
}

resume_recorded_phase() {
  dx_lifecycle_resume_completion_context "$SESSION_ID"
}

parse_policy_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)
        [[ $# -ge 2 ]] || { dx_error "--source requires agent or human."; return 1; }
        CONTROL_ORIGIN="$2"
        shift 2
        ;;
      --reason)
        [[ $# -ge 2 ]] || { dx_error "--reason requires text."; return 1; }
        CONTROL_REASON="$2"
        shift 2
        ;;
      --scope)
        [[ $# -ge 2 ]] || { dx_error "--scope requires phase or session."; return 1; }
        CONTROL_SCOPE="$2"
        shift 2
        ;;
      --for-seconds)
        [[ $# -ge 2 ]] || { dx_error "--for-seconds requires a non-negative integer."; return 1; }
        CONTROL_FOR_SECONDS="$2"
        shift 2
        ;;
      *)
        dx_error "Unknown control option: $1"
        return 1
        ;;
    esac
  done
  [[ "$CONTROL_ORIGIN" == "agent" || "$CONTROL_ORIGIN" == "human" ]] || {
    dx_error "--source must be agent or human."
    return 1
  }
  [[ "$CONTROL_SCOPE" == "phase" || "$CONTROL_SCOPE" == "session" ]] || {
    dx_error "--scope must be phase or session."
    return 1
  }
  [[ "$CONTROL_FOR_SECONDS" =~ ^[0-9]+$ \
    && ${#CONTROL_FOR_SECONDS} -le 15 ]] || {
    dx_error "--for-seconds must be a non-negative decimal with at most 15 digits."
    return 1
  }
  if [[ "$CONTROL_ORIGIN" == "agent" && -z "$CONTROL_REASON" ]]; then
    dx_error "--reason is required for an agent override or control."
    return 1
  fi
}

record_control_policy() {
  local gate="$1" value="$2" scope_phase="-" expires_at=0
  if [[ "$CONTROL_SCOPE" == "phase" ]]; then
    scope_phase="$CURRENT_PHASE"
    dx_override_phase_valid "$scope_phase" || {
      dx_error "A phase-scoped override requires an active numeric or prompt-loop phase."
      return 1
    }
  fi
  if [[ "$CONTROL_FOR_SECONDS" -gt 0 ]]; then
    expires_at=$(( $(date +%s) + CONTROL_FOR_SECONDS ))
  fi
  dx_override_set "$SESSION_ID" "$gate" "$value" "$CONTROL_SCOPE" \
    "$scope_phase" "$CONTROL_ORIGIN" "$CONTROL_REASON" "$expires_at"
}

record_control_waiver() {
  dx_override_waive "$SESSION_ID" "$CONTROL_GATE" "$CURRENT_PHASE" \
    "$CONTROL_ORIGIN" "$CONTROL_REASON"
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

CONTROL_ORIGIN="human"
CONTROL_REASON=""
CONTROL_SCOPE="phase"
CONTROL_FOR_SECONDS=0
CONTROL_GATE=""
CONTROL_VALUE=""
TARGET_INPUT=""
RECOVERY_TARGET=""

case "$COMMAND" in
  status)
    [[ $# -eq 0 ]] || { dx_error "dx control ${COMMAND} does not accept arguments."; exit 1; }
    ;;
  resume)
    if [[ $# -gt 0 && "$1" != --* ]]; then
      dx_error "dx control resume does not accept positional arguments."
      exit 1
    fi
    parse_policy_options "$@" || exit 1
    ;;
  pause|detach|stop|cancel|done|complete)
    if [[ $# -gt 0 && "$1" != --* ]]; then
      dx_error "dx control ${COMMAND} does not accept arguments."
      exit 1
    fi
    parse_policy_options "$@" || exit 1
    ;;
  jump|phase)
    [[ $# -ge 1 ]] || { dx_error "Usage: dx control jump <0-6|phase-name>"; exit 1; }
    TARGET_INPUT="$1"
    shift
    parse_policy_options "$@" || exit 1
    ;;
  recover)
    [[ $# -ge 1 ]] || {
      dx_error "Usage: dx control recover review --reason TEXT"
      exit 1
    }
    RECOVERY_TARGET="$1"
    shift
    parse_policy_options "$@" || exit 1
    if ! RECOVERY_PHASE=$(phase_number "$RECOVERY_TARGET") \
      || [[ "$RECOVERY_PHASE" != "3" ]]; then
      dx_error "Recovery currently supports only the Phase 3 review fence."
      exit 1
    fi
    [[ -n "$CONTROL_REASON" ]] || {
      dx_error "--reason is required for review-fence recovery."
      exit 1
    }
    [[ "$CONTROL_SCOPE" == "phase" && "$CONTROL_FOR_SECONDS" -eq 0 ]] || {
      dx_error "Review-fence recovery does not accept --scope or --for-seconds."
      exit 1
    }
    ;;
  override)
    [[ $# -ge 2 ]] || { dx_error "Usage: dx control override GATE VALUE --reason TEXT"; exit 1; }
    CONTROL_GATE="$1"
    CONTROL_VALUE="$2"
    shift 2
    CONTROL_ORIGIN="agent"
    parse_policy_options "$@" || exit 1
    [[ -n "$CONTROL_REASON" ]] || { dx_error "--reason is required for an override."; exit 1; }
    ;;
  clear-override)
    [[ $# -ge 1 ]] || { dx_error "Usage: dx control clear-override GATE --reason TEXT"; exit 1; }
    CONTROL_GATE="$1"
    shift
    CONTROL_ORIGIN="agent"
    parse_policy_options "$@" || exit 1
    [[ -n "$CONTROL_REASON" ]] || { dx_error "--reason is required for an override."; exit 1; }
    ;;
  waive)
    [[ $# -ge 1 ]] || { dx_error "Usage: dx control waive GATE --reason TEXT"; exit 1; }
    CONTROL_GATE="$1"
    shift
    CONTROL_ORIGIN="agent"
    parse_policy_options "$@" || exit 1
    [[ -n "$CONTROL_REASON" ]] || { dx_error "--reason is required for a waiver."; exit 1; }
    [[ "$CONTROL_SCOPE" == "phase" ]] || { dx_error "A gate waiver is phase-scoped."; exit 1; }
    ;;
esac

if [[ "$COMMAND" != "status" && "$COMMAND" != "resume" ]] \
  && ! dx_lifecycle_session_active "$SESSION_ID"; then
  if [[ ( "$COMMAND" == "override" || "$COMMAND" == "clear-override" ) \
    && "$CONTROL_SCOPE" == "session" ]]; then
    : # Standalone provider sessions may keep provider-neutral session policy.
  else
    dx_error "No active Dex lifecycle was found for this checkout."
    exit 1
  fi
fi

OWNER_SESSION=""
[[ -f "$(dx_owner_file "$SESSION_ID")" ]] && OWNER_SESSION=$(cat "$(dx_owner_file "$SESSION_ID")" 2>/dev/null || true)

case "$COMMAND" in
  status)
    if [[ "$PAUSE_CONTEXT_RC" -eq 2 ]]; then
      dx_error "Dex found an unsafe or malformed pause state for this checkout. Repair it before resuming."
      exit 1
    fi
    ACTIVE_OVERRIDES=$(dx_override_list "$SESSION_ID" "${CURRENT_PHASE:--}") || {
      dx_error "Dex found an unsafe or malformed override journal."
      exit 1
    }
    if [[ -z "$CURRENT_PHASE" && ! -e "$CONTROL_FILE" \
      && ! -L "$CONTROL_FILE" && "$PAUSE_CONTEXT_RC" -eq 1 \
      && -z "$ACTIVE_OVERRIDES" ]]; then
      dx_info "No Dex lifecycle state was found for this checkout."
      exit 0
    fi
    [[ -n "$CURRENT_PHASE" ]] && printf 'Phase: %s (%s)\n' "$CURRENT_PHASE" "$(phase_label "$CURRENT_PHASE")"
    CONTROL_SNAPSHOT=$(dx_lifecycle_control_snapshot "$SESSION_ID")
    if [[ -z "$CONTROL_SNAPSHOT" \
      && ( -e "$CONTROL_FILE" || -L "$CONTROL_FILE" ) ]]; then
      dx_error "Dex found an unsafe or unreadable control receipt. Repair it before changing lifecycle state."
      exit 1
    fi
    CONTROL_ACTION=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" action)
    CONTROL_TARGET=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" target_phase)
    CONTROL_SOURCE=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" source)
    if [[ -n "$CONTROL_ACTION" ]]; then
      printf 'Control (%s): %s' "${CONTROL_SOURCE:-unknown}" "$CONTROL_ACTION"
      [[ -n "$CONTROL_TARGET" ]] && printf ' -> Phase %s' "$CONTROL_TARGET"
      printf '\n'
    else
      printf 'Control: none\n'
    fi
    if [[ "$PAUSE_CONTEXT_RC" -eq 0 ]]; then
      PAUSE_REASON=$(dx_pause_state_read "$SESSION_ID" reason)
      printf 'Lifecycle: paused%s\n' "${PAUSE_REASON:+ (${PAUSE_REASON})}"
    fi
    REVIEW_OWNER_STATUS=$(dx_phase_busy_owner_status "$SESSION_ID" 3)
    REVIEW_OWNER_KIND="${REVIEW_OWNER_STATUS%%$'\t'*}"
    REVIEW_OWNER_PID=""
    [[ "$REVIEW_OWNER_STATUS" == *$'\t'* ]] \
      && REVIEW_OWNER_PID="${REVIEW_OWNER_STATUS#*$'\t'}"
    case "$REVIEW_OWNER_KIND" in
      live) printf 'Review fence: active (owner PID %s)\n' "$REVIEW_OWNER_PID" ;;
      dead)
        printf 'Review fence: stale (owner PID %s is dead)\n' "$REVIEW_OWNER_PID"
        printf '%s\n' 'Recovery: dx control recover review --source agent --reason "<why the review owner stopped>"'
        ;;
      invalid) printf '%s\n' 'Review fence: malformed (automatic recovery is disabled)' ;;
    esac
    if [[ -n "$ACTIVE_OVERRIDES" ]]; then
      printf 'Overrides:\n'
      while IFS=$'\t' read -r OVERRIDE_GATE OVERRIDE_VALUE OVERRIDE_SCOPE \
        OVERRIDE_PHASE OVERRIDE_SOURCE OVERRIDE_EXPIRY OVERRIDE_REASON; do
        OVERRIDE_SCOPE_DETAIL="$OVERRIDE_SCOPE"
        [[ "$OVERRIDE_SCOPE" == "phase" ]] \
          && OVERRIDE_SCOPE_DETAIL="${OVERRIDE_SCOPE} ${OVERRIDE_PHASE}"
        OVERRIDE_EXPIRY_DETAIL=""
        [[ "$OVERRIDE_EXPIRY" != "0" ]] \
          && OVERRIDE_EXPIRY_DETAIL=", expires ${OVERRIDE_EXPIRY}"
        printf '  %s=%s (%s, %s%s): %s\n' "$OVERRIDE_GATE" \
          "$OVERRIDE_VALUE" "$OVERRIDE_SCOPE_DETAIL" "$OVERRIDE_SOURCE" \
          "$OVERRIDE_EXPIRY_DETAIL" "$OVERRIDE_REASON"
      done <<< "$ACTIVE_OVERRIDES"
    else
      printf 'Overrides: none\n'
    fi
    ;;
  recover)
    RECOVERY_RESULT_RC=0
    dx_lifecycle_recover_review_fence "$SESSION_ID" "$CONTROL_ORIGIN" \
      "$CONTROL_REASON" || RECOVERY_RESULT_RC=$?
    case "$RECOVERY_RESULT_RC" in
      0)
        dx_done "Recovered the stale Phase 3 review fence. The lifecycle remains paused."
        dx_info "Use /dxresume to retry Phase 3 or /dxskip to move on with a recorded waiver."
        ;;
      2)
        dx_error "No Phase 3 review fence was found. Nothing was changed."
        exit 1
        ;;
      3)
        dx_error "The Phase 3 review fence is malformed or untrusted. Nothing was removed."
        exit 1
        ;;
      4)
        REVIEW_OWNER_STATUS=$(dx_phase_busy_owner_status "$SESSION_ID" 3)
        REVIEW_OWNER_PID="${REVIEW_OWNER_STATUS#*$'\t'}"
        dx_error "The Phase 3 review owner PID ${REVIEW_OWNER_PID} is still alive. Interrupt or wait for that process, then retry recovery."
        exit 1
        ;;
      *)
        dx_error "Dex could not safely recover the Phase 3 review fence. The lifecycle remains paused."
        exit 1
        ;;
    esac
    ;;
  override)
    if ! record_control_policy "$CONTROL_GATE" "$CONTROL_VALUE"; then
      dx_error "Could not persist the override. Check its gate, value, scope, and state file."
      exit 1
    fi
    dx_done "Override ${CONTROL_GATE}=${CONTROL_VALUE} is active for this ${CONTROL_SCOPE}."
    dx_info "Source: ${CONTROL_ORIGIN}; reason: ${CONTROL_REASON}"
    ;;
  clear-override)
    CLEAR_PHASE="-"
    [[ "$CONTROL_SCOPE" == "phase" ]] && CLEAR_PHASE="$CURRENT_PHASE"
    if ! dx_override_clear "$SESSION_ID" "$CONTROL_GATE" "$CONTROL_SCOPE" \
      "$CLEAR_PHASE" "$CONTROL_ORIGIN" "$CONTROL_REASON"; then
      dx_error "Could not clear the override. Check its gate, scope, and state file."
      exit 1
    fi
    dx_done "Override ${CONTROL_GATE} was cleared for this ${CONTROL_SCOPE}."
    ;;
  pause|detach|stop|cancel)
    ACTION="pause"
    [[ "$COMMAND" == "stop" || "$COMMAND" == "cancel" ]] && ACTION="cancel"
    CONTROL_RECEIPT_SOURCE="terminal"
    [[ "$CONTROL_ORIGIN" == "agent" ]] && CONTROL_RECEIPT_SOURCE="agent"
    if [[ -n "$CONTROL_REASON" ]]; then
      record_control_policy "control.${ACTION}" requested || exit 1
    fi
    if ! dx_write_lifecycle_control "$SESSION_ID" "$ACTION" "" "$CONTROL_RECEIPT_SOURCE" "" "$CURRENT_PHASE" "$OWNER_SESSION"; then
      dx_error "Could not publish the ${ACTION} control."
      exit 1
    fi
    if ! dx_lifecycle_detach "$SESSION_ID" "manual-${ACTION}" "$CONTROL_RECEIPT_SOURCE"; then
      dx_error "Dex could not prove that completion authorization was revoked. Repair the lifecycle state files and retry ${COMMAND}."
      exit 1
    fi
    dx_done "Dex ${ACTION} accepted for Phase ${CURRENT_PHASE:-unknown}. The workspace and phase state are preserved."
    ;;
  done|complete|waive)
    [[ "$DURABLE_LIFECYCLE" -eq 1 ]] || {
      dx_error "Phase completion controls apply only to an inline Dex lifecycle; this is a standalone or untrusted loop context."
      exit 1
    }
    [[ "$CURRENT_PHASE" =~ ^[0-6]$ ]] || { dx_error "No resumable lifecycle phase was found."; exit 1; }
    if [[ "$COMMAND" == "waive" ]]; then
      record_control_waiver || {
        dx_error "Could not record the waiver. Check its gate and lifecycle state."
        exit 1
      }
    elif [[ -n "$CONTROL_REASON" ]]; then
      record_control_policy phase.completion waived || exit 1
    fi
    CONTROL_RECEIPT_SOURCE="terminal"
    [[ "$CONTROL_ORIGIN" == "agent" ]] && CONTROL_RECEIPT_SOURCE="agent"
    TARGET_PHASE=$((CURRENT_PHASE + 1))
    if dx_phase_busy_transition_blocked "$SESSION_ID" 3 "$CURRENT_PHASE" "$TARGET_PHASE"; then
      if ! dx_write_lifecycle_control "$SESSION_ID" pause "" "$CONTROL_RECEIPT_SOURCE" "" "$CURRENT_PHASE" "$OWNER_SESSION"; then
        dx_error "Could not publish the pause control."
        exit 1
      fi
      if ! dx_lifecycle_detach "$SESSION_ID" "review-child-active" "$CONTROL_RECEIPT_SOURCE"; then
        dx_error "Dex could not prove that completion authorization was revoked. Repair the lifecycle state files and retry the phase change."
        exit 1
      fi
      dx_warn "Dex detached at Phase 3 because a review child is still marked in flight. If an interrupt killed its owner, run: dx control recover review --source agent --reason \"<why>\""
      exit 0
    fi
    if ! dx_write_lifecycle_control "$SESSION_ID" complete "$TARGET_PHASE" "$CONTROL_RECEIPT_SOURCE" "" \
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
      dx_done "Phase ${CURRENT_PHASE} marked done by ${CONTROL_ORIGIN} override; transition to Phase ${TARGET_PHASE} is pending."
    fi
    ;;
  jump|phase)
    [[ "$DURABLE_LIFECYCLE" -eq 1 ]] || {
      dx_error "Phase jump controls apply only to an inline Dex lifecycle; this is a standalone or untrusted loop context."
      exit 1
    }
    if ! TARGET_PHASE=$(phase_number "$TARGET_INPUT"); then
      dx_error "Unknown phase '$TARGET_INPUT'. Use 0-6, plan, implement, review, verify, pr, or complete."
      exit 1
    fi
    if [[ -n "$CONTROL_REASON" ]]; then
      record_control_policy phase.jump "$TARGET_PHASE" || exit 1
    fi
    CONTROL_RECEIPT_SOURCE="terminal"
    [[ "$CONTROL_ORIGIN" == "agent" ]] && CONTROL_RECEIPT_SOURCE="agent"
    if dx_phase_busy_transition_blocked "$SESSION_ID" 3 "$CURRENT_PHASE" "$TARGET_PHASE"; then
      if ! dx_write_lifecycle_control "$SESSION_ID" pause "" "$CONTROL_RECEIPT_SOURCE" "" "$CURRENT_PHASE" "$OWNER_SESSION"; then
        dx_error "Could not publish the pause control."
        exit 1
      fi
      if ! dx_lifecycle_detach "$SESSION_ID" "review-child-active" "$CONTROL_RECEIPT_SOURCE"; then
        dx_error "Dex could not prove that completion authorization was revoked. Repair the lifecycle state files and retry the phase change."
        exit 1
      fi
      dx_warn "Dex detached at Phase 3 because a review child is still marked in flight. If an interrupt killed its owner, run: dx control recover review --source agent --reason \"<why>\""
      exit 0
    fi
    if ! dx_write_lifecycle_control "$SESSION_ID" jump "$TARGET_PHASE" "$CONTROL_RECEIPT_SOURCE" "" \
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
      dx_done "The ${CONTROL_ORIGIN} override to Phase ${TARGET_PHASE} ($(phase_label "$TARGET_PHASE")) was applied."
    else
      dx_done "The ${CONTROL_ORIGIN} override to Phase ${TARGET_PHASE} ($(phase_label "$TARGET_PHASE")) is pending."
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
    CONTROL_RECEIPT_SOURCE="terminal"
    [[ "$CONTROL_ORIGIN" == "agent" ]] && CONTROL_RECEIPT_SOURCE="agent"
    if [[ -n "$CONTROL_REASON" ]]; then
      record_control_policy control.resume requested || exit 1
    fi
    if ! dx_write_lifecycle_control "$SESSION_ID" resume "" "$CONTROL_RECEIPT_SOURCE" \
      "" "$CURRENT_PHASE" "$OWNER_SESSION"; then
      dx_error "Could not publish the resume control."
      exit 1
    fi
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

#!/usr/bin/env bash
# UserPromptSubmit hook — honor direct human lifecycle control and pause Phase 6 watchers.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
dx_lifecycle_session_id_valid "$SESSION_ID" || exit 0
HOOK_INPUT=$(cat)

__dx_user_prompt_from_json() {
  printf '%s' "$HOOK_INPUT" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

prompt = data.get("prompt", "")
if isinstance(prompt, str):
    print(prompt)
' 2>/dev/null
}

__dx_hook_session_from_json() {
  printf '%s' "$HOOK_INPUT" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

session_id = data.get("session_id", "")
if isinstance(session_id, str):
    print(session_id)
' 2>/dev/null
}

__dx_complete_phase_active() {
  local phase config_raw config_phase

  [[ "${DEX_LOOP_PHASE:-}" == "6" ]] && return 0

  phase=$(cat "$(dx_state_file "$SESSION_ID")" 2>/dev/null || echo "")
  [[ "$phase" == "6" ]] && return 0

  config_raw=$(cat "$(dx_loop_config_file "$SESSION_ID")" 2>/dev/null || echo "")
  config_phase="${config_raw%%:*}"
  [[ "$config_phase" == "6" ]] && return 0

  if [[ "${DEX_LOOP_ACTIVE:-}" == "1" || -f "$(dx_active_file "$SESSION_ID")" ]]; then
    [[ -f "$(dx_complete_state_file "$SESSION_ID")" ]] && return 0
  fi

  return 1
}

__dx_lifecycle_phase_label() {
  case "$1" in
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

__dx_write_human_control() {
  local action="$1" target_phase="$2" prompt_sha256="$3"
  if ! dx_write_lifecycle_control "$SESSION_ID" "$action" "$target_phase" user-prompt \
    "$prompt_sha256" "$CURRENT_PHASE" "$HOOK_CLAUDE_SESSION_ID"; then
    dx_run_log_append_for_session "$SESSION_ID" "error" "human-control" \
      "Failed to persist direct human lifecycle instruction" 2>/dev/null || true
    return 1
  fi
  dx_run_log_append_for_session "$SESSION_ID" "warn" "human-control" \
    "Direct human lifecycle instruction: action=${action}; target_phase=${target_phase:-none}; prompt_sha256=${prompt_sha256}" 2>/dev/null || true
}

__dx_detach_lifecycle_now() {
  local action="${1:-pause}" reason="${2:-manual-${1:-pause}}"
  dx_write_pause_state "$SESSION_ID" "$reason" "user-prompt" 2>/dev/null || true
  if [[ -f "$(dx_phase_busy_file "$SESSION_ID" 3)" ]]; then
    dx_phase_busy_request_cancel "$SESSION_ID" 3 2>/dev/null || true
  fi
  touch "$(dx_paused_file "$SESSION_ID")"
  rm -f "$(dx_active_file "$SESSION_ID")" \
    "$(dx_complete_file "$SESSION_ID")" "$(dx_loop_file "$SESSION_ID")" 2>/dev/null || true
  dx_write_watch_pause "$SESSION_ID" "human-${action}" 2>/dev/null || true
}

__dx_prompt_resumes_watchers() {
  local prompt_lc="$1"

  # Keep the watcher paused when the user explicitly negates a nearby resume
  # action. This check must run before the positive keyword checks below.
  if [[ "$prompt_lc" =~ (do[[:space:]]+not|don.t|dont|never)[[:space:]]+([^[:space:]]+[[:space:]]+){0,3}(resume|restart|continue|run|start|enable|watch|monitor|/dxcomplete) ]]; then
    return 1
  fi

  [[ "$prompt_lc" == *"/dxcomplete"* ]] && return 0

  if [[ "$prompt_lc" == *"resume"* ]]; then
    [[ "$prompt_lc" == *"watcher"* ]] && return 0
    [[ "$prompt_lc" == *"watching"* ]] && return 0
    [[ "$prompt_lc" == *"autonomous monitoring"* ]] && return 0
  fi

  return 1
}

PROMPT=$(__dx_user_prompt_from_json || printf '%s' "$HOOK_INPUT")
PROMPT_LC=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')
HOOK_CLAUDE_SESSION_ID=$(__dx_hook_session_from_json || true)
HOOK_SESSION_VALID=0
dx_lifecycle_session_id_valid "$HOOK_CLAUDE_SESSION_ID" && HOOK_SESSION_VALID=1

OWNER_ID=""
OWNER_FILE=$(dx_owner_file "$SESSION_ID")
if [[ ( -e "$OWNER_FILE" || -L "$OWNER_FILE" ) && ( ! -f "$OWNER_FILE" || -L "$OWNER_FILE" ) ]]; then
  exit 0
fi
[[ -f "$OWNER_FILE" ]] && OWNER_ID=$(cat "$OWNER_FILE" 2>/dev/null || true)
if [[ -n "$OWNER_ID" && ( "$HOOK_SESSION_VALID" -ne 1 || "$OWNER_ID" != "$HOOK_CLAUDE_SESSION_ID" ) ]]; then
  exit 0
fi

LIFECYCLE_ACTIVE=0
dx_lifecycle_session_active "$SESSION_ID" && LIFECYCLE_ACTIVE=1
if [[ "$LIFECYCLE_ACTIVE" -eq 1 ]]; then
  if [[ -z "$OWNER_ID" ]]; then
    if [[ "$HOOK_SESSION_VALID" -ne 1 || "${DEX_LOOP_ACTIVE:-}" != "1" \
      || -z "${DEX_SESSION_ID:-}" || "$DEX_SESSION_ID" != "$SESSION_ID" ]] \
      || ! dx_lifecycle_session_id_valid "$DEX_SESSION_ID"; then
      exit 0
    fi
    if ! dx_lifecycle_atomic_write "$OWNER_FILE" "$HOOK_CLAUDE_SESSION_ID"; then
      exit 0
    fi
    OWNER_ID="$HOOK_CLAUDE_SESSION_ID"
  fi

  CURRENT_PHASE=$(dx_lifecycle_current_phase "$SESSION_ID")
  CONTROL_FIELDS=$(printf '%s' "$PROMPT" | python3 "$DEX_DIR/scripts/lifecycle-control.py" \
    --phase "$CURRENT_PHASE" --format tsv 2>/dev/null || true)
  CONTROL_ACTION=""
  CONTROL_TARGET=""
  CONTROL_HASH=""
  if [[ -n "$CONTROL_FIELDS" ]]; then
    IFS=$'\t' read -r CONTROL_ACTION CONTROL_TARGET CONTROL_HASH <<< "$CONTROL_FIELDS"
    [[ "$CONTROL_TARGET" == "-" ]] && CONTROL_TARGET=""
  fi

  case "$CONTROL_ACTION" in
    resume)
      __dx_write_human_control resume "" "$CONTROL_HASH" || exit 0
      dx_clear_lifecycle_control "$SESSION_ID"
      rm -f "$(dx_paused_file "$SESSION_ID")" "$(dx_pause_state_file "$SESSION_ID")" 2>/dev/null || true
      dx_clear_watch_pause "$SESSION_ID"
      if [[ -f "$(dx_loop_config_file "$SESSION_ID")" || -f "$(dx_handoff_mode_file "$SESSION_ID")" ]]; then
        touch "$(dx_active_file "$SESSION_ID")"
      fi
      cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Direct human instruction accepted. Dex lifecycle controls resumed for this session. Continue the current phase unless the user's prompt gives a different scope."}}
JSON
      exit 0
      ;;
    pause|cancel)
      __dx_write_human_control "$CONTROL_ACTION" "" "$CONTROL_HASH" || exit 0
      __dx_detach_lifecycle_now "$CONTROL_ACTION"
      cat <<JSON
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Direct human ${CONTROL_ACTION} instruction accepted. The latest human request has priority over Dex phase, review, verification, skill, and audit-loop instructions. Dex lifecycle sequencing is disabled for this session; review-wave session isolation and security guards remain active. Commit, push, and PR operations are not phase-blocked. Follow the user's request now; if no other work was requested, stop normally. Do not write Dex completion or readiness markers. The lifecycle can be restarted later with a direct 'resume Dex' instruction or the normal dx resume command."}}
JSON
      exit 0
      ;;
    complete|jump)
      if dx_phase_busy_transition_blocked "$SESSION_ID" 3 "$CURRENT_PHASE" "$CONTROL_TARGET"; then
        __dx_write_human_control pause "" "$CONTROL_HASH" || exit 0
        __dx_detach_lifecycle_now pause review-child-active
        cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Direct human instruction accepted. Dex detached from Phase 3 immediately. A review child was still marked in flight, so Dex did not jump across it while it could still edit files. The latest human request has priority; stop normally and resume or jump after the review process has ended."}}
JSON
        exit 0
      fi
      __dx_write_human_control "$CONTROL_ACTION" "$CONTROL_TARGET" "$CONTROL_HASH" || exit 0
      rm -f "$(dx_paused_file "$SESSION_ID")" "$(dx_complete_file "$SESSION_ID")" 2>/dev/null || true
      TARGET_LABEL=$(__dx_lifecycle_phase_label "$CONTROL_TARGET")
      cat <<JSON
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Direct human lifecycle instruction accepted. The latest human request has priority over Dex phase and audit gates. Dex will move to Phase ${CONTROL_TARGET} (${TARGET_LABEL}) without requiring the skipped phase's readiness, review, or verification markers. Stop once now so the Stop hook can apply the human-authorized transition, then follow the new phase handoff."}}
JSON
      exit 0
      ;;
  esac
fi

if ! __dx_complete_phase_active; then
  exit 0
fi

if __dx_prompt_resumes_watchers "$PROMPT_LC"; then
  dx_clear_watch_pause "$SESSION_ID"
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Dex resumed scheduled Phase 6 watcher loops for this session."}}
JSON
  exit 0
fi

dx_write_watch_pause "$SESSION_ID" "user-prompt"
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Dex detected a direct user prompt during Phase 6 and paused the scheduled PR watcher loop for this session. Prioritize the user's latest request. Do not run /dxwatchpr unless the user asks to resume autonomous monitoring."}}
JSON

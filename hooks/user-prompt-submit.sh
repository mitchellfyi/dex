#!/usr/bin/env bash
# UserPromptSubmit hook — honor direct human lifecycle control and pause Phase 6 watchers.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

# Review waves are one-shot child processes. Their generated task prompt is
# not a human lifecycle instruction, and there is no later interactive turn
# in which a parsed control could safely run. The parent review loop owns all
# pause, cancel, and phase decisions for these children.
if [[ "${DEX_REVIEW_PASS_ACTIVE:-}" == "1" ]]; then
  exit 0
fi

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
dx_lifecycle_session_id_valid "$SESSION_ID" || exit 0
HOOK_INPUT=$(cat)

# Read both fields in one interpreter start. This hook runs on every user
# prompt, and two python3 launches to read two keys out of the same object was
# the largest thing it did.
#
# The prompt is printed last and may contain newlines; the session id may not,
# so a single leading line carries it. Fields are printed even when absent, so
# the caller can tell "not present" from "payload was not JSON" (exit 1).
__dx_hook_fields_from_json() {
  printf '%s' "$HOOK_INPUT" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)


def text(value):
    return value if isinstance(value, str) else ""


print(text(data.get("session_id", "")).replace("\n", " "))
print(text(data.get("prompt", "")), end="")
' 2>/dev/null
}

__dx_complete_phase_active() {
  local phase completion_context config_phase

  [[ "${DEX_LOOP_PHASE:-}" == "6" ]] && return 0

  phase=$(dx_lifecycle_current_phase "$SESSION_ID")
  [[ "$phase" == "6" ]] && return 0

  completion_context=$(dx_lifecycle_completion_context_read "$SESSION_ID" \
    2>/dev/null || true)
  config_phase="${completion_context%%$'\t'*}"
  [[ "$config_phase" == "6" ]] && return 0

  if [[ "${DEX_LOOP_ACTIVE:-}" == "1" || -f "$(dx_active_file "$SESSION_ID")" ]]; then
    [[ -f "$(dx_complete_state_file "$SESSION_ID")" ]] && return 0
  fi

  return 1
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
  dx_lifecycle_detach "$SESSION_ID" "$reason" "user-prompt" || return 1
  dx_write_watch_pause "$SESSION_ID" "human-${action}" 2>/dev/null || true
}

__dx_report_detach_failure() {
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Dex received the human control request but could not prove that completion authorization was revoked. It did not report a clean detach. Repair the lifecycle state files and retry the control before resuming automated work."}}
JSON
}

__dx_resume_lifecycle_now() {
  local resume_record _resume_phase _resume_mode _resume_purpose
  resume_record=$(dx_lifecycle_resume_completion_context "$SESSION_ID") || return 1
  IFS=$'\t' read -r _resume_phase RESUME_COMPLETION_GENERATION \
    _resume_mode _resume_purpose <<< "$resume_record"
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

HOOK_CLAUDE_SESSION_ID=""
PROMPT=""
if HOOK_FIELDS=$(__dx_hook_fields_from_json); then
  case "$HOOK_FIELDS" in
    # Command substitution eats the trailing newline, so an empty prompt leaves
    # no separator behind and the session id would be read as the prompt too.
    *$'\n'*)
      HOOK_CLAUDE_SESSION_ID="${HOOK_FIELDS%%$'\n'*}"
      PROMPT="${HOOK_FIELDS#*$'\n'}"
      ;;
    *) HOOK_CLAUDE_SESSION_ID="$HOOK_FIELDS" ;;
  esac
else
  # Not JSON: the whole payload is the prompt, as it was before hooks sent one.
  PROMPT="$HOOK_INPUT"
fi
PROMPT_LC=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')
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
COMPLETION_CONTEXT=$(dx_lifecycle_completion_context_read "$SESSION_ID" 2>/dev/null || true)
CONTEXT_PHASE=""
CONTEXT_MODE=""
CONTEXT_PURPOSE=""
CONTEXT_HANDOFF=""
if [[ -n "$COMPLETION_CONTEXT" ]]; then
  IFS=$'\t' read -r CONTEXT_PHASE _ _ _ CONTEXT_MODE CONTEXT_PURPOSE _ \
    CONTEXT_HANDOFF <<< "$COMPLETION_CONTEXT"
fi
if [[ "$LIFECYCLE_ACTIVE" -ne 1 && -n "$COMPLETION_CONTEXT" \
  && -f "$(dx_paused_file "$SESSION_ID")" ]]; then
  LIFECYCLE_ACTIVE=1
fi
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
  if [[ "$CONTEXT_MODE" == "standalone" || -z "$CURRENT_PHASE" ]]; then
    CURRENT_PHASE="$CONTEXT_PHASE"
  fi
  CONTROL_FIELDS=$(printf '%s' "$PROMPT" | python3 "$DEX_DIR/scripts/lifecycle-control.py" \
    --phase "$CURRENT_PHASE" --format tsv 2>/dev/null || true)
  CONTROL_ACTION=""
  CONTROL_TARGET=""
  CONTROL_HASH=""
  if [[ -n "$CONTROL_FIELDS" ]]; then
    IFS=$'\t' read -r CONTROL_ACTION CONTROL_TARGET CONTROL_HASH <<< "$CONTROL_FIELDS"
    [[ "$CONTROL_TARGET" == "-" ]] && CONTROL_TARGET=""
  fi

  if [[ "$CONTROL_ACTION" == "complete" || "$CONTROL_ACTION" == "jump" ]]; then
    if [[ "$CONTEXT_MODE" != "lifecycle" || "$CONTEXT_PURPOSE" != "phase" \
      || "$CONTEXT_HANDOFF" != "inline" ]]; then
      cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Dex did not apply that phase transition because this session is a standalone loop, not an inline lifecycle. You can pause or stop the loop, or let its own completion contract finish it."}}
JSON
      exit 0
    fi
  fi

  case "$CONTROL_ACTION" in
    resume)
      __dx_write_human_control resume "" "$CONTROL_HASH" || exit 0
      if ! __dx_resume_lifecycle_now; then
        cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Dex received the resume request but could not create a fresh completion authorization. The lifecycle remains paused; fix the state-file error and resume again."}}
JSON
        exit 0
      fi
      dx_clear_watch_pause "$SESSION_ID"
      cat <<JSON
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Direct human instruction accepted. Dex lifecycle controls resumed for this session with fresh completion authorization. Continue the current phase unless the user's prompt gives a different scope. When its audit gate passes, run exactly: bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${SESSION_ID}\" \"${RESUME_COMPLETION_GENERATION}\""}}
JSON
      exit 0
      ;;
    pause|cancel)
      __dx_write_human_control "$CONTROL_ACTION" "" "$CONTROL_HASH" || exit 0
      if ! __dx_detach_lifecycle_now "$CONTROL_ACTION"; then
        __dx_report_detach_failure
        exit 0
      fi
      cat <<JSON
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Direct human ${CONTROL_ACTION} instruction accepted. The latest human request has priority over Dex phase, review, verification, skill, and audit-loop instructions. Dex lifecycle sequencing is disabled for this session; review-wave session isolation and security guards remain active. Commit, push, and PR operations are not phase-blocked. Follow the user's request now; if no other work was requested, stop normally. Do not write Dex completion or readiness markers. The lifecycle can be restarted later with a direct 'resume Dex' instruction or the normal dx resume command."}}
JSON
      exit 0
      ;;
    complete|jump)
      if dx_phase_busy_transition_blocked "$SESSION_ID" 3 "$CURRENT_PHASE" "$CONTROL_TARGET"; then
        __dx_write_human_control pause "" "$CONTROL_HASH" || exit 0
        if ! __dx_detach_lifecycle_now pause review-child-active; then
          __dx_report_detach_failure
          exit 0
        fi
        cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Direct human instruction accepted. Dex detached from Phase 3 immediately. A review child was still marked in flight, so Dex did not jump across it while it could still edit files. The latest human request has priority; stop normally and resume or jump after the review process has ended."}}
JSON
        exit 0
      fi
      __dx_write_human_control "$CONTROL_ACTION" "$CONTROL_TARGET" "$CONTROL_HASH" || exit 0
      rm -f "$(dx_paused_file "$SESSION_ID")" "$(dx_complete_file "$SESSION_ID")" 2>/dev/null || true
      TARGET_LABEL=$(dx_lifecycle_phase_label "$CONTROL_TARGET")
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

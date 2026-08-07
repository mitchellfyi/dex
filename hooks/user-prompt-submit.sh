#!/usr/bin/env bash
# UserPromptSubmit hook — pause Phase 6 scheduled watchers during manual user work.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
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

if ! __dx_complete_phase_active; then
  exit 0
fi

PROMPT=$(__dx_user_prompt_from_json || printf '%s' "$HOOK_INPUT")
PROMPT_LC=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')

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

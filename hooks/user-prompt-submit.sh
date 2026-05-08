#!/usr/bin/env bash
# UserPromptSubmit hook — pause Phase 6 scheduled watchers during manual user work.
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
HOOK_INPUT=$(cat)

__dk_user_prompt_from_json() {
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

__dk_complete_phase_active() {
  local phase config_raw config_phase

  [[ "${DOYAKEN_LOOP_PHASE:-}" == "6" ]] && return 0

  phase=$(cat "$(dk_state_file "$SESSION_ID")" 2>/dev/null || echo "")
  [[ "$phase" == "6" ]] && return 0

  config_raw=$(cat "$(dk_loop_config_file "$SESSION_ID")" 2>/dev/null || echo "")
  config_phase="${config_raw%%:*}"
  [[ "$config_phase" == "6" ]] && return 0

  if [[ "${DOYAKEN_LOOP_ACTIVE:-}" == "1" || -f "$(dk_active_file "$SESSION_ID")" ]]; then
    [[ -f "$(dk_complete_state_file "$SESSION_ID")" ]] && return 0
  fi

  return 1
}

__dk_prompt_resumes_watchers() {
  local prompt_lc="$1"

  [[ "$prompt_lc" == *"/dkcomplete"* ]] && return 0

  if [[ "$prompt_lc" == *"resume"* ]]; then
    [[ "$prompt_lc" == *"watcher"* ]] && return 0
    [[ "$prompt_lc" == *"watching"* ]] && return 0
    [[ "$prompt_lc" == *"autonomous monitoring"* ]] && return 0
  fi

  return 1
}

if ! __dk_complete_phase_active; then
  exit 0
fi

PROMPT=$(__dk_user_prompt_from_json || printf '%s' "$HOOK_INPUT")
PROMPT_LC=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')

if __dk_prompt_resumes_watchers "$PROMPT_LC"; then
  dk_clear_watch_pause "$SESSION_ID"
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Doyaken resumed scheduled Phase 6 watcher loops for this session."}}
JSON
  exit 0
fi

dk_write_watch_pause "$SESSION_ID" "user-prompt"
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Doyaken detected a direct user prompt during Phase 6 and paused scheduled CI/PR watcher loops for this session. Prioritize the user's latest request. Do not run /dkwatchci or /dkwatchpr unless the user asks to resume autonomous monitoring."}}
JSON

#!/usr/bin/env bash
# SessionEnd hook — records session end time and cleans up ephemeral state files.
# Runs when a Claude Code session ends (cleanly or otherwise).
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"

# A checkout-derived Dex session can be visible to more than one Claude
# session. Only the Claude session that claimed the active loop may mutate its
# state during SessionEnd. If the payload cannot prove ownership, leave the
# state for the real owner or wrapper to clean up.
OWNER_FILE=$(dx_owner_file "$SESSION_ID")
if [[ -s "$OWNER_FILE" ]]; then
  HOOK_INPUT=$(cat 2>/dev/null || true)
  HOOK_CLAUDE_SESSION_ID=""
  if [[ -n "$HOOK_INPUT" ]]; then
    HOOK_CLAUDE_SESSION_ID=$(printf '%s' "$HOOK_INPUT" | python3 -c '
import json
import sys

try:
    value = json.load(sys.stdin).get("session_id", "")
except Exception:
    value = ""
if isinstance(value, str):
    print(value)
' 2>/dev/null || true)
  fi
  OWNER_ID=$(cat "$OWNER_FILE" 2>/dev/null || true)
  if [[ -n "$OWNER_ID" && "$HOOK_CLAUDE_SESSION_ID" != "$OWNER_ID" ]]; then
    exit 0
  fi
fi

# Record end time in the times file (complements phase start times written by dx.sh)
TIMES_FILE=$(dx_times_file "$SESSION_ID")
CTX_FILE=$(dx_context_file "$SESSION_ID")

if [[ -f "$TIMES_FILE" || -f "$CTX_FILE" || -f "$(dx_state_file "$SESSION_ID")" || -f "$(dx_active_file "$SESSION_ID")" || -f "$(dx_loop_config_file "$SESSION_ID")" || -f "$(dx_handoff_mode_file "$SESSION_ID")" ]]; then
  dx_record_session_branch "$SESSION_ID" "$(pwd)" 2>/dev/null || true
fi

if [[ -f "$TIMES_FILE" ]]; then
  echo "end:$(date +%s)" >> "$TIMES_FILE"
fi

# Clean up the system context file — it's regenerated at each phase start
rm -f "$CTX_FILE" 2>/dev/null || true

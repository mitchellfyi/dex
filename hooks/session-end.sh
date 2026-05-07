#!/usr/bin/env bash
# SessionEnd hook — records session end time and cleans up ephemeral state files.
# Runs when a Claude Code session ends (cleanly or otherwise).
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"

# Record end time in the times file (complements phase start times written by dk.sh)
TIMES_FILE=$(dk_times_file "$SESSION_ID")
CTX_FILE=$(dk_context_file "$SESSION_ID")

if [[ -f "$TIMES_FILE" || -f "$CTX_FILE" || -f "$(dk_state_file "$SESSION_ID")" || -f "$(dk_active_file "$SESSION_ID")" || -f "$(dk_loop_config_file "$SESSION_ID")" || -f "$(dk_handoff_mode_file "$SESSION_ID")" ]]; then
  dk_record_session_branch "$SESSION_ID" "$(pwd)" 2>/dev/null || true
fi

if [[ -f "$TIMES_FILE" ]]; then
  echo "end:$(date +%s)" >> "$TIMES_FILE"
fi

# Clean up the system context file — it's regenerated at each phase start
rm -f "$CTX_FILE" 2>/dev/null || true

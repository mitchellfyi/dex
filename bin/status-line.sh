#!/usr/bin/env bash
# Dex status line — displayed persistently in Claude Code TUI via statusLine setting.
# Reads phase state, audit loop iteration, and elapsed time from Dex state files.
# Must be fast (<50ms) since it runs on every TUI render cycle.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"

CONTROL_SNAPSHOT=$(dx_lifecycle_control_snapshot_unlocked "$SESSION_ID")
CONTROL_ACTION=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" action)
if [[ "$CONTROL_ACTION" == "pause" || "$CONTROL_ACTION" == "cancel" ]]; then
  [[ "$CONTROL_ACTION" == "pause" ]] && CONTROL_LABEL="paused" || CONTROL_LABEL="stopped"
  echo "Dex ${CONTROL_LABEL} by human | phase sequencing detached"
  exit 0
fi
if [[ -f "$(dx_paused_file "$SESSION_ID")" && ! -L "$(dx_paused_file "$SESSION_ID")" ]]; then
  PAUSE_REASON=$(dx_pause_state_read "$SESSION_ID" reason)
  echo "Dex paused${PAUSE_REASON:+ | ${PAUSE_REASON}} | phase sequencing detached"
  exit 0
fi

# Phase info
PHASE="?"
PHASE_FILE=$(dx_state_file "$SESSION_ID")
if [[ -f "$PHASE_FILE" ]]; then
  PHASE=$(cat "$PHASE_FILE" 2>/dev/null || echo "?")
fi

# Audit loop iteration
ITER=""
LOOP_FILE=$(dx_loop_file "$SESSION_ID")
if [[ -f "$LOOP_FILE" ]]; then
  ITER=$(cut -d: -f1 "$LOOP_FILE" 2>/dev/null || echo "0")
  MAX="${DEX_LOOP_MAX_ITERATIONS:-30}"
  ITER=" | Audit ${ITER}/${MAX}"
fi

# Elapsed time from times file
ELAPSED=""
TIMES_FILE=$(dx_times_file "$SESSION_ID")
if [[ -f "$TIMES_FILE" ]]; then
  TOTAL_START=$(head -1 "$TIMES_FILE" 2>/dev/null | cut -d: -f2)
  if [[ -n "${TOTAL_START:-}" ]]; then
    NOW=$(date +%s)
    SECS=$((NOW - TOTAL_START))
    if [[ $SECS -lt 60 ]]; then
      ELAPSED=" | ${SECS}s"
    else
      ELAPSED=" | $((SECS / 60))m $((SECS % 60))s"
    fi
  fi
fi

if [[ "$PHASE" =~ ^[0-9]+$ ]] && [[ "$PHASE" -gt 6 ]]; then
  echo "Lifecycle complete${ELAPSED}"
else
  echo "Phase ${PHASE}/6${ITER}${ELAPSED}"
fi

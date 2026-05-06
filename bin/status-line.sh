#!/usr/bin/env bash
# Doyaken status line — displayed persistently in Claude Code TUI via statusLine setting.
# Reads phase state, audit loop iteration, and elapsed time from Doyaken state files.
# Must be fast (<50ms) since it runs on every TUI render cycle.
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"

# Phase info
PHASE="?"
PHASE_FILE=$(dk_state_file "$SESSION_ID")
if [[ -f "$PHASE_FILE" ]]; then
  PHASE=$(cat "$PHASE_FILE" 2>/dev/null || echo "?")
fi

# Audit loop iteration
ITER=""
LOOP_FILE=$(dk_loop_file "$SESSION_ID")
if [[ -f "$LOOP_FILE" ]]; then
  ITER=$(cut -d: -f1 "$LOOP_FILE" 2>/dev/null || echo "0")
  MAX="${DOYAKEN_LOOP_MAX_ITERATIONS:-30}"
  ITER=" | Audit ${ITER}/${MAX}"
fi

# Elapsed time from times file
ELAPSED=""
TIMES_FILE=$(dk_times_file "$SESSION_ID")
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

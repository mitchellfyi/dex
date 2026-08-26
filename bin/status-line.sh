#!/usr/bin/env bash
# Dex status line — displayed persistently in Claude Code TUI via statusLine setting.
# Reads phase state, audit loop iteration, and elapsed time from Dex state files.
# Must be fast (<50ms) since it runs on every TUI render cycle.
set -euo pipefail

# Only session and lifecycle-control helpers are used below, and none of them
# run at source time, so the rest of lib/ is not loaded. See lib/common.sh.
# shellcheck disable=SC2034 # read by lib/common.sh when it is sourced below
DX_COMMON_MODULES="output session override lifecycle-control"
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
unset DX_COMMON_MODULES

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"

CONTROL_SNAPSHOT=$(dx_lifecycle_control_snapshot_unlocked "$SESSION_ID")
CONTROL_FILE=$(dx_lifecycle_control_file "$SESSION_ID")
if [[ -z "$CONTROL_SNAPSHOT" \
  && ( -e "$CONTROL_FILE" || -L "$CONTROL_FILE" ) ]]; then
  echo "Dex blocked | unsafe human-control state"
  exit 0
fi
CONTROL_ACTION=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" action)
CONTROL_SOURCE=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" source)
if [[ "$CONTROL_ACTION" == "pause" || "$CONTROL_ACTION" == "cancel" ]]; then
  [[ "$CONTROL_ACTION" == "pause" ]] && CONTROL_LABEL="paused" || CONTROL_LABEL="stopped"
  CONTROL_ACTOR="human"
  [[ "$CONTROL_SOURCE" == "agent" ]] && CONTROL_ACTOR="agent"
  echo "Dex ${CONTROL_LABEL} by ${CONTROL_ACTOR} | phase sequencing detached"
  exit 0
fi
PAUSE_CONTEXT_RC=0
dx_lifecycle_pause_context_state "$SESSION_ID" || PAUSE_CONTEXT_RC=$?
if [[ "$PAUSE_CONTEXT_RC" -eq 2 ]]; then
  echo "Dex blocked | unsafe pause state"
  exit 0
fi
if [[ "$PAUSE_CONTEXT_RC" -eq 0 ]]; then
  PAUSE_METADATA=$(dx_lifecycle_trusted_file_read \
    "$(dx_pause_state_file "$SESSION_ID")" 1024 2>/dev/null || true)
  PAUSE_REASON="${PAUSE_METADATA%%$'\n'*}"
  PAUSE_REASON="${PAUSE_REASON#reason=}"
  [[ "$PAUSE_REASON" == "$PAUSE_METADATA" ]] && PAUSE_REASON=""
  echo "Dex paused${PAUSE_REASON:+ | ${PAUSE_REASON}} | phase sequencing detached"
  exit 0
fi

# Phase info
PHASE="?"
PHASE_FILE=$(dx_state_file "$SESSION_ID")
if [[ -e "$PHASE_FILE" || -L "$PHASE_FILE" ]]; then
  if ! PHASE=$(dx_lifecycle_phase_state "$SESSION_ID" 2>/dev/null); then
    echo "Dex blocked | unsafe phase state"
    exit 0
  fi
fi

# Audit loop iteration
ITER=""
LOOP_FILE=$(dx_loop_file "$SESSION_ID")
if [[ -f "$LOOP_FILE" ]]; then
  ITER=$(cut -d: -f1 "$LOOP_FILE" 2>/dev/null || echo "0")
  MAX="${DEX_LOOP_MAX_ITERATIONS:-30}"
  OVERRIDE_PHASE="$PHASE"
  [[ "$OVERRIDE_PHASE" =~ ^[0-6]$ ]] || OVERRIDE_PHASE="-"
  if ! MAX=$(dx_override_effective "$SESSION_ID" loop.max-iterations \
    "$MAX" "$OVERRIDE_PHASE" 2>/dev/null); then
    echo "Dex blocked | unsafe override state"
    exit 0
  fi
  ITER=" | Audit ${ITER}/${MAX}"
fi

# Elapsed time from times file
ELAPSED=""
TIMES_FILE=$(dx_times_file "$SESSION_ID")
if [[ -f "$TIMES_FILE" ]]; then
  TOTAL_START=$(head -1 "$TIMES_FILE" 2>/dev/null | cut -d: -f2)
  # Digits, not merely non-empty. $(( )) evaluates an array subscript as an
  # arithmetic expression, so a times file holding `HOME[$(…)]` runs that
  # command — and this script runs on every prompt render, long after whatever
  # wrote the file is gone. `set -u` does not stop it: naming a variable that
  # is already set keeps nounset quiet. bin/log.sh reads the same file and
  # already checks this way.
  if [[ "${TOTAL_START:-}" =~ ^[0-9]+$ ]]; then
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
  if dx_lifecycle_terminal_commit_valid "$SESSION_ID"; then
    echo "Lifecycle complete${ELAPSED}"
  else
    echo "Dex blocked | terminal commit incomplete${ELAPSED}"
  fi
else
  echo "Phase ${PHASE}/6${ITER}${ELAPSED}"
fi

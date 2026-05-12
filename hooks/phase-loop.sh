#!/usr/bin/env bash
# Stop hook — Phase audit loop for quality-gated autonomous execution.
#
# Flow:
#   1. Claude tries to stop → this hook runs
#   2. Check .complete file → advance inline or finish the lifecycle
#   3. Check iteration count → pause/escalate
#   4. Check min audit iterations:
#      a. Below threshold → block stop, inject audit prompt WITHOUT completion instructions
#      b. At/above threshold → block stop, inject audit prompt WITH completion instructions
#   5. Claude reads the audit prompt, reviews its work, and either:
#      a. Finds issues → fixes them → tries to stop → back to step 1
#      b. Finds nothing, below min iterations → tries to stop → back to step 4a
#      c. Finds nothing, at/above min iterations → writes .complete → step 2 exits
#
# Completion detection:
#   .complete signal file — written by Claude after the hook authorizes completion
#   (provides the file path and promise string after MIN_AUDIT_ITERATIONS passes).
#   The promise string (e.g., PHASE_1_COMPLETE) is not parsed by the hook.
#
# Activated by:
#   - DOYAKEN_LOOP_ACTIVE=1 in environment (set by dk/dkloop wrappers)
#   - .active signal file in DK_LOOP_DIR (created by /dkloop skill for in-session use)
# Deactivated by: .complete file or max iterations
#
# See: docs/autonomous-mode.md for full architecture documentation
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
mkdir -p "$DK_LOOP_DIR"

SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"

dk_phase_name() {
  case "$1" in
    1) printf '%s\n' "Plan" ;;
    2) printf '%s\n' "Implement" ;;
    3) printf '%s\n' "Review" ;;
    4) printf '%s\n' "Verify & Commit" ;;
    5) printf '%s\n' "PR" ;;
    6) printf '%s\n' "Complete" ;;
    *) printf '%s\n' "Unknown" ;;
  esac
}

dk_phase_promise() {
  case "$1" in
    1) printf '%s\n' "PHASE_1_COMPLETE" ;;
    2) printf '%s\n' "PHASE_2_COMPLETE" ;;
    3) printf '%s\n' "PHASE_3_COMPLETE" ;;
    4) printf '%s\n' "PHASE_4_COMPLETE" ;;
    5) printf '%s\n' "PHASE_5_COMPLETE" ;;
    6) printf '%s\n' "DOYAKEN_TICKET_COMPLETE" ;;
    *) printf '%s\n' "DOYAKEN_TICKET_COMPLETE" ;;
  esac
}

dk_phase_audit_file() {
  local phase="$1" name
  case "$phase" in
    1) name="1-plan" ;;
    2) name="2-implement" ;;
    3) name="3-review-loop" ;;
    4) name="4-verify" ;;
    5) name="5-pr" ;;
    6) name="6-complete" ;;
    *) name="" ;;
  esac
  [[ -n "$name" ]] && printf '%s\n' "$DOYAKEN_DIR/prompts/phase-audits/${name}.md"
}

dk_phase_min_audits() {
  local phase="$1" env_name value
  env_name="DOYAKEN_PHASE_${phase}_MIN_AUDITS"
  value="$(printenv "$env_name" 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "1"
  fi
}

dk_reverse_file_lines() {
  local file="$1"
  awk '{ lines[NR] = $0 } END { for (i = NR; i >= 1; i--) print lines[i] }' "$file"
}

dk_phase_iteration_count() {
  local state_file="$1" raw iterations
  raw=$(cat "$state_file" 2>/dev/null || echo "0")
  iterations="${raw%%:*}"
  if [[ "$iterations" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$iterations"
  else
    printf '%s\n' "0"
  fi
}

dk_format_duration() {
  local seconds="$1" minutes remainder
  if [[ ! "$seconds" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$seconds"
    return 0
  fi

  minutes=$((seconds / 60))
  remainder=$((seconds % 60))
  printf '%dm %ds\n' "$minutes" "$remainder"
}

dk_phase_start_epoch() {
  local phase="$1" times_file
  times_file=$(dk_times_file "$SESSION_ID")
  if [[ -f "$times_file" ]]; then
    awk -F: -v phase="$phase" '$1 == phase { start=$2 } END { if (start != "") print start }' "$times_file"
  fi
}

dk_record_phase_result() {
  local phase="$1" status="$2" exit_code="$3" start_epoch end_epoch duration iterations
  [[ "$phase" =~ ^[1-6]$ ]] || return 0
  end_epoch=$(date +%s)
  start_epoch=$(dk_phase_start_epoch "$phase")
  [[ "$start_epoch" =~ ^[0-9]+$ ]] || start_epoch="$end_epoch"
  duration=$((end_epoch - start_epoch))
  iterations=$(dk_phase_iteration_count "$STATE_FILE")
  dk_log_phase "$SESSION_ID" "$phase" "$(dk_phase_name "$phase")" "$start_epoch" "$end_epoch" "$duration" "$iterations" "$status" "$exit_code"
}

dk_start_phase_timer() {
  local phase="$1" times_file
  times_file=$(dk_times_file "$SESSION_ID")
  mkdir -p "$(dirname "$times_file")"
  printf '%s:%s\n' "$phase" "$(date +%s)" >> "$times_file"
}

# Claude hook subprocesses can inherit stale DOYAKEN_LOOP_PHASE values from the
# original launch. In inline mode, the phase file is the lifecycle source of
# truth after handoffs, so use it to recover before applying phase-specific gates.
dk_sync_inline_phase_from_state() {
  [[ "$HANDOFF_MODE" == "inline" ]] || return 0

  local phase_file phase phase_min audit_file
  phase_file=$(dk_state_file "$SESSION_ID")
  [[ -f "$phase_file" ]] || return 0

  phase=$(cat "$phase_file" 2>/dev/null || echo "")
  [[ "$phase" =~ ^[1-6]$ ]] || return 0
  [[ "${DOYAKEN_LOOP_PHASE:-}" == "$phase" ]] && return 0

  DOYAKEN_LOOP_PHASE="$phase"
  DOYAKEN_LOOP_PROMISE=$(dk_phase_promise "$phase")
  phase_min=$(dk_phase_min_audits "$phase")
  MIN_AUDIT_ITERATIONS="${DOYAKEN_LOOP_MIN_AUDITS:-$phase_min}"

  audit_file=$(dk_phase_audit_file "$phase")
  if [[ -n "$audit_file" && -f "$audit_file" ]]; then
    DOYAKEN_LOOP_PROMPT=$(cat "$audit_file")
  fi
}

dk_inline_phase_message() {
  case "$1" in
    2)
      cat <<'EOF'
The plan is approved. Invoke the Skill tool with skill: "dkimplement" to begin implementation. Scope: implementation, testing, and UI capture evidence only. For UI-affecting changes, invoke dkuicapture and link screenshots/videos/traces before stopping. Do not commit, push, create branches, or create PRs. When implementation is complete and the audit criteria are met, stop so the Stop hook can advance the lifecycle.
EOF
      ;;
    3)
      cat <<'EOF'
Begin Phase 3: Review. Invoke the Skill tool with skill: "dkreviewloop" to run the 3-clean-pass review loop in fresh subagents. Fix any findings it reports, rerun until it reports SUCCESS, then stop so the Stop hook can audit and advance. Scope: review and fix only. Do not commit, push, create branches, or create PRs.
EOF
      ;;
    4)
      cat <<'EOF'
Begin Phase 4: Verify & Commit. Invoke the Skill tool with skill: "dkverify" to run the quality pipeline. Fix failures and rerun until green. Then invoke skill: "dkcommit" to commit and push. Do not create PRs. When pushed, stop so the Stop hook can audit and advance.
EOF
      ;;
    5)
      cat <<'EOF'
Begin Phase 5: PR. Invoke the Skill tool with skill: "dkpr" to generate the PR description, create the draft PR, and attach configured request reviewers. Do not mark the PR ready, post @mention comments, or modify implementation code. When done, stop so the Stop hook can audit and advance.
EOF
      ;;
    6)
      cat <<'EOF'
Begin Phase 6: Complete. Invoke the Skill tool with skill: "dkcomplete". Mark the PR ready, request reviewers, post configured @mention comments, monitor CI/reviews, address comments, and close the ticket when CI is green and configured reviewers approve. Continue unattended until completion or a real escalation condition is hit.
EOF
      ;;
  esac
}

dk_compact_repeat_audit_prompt() {
  local phase="$1" audit_file="${2:-}"

  case "$phase" in
    2)
      printf '%s\n' "The full Phase 2 implementation audit was already shown for this phase."
      if [[ -n "$audit_file" ]]; then
        printf 'Full audit prompt: %s\n' "$audit_file"
      fi
      printf '%s\n' ""
      printf '%s\n' "Before completing Phase 2, all of these must be true:"
      printf '%s\n' "- Every task from the approved plan is implemented."
      printf '%s\n' "- Every acceptance criterion and verification gate has status MET with specific implementation and test locations."
      printf '%s\n' "- No evidence-table status is DEFERRED, SKIPPED, NOT MET, NOT FOUND, BLOCKED, N/A, or equivalent unless the user explicitly approved a plan change."
      printf '%s\n' "- The final verification commands have passed."
      printf '%s\n' "- Port conflicts or unavailable local services have been resolved or worked around locally; future CI is not a substitute for required Phase 2 verification."
      printf '%s\n' "- No TODO/FIXME/HACK, debug output, commented-out code blocks, missing imports, or obvious runtime errors remain."
      printf '%s\n' "- No Phase 2 background agents or long-running verification commands are still in flight."
      printf '%s\n' "- Any needed .doyaken/ updates are made."
      printf '%s\n' "- UI capture evidence is linked for UI-affecting changes, or UI capture is explicitly marked N/A."
      printf '%s\n' "- The Phase 2 ready marker has been written."
      printf '%s\n' ""
      printf '%s\n' "If any item is not true, continue implementing or verifying instead of signalling completion."
      ;;
    *)
      return 1
      ;;
  esac
}

# Check activation: env var OR .active file (for in-session /dkloop skill)
ACTIVE_FILE=$(dk_active_file "$SESSION_ID")
LOOP_ACTIVE="${DOYAKEN_LOOP_ACTIVE:-0}"
if [[ "$LOOP_ACTIVE" != "1" ]] && [[ ! -f "$ACTIVE_FILE" ]]; then
  exit 0
fi

HANDOFF_MODE="${DOYAKEN_PHASE_HANDOFF:-}"
HANDOFF_MODE_FILE=$(dk_handoff_mode_file "$SESSION_ID")
if [[ -z "$HANDOFF_MODE" && -f "$HANDOFF_MODE_FILE" ]]; then
  HANDOFF_MODE=$(cat "$HANDOFF_MODE_FILE" 2>/dev/null || echo "")
fi
PAUSED_FILE=$(dk_paused_file "$SESSION_ID")
COMPLETE_FILE=$(dk_complete_file "$SESSION_ID")
PHASE_STATE_FILE=$(dk_state_file "$SESSION_ID")

# After inline Phase 6 completes, the Claude process can still carry stale
# DOYAKEN_LOOP_ACTIVE/DOYAKEN_LOOP_PHASE env vars until the user closes the
# session. The phase state file is authoritative; phase 7 means the lifecycle is
# done and the Stop hook must not re-enter an earlier gate.
if [[ "$HANDOFF_MODE" == "inline" && -f "$PHASE_STATE_FILE" ]]; then
  PHASE_STATE=$(cat "$PHASE_STATE_FILE" 2>/dev/null || echo "")
  if [[ "$PHASE_STATE" == "7" ]]; then
    rm -f "$ACTIVE_FILE" "$HANDOFF_MODE_FILE" "$PAUSED_FILE" "$COMPLETE_FILE" "$(dk_loop_file "$SESSION_ID")" "$(dk_loop_config_file "$SESSION_ID")" "$(dk_findings_file "$SESSION_ID")" "$(dk_prompt_file "$SESSION_ID")" "${DK_LOOP_DIR}/${SESSION_ID}".phase-*.started "${DK_LOOP_DIR}/${SESSION_ID}".phase-*.ready "${DK_LOOP_DIR}/${SESSION_ID}".phase-*.busy "${DK_LOOP_DIR}/${SESSION_ID}".phase-*.busy-notice 2>/dev/null
    exit 0
  fi
fi

if [[ -f "$PAUSED_FILE" && ! -f "$COMPLETE_FILE" ]]; then
  rm -f "$PAUSED_FILE" "$HANDOFF_MODE_FILE"
  exit 0
fi

# Read phase configuration from .config file when env vars are not inherited.
# dk.sh writes this file before launching Claude for phases 1-6. Format:
# "phase_number:promise_string:audit_file_path:min_audits"
# Env vars take priority (belt-and-suspenders with file-based activation).
# IMPORTANT: This block MUST run before the .active file defaults below,
# because .active defaults set prompt-loop mode which would shadow the
# correct phase values from .config.
MIN_AUDIT_ITERATIONS="${DOYAKEN_LOOP_MIN_AUDITS:-1}"
CONFIG_FILE=$(dk_loop_config_file "$SESSION_ID")
CONFIG_AUDIT_FILE=""
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_RAW=$(cat "$CONFIG_FILE" 2>/dev/null || echo "")
  if [[ -n "$CONFIG_RAW" ]]; then
    CONFIG_PHASE="${CONFIG_RAW%%:*}"
    CONFIG_REST="${CONFIG_RAW#*:}"
    CONFIG_PROMISE="${CONFIG_REST%%:*}"
    CONFIG_REST2="${CONFIG_REST#*:}"
    CONFIG_AUDIT_FILE="${CONFIG_REST2%%:*}"
    CONFIG_MIN_AUDITS="${CONFIG_REST2#*:}"
    if [[ "$HANDOFF_MODE" == "inline" ]]; then
      DOYAKEN_LOOP_PHASE="$CONFIG_PHASE"
      DOYAKEN_LOOP_PROMISE="$CONFIG_PROMISE"
    else
      DOYAKEN_LOOP_PHASE="${DOYAKEN_LOOP_PHASE:-$CONFIG_PHASE}"
      DOYAKEN_LOOP_PROMISE="${DOYAKEN_LOOP_PROMISE:-$CONFIG_PROMISE}"
    fi
    # Use config min_audits if no env override
    [[ "$CONFIG_MIN_AUDITS" =~ ^[0-9]+$ ]] && MIN_AUDIT_ITERATIONS="${DOYAKEN_LOOP_MIN_AUDITS:-$CONFIG_MIN_AUDITS}"
    if { [[ "$HANDOFF_MODE" == "inline" ]] || [[ -z "${DOYAKEN_LOOP_PROMPT:-}" ]]; } && [[ -n "$CONFIG_AUDIT_FILE" ]] && [[ -f "$CONFIG_AUDIT_FILE" ]]; then
      DOYAKEN_LOOP_PROMPT=$(cat "$CONFIG_AUDIT_FILE")
    fi
  fi
fi

# If activated via .active file only (in-session /dkloop with no .config file),
# default to prompt-loop mode. The .active file is a touch file — it doesn't
# carry data. When a .config file exists (dk phase workflow), the values above
# take precedence.
if [[ -f "$ACTIVE_FILE" ]]; then
  DOYAKEN_LOOP_PHASE="${DOYAKEN_LOOP_PHASE:-prompt-loop}"
  DOYAKEN_LOOP_PROMISE="${DOYAKEN_LOOP_PROMISE:-PROMPT_COMPLETE}"
fi

dk_sync_inline_phase_from_state

STATE_FILE=$(dk_loop_file "$SESSION_ID")
dk_record_session_branch "$SESSION_ID" "$(pwd)" 2>/dev/null || true
# 30 iterations is tuned for medium-sized features; reduce for simple bugs (10-15).
# Each iteration = one audit cycle, so 30 is a safety net, not an expected count.
MAX_ITERATIONS="${DOYAKEN_LOOP_MAX_ITERATIONS:-30}"
COMPLETION_PROMISE="${DOYAKEN_LOOP_PROMISE:-DOYAKEN_TICKET_COMPLETE}"

# Phase 1 has an external approval gate: the plan must be presented through
# ExitPlanMode and explicitly approved by the user before the audit loop should
# count iterations or reveal the completion signal. This keeps ordinary
# planning waits/background-agent pauses from burning the max-iteration budget.
if [[ "$HANDOFF_MODE" == "inline" && "${DOYAKEN_LOOP_PHASE:-}" == "1" ]]; then
  PHASE_STARTED_FILE=$(dk_phase_started_file "$SESSION_ID" 1)
  PHASE_READY_FILE=$(dk_phase_ready_file "$SESSION_ID" 1)
  if [[ ! -f "$PHASE_READY_FILE" ]]; then
    rm -f "$COMPLETE_FILE" "$STATE_FILE"
    if [[ ! -f "$PHASE_STARTED_FILE" ]]; then
      printf '\n%s\n\n' "--- Doyaken Phase 1 Gate: dkplan required ---" >&2
      printf '%s\n' "No audit iteration was counted and no completion signal is available yet." >&2
      printf '%s\n' "" >&2
      printf '%s\n' "Mandatory next step: invoke the dkplan skill now (Skill tool with skill: \"dkplan\", or /dkplan if slash skills are the available interface)." >&2
      printf '%s\n' "Do not manually fetch the ticket, rename branches, update tracker status, explore code, or draft the plan outside that skill unless the skill explicitly instructs you to." >&2
    else
      printf '\n%s\n\n' "--- Doyaken Phase 1 Gate: dkplan still in progress ---" >&2
      printf '%s\n' "No audit iteration was counted. Continue dkplan until ExitPlanMode has presented the plan and the user has approved it." >&2
      printf '%s\n' "After approval only, write the ready marker from dkplan Step 7, then stop once for the audit handoff." >&2
    fi
    printf '%s\n' "" >&2
    exit 2
  fi
fi

if [[ "$HANDOFF_MODE" == "inline" && "${DOYAKEN_LOOP_PHASE:-}" == "3" ]]; then
  PHASE_BUSY_FILE=$(dk_phase_busy_file "$SESSION_ID" 3)
  if [[ -f "$PHASE_BUSY_FILE" && ! -f "$COMPLETE_FILE" ]]; then
    PHASE_BUSY_NOTICE_FILE=$(dk_phase_busy_notice_file "$SESSION_ID" 3)
    BUSY_RAW=$(cat "$PHASE_BUSY_FILE" 2>/dev/null || echo "")
    BUSY_EPOCH="$BUSY_RAW"
    BUSY_LABEL=""
    if [[ "$BUSY_RAW" == *$'\t'* ]]; then
      BUSY_EPOCH="${BUSY_RAW%%$'\t'*}"
      BUSY_LABEL="${BUSY_RAW#*$'\t'}"
    fi
    [[ "$BUSY_EPOCH" =~ ^[0-9]+$ ]] || BUSY_EPOCH=$(date +%s)
    BUSY_AGE=$(( $(date +%s) - BUSY_EPOCH ))
    BUSY_TIMEOUT="${DOYAKEN_REVIEW_PASS_TIMEOUT:-900}"

    if [[ "$BUSY_TIMEOUT" =~ ^[0-9]+$ && "$BUSY_TIMEOUT" -gt 0 && "$BUSY_AGE" -gt "$BUSY_TIMEOUT" ]]; then
      rm -f "$ACTIVE_FILE" "$CONFIG_FILE" "$PHASE_BUSY_FILE" "$PHASE_BUSY_NOTICE_FILE"
      dk_record_phase_result "3" "review-pass-timeout" "89"
      touch "$PAUSED_FILE"
      printf '\n%s\n\n' "--- Doyaken phase paused: review pass timeout reached ($(dk_format_duration "$BUSY_AGE")/$(dk_format_duration "$BUSY_TIMEOUT")) ---" >&2
      printf '%s\n' "Do not advance to the next phase. Summarize the in-flight review pass, current clean-pass count, and whether the user wants to retry, reduce review depth, or continue with documented risk." >&2
      exit 2
    fi

    rm -f "$STATE_FILE"

    BUSY_NOTICE_INTERVAL="${DOYAKEN_REVIEW_PASS_NOTICE_INTERVAL:-120}"
    [[ "$BUSY_NOTICE_INTERVAL" =~ ^[0-9]+$ ]] || BUSY_NOTICE_INTERVAL=120
    SHOULD_PRINT_BUSY_NOTICE=1

    if [[ "$BUSY_NOTICE_INTERVAL" -gt 0 && -f "$PHASE_BUSY_NOTICE_FILE" ]]; then
      BUSY_NOTICE_RAW=$(cat "$PHASE_BUSY_NOTICE_FILE" 2>/dev/null || echo "")
      BUSY_NOTICE_EPOCH="$BUSY_NOTICE_RAW"
      BUSY_NOTICE_LABEL=""
      if [[ "$BUSY_NOTICE_RAW" == *$'\t'* ]]; then
        BUSY_NOTICE_EPOCH="${BUSY_NOTICE_RAW%%$'\t'*}"
        BUSY_NOTICE_LABEL="${BUSY_NOTICE_RAW#*$'\t'}"
      fi
      if [[ "$BUSY_NOTICE_EPOCH" =~ ^[0-9]+$ && "$BUSY_NOTICE_LABEL" == "$BUSY_LABEL" ]]; then
        BUSY_NOTICE_AGE=$(( $(date +%s) - BUSY_NOTICE_EPOCH ))
        if [[ "$BUSY_NOTICE_AGE" -lt "$BUSY_NOTICE_INTERVAL" ]]; then
          SHOULD_PRINT_BUSY_NOTICE=0
        fi
      fi
    fi

    if [[ $SHOULD_PRINT_BUSY_NOTICE -eq 0 ]]; then
      BUSY_RECHECK_SECONDS="${DOYAKEN_REVIEW_PASS_RECHECK_SECONDS:-45}"
      [[ "$BUSY_RECHECK_SECONDS" =~ ^[0-9]+$ ]] || BUSY_RECHECK_SECONDS=45
      if [[ "$BUSY_RECHECK_SECONDS" -gt 0 ]]; then
        BUSY_POLL_DEADLINE=$(( $(date +%s) + BUSY_RECHECK_SECONDS ))
        while [[ -f "$PHASE_BUSY_FILE" ]]; do
          BUSY_POLL_NOW=$(date +%s)
          [[ "$BUSY_POLL_NOW" -lt "$BUSY_POLL_DEADLINE" ]] || break
          BUSY_SLEEP_SECONDS=$((BUSY_POLL_DEADLINE - BUSY_POLL_NOW))
          [[ "$BUSY_SLEEP_SECONDS" -le 2 ]] || BUSY_SLEEP_SECONDS=2
          [[ "$BUSY_SLEEP_SECONDS" -gt 0 ]] || break
          sleep "$BUSY_SLEEP_SECONDS"
        done
      fi

      if [[ ! -f "$PHASE_BUSY_FILE" ]]; then
        rm -f "$PHASE_BUSY_NOTICE_FILE"
        printf '\n%s\n\n' "--- Doyaken Phase 3 Gate: review pass finished ---" >&2
        printf '%s\n' "The busy marker cleared while the Stop hook was waiting. Continue dkreviewloop with the returned review result before stopping again." >&2
        exit 2
      fi

      BUSY_AGE=$(( $(date +%s) - BUSY_EPOCH ))
      if [[ -n "$BUSY_LABEL" && "$BUSY_LABEL" != "$BUSY_RAW" ]]; then
        printf '\n--- Doyaken Phase 3 Gate: still waiting on %s (%s/%s timeout) ---\n\n' "$BUSY_LABEL" "$(dk_format_duration "$BUSY_AGE")" "$(dk_format_duration "$BUSY_TIMEOUT")" >&2
      else
        printf '\n--- Doyaken Phase 3 Gate: review pass still running (%s/%s timeout) ---\n\n' "$(dk_format_duration "$BUSY_AGE")" "$(dk_format_duration "$BUSY_TIMEOUT")" >&2
      fi
    fi

    if [[ $SHOULD_PRINT_BUSY_NOTICE -eq 1 ]]; then
      BUSY_NOTICE_TMP="${PHASE_BUSY_NOTICE_FILE}.tmp.$$"
      if ! printf '%s\t%s\n' "$(date +%s)" "$BUSY_LABEL" > "$BUSY_NOTICE_TMP" || ! command mv -f "$BUSY_NOTICE_TMP" "$PHASE_BUSY_NOTICE_FILE"; then
        command rm -f "$BUSY_NOTICE_TMP" 2>/dev/null
      fi

      printf '\n%s\n\n' "--- Doyaken Phase 3 Gate: review pass in progress ---" >&2
      printf '%s\n' "No audit iteration was counted and no completion signal is available while dkreviewloop is waiting on a review pass." >&2
      if [[ -n "$BUSY_LABEL" && "$BUSY_LABEL" != "$BUSY_RAW" ]]; then
        printf '%s\n' "" >&2
        printf 'Current review work: %s\n' "$BUSY_LABEL" >&2
      fi
      printf '%s\n' "" >&2
      printf 'This wait-state notice is throttled to once every %s unless the review pass changes or times out.\n' "$(dk_format_duration "$BUSY_NOTICE_INTERVAL")" >&2
      printf 'Continue waiting for the current review pass. If this exceeds %s, Doyaken will pause Phase 3 for intervention. Do not commit, push, create a PR, or start later lifecycle phases from Phase 3.\n' "$(dk_format_duration "$BUSY_TIMEOUT")" >&2
    fi
    exit 2
  fi
fi

# Completion detection: The .complete file is the sole mechanism.
# This hook provides the .complete file path and promise string to Claude
# ONLY after MIN_AUDIT_ITERATIONS passes — audit prompts do NOT contain
# completion instructions (they were removed to prevent premature completion).
# See: docs/autonomous-mode.md § Completion Signals
if [[ -f "$COMPLETE_FILE" ]]; then
  CURRENT_PHASE="${DOYAKEN_LOOP_PHASE:-0}"

  if [[ "$HANDOFF_MODE" == "inline" && "$CURRENT_PHASE" == "2" ]]; then
    PHASE_READY_FILE=$(dk_phase_ready_file "$SESSION_ID" 2)
    if [[ ! -f "$PHASE_READY_FILE" ]]; then
      rm -f "$COMPLETE_FILE"
      printf '\n%s\n\n' "--- Doyaken Phase 2 Gate: implementation readiness marker missing ---" >&2
      printf '%s\n' "Completion signal ignored; Phase 2 did not advance." >&2
      printf '%s\n' "" >&2
      printf '%s\n' "Before writing the Phase 2 ready marker, confirm every approved task and acceptance criterion is exactly MET, with no DEFERRED/SKIPPED/N/A entries unless the user explicitly approved a plan change." >&2
      printf '%s\n' "All required verification, flake gates, and UI capture evidence must be complete locally. Do not rely on future CI as a substitute for a required Phase 2 check." >&2
      printf '%s\n' "No Phase 2 background agents or long-running verification commands may still be in flight." >&2
      printf '%s\n' "" >&2
      printf '%s\n' "If all of that is true, write the ready marker, then stop again for the completion signal:" >&2
      printf '%s\n' '```bash' >&2
      printf '%s\n' "source \"\${DOYAKEN_DIR:-\$HOME/work/doyaken}/lib/common.sh\"" >&2
      printf '%s\n' "touch \"\$(dk_phase_ready_file \"\${DOYAKEN_SESSION_ID:-\$(dk_session_id)}\" 2)\"" >&2
      printf '%s\n' '```' >&2
      printf '%s\n' "" >&2
      exit 2
    fi
  fi

  if [[ "$HANDOFF_MODE" == "inline" && "$CURRENT_PHASE" =~ ^[0-9]+$ && "$CURRENT_PHASE" -lt 6 ]]; then
    NEXT_PHASE=$((CURRENT_PHASE + 1))
    dk_record_phase_result "$CURRENT_PHASE" "advance" "0"
    rm -f "$STATE_FILE" "$COMPLETE_FILE" "$CONFIG_FILE" "$(dk_findings_file "$SESSION_ID")" "$PAUSED_FILE" "$(dk_phase_started_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dk_phase_ready_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dk_phase_busy_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dk_phase_busy_notice_file "$SESSION_ID" "$CURRENT_PHASE")"

    PHASE_STATE_FILE=$(dk_state_file "$SESSION_ID")
    printf '%s\n' "$NEXT_PHASE" > "$PHASE_STATE_FILE"

    # Preserve phase checkpoints at same-session phase boundaries.
    if [[ "$NEXT_PHASE" -ge 2 ]] && git rev-parse --git-dir >/dev/null 2>&1; then
      dk_checkpoint_tag "$NEXT_PHASE" "$(pwd)"
    fi

    dk_start_phase_timer "$NEXT_PHASE"

    NEXT_AUDIT_FILE=$(dk_phase_audit_file "$NEXT_PHASE")
    NEXT_PROMISE=$(dk_phase_promise "$NEXT_PHASE")
    NEXT_MIN_AUDITS=$(dk_phase_min_audits "$NEXT_PHASE")
    printf '%s:%s:%s:%s\n' "$NEXT_PHASE" "$NEXT_PROMISE" "$NEXT_AUDIT_FILE" "$NEXT_MIN_AUDITS" > "$CONFIG_FILE"
    touch "$ACTIVE_FILE"

    {
      printf '\n%s\n\n' "--- Doyaken Phase Handoff: Phase ${CURRENT_PHASE} complete → Phase ${NEXT_PHASE} ($(dk_phase_name "$NEXT_PHASE")) ---"
      printf '%s\n\n' "Continue in this same Claude session. Do not ask the user whether to proceed."
      dk_inline_phase_message "$NEXT_PHASE"
      printf '\n%s\n' "When Phase ${NEXT_PHASE} is genuinely complete, stop so the Stop hook can audit it."
    } >&2
    exit 2
  fi

  if [[ "$HANDOFF_MODE" == "inline" && "$CURRENT_PHASE" == "6" ]]; then
    dk_record_phase_result "$CURRENT_PHASE" "advance" "0"
    rm -f "$STATE_FILE" "$COMPLETE_FILE" "$CONFIG_FILE" "$(dk_findings_file "$SESSION_ID")" "$PAUSED_FILE" "$(dk_prompt_file "$SESSION_ID")" "$(dk_phase_started_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dk_phase_ready_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dk_phase_busy_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dk_phase_busy_notice_file "$SESSION_ID" "$CURRENT_PHASE")"
    printf '%s\n' "7" > "$(dk_state_file "$SESSION_ID")"
    rm -f "$ACTIVE_FILE" "$HANDOFF_MODE_FILE" "$PAUSED_FILE"
    {
      printf '\n%s\n\n' "--- Doyaken lifecycle complete ---"
      printf '%s\n' "All phases are complete. Present the final summary to the user, including PR status and any cleanup command."
    } >&2
    exit 2
  fi

  rm -f "$STATE_FILE" "$COMPLETE_FILE" "$CONFIG_FILE" "$(dk_findings_file "$SESSION_ID")" "$PAUSED_FILE" "$(dk_phase_started_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dk_phase_ready_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dk_phase_busy_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dk_phase_busy_notice_file "$SESSION_ID" "$CURRENT_PHASE")"
  rm -f "$ACTIVE_FILE" "$HANDOFF_MODE_FILE" "$PAUSED_FILE"
  printf '%s\n' '{"continue":false,"stopReason":"Doyaken loop complete."}'
  exit 0
fi

# Read current iteration count and timestamp.
# State file format: "iteration:epoch" (new) or bare "iteration" (legacy).
ITERATION=0
LAST_EPOCH=0
STALL_COUNT=0
if [[ -f "$STATE_FILE" ]]; then
  RAW=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
  if [[ "$RAW" =~ ^([0-9]+):([0-9]+):?([0-9]*)$ ]]; then
    # New format: iteration:epoch or iteration:epoch:stall_count
    ITERATION="${BASH_REMATCH[1]}"
    LAST_EPOCH="${BASH_REMATCH[2]}"
    STALL_COUNT="${BASH_REMATCH[3]:-0}"
  elif [[ "$RAW" =~ ^[0-9]+$ ]]; then
    # Legacy format: bare iteration count
    ITERATION=$RAW
  fi
fi
ITERATION=$((ITERATION + 1))
NOW_EPOCH=$(date +%s)

# Stall detection — if the time between consecutive iterations exceeds the
# threshold, the loop may be stuck on a fundamentally broken problem.
# Inspired by autoresearch's NaN/exploding-loss early termination.
STALL_TIMEOUT="${DOYAKEN_LOOP_STALL_TIMEOUT:-300}"  # default: 5 minutes
STALL_ESCALATE_AFTER="${DOYAKEN_LOOP_STALL_ESCALATE:-3}"  # escalate after N stalls
IS_STALLED=0
if [[ $LAST_EPOCH -gt 0 ]] && [[ $STALL_TIMEOUT -gt 0 ]]; then
  ELAPSED=$((NOW_EPOCH - LAST_EPOCH))
  if [[ $ELAPSED -gt $STALL_TIMEOUT ]]; then
    STALL_COUNT=$((STALL_COUNT + 1))
    IS_STALLED=1
  else
    STALL_COUNT=0
  fi
fi

# Semantic stuck detection — check if review findings are repeating across
# iterations. Claude writes a findings hash after each review cycle (see
# prompts/phase-audits/2-implement.md). If the same hash appears 3+ consecutive
# times, the loop is semantically stuck on the same issues.
FINDINGS_FILE=$(dk_findings_file "$SESSION_ID")
SEMANTIC_STUCK=0
if [[ -f "$FINDINGS_FILE" ]]; then
  LAST_HASH=$(tail -1 "$FINDINGS_FILE" 2>/dev/null || echo "")
  if [[ -n "$LAST_HASH" ]]; then
    # Count consecutive identical hashes from the end of the file
    REPEAT_COUNT=0
    while IFS= read -r line; do
      if [[ "$line" == "$LAST_HASH" ]]; then
        REPEAT_COUNT=$((REPEAT_COUNT + 1))
      else
        break
      fi
    done < <(dk_reverse_file_lines "$FINDINGS_FILE" 2>/dev/null)
    if [[ $REPEAT_COUNT -ge 3 ]]; then
      SEMANTIC_STUCK=1
    fi
  fi
fi

# Check max iterations.
# Leave STATE_FILE intact (unlike the .complete path) so the wrapper can
# distinguish max-iter (exit 0 + state file present) from advance (exit 0 +
# state file removed by .complete cleanup). The wrapper is responsible for
# cleaning up the state file after reading the iteration count.
if [[ $ITERATION -gt $MAX_ITERATIONS ]]; then
  rm -f "$ACTIVE_FILE" "$CONFIG_FILE"
  if [[ "$HANDOFF_MODE" == "inline" ]]; then
    CURRENT_PHASE="${DOYAKEN_LOOP_PHASE:-0}"
    dk_record_phase_result "$CURRENT_PHASE" "max-iter" "88"
    touch "$PAUSED_FILE"
    printf '\n%s\n\n' "--- Doyaken phase paused: max audit iterations reached (${MAX_ITERATIONS}) ---" >&2
    printf '%s\n' "Do not advance to the next phase. Summarize the blocker, current phase, and the exact user decision or intervention needed." >&2
    exit 2
  fi
  printf '{"continue":false,"stopReason":"Doyaken audit loop reached max iterations (%s). Inspect the pause and resume when ready."}\n' "$MAX_ITERATIONS"
  exit 0
fi

# Save iteration count with timestamp atomically: write to a PID-suffixed temp
# file, then mv. mv is atomic on POSIX filesystems, so a crash mid-write won't
# corrupt the state file (we'd lose at most the temp file, and default to 0 on
# next read).
TEMP_FILE="${STATE_FILE}.tmp.$$"
if ! printf '%s\n' "${ITERATION}:${NOW_EPOCH}:${STALL_COUNT}" > "$TEMP_FILE" || ! command mv -f "$TEMP_FILE" "$STATE_FILE"; then
  echo "WARNING: Failed to save loop state. Allowing stop."
  command rm -f "$TEMP_FILE" 2>/dev/null
  exit 0
fi

# Resolve the audit prompt — injected into stderr so Claude sees it on its next turn.
# Three sources, checked in priority order:
#   1. DOYAKEN_LOOP_PROMPT env var — set by dk.sh wrapper per-phase (preloaded from file)
#   2. Phase audit file from prompts/phase-audits/<name>.md — looked up via DOYAKEN_LOOP_PHASE
#      (used by in-session activations like /dkloop where the env var isn't set)
#   3. Generic fallback — hardcoded prompt below, used when neither source is available
AUDIT_PROMPT="${DOYAKEN_LOOP_PROMPT:-}"
AUDIT_SOURCE_FILE="${CONFIG_AUDIT_FILE:-}"

if [[ -z "$AUDIT_PROMPT" ]]; then
  LOOP_PHASE="${DOYAKEN_LOOP_PHASE:-}"
  # Map phase number to audit file basename (must match actual filenames)
  AUDIT_FILENAME=""
  case "$LOOP_PHASE" in
    1) AUDIT_FILENAME="1-plan" ;;
    2) AUDIT_FILENAME="2-implement" ;;
    3) AUDIT_FILENAME="3-review-loop" ;;
    4) AUDIT_FILENAME="4-verify" ;;
    5) AUDIT_FILENAME="5-pr" ;;
    6) AUDIT_FILENAME="6-complete" ;;
    prompt-loop) AUDIT_FILENAME="prompt-loop" ;;
  esac
  AUDIT_FILE="$DOYAKEN_DIR/prompts/phase-audits/${AUDIT_FILENAME}.md"
  if [[ -n "$AUDIT_FILENAME" ]] && [[ -f "$AUDIT_FILE" ]]; then
    AUDIT_SOURCE_FILE="$AUDIT_FILE"
    AUDIT_PROMPT=$(cat "$AUDIT_FILE")
  fi
fi

if [[ -z "$AUDIT_SOURCE_FILE" ]]; then
  AUDIT_SOURCE_FILE=$(dk_phase_audit_file "${DOYAKEN_LOOP_PHASE:-}" 2>/dev/null || true)
fi

if [[ -z "$AUDIT_PROMPT" ]]; then
  AUDIT_PROMPT="You are not done yet. Review your work critically before stopping:

1. Is the current phase fully complete?
2. Are there any issues, improvements, or optimizations remaining?
3. Have you verified the quality of your output?

If something needs work, fix it and try again."
fi

echo "" >&2
if [[ "${DOYAKEN_LOOP_PHASE:-}" == "prompt-loop" ]]; then
  echo "--- Prompt Loop: iteration $ITERATION/$MAX_ITERATIONS ---" >&2
else
  echo "--- Phase Audit: iteration $ITERATION/$MAX_ITERATIONS ---" >&2
fi
echo "" >&2

# Re-inject the original prompt so Claude doesn't lose it after context compaction.
# The prompt file is written by dkloop in dk.sh before launching Claude.
PROMPT_FILE=$(dk_prompt_file "$SESSION_ID")
if [[ -f "$PROMPT_FILE" ]]; then
  printf '%s\n' "## Original Task Prompt" >&2
  printf '%s\n' "" >&2
  cat "$PROMPT_FILE" >&2
  printf '%s\n' "" >&2
  printf '%s\n' "---" >&2
  printf '%s\n' "" >&2
fi

# If stalled beyond the escalation threshold, inject an escalation prompt instead
# of (or in addition to) the normal audit prompt.
if [[ $IS_STALLED -eq 1 ]] && [[ $STALL_COUNT -ge $STALL_ESCALATE_AFTER ]]; then
  printf '%s\n' "## STUCK LOOP DETECTED (stalled $STALL_COUNT times)" >&2
  printf '%s\n' "" >&2
  printf '%s\n' "You appear to be stuck in a loop. The last $STALL_COUNT iterations each took longer than $(dk_format_duration "$STALL_TIMEOUT") without making progress." >&2
  printf '%s\n' "" >&2
  printf '%s\n' "MANDATORY: Read prompts/failure-recovery.md and run the failure analysis." >&2
  printf '%s\n' "You MUST choose a different recovery strategy. Do NOT retry the same approach." >&2
  printf '%s\n' "" >&2
fi

if [[ $SEMANTIC_STUCK -eq 1 ]]; then
  printf '%s\n' "## STUCK LOOP DETECTED (same findings recurring)" >&2
  printf '%s\n' "" >&2
  printf '%s\n' "The last 3+ review cycles found the SAME issues. You are going in circles." >&2
  printf '%s\n' "" >&2
  printf '%s\n' "MANDATORY: Read prompts/failure-recovery.md and run the failure analysis." >&2
  printf '%s\n' "You MUST choose a different strategy. Options:" >&2
  printf '%s\n' "  - CHANGE_APPROACH: Try a fundamentally different implementation" >&2
  printf '%s\n' "  - ACCEPT_WITH_DEBT: Accept non-critical findings and track as debt" >&2
  printf '%s\n' "  - SPLIT_TASK: Reduce scope to what you can complete cleanly" >&2
  printf '%s\n' "  - ESCALATE: Signal completion and let the user take over" >&2
  printf '%s\n' "" >&2
fi

if [[ $ITERATION -gt 1 ]] && dk_compact_repeat_audit_prompt "${DOYAKEN_LOOP_PHASE:-}" "$AUDIT_SOURCE_FILE" >&2; then
  :
else
  printf '%s\n' "$AUDIT_PROMPT" >&2
fi
echo "" >&2

# Completion gate — only provide completion instructions after enough audit iterations.
# Before the threshold: Claude can't complete (doesn't know how to write .complete).
# After the threshold: Claude receives the .complete file path and promise string.
# COMPLETE_FILE was already set above (line 87) for the early-exit check.
if [[ $ITERATION -ge $MIN_AUDIT_ITERATIONS ]]; then
  printf '%s\n' "---" >&2
  printf '%s\n' "## Completion Signal Available ($ITERATION/$MIN_AUDIT_ITERATIONS audit iterations reached)" >&2
  printf '%s\n' "" >&2
  printf '%s\n' "If ALL completion criteria above are met, you may now signal completion:" >&2
  printf '%s\n' "" >&2
  printf '%s\n' "1. Write the signal file:" >&2
  printf '%s\n' '```bash' >&2
  printf '%s\n' "touch \"${COMPLETE_FILE}\"" >&2
  printf '%s\n' '```' >&2
  printf '%s\n' "2. Output the promise string: ${COMPLETION_PROMISE}" >&2
  printf '%s\n' "" >&2
  printf '%s\n' "If criteria are NOT met, fix the issues and stop again. Do NOT write the signal file until all criteria pass." >&2
  printf '%s\n' "" >&2
else
  REMAINING=$((MIN_AUDIT_ITERATIONS - ITERATION))
  printf '%s\n' "---" >&2
  printf '%s\n' "## Completion NOT Yet Authorized (audit iteration $ITERATION/$MIN_AUDIT_ITERATIONS)" >&2
  printf '%s\n' "" >&2
  printf '%s\n' "You must complete $REMAINING more audit iteration(s) before completion can be authorized." >&2
  printf '%s\n' "Follow the audit steps above, then stop again for the next iteration." >&2
  printf '%s\n' "Do NOT attempt to write any completion signal files." >&2
  printf '%s\n' "" >&2
fi

# Exit 2 to block the Stop action
exit 2

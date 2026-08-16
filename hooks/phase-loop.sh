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
#   - DEX_LOOP_ACTIVE=1 in environment (set by dx/dxloop wrappers)
#   - .active signal file in DX_LOOP_DIR (created by /dxloop skill for in-session use)
# Deactivated by: .complete file or max iterations
#
# See: docs/autonomous-mode.md for full architecture documentation
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
mkdir -p "$DX_LOOP_DIR"

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
if ! dx_session_id_valid "$SESSION_ID"; then
  printf '%s\n' "Dex: refusing unsafe session id." >&2
  exit 1
fi

dx_phase_name() {
  case "$1" in
    0) printf '%s\n' "Setup" ;;
    1) printf '%s\n' "Plan" ;;
    2) printf '%s\n' "Implement" ;;
    3) printf '%s\n' "Review" ;;
    4) printf '%s\n' "Verify & Commit" ;;
    5) printf '%s\n' "PR" ;;
    6) printf '%s\n' "Complete" ;;
    *) printf '%s\n' "Unknown" ;;
  esac
}

dx_phase_promise() {
  case "$1" in
    0) printf '%s\n' "PHASE_0_COMPLETE" ;;
    1) printf '%s\n' "PHASE_1_COMPLETE" ;;
    2) printf '%s\n' "PHASE_2_COMPLETE" ;;
    3) printf '%s\n' "PHASE_3_COMPLETE" ;;
    4) printf '%s\n' "PHASE_4_COMPLETE" ;;
    5) printf '%s\n' "PHASE_5_COMPLETE" ;;
    6) printf '%s\n' "DEX_TICKET_COMPLETE" ;;
    *) printf '%s\n' "DEX_TICKET_COMPLETE" ;;
  esac
}

dx_phase_audit_file() {
  local phase="$1" name
  case "$phase" in
    0) name="0-setup" ;;
    1) name="1-plan" ;;
    2) name="2-implement" ;;
    3) name="3-review-loop" ;;
    4) name="4-verify" ;;
    5) name="5-pr" ;;
    6) name="6-complete" ;;
    *) name="" ;;
  esac
  [[ -n "$name" ]] && printf '%s\n' "$DEX_DIR/prompts/phase-audits/${name}.md"
}

dx_phase_min_audits() {
  local phase="$1" env_name value
  env_name="DEX_PHASE_${phase}_MIN_AUDITS"
  value="$(printenv "$env_name" 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "1"
  fi
}

dx_reverse_file_lines() {
  local file="$1"
  awk '{ lines[NR] = $0 } END { for (i = NR; i >= 1; i--) print lines[i] }' "$file"
}

dx_phase_iteration_count() {
  local state_file="$1" raw iterations
  raw=$(cat "$state_file" 2>/dev/null || echo "0")
  iterations="${raw%%:*}"
  if [[ "$iterations" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$iterations"
  else
    printf '%s\n' "0"
  fi
}

# dx_format_duration comes from lib/output.sh via common.sh.

# Normalize an environment-supplied loop limit before bash arithmetic sees it.
# Fifteen digits leave enough headroom for the minute-to-second conversions
# and epoch additions below. Stripping leading zeroes avoids octal parsing.
dx_normalize_numeric_limit() {
  local value="${1:-}"
  case "$value" in
    ""|*[!0-9]*) return 1 ;;
  esac

  while [[ ${#value} -gt 1 && "$value" == 0* ]]; do
    value="${value#0}"
  done
  [[ ${#value} -le 15 ]] || return 1
  printf '%s\n' "$value"
}

dx_report_invalid_numeric_limit() {
  local name="$1" value="$2"
  printf '\n%s\n\n' "--- Dex loop blocked: invalid numeric limit ---" >&2
  printf '%s\n' "${name}='${value}' must be a non-negative decimal with at most 15 digits." >&2
  printf '%s\n' "Correct or unset ${name}, then stop again." >&2
}

dx_phase_start_epoch() {
  local phase="$1" times_file
  times_file=$(dx_times_file "$SESSION_ID")
  if [[ -f "$times_file" ]]; then
    awk -F: -v phase="$phase" '$1 == phase { start=$2 } END { if (start != "") print start }' "$times_file"
  fi
}

dx_record_phase_result() {
  local phase="$1" status="$2" exit_code="$3" start_epoch end_epoch duration iterations phase_name
  local outcome_status=0 outcome_generation
  [[ "$phase" =~ ^[0-6]$ ]] || return 0
  end_epoch=$(date +%s)
  start_epoch=$(dx_phase_start_epoch "$phase")
  [[ "$start_epoch" =~ ^[0-9]+$ ]] || start_epoch="$end_epoch"
  duration=$((end_epoch - start_epoch))
  iterations=$(dx_phase_iteration_count "$STATE_FILE")
  phase_name=$(dx_phase_name "$phase")
  dx_log_phase "$SESSION_ID" "$phase" "$phase_name" "$start_epoch" "$end_epoch" "$duration" "$iterations" "$status" "$exit_code"

  local event_type severity message data_json
  if [[ "$status" == "advance" && "$exit_code" == "0" ]]; then
    event_type="phase.completed"
    severity="info"
    message="Phase ${phase} completed: ${phase_name}"
    outcome_generation="phase-loop-${phase}-${end_epoch}-$$-${RANDOM}"
    dx_phase_outcome_record "$SESSION_ID" "$phase" "completed" "phase-loop" \
      "$outcome_generation" "gates-passed" || outcome_status=$?
    if [[ "$outcome_status" -ne 0 && "$outcome_status" -ne 3 ]]; then
      dx_run_log_append_for_session "$SESSION_ID" "warn" "phase-loop" \
        "Could not append the explicit Phase ${phase} completion receipt; the successful phase log remains available for progress reconciliation"
    fi
  else
    event_type="phase.failed"
    severity="error"
    message="Phase ${phase} failed: ${phase_name} (${status})"
  fi
  data_json=$(
    DX_PHASE_NAME="$phase_name" \
    DX_PHASE_START_EPOCH="$start_epoch" \
    DX_PHASE_END_EPOCH="$end_epoch" \
    DX_PHASE_DURATION="$duration" \
    DX_PHASE_ITERATIONS="$iterations" \
    DX_PHASE_STATUS="$status" \
    DX_PHASE_EXIT_CODE="$exit_code" \
    python3 - <<'PY'
import json
import os


def as_int(name):
    try:
        return int(os.environ.get(name, "0"))
    except ValueError:
        return 0


print(json.dumps({
    "phase_name": os.environ.get("DX_PHASE_NAME", ""),
    "start_epoch": as_int("DX_PHASE_START_EPOCH"),
    "end_epoch": as_int("DX_PHASE_END_EPOCH"),
    "duration_s": as_int("DX_PHASE_DURATION"),
    "iterations": as_int("DX_PHASE_ITERATIONS"),
    "status": os.environ.get("DX_PHASE_STATUS", ""),
    "exit_code": as_int("DX_PHASE_EXIT_CODE"),
}, sort_keys=True, separators=(",", ":")))
PY
  )
  dx_event_emit_for_session "$SESSION_ID" "$event_type" "$severity" "$message" "$phase" "$data_json"
  dx_run_log_append_for_session "$SESSION_ID" "$severity" "phase-loop" "${message}; status=${status}; duration_s=${duration}; iterations=${iterations}; exit_code=${exit_code}"
}

dx_start_phase_timer() {
  local phase="$1" times_file
  times_file=$(dx_times_file "$SESSION_ID")
  mkdir -p "$(dirname "$times_file")"
  printf '%s:%s\n' "$phase" "$(date +%s)" >> "$times_file"
  dx_event_maybe_emit_phase_started_for_session "$SESSION_ID" "$phase" "$(dx_phase_name "$phase")" "hook"
  dx_run_log_append_for_session "$SESSION_ID" "info" "phase-loop" "Phase ${phase} started: $(dx_phase_name "$phase")"
}

# Claude hook subprocesses can inherit stale DEX_LOOP_PHASE values from the
# original launch. In inline mode, the phase file is the lifecycle source of
# truth after handoffs, so use it to recover before applying phase-specific gates.
dx_sync_inline_phase_from_state() {
  [[ "$HANDOFF_MODE" == "inline" ]] || return 0

  local phase_file phase phase_min audit_file
  phase_file=$(dx_state_file "$SESSION_ID")
  [[ -f "$phase_file" ]] || return 0

  phase=$(cat "$phase_file" 2>/dev/null || echo "")
  [[ "$phase" =~ ^[0-6]$ ]] || return 0
  [[ "${DEX_LOOP_PHASE:-}" == "$phase" ]] && return 0

  DEX_LOOP_PHASE="$phase"
  DEX_LOOP_PROMISE=$(dx_phase_promise "$phase")
  phase_min=$(dx_phase_min_audits "$phase")
  MIN_AUDIT_ITERATIONS="${DEX_LOOP_MIN_AUDITS:-$phase_min}"

  audit_file=$(dx_phase_audit_file "$phase")
  if [[ -n "$audit_file" && -f "$audit_file" ]]; then
    DEX_LOOP_PROMPT=$(cat "$audit_file")
  fi
}

dx_inline_phase_message() {
  case "$1" in
    1)
      cat <<'EOF'
Phase 0 setup is complete (branch renamed and pushed, ticket assigned, status set to In Progress). Begin Phase 1: Plan. Call EnterPlanMode now, then immediately invoke the Skill tool with skill: "dxplan". Do not redo ticket setup unless something is clearly missing. For freeform task requests with a configured tracker, after the user approves the plan via ExitPlanMode, offer the dxplan tracker intake choices before writing the Phase 1 approval marker. After that gate is complete or explicitly skipped, write the Phase 1 approval marker and stop so the Stop hook can audit and advance.

For headless dx run sessions with workflow.requires_plan_approval=false, the run spec authorizes Phase 1 after the normal plan quality checks pass; follow the dxplan headless instructions instead of waiting for interactive approval.
EOF
      ;;
    2)
      cat <<'EOF'
The plan is approved. Invoke the Skill tool with skill: "dximplement" to begin implementation. Phase focus: implementation, testing, and UI capture evidence. For UI-affecting changes, invoke dxuicapture before UI edits for baseline evidence, then capture after evidence and link the visual manifest/screenshots/videos/traces before stopping. Commit, push, branch, and PR actions remain available when useful; later phases still perform the normal verification and handoff. When implementation is complete and the audit criteria are met, stop so the Stop hook can advance the lifecycle.
EOF
      ;;
    3)
      cat <<'EOF'
Begin Phase 3: Review. Invoke the Skill tool with skill: "dxreviewloop". Use the current Phase 2 risk selection: small requires 3, normal 6, and complex 9 consecutive independent CLEAN waves. Each fresh wave builds its own context pack, runs deterministic checks and domain review, verifies findings, batch-fixes safe issues, and rechecks. Any fix resets the clean streak. Residual findings, blockers, churn, invalid results, or provider failures pause the loop instead of counting as clean. Phase focus: review and fixes. Commit, push, branch, and PR actions remain available when useful. When the loop writes a valid success receipt, stop so the Stop hook can audit and advance.
EOF
      ;;
    4)
      cat <<'EOF'
Begin Phase 4: Verify & Commit. Invoke the Skill tool with skill: "dxverify" to run the quality pipeline. Fix failures and rerun until green. Then invoke skill: "dxcommit" to commit and push. PR creation and broader implementation work remain available when useful. When pushed, stop so the Stop hook can audit and advance.
EOF
      ;;
    5)
      cat <<'EOF'
Begin Phase 5: PR. Invoke the Skill tool with skill: "dxpr" to generate the PR description, prepare any UI visual evidence handoff, create or update the PR, and attach configured request reviewers. Ready-state changes, @mention comments, implementation changes, commits, and pushes remain available when useful; Phase 6 still performs the normal completion workflow. When done, stop so the Stop hook can audit and advance.
EOF
      ;;
    6)
      cat <<'EOF'
Begin Phase 6: Complete. Invoke the Skill tool with skill: "dxcomplete". Mark the PR ready, request reviewers, post configured @mention comments, monitor CI/reviews through /dxwatchpr, address failures, and close the ticket when CI is green and configured reviewers approve. Do not merge the PR. Continue unattended until completion, the bounded watch window expires, or a real escalation condition is hit.
EOF
      ;;
  esac
}

dx_compact_repeat_audit_prompt() {
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
      printf '%s\n' "- No Phase 2 background processes or long-running verification commands are still in flight."
      printf '%s\n' "- Any needed .dex/ updates are made."
      printf '%s\n' "- UI capture evidence is linked for UI-affecting changes, including before/after evidence or a before-unavailable reason, or UI capture is explicitly marked N/A."
      printf '%s\n' "- The Phase 2 ready marker has been written."
      printf '%s\n' ""
      printf '%s\n' "If any item is not true, continue implementing or verifying instead of signalling completion."
      ;;
    *)
      return 1
      ;;
  esac
}

# Check activation: env var OR .active file (for in-session /dxloop skill)
ACTIVE_FILE=$(dx_active_file "$SESSION_ID")
LOOP_ACTIVE="${DEX_LOOP_ACTIVE:-0}"
if [[ "$LOOP_ACTIVE" != "1" ]] && [[ ! -f "$ACTIVE_FILE" ]]; then
  exit 0
fi

# Claude Code sends the hook payload on stdin; session_id identifies the
# concrete Claude session this Stop fired in. Used for the ownership guard
# below — dx session ids are path-derived, so multiple Claude sessions in the
# same checkout resolve the same SESSION_ID. Parsed only after the activation
# check above so stops in non-Dex sessions never pay the python3 spawn.
HOOK_INPUT=$(cat 2>/dev/null || true)
HOOK_CLAUDE_SESSION_ID=""
if [[ -n "$HOOK_INPUT" ]]; then
  HOOK_CLAUDE_SESSION_ID=$(printf '%s' "$HOOK_INPUT" | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get("session_id", "")
except Exception:
    value = ""
if isinstance(value, str):
    print(value)
' 2>/dev/null || true)
fi

# Ownership guard — SESSION_ID is path-derived, so a bystander Claude session
# opened in the same worktree/branch resolves the same id and would otherwise
# be captured by this hook (injected audits, phase handoffs). Claim rules:
#   - env-activated sessions (DEX_LOOP_ACTIVE=1 with an explicit
#     DEX_SESSION_ID) were launched by a dx wrapper for exactly this loop;
#     they own it and (re)claim on every stop.
#   - file-activated sessions (.active only) claim only when unclaimed; on a
#     mismatch they stay inert.
# Wrappers remove the claim before each launch (relaunch/--resume gets a fresh
# Claude session id). Empty HOOK_CLAUDE_SESSION_ID (payload missing/unparsable)
# skips enforcement rather than breaking active loops.
OWNER_FILE=$(dx_owner_file "$SESSION_ID")
if [[ -n "$HOOK_CLAUDE_SESSION_ID" ]]; then
  OWNER_ID=""
  [[ -f "$OWNER_FILE" ]] && OWNER_ID=$(cat "$OWNER_FILE" 2>/dev/null || echo "")
  if [[ "$OWNER_ID" != "$HOOK_CLAUDE_SESSION_ID" ]]; then
    if [[ "$LOOP_ACTIVE" == "1" && -n "${DEX_SESSION_ID:-}" ]]; then
      printf '%s\n' "$HOOK_CLAUDE_SESSION_ID" > "$OWNER_FILE" 2>/dev/null || true
    elif [[ -n "$OWNER_ID" ]]; then
      exit 0
    else
      printf '%s\n' "$HOOK_CLAUDE_SESSION_ID" > "$OWNER_FILE" 2>/dev/null || true
    fi
  fi
fi

HANDOFF_MODE="${DEX_PHASE_HANDOFF:-}"
HANDOFF_MODE_FILE=$(dx_handoff_mode_file "$SESSION_ID")
if [[ -z "$HANDOFF_MODE" && -f "$HANDOFF_MODE_FILE" ]]; then
  HANDOFF_MODE=$(cat "$HANDOFF_MODE_FILE" 2>/dev/null || echo "")
fi

# Review-wave passes are single-shot child sessions. They must never run the
# inline lifecycle handoff — advancing the shared phase state and instructing
# the wave to commit/push — even when they inherit lifecycle loop env or share
# a handoff-mode file with the parent session. Forcing non-inline here routes a
# completed pass to the plain "loop complete" stop below.
if [[ "${DEX_REVIEW_PASS_ACTIVE:-}" == "1" ]]; then
  HANDOFF_MODE=""
fi
PAUSED_FILE=$(dx_paused_file "$SESSION_ID")
COMPLETE_FILE=$(dx_complete_file "$SESSION_ID")
PHASE_STATE_FILE=$(dx_state_file "$SESSION_ID")
CONFIG_FILE=$(dx_loop_config_file "$SESSION_ID")

# Direct human lifecycle control wins before every readiness, busy, wait, and
# completion gate. The UserPromptSubmit hook writes this receipt from the
# human's prompt before the agent receives its next turn.
if ! dx_lifecycle_control_lock_acquire "$SESSION_ID"; then
  printf '\n%s\n' "Dex is already applying lifecycle state; stop again after it finishes." >&2
  exit 2
fi

# The phase file is the transition commit point. If a prior process published
# the next config but exited before committing the phase, rebuild config from
# the authoritative phase before any gate reads it.
AUTHORITATIVE_PHASE=$(cat "$PHASE_STATE_FILE" 2>/dev/null || true)
if [[ "$AUTHORITATIVE_PHASE" =~ ^[0-6]$ ]]; then
  CONFIG_PHASE=$(cut -d: -f1 "$CONFIG_FILE" 2>/dev/null || true)
  if [[ "$CONFIG_PHASE" != "$AUTHORITATIVE_PHASE" ]]; then
    REPAIR_CONFIG="${AUTHORITATIVE_PHASE}:$(dx_phase_promise "$AUTHORITATIVE_PHASE"):$(dx_phase_audit_file "$AUTHORITATIVE_PHASE"):$(dx_phase_min_audits "$AUTHORITATIVE_PHASE")"
    if ! dx_lifecycle_atomic_write "$CONFIG_FILE" "$REPAIR_CONFIG"; then
      dx_lifecycle_control_lock_release "$SESSION_ID" || true
      printf '\n%s\n' "Dex could not repair lifecycle config from the authoritative phase state." >&2
      exit 2
    fi
  fi
fi

CONTROL_SNAPSHOT=$(dx_lifecycle_control_snapshot_unlocked "$SESSION_ID")
CONTROL_ACTION=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" action)
CONTROL_TARGET=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" target_phase)
CONTROL_EXPECTED_PHASE=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" expected_phase)
CONTROL_SOURCE=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" source)
CONTROL_OWNER=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" owner_session)
CONTROL_GENERATION=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" generation)

CONTROL_VALID=0
if [[ "$CONTROL_SOURCE" == "user-prompt" || "$CONTROL_SOURCE" == "terminal" ]]; then
  if [[ "$CONTROL_GENERATION" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]]; then
    case "$CONTROL_ACTION" in
      pause|cancel|resume) CONTROL_VALID=1 ;;
      complete|jump) [[ "$CONTROL_TARGET" =~ ^[0-7]$ ]] && CONTROL_VALID=1 ;;
    esac
  fi
fi
if [[ -n "$CONTROL_OWNER" && ( -z "$HOOK_CLAUDE_SESSION_ID" || "$CONTROL_OWNER" != "$HOOK_CLAUDE_SESSION_ID" ) ]]; then
  CONTROL_VALID=0
fi

if [[ "$CONTROL_VALID" -eq 1 ]]; then
  case "$CONTROL_ACTION" in
    resume)
      dx_clear_lifecycle_control_unlocked "$SESSION_ID"
      rm -f "$PAUSED_FILE" "$(dx_pause_state_file "$SESSION_ID")" 2>/dev/null || true
      touch "$ACTIVE_FILE"
      dx_lifecycle_control_lock_release "$SESSION_ID" || true
      ;;
    pause|cancel)
      dx_write_pause_state "$SESSION_ID" "manual-${CONTROL_ACTION}" "$CONTROL_SOURCE" 2>/dev/null || true
      [[ -f "$(dx_phase_busy_file "$SESSION_ID" 3)" ]] && dx_phase_busy_request_cancel "$SESSION_ID" 3 2>/dev/null || true
      touch "$PAUSED_FILE"
      rm -f "$ACTIVE_FILE" "$COMPLETE_FILE" "$(dx_loop_file "$SESSION_ID")" 2>/dev/null || true
      dx_run_log_append_for_session "$SESSION_ID" "warn" "phase-loop" \
        "Dex lifecycle ${CONTROL_ACTION} accepted from direct human instruction; generation=${CONTROL_GENERATION}" 2>/dev/null || true
      dx_lifecycle_control_lock_release "$SESSION_ID" || true
      printf '{"continue":false,"stopReason":"Dex lifecycle %s by direct human instruction."}\n' "$CONTROL_ACTION"
      exit 0
      ;;
    complete|jump)
      CONTROL_CURRENT_PHASE=$(dx_lifecycle_current_phase "$SESSION_ID")
      CONTROL_FROM_PHASE="$CONTROL_CURRENT_PHASE"
      CONTROL_RECOVERY=0
      CONTROL_CAN_APPLY=1
      if [[ "${DEX_REVIEW_PASS_ACTIVE:-}" == "1" || "$HANDOFF_MODE" != "inline" ]]; then
        dx_write_pause_state "$SESSION_ID" "manual-${CONTROL_ACTION}" "$CONTROL_SOURCE" 2>/dev/null || true
        touch "$PAUSED_FILE"
        rm -f "$ACTIVE_FILE" "$COMPLETE_FILE" "$(dx_loop_file "$SESSION_ID")" 2>/dev/null || true
        dx_lifecycle_control_lock_release "$SESSION_ID" || true
        printf '{"continue":false,"stopReason":"Dex loop stopped by direct human instruction."}\n'
        exit 0
      elif [[ "$CONTROL_TARGET" == "$CONTROL_CURRENT_PHASE" \
        && "$CONTROL_EXPECTED_PHASE" =~ ^[0-7]$ \
        && "$CONTROL_EXPECTED_PHASE" != "$CONTROL_CURRENT_PHASE" ]]; then
        # Config/state publication happens before cleanup. A surviving control
        # receipt whose target is now authoritative is a recoverable commit:
        # finish its ledger and cleanup work before clearing the receipt.
        CONTROL_FROM_PHASE="$CONTROL_EXPECTED_PHASE"
        CONTROL_RECOVERY=1
      elif [[ -n "$CONTROL_EXPECTED_PHASE" && "$CONTROL_EXPECTED_PHASE" != "$CONTROL_CURRENT_PHASE" ]]; then
        dx_run_log_append_for_session "$SESSION_ID" "warn" "phase-loop" \
          "Ignored stale human lifecycle transition: expected_phase=${CONTROL_EXPECTED_PHASE}; current_phase=${CONTROL_CURRENT_PHASE}; generation=${CONTROL_GENERATION}" 2>/dev/null || true
        dx_clear_lifecycle_control_unlocked "$SESSION_ID"
        dx_lifecycle_control_lock_release "$SESSION_ID" || true
        CONTROL_CAN_APPLY=0
      elif [[ "$CONTROL_TARGET" == "$CONTROL_CURRENT_PHASE" ]]; then
        dx_clear_lifecycle_control_unlocked "$SESSION_ID"
        dx_lifecycle_control_lock_release "$SESSION_ID" || true
        CONTROL_CAN_APPLY=0
      fi

      if [[ "$CONTROL_CAN_APPLY" -eq 1 ]]; then
        if [[ "$CONTROL_ACTION" == "complete" \
          && "$CONTROL_TARGET" -ne $((CONTROL_FROM_PHASE + 1)) ]]; then
          dx_run_log_append_for_session "$SESSION_ID" "warn" "phase-loop" \
            "Ignored invalid human completion transition: phase=${CONTROL_FROM_PHASE}; target_phase=${CONTROL_TARGET}; generation=${CONTROL_GENERATION}" 2>/dev/null || true
          dx_clear_lifecycle_control_unlocked "$SESSION_ID"
          dx_lifecycle_control_lock_release "$SESSION_ID" || true
        elif dx_phase_busy_transition_blocked "$SESSION_ID" 3 "$CONTROL_FROM_PHASE" "$CONTROL_TARGET"; then
          dx_write_pause_state "$SESSION_ID" "review-child-active" "$CONTROL_SOURCE" 2>/dev/null || true
          dx_phase_busy_request_cancel "$SESSION_ID" 3 2>/dev/null || true
          touch "$PAUSED_FILE"
          rm -f "$ACTIVE_FILE" "$COMPLETE_FILE" "$(dx_loop_file "$SESSION_ID")" 2>/dev/null || true
          dx_lifecycle_control_lock_release "$SESSION_ID" || true
          printf '\n%s\n\n' "--- Dex detached by direct human instruction ---" >&2
          printf '%s\n' "The active review child must finish or be interrupted before a phase jump can be applied. Its result will not advance the lifecycle." >&2
          exit 0
        else
          if ! dx_consume_completion_receipt "$SESSION_ID"; then
            dx_lifecycle_control_lock_release "$SESSION_ID" || true
            printf '\n%s\n' "Dex could not consume the current phase completion receipt. The human transition remains pending." >&2
            exit 2
          fi

          if [[ "$CONTROL_RECOVERY" -eq 0 ]]; then
            CONTROL_CONFIG="${CONTROL_TARGET}:$(dx_phase_promise "$CONTROL_TARGET"):$(dx_phase_audit_file "$CONTROL_TARGET"):$(dx_phase_min_audits "$CONTROL_TARGET")"
            [[ "$CONTROL_TARGET" == "7" ]] && CONTROL_CONFIG="7:::0"
            if ! dx_lifecycle_atomic_write "$CONFIG_FILE" "$CONTROL_CONFIG" \
              || ! dx_lifecycle_atomic_write "$PHASE_STATE_FILE" "$CONTROL_TARGET"; then
              dx_lifecycle_control_lock_release "$SESSION_ID" || true
              printf '\n%s\n' "Dex could not commit the human phase transition. The current phase remains authoritative; stop again to retry the pending human transition." >&2
              exit 2
            fi
          fi

          if ! dx_record_human_phase_outcomes "$SESSION_ID" "$CONTROL_FROM_PHASE" \
            "$CONTROL_TARGET" "$CONTROL_ACTION" "$CONTROL_GENERATION" "$CONTROL_SOURCE" \
            "$CONTROL_RECOVERY"; then
            dx_lifecycle_control_lock_release "$SESSION_ID" || true
            printf '\n%s\n' "Dex committed the human phase transition but could not finish its outcome ledger. The control receipt was preserved for recovery." >&2
            exit 2
          fi

          dx_run_log_append_for_session "$SESSION_ID" "warn" "phase-loop" \
            "Human-authorized lifecycle transition: phase=${CONTROL_FROM_PHASE}; target_phase=${CONTROL_TARGET}; action=${CONTROL_ACTION}; generation=${CONTROL_GENERATION}; recovery=${CONTROL_RECOVERY}" 2>/dev/null || true

          # Cleanup follows the authoritative phase commit. A Phase 3 busy
          # marker is owned by the review orchestrator and survives unless its
          # matching token has acknowledged quiescence.
          rm -f "$(dx_loop_file "$SESSION_ID")" "$(dx_findings_file "$SESSION_ID")" \
            "$PAUSED_FILE" "$(dx_pause_state_file "$SESSION_ID")" 2>/dev/null || true
          for CONTROL_PHASE in 0 1 2 3 4 5 6; do
            rm -f "$(dx_phase_started_file "$SESSION_ID" "$CONTROL_PHASE")" \
              "$(dx_phase_ready_file "$SESSION_ID" "$CONTROL_PHASE")" 2>/dev/null || true
            if [[ "$CONTROL_PHASE" != "3" ]]; then
              rm -f "$(dx_phase_busy_file "$SESSION_ID" "$CONTROL_PHASE")" \
                "$(dx_phase_busy_notice_file "$SESSION_ID" "$CONTROL_PHASE")" 2>/dev/null || true
            fi
          done
          if dx_phase_busy_quiesced "$SESSION_ID" 3; then
            CONTROL_BUSY_TOKEN=$(dx_phase_busy_token "$SESSION_ID" 3)
            dx_phase_busy_finish "$SESSION_ID" 3 "$CONTROL_BUSY_TOKEN" 2>/dev/null || true
          fi

          if [[ "$CONTROL_TARGET" == "7" ]]; then
            if ! touch "$(dx_lifecycle_human_complete_file "$SESSION_ID")"; then
              dx_lifecycle_control_lock_release "$SESSION_ID" || true
              printf '\n%s\n' "Dex recorded human-authorized completion but could not persist its workspace-preservation marker. The control receipt was preserved for recovery." >&2
              exit 2
            fi
            dx_clear_lifecycle_control_unlocked "$SESSION_ID"
            rm -f "$ACTIVE_FILE" "$OWNER_FILE" "$HANDOFF_MODE_FILE" "$CONFIG_FILE" 2>/dev/null || true
            dx_lifecycle_control_lock_release "$SESSION_ID"
            {
              printf '\n%s\n\n' "--- Dex lifecycle marked complete by direct human instruction ---"
              printf '%s\n' "The lifecycle workspace is preserved; human-authorized completion does not run automatic worktree cleanup."
            } >&2
            exit 2
          fi

          dx_clear_lifecycle_control_unlocked "$SESSION_ID"
          touch "$ACTIVE_FILE"
          dx_start_phase_timer "$CONTROL_TARGET"
          dx_lifecycle_control_lock_release "$SESSION_ID"
          {
            printf '\n%s\n\n' "--- Dex phase changed by direct human instruction ---"
            printf 'Continue at Phase %s (%s). Earlier gates carry explicit human-authorized outcomes in the lifecycle ledger.\n\n' \
              "$CONTROL_TARGET" "$(dx_phase_name "$CONTROL_TARGET")"
            dx_inline_phase_message "$CONTROL_TARGET"
          } >&2
          exit 2
        fi
      fi
      ;;
  esac
elif [[ -n "$CONTROL_SNAPSHOT" ]]; then
  # A malformed or foreign receipt must not remain live indefinitely.
  dx_clear_lifecycle_control_unlocked "$SESSION_ID"
  dx_lifecycle_control_lock_release "$SESSION_ID" || true
else
  dx_lifecycle_control_lock_release "$SESSION_ID" || true
fi

# After inline Phase 6 completes, the Claude process can still carry stale
# DEX_LOOP_ACTIVE/DEX_LOOP_PHASE env vars until the user closes the
# session. The phase state file is authoritative; phase 7 means the lifecycle is
# done and the Stop hook must not re-enter an earlier gate.
if [[ "$HANDOFF_MODE" == "inline" && -f "$PHASE_STATE_FILE" ]]; then
  PHASE_STATE=$(cat "$PHASE_STATE_FILE" 2>/dev/null || echo "")
  if [[ "$PHASE_STATE" == "7" ]]; then
    rm -f "$ACTIVE_FILE" "$OWNER_FILE" "$HANDOFF_MODE_FILE" "$PAUSED_FILE" "$COMPLETE_FILE" \
      "$(dx_pause_state_file "$SESSION_ID")" "$(dx_loop_file "$SESSION_ID")" \
      "$(dx_loop_config_file "$SESSION_ID")" "$(dx_findings_file "$SESSION_ID")" \
      "$(dx_prompt_file "$SESSION_ID")" "${DX_LOOP_DIR}/${SESSION_ID}".phase-*.started \
      "${DX_LOOP_DIR}/${SESSION_ID}".phase-*.ready "${DX_LOOP_DIR}/${SESSION_ID}".phase-*.busy-notice 2>/dev/null
    for FINISHED_PHASE in 0 1 2 4 5 6; do
      rm -f "$(dx_phase_busy_file "$SESSION_ID" "$FINISHED_PHASE")" 2>/dev/null || true
    done
    if dx_phase_busy_quiesced "$SESSION_ID" 3; then
      FINISHED_BUSY_TOKEN=$(dx_phase_busy_token "$SESSION_ID" 3)
      dx_phase_busy_finish "$SESSION_ID" 3 "$FINISHED_BUSY_TOKEN" 2>/dev/null || true
    fi
    exit 0
  fi
fi

if [[ -f "$PAUSED_FILE" && ! -f "$COMPLETE_FILE" ]]; then
  # Leave the paused marker for the wrapper so it can distinguish a
  # bounded/manual-intervention exit from successful phase completion.
  rm -f "$HANDOFF_MODE_FILE"
  exit 0
fi

# Read phase configuration from .config file when env vars are not inherited.
# dx.sh writes this file before launching Claude for phases 1-6. Format:
# "phase_number:promise_string:audit_file_path:min_audits"
# Env vars take priority (belt-and-suspenders with file-based activation).
# IMPORTANT: This block MUST run before the .active file defaults below,
# because .active defaults set prompt-loop mode which would shadow the
# correct phase values from .config.
MIN_AUDIT_ITERATIONS="${DEX_LOOP_MIN_AUDITS:-1}"
CONFIG_FILE=$(dx_loop_config_file "$SESSION_ID")
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
      DEX_LOOP_PHASE="$CONFIG_PHASE"
      DEX_LOOP_PROMISE="$CONFIG_PROMISE"
    else
      DEX_LOOP_PHASE="${DEX_LOOP_PHASE:-$CONFIG_PHASE}"
      DEX_LOOP_PROMISE="${DEX_LOOP_PROMISE:-$CONFIG_PROMISE}"
    fi
    # Use config min_audits if no env override
    [[ "$CONFIG_MIN_AUDITS" =~ ^[0-9]+$ ]] && MIN_AUDIT_ITERATIONS="${DEX_LOOP_MIN_AUDITS:-$CONFIG_MIN_AUDITS}"
    if { [[ "$HANDOFF_MODE" == "inline" ]] || [[ -z "${DEX_LOOP_PROMPT:-}" ]]; } && [[ -n "$CONFIG_AUDIT_FILE" ]] && [[ -f "$CONFIG_AUDIT_FILE" ]]; then
      DEX_LOOP_PROMPT=$(cat "$CONFIG_AUDIT_FILE")
    fi
  fi
fi

# If activated via .active file only (in-session /dxloop with no .config file),
# default to prompt-loop mode. The .active file is a touch file — it doesn't
# carry data. When a .config file exists (dx phase workflow), the values above
# take precedence.
if [[ -f "$ACTIVE_FILE" ]]; then
  DEX_LOOP_PHASE="${DEX_LOOP_PHASE:-prompt-loop}"
  DEX_LOOP_PROMISE="${DEX_LOOP_PROMISE:-PROMPT_COMPLETE}"
fi

dx_sync_inline_phase_from_state

STATE_FILE=$(dx_loop_file "$SESSION_ID")
dx_record_session_branch "$SESSION_ID" "$(pwd)" 2>/dev/null || true
# 30 iterations is tuned for medium-sized features; reduce for simple bugs (10-15).
# Each iteration = one audit cycle, so 30 is a safety net, not an expected count.
MAX_ITERATIONS_RAW="${DEX_LOOP_MAX_ITERATIONS:-30}"
if ! MAX_ITERATIONS=$(dx_normalize_numeric_limit "$MAX_ITERATIONS_RAW"); then
  dx_report_invalid_numeric_limit "DEX_LOOP_MAX_ITERATIONS" "$MAX_ITERATIONS_RAW"
  exit 2
fi
MIN_AUDIT_ITERATIONS_RAW="$MIN_AUDIT_ITERATIONS"
if ! MIN_AUDIT_ITERATIONS=$(dx_normalize_numeric_limit "$MIN_AUDIT_ITERATIONS_RAW"); then
  dx_report_invalid_numeric_limit "DEX_LOOP_MIN_AUDITS" "$MIN_AUDIT_ITERATIONS_RAW"
  exit 2
fi
COMPLETION_PROMISE="${DEX_LOOP_PROMISE:-DEX_TICKET_COMPLETE}"

# Phase 6 has a wall-clock watch window between outcome checks. The agent writes
# dx_complete_state_file as "cycle:last_check_epoch"; hold the Stop hook quietly
# until that window matures so the audit loop does not spin and consume tokens.
if [[ "${DEX_LOOP_PHASE:-}" == "6" && ! -f "$COMPLETE_FILE" ]]; then
  COMPLETE_STATE_FILE=$(dx_complete_state_file "$SESSION_ID")
  if [[ -f "$COMPLETE_STATE_FILE" ]]; then
    COMPLETE_STATE_RAW=$(cat "$COMPLETE_STATE_FILE" 2>/dev/null || echo "")
    if [[ "$COMPLETE_STATE_RAW" =~ ^([0-9]+):([0-9]+)$ ]]; then
      COMPLETE_CYCLE="${BASH_REMATCH[1]}"
      COMPLETE_LAST_EPOCH="${BASH_REMATCH[2]}"
      COMPLETE_WAIT_MINUTES_RAW="${DEX_COMPLETE_WAIT_MINUTES:-5}"
      if ! COMPLETE_WAIT_MINUTES=$(dx_normalize_numeric_limit "$COMPLETE_WAIT_MINUTES_RAW"); then
        dx_report_invalid_numeric_limit "DEX_COMPLETE_WAIT_MINUTES" "$COMPLETE_WAIT_MINUTES_RAW"
        exit 2
      fi
      COMPLETE_WAIT_SECONDS=$((COMPLETE_WAIT_MINUTES * 60))
      if [[ "$COMPLETE_WAIT_SECONDS" -gt 0 ]]; then
        NOW_EPOCH=$(date +%s)
        COMPLETE_ELAPSED=$((NOW_EPOCH - COMPLETE_LAST_EPOCH))
        [[ "$COMPLETE_ELAPSED" -lt 0 ]] && COMPLETE_ELAPSED=0
        COMPLETE_REMAINING=$((COMPLETE_WAIT_SECONDS - COMPLETE_ELAPSED))
        if [[ "$COMPLETE_REMAINING" -gt 0 ]]; then
          printf '\n%s\n\n' "--- Dex Phase 6 wait window: cycle ${COMPLETE_CYCLE}, sleeping $(dx_format_duration "$COMPLETE_REMAINING") before next outcome check ---" >&2
          while [[ "$COMPLETE_REMAINING" -gt 0 ]]; do
            [[ -f "$PAUSED_FILE" || -f "$COMPLETE_FILE" ]] && break
            if [[ "$COMPLETE_REMAINING" -gt 30 ]]; then
              sleep 30
            else
              sleep "$COMPLETE_REMAINING"
            fi
            NOW_EPOCH=$(date +%s)
            COMPLETE_ELAPSED=$((NOW_EPOCH - COMPLETE_LAST_EPOCH))
            [[ "$COMPLETE_ELAPSED" -lt 0 ]] && COMPLETE_ELAPSED=0
            COMPLETE_REMAINING=$((COMPLETE_WAIT_SECONDS - COMPLETE_ELAPSED))
          done
        fi
      fi
    fi
  fi
fi

# Phase 0 has an external readiness gate: the agent must explicitly mark setup
# done (after renaming the branch, pushing, and updating tracker status). Block
# the stop until the ready marker exists so an early "I'm done" cannot skip
# bootstrap. Mirrors Phase 1/Phase 2 gates below.
if [[ "$HANDOFF_MODE" == "inline" && "${DEX_LOOP_PHASE:-}" == "0" ]]; then
  PHASE_READY_FILE=$(dx_phase_ready_file "$SESSION_ID" 0)
  if [[ ! -f "$PHASE_READY_FILE" ]]; then
    rm -f "$COMPLETE_FILE" "$STATE_FILE"
    printf '\n%s\n\n' "--- Dex Phase 0 Gate: ticket setup required ---" >&2
    printf '%s\n' "No audit iteration was counted and no completion signal is available yet." >&2
    printf '%s\n' "" >&2
    printf '%s\n' "Phase 0 owns ticket bootstrap. Before you can advance to planning, all of these must be true:" >&2
    printf '%s\n' "- Ticket fetched from the configured tracker (skip if none is configured)." >&2
    printf '%s\n' "- Assignee set to the authenticated user (skip if already assigned to you; STOP and warn if assigned to someone else)." >&2
    printf '%s\n' "- Lifecycle branch renamed to the tracker's git branch name and pushed (no draft PR yet — Phase 5 owns that)." >&2
    printf '%s\n' "- Ticket status moved to In Progress." >&2
    printf '%s\n' "- Description / acceptance criteria drafted (only if the ticket was empty or unclear)." >&2
    printf '%s\n' "" >&2
    printf '%s\n' "When all of the above is done, write the Phase 0 ready marker and stop once:" >&2
    printf '%s\n' '```bash' >&2
    printf '%s\n' "source \"\${DEX_DIR:-\$HOME/work/dex}/lib/common.sh\" || exit 1" >&2
    printf '%s\n' "touch \"\$(dx_phase_ready_file \"\${DEX_SESSION_ID:-\$(dx_session_id)}\" 0)\"" >&2
    printf '%s\n' '```' >&2
    printf '%s\n' "" >&2
    exit 2
  fi
fi

# Phase 1 has an external approval gate: the plan must be presented through
# ExitPlanMode and explicitly approved by the user before the audit loop should
# count iterations or reveal the completion signal. This keeps ordinary
# planning waits from burning the max-iteration budget.
if [[ "$HANDOFF_MODE" == "inline" && "${DEX_LOOP_PHASE:-}" == "1" ]]; then
  PHASE_STARTED_FILE=$(dx_phase_started_file "$SESSION_ID" 1)
  PHASE_READY_FILE=$(dx_phase_ready_file "$SESSION_ID" 1)
  if [[ ! -f "$PHASE_READY_FILE" ]]; then
    rm -f "$COMPLETE_FILE" "$STATE_FILE"
    if [[ ! -f "$PHASE_STARTED_FILE" ]]; then
      printf '\n%s\n\n' "--- Dex Phase 1 Gate: dxplan required ---" >&2
      printf '%s\n' "No audit iteration was counted and no completion signal is available yet." >&2
      printf '%s\n' "" >&2
      printf '%s\n' "Mandatory next step: invoke the dxplan skill now (Skill tool with skill: \"dxplan\", or /dxplan if slash skills are the available interface)." >&2
      printf '%s\n' "Do not manually fetch the ticket, rename branches, update tracker status, explore code, or draft the plan outside that skill unless the skill explicitly instructs you to." >&2
    else
      printf '\n%s\n\n' "--- Dex Phase 1 Gate: dxplan still in progress ---" >&2
      printf '%s\n' "No audit iteration was counted. Continue dxplan until ExitPlanMode has presented the plan and the user has approved it." >&2
      printf '%s\n' "After approval only, complete the freeform tracker intake gate when it applies, write the ready marker from dxplan Step 9, then stop once for the audit handoff." >&2
    fi
    printf '%s\n' "" >&2
    exit 2
  fi
  REVIEW_CRITERIA_FILE=$(dx_review_criteria_file "$SESSION_ID")
  REVIEW_CRITERIA_APPROVAL_FILE=$(dx_review_criteria_approval_file "$SESSION_ID")
  if dx_review_criteria_valid "$REVIEW_CRITERIA_FILE" && [[ ! -e "$REVIEW_CRITERIA_APPROVAL_FILE" ]]; then
    REVIEW_CRITERIA_HASH=$(dx_review_criteria_hash "$REVIEW_CRITERIA_FILE" 2>/dev/null || true)
    if [[ "$REVIEW_CRITERIA_HASH" =~ ^[a-f0-9]{64}$ ]]; then
      dx_review_approve_criteria "$SESSION_ID" initial "$REVIEW_CRITERIA_HASH" >/dev/null || true
    fi
  fi
  REVIEW_CRITERIA_BINDING=$(dx_review_read_criteria_approval "$SESSION_ID" 2>/dev/null || true)
  if [[ ! "$REVIEW_CRITERIA_BINDING" =~ ^[a-f0-9]{64}$ ]]; then
    rm -f "$COMPLETE_FILE" "$STATE_FILE"
    printf '\n%s\n\n' "--- Dex Phase 1 Gate: approved review criteria missing, invalid, or unsealed ---" >&2
    printf '%s\n' "No audit iteration was counted and Phase 1 did not advance." >&2
    printf '%s\n' "" >&2
    printf '%s\n' "After plan approval, export the approved objectives, acceptance criteria, and verification requirements to:" >&2
    printf '  %s\n' "$REVIEW_CRITERIA_FILE" >&2
    printf '%s\n' "Use the version 1 schema documented in dxplan Step 9 and validate it. The Phase 1 transition seals its approved hash before advancing." >&2
    printf '%s\n' "Do not use placeholders, summaries that omit requirements, or unapproved additions." >&2
    printf '%s\n' "" >&2
    exit 2
  fi
fi

if [[ "$HANDOFF_MODE" == "inline" && "${DEX_LOOP_PHASE:-}" == "3" ]]; then
  PHASE_BUSY_FILE=$(dx_phase_busy_file "$SESSION_ID" 3)
  if [[ -f "$PHASE_BUSY_FILE" && ! -f "$COMPLETE_FILE" ]]; then
    PHASE_BUSY_NOTICE_FILE=$(dx_phase_busy_notice_file "$SESSION_ID" 3)
    if dx_phase_busy_quiesced "$SESSION_ID" 3; then
      BUSY_TOKEN=$(dx_phase_busy_token "$SESSION_ID" 3)
      dx_phase_busy_finish "$SESSION_ID" 3 "$BUSY_TOKEN" 2>/dev/null || true
      printf '\n%s\n\n' "--- Dex Phase 3 Gate: review child quiesced ---" >&2
      printf '%s\n' "The matching review owner acknowledged that its child ended. Continue dxreviewloop with the returned result before stopping again." >&2
      exit 2
    fi
    BUSY_RAW=$(cat "$PHASE_BUSY_FILE" 2>/dev/null || echo "")
    BUSY_EPOCH="$BUSY_RAW"
    BUSY_LABEL=""
    if [[ "$BUSY_RAW" == *$'\t'* ]]; then
      BUSY_EPOCH="${BUSY_RAW%%$'\t'*}"
      BUSY_REST="${BUSY_RAW#*$'\t'}"
      BUSY_TOKEN_FIELD="${BUSY_REST%%$'\t'*}"
      if [[ "$BUSY_TOKEN_FIELD" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]]; then
        BUSY_REST="${BUSY_REST#*$'\t'}"
        BUSY_REST="${BUSY_REST#*$'\t'}"
      fi
      BUSY_LABEL="$BUSY_REST"
    fi
    [[ "$BUSY_EPOCH" =~ ^[0-9]+$ ]] || BUSY_EPOCH=$(date +%s)
    BUSY_AGE=$(( $(date +%s) - BUSY_EPOCH ))
    BUSY_TIMEOUT_RAW="${DEX_REVIEW_PASS_TIMEOUT:-900}"
    if ! BUSY_TIMEOUT=$(dx_normalize_numeric_limit "$BUSY_TIMEOUT_RAW"); then
      dx_report_invalid_numeric_limit "DEX_REVIEW_PASS_TIMEOUT" "$BUSY_TIMEOUT_RAW"
      exit 2
    fi

    if [[ "$BUSY_TIMEOUT" -gt 0 && "$BUSY_AGE" -gt "$BUSY_TIMEOUT" ]]; then
      rm -f "$ACTIVE_FILE" "$CONFIG_FILE" "$PHASE_BUSY_NOTICE_FILE"
      dx_phase_busy_request_cancel "$SESSION_ID" 3 2>/dev/null || true
      dx_record_phase_result "3" "pass_timeout" "89"
      dx_event_emit_for_session "$SESSION_ID" "run.blocked" "warn" "Dex lifecycle paused: review pass timeout" "3" "{\"reason\":\"pass_timeout\",\"age_s\":${BUSY_AGE},\"timeout_s\":${BUSY_TIMEOUT}}"
      dx_run_log_append_for_session "$SESSION_ID" "warn" "phase-loop" "Lifecycle paused: review pass timeout after ${BUSY_AGE}s"
      dx_run_write_summary_for_session "$SESSION_ID" "blocked" "Review pass timeout in Phase 3"
      dx_write_pause_state "$SESSION_ID" "review-pass-timeout" "phase-loop" 2>/dev/null || true
      touch "$PAUSED_FILE"
      printf '\n%s\n\n' "--- Dex phase paused: review pass timeout reached ($(dx_format_duration "$BUSY_AGE")/$(dx_format_duration "$BUSY_TIMEOUT")) ---" >&2
      printf '%s\n' "Do not advance to the next phase. Summarize the in-flight review pass, current clean-pass count, and whether the user wants to retry, reduce review depth, or continue with documented risk." >&2
      exit 2
    fi

    rm -f "$STATE_FILE"

    BUSY_NOTICE_INTERVAL_RAW="${DEX_REVIEW_PASS_NOTICE_INTERVAL:-120}"
    if ! BUSY_NOTICE_INTERVAL=$(dx_normalize_numeric_limit "$BUSY_NOTICE_INTERVAL_RAW"); then
      dx_report_invalid_numeric_limit "DEX_REVIEW_PASS_NOTICE_INTERVAL" "$BUSY_NOTICE_INTERVAL_RAW"
      exit 2
    fi
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
      BUSY_RECHECK_SECONDS_RAW="${DEX_REVIEW_PASS_RECHECK_SECONDS:-45}"
      if ! BUSY_RECHECK_SECONDS=$(dx_normalize_numeric_limit "$BUSY_RECHECK_SECONDS_RAW"); then
        dx_report_invalid_numeric_limit "DEX_REVIEW_PASS_RECHECK_SECONDS" "$BUSY_RECHECK_SECONDS_RAW"
        exit 2
      fi
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
        printf '\n%s\n\n' "--- Dex Phase 3 Gate: review pass finished ---" >&2
        printf '%s\n' "The busy marker cleared while the Stop hook was waiting. Continue dxreviewloop with the returned review result before stopping again." >&2
        exit 2
      fi

      BUSY_AGE=$(( $(date +%s) - BUSY_EPOCH ))
      if [[ -n "$BUSY_LABEL" && "$BUSY_LABEL" != "$BUSY_RAW" ]]; then
        printf '\n--- Dex Phase 3 Gate: still waiting on %s (%s/%s timeout) ---\n\n' "$BUSY_LABEL" "$(dx_format_duration "$BUSY_AGE")" "$(dx_format_duration "$BUSY_TIMEOUT")" >&2
      else
        printf '\n--- Dex Phase 3 Gate: review pass still running (%s/%s timeout) ---\n\n' "$(dx_format_duration "$BUSY_AGE")" "$(dx_format_duration "$BUSY_TIMEOUT")" >&2
      fi
    fi

    if [[ $SHOULD_PRINT_BUSY_NOTICE -eq 1 ]]; then
      BUSY_NOTICE_TMP="${PHASE_BUSY_NOTICE_FILE}.tmp.$$"
      if ! printf '%s\t%s\n' "$(date +%s)" "$BUSY_LABEL" > "$BUSY_NOTICE_TMP" || ! command mv -f "$BUSY_NOTICE_TMP" "$PHASE_BUSY_NOTICE_FILE"; then
        command rm -f "$BUSY_NOTICE_TMP" 2>/dev/null
      fi

      printf '\n%s\n\n' "--- Dex Phase 3 Gate: review pass in progress ---" >&2
      printf '%s\n' "No audit iteration was counted and no completion signal is available while dxreviewloop is waiting on a review pass." >&2
      if [[ -n "$BUSY_LABEL" && "$BUSY_LABEL" != "$BUSY_RAW" ]]; then
        printf '%s\n' "" >&2
        printf 'Current review work: %s\n' "$BUSY_LABEL" >&2
      fi
      printf '%s\n' "" >&2
      printf 'This wait-state notice is throttled to once every %s unless the review pass changes or times out.\n' "$(dx_format_duration "$BUSY_NOTICE_INTERVAL")" >&2
      printf 'Continue waiting for the current review pass. If this exceeds %s, Dex will pause Phase 3 for intervention. Commit, push, and PR actions remain available, but do not start a later lifecycle phase while this review child can still edit files.\n' "$(dx_format_duration "$BUSY_TIMEOUT")" >&2
    fi
    exit 2
  fi
fi

# Completion detection: The .complete file is the sole mechanism.
# This hook normally provides the .complete file path and promise string to Claude
# after MIN_AUDIT_ITERATIONS passes. The dxreviewloop per-pass wrapper may provide
# the pass completion path up front; the review-pass gate below requires a valid
# review result before accepting it.
# See: docs/autonomous-mode.md § Completion Signals
if [[ -f "$COMPLETE_FILE" ]]; then
  CURRENT_PHASE="${DEX_LOOP_PHASE:-0}"

  if [[ "${DEX_REVIEW_PASS_ACTIVE:-}" == "1" ]]; then
    REVIEW_RESULT_FILE=$(dx_review_result_file "$SESSION_ID")
    REVIEW_CONTEXT_FILE=$(dx_review_context_file "$SESSION_ID")
    REVIEW_CRITERIA_FILE=$(dx_review_criteria_file "$SESSION_ID")
    REVIEW_CRITERIA_BINDING="${DEX_REVIEW_CRITERIA_BINDING:-standalone}"
    REVIEW_POLICY_BINDING="${DEX_REVIEW_POLICY_BINDING:-}"
    REVIEW_PASS_ID="${DEX_REVIEW_PASS_ID:-}"
    REVIEW_PASS_BINDING="${DEX_REVIEW_PASS_BINDING:-}"
    REVIEW_EVIDENCE_FILE=$(dx_review_evidence_file "$SESSION_ID")
    REVIEW_FINDINGS_FILE=$(dx_findings_file "$SESSION_ID")
    REVIEW_RESULT=$(cat "$REVIEW_RESULT_FILE" 2>/dev/null || true)
    if ! dx_review_result_valid "$REVIEW_RESULT"; then
      rm -f "$COMPLETE_FILE"
      printf '\n%s\n\n' "--- Dex Review Pass Gate: result signal missing or invalid ---" >&2
      printf '%s\n' "Completion signal ignored; this review-wave pass must write an allowed result before it can exit." >&2
      printf '%s\n' "" >&2
      printf '%s\n' "Write exactly one of these values to the review result file, then touch the completion file again:" >&2
      printf '%s\n' '```bash' >&2
      printf '%s\n' "source \"\${DEX_DIR:-\$HOME/work/dex}/lib/common.sh\" || exit 1" >&2
      printf '%s\n' "SESSION_ID=\"\${DEX_SESSION_ID:-\$(dx_session_id)}\"" >&2
      printf '%s\n' "printf '%s\n' '<CLEAN|FINDINGS_FIXED:N|FINDINGS:N|BLOCKED:reason|CHURN:reason|ESCALATE:normal:reason|ESCALATE:complex:reason>' > \"\$(dx_review_result_file \"\$SESSION_ID\")\"" >&2
      printf '%s\n' "touch \"\$(dx_complete_file \"\$SESSION_ID\")\"" >&2
      printf '%s\n' '```' >&2
      printf '%s\n' "" >&2
      exit 2
    fi
    if [[ "$REVIEW_CRITERIA_BINDING" == "standalone" ]]; then
      REVIEW_CRITERIA_VALID=1
      [[ -e "$REVIEW_CRITERIA_FILE" ]] && REVIEW_CRITERIA_VALID=0
    else
      REVIEW_CRITERIA_VALID=0
      if [[ "$REVIEW_CRITERIA_BINDING" =~ ^[a-f0-9]{64}$ ]] &&
         [[ "${DEX_REVIEW_CRITERIA_FILE:-}" == "$REVIEW_CRITERIA_FILE" ]] &&
         [[ "$(dx_review_criteria_hash "$REVIEW_CRITERIA_FILE" 2>/dev/null)" == "$REVIEW_CRITERIA_BINDING" ]]; then
        REVIEW_CRITERIA_VALID=1
      fi
    fi
    if [[ $REVIEW_CRITERIA_VALID -ne 1 ]]; then
      rm -f "$COMPLETE_FILE"
      printf '\n%s\n\n' "--- Dex Review Pass Gate: approved criteria missing or changed ---" >&2
      printf '%s\n' "Completion signal ignored; this pass must use the immutable criteria copy supplied by dxreviewloop." >&2
      printf '%s\n' "Do not recreate or reinterpret the artifact. Return control to dxreviewloop so it can pause safely." >&2
      printf '%s\n' "" >&2
      exit 2
    fi
    REVIEW_POLICY_RECORD=$(dx_review_policy_resolve "$(pwd)" 2>/dev/null || true)
    IFS=$'\t' read -r _ _ _ CURRENT_REVIEW_POLICY_BINDING _ <<< "$REVIEW_POLICY_RECORD"
    EXPECTED_REVIEW_PASS_BINDING=$(dx_review_pass_binding "$REVIEW_PASS_ID" \
      "${DEX_REVIEW_SCOPE_FINGERPRINT:-}" "$REVIEW_CRITERIA_BINDING" "$REVIEW_POLICY_BINDING" 2>/dev/null || true)
    if [[ -z "$CURRENT_REVIEW_POLICY_BINDING" || "$REVIEW_POLICY_BINDING" != "$CURRENT_REVIEW_POLICY_BINDING" || \
          -z "$EXPECTED_REVIEW_PASS_BINDING" || "$REVIEW_PASS_BINDING" != "$EXPECTED_REVIEW_PASS_BINDING" ]]; then
      rm -f "$COMPLETE_FILE"
      printf '\n%s\n\n' "--- Dex Review Pass Gate: policy or pass binding missing or stale ---" >&2
      printf '%s\n' "Completion signal ignored; return control to dxreviewloop so it can restart this pass with current trusted bindings." >&2
      printf '%s\n' "" >&2
      exit 2
    fi
    if ! dx_review_context_valid "$REVIEW_CONTEXT_FILE" "$REVIEW_CRITERIA_BINDING"; then
      rm -f "$COMPLETE_FILE"
      printf '\n%s\n\n' "--- Dex Review Pass Gate: context pack missing or empty ---" >&2
      printf '%s\n' "Completion signal ignored; this review-wave pass must write a non-empty context pack before it can exit." >&2
      printf '%s\n' "Context pack: ${REVIEW_CONTEXT_FILE}" >&2
      printf '%s\n' "Write the review scope, exact criteria binding, checks, coverage, and verified findings to that file, then touch the completion file again." >&2
      printf '%s\n' "" >&2
      exit 2
    fi
    if ! dx_review_evidence_valid "$REVIEW_EVIDENCE_FILE" "$REVIEW_RESULT" "${DEX_REVIEW_PROFILE:-}" \
      "${DEX_REVIEW_SCOPE_FINGERPRINT:-}" "$REVIEW_CRITERIA_BINDING" "$REVIEW_CRITERIA_FILE" \
      "$REVIEW_PASS_ID" "$REVIEW_POLICY_BINDING" "$REVIEW_CONTEXT_FILE"; then
      rm -f "$COMPLETE_FILE"
      printf '\n%s\n\n' "--- Dex Review Pass Gate: evidence manifest missing or invalid ---" >&2
      printf '%s\n' "Completion signal ignored; this pass must write valid versioned evidence for its result, profile, and scope fingerprint." >&2
      printf '%s\n' "Evidence manifest: ${REVIEW_EVIDENCE_FILE}" >&2
      printf '%s\n' "Follow prompts/review-wave.md, replace the manifest, then touch the completion file again." >&2
      printf '%s\n' "" >&2
      exit 2
    fi
    if ! dx_review_findings_hash_valid "$REVIEW_FINDINGS_FILE"; then
      rm -f "$COMPLETE_FILE"
      printf '\n%s\n\n' "--- Dex Review Pass Gate: findings hash missing or invalid ---" >&2
      printf '%s\n' "Completion signal ignored; this review-wave pass must write exactly one lowercase 16-character findings hash before it can exit." >&2
      printf '%s\n' "Findings hash file: ${REVIEW_FINDINGS_FILE}" >&2
      printf '%s\n' "Replace that file with one SHA-256 prefix for the final verified finding inventory, then touch the completion file again." >&2
      printf '%s\n' "" >&2
      exit 2
    fi
  fi

  if [[ "$CURRENT_PHASE" == "3" && "${DEX_REVIEW_PASS_ACTIVE:-}" != "1" ]]; then
    REVIEW_CRITERIA_FILE=$(dx_review_criteria_file "$SESSION_ID")
    REVIEW_CRITERIA_BINDING=$(dx_review_read_criteria_approval "$SESSION_ID" 2>/dev/null || true)
    REVIEW_POLICY_RECORD=$(dx_review_policy_resolve "$(pwd)" 2>/dev/null || true)
    IFS=$'\t' read -r _ _ _ REVIEW_POLICY_BINDING _ <<< "$REVIEW_POLICY_RECORD"
    if [[ ! "$REVIEW_CRITERIA_BINDING" =~ ^[a-f0-9]{64}$ ]] ||
       ! dx_review_policy_binding_valid "$REVIEW_POLICY_BINDING" ||
       ! dx_review_receipt_valid "$SESSION_ID" "$(pwd)" "$REVIEW_CRITERIA_BINDING" "$REVIEW_POLICY_BINDING"; then
      rm -f "$COMPLETE_FILE"
      printf '\n%s\n\n' "--- Dex Phase 3 Gate: review receipt missing or stale ---" >&2
      printf '%s\n' "Completion signal ignored; Phase 3 did not advance." >&2
      printf '%s\n' "" >&2
      printf '%s\n' "Run /dxreviewloop on the current checkout until it reaches the required clean-pass gate. The review loop writes the receipt only after that gate succeeds." >&2
      printf '%s\n' "Do not create or edit the receipt manually. After /dxreviewloop succeeds, follow the normal completion instructions and stop again." >&2
      printf '%s\n' "" >&2
      exit 2
    fi
  fi

  if [[ "$HANDOFF_MODE" == "inline" && "$CURRENT_PHASE" == "2" ]]; then
    PHASE_READY_FILE=$(dx_phase_ready_file "$SESSION_ID" 2)
    if [[ ! -f "$PHASE_READY_FILE" ]]; then
      rm -f "$COMPLETE_FILE"
      printf '\n%s\n\n' "--- Dex Phase 2 Gate: implementation readiness marker missing ---" >&2
      printf '%s\n' "Completion signal ignored; Phase 2 did not advance." >&2
      printf '%s\n' "" >&2
      printf '%s\n' "Before writing the Phase 2 ready marker, confirm every approved task and acceptance criterion is exactly MET, with no DEFERRED/SKIPPED/N/A entries unless the user explicitly approved a plan change." >&2
      printf '%s\n' "All required verification, flake gates, and UI capture evidence must be complete locally. Do not rely on future CI as a substitute for a required Phase 2 check." >&2
      printf '%s\n' "No Phase 2 background processes or long-running verification commands may still be in flight." >&2
      printf '%s\n' "" >&2
      printf '%s\n' "If all of that is true, write the ready marker, then stop again for the completion signal:" >&2
      printf '%s\n' '```bash' >&2
      printf '%s\n' "source \"\${DEX_DIR:-\$HOME/work/dex}/lib/common.sh\" || exit 1" >&2
      printf '%s\n' "touch \"\$(dx_phase_ready_file \"\${DEX_SESSION_ID:-\$(dx_session_id)}\" 2)\"" >&2
      printf '%s\n' '```' >&2
      printf '%s\n' "" >&2
      exit 2
    fi
    REVIEW_CRITERIA_FILE=$(dx_review_criteria_file "$SESSION_ID")
    REVIEW_CRITERIA_BINDING=$(dx_review_read_criteria_approval "$SESSION_ID" 2>/dev/null || true)
    if [[ ! "$REVIEW_CRITERIA_BINDING" =~ ^[a-f0-9]{64}$ ]]; then
      rm -f "$COMPLETE_FILE"
      printf '\n%s\n\n' "--- Dex Phase 2 Gate: approved review criteria missing, invalid, or changed after approval ---" >&2
      printf '%s\n' "Completion signal ignored; Phase 2 did not advance." >&2
      printf '%s\n' "" >&2
      printf '%s\n' "Restore the approved Phase 1 requirements at:" >&2
      printf '  %s\n' "$REVIEW_CRITERIA_FILE" >&2
      printf '%s\n' "Use the version 1 schema from dxplan Step 9. If the user approved a plan change during implementation, replace the artifact and explicitly rotate its approval with dx_review_approve_criteria before continuing." >&2
      printf '%s\n' "" >&2
      exit 2
    fi
    REVIEW_POLICY_RECORD=$(dx_review_policy_resolve "$(pwd)" 2>/dev/null || true)
    IFS=$'\t' read -r _ _ _ REVIEW_POLICY_BINDING _ <<< "$REVIEW_POLICY_RECORD"
    if [[ ! "$REVIEW_CRITERIA_BINDING" =~ ^[a-f0-9]{64}$ ]] ||
       ! dx_review_policy_binding_valid "$REVIEW_POLICY_BINDING" ||
       ! dx_review_selection_valid "$SESSION_ID" "$(pwd)" "$REVIEW_CRITERIA_BINDING" "$REVIEW_POLICY_BINDING"; then
      rm -f "$COMPLETE_FILE"
      printf '\n%s\n\n' "--- Dex Phase 2 Gate: review risk selection missing or stale ---" >&2
      printf '%s\n' "Completion signal ignored; Phase 2 did not advance." >&2
      printf '%s\n' "" >&2
      printf '%s\n' "Choose the review risk tier for the implementation you just completed: small, normal, or complex. Use the ordered rubric in prompts/review-risk-assessment.md and persist comma-separated reason codes." >&2
      printf '%s\n' "" >&2
      printf '%s\n' "Record the current-scope choice, then stop again:" >&2
      printf '%s\n' '```bash' >&2
      printf '%s\n' "source \"\${DEX_DIR:-\$HOME/work/dex}/lib/common.sh\" || exit 1" >&2
      printf '%s\n' "SESSION_ID=\"\${DEX_SESSION_ID:-\$(dx_session_id)}\"" >&2
      printf '%s\n' "dx_review_write_selection \"\$SESSION_ID\" \"<small|normal|complex>\" \"lifecycle-agent\" \"<comma-separated-reason-codes>\" \"\$PWD\"" >&2
      printf '%s\n' '```' >&2
      printf '%s\n' "" >&2
      exit 2
    fi
  fi

  if [[ "$HANDOFF_MODE" == "inline" && "$CURRENT_PHASE" =~ ^[0-6]$ ]]; then
    if ! dx_lifecycle_control_lock_acquire "$SESSION_ID"; then
      printf '\n%s\n' "Dex is already applying lifecycle state; stop again after it finishes." >&2
      exit 2
    fi
    LATE_CONTROL_SNAPSHOT=$(dx_lifecycle_control_snapshot_unlocked "$SESSION_ID")
    if [[ -n "$LATE_CONTROL_SNAPSHOT" ]]; then
      LATE_CONTROL_ACTION=$(dx_lifecycle_control_value "$LATE_CONTROL_SNAPSHOT" action)
      if [[ "$LATE_CONTROL_ACTION" == "pause" || "$LATE_CONTROL_ACTION" == "cancel" ]]; then
        dx_write_pause_state "$SESSION_ID" "manual-${LATE_CONTROL_ACTION}" \
          "$(dx_lifecycle_control_value "$LATE_CONTROL_SNAPSHOT" source)" 2>/dev/null || true
        [[ -f "$(dx_phase_busy_file "$SESSION_ID" 3)" ]] && dx_phase_busy_request_cancel "$SESSION_ID" 3 2>/dev/null || true
        touch "$PAUSED_FILE"
        rm -f "$ACTIVE_FILE" "$COMPLETE_FILE" "$(dx_loop_file "$SESSION_ID")" 2>/dev/null || true
        dx_lifecycle_control_lock_release "$SESSION_ID" || true
        printf '{"continue":false,"stopReason":"Dex lifecycle paused by direct human instruction."}\n'
        exit 0
      fi
      dx_lifecycle_control_lock_release "$SESSION_ID" || true
      printf '\n%s\n' "A direct human lifecycle transition arrived before phase completion committed. Stop again to apply it." >&2
      exit 2
    fi
  fi

  if [[ "$HANDOFF_MODE" == "inline" && "$CURRENT_PHASE" =~ ^[0-9]+$ && "$CURRENT_PHASE" -lt 6 ]]; then
    NEXT_PHASE=$((CURRENT_PHASE + 1))
    if dx_phase_busy_transition_blocked "$SESSION_ID" 3 "$CURRENT_PHASE" "$NEXT_PHASE"; then
      dx_write_pause_state "$SESSION_ID" "review-child-active" "phase-loop" 2>/dev/null || true
      dx_phase_busy_request_cancel "$SESSION_ID" 3 2>/dev/null || true
      touch "$PAUSED_FILE"
      rm -f "$ACTIVE_FILE" "$COMPLETE_FILE" "$(dx_loop_file "$SESSION_ID")" 2>/dev/null || true
      dx_lifecycle_control_lock_release "$SESSION_ID" || true
      printf '\n%s\n' "Dex paused before crossing Phase 3 because its review child has not acknowledged quiescence." >&2
      exit 0
    fi

    if ! dx_consume_completion_receipt "$SESSION_ID"; then
      dx_lifecycle_control_lock_release "$SESSION_ID" || true
      printf '\n%s\n' "Dex could not consume the Phase ${CURRENT_PHASE} completion receipt. Stop again after correcting the state-file error." >&2
      exit 2
    fi

    NEXT_CONFIG="${NEXT_PHASE}:$(dx_phase_promise "$NEXT_PHASE"):$(dx_phase_audit_file "$NEXT_PHASE"):$(dx_phase_min_audits "$NEXT_PHASE")"
    if ! dx_lifecycle_atomic_write "$CONFIG_FILE" "$NEXT_CONFIG" \
      || ! dx_lifecycle_atomic_write "$PHASE_STATE_FILE" "$NEXT_PHASE"; then
      dx_lifecycle_control_lock_release "$SESSION_ID" || true
      printf '\n%s\n' "Dex could not commit the phase handoff. The current phase remains authoritative and its consumed completion receipt cannot affect the next phase; stop again to retry its audit." >&2
      exit 2
    fi

    dx_record_phase_result "$CURRENT_PHASE" "advance" "0"
    if [[ "$CURRENT_PHASE" == "3" ]]; then
      rm -f "$(dx_review_selection_file "$SESSION_ID")" "$(dx_review_receipt_file "$SESSION_ID")" \
        "$(dx_review_state_file "$SESSION_ID")" 2>/dev/null
      dx_review_ledger_reset "$SESSION_ID" 2>/dev/null || true
      if dx_phase_busy_quiesced "$SESSION_ID" 3; then
        PHASE_3_BUSY_TOKEN=$(dx_phase_busy_token "$SESSION_ID" 3)
        dx_phase_busy_finish "$SESSION_ID" 3 "$PHASE_3_BUSY_TOKEN" 2>/dev/null || true
      fi
    fi
    rm -f "$STATE_FILE" "$COMPLETE_FILE" "$(dx_findings_file "$SESSION_ID")" "$PAUSED_FILE" \
      "$(dx_pause_state_file "$SESSION_ID")" "$(dx_phase_started_file "$SESSION_ID" "$CURRENT_PHASE")" \
      "$(dx_phase_ready_file "$SESSION_ID" "$CURRENT_PHASE")" 2>/dev/null || true
    if [[ "$CURRENT_PHASE" != "3" ]]; then
      rm -f "$(dx_phase_busy_file "$SESSION_ID" "$CURRENT_PHASE")" \
        "$(dx_phase_busy_notice_file "$SESSION_ID" "$CURRENT_PHASE")" 2>/dev/null || true
    fi

    # Preserve phase checkpoints at same-session phase boundaries.
    if [[ "$NEXT_PHASE" -ge 2 ]] && git rev-parse --git-dir >/dev/null 2>&1; then
      dx_checkpoint_tag "$NEXT_PHASE" "$(pwd)"
    fi

    dx_start_phase_timer "$NEXT_PHASE"

    touch "$ACTIVE_FILE"
    dx_lifecycle_control_lock_release "$SESSION_ID" || true

    {
      printf '\n%s\n\n' "--- Dex Phase Handoff: Phase ${CURRENT_PHASE} complete → Phase ${NEXT_PHASE} ($(dx_phase_name "$NEXT_PHASE")) ---"
      printf '%s\n\n' "Continue in this same Claude session. Do not ask the user whether to proceed."
      dx_inline_phase_message "$NEXT_PHASE"
      printf '\n%s\n' "When Phase ${NEXT_PHASE} is genuinely complete, stop so the Stop hook can audit it."
    } >&2
    exit 2
  fi

  if [[ "$HANDOFF_MODE" == "inline" && "$CURRENT_PHASE" == "6" ]]; then
    if ! dx_consume_completion_receipt "$SESSION_ID"; then
      dx_lifecycle_control_lock_release "$SESSION_ID" || true
      printf '\n%s\n' "Dex could not consume the Phase 6 completion receipt. Stop again after correcting the state-file error." >&2
      exit 2
    fi
    if ! dx_lifecycle_atomic_write "$CONFIG_FILE" "7:::0" \
      || ! dx_lifecycle_atomic_write "$PHASE_STATE_FILE" "7"; then
      dx_lifecycle_control_lock_release "$SESSION_ID" || true
      printf '\n%s\n' "Dex could not commit lifecycle completion. Phase 6 remains authoritative; stop again to retry its audit." >&2
      exit 2
    fi
    dx_record_phase_result "$CURRENT_PHASE" "advance" "0"
    rm -f "$STATE_FILE" "$COMPLETE_FILE" "$CONFIG_FILE" "$(dx_findings_file "$SESSION_ID")" "$PAUSED_FILE" \
      "$(dx_pause_state_file "$SESSION_ID")" "$(dx_prompt_file "$SESSION_ID")" \
      "$(dx_phase_started_file "$SESSION_ID" "$CURRENT_PHASE")" \
      "$(dx_phase_ready_file "$SESSION_ID" "$CURRENT_PHASE")" \
      "$(dx_phase_busy_file "$SESSION_ID" "$CURRENT_PHASE")" \
      "$(dx_phase_busy_notice_file "$SESSION_ID" "$CURRENT_PHASE")" 2>/dev/null || true
    dx_event_emit_for_session "$SESSION_ID" "run.completed" "info" "Dex lifecycle completed" "6" "{\"final_phase\":6}"
    dx_run_log_append_for_session "$SESSION_ID" "info" "phase-loop" "Dex lifecycle completed"
    dx_run_write_summary_for_session "$SESSION_ID" "completed" "Dex lifecycle completed"
    rm -f "$ACTIVE_FILE" "$OWNER_FILE" "$HANDOFF_MODE_FILE" "$PAUSED_FILE"
    dx_lifecycle_control_lock_release "$SESSION_ID" || true
    {
      printf '\n%s\n\n' "--- Dex lifecycle complete ---"
      printf '%s\n' "All phases are complete. Present the final summary to the user, including PR status and any cleanup command."
    } >&2
    exit 2
  fi

  # Accepted review-wave passes leave both evidence files for the launching
  # wrapper. Invalid result/context/hash paths remove the completion marker
  # before reaching this branch, so a surviving marker is the durable
  # cross-provider acceptance receipt. The wrapper validates and removes all
  # pass-scoped state after the provider exits.
  if [[ "${DEX_REVIEW_PASS_ACTIVE:-}" == "1" ]]; then
    rm -f "$STATE_FILE" "$CONFIG_FILE" "$PAUSED_FILE" "$(dx_phase_started_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dx_phase_ready_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dx_phase_busy_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dx_phase_busy_notice_file "$SESSION_ID" "$CURRENT_PHASE")"
  else
    rm -f "$(dx_findings_file "$SESSION_ID")" "$STATE_FILE" "$COMPLETE_FILE" "$CONFIG_FILE" "$PAUSED_FILE" "$(dx_phase_started_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dx_phase_ready_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dx_phase_busy_file "$SESSION_ID" "$CURRENT_PHASE")" "$(dx_phase_busy_notice_file "$SESSION_ID" "$CURRENT_PHASE")"
  fi
  rm -f "$ACTIVE_FILE" "$OWNER_FILE" "$HANDOFF_MODE_FILE" "$PAUSED_FILE"
  printf '%s\n' '{"continue":false,"stopReason":"Dex loop complete."}'
  exit 0
fi

# Read current iteration count and timestamp.
# State file format: "iteration:epoch" or bare "iteration".
ITERATION=0
LAST_EPOCH=0
STALL_COUNT=0
if [[ -f "$STATE_FILE" ]]; then
  RAW=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
  if [[ "$RAW" =~ ^([0-9]+):([0-9]+):?([0-9]*)$ ]]; then
    # Timestamp format: iteration:epoch or iteration:epoch:stall_count
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
STALL_TIMEOUT_RAW="${DEX_LOOP_STALL_TIMEOUT:-300}"  # default: 5 minutes
if ! STALL_TIMEOUT=$(dx_normalize_numeric_limit "$STALL_TIMEOUT_RAW"); then
  dx_report_invalid_numeric_limit "DEX_LOOP_STALL_TIMEOUT" "$STALL_TIMEOUT_RAW"
  exit 2
fi
STALL_ESCALATE_AFTER_RAW="${DEX_LOOP_STALL_ESCALATE:-3}"  # escalate after N stalls
if ! STALL_ESCALATE_AFTER=$(dx_normalize_numeric_limit "$STALL_ESCALATE_AFTER_RAW"); then
  dx_report_invalid_numeric_limit "DEX_LOOP_STALL_ESCALATE" "$STALL_ESCALATE_AFTER_RAW"
  exit 2
fi
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
FINDINGS_FILE=$(dx_findings_file "$SESSION_ID")
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
    done < <(dx_reverse_file_lines "$FINDINGS_FILE" 2>/dev/null)
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
    CURRENT_PHASE="${DEX_LOOP_PHASE:-0}"
    dx_record_phase_result "$CURRENT_PHASE" "max-iter" "88"
    dx_event_emit_for_session "$SESSION_ID" "run.blocked" "warn" "Dex lifecycle paused: max audit iterations reached" "$CURRENT_PHASE" "{\"reason\":\"max-iter\",\"max_iterations\":${MAX_ITERATIONS}}"
    dx_run_log_append_for_session "$SESSION_ID" "warn" "phase-loop" "Lifecycle paused: max audit iterations reached (${MAX_ITERATIONS})"
    dx_run_write_summary_for_session "$SESSION_ID" "blocked" "Max audit iterations reached in Phase ${CURRENT_PHASE}"
    dx_write_pause_state "$SESSION_ID" "max-iterations" "phase-loop" 2>/dev/null || true
    touch "$PAUSED_FILE"
    printf '\n%s\n\n' "--- Dex phase paused: max audit iterations reached (${MAX_ITERATIONS}) ---" >&2
    printf '%s\n' "Do not advance to the next phase. Summarize the blocker, current phase, and the exact user decision or intervention needed." >&2
    exit 2
  fi
  printf '{"continue":false,"stopReason":"Dex audit loop reached max iterations (%s). Inspect the pause and resume when ready."}\n' "$MAX_ITERATIONS"
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
#   1. DEX_LOOP_PROMPT env var — set by dx.sh wrapper per-phase (preloaded from file)
#   2. Phase audit file from prompts/phase-audits/<name>.md — looked up via DEX_LOOP_PHASE
#      (used by in-session activations like /dxloop where the env var isn't set)
#   3. Generic fallback — hardcoded prompt below, used when neither source is available
AUDIT_PROMPT="${DEX_LOOP_PROMPT:-}"
AUDIT_SOURCE_FILE="${CONFIG_AUDIT_FILE:-}"

if [[ -z "$AUDIT_PROMPT" ]]; then
  LOOP_PHASE="${DEX_LOOP_PHASE:-}"
  # Map phase number to audit file basename (must match actual filenames)
  AUDIT_FILENAME=""
  case "$LOOP_PHASE" in
    0) AUDIT_FILENAME="0-setup" ;;
    1) AUDIT_FILENAME="1-plan" ;;
    2) AUDIT_FILENAME="2-implement" ;;
    3) AUDIT_FILENAME="3-review-loop" ;;
    4) AUDIT_FILENAME="4-verify" ;;
    5) AUDIT_FILENAME="5-pr" ;;
    6) AUDIT_FILENAME="6-complete" ;;
    prompt-loop) AUDIT_FILENAME="prompt-loop" ;;
  esac
  AUDIT_FILE="$DEX_DIR/prompts/phase-audits/${AUDIT_FILENAME}.md"
  if [[ -n "$AUDIT_FILENAME" ]] && [[ -f "$AUDIT_FILE" ]]; then
    AUDIT_SOURCE_FILE="$AUDIT_FILE"
    AUDIT_PROMPT=$(cat "$AUDIT_FILE")
  fi
fi

if [[ -z "$AUDIT_SOURCE_FILE" ]]; then
  AUDIT_SOURCE_FILE=$(dx_phase_audit_file "${DEX_LOOP_PHASE:-}" 2>/dev/null || true)
fi

if [[ -z "$AUDIT_PROMPT" ]]; then
  AUDIT_PROMPT="You are not done yet. Review your work critically before stopping:

1. Is the current phase fully complete?
2. Are there any issues, improvements, or optimizations remaining?
3. Have you verified the quality of your output?

If something needs work, fix it and try again."
fi

echo "" >&2
if [[ "${DEX_LOOP_PHASE:-}" == "prompt-loop" ]]; then
  echo "--- Prompt Loop: iteration $ITERATION/$MAX_ITERATIONS ---" >&2
else
  echo "--- Phase Audit: iteration $ITERATION/$MAX_ITERATIONS ---" >&2
fi
echo "" >&2

# Re-inject the original prompt so Claude doesn't lose it after context compaction.
# The prompt file is written by dxloop in dx.sh before launching Claude.
PROMPT_FILE=$(dx_prompt_file "$SESSION_ID")
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
  printf '%s\n' "You appear to be stuck in a loop. The last $STALL_COUNT iterations each took longer than $(dx_format_duration "$STALL_TIMEOUT") without making progress." >&2
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

if [[ $ITERATION -gt 1 ]] && dx_compact_repeat_audit_prompt "${DEX_LOOP_PHASE:-}" "$AUDIT_SOURCE_FILE" >&2; then
  :
else
  printf '%s\n' "$AUDIT_PROMPT" >&2
fi
echo "" >&2

# Completion gate — only provide completion instructions after enough audit iterations.
# Before the threshold: Claude can't complete (doesn't know how to write .complete).
# After the threshold: Claude receives the .complete file path and promise string.
# COMPLETE_FILE was already set above for the early-exit check.
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

#!/usr/bin/env bash
# Research harness — Claude execution capture
# Wraps claude -p invocations with output routing, timeout, and exit code capture.

# shellcheck source=research/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# _inject_workspace_context <workspace_dir>
# Create a CLAUDE.md in the workspace with guardrails and implementation guidance.
# The workspace has its own .git root (from git init), so Claude won't see the
# parent repo's files. This function bridges that gap.
_inject_workspace_context() {
  local ws="$1"
  local guardrails_file="$DOYAKEN_DIR/prompts/guardrails.md"
  local implement_skill="$DOYAKEN_DIR/skills/dkimplement/SKILL.md"

  # Extract the non-interactive mode guidance from dkimplement
  local noninteractive_guidance=""
  if [[ -f "$implement_skill" ]]; then
    noninteractive_guidance=$(awk '/\*\*When running non-interactively\*\*/{found=1} found{if(/^When stopping for scope/)exit; print}' "$implement_skill")
  fi

  cat > "$ws/CLAUDE.md" <<CLAUDEMD
# Implementation Guidelines

You are building production-quality code. Follow these guardrails strictly.

## Handling Ambiguity

${noninteractive_guidance:-Choose the most comprehensive reasonable interpretation. For algorithmic choices, implement at least two approaches. Default to per-client isolation with configurable limits. Include a README explaining design decisions.}

## Guardrails

$(cat "$guardrails_file" 2>/dev/null || echo "No guardrails file found.")
CLAUDEMD

  log_info "Injected CLAUDE.md into workspace"
}

# capture_run <scenario_name> <result_dir> [--lifecycle]
# Execute Claude against a scenario's prompt in its workspace.
# Captures: stream.jsonl, stderr.log, exit code, timing.
capture_run() {
  local scenario="$1"
  local result_dir="$2"
  local mode="${3:-dkloop}"

  local ws
  ws=$(workspace_dir "$scenario")
  local scenario_dir
  scenario_dir=$(scenario_dir "$scenario")

  # Read the prompt
  local prompt_file="$scenario_dir/prompt.md"
  if [[ ! -f "$prompt_file" ]]; then
    log_error "No prompt.md found for scenario: $scenario"
    return 1
  fi
  local prompt
  prompt=$(cat "$prompt_file")

  # Read scenario config for timeout override
  local timeout="$SCENARIO_TIMEOUT"
  if [[ -f "$scenario_dir/scenario.json" ]]; then
    local custom_timeout
    custom_timeout=$(json_field "$scenario_dir/scenario.json" "timeout")
    [[ -n "$custom_timeout" && "$custom_timeout" != "0" ]] && timeout="$custom_timeout"
  fi

  mkdir -p "$result_dir"

  local start_epoch
  start_epoch=$(date +%s)

  log_step "Executing scenario: $scenario (timeout: ${timeout}s)"

  local exit_code=0

  if [[ "$mode" == "--lifecycle" ]]; then
    _capture_lifecycle "$scenario" "$ws" "$result_dir" "$prompt" "$timeout" || exit_code=$?
  else
    _capture_dkloop "$scenario" "$ws" "$result_dir" "$prompt" "$timeout" || exit_code=$?
  fi

  local end_epoch
  end_epoch=$(date +%s)
  local duration=$((end_epoch - start_epoch))

  # Write timing info
  json_write "$result_dir/timing.json" "{
    \"scenario\": \"$scenario\",
    \"start_epoch\": $start_epoch,
    \"end_epoch\": $end_epoch,
    \"duration_s\": $duration,
    \"exit_code\": $exit_code,
    \"timeout_s\": $timeout,
    \"mode\": \"$mode\"
  }"

  # Write files changed
  workspace_files_changed "$scenario" > "$result_dir/files-changed.txt" 2>/dev/null || true

  if [[ $exit_code -eq 0 ]]; then
    log_success "Scenario $scenario completed in ${duration}s"
  else
    log_warn "Scenario $scenario exited with code $exit_code in ${duration}s"
  fi

  return $exit_code
}

# ── Internal execution modes ───────────────────────────────────────────────

# Default mode: single claude -p invocation, similar to dkloop behavior.
# The prompt includes instructions to plan, implement, verify, and self-review.
_capture_dkloop() {
  local scenario="$1" ws="$2" result_dir="$3" prompt="$4" timeout="$5"

  # Inject guardrails into workspace as CLAUDE.md so Claude auto-reads them.
  # Without this, the workspace's own .git root isolates it from the parent repo's
  # guardrails.md, skill files, and AGENTS.md — making DK prompt improvements invisible.
  _inject_workspace_context "$ws"

  # Build the full prompt with DK skill instructions
  local full_prompt
  full_prompt="You are working in an empty project directory. Your task:

${prompt}

Instructions:
1. Read the CLAUDE.md in this directory — it contains implementation guardrails you must follow.
2. Plan your approach first — think about the structure, files needed, and edge cases.
3. Implement the solution — write all code, tests, and configuration files.
4. Verify your work — run the tests, check for lint errors, review your own code.
5. Fix any issues you find — iterate until everything works correctly.
6. Do a final self-review: check for edge cases, error handling, input validation, and code quality.

Work autonomously. Create all files from scratch. Do not ask questions — make reasonable assumptions for anything unspecified."

  # Generate unique session ID for this run
  local session_id
  session_id="research-${scenario}-$(date +%s)-$$"

  # Ensure DK state dirs exist for the stop hook
  local state_dir="${WORKSPACES_DIR}/.state"
  local loop_dir="${WORKSPACES_DIR}/.loops"
  mkdir -p "$state_dir" "$loop_dir"

  local claude_exit=0

  # Run Claude in the workspace directory
  (cd "$ws" && \
    DOYAKEN_DIR="$DOYAKEN_DIR" \
    DOYAKEN_SESSION_ID="$session_id" \
    DK_STATE_DIR="$state_dir" \
    DK_LOOP_DIR="$loop_dir" \
    timeout "${timeout}s" \
    claude -p \
      --model "$CLAUDE_MODEL" \
      "$CLAUDE_BYPASS_FLAG" \
      --permission-mode "$CLAUDE_PERMISSION_MODE" \
      --effort "$CLAUDE_EFFORT" \
      --output-format stream-json \
      --verbose \
      "$full_prompt" \
    >"$result_dir/stream.jsonl" 2>"$result_dir/stderr.log") || claude_exit=$?

  # Clean up state files
  rm -f "$loop_dir/$session_id".* "$state_dir/$session_id".* 2>/dev/null

  return $claude_exit
}

# Lifecycle mode: separate plan and implement sessions.
_capture_lifecycle() {
  local scenario="$1" ws="$2" result_dir="$3" prompt="$4" timeout="$5"

  _inject_workspace_context "$ws"

  local session_id
  session_id="research-lifecycle-${scenario}-$(date +%s)-$$"
  local state_dir="${WORKSPACES_DIR}/.state"
  local loop_dir="${WORKSPACES_DIR}/.loops"
  mkdir -p "$state_dir" "$loop_dir"

  local half_timeout=$((timeout / 2))

  # Phase 1: Plan
  log_info "Phase 1: Planning"
  local plan_exit=0
  (cd "$ws" && \
    DOYAKEN_DIR="$DOYAKEN_DIR" \
    DOYAKEN_SESSION_ID="$session_id" \
    DK_STATE_DIR="$state_dir" \
    DK_LOOP_DIR="$loop_dir" \
    timeout "${half_timeout}s" \
    claude -p \
      --model "$CLAUDE_MODEL" \
      "$CLAUDE_BYPASS_FLAG" \
      --permission-mode "$CLAUDE_PERMISSION_MODE" \
      --effort "$CLAUDE_EFFORT" \
      --output-format stream-json \
      --verbose \
      "You are working in an empty project directory. Plan the implementation for this task, then create a detailed step-by-step plan. Do NOT implement yet — only plan.

${prompt}" \
    >"$result_dir/plan-stream.jsonl" 2>"$result_dir/plan-stderr.log") || plan_exit=$?

  if [[ $plan_exit -ne 0 && $plan_exit -ne 124 ]]; then
    log_warn "Plan phase failed with exit $plan_exit"
  fi

  # Phase 2: Implement + Verify
  log_info "Phase 2: Implement + Verify"
  local audit_prompt=""
  local audit_file="$DOYAKEN_DIR/prompts/phase-audits/prompt-loop.md"
  [[ -f "$audit_file" ]] && audit_prompt=$(cat "$audit_file")

  local impl_exit=0
  (cd "$ws" && \
    DOYAKEN_DIR="$DOYAKEN_DIR" \
    DOYAKEN_SESSION_ID="$session_id" \
    DOYAKEN_LOOP_ACTIVE=1 \
    DOYAKEN_LOOP_PROMISE="PROMPT_COMPLETE" \
    DOYAKEN_LOOP_PHASE="prompt-loop" \
    DOYAKEN_LOOP_MAX_ITERATIONS="$MAX_LOOP_ITERATIONS" \
    DOYAKEN_LOOP_PROMPT="$audit_prompt" \
    DK_STATE_DIR="$state_dir" \
    DK_LOOP_DIR="$loop_dir" \
    timeout "${half_timeout}s" \
    claude -p \
      --model "$CLAUDE_MODEL" \
      "$CLAUDE_BYPASS_FLAG" \
      --permission-mode "$CLAUDE_PERMISSION_MODE" \
      --effort "$CLAUDE_EFFORT" \
      --output-format stream-json \
      --verbose \
      "Implement the following task. Write all code, tests, and configuration. Verify everything works. Fix any issues.

${prompt}" \
    >"$result_dir/impl-stream.jsonl" 2>"$result_dir/impl-stderr.log") || impl_exit=$?

  # Merge streams for scoring
  cat "$result_dir/plan-stream.jsonl" "$result_dir/impl-stream.jsonl" > "$result_dir/stream.jsonl" 2>/dev/null || true
  cat "$result_dir/plan-stderr.log" "$result_dir/impl-stderr.log" > "$result_dir/stderr.log" 2>/dev/null || true

  # Clean up state files
  rm -f "$loop_dir/$session_id".* "$state_dir/$session_id".* 2>/dev/null

  return $impl_exit
}

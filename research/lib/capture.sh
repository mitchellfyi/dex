#!/usr/bin/env bash
# Research harness — agent execution capture
# Wraps Claude/Codex invocations with output routing, timeout, and exit code capture.

# shellcheck source=research/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# _inject_workspace_context <workspace_dir> <runner>
# Create the agent context file with guardrails and implementation guidance.
# The workspace has its own .git root (from git init), so the agent won't see the
# parent repo's files. This function bridges that gap.
_inject_workspace_context() {
  local ws="$1"
  local runner="${2:-claude}"
  local guardrails_file="$DEX_DIR/prompts/guardrails.md"
  local implement_skill="$DEX_DIR/skills/dximplement/SKILL.md"
  local context_file="CLAUDE.md"
  [[ "$runner" == "codex" ]] && context_file="AGENTS.md"

  # Extract the non-interactive mode guidance from dximplement
  local noninteractive_guidance=""
  if [[ -f "$implement_skill" ]]; then
    noninteractive_guidance=$(awk '/\*\*When running non-interactively\*\*/{found=1} found{if(/^When stopping for scope/)exit; print}' "$implement_skill")
  fi

  cat > "$ws/$context_file" <<CLAUDEMD
# Implementation Guidelines

You are building production-quality code. Follow these guardrails strictly.

## Handling Ambiguity

${noninteractive_guidance:-Choose the most comprehensive reasonable interpretation. For algorithmic choices, implement at least two approaches. Default to per-client isolation with configurable limits. Include a README explaining design decisions.}

## Guardrails

$(cat "$guardrails_file" 2>/dev/null || echo "No guardrails file found.")
CLAUDEMD

  log_info "Injected $context_file into workspace"
}

_runner_model_label() {
  case "$1" in
    codex) printf '%s\n' "codex-provider" ;;
    *) printf '%s\n' "$CLAUDE_MODEL" ;;
  esac
}

_context_file_for_runner() {
  case "$1" in
    codex) printf '%s\n' "AGENTS.md" ;;
    *) printf '%s\n' "CLAUDE.md" ;;
  esac
}

_build_dxloop_prompt() {
  local prompt="$1" context_file="$2"
  cat <<EOF
You are working in an empty project directory. Your task:

${prompt}

Instructions:
1. Read the ${context_file} in this directory — it contains implementation guardrails you must follow.
2. Plan your approach first — think about the structure, files needed, and edge cases.
3. Implement the solution — write all code, tests, and configuration files.
4. Verify your work — run the tests, check for lint errors, review your own code.
5. Fix any issues you find — iterate until everything works correctly.
6. Do a final self-review: check for edge cases, error handling, input validation, and code quality.

Work autonomously. Create all files from scratch. Do not ask questions — make reasonable assumptions for anything unspecified.
EOF
}

# capture_run <scenario_name> <result_dir> [--lifecycle] [runner]
# Execute a scenario prompt in its workspace.
# Captures: stream.jsonl, stderr.log, exit code, timing.
capture_run() {
  local scenario="$1"
  local result_dir="$2"
  local mode="${3:-dxloop}"
  local runner="${4:-${RESEARCH_RUNNER:-claude}}"

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

  # Resolve scenario timeout. Priority (highest first):
  #   1. SCENARIO_TIMEOUT_OVERRIDE — global force (set by `--scenario-timeout`)
  #   2. scenario.json "timeout"   — per-scenario value (non-zero)
  #   3. SCENARIO_TIMEOUT          — global default from config.sh
  local timeout="$SCENARIO_TIMEOUT"
  if [[ -f "$scenario_dir/scenario.json" ]]; then
    local custom_timeout
    custom_timeout=$(json_field "$scenario_dir/scenario.json" "timeout")
    [[ -n "$custom_timeout" && "$custom_timeout" != "0" ]] && timeout="$custom_timeout"
  fi
  [[ -n "${SCENARIO_TIMEOUT_OVERRIDE:-}" ]] && timeout="$SCENARIO_TIMEOUT_OVERRIDE"

  mkdir -p "$result_dir"

  local start_epoch
  start_epoch=$(date +%s)

  case "$runner" in
    claude|codex) ;;
    *)
      log_error "Unknown runner: $runner"
      return 1
      ;;
  esac

  log_step "Executing scenario: $scenario (runner: $runner, timeout: ${timeout}s)"

  local exit_code=0

  case "$runner:$mode" in
    claude:--lifecycle)
      _capture_lifecycle "$scenario" "$ws" "$result_dir" "$prompt" "$timeout" || exit_code=$?
      ;;
    codex:--lifecycle)
      _capture_codex_lifecycle "$scenario" "$ws" "$result_dir" "$prompt" "$timeout" || exit_code=$?
      ;;
    claude:*)
      _capture_dxloop "$scenario" "$ws" "$result_dir" "$prompt" "$timeout" || exit_code=$?
      ;;
    codex:*)
      _capture_codex_dxloop "$scenario" "$ws" "$result_dir" "$prompt" "$timeout" || exit_code=$?
      ;;
  esac

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
    \"runner\": \"$runner\",
    \"model\": \"$(_runner_model_label "$runner")\",
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

# Default mode: single claude -p invocation, similar to dxloop behavior.
# The prompt includes instructions to plan, implement, verify, and self-review.
_capture_dxloop() {
  local scenario="$1" ws="$2" result_dir="$3" prompt="$4" timeout="$5"

  # Inject guardrails into workspace as CLAUDE.md so Claude auto-reads them.
  # Without this, the workspace's own .git root isolates it from the parent repo's
  # guardrails.md, skill files, and AGENTS.md — making DX prompt improvements invisible.
  _inject_workspace_context "$ws" "claude"

  # Build the full prompt with DX skill instructions
  local full_prompt
  full_prompt=$(_build_dxloop_prompt "$prompt" "$(_context_file_for_runner claude)")

  # Generate unique session ID for this run
  local session_id
  session_id="research-${scenario}-$(date +%s)-$$"

  # Ensure DX state dirs exist for the stop hook
  local state_dir="${WORKSPACES_DIR}/.state"
  local loop_dir="${WORKSPACES_DIR}/.loops"
  mkdir -p "$state_dir" "$loop_dir"

  local claude_exit=0

  # Run Claude in the workspace directory
  (cd "$ws" && \
    DEX_DIR="$DEX_DIR" \
    DEX_SESSION_ID="$session_id" \
    DX_STATE_DIR="$state_dir" \
    DX_LOOP_DIR="$loop_dir" \
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

  _inject_workspace_context "$ws" "claude"

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
    DEX_DIR="$DEX_DIR" \
    DEX_SESSION_ID="$session_id" \
    DX_STATE_DIR="$state_dir" \
    DX_LOOP_DIR="$loop_dir" \
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
  local audit_file="$DEX_DIR/prompts/phase-audits/prompt-loop.md"
  [[ -f "$audit_file" ]] && audit_prompt=$(cat "$audit_file")

  local impl_exit=0
  (cd "$ws" && \
    DEX_DIR="$DEX_DIR" \
    DEX_SESSION_ID="$session_id" \
    DEX_LOOP_ACTIVE=1 \
    DEX_LOOP_PROMISE="PROMPT_COMPLETE" \
    DEX_LOOP_PHASE="prompt-loop" \
    DEX_LOOP_MAX_ITERATIONS="$MAX_LOOP_ITERATIONS" \
    DEX_LOOP_PROMPT="$audit_prompt" \
    DX_STATE_DIR="$state_dir" \
    DX_LOOP_DIR="$loop_dir" \
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

_capture_codex_exec() {
  local ws="$1" result_dir="$2" stream_name="$3" stderr_name="$4" last_name="$5" prompt="$6" timeout="$7"
  local codex_exit=0
  local profile="${DX_PROVIDER_PROFILE:-codex-subscription}"
  local dex_dir="$DEX_DIR"
  local codex_wrapper="$dex_dir/bin/dxcodex.sh"

  (cd "$ws" && \
    DEX_DIR="$dex_dir" \
    DX_PROVIDER_PROFILE="$profile" \
    DX_CODEX_JSON=1 \
    DX_CODEX_OUTPUT_LAST_MESSAGE="$result_dir/$last_name" \
    timeout "${timeout}s" \
    "$codex_wrapper" exec -- "$prompt" \
    >"$result_dir/$stream_name" 2>"$result_dir/$stderr_name") || codex_exit=$?

  return $codex_exit
}

_capture_codex_dxloop() {
  local scenario="$1" ws="$2" result_dir="$3" prompt="$4" timeout="$5"
  local context_file
  context_file=$(_context_file_for_runner codex)

  _inject_workspace_context "$ws" "codex"

  local full_prompt
  full_prompt=$(_build_dxloop_prompt "$prompt" "$context_file")

  _capture_codex_exec "$ws" "$result_dir" "stream.jsonl" "stderr.log" "last-message.txt" "$full_prompt" "$timeout"
}

_capture_codex_lifecycle() {
  local scenario="$1" ws="$2" result_dir="$3" prompt="$4" timeout="$5"
  local context_file
  context_file=$(_context_file_for_runner codex)

  _inject_workspace_context "$ws" "codex"

  local half_timeout=$((timeout / 2))

  log_info "Phase 1: Planning"
  local plan_prompt
  plan_prompt="You are working in an empty project directory. Read ${context_file}, then plan the implementation for this task. Create a detailed step-by-step plan. Do NOT implement yet — only plan.

${prompt}"
  local plan_exit=0
  _capture_codex_exec "$ws" "$result_dir" "plan-stream.jsonl" "plan-stderr.log" "plan-last-message.txt" "$plan_prompt" "$half_timeout" || plan_exit=$?

  if [[ $plan_exit -ne 0 && $plan_exit -ne 124 ]]; then
    log_warn "Plan phase failed with exit $plan_exit"
  fi

  log_info "Phase 2: Implement + Verify"
  local impl_prompt
  impl_prompt="You are working in an empty project directory. Read ${context_file}, then implement the following task. Write all code, tests, and configuration. Verify everything works. Fix any issues.

${prompt}"
  local impl_exit=0
  _capture_codex_exec "$ws" "$result_dir" "impl-stream.jsonl" "impl-stderr.log" "impl-last-message.txt" "$impl_prompt" "$half_timeout" || impl_exit=$?

  cat "$result_dir/plan-stream.jsonl" "$result_dir/impl-stream.jsonl" > "$result_dir/stream.jsonl" 2>/dev/null || true
  cat "$result_dir/plan-stderr.log" "$result_dir/impl-stderr.log" > "$result_dir/stderr.log" 2>/dev/null || true

  return $impl_exit
}

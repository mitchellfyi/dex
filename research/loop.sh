#!/usr/bin/env bash
# Research harness — outer improvement loop
# Runs suite → analyzes failures → improves DX → validates → repeats.
#
# Usage:
#   ./research/loop.sh                          # Run until stopped
#   ./research/loop.sh --max-iterations 5       # Custom iteration limit
#   ./research/loop.sh --cost-limit 100         # Custom cost limit (USD)
#   ./research/loop.sh --scenario cli-todo-app  # Focus on one scenario
#   ./research/loop.sh --skip-llm-judge         # Faster runs without LLM scoring
#   ./research/loop.sh --runner codex           # Execute scenarios with Codex CLI
#   ./research/loop.sh --commit                 # Commit accepted changes
#   ./research/loop.sh --allow-main             # Intentionally run on main/master
#   ./research/loop.sh --objective legacy       # Judge changes by the old rubric
#
# By default (--objective outcomes) every suite is a research/compare run of
# the dex arm, and research/compare/objective.py decides keep or revert from
# hidden tests, fuzzing, the follow-up task, cost and code size. The old
# rubric rewarded test counts, file counts and edit counts, and tuning Dex's
# prompts against it made Dex write more without catching more bugs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=research/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=research/lib/safety.sh
source "$SCRIPT_DIR/lib/safety.sh"
# shellcheck source=research/lib/report.sh
source "$SCRIPT_DIR/lib/report.sh"

# ── Parse arguments ────────────────────────────────────────────────────────
MAX_ITER="$MAX_IMPROVE_ITERATIONS"
COST_LIMIT="$COST_LIMIT_USD"
SCENARIO_FLAG=""
SKIP_LLM_FLAG=""
RUN_FLAGS=()
ALLOW_MAIN=0
COMMIT_ACCEPTED=0
OBJECTIVE="outcomes"
COMPARE_REPLICAS=2
COMPARE_JOBS=3
COMPARE_FLAGS=()

require_value() {
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    log_error "$1 requires a value"
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-iterations)
      require_value "$1" "${2:-}"
      MAX_ITER="$2"
      shift 2
      ;;
    --cost-limit)
      require_value "$1" "${2:-}"
      COST_LIMIT="$2"
      shift 2
      ;;
    --scenario)
      require_value "$1" "${2:-}"
      SCENARIO_FLAG="$2"
      RUN_FLAGS+=(--scenario "$2")
      COMPARE_FLAGS+=(--scenario "$2")
      shift 2
      ;;
    --objective)
      require_value "$1" "${2:-}"
      OBJECTIVE="$2"
      shift 2
      ;;
    --replicas)
      require_value "$1" "${2:-}"
      COMPARE_REPLICAS="$2"
      shift 2
      ;;
    --jobs)
      require_value "$1" "${2:-}"
      COMPARE_JOBS="$2"
      shift 2
      ;;
    --skip-llm-judge)
      SKIP_LLM_FLAG="--skip-llm-judge"
      RUN_FLAGS+=("--skip-llm-judge")
      shift
      ;;
    --runner)
      require_value "$1" "${2:-}"
      RUN_FLAGS+=(--runner "$2")
      shift 2
      ;;
    --commit)
      COMMIT_ACCEPTED=1
      shift
      ;;
    --allow-main)
      ALLOW_MAIN=1
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--max-iterations N] [--cost-limit USD] [--scenario name] [--skip-llm-judge] [--runner claude|codex] [--objective outcomes|legacy] [--replicas N] [--jobs N] [--commit] [--allow-main]"
      echo ""
      echo "  --objective NAME     outcomes (default): research/compare runs judged by objective.py"
      echo "                       legacy: research/run.sh judged by the rubric aggregate"
      echo "  --replicas N         Replicas per scenario in outcomes mode (default 2)"
      echo "  --jobs N             Trials at once in outcomes mode (default 3)"
      echo "  --max-iterations N   Stop after N experiments (0 = run until stopped, default 0)"
      echo "  --cost-limit USD     Stop when estimated cost exceeds USD (0 = disabled, default 0)"
      echo "  --commit             Commit accepted improvements. By default, accepted changes remain unstaged."
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

case "$OBJECTIVE" in
  outcomes|legacy) ;;
  *) log_error "--objective must be outcomes or legacy"; exit 1 ;;
esac

# compare_suite <label> <with_scenario_flags:0|1> [extra run.sh args...] —
# run the dex arm through research/compare and print the run directory.
compare_suite() {
  local label="$1" with_flags="$2" out
  shift 2
  local -a flags=()
  if [[ "$with_flags" == 1 ]]; then
    flags=(${COMPARE_FLAGS[@]+"${COMPARE_FLAGS[@]}"})
  fi
  out=$(bash "$SCRIPT_DIR/compare/run.sh" --arms dex --no-judge \
    ${flags[@]+"${flags[@]}"} "$@" 2>&1 | tee -a "$RESULTS_DIR/loop-${label}.log" | tail -1)
  [[ "$out" == RUN_DIR=* ]] || return 1
  printf '%s\n' "${out#RUN_DIR=}"
}

if [[ $ALLOW_MAIN -eq 1 ]]; then
  export RESEARCH_ALLOW_MAIN=1
fi

# ── Safety checks ──────────────────────────────────────────────────────────
safety_check_branch
safety_check_clean

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DX AUTORESEARCH — Improvement Loop"
echo ""
echo "  Branch:         $(dx_branch)"
echo "  DX commit:      $(dx_commit_hash)"
echo "  Max iterations: ${MAX_ITER:-0} (0 = until stopped)"
echo "  Cost limit:     ${COST_LIMIT:-0} (0 = disabled)"
echo "  Scenario:       ${SCENARIO_FLAG:-all}"
echo "  Objective:      $OBJECTIVE"
echo "  Commit changes: $([[ $COMMIT_ACCEPTED -eq 1 ]] && echo yes || echo no)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Changelog ──────────────────────────────────────────────────────────────
CHANGELOG="$IMPROVEMENTS_DIR/changelog.md"
mkdir -p "$IMPROVEMENTS_DIR/applied"

_changelog() {
  echo "$@" >> "$CHANGELOG"
}

_changelog ""
_changelog "## Loop: $(date +%Y-%m-%d\ %H:%M:%S)"
_changelog "Branch: $(dx_branch) | Start commit: $(dx_commit_hash)"
_changelog ""

if [[ ! "$MAX_ITER" =~ ^[0-9]+$ ]]; then
  log_error "--max-iterations must be a non-negative integer"
  exit 1
fi

# ── Baseline run ───────────────────────────────────────────────────────────
log_step "Running baseline suite..."

if [[ "$OBJECTIVE" == outcomes ]]; then
  if ! BASELINE_DIR=$(compare_suite baseline 1 --replicas "$COMPARE_REPLICAS" --jobs "$COMPARE_JOBS"); then
    log_error "Baseline comparison run failed. See $RESULTS_DIR/loop-baseline.log"
    exit 1
  fi
  BASELINE_RUN_ID="$BASELINE_DIR"
  BASELINE_SCORE="(outcomes; see $BASELINE_DIR/report.md)"
else
  BASELINE_RUN_ID=$("$SCRIPT_DIR/run.sh" ${RUN_FLAGS[@]+"${RUN_FLAGS[@]}"} --iteration 0 2>&1 | tail -1) || true
  BASELINE_DIR="$RESULTS_DIR/$BASELINE_RUN_ID"

  if [[ -z "$BASELINE_RUN_ID" || ! -f "$BASELINE_DIR/summary.json" ]]; then
    log_error "Baseline run failed. Check results in $RESULTS_DIR"
    exit 1
  fi

  BASELINE_SCORE=$(json_field "$BASELINE_DIR/summary.json" "aggregate_score")
fi
log_success "Baseline score: $BASELINE_SCORE"
_changelog "### Baseline: $BASELINE_SCORE (${BASELINE_RUN_ID})"

PREV_SUMMARY="$BASELINE_DIR/summary.json"
PREV_RUN_ID="$BASELINE_RUN_ID"
CUMULATIVE_COST=0
ITERS_COMPLETED=0

# ── Improvement loop ──────────────────────────────────────────────────────
iter=0
while [[ "$MAX_ITER" -eq 0 || "$iter" -lt "$MAX_ITER" ]]; do
  iter=$((iter + 1))
  ITERS_COMPLETED=$iter
  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  if [[ "$MAX_ITER" -eq 0 ]]; then
    log_step "Iteration $iter / infinity"
  else
    log_step "Iteration $iter / $MAX_ITER"
  fi
  echo "════════════════════════════════════════════════════════════════════"
  echo ""

  # Tag checkpoint
  safety_tag_checkpoint "$iter"

  # ── Improve ────────────────────────────────────────────────────────────
  log_step "Analyzing failures and proposing improvements..."
  PATCH_FILE=""
  PATCH_FILE=$("$SCRIPT_DIR/improve.sh" "$PREV_RUN_ID" 2>&1 | tail -1) || true

  if [[ -z "$PATCH_FILE" || ! -f "$PATCH_FILE" ]]; then
    log_warn "No patch generated for iteration $iter. Skipping."
    _changelog "### Iteration $iter: SKIP (no patch generated)"
    continue
  fi

  # ── Apply ──────────────────────────────────────────────────────────────
  log_step "Applying patch..."
  if ! safety_apply_patch "$PATCH_FILE"; then
    log_warn "No patches applied. Skipping iteration."
    _changelog "### Iteration $iter: SKIP (patch failed to apply)"
    continue
  fi

  # Copy patch to applied/
  cp "$PATCH_FILE" "$IMPROVEMENTS_DIR/applied/$(basename "$PATCH_FILE")"
  log_info "Applied experimental changes; validating before accept/reject"

  if [[ "$OBJECTIVE" == outcomes ]]; then
    # ── Smoke test: one trial, no quality phase ──────────────────────────
    log_step "Running smoke test ($COMPARE_SMOKE_SCENARIO)..."
    SMOKE_DIR=$(compare_suite "smoke-$iter" 0 --scenario "$COMPARE_SMOKE_SCENARIO" --replicas 1 --no-quality) || SMOKE_DIR=""
    smoke_ok=0
    if [[ -n "$SMOKE_DIR" ]] && python3 "$SCRIPT_DIR/compare/objective.py" --smoke "$SMOKE_DIR"; then
      smoke_ok=1
    fi
    if [[ "$smoke_ok" != 1 ]]; then
      log_warn "Smoke test failed: no valid trial with a passing test suite. Reverting."
      safety_reverse_patch "$PATCH_FILE" || exit 1
      _changelog "### Iteration $iter: REVERT (smoke test failed: ${SMOKE_DIR:-no run})"
      continue
    fi

    # ── Full suite, judged on outcomes ───────────────────────────────────
    log_step "Running full comparison suite..."
    if ! CURR_DIR=$(compare_suite "iter-$iter" 1 --replicas "$COMPARE_REPLICAS" --jobs "$COMPARE_JOBS"); then
      log_warn "Suite run failed. Reverting."
      safety_reverse_patch "$PATCH_FILE" || exit 1
      _changelog "### Iteration $iter: REVERT (suite run failed)"
      continue
    fi
    verdict_status=0
    verdict=$(python3 "$SCRIPT_DIR/compare/objective.py" "$PREV_RUN_ID" "$CURR_DIR" 2>&1) || verdict_status=$?
    printf '%s\n' "$verdict"
    if [[ "$verdict_status" -ne 0 ]]; then
      log_warn "Outcome objective says revert. Reverting."
      safety_reverse_patch "$PATCH_FILE" || exit 1
      _changelog "### Iteration $iter: REVERT ($(printf '%s' "$verdict" | tail -1))"
      _changelog '```'
      _changelog "$verdict"
      _changelog '```'
      continue
    fi
    log_success "Improvement accepted: $(printf '%s' "$verdict" | tail -1)"
    _changelog "### Iteration $iter: KEEP ($(printf '%s' "$verdict" | tail -1))"
    _changelog '```'
    _changelog "$verdict"
    _changelog '```'
    if [[ $COMMIT_ACCEPTED -eq 1 ]]; then
      (cd "$DEX_DIR" && \
        git add -A && \
        git commit \
          -m "research: iteration $iter - improve DX based on outcome benchmark" \
          -m "Accepted generated research changes after smoke and outcome validation." \
          -m "Co-Authored-By: DX Autoresearch <noreply@dexcode.ai>" 2>/dev/null) || true
      log_info "Committed accepted changes"
    else
      log_info "Accepted changes remain unstaged for review"
    fi
    PREV_RUN_ID="$CURR_DIR"
    continue
  fi

  # ── Smoke test ─────────────────────────────────────────────────────────
  log_step "Running smoke test ($SMOKE_SCENARIO)..."
  SMOKE_RUN_ID=$("$SCRIPT_DIR/run.sh" --scenario "$SMOKE_SCENARIO" $SKIP_LLM_FLAG --iteration "$iter" 2>&1 | tail -1) || true
  SMOKE_DIR="$RESULTS_DIR/$SMOKE_RUN_ID"

  if [[ -f "$SMOKE_DIR/$SMOKE_SCENARIO/rubric-results.json" ]]; then
    SMOKE_SCORE=$(json_field "$SMOKE_DIR/$SMOKE_SCENARIO/rubric-results.json" "total")
    log_info "Smoke test score: $SMOKE_SCORE"

    # Check if smoke test regressed significantly
    if [[ $SMOKE_SCORE -lt 10 ]]; then
      log_warn "Smoke test score critically low ($SMOKE_SCORE). Reverting."
      safety_reverse_patch "$PATCH_FILE" || exit 1
      _changelog "### Iteration $iter: REVERT (smoke test score: $SMOKE_SCORE)"
      continue
    fi
  else
    log_warn "Smoke test produced no results. Continuing cautiously."
  fi

  # ── Full suite ─────────────────────────────────────────────────────────
  log_step "Running full suite..."
  CURR_RUN_ID=$("$SCRIPT_DIR/run.sh" ${RUN_FLAGS[@]+"${RUN_FLAGS[@]}"} --iteration "$iter" 2>&1 | tail -1) || true
  CURR_DIR="$RESULTS_DIR/$CURR_RUN_ID"

  if [[ -z "$CURR_RUN_ID" || ! -f "$CURR_DIR/summary.json" ]]; then
    log_warn "Suite run failed. Reverting."
    safety_reverse_patch "$PATCH_FILE" || exit 1
    _changelog "### Iteration $iter: REVERT (suite run failed)"
    continue
  fi

  CURR_SCORE=$(json_field "$CURR_DIR/summary.json" "aggregate_score")
  log_info "Current score: $CURR_SCORE (previous: $(json_field "$PREV_SUMMARY" "aggregate_score"))"

  # ── Check regression ───────────────────────────────────────────────────
  if ! safety_check_regression "$PREV_SUMMARY" "$CURR_DIR/summary.json" 2>&1; then
    log_warn "Regression detected. Reverting."
    safety_reverse_patch "$PATCH_FILE" || exit 1
    _changelog "### Iteration $iter: REVERT (regression — score: $CURR_SCORE)"
    continue
  fi

  # ── Accept improvement ─────────────────────────────────────────────────
  PREV_SCORE=$(json_field "$PREV_SUMMARY" "aggregate_score")
  DELTA=$(python3 -c "print(round($CURR_SCORE - $PREV_SCORE, 1))" 2>/dev/null || echo "0")

  log_success "Improvement accepted: $PREV_SCORE → $CURR_SCORE (Δ $DELTA)"
  report_comparison "$PREV_SUMMARY" "$CURR_DIR/summary.json"

  _changelog "### Iteration $iter: KEEP (score: $CURR_SCORE, Δ $DELTA)"
  _changelog "$(report_comparison "$PREV_SUMMARY" "$CURR_DIR/summary.json" 2>/dev/null || echo "")"
  _changelog ""

  if [[ $COMMIT_ACCEPTED -eq 1 ]]; then
    (cd "$DEX_DIR" && \
      git add -A && \
      git commit \
        -m "research: iteration $iter - improve DX based on harness results" \
        -m "Accepted generated research changes after smoke and full-suite validation." \
        -m "Co-Authored-By: DX Autoresearch <noreply@dexcode.ai>" 2>/dev/null) || true
    log_info "Committed accepted changes"
  else
    log_info "Accepted changes remain unstaged for review"
  fi

  PREV_SUMMARY="$CURR_DIR/summary.json"
  PREV_RUN_ID="$CURR_RUN_ID"

  # ── Cost check ─────────────────────────────────────────────────────────
  # TODO: parse actual cost from stream-json when available
  # For now, estimate based on iteration count
  CUMULATIVE_COST=$(python3 -c "print($iter * 15)" 2>/dev/null || echo "0")

  if ! safety_cost_check "$CUMULATIVE_COST" 2>&1; then
    log_warn "Cost limit reached. Stopping loop."
    _changelog "### Stopped: cost limit reached (\$$CUMULATIVE_COST)"
    break
  fi
done

# ── Final summary ──────────────────────────────────────────────────────────
FINAL_SCORE=$(json_field "$PREV_SUMMARY" "aggregate_score")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  IMPROVEMENT LOOP COMPLETE"
echo ""
echo "  Baseline score:  $BASELINE_SCORE"
echo "  Final score:     $FINAL_SCORE"
echo "  Total improvement: $(python3 -c "print(round($FINAL_SCORE - $BASELINE_SCORE, 1))" 2>/dev/null || echo "?")"
echo "  Iterations run:  $ITERS_COMPLETED"
echo "  DX commit:       $(dx_commit_hash)"
echo "  Branch:          $(dx_branch)"
echo ""
echo "  Changelog:       $CHANGELOG"
echo "  Scores history:  $SCORES_TSV"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

_changelog "### Final: $FINAL_SCORE (Δ $(python3 -c "print(round($FINAL_SCORE - $BASELINE_SCORE, 1))" 2>/dev/null || echo "?") from baseline)"
_changelog "---"

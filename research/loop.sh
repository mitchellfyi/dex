#!/usr/bin/env bash
# Research harness — outer improvement loop
# Runs suite → analyzes failures → improves DX → validates → repeats.
#
# Usage:
#   ./research/loop.sh                          # Default: 20 iterations
#   ./research/loop.sh --max-iterations 5       # Custom iteration limit
#   ./research/loop.sh --cost-limit 100         # Custom cost limit (USD)
#   ./research/loop.sh --scenario cli-todo-app  # Focus on one scenario
#   ./research/loop.sh --skip-llm-judge         # Faster runs without LLM scoring
#   ./research/loop.sh --runner codex           # Execute scenarios with Codex CLI
#   ./research/loop.sh --allow-main             # Intentionally run on main/master

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-iterations)
      MAX_ITER="$2"
      shift 2
      ;;
    --cost-limit)
      COST_LIMIT="$2"
      shift 2
      ;;
    --scenario)
      SCENARIO_FLAG="$2"
      RUN_FLAGS+=(--scenario "$2")
      shift 2
      ;;
    --skip-llm-judge)
      SKIP_LLM_FLAG="--skip-llm-judge"
      RUN_FLAGS+=("--skip-llm-judge")
      shift
      ;;
    --runner)
      RUN_FLAGS+=(--runner "$2")
      shift 2
      ;;
    --allow-main)
      ALLOW_MAIN=1
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--max-iterations N] [--cost-limit USD] [--scenario name] [--skip-llm-judge] [--runner claude|codex] [--allow-main]"
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

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
echo "  Max iterations: $MAX_ITER"
echo "  Cost limit:     \$$COST_LIMIT"
echo "  Scenario:       ${SCENARIO_FLAG:-all}"
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

# ── Baseline run ───────────────────────────────────────────────────────────
log_step "Running baseline suite..."

BASELINE_RUN_ID=$("$SCRIPT_DIR/run.sh" "${RUN_FLAGS[@]}" --iteration 0 2>&1 | tail -1)
BASELINE_DIR="$RESULTS_DIR/$BASELINE_RUN_ID"

if [[ ! -f "$BASELINE_DIR/summary.json" ]]; then
  log_error "Baseline run failed. Check results in $RESULTS_DIR"
  exit 1
fi

BASELINE_SCORE=$(json_field "$BASELINE_DIR/summary.json" "aggregate_score")
log_success "Baseline score: $BASELINE_SCORE"
_changelog "### Baseline: $BASELINE_SCORE (${BASELINE_RUN_ID})"

PREV_SUMMARY="$BASELINE_DIR/summary.json"
PREV_RUN_ID="$BASELINE_RUN_ID"
CUMULATIVE_COST=0
ITERS_COMPLETED=0

# ── Improvement loop ──────────────────────────────────────────────────────
for iter in $(seq 1 "$MAX_ITER"); do
  ITERS_COMPLETED=$iter
  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  log_step "Iteration $iter / $MAX_ITER"
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
  applied=0
  # Try individual patch parts first (avoids hunk offset issues)
  # Use `patch` instead of `git apply` for better fuzz/offset tolerance
  part_idx=0
  while [[ -f "${PATCH_FILE}.${part_idx}" ]]; do
    if (cd "$DEX_DIR" && patch -p1 --fuzz=3 --no-backup-if-mismatch < "${PATCH_FILE}.${part_idx}" 2>/dev/null); then
      applied=$((applied + 1))
    else
      log_warn "Patch part $part_idx failed to apply"
    fi
    part_idx=$((part_idx + 1))
  done

  # Fallback: try applying the combined patch if no parts exist
  if [[ $part_idx -eq 0 ]]; then
    if (cd "$DEX_DIR" && patch -p1 --fuzz=3 --no-backup-if-mismatch < "$PATCH_FILE" 2>/dev/null); then
      applied=1
    fi
  fi

  if [[ $applied -eq 0 ]]; then
    log_warn "No patches applied. Skipping iteration."
    _changelog "### Iteration $iter: SKIP (patch failed to apply)"
    continue
  fi

  log_info "Applied $applied patch part(s)"

  # Copy patch to applied/
  cp "$PATCH_FILE" "$IMPROVEMENTS_DIR/applied/$(basename "$PATCH_FILE")"
  log_info "Applied changes; validating before commit"

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
  CURR_RUN_ID=$("$SCRIPT_DIR/run.sh" "${RUN_FLAGS[@]}" --iteration "$iter" 2>&1 | tail -1)
  CURR_DIR="$RESULTS_DIR/$CURR_RUN_ID"

  if [[ ! -f "$CURR_DIR/summary.json" ]]; then
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

  (cd "$DEX_DIR" && \
    git add -A && \
    git commit \
      -m "research: iteration $iter - improve DX based on harness results" \
      -m "Accepted generated research changes after smoke and full-suite validation." \
      -m "Co-Authored-By: DX Autoresearch <noreply@dexcode.ai>" 2>/dev/null) || true

  log_info "Committed accepted changes"

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

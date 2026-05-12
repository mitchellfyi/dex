#!/usr/bin/env bash
# Research harness — suite runner
# Runs DK against scenarios, scores output, records results.
#
# Usage:
#   ./research/run.sh                          # Run all scenarios
#   ./research/run.sh --scenario cli-todo-app   # Run one scenario
#   ./research/run.sh --skip-llm-judge          # Skip LLM-judged scoring
#   ./research/run.sh --lifecycle               # Use multi-phase execution
#   ./research/run.sh --iteration 3             # Tag results with iteration number

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=research/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=research/lib/workspace.sh
source "$SCRIPT_DIR/lib/workspace.sh"
# shellcheck source=research/lib/capture.sh
source "$SCRIPT_DIR/lib/capture.sh"
# shellcheck source=research/lib/score.sh
source "$SCRIPT_DIR/lib/score.sh"
# shellcheck source=research/lib/report.sh
source "$SCRIPT_DIR/lib/report.sh"

# ── Parse arguments ────────────────────────────────────────────────────────
SCENARIO_FILTER=""
SKIP_LLM=""
EXEC_MODE="dkloop"
ITERATION="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      SCENARIO_FILTER="$2"
      shift 2
      ;;
    --skip-llm-judge)
      SKIP_LLM="--skip-llm-judge"
      shift
      ;;
    --lifecycle)
      EXEC_MODE="--lifecycle"
      shift
      ;;
    --iteration)
      ITERATION="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--scenario <name>] [--skip-llm-judge] [--lifecycle] [--iteration N]"
      echo ""
      echo "Options:"
      echo "  --scenario <name>   Run only this scenario"
      echo "  --skip-llm-judge    Skip LLM-judged code quality scoring"
      echo "  --lifecycle         Use multi-phase execution (plan then implement)"
      echo "  --iteration N       Tag results with iteration number (for loop.sh)"
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ── Setup ──────────────────────────────────────────────────────────────────
RUN_ID=$(run_id)
RUN_DIR=$(run_result_dir "$RUN_ID")
mkdir -p "$RUN_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DK AUTORESEARCH — Suite Run"
echo ""
echo "  Run ID:    $RUN_ID"
echo "  Iteration: $ITERATION"
echo "  DK commit: $(dk_commit_hash)"
echo "  Model:     $CLAUDE_MODEL"
echo "  Mode:      ${EXEC_MODE:-dkloop}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Discover scenarios ─────────────────────────────────────────────────────
SCENARIOS=()
if [[ -n "$SCENARIO_FILTER" ]]; then
  scenario_name_require_valid "$SCENARIO_FILTER" || exit 1
  if [[ ! -d "$SCENARIOS_DIR/$SCENARIO_FILTER" ]]; then
    log_error "Scenario not found: $SCENARIO_FILTER"
    exit 1
  fi
  SCENARIOS=("$SCENARIO_FILTER")
else
  while IFS= read -r s; do
    scenario_name_require_valid "$s" || exit 1
    SCENARIOS+=("$s")
  done < <(list_scenarios)
fi

if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
  log_error "No scenarios found"
  exit 1
fi

log_info "Running ${#SCENARIOS[@]} scenario(s): ${SCENARIOS[*]}"
echo ""

# ── Run each scenario ──────────────────────────────────────────────────────
TOTAL_SCORE=0
SCENARIO_COUNT=0
FAILED=()

for scenario in "${SCENARIOS[@]}"; do
  echo "────────────────────────────────────────────────────────────────────"
  log_step "[$((SCENARIO_COUNT + 1))/${#SCENARIOS[@]}] $scenario"
  echo "────────────────────────────────────────────────────────────────────"

  local_result_dir="$RUN_DIR/$scenario"
  mkdir -p "$local_result_dir"

  # 1. Create fresh workspace
  workspace_create "$scenario" > /dev/null

  # 2. Execute DK (exit code unused — scoring proceeds regardless of execution outcome)
  capture_run "$scenario" "$local_result_dir" "$EXEC_MODE" || true

  # 3. Score the output
  scenario_score=0
  scenario_score=$(score_scenario "$scenario" "$local_result_dir" "$SKIP_LLM") || true

  # 4. Record the score
  report_append_score "$RUN_ID" "$ITERATION" "$scenario" "$local_result_dir"

  TOTAL_SCORE=$((TOTAL_SCORE + scenario_score))
  SCENARIO_COUNT=$((SCENARIO_COUNT + 1))

  if [[ $scenario_score -lt 30 ]]; then
    FAILED+=("$scenario ($scenario_score)")
  fi

  echo ""
done

# ── Generate summary ───────────────────────────────────────────────────────
log_step "Generating summary..."

report_summary "$RUN_ID" "$RUN_DIR" > /dev/null 2>&1 || true

# Update latest symlink
ln -sfn "$RUN_ID" "$RESULTS_DIR/latest"

# ── Print results ──────────────────────────────────────────────────────────
report_table "$RUN_DIR"

AVG_SCORE=$((TOTAL_SCORE / SCENARIO_COUNT))
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Run complete: $RUN_ID"
echo "  Average score: $AVG_SCORE / 100"
echo "  Results: $RUN_DIR"
echo "  Scores:  $SCORES_TSV"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo ""
  echo "  Low-scoring scenarios:"
  for f in "${FAILED[@]}"; do
    echo "    - $f"
  done
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Write the run ID to stdout for loop.sh to capture
echo "$RUN_ID"

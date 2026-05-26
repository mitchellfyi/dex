#!/usr/bin/env bash
# Research harness — autonomous orchestrator
# Runs continuously: execute suite → analyze → improve → validate → merge → repeat
# Checks in every iteration and monitors progress.
#
# Usage:
#   ./research/orchestrate.sh                            # Run continuously (default 30s gap between cycles)
#   ./research/orchestrate.sh --max-cycles 5             # Limit cycles
#   ./research/orchestrate.sh --scenario-timeout 7200    # Force 2h per scenario (overrides scenario.json)
#   ./research/orchestrate.sh --runner codex             # Execute scenarios with Codex CLI
#   ./research/orchestrate.sh --allow-main               # Intentionally run on main/master
#
# Notes:
#   • The between-cycle sleep is intentionally short (30s) — each cycle already
#     runs a full suite (~1h with 12 scenarios at the default budget), so this is
#     just a breather for log flushing, not a rate limiter.
#   • SCENARIO_TIMEOUT (per-scenario agent budget) defaults to 3600s. Override
#     via `--scenario-timeout N` here, or set SCENARIO_TIMEOUT_OVERRIDE in env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=research/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=research/lib/report.sh
source "$SCRIPT_DIR/lib/report.sh"
# shellcheck source=research/lib/safety.sh
source "$SCRIPT_DIR/lib/safety.sh"

# ── Parse arguments ────────────────────────────────────────────────────────
MAX_CYCLES=0   # 0 = infinite
INTERVAL=30    # seconds between cycles — short on purpose; each cycle is the slow part
CYCLE=0
ALLOW_MAIN=0
SCENARIO_TIMEOUT_FLAG=""
RUNNER_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-cycles) MAX_CYCLES="$2"; shift 2 ;;
    --scenario-timeout) SCENARIO_TIMEOUT_FLAG="$2"; shift 2 ;;
    --runner) RUNNER_FLAG="$2"; shift 2 ;;
    --allow-main) ALLOW_MAIN=1; shift ;;
    --help|-h)
      echo "Usage: $0 [--max-cycles N] [--scenario-timeout SECONDS] [--runner claude|codex] [--allow-main]"
      echo ""
      echo "  --max-cycles N           Stop after N cycles (0 = infinite, default 0)"
      echo "  --scenario-timeout N     Force every scenario to use N-second budget,"
      echo "                           ignoring scenario.json overrides. Default budget"
      echo "                           is 3600s (set in research/config.sh)."
      echo "  --runner <name>          Scenario runner: claude (default) or codex."
      echo "  --allow-main             Allow running on main/master (off by default)."
      exit 0
      ;;
    *) shift ;;
  esac
done

if [[ $ALLOW_MAIN -eq 1 ]]; then
  export RESEARCH_ALLOW_MAIN=1
fi

if [[ -n "$SCENARIO_TIMEOUT_FLAG" ]]; then
  export SCENARIO_TIMEOUT_OVERRIDE="$SCENARIO_TIMEOUT_FLAG"
fi

RUN_FLAGS=()
if [[ -n "$RUNNER_FLAG" ]]; then
  case "$RUNNER_FLAG" in
    claude|codex) RUN_FLAGS+=(--runner "$RUNNER_FLAG") ;;
    *)
      log_error "Unknown runner: $RUNNER_FLAG"
      log_info "Supported runners: claude, codex"
      exit 1
      ;;
  esac
fi

# ── Pre-flight safety checks ──────────────────────────────────────────────
safety_check_branch
safety_check_clean
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DX AUTORESEARCH — Autonomous Orchestrator"
echo ""
echo "  Branch:           $(dx_branch)"
echo "  Max cycles:       ${MAX_CYCLES:-∞}"
echo "  Cycle gap:        ${INTERVAL}s"
echo "  Runner:           ${RUNNER_FLAG:-${RESEARCH_RUNNER:-claude}}"
echo "  Scenario timeout: ${SCENARIO_TIMEOUT_OVERRIDE:-per-scenario (scenario.json), default ${SCENARIO_TIMEOUT}s}"
echo "  Started:          $(date)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

_orchestrate_log() {
  echo "[$(date +%H:%M:%S)] $*" | tee -a "$RESEARCH_DIR/orchestrate.log"
}

_orchestrate_commit_pending() {
  local subject="$1"
  local body="${2:-}"

  if [[ -z "$(git -C "$DEX_DIR" status --porcelain)" ]]; then
    return 0
  fi

  if (cd "$DEX_DIR" && git add -A && git commit -m "$subject" -m "$body" -m "Co-Authored-By: DX Autoresearch <noreply@dexcode.ai>"); then
    _orchestrate_log "Committed pending changes: $subject"
    return 0
  fi

  _orchestrate_log "Commit failed: $subject"
  return 1
}

# ── Main loop ──────────────────────────────────────────────────────────────
while true; do
  CYCLE=$((CYCLE + 1))

  if [[ $MAX_CYCLES -gt 0 && $CYCLE -gt $MAX_CYCLES ]]; then
    _orchestrate_log "Reached max cycles ($MAX_CYCLES). Stopping."
    break
  fi

  _orchestrate_log "════ Cycle $CYCLE ════"

  # Step 1: Run full suite
  _orchestrate_log "Running full suite..."
  RUN_ID=""
  RUN_ID=$(bash "$SCRIPT_DIR/run.sh" "${RUN_FLAGS[@]}" --skip-llm-judge --iteration "$CYCLE" 2>&1 | tail -1) || true

  if [[ -z "$RUN_ID" || ! -f "$RESULTS_DIR/$RUN_ID/summary.json" ]]; then
    _orchestrate_log "Suite run failed. Waiting before retry..."
    sleep "$INTERVAL"
    continue
  fi

  # Step 2: Analyze results
  SUMMARY="$RESULTS_DIR/$RUN_ID/summary.json"
  AGG_SCORE=$(json_field "$SUMMARY" "aggregate_score")
  _orchestrate_log "Suite complete: $RUN_ID (aggregate: $AGG_SCORE)"

  # Check for any scenarios scoring 0 (likely harness bug)
  HAS_ZERO=false
  for scenario_dir in "$RESULTS_DIR/$RUN_ID"/*/; do
    [[ -d "$scenario_dir" ]] || continue
    scenario=$(basename "$scenario_dir")
    [[ -f "$scenario_dir/rubric-results.json" ]] || continue
    total=$(json_field "$scenario_dir/rubric-results.json" "total")
    if [[ "$total" == "0" ]]; then
      _orchestrate_log "WARNING: $scenario scored 0 — likely harness bug"
      HAS_ZERO=true
    fi
  done

  # Step 3: If all scores are 90+, we're done improving for this round
  ALL_HIGH=true
  for scenario_dir in "$RESULTS_DIR/$RUN_ID"/*/; do
    [[ -d "$scenario_dir" ]] || continue
    [[ -f "$scenario_dir/rubric-results.json" ]] || continue
    total=$(json_field "$scenario_dir/rubric-results.json" "total")
    [[ -z "$total" ]] && continue
    if [[ $total -lt 90 ]]; then
      ALL_HIGH=false
      break
    fi
  done

  if $ALL_HIGH && ! $HAS_ZERO; then
    _orchestrate_log "All scenarios scoring 90+! Merging to main."

    # Commit any pending changes
    _orchestrate_commit_pending \
      "research: all scenarios 90+ (cycle $CYCLE, aggregate $AGG_SCORE)" \
      "Recorded research results for a passing cycle."

    # Merge to main
    current_branch=""
    current_branch=$(dx_branch)
    if [[ "$current_branch" != "main" && "$current_branch" != "master" ]]; then
      (cd "$DEX_DIR" && \
        git checkout main && \
        git merge "$current_branch" --no-ff -m "Merge research: all scenarios 90+ (aggregate $AGG_SCORE)" && \
        git checkout "$current_branch") || {
          _orchestrate_log "Merge to main failed — continuing on research branch"
          (cd "$DEX_DIR" && git checkout "$current_branch") 2>/dev/null || true
        }
    fi
  fi

  # Step 4: Run improvement if scores are below target
  if ! $ALL_HIGH; then
    _orchestrate_log "Running improvement analysis..."
    PATCH_FILE=""
    PATCH_FILE=$(bash "$SCRIPT_DIR/improve.sh" "$RUN_ID" 2>&1 | tail -1) || true

    if [[ -n "$PATCH_FILE" && -f "$PATCH_FILE" ]]; then
      # Tag checkpoint
      safety_tag_checkpoint "cycle-$CYCLE"

      # Apply
      if (cd "$DEX_DIR" && git apply "$PATCH_FILE" 2>/dev/null); then
        _orchestrate_log "Applied improvement patch"

        # Validate with a quick run
        VALIDATE_ID=$(bash "$SCRIPT_DIR/run.sh" "${RUN_FLAGS[@]}" --skip-llm-judge --iteration "${CYCLE}-validate" 2>&1 | tail -1) || true

        if [[ -n "$VALIDATE_ID" && -f "$RESULTS_DIR/$VALIDATE_ID/summary.json" ]]; then
          NEW_SCORE=$(json_field "$RESULTS_DIR/$VALIDATE_ID/summary.json" "aggregate_score")
          _orchestrate_log "Validation score: $NEW_SCORE (was: $AGG_SCORE)"

          if python3 -c "exit(0 if $NEW_SCORE >= $AGG_SCORE - 5 else 1)" 2>/dev/null; then
            _orchestrate_log "Improvement accepted (Δ $(python3 -c "print(round($NEW_SCORE - $AGG_SCORE, 1))"))"

            # Commit
            _orchestrate_commit_pending \
              "research: improve DX (cycle $CYCLE, $AGG_SCORE to $NEW_SCORE)" \
              "Accepted generated research improvements after validation."

            # Merge to main if improved
            if python3 -c "exit(0 if $NEW_SCORE > $AGG_SCORE else 1)" 2>/dev/null; then
              current_branch=""
              current_branch=$(dx_branch)
              if [[ "$current_branch" != "main" && "$current_branch" != "master" ]]; then
                (cd "$DEX_DIR" && \
                  git checkout main && \
                  git merge "$current_branch" --no-ff -m "Merge research improvement: cycle $CYCLE ($AGG_SCORE → $NEW_SCORE)" && \
                  git checkout "$current_branch") || {
                    _orchestrate_log "Merge failed — staying on research branch"
                    (cd "$DEX_DIR" && git checkout "$current_branch") 2>/dev/null || true
                  }
              fi
            fi
          else
            _orchestrate_log "Improvement regressed. Reverting."
            safety_reverse_patch "$PATCH_FILE" || exit 1
            _orchestrate_commit_pending \
              "research: record rejected cycle $CYCLE results" \
              "Generated patch was rejected after validation. The patch was reversed without rewriting branch history."
          fi
        fi
      else
        _orchestrate_log "Patch failed to apply"
        _orchestrate_commit_pending \
          "research: record cycle $CYCLE results" \
          "Generated patch failed to apply. Recorded the suite results for analysis."
      fi
    else
      _orchestrate_log "No improvement patch generated"
      _orchestrate_commit_pending \
        "research: record cycle $CYCLE results" \
        "No applicable improvement patch was generated. Recorded the suite results for analysis."
    fi
  fi

  # Step 5: Wait before next cycle
  _orchestrate_log "Cycle $CYCLE complete. Next cycle in ${INTERVAL}s."
  _orchestrate_log ""
  sleep "$INTERVAL"
done

_orchestrate_log "Orchestrator stopped after $CYCLE cycles."

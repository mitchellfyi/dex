#!/usr/bin/env bash
# Research harness — autonomous orchestrator
# Runs continuously: execute suite → analyze → improve → validate → merge → repeat
# Checks in every iteration and monitors progress.
#
# Usage:
#   ./research/orchestrate.sh                    # Run continuously
#   ./research/orchestrate.sh --max-cycles 5     # Limit cycles
#   ./research/orchestrate.sh --interval 600     # Check every 10 min (default)

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
INTERVAL=600   # seconds between cycles
CYCLE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-cycles) MAX_CYCLES="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--max-cycles N] [--interval SECONDS]"
      exit 0
      ;;
    *) shift ;;
  esac
done

# ── Pre-flight safety checks ──────────────────────────────────────────────
safety_check_branch
safety_check_clean
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DK AUTORESEARCH — Autonomous Orchestrator"
echo ""
echo "  Branch:     $(dk_branch)"
echo "  Max cycles: ${MAX_CYCLES:-∞}"
echo "  Interval:   ${INTERVAL}s"
echo "  Started:    $(date)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

_orchestrate_log() {
  echo "[$(date +%H:%M:%S)] $*" | tee -a "$RESEARCH_DIR/orchestrate.log"
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
  RUN_ID=$(bash "$SCRIPT_DIR/run.sh" --skip-llm-judge --iteration "$CYCLE" 2>&1 | tail -1) || true

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
    if [[ -n "$(git -C "$DOYAKEN_DIR" status --porcelain)" ]]; then
      (cd "$DOYAKEN_DIR" && git add -A && git commit -m "research: all scenarios 90+ (cycle $CYCLE, aggregate $AGG_SCORE)

Co-Authored-By: DK Autoresearch <noreply@doyaken.ai>") || true
    fi

    # Merge to main
    current_branch=""
    current_branch=$(dk_branch)
    if [[ "$current_branch" != "main" && "$current_branch" != "master" ]]; then
      (cd "$DOYAKEN_DIR" && \
        git checkout main && \
        git merge "$current_branch" --no-ff -m "Merge research: all scenarios 90+ (aggregate $AGG_SCORE)" && \
        git checkout "$current_branch") || {
          _orchestrate_log "Merge to main failed — continuing on research branch"
          (cd "$DOYAKEN_DIR" && git checkout "$current_branch") 2>/dev/null || true
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
      if (cd "$DOYAKEN_DIR" && git apply "$PATCH_FILE" 2>/dev/null); then
        _orchestrate_log "Applied improvement patch"

        # Validate with a quick run
        VALIDATE_ID=$(bash "$SCRIPT_DIR/run.sh" --skip-llm-judge --iteration "${CYCLE}-validate" 2>&1 | tail -1) || true

        if [[ -n "$VALIDATE_ID" && -f "$RESULTS_DIR/$VALIDATE_ID/summary.json" ]]; then
          NEW_SCORE=$(json_field "$RESULTS_DIR/$VALIDATE_ID/summary.json" "aggregate_score")
          _orchestrate_log "Validation score: $NEW_SCORE (was: $AGG_SCORE)"

          if python3 -c "exit(0 if $NEW_SCORE >= $AGG_SCORE - 5 else 1)" 2>/dev/null; then
            _orchestrate_log "Improvement accepted (Δ $(python3 -c "print(round($NEW_SCORE - $AGG_SCORE, 1))"))"

            # Commit
            (cd "$DOYAKEN_DIR" && git add -A && git commit -m "research: improve DK (cycle $CYCLE, $AGG_SCORE → $NEW_SCORE)

Co-Authored-By: DK Autoresearch <noreply@doyaken.ai>") || true

            # Merge to main if improved
            if python3 -c "exit(0 if $NEW_SCORE > $AGG_SCORE else 1)" 2>/dev/null; then
              current_branch=""
              current_branch=$(dk_branch)
              if [[ "$current_branch" != "main" && "$current_branch" != "master" ]]; then
                (cd "$DOYAKEN_DIR" && \
                  git checkout main && \
                  git merge "$current_branch" --no-ff -m "Merge research improvement: cycle $CYCLE ($AGG_SCORE → $NEW_SCORE)" && \
                  git checkout "$current_branch") || {
                    _orchestrate_log "Merge failed — staying on research branch"
                    (cd "$DOYAKEN_DIR" && git checkout "$current_branch") 2>/dev/null || true
                  }
              fi
            fi
          else
            _orchestrate_log "Improvement regressed. Reverting."
            safety_revert_to_checkpoint "cycle-$CYCLE"
          fi
        fi
      else
        _orchestrate_log "Patch failed to apply"
      fi
    else
      _orchestrate_log "No improvement patch generated"
    fi
  fi

  # Step 5: Wait before next cycle
  _orchestrate_log "Cycle $CYCLE complete. Next cycle in ${INTERVAL}s."
  _orchestrate_log ""
  sleep "$INTERVAL"
done

_orchestrate_log "Orchestrator stopped after $CYCLE cycles."

#!/usr/bin/env bash
# Compare Dex against bare Claude Code on the same model.
#
# Usage:
#   bash research/compare/run.sh                       # every scenario with a compare/ dir, 3 replicas
#   bash research/compare/run.sh --scenario cli-todo-app --replicas 1
#   bash research/compare/run.sh --jobs 3 --no-followup
#   bash research/compare/run.sh --resume research/results/compare/<run-id>
#   bash research/compare/run.sh --dry-run
#   bash research/compare/run.sh --arms bare,dex@HEAD,dex,dex-loop
#
# Trials run in a shuffled order so neither arm always goes first, which would
# let time of day or a rate limit land on one arm more than the other.

set -euo pipefail

COMPARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=research/lib/common.sh
source "$COMPARE_DIR/../lib/common.sh"
# shellcheck source=research/compare/arms.sh
source "$COMPARE_DIR/arms.sh"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --scenario <name>   Run this scenario (repeatable). Default: every scenario
                      with a compare/ directory.
  --arms <a,b>        Arms to run: bare, dex, dex-loop, and dex@<ref> or
                      dex-loop@<ref> for another revision's prompts.
                      Default: bare,dex
  --replicas <n>      Replicas per arm and scenario. Default: 3
  --jobs <n>          Trials to run at once. Default: 2
  --seed <n>          Shuffle seed. Default: the run id
  --no-followup       Skip the follow-up task
  --resume <run_dir>  Finish the trials of an earlier run that have no meta.json
  --no-quality        Skip the quality phase (quality.sh) after the trials
  --no-judge          Run the quality phase without the judge
  --judge-provider <p> auto (default), codex or claude
  --judge-model <m>   Model for the judge
  --dry-run           Print the trial list and exit
  -h, --help          Show this help

Environment: CLAUDE_MODEL (default opus), CLAUDE_EFFORT (default max),
FOLLOWUP_MODEL (default sonnet), FOLLOWUP_EFFORT (default high),
SCENARIO_TIMEOUT_OVERRIDE (seconds, forces every scenario's budget).
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    log_error "$1 requires a value"
    exit 2
  fi
}

SCENARIOS=()
ARMS="bare,dex"
REPLICAS=3
JOBS=2
SEED=""
FOLLOWUP=1
RESUME=""
DRY_RUN=0
QUALITY=1
JUDGE=1
JUDGE_PROVIDER="auto"
JUDGE_MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) require_value "$1" "${2:-}"; SCENARIOS+=("$2"); shift 2 ;;
    --arms) require_value "$1" "${2:-}"; ARMS="$2"; shift 2 ;;
    --replicas) require_value "$1" "${2:-}"; REPLICAS="$2"; shift 2 ;;
    --jobs) require_value "$1" "${2:-}"; JOBS="$2"; shift 2 ;;
    --seed) require_value "$1" "${2:-}"; SEED="$2"; shift 2 ;;
    --no-followup) FOLLOWUP=0; shift ;;
    --resume) require_value "$1" "${2:-}"; RESUME="$2"; shift 2 ;;
    --no-quality) QUALITY=0; shift ;;
    --no-judge) JUDGE=0; shift ;;
    --judge-provider) require_value "$1" "${2:-}"; JUDGE_PROVIDER="$2"; shift 2 ;;
    --judge-model) require_value "$1" "${2:-}"; JUDGE_MODEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown option: $1"; usage >&2; exit 2 ;;
  esac
done

for value in "$REPLICAS" "$JOBS"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { log_error "--replicas and --jobs take a positive integer"; exit 2; }
done

if [[ -n "$RESUME" ]]; then
  RUN_DIR="$(cd "$RESUME" && pwd)"
  [[ -f "$RUN_DIR/trials.tsv" ]] || { log_error "No trials.tsv in $RUN_DIR"; exit 2; }
  FOLLOWUP=$(json_field "$RUN_DIR/run.json" "followup")
  [[ "$FOLLOWUP" == 1 || "$FOLLOWUP" == 0 ]] || FOLLOWUP=1
else
  IFS=',' read -r -a ARM_LIST <<< "$ARMS"
  for arm in "${ARM_LIST[@]}"; do
    compare_arm_valid "$arm" || { log_error "Unknown arm: $arm (known: $COMPARE_ARMS)"; exit 2; }
    ref=$(compare_arm_ref "$arm")
    if [[ -n "$ref" ]] && ! git -C "$DEX_DIR" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
      log_error "$arm: $ref is not a commit in $DEX_DIR"
      exit 2
    fi
  done
  if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
    for dir in "$SCENARIOS_DIR"/*/compare; do
      [[ -d "$dir/hidden" ]] && SCENARIOS+=("$(basename "$(dirname "$dir")")")
    done
  fi
  for scenario in "${SCENARIOS[@]}"; do
    scenario_name_require_valid "$scenario" || exit 2
    [[ -d "$SCENARIOS_DIR/$scenario/compare/hidden" ]] \
      || { log_error "$scenario has no compare/hidden suite"; exit 2; }
    missing=$(scenario_missing_prerequisites "$scenario")
    [[ -z "$missing" ]] || { log_error "$scenario needs $missing"; exit 2; }
  done

  RUN_ID="compare-$(date +%Y%m%d-%H%M%S)"
  [[ -n "$SEED" ]] || SEED="$RUN_ID"
  RUN_DIR="$RESULTS_DIR/compare/$RUN_ID"
  trials=$(python3 - "$SEED" "$REPLICAS" "${ARM_LIST[*]}" "${SCENARIOS[*]}" <<'PY'
import random
import sys

seed, replicas, arms, scenarios = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(), sys.argv[4].split()
rows = [(arm, scenario, r) for r in range(1, replicas + 1) for scenario in scenarios for arm in arms]
random.Random(seed).shuffle(rows)
for i, (arm, scenario, r) in enumerate(rows, 1):
    slug = arm.replace("@", "-at-").replace("/", "_")
    print(f"t{i:03d}-{slug}-{scenario}-r{r}\t{arm}\t{scenario}\t{r}")
PY
)
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s\n' "$trials"
    exit 0
  fi
  mkdir -p "$RUN_DIR/trials"
  printf '%s\n' "$trials" > "$RUN_DIR/trials.tsv"
  # Each dex arm's prompts are fixed now: editing them mid-run changes nothing.
  for arm in "${ARM_LIST[@]}"; do
    if [[ "$(compare_arm_family "$arm")" != bare ]]; then
      compare_arm_prompts "$arm" "$RUN_DIR/arms/$(compare_arm_slug "$arm")"
    fi
  done

  dirty=$(git -C "$DEX_DIR" status --porcelain -- prompts skills hooks research/lib research/compare research/scenarios | wc -l | tr -d ' ')
  json_write "$RUN_DIR/run.json" "{
    \"run_id\": \"$RUN_ID\",
    \"started_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
    \"arms\": \"${ARM_LIST[*]}\",
    \"scenarios\": \"${SCENARIOS[*]}\",
    \"replicas\": $REPLICAS,
    \"jobs\": $JOBS,
    \"seed\": \"$SEED\",
    \"followup\": $FOLLOWUP,
    \"model\": \"$CLAUDE_MODEL\",
    \"effort\": \"$CLAUDE_EFFORT\",
    \"followup_model\": \"$FOLLOWUP_MODEL\",
    \"followup_effort\": \"$FOLLOWUP_EFFORT\",
    \"dex_commit\": \"$(dx_commit_hash)\",
    \"dex_dirty_files\": $dirty,
    \"claude_version\": \"$(claude --version 2>/dev/null | head -1)\",
    \"node_version\": \"$(node --version 2>/dev/null)\",
    \"host\": \"$(uname -sm)\"
  }"
fi

if [[ "$DRY_RUN" == 1 ]]; then
  cat "$RUN_DIR/trials.tsv"
  exit 0
fi

total=$(grep -c . "$RUN_DIR/trials.tsv")
log_step "Run: $RUN_DIR"
log_info "$total trials, $JOBS at a time, follow-up $([[ $FOLLOWUP == 1 ]] && echo on || echo off)"

export COMPARE_FOLLOWUP="$FOLLOWUP"
# Each line is "<trial_id> <arm> <scenario> <replica>"; xargs appends them to
# trial.sh's arguments. A failed trial does not stop the others.
cut -f1-4 "$RUN_DIR/trials.tsv" | tr '\t' ' ' \
  | xargs -P "$JOBS" -L 1 bash "$COMPARE_DIR/trial.sh" "$RUN_DIR" \
  || log_warn "At least one trial exited non-zero; see its trial.log"

if [[ "$QUALITY" == 1 ]]; then
  quality_args=("$RUN_DIR" --judge-provider "$JUDGE_PROVIDER")
  if [[ -n "$JUDGE_MODEL" ]]; then
    quality_args+=(--judge-model "$JUDGE_MODEL")
  fi
  if [[ "$JUDGE" == 0 ]]; then
    quality_args+=(--no-judge)
  fi
  bash "$COMPARE_DIR/quality.sh" "${quality_args[@]}" || {
    log_warn "The quality phase failed; rerun it with: bash $COMPARE_DIR/quality.sh $RUN_DIR"
    python3 "$COMPARE_DIR/report.py" "$RUN_DIR"
  }
else
  python3 "$COMPARE_DIR/report.py" "$RUN_DIR"
fi

# Last line, for scripts (loop.sh) that need the run directory.
printf 'RUN_DIR=%s\n' "$RUN_DIR"

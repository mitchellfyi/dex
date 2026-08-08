#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ -n "${REVIEW_EVAL_TEST_STUB+x}" || \
      -n "${REVIEW_EVAL_TEST_STUB_MODE+x}" || \
      -n "${REVIEW_EVAL_METADATA_SOURCE_REPO+x}" || \
      -n "${REVIEW_EVAL_METADATA_CONTROLLER+x}" || \
      -n "${REVIEW_EVAL_METADATA_CONTROLLER_INPUTS+x}" || \
      -n "${REVIEW_EVAL_METADATA_SCENARIOS+x}" || \
      -n "${REVIEW_EVAL_SCENARIOS_DIR+x}" || \
      -n "${REVIEW_EVAL_CHECK_TIMEOUT_SECONDS+x}" ]]; then
  printf '%s\n' "review-loop evaluation: test-only environment overrides are not allowed by run.sh" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=research/review-loop/lib.sh
source "$SCRIPT_DIR/lib.sh"

stage="baseline"
replicas="3"
jobs="2"
dex_ref="HEAD"
trial_timeout="7200"
scenario_filter=""
dry_run=0
output_root="$REVIEW_EVAL_RESULTS_DIR"
claude_model=""
claude_effort=""
codex_model=""
codex_effort="default"
runners=()

usage() {
  printf '%s\n' "Usage: research/review-loop/run.sh [options]"
  printf '%s\n' ""
  printf '%s\n' "Options:"
  printf '%s\n' "  --stage baseline|final       Evaluation stage (default: baseline)"
  printf '%s\n' "  --replicas N                Replicas per scenario/provider (default: 3)"
  printf '%s\n' "  --runner claude|codex       Provider to include; repeatable"
  printf '%s\n' "  --jobs N                    Maximum parallel trials (default: 2)"
  printf '%s\n' "  --dex-ref REF               Committed Dex runtime to evaluate (default: HEAD)"
  printf '%s\n' "  --trial-timeout SECONDS     Whole-trial timeout; timeouts are censored"
  printf '%s\n' "  --scenario ID               Run one catalog scenario"
  printf '%s\n' "  --claude-model MODEL        Explicit Claude model or alias"
  printf '%s\n' "  --claude-effort LEVEL       Explicit Claude effort"
  printf '%s\n' "  --codex-model MODEL         Explicit Codex model"
  printf '%s\n' "  --output-root PATH          Result parent directory"
  printf '%s\n' "  --dry-run                   Print the resolved matrix only"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage|--replicas|--runner|--jobs|--dex-ref|--trial-timeout|--scenario|--claude-model|--claude-effort|--codex-model|--output-root)
      [[ $# -ge 2 ]] || { review_eval_error "$1 requires a value"; exit 2; }
      option="$1"
      value="$2"
      shift 2
      case "$option" in
        --stage) stage="$value" ;;
        --replicas) replicas="$value" ;;
        --runner) runners+=("$value") ;;
        --jobs) jobs="$value" ;;
        --dex-ref) dex_ref="$value" ;;
        --trial-timeout) trial_timeout="$value" ;;
        --scenario) scenario_filter="$value" ;;
        --claude-model) claude_model="$value" ;;
        --claude-effort) claude_effort="$value" ;;
        --codex-model) codex_model="$value" ;;
        --output-root) output_root="$value" ;;
      esac
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      review_eval_error "unknown option: $1"
      exit 2
      ;;
  esac
done

case "$stage" in
  baseline|final) ;;
  *) review_eval_error "stage must be baseline or final"; exit 2 ;;
esac
replicas=$(review_eval_positive_integer "$replicas") || {
  review_eval_error "replicas must be a positive integer"
  exit 2
}
jobs=$(review_eval_positive_integer "$jobs") || {
  review_eval_error "jobs must be a positive integer"
  exit 2
}
trial_timeout=$(review_eval_positive_integer "$trial_timeout") || {
  review_eval_error "trial timeout must be a positive integer"
  exit 2
}
[[ "$replicas" -le "$REVIEW_EVAL_MAX_REPLICAS" ]] || {
  review_eval_error "replicas cannot exceed $REVIEW_EVAL_MAX_REPLICAS"
  exit 2
}
[[ "$jobs" -le "$REVIEW_EVAL_MAX_JOBS" ]] || {
  review_eval_error "jobs cannot exceed $REVIEW_EVAL_MAX_JOBS"
  exit 2
}
[[ "$trial_timeout" -le "$REVIEW_EVAL_MAX_TRIAL_TIMEOUT" ]] || {
  review_eval_error "trial timeout cannot exceed $REVIEW_EVAL_MAX_TRIAL_TIMEOUT seconds"
  exit 2
}
[[ -n "$output_root" ]] || { review_eval_error "output root cannot be empty"; exit 2; }
if [[ -n "$scenario_filter" ]]; then
  review_eval_scenario_name_valid "$scenario_filter" && \
    [[ -f "$(review_eval_scenario_dir "$scenario_filter")/scenario.json" ]] || {
      review_eval_error "unknown scenario: $scenario_filter"
      exit 2
    }
fi
if [[ ${#runners[@]} -eq 0 ]]; then
  runners=(claude codex)
fi
for runner in "${runners[@]}"; do
  case "$runner" in
    claude|codex) ;;
    *) review_eval_error "runner must be claude or codex"; exit 2 ;;
  esac
done
if [[ ${#runners[@]} -ne $(printf '%s\n' "${runners[@]}" | LC_ALL=C sort -u | wc -l | tr -d ' ') ]]; then
  review_eval_error "each runner may be selected only once"
  exit 2
fi
review_eval_validate_catalog || exit 2
dex_sha=$(git -C "$REVIEW_EVAL_REPO_ROOT" rev-parse --verify "${dex_ref}^{commit}") || {
  review_eval_error "could not resolve committed Dex ref: $dex_ref"
  exit 2
}

matrix_file=$(mktemp "${TMPDIR:-/tmp}/dex-review-matrix.XXXXXX")
pids=()
trial_labels=()
cleanup() {
  local pid
  trap - EXIT INT TERM HUP
  for pid in "${pids[@]:-}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${pids[@]:-}"; do
    wait "$pid" 2>/dev/null || true
  done
  rm -f "$matrix_file"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
review_eval_matrix_rows "$replicas" "${runners[@]}" > "$matrix_file"
if [[ -n "$scenario_filter" ]]; then
  filtered_matrix="${matrix_file}.filtered"
  awk -F '\t' -v scenario="$scenario_filter" '$1 == scenario' "$matrix_file" > "$filtered_matrix"
  mv "$filtered_matrix" "$matrix_file"
fi

if [[ $dry_run -eq 1 ]]; then
  while IFS=$'\t' read -r scenario replica runner; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$stage" "$scenario" "$replica" "$runner" "$dex_sha"
  done < "$matrix_file"
  exit 0
fi

for runner in "${runners[@]}"; do
  case "$runner" in
    claude)
      [[ -n "$claude_model" && -n "$claude_effort" ]] || {
        review_eval_error "non-dry Claude runs require --claude-model and --claude-effort"
        exit 2
      }
      ;;
    codex)
      [[ -n "$codex_model" ]] || {
        review_eval_error "non-dry Codex runs require --codex-model"
        exit 2
      }
      ;;
  esac
done

command -v zsh >/dev/null 2>&1 || { review_eval_error "zsh is required"; exit 2; }
command -v node >/dev/null 2>&1 || { review_eval_error "node is required by the fixture catalog"; exit 2; }
for runner in "${runners[@]}"; do
  command -v "$runner" >/dev/null 2>&1 || {
    review_eval_error "$runner CLI is required for this matrix"
    exit 2
  }
done

run_stamp=$(date -u +%Y%m%dT%H%M%SZ)
run_dir="$output_root/${stage}-${run_stamp}-${dex_sha:0:12}-$$"
mkdir -p "$run_dir/trials"
chmod 700 "$run_dir" "$run_dir/trials"
controller_inputs=$(review_eval_archive_controller_inputs "$run_dir")
REVIEW_EVAL_DIR="$controller_inputs/controller"
REVIEW_EVAL_SCENARIOS_DIR="$controller_inputs/scenarios"
export REVIEW_EVAL_SCENARIOS_DIR
review_eval_validate_catalog
review_eval_matrix_rows "$replicas" "${runners[@]}" > "$matrix_file"
if [[ -n "$scenario_filter" ]]; then
  filtered_matrix="${matrix_file}.filtered"
  awk -F '\t' -v scenario="$scenario_filter" '$1 == scenario' "$matrix_file" > "$filtered_matrix"
  mv "$filtered_matrix" "$matrix_file"
fi
cp "$matrix_file" "$run_dir/matrix.tsv"
review_eval_write_run_metadata "$run_dir" "$stage" "$dex_sha" "$replicas" "$jobs" \
  "$trial_timeout" "$claude_model" "$claude_effort" "$codex_model" "$codex_effort" "${runners[*]}"

failures=0

reap_first_trial() {
  local pid="${pids[0]}" label="${trial_labels[0]}" status=0
  wait "$pid" || status=$?
  if [[ $status -ne 0 ]]; then
    review_eval_error "trial failed: $label (exit $status)"
    failures=$((failures + 1))
  fi
  pids=("${pids[@]:1}")
  trial_labels=("${trial_labels[@]:1}")
}

while IFS=$'\t' read -r scenario replica runner; do
  trial_dir="$run_dir/trials/$scenario/replica-$replica/$runner"
  model="$claude_model"
  effort="$claude_effort"
  if [[ "$runner" == "codex" ]]; then
    model="$codex_model"
    effort="$codex_effort"
  fi
  review_eval_run_trial "$REVIEW_EVAL_REPO_ROOT" "$dex_sha" "$stage" "$scenario" \
    "$replica" "$runner" "$model" "$effort" "$trial_timeout" "$trial_dir" &
  pids+=("$!")
  trial_labels+=("$scenario/$replica/$runner")
  if [[ ${#pids[@]} -ge $jobs ]]; then
    reap_first_trial
  fi
done < "$matrix_file"
while [[ ${#pids[@]} -gt 0 ]]; do
  reap_first_trial
done

review_eval_summarize_run "$run_dir" || failures=$((failures + 1))
printf '%s\n' "$run_dir"
[[ $failures -eq 0 ]]

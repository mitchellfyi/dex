#!/usr/bin/env bash
# Measure the quality dimensions of every finished trial in a run, judge the
# bare/dex pairs, and rewrite the report.
#
# Usage:
#   bash research/compare/quality.sh <run_dir>
#   bash research/compare/quality.sh <run_dir> --skip perf,fuzz --no-judge
#   bash research/compare/quality.sh <run_dir> --judge-provider claude --judge-model sonnet
#
# run.sh calls this once every agent has finished. Trials are measured one at
# a time, so the timing-sensitive dimensions (performance, suite runtime and
# flakiness) never compete with agents still working. It works on any earlier
# run too: the measurements read only the snapshots each trial saved.

set -euo pipefail

COMPARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=research/lib/common.sh
source "$COMPARE_DIR/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $0 <run_dir> [options]

Options:
  --force                  Re-measure trials that already have quality.json
  --rejudge                Discard judge.json and judge every pair again
  --judge-only             Skip measurement; only judge and report
  --skip <dims>            Comma-separated dimensions to skip:
                           deps,suite,static,duplication,cli,docs,perf,fuzz
  --no-judge               Skip the pairwise and report-accuracy judge
  --judge-provider <name>  auto (default: codex when installed, else claude),
                           codex or claude
  --judge-model <model>    Model for the judge; the provider default otherwise
  -h, --help               Show this help
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    log_error "$1 requires a value"
    exit 2
  fi
}

RUN_DIR=""
FORCE=0
REJUDGE=0
JUDGE_ONLY=0
SKIP=""
JUDGE=1
JUDGE_PROVIDER="${COMPARE_JUDGE_PROVIDER:-auto}"
JUDGE_MODEL="${COMPARE_JUDGE_MODEL:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --rejudge) REJUDGE=1; shift ;;
    --judge-only) JUDGE_ONLY=1; shift ;;
    --skip) require_value "$1" "${2:-}"; SKIP="$2"; shift 2 ;;
    --no-judge) JUDGE=0; shift ;;
    --judge-provider) require_value "$1" "${2:-}"; JUDGE_PROVIDER="$2"; shift 2 ;;
    --judge-model) require_value "$1" "${2:-}"; JUDGE_MODEL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) log_error "Unknown option: $1"; usage >&2; exit 2 ;;
    *) RUN_DIR="$1"; shift ;;
  esac
done

[[ -n "$RUN_DIR" && -d "$RUN_DIR/trials" ]] || { usage >&2; exit 2; }
RUN_DIR="$(cd "$RUN_DIR" && pwd)"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/bench-quality.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

measured=0
for trial_dir in "$RUN_DIR"/trials/*/; do
  trial_dir="${trial_dir%/}"
  [[ "$JUDGE_ONLY" == 0 && -f "$trial_dir/meta.json" && -d "$trial_dir/final" ]] || continue
  if [[ "$FORCE" != 1 && -f "$trial_dir/quality.json" ]]; then
    continue
  fi
  trial_id="$(basename "$trial_dir")"
  scenario=$(json_field "$trial_dir/meta.json" "scenario")
  arm=$(json_field "$trial_dir/meta.json" "arm")
  scenario_name_require_valid "$scenario" || continue

  log_step "[$trial_id] measuring quality"
  ws="$scratch/$trial_id/$scenario"
  mkdir -p "$ws"
  rsync -a --exclude node_modules "$trial_dir/final/" "$ws/"
  # The dex arm's injected CLAUDE.md is harness input, as in trial.sh.
  if [[ "$arm" != bare && ! -e "$SCENARIOS_DIR/$scenario/seed/CLAUDE.md" ]]; then
    rm -f "$ws/CLAUDE.md"
  fi
  if python3 "$COMPARE_DIR/quality.py" measure \
      --scenario-dir "$SCENARIOS_DIR/$scenario" --ws "$ws" \
      --out "$trial_dir/quality.json.tmp" --skip "$SKIP" \
      2>>"$trial_dir/trial.log"; then
    mv "$trial_dir/quality.json.tmp" "$trial_dir/quality.json"
    measured=$((measured + 1))
  else
    rm -f "$trial_dir/quality.json.tmp"
    log_warn "[$trial_id] quality measurement failed; see $trial_dir/trial.log"
  fi
  rm -rf "${scratch:?}/$trial_id"
done
log_info "Measured $measured trial(s)"

if [[ "$JUDGE" == 1 ]]; then
  judge_args=("$RUN_DIR" --provider "$JUDGE_PROVIDER")
  if [[ -n "$JUDGE_MODEL" ]]; then
    judge_args+=(--model "$JUDGE_MODEL")
  fi
  if [[ "$REJUDGE" == 1 ]]; then
    judge_args+=(--force)
  fi
  python3 "$COMPARE_DIR/judge.py" "${judge_args[@]}" \
    || log_warn "The judge did not run; the report will not have its sections"
fi

python3 "$COMPARE_DIR/report.py" "$RUN_DIR"

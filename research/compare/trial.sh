#!/usr/bin/env bash
# One trial of the arm comparison: run an arm on a scenario, measure the
# result, then hand the result to a fixed follow-up agent and measure again.
#
# Usage: trial.sh <run_dir> <trial_id> <arm> <scenario> <replica>
#
# Workspaces live in a fresh temp directory, not under research/, so neither
# the agent nor its path can see the harness, the rubrics or the hidden tests.
# Everything worth keeping is copied into <run_dir>/trials/<trial_id>/.

set -euo pipefail

COMPARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=research/lib/common.sh
source "$COMPARE_DIR/../lib/common.sh"
# shellcheck source=research/lib/workspace.sh
source "$COMPARE_DIR/../lib/workspace.sh"
# shellcheck source=research/lib/capture.sh
source "$COMPARE_DIR/../lib/capture.sh"
# shellcheck source=research/lib/score.sh
source "$COMPARE_DIR/../lib/score.sh"
# shellcheck source=research/compare/arms.sh
source "$COMPARE_DIR/arms.sh"

if [[ $# -ne 5 ]]; then
  echo "Usage: $0 <run_dir> <trial_id> <arm> <scenario> <replica>" >&2
  exit 2
fi
run_dir="$1" trial_id="$2" arm="$3" scenario="$4" replica="$5"
scenario_name_require_valid "$scenario" || exit 2
compare_arm_valid "$arm" || { log_error "Unknown arm: $arm"; exit 2; }
family=$(compare_arm_family "$arm")
prompts_dir="$run_dir/arms/$(compare_arm_slug "$arm")"
if [[ "$family" != bare && ! -f "$prompts_dir/guardrails.md" ]]; then
  log_error "No prompt snapshot for $arm in $prompts_dir; run.sh writes it when the run starts"
  exit 2
fi

sc_dir="$(scenario_dir "$scenario")"
trial_dir="$run_dir/trials/$trial_id"
if [[ -f "$trial_dir/meta.json" ]]; then
  log_info "[$trial_id] already complete, skipping"
  exit 0
fi
rm -rf "$trial_dir"
mkdir -p "$trial_dir"
log="$trial_dir/trial.log"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/bench.XXXXXX")"
cleanup() {
  if [[ "${COMPARE_KEEP_SCRATCH:-0}" == 1 ]]; then
    log_info "[$trial_id] scratch kept at $scratch"
  else
    rm -rf "$scratch"
  fi
}
trap cleanup EXIT

# copy_tree <from> <to> — the tree without node_modules.
copy_tree() {
  mkdir -p "$2"
  rsync -a --exclude node_modules "$1/" "$2/"
}

scenario_timeout() {
  local value
  value=$(json_field "$sc_dir/scenario.json" "timeout")
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || value="$SCENARIO_TIMEOUT"
  [[ -n "${SCENARIO_TIMEOUT_OVERRIDE:-}" ]] && value="$SCENARIO_TIMEOUT_OVERRIDE"
  printf '%s\n' "$value"
}

# ── Main task ────────────────────────────────────────────────────────────────

# workspace_dir and score_scenario resolve the workspace through this.
# shellcheck disable=SC2034
WORKSPACES_DIR="$scratch/w"
ws=$(workspace_create "$scenario" 2>>"$log")
baseline=$(git -C "$ws" rev-parse HEAD)
seeded=0
_scenario_seeded "$scenario" && seeded=1
timeout_s=$(scenario_timeout)

log_step "[$trial_id] $arm on $scenario (replica $replica, timeout ${timeout_s}s)"
start_epoch=$(date +%s)
main_exit=0
compare_arm_run "$arm" "$ws" "$trial_dir" "$(cat "$sc_dir/prompt.md")" "$timeout_s" "$seeded" "$scratch" "$prompts_dir" \
  || main_exit=$?
end_epoch=$(date +%s)
log_info "[$trial_id] $arm finished: exit $main_exit in $((end_epoch - start_epoch))s"

copy_tree "$ws" "$trial_dir/final"

# The dex arms write CLAUDE.md into the workspace. It is harness input, not
# something the agent produced, so it stays out of the diff and is removed
# before the follow-up agent sees the code.
injected=()
if [[ "$family" != bare && ! -e "$sc_dir/seed/CLAUDE.md" ]]; then
  injected+=(CLAUDE.md)
fi
exclude_args=()
for name in ${injected[@]+"${injected[@]}"}; do
  exclude_args+=(--exclude "$name")
done

measure_ws="$scratch/m/$scenario"
copy_tree "$ws" "$measure_ws"
python3 "$COMPARE_DIR/measure.py" main \
  --scenario-dir "$sc_dir" --ws "$measure_ws" --baseline "$baseline" \
  --stream "$trial_dir/stream.jsonl" --out "$trial_dir/main.json" \
  ${exclude_args[@]+"${exclude_args[@]}"} 2>>"$log" || log_warn "[$trial_id] main measurement failed; see $log"

# The existing rubric, for continuity with scores.tsv. It runs in the original
# workspace because it expects workspace_dir <scenario>; its dimensions are
# reported beside the outcome metrics, not folded into them.
legacy_total=$(score_scenario "$scenario" "$trial_dir" --skip-llm-judge 2>>"$log") || legacy_total=""
[[ "$legacy_total" =~ ^[0-9]+$ ]] || legacy_total=""

# ── Follow-up task ───────────────────────────────────────────────────────────

followup_exit=""
followup_seconds=""
followup_prompt="$sc_dir/compare/followup/prompt.md"
if [[ "${COMPARE_FOLLOWUP:-1}" == 1 && -f "$followup_prompt" ]]; then
  fws="$scratch/f/$scenario"
  copy_tree "$trial_dir/final" "$fws"
  for name in ${injected[@]+"${injected[@]}"}; do
    rm -f "$fws/$name"
  done
  git -C "$fws" add -A
  git -C "$fws" commit --quiet --allow-empty -m "main task output"
  fbaseline=$(git -C "$fws" rev-parse HEAD)
  ftimeout=$(json_field "$sc_dir/compare/compare.json" "followup_timeout")
  [[ "$ftimeout" =~ ^[1-9][0-9]*$ ]] || ftimeout=1800

  log_step "[$trial_id] follow-up on $arm output ($FOLLOWUP_MODEL, timeout ${ftimeout}s)"
  fstart=$(date +%s)
  followup_exit=0
  compare_followup_run "$fws" "$trial_dir/followup" "$(cat "$followup_prompt")" "$ftimeout" \
    || followup_exit=$?
  followup_seconds=$(( $(date +%s) - fstart ))
  log_info "[$trial_id] follow-up finished: exit $followup_exit in ${followup_seconds}s"

  copy_tree "$fws" "$trial_dir/followup/final"
  fmeasure_ws="$scratch/fm/$scenario"
  copy_tree "$fws" "$fmeasure_ws"
  python3 "$COMPARE_DIR/measure.py" followup \
    --scenario-dir "$sc_dir" --ws "$fmeasure_ws" --baseline "$fbaseline" \
    --stream "$trial_dir/followup/stream.jsonl" --out "$trial_dir/followup.json" \
    2>>"$log" || log_warn "[$trial_id] follow-up measurement failed; see $log"
fi

# ── Record ───────────────────────────────────────────────────────────────────

# meta.json is written last: its presence is what marks the trial complete.
json_write "$trial_dir/meta.json" "{
  \"trial_id\": \"$trial_id\",
  \"arm\": \"$arm\",
  \"arm_family\": \"$family\",
  \"prompts_source\": \"$(cat "$prompts_dir/source" 2>/dev/null || echo none)\",
  \"scenario\": \"$scenario\",
  \"replica\": $replica,
  \"seeded\": $seeded,
  \"model\": \"$CLAUDE_MODEL\",
  \"effort\": \"$CLAUDE_EFFORT\",
  \"timeout_s\": $timeout_s,
  \"exit_code\": $main_exit,
  \"wall_seconds\": $((end_epoch - start_epoch)),
  \"legacy_total\": ${legacy_total:-null},
  \"followup_model\": \"$FOLLOWUP_MODEL\",
  \"followup_effort\": \"$FOLLOWUP_EFFORT\",
  \"followup_exit_code\": ${followup_exit:-null},
  \"followup_wall_seconds\": ${followup_seconds:-null}
}"
log_success "[$trial_id] complete"

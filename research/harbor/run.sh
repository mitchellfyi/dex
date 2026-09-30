#!/usr/bin/env bash
# Run a public benchmark through Harbor with Dex, the Claude Code baseline, or both.
#
# Usage:
#   research/harbor/run.sh [options] [-- extra harbor run args]
#
#   --agent ARMS                   Comma-separated arms (default: both):
#                                    claude-code   Harbor's plain Claude Code
#                                    dex           Plan, Implement, Review
#                                    dex-noplan    Implement, Review
#                                    dex-noreview  Plan, Implement
#                                    dex-implement Implement only
#                                  both = claude-code,dex; all = every arm
#   --review-tier TIER             Force Dex's review depth: trivial|small|normal|complex
#   --dataset NAME@VERSION         Harbor dataset (default: terminal-bench-sample@2.0)
#   --model MODEL                  Model for both arms (default: anthropic/claude-sonnet-5-5)
#   --tasks N                      Run the first N tasks (harbor -l)
#   --task GLOB                    Run tasks matching GLOB (harbor -i, repeatable)
#   --concurrency N                Trials at once (default: 1)
#   --attempts K                   Attempts per task (default: 1)
#   --timeout-multiplier X         Agent timeout multiplier for both arms (default: 1)
#   --setup-timeout-multiplier X   Agent install time multiplier (default: 3). Setup only:
#                                  under emulation installing Claude Code outlasts
#                                  Harbor's 6 minutes, which is not the agent failing
#   --effort LEVEL                 low|medium|high|xhigh|max for both arms
#   --failed-in JOB                Add the tasks JOB failed (a screening run)
#   --passed-in JOB                Add the tasks JOB passed
#   --sample N                     Take N of the --passed-in tasks (fixed seed)
#   --task-file FILE               Add the task names listed in FILE, one per line
#   --one-at-a-time                Run each task as its own job (needs named tasks)
#   --prune-images                 After each job, delete the task images it pulled or
#                                  built; only benchmark images are touched
#   --stamp STAMP                  Continue an earlier --one-at-a-time run: tasks with a
#                                  verified result are skipped, errored ones rerun
#   --oracle                       Run the reference solutions instead (checks the setup)
#
# Needs Docker and Harbor (`uv tool install harbor`), plus ANTHROPIC_API_KEY or
# CLAUDE_CODE_OAUTH_TOKEN for the agent arms. An organisation-level key also
# needs ANTHROPIC_WORKSPACE_ID. Results land in
# ${DEX_BENCH_JOBS_DIR:-~/.dex/bench/jobs}; `harbor view jobs -o <dir>` browses them.
# See docs/benchmarks.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Everything runs inside main, which bash parses whole before it starts. A
# screen runs for hours, and bash reads a script file as it executes it, so an
# edit to this file mid-run would otherwise change what the rest of it does.
main() {

AGENT="both"
DATASET="terminal-bench-sample@2.0"
MODEL="anthropic/claude-sonnet-5-5"
N_TASKS=""
TASK_GLOBS=()
CONCURRENCY=1
ATTEMPTS=1
TIMEOUT_MULTIPLIER=1
SETUP_TIMEOUT_MULTIPLIER=3
STAMP=""
EFFORT=""
REVIEW_TIER=""
FAILED_IN=""
PASSED_IN=""
SAMPLE=""
ONE_AT_A_TIME=0
PRUNE_IMAGES=0
ORACLE=0
EXTRA_ARGS=()
JOBS_DIR="${DEX_BENCH_JOBS_DIR:-$HOME/.dex/bench/jobs}"

usage() {
  sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'
}

require_value() {
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    printf 'run.sh: %s requires a value\n' "$1" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) require_value "$@"; AGENT="$2"; shift 2 ;;
    --dataset) require_value "$@"; DATASET="$2"; shift 2 ;;
    --model) require_value "$@"; MODEL="$2"; shift 2 ;;
    --tasks) require_value "$@"; N_TASKS="$2"; shift 2 ;;
    --task) require_value "$@"; TASK_GLOBS+=("$2"); shift 2 ;;
    --concurrency) require_value "$@"; CONCURRENCY="$2"; shift 2 ;;
    --attempts) require_value "$@"; ATTEMPTS="$2"; shift 2 ;;
    --timeout-multiplier) require_value "$@"; TIMEOUT_MULTIPLIER="$2"; shift 2 ;;
    --setup-timeout-multiplier) require_value "$@"; SETUP_TIMEOUT_MULTIPLIER="$2"; shift 2 ;;
    --stamp) require_value "$@"; STAMP="$2"; shift 2 ;;
    --effort) require_value "$@"; EFFORT="$2"; shift 2 ;;
    --review-tier) require_value "$@"; REVIEW_TIER="$2"; shift 2 ;;
    --failed-in) require_value "$@"; FAILED_IN="$2"; shift 2 ;;
    --passed-in) require_value "$@"; PASSED_IN="$2"; shift 2 ;;
    --sample) require_value "$@"; SAMPLE="$2"; shift 2 ;;
    --task-file)
      require_value "$@"
      [[ -f "$2" ]] || { printf 'run.sh: no such task file: %s\n' "$2" >&2; exit 1; }
      while IFS= read -r line; do
        line="${line%%#*}"; line="${line//[[:space:]]/}"
        [[ -n "$line" ]] && TASK_GLOBS+=("$line")
      done < "$2"
      shift 2 ;;
    --one-at-a-time) ONE_AT_A_TIME=1; shift ;;
    --prune-images) PRUNE_IMAGES=1; shift ;;
    --oracle) ORACLE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; EXTRA_ARGS=("$@"); break ;;
    *) printf 'run.sh: unknown option %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$AGENT" in
  both) AGENT="claude-code,dex" ;;
  all) AGENT="claude-code,dex,dex-noplan,dex-noreview,dex-implement" ;;
esac
IFS=',' read -r -a ARMS <<< "$AGENT"
for arm in "${ARMS[@]}"; do
  case "$arm" in
    claude-code|dex|dex-noplan|dex-noreview|dex-implement) ;;
    *) printf 'run.sh: unknown arm %s\n' "$arm" >&2; exit 1 ;;
  esac
done

command -v harbor >/dev/null 2>&1 || {
  printf 'run.sh: harbor not found; install it with: uv tool install harbor\n' >&2
  exit 1
}
docker info >/dev/null 2>&1 || {
  printf 'run.sh: Docker is not running\n' >&2
  exit 1
}
if [[ "$ORACLE" -eq 0 && -z "${ANTHROPIC_API_KEY:-}" && -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  printf 'run.sh: set ANTHROPIC_API_KEY (or CLAUDE_CODE_OAUTH_TOKEN) for the agent arms\n' >&2
  exit 1
fi

# Task images are x86_64. On Apple Silicon, Docker has to be told to emulate,
# or SWE-bench's Dockerfile builds fail to resolve their base image.
if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
  export DOCKER_DEFAULT_PLATFORM="${DOCKER_DEFAULT_PLATFORM:-linux/amd64}"
fi

# Harbor forwards the host's ANTHROPIC_BASE_URL into the task container. On a
# machine routed through the Dex router that is a loopback address, which
# means nothing inside the container, so both arms would fail to connect.
# Set DEX_BENCH_BASE_URL to point the containers at a reachable endpoint.
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
if [[ -n "${DEX_BENCH_BASE_URL:-}" ]]; then
  export ANTHROPIC_BASE_URL="$DEX_BENCH_BASE_URL"
fi

# A screening job's results become this run's task list.
add_tasks_from() { # <failed|passed> <job> [sample]
  local kind="$1" job="$2" sample="${3:-}" task found=0
  [[ -d "$job" ]] || job="$JOBS_DIR/$job"
  [[ -d "$job" ]] || { printf 'run.sh: no such job: %s\n' "$2" >&2; exit 1; }
  while IFS= read -r task; do
    [[ -n "$task" ]] || continue
    TASK_GLOBS+=("$task")
    found=$((found + 1))
  done < <(python3 "$SCRIPT_DIR/compare.py" --tasks "$kind" "$job" ${sample:+--sample "$sample"})
  printf 'run.sh: %d %s task(s) from %s\n' "$found" "$kind" "$(basename "$job")"
}
if [[ -n "$FAILED_IN" ]]; then
  add_tasks_from failed "$FAILED_IN"
fi
if [[ -n "$PASSED_IN" ]]; then
  add_tasks_from passed "$PASSED_IN" "$SAMPLE"
fi
if [[ ( -n "$FAILED_IN" || -n "$PASSED_IN" ) && ${#TASK_GLOBS[@]} -eq 0 ]]; then
  printf 'run.sh: the selected jobs contribute no tasks; nothing to run\n' >&2
  exit 1
fi

mkdir -p "$JOBS_DIR"
[[ -n "$STAMP" ]] || STAMP=$(date +%Y%m%d-%H%M%S)
DATASET_SLUG="${DATASET//[^A-Za-z0-9._-]/-}"

if [[ "$ONE_AT_A_TIME" -eq 1 && ${#TASK_GLOBS[@]} -eq 0 ]]; then
  printf 'run.sh: --one-at-a-time needs named tasks (--task, --task-file, --failed-in or --passed-in)\n' >&2
  exit 1
fi

base_args=(-d "$DATASET" -o "$JOBS_DIR" -n "$CONCURRENCY" -k "$ATTEMPTS"
  --agent-timeout-multiplier "$TIMEOUT_MULTIPLIER"
  --agent-setup-timeout-multiplier "$SETUP_TIMEOUT_MULTIPLIER" -y)
common_args=("${base_args[@]}")
[[ -n "$N_TASKS" ]] && common_args+=(-l "$N_TASKS")
for glob in ${TASK_GLOBS[@]+"${TASK_GLOBS[@]}"}; do
  common_args+=(-i "$glob")
done

# Task images are several GB each and Docker keeps every one it pulls. Remove
# what a finished job used: the task's base and prebuilt images, read from
# Harbor's task cache, and Harbor's own hb__ builds. Nothing else is touched,
# and `docker rmi` without -f refuses an image a container still uses.
prune_task_images() { # [task...]
  local image used
  local -a images=()
  while IFS= read -r image; do
    [[ -n "$image" ]] && images+=("$image")
  done < <(python3 "$SCRIPT_DIR/task_images.py" "$@")
  while IFS= read -r image; do
    [[ -n "$image" ]] && images+=("$image")
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' | awk '/^hb__/')
  used=$(docker ps -a --format '{{.Image}}')
  for image in ${images[@]+"${images[@]}"}; do
    grep -qxF "$image" <<< "$used" && continue
    docker rmi "$image" >/dev/null 2>&1 && printf 'run.sh: removed image %s\n' "$image"
  done
  return 0
}

# Did this job's verifier run? A trial that errored or was stopped before
# verification has no reward, and says nothing about the agent.
job_verified() { # <job_dir>
  python3 - "$1" <<'PY'
import glob
import json
import sys

for path in glob.glob(sys.argv[1] + "/*/result.json"):
    with open(path, encoding="utf-8") as handle:
        if (json.load(handle).get("verifier_result") or {}).get("rewards"):
            sys.exit(0)
sys.exit(1)
PY
}

run_arm() { # <label> <harbor agent args...>
  local label="$1"
  shift
  local job_name="${DATASET_SLUG}-${label}-${STAMP}" task arm_status=0
  if [[ "$ONE_AT_A_TIME" -eq 0 ]]; then
    printf '\n==> %s: %s (job %s)\n' "$label" "$DATASET" "$job_name"
    PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" harbor run \
      "${common_args[@]}" --job-name "$job_name" "$@" \
      ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} || arm_status=$?
    [[ "$PRUNE_IMAGES" -eq 1 ]] && prune_task_images ${TASK_GLOBS[@]+"${TASK_GLOBS[@]}"}
    return "$arm_status"
  fi
  # One job per task, named <run>--<task>; compare.py merges them back into
  # one run. A failed or cancelled task does not stop the ones after it.
  for task in "${TASK_GLOBS[@]}"; do
    local job_dir="$JOBS_DIR/${job_name}--${task}"
    if [[ -d "$job_dir" ]]; then
      if job_verified "$job_dir"; then
        printf 'run.sh: %s already has a verified result; skipping\n' "$task"
        continue
      fi
      # An earlier attempt at this run errored or was stopped: start it again.
      command rm -rf "$job_dir"
    fi
    printf '\n==> %s: %s (job %s--%s)\n' "$label" "$DATASET" "$job_name" "$task"
    PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" harbor run \
      "${base_args[@]}" -i "$task" --job-name "${job_name}--${task}" "$@" \
      ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} || arm_status=$?
    [[ "$PRUNE_IMAGES" -eq 1 ]] && prune_task_images "$task"
  done
  return "$arm_status"
}

if [[ "$ORACLE" -eq 1 ]]; then
  run_arm oracle -a oracle
  return 0
fi

agent_args=(-m "$MODEL")
[[ -n "$EFFORT" ]] && agent_args+=(--ak "reasoning_effort=$EFFORT")
# An organisation-level API key is rejected unless each request names the
# workspace to bill. Claude Code sends extra headers from this variable.
if [[ -n "${ANTHROPIC_WORKSPACE_ID:-}" ]]; then
  agent_args+=(--ae "ANTHROPIC_CUSTOM_HEADERS=anthropic-workspace-id: $ANTHROPIC_WORKSPACE_ID")
fi

dex_args=()
[[ -n "$REVIEW_TIER" ]] && dex_args+=(--ak "review_tier=$REVIEW_TIER")

status=0
for arm in "${ARMS[@]}"; do
  case "$arm" in
    claude-code) run_arm claude-code -a claude-code "${agent_args[@]}" || status=$? ;;
    dex) phases="plan,implement,review" ;;
    dex-noplan) phases="implement,review" ;;
    dex-noreview) phases="plan,implement" ;;
    dex-implement) phases="implement" ;;
  esac
  if [[ "$arm" == dex* ]]; then
    run_arm "$arm" -a dex_agent:DexAgent --ak "phases=$phases" \
      "${agent_args[@]}" ${dex_args[@]+"${dex_args[@]}"} || status=$?
  fi
done

printf '\nJobs: %s\nBrowse: harbor view jobs -o %s\nCompare: python3 %s/compare.py %s\n' \
  "$JOBS_DIR" "$JOBS_DIR" "$SCRIPT_DIR" "$JOBS_DIR"
return "$status"
}

main "$@"
exit $?

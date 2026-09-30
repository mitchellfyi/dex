#!/usr/bin/env bash
# Run a public benchmark through Harbor with Dex, the Claude Code baseline, or both.
#
# Usage:
#   research/harbor/run.sh [options] [-- extra harbor run args]
#
#   --agent dex|claude-code|both   Which arm to run (default: both)
#   --dataset NAME@VERSION         Harbor dataset (default: terminal-bench-sample@2.0)
#   --model MODEL                  Model for both arms (default: anthropic/claude-sonnet-5-5)
#   --tasks N                      Run the first N tasks (harbor -l)
#   --task GLOB                    Run tasks matching GLOB (harbor -i, repeatable)
#   --concurrency N                Trials at once (default: 1)
#   --attempts K                   Attempts per task (default: 1)
#   --timeout-multiplier X         Agent timeout multiplier for both arms (default: 1)
#   --effort LEVEL                 low|medium|high|xhigh|max for both arms
#   --failed-in JOB                Add the tasks JOB failed (a screening run)
#   --passed-in JOB                Add the tasks JOB passed
#   --sample N                     Take N of the --passed-in tasks (fixed seed)
#   --oracle                       Run the reference solutions instead (checks the setup)
#
# Needs Docker and Harbor (`uv tool install harbor`), plus ANTHROPIC_API_KEY or
# CLAUDE_CODE_OAUTH_TOKEN for the agent arms. An organisation-level key also
# needs ANTHROPIC_WORKSPACE_ID. Results land in
# ${DEX_BENCH_JOBS_DIR:-~/.dex/bench/jobs}; `harbor view jobs -o <dir>` browses them.
# See docs/benchmarks.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGENT="both"
DATASET="terminal-bench-sample@2.0"
MODEL="anthropic/claude-sonnet-5-5"
N_TASKS=""
TASK_GLOBS=()
CONCURRENCY=1
ATTEMPTS=1
TIMEOUT_MULTIPLIER=1
EFFORT=""
FAILED_IN=""
PASSED_IN=""
SAMPLE=""
ORACLE=0
EXTRA_ARGS=()
JOBS_DIR="${DEX_BENCH_JOBS_DIR:-$HOME/.dex/bench/jobs}"

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
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
    --effort) require_value "$@"; EFFORT="$2"; shift 2 ;;
    --failed-in) require_value "$@"; FAILED_IN="$2"; shift 2 ;;
    --passed-in) require_value "$@"; PASSED_IN="$2"; shift 2 ;;
    --sample) require_value "$@"; SAMPLE="$2"; shift 2 ;;
    --oracle) ORACLE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; EXTRA_ARGS=("$@"); break ;;
    *) printf 'run.sh: unknown option %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$AGENT" in
  dex|claude-code|both) ;;
  *) printf 'run.sh: --agent must be dex, claude-code or both\n' >&2; exit 1 ;;
esac

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
STAMP=$(date +%Y%m%d-%H%M%S)
DATASET_SLUG="${DATASET//[^A-Za-z0-9._-]/-}"

common_args=(-d "$DATASET" -o "$JOBS_DIR" -n "$CONCURRENCY" -k "$ATTEMPTS"
  --agent-timeout-multiplier "$TIMEOUT_MULTIPLIER" -y)
[[ -n "$N_TASKS" ]] && common_args+=(-l "$N_TASKS")
for glob in ${TASK_GLOBS[@]+"${TASK_GLOBS[@]}"}; do
  common_args+=(-i "$glob")
done

run_arm() { # <label> <harbor agent args...>
  local label="$1"
  shift
  local job_name="${DATASET_SLUG}-${label}-${STAMP}"
  printf '\n==> %s: %s (job %s)\n' "$label" "$DATASET" "$job_name"
  PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" harbor run \
    "${common_args[@]}" --job-name "$job_name" "$@" \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
}

if [[ "$ORACLE" -eq 1 ]]; then
  run_arm oracle -a oracle
  exit 0
fi

agent_args=(-m "$MODEL")
[[ -n "$EFFORT" ]] && agent_args+=(--ak "reasoning_effort=$EFFORT")
# An organisation-level API key is rejected unless each request names the
# workspace to bill. Claude Code sends extra headers from this variable.
if [[ -n "${ANTHROPIC_WORKSPACE_ID:-}" ]]; then
  agent_args+=(--ae "ANTHROPIC_CUSTOM_HEADERS=anthropic-workspace-id: $ANTHROPIC_WORKSPACE_ID")
fi

status=0
if [[ "$AGENT" == "claude-code" || "$AGENT" == "both" ]]; then
  run_arm claude-code -a claude-code "${agent_args[@]}" || status=$?
fi
if [[ "$AGENT" == "dex" || "$AGENT" == "both" ]]; then
  run_arm dex -a dex_agent:DexAgent "${agent_args[@]}" || status=$?
fi

printf '\nJobs: %s\nBrowse: harbor view jobs -o %s\nCompare: python3 %s/compare.py %s\n' \
  "$JOBS_DIR" "$JOBS_DIR" "$SCRIPT_DIR" "$JOBS_DIR"
exit "$status"

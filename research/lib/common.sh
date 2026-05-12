#!/usr/bin/env bash
# Research harness — shared library
# Sourced by all harness scripts. Provides logging, path helpers, and loads config.

set -euo pipefail

# Source config if not already loaded
if [[ -z "${RESEARCH_DIR:-}" ]]; then
  # shellcheck source=research/config.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"
fi

# ── Logging ────────────────────────────────────────────────────────────────
_log() {
  local level="$1" color="$2"
  shift 2
  printf '%b[%s]%b %s\n' "$color" "$level" '\033[0m' "$*" >&2
}

log_info()    { _log "INFO"    '\033[0;36m' "$@"; }
log_success() { _log "OK"      '\033[0;32m' "$@"; }
log_warn()    { _log "WARN"    '\033[0;33m' "$@"; }
log_error()   { _log "ERROR"   '\033[0;31m' "$@"; }
log_step()    { _log "STEP"    '\033[0;35m' "$@"; }

# ── Path helpers ───────────────────────────────────────────────────────────

# Generate a timestamped run ID
run_id() {
  echo "run-$(date +%Y%m%d-%H%M%S)"
}

# Path to a scenario directory
scenario_dir() {
  echo "$SCENARIOS_DIR/$1"
}

# Scenario names are path components used under scenarios/, workspaces/, and
# results/. Keep them as basenames so user input cannot escape those roots.
scenario_name_valid() {
  local name="${1:-}"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]
}

scenario_name_require_valid() {
  local name="${1:-}"
  if scenario_name_valid "$name"; then
    return 0
  fi
  log_error "Invalid scenario name: $name"
  return 1
}

# Path to a workspace for a given scenario
workspace_dir() {
  echo "$WORKSPACES_DIR/$1"
}

# Path to a run's result directory
run_result_dir() {
  echo "$RESULTS_DIR/$1"
}

# Path to a scenario's result within a run
scenario_result_dir() {
  local run="$1" scenario="$2"
  echo "$RESULTS_DIR/$run/$scenario"
}

# ── Scenario discovery ─────────────────────────────────────────────────────

# List all scenario names (directories under scenarios/ excluding _template)
list_scenarios() {
  local dir
  for dir in "$SCENARIOS_DIR"/*/; do
    local name
    name=$(basename "$dir")
    [[ "$name" == "_template" ]] && continue
    [[ -f "$dir/prompt.md" ]] || continue
    echo "$name"
  done
}

# ── JSON helpers (no external deps) ────────────────────────────────────────

# Read a field from a simple JSON file (no nested objects)
# Usage: json_field file.json "key"
json_field() {
  local file="$1" key="$2"
  _JF_FILE="$file" _JF_KEY="$key" python3 -c "
import json, sys, os
with open(os.environ['_JF_FILE']) as f:
    d = json.load(f)
print(d.get(os.environ['_JF_KEY'], ''))
" 2>/dev/null || echo ""
}

# Write a JSON object to a file
# Usage: json_write file.json '{"key": "value"}'
json_write() {
  local file="$1" content="$2"
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
with open('$file', 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
" "$content"
}

# ── Git helpers ────────────────────────────────────────────────────────────

# Current DK commit hash (short)
dk_commit_hash() {
  git -C "$DOYAKEN_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

# Current branch name
dk_branch() {
  git -C "$DOYAKEN_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
}

# Check if on main/master (safety check)
is_main_branch() {
  local branch
  branch=$(dk_branch)
  [[ "$branch" == "main" || "$branch" == "master" ]]
}

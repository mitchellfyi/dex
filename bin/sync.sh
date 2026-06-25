#!/usr/bin/env bash
# shellcheck disable=SC1091
# dex sync - refresh project context and repo memory from current evidence.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

SYNC_PROVIDER_SESSION_ID=""
SYNC_RUN_SESSION_ID=""
SYNC_RUN_ID=""
__dx_sync_cleanup() {
  local status=$?
  if [[ -n "${SYNC_RUN_ID:-}" ]]; then
    if [[ $status -eq 0 ]]; then
      dx_event_emit_safe "$SYNC_RUN_ID" "run.completed" "info" "Dex sync completed" "" "{\"command\":\"dx sync\"}"
      dx_run_log_append_safe "$SYNC_RUN_ID" "info" "sync" "Dex sync completed"
      dx_run_write_summary_safe "$SYNC_RUN_ID" "completed" "Dex sync completed"
    elif [[ $status -eq 130 ]]; then
      dx_event_emit_safe "$SYNC_RUN_ID" "run.blocked" "warn" "Dex sync interrupted" "" "{\"command\":\"dx sync\",\"exit_code\":${status}}"
      dx_run_log_append_safe "$SYNC_RUN_ID" "warn" "sync" "Dex sync interrupted"
      dx_run_write_summary_safe "$SYNC_RUN_ID" "blocked" "Dex sync interrupted"
    else
      dx_event_emit_safe "$SYNC_RUN_ID" "run.failed" "error" "Dex sync failed" "" "{\"command\":\"dx sync\",\"exit_code\":${status}}"
      dx_run_log_append_safe "$SYNC_RUN_ID" "error" "sync" "Dex sync failed with code ${status}"
      dx_run_write_summary_safe "$SYNC_RUN_ID" "failed" "Dex sync failed with code ${status}"
    fi
  fi
  if [[ -n "${SYNC_PROVIDER_SESSION_ID:-}" ]]; then
    dx_provider_cleanup_session_state "$SYNC_PROVIDER_SESSION_ID" 2>/dev/null || true
  fi
}
trap __dx_sync_cleanup EXIT
trap 'printf "\nInterrupted.\n"; exit 130' INT

usage() {
  cat <<'USAGE'
Usage: dx sync [options]

Refresh Dex project context and repo memory in .dex/.

Options:
  --dry-run                         Explain proposed changes without writing files
  --state-dir <path>                Read raw observations/episodes from this directory
  --since <ref|date>                Limit repository/review-history scanning
  --budget-minutes <n>              Maximum provider runtime (default: 60)
  --no-pr                           Do not create or update a PR
  --trace-retrieval <prompt|path>   Explain which memories would load
  --phase <phase>                   Phase for retrieval tracing
  --include-working-tree            Allow uncommitted changes as promotion evidence
  -h, --help                        Show this help
USAGE
}

__dx_sync_project_context_complete() {
  local root="$1"

  if [[ ! -f "$root/.dex/dex.md" ]] || ! grep -q '^## Tech Stack' "$root/.dex/dex.md" 2>/dev/null; then
    return 1
  fi

  if [[ ! -d "$root/.dex/rules" ]] || [[ -z "$(find "$root/.dex/rules" -maxdepth 1 -type f -name '*.md' -print -quit 2>/dev/null)" ]]; then
    return 1
  fi

  return 0
}

DRY_RUN=0
NO_PR=0
STATE_DIR=""
SINCE=""
TRACE_RETRIEVAL=""
PHASE=""
INCLUDE_WORKING_TREE=0
SYNC_BUDGET_MINUTES="${DEX_SYNC_BUDGET_MINUTES:-60}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-pr)
      NO_PR=1
      shift
      ;;
    --state-dir)
      [[ $# -ge 2 ]] || { dx_error "--state-dir requires a path"; exit 1; }
      STATE_DIR="$2"
      shift 2
      ;;
    --since)
      [[ $# -ge 2 ]] || { dx_error "--since requires a ref or date"; exit 1; }
      SINCE="$2"
      shift 2
      ;;
    --budget-minutes)
      [[ $# -ge 2 ]] || { dx_error "--budget-minutes requires a positive integer"; exit 1; }
      if [[ ! "$2" =~ ^[0-9]+$ ]]; then
        dx_error "--budget-minutes requires a positive integer"
        exit 1
      fi
      SYNC_BUDGET_MINUTES="$2"
      shift 2
      ;;
    --trace-retrieval)
      [[ $# -ge 2 ]] || { dx_error "--trace-retrieval requires a prompt or path"; exit 1; }
      TRACE_RETRIEVAL="$2"
      shift 2
      ;;
    --phase)
      [[ $# -ge 2 ]] || { dx_error "--phase requires a phase"; exit 1; }
      PHASE="$2"
      shift 2
      ;;
    --include-working-tree)
      INCLUDE_WORKING_TREE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      dx_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

READ_ONLY=0
if [[ "$DRY_RUN" -eq 1 || -n "$TRACE_RETRIEVAL" ]]; then
  READ_ONLY=1
fi

if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  repo_root=""
fi
if [[ -z "$repo_root" ]]; then
  dx_error "Not in a git repository."
  exit 1
fi

repo_name=$(basename "$repo_root")
echo "Dex - Sync: $repo_name"
echo ""

SYNC_RUN_SESSION_ID="sync-$(dx_unique_session_id)"
if SYNC_RUN_ID=$(dx_run_prepare "$SYNC_RUN_SESSION_ID" "$repo_root" "current-checkout" "$repo_name" "dx sync $*" "dx sync"); then
  export DEX_RUN_ID="$SYNC_RUN_ID"
  dx_run_maybe_emit_started "$SYNC_RUN_ID" "Dex sync started" "{\"command\":\"dx sync\"}"
  dx_run_log_append_safe "$SYNC_RUN_ID" "info" "sync" "Dex sync started for ${repo_name}"
  dx_info "Run id: $SYNC_RUN_ID"
else
  dx_warn "Continuing without a local Dex run journal."
  SYNC_RUN_ID=""
fi

if [[ "$READ_ONLY" -eq 1 ]]; then
  if ! dx_bootstrap_agent_tooling "$repo_root" "check"; then
    dx_warn "Read-only sync found Claude/Codex tooling drift; run 'dx sync' or 'dx tools bootstrap' to reinstall it."
  fi
else
  dx_install_repo_attribution "$repo_root"
  if ! dx_bootstrap_agent_tooling "$repo_root" "install"; then
    dx_warn "Continuing sync without complete Claude/Codex tooling bootstrap"
  fi
fi

BASELINE_ANALYSIS_RAN=0
if [[ ! -d "$repo_root/.dex" ]]; then
  if [[ "$READ_ONLY" -eq 1 ]]; then
    dx_info "No .dex/ directory found; read-only sync will report the missing scaffold"
  else
    dx_info "No .dex/ directory found; running baseline project analysis first"
    DEX_SKIP_TOOL_BOOTSTRAP=1 bash "$DEX_DIR/bin/init.sh" --skip-config
    BASELINE_ANALYSIS_RAN=1
  fi
fi

if [[ "$READ_ONLY" -eq 0 && "$BASELINE_ANALYSIS_RAN" -eq 0 ]]; then
  if ! __dx_sync_project_context_complete "$repo_root"; then
    dx_info "Dex project context is incomplete; running baseline project analysis first"
    DEX_SKIP_TOOL_BOOTSTRAP=1 bash "$DEX_DIR/bin/init.sh" --skip-config
    BASELINE_ANALYSIS_RAN=1
  fi
fi

if [[ "$READ_ONLY" -eq 0 && "$BASELINE_ANALYSIS_RAN" -eq 1 ]] && ! __dx_sync_project_context_complete "$repo_root"; then
  dx_warn "Baseline project analysis did not produce complete .dex context; sync will continue with available files."
  dx_info "Re-run 'dx init --skip-config' after resolving provider or tooling issues."
fi

if [[ ! -f "$repo_root/.dex/memory/index.md" ]]; then
  if [[ "$READ_ONLY" -eq 1 ]]; then
    dx_info "Read-only sync would create .dex/memory/index.md"
  else
    mkdir -p "$repo_root/.dex/memory/domains"
    memory_index="$repo_root/.dex/memory/index.md"
    cat > "${memory_index}.tmp" <<'MEMORYINDEX'
# Dex Memory Index

No durable repo memory has been promoted yet.

Run `/dxsync` or `dx sync` after repeated review comments, CI failures,
maintenance runs, or durable workflow lessons create evidence worth preserving.

## Domains

| Domain | File | Loads For | Status |
|--------|------|-----------|--------|
MEMORYINDEX
    mv "${memory_index}.tmp" "$memory_index"
    dx_done "Created .dex/memory/index.md"
  fi
fi

if ! command -v claude >/dev/null 2>&1; then
  dx_error "Claude Code CLI not found. Run /dxsync inside an agent session, or install Claude Code CLI."
  exit 1
fi

dx_info "Preparing DXSync provider session"
dx_provider_apply
sync_prompt=$(cat "$DEX_DIR/prompts/sync-memory.md")
provider_prompt=$(dx_provider_prompt)
invocation=$(cat <<EOF

# DXSync Invocation

Repo: $repo_root
Dry run: $DRY_RUN
No PR: $NO_PR
State dir: ${STATE_DIR:-N/A}
Since: ${SINCE:-N/A}
Budget minutes: $SYNC_BUDGET_MINUTES
Trace retrieval: ${TRACE_RETRIEVAL:-N/A}
Phase: ${PHASE:-N/A}
Include working tree evidence: $INCLUDE_WORKING_TREE

Follow the DXSync Memory Refresh prompt above. If Dry run is 1 or Trace
retrieval is not N/A, do not modify files.
EOF
)

SYNC_PROVIDER_SESSION_ID="${SYNC_RUN_SESSION_ID:-sync-$(dx_unique_session_id)}"
dx_provider_cleanup_session_state "$SYNC_PROVIDER_SESSION_ID"

sync_status_before=$(git -C "$repo_root" status --porcelain=v1 -- .dex 2>/dev/null || true)
budget_seconds=0
if [[ "$SYNC_BUDGET_MINUTES" =~ ^[0-9]+$ && "$SYNC_BUDGET_MINUTES" -gt 0 ]]; then
  budget_seconds=$((SYNC_BUDGET_MINUTES * 60))
fi

model_flags=()
if [[ -n "${DX_CLAUDE_MODEL:-}" ]]; then
  model_flags+=(--model "$DX_CLAUDE_MODEL")
fi
if [[ -n "${DX_CLAUDE_EFFORT:-}" ]]; then
  model_flags+=(--effort "$DX_CLAUDE_EFFORT")
fi

dx_info "Launching provider: ${DX_PROVIDER_PROFILE_RESOLVED:-unknown} (${DX_PROVIDER_ENGINE:-unknown}), model ${DX_CLAUDE_MODEL:-session default}, effort ${DX_CLAUDE_EFFORT:-session default}"
dx_info "Session id: $SYNC_PROVIDER_SESSION_ID"
dx_info "Re-analyzing current project context, rules, guards, and scoped memory."
dx_info "Large repos may be quiet while the provider reads context; timeout is ${SYNC_BUDGET_MINUTES} minute(s)."

set +e
set +o pipefail
DEX_SESSION_ID="$SYNC_PROVIDER_SESSION_ID" DEX_RUN_ID="${SYNC_RUN_ID:-}" DX_RUN_ROOT="$DX_RUN_ROOT" dx_run_with_timeout "$budget_seconds" dx_provider_claude -p "${sync_prompt}${provider_prompt}${invocation}" \
  ${model_flags[@]+"${model_flags[@]}"} \
  --dangerously-skip-permissions --permission-mode bypassPermissions \
  --verbose --output-format stream-json --include-partial-messages \
  | dx_progress_filter \
  | dx_run_log_tee "${SYNC_RUN_ID:-}" "sync-provider"
CLAUDE_EXIT=${PIPESTATUS[0]}
set -o pipefail
set -e
echo ""

dx_provider_cleanup_session_state "$SYNC_PROVIDER_SESSION_ID"
SYNC_PROVIDER_SESSION_ID=""

if [[ $CLAUDE_EXIT -ne 0 ]]; then
  if [[ $CLAUDE_EXIT -eq 124 ]]; then
    dx_error "Sync exceeded budget of ${SYNC_BUDGET_MINUTES} minute(s)."
  else
    dx_error "Sync exited with code $CLAUDE_EXIT."
  fi
  exit "$CLAUDE_EXIT"
fi

sync_status_after=$(git -C "$repo_root" status --porcelain=v1 -- .dex 2>/dev/null || true)
if [[ "$READ_ONLY" -eq 1 ]]; then
  dx_info "Read-only sync complete; no file changes were expected."
elif [[ "$sync_status_before" == "$sync_status_after" ]]; then
  dx_skip "No project context, rule, guard, or durable memory changes were promoted."
  dx_info "This is normal when DXSync finds no verified drift or repo-wide lesson worth saving."
else
  dx_info "Dex context changes after sync:"
  git -C "$repo_root" status --short -- .dex | sed 's/^/  /'
fi

echo ""
if [[ "$READ_ONLY" -eq 0 ]]; then
  dx_dexcode_sync_project_context "$repo_root"
fi

echo ""
dx_done "Sync complete for: $repo_name"

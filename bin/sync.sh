#!/usr/bin/env bash
# shellcheck disable=SC1091
# doyaken sync - refresh project context and repo memory from current evidence.
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

SYNC_PROVIDER_SESSION_ID=""
__dk_sync_cleanup() {
  if [[ -n "${SYNC_PROVIDER_SESSION_ID:-}" ]]; then
    dk_provider_cleanup_session_state "$SYNC_PROVIDER_SESSION_ID" 2>/dev/null || true
  fi
}
trap __dk_sync_cleanup EXIT
trap 'printf "\nInterrupted.\n"; exit 130' INT

usage() {
  cat <<'USAGE'
Usage: dk sync [options]

Refresh Doyaken project context and repo memory in .doyaken/.

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

__dk_sync_project_context_complete() {
  local root="$1"

  if [[ ! -f "$root/.doyaken/doyaken.md" ]] || ! grep -q '^## Tech Stack' "$root/.doyaken/doyaken.md" 2>/dev/null; then
    return 1
  fi

  if [[ ! -d "$root/.doyaken/rules" ]] || [[ -z "$(find "$root/.doyaken/rules" -maxdepth 1 -type f -name '*.md' -print -quit 2>/dev/null)" ]]; then
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
SYNC_BUDGET_MINUTES="${DOYAKEN_SYNC_BUDGET_MINUTES:-60}"

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
      [[ $# -ge 2 ]] || { dk_error "--state-dir requires a path"; exit 1; }
      STATE_DIR="$2"
      shift 2
      ;;
    --since)
      [[ $# -ge 2 ]] || { dk_error "--since requires a ref or date"; exit 1; }
      SINCE="$2"
      shift 2
      ;;
    --budget-minutes)
      [[ $# -ge 2 ]] || { dk_error "--budget-minutes requires a positive integer"; exit 1; }
      if [[ ! "$2" =~ ^[0-9]+$ ]]; then
        dk_error "--budget-minutes requires a positive integer"
        exit 1
      fi
      SYNC_BUDGET_MINUTES="$2"
      shift 2
      ;;
    --trace-retrieval)
      [[ $# -ge 2 ]] || { dk_error "--trace-retrieval requires a prompt or path"; exit 1; }
      TRACE_RETRIEVAL="$2"
      shift 2
      ;;
    --phase)
      [[ $# -ge 2 ]] || { dk_error "--phase requires a phase"; exit 1; }
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
      dk_error "Unknown option: $1"
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
  dk_error "Not in a git repository."
  exit 1
fi

repo_name=$(basename "$repo_root")
echo "Doyaken - Sync: $repo_name"
echo ""

if [[ "$READ_ONLY" -eq 1 ]]; then
  if ! dk_bootstrap_agent_tooling "$repo_root" "check"; then
    dk_warn "Read-only sync found Claude/Codex tooling drift; run 'dk sync' or 'dk tools bootstrap' to repair it."
  fi
else
  if ! dk_bootstrap_agent_tooling "$repo_root" "repair"; then
    dk_warn "Continuing sync without complete Claude/Codex tooling bootstrap"
  fi
fi

BASELINE_ANALYSIS_RAN=0
if [[ ! -d "$repo_root/.doyaken" ]]; then
  if [[ "$READ_ONLY" -eq 1 ]]; then
    dk_info "No .doyaken/ directory found; read-only sync will report the missing scaffold"
  else
    dk_info "No .doyaken/ directory found; running baseline project analysis first"
    DOYAKEN_SKIP_TOOL_BOOTSTRAP=1 bash "$DOYAKEN_DIR/bin/init.sh" --skip-config
    BASELINE_ANALYSIS_RAN=1
  fi
fi

if [[ "$READ_ONLY" -eq 0 && "$BASELINE_ANALYSIS_RAN" -eq 0 ]]; then
  if ! __dk_sync_project_context_complete "$repo_root"; then
    dk_info "Doyaken project context is incomplete; running baseline project analysis first"
    DOYAKEN_SKIP_TOOL_BOOTSTRAP=1 bash "$DOYAKEN_DIR/bin/init.sh" --skip-config
    BASELINE_ANALYSIS_RAN=1
  fi
fi

if [[ "$READ_ONLY" -eq 0 && "$BASELINE_ANALYSIS_RAN" -eq 1 ]] && ! __dk_sync_project_context_complete "$repo_root"; then
  dk_warn "Baseline project analysis did not produce complete .doyaken context; sync will continue with available files."
  dk_info "Re-run 'dk init --skip-config' after resolving provider or tooling issues."
fi

if [[ ! -f "$repo_root/.doyaken/memory/index.md" ]]; then
  if [[ "$READ_ONLY" -eq 1 ]]; then
    dk_info "Read-only sync would create .doyaken/memory/index.md"
  else
    mkdir -p "$repo_root/.doyaken/memory/domains"
    memory_index="$repo_root/.doyaken/memory/index.md"
    cat > "${memory_index}.tmp" <<'MEMORYINDEX'
# Doyaken Memory Index

No durable repo memory has been promoted yet.

Run `/dksync` or `dk sync` after repeated review comments, CI failures,
maintenance runs, or durable workflow lessons create evidence worth preserving.

## Domains

| Domain | File | Loads For | Status |
|--------|------|-----------|--------|
MEMORYINDEX
    mv "${memory_index}.tmp" "$memory_index"
    dk_done "Created .doyaken/memory/index.md"
  fi
fi

if ! command -v claude >/dev/null 2>&1; then
  dk_error "Claude Code CLI not found. Run /dksync inside an agent session, or install Claude Code CLI."
  exit 1
fi

dk_info "Preparing DKSync provider session"
dk_provider_apply
sync_prompt=$(cat "$DOYAKEN_DIR/prompts/sync-memory.md")
provider_prompt=$(dk_provider_prompt)
invocation=$(cat <<EOF

# DKSync Invocation

Repo: $repo_root
Dry run: $DRY_RUN
No PR: $NO_PR
State dir: ${STATE_DIR:-N/A}
Since: ${SINCE:-N/A}
Budget minutes: $SYNC_BUDGET_MINUTES
Trace retrieval: ${TRACE_RETRIEVAL:-N/A}
Phase: ${PHASE:-N/A}
Include working tree evidence: $INCLUDE_WORKING_TREE

Follow the DKSync Memory Refresh prompt above. If Dry run is 1 or Trace
retrieval is not N/A, do not modify files.
EOF
)

SYNC_PROVIDER_SESSION_ID="sync-$(dk_unique_session_id)"
dk_provider_cleanup_session_state "$SYNC_PROVIDER_SESSION_ID"

sync_status_before=$(git -C "$repo_root" status --porcelain=v1 -- .doyaken 2>/dev/null || true)
budget_seconds=0
if [[ "$SYNC_BUDGET_MINUTES" =~ ^[0-9]+$ && "$SYNC_BUDGET_MINUTES" -gt 0 ]]; then
  budget_seconds=$((SYNC_BUDGET_MINUTES * 60))
fi

dk_info "Launching provider: ${DK_PROVIDER_PROFILE_RESOLVED:-unknown} (${DK_PROVIDER_ENGINE:-unknown}), model ${DK_CLAUDE_MODEL}, effort ${DK_CLAUDE_EFFORT}"
dk_info "Session id: $SYNC_PROVIDER_SESSION_ID"
dk_info "Re-analyzing current project context, rules, guards, and scoped memory."
dk_info "Large repos may be quiet while the provider reads context; timeout is ${SYNC_BUDGET_MINUTES} minute(s)."

set +e
set +o pipefail
DOYAKEN_SESSION_ID="$SYNC_PROVIDER_SESSION_ID" dk_run_with_timeout "$budget_seconds" dk_provider_claude -p "${sync_prompt}${provider_prompt}${invocation}" \
  --model "$DK_CLAUDE_MODEL" --effort "$DK_CLAUDE_EFFORT" \
  --dangerously-skip-permissions --permission-mode bypassPermissions \
  --verbose --output-format stream-json --include-partial-messages \
  | dk_progress_filter
CLAUDE_EXIT=${PIPESTATUS[0]}
set -o pipefail
set -e
echo ""

dk_provider_cleanup_session_state "$SYNC_PROVIDER_SESSION_ID"
SYNC_PROVIDER_SESSION_ID=""

if [[ $CLAUDE_EXIT -ne 0 ]]; then
  if [[ $CLAUDE_EXIT -eq 124 ]]; then
    dk_error "Sync exceeded budget of ${SYNC_BUDGET_MINUTES} minute(s)."
  else
    dk_error "Sync exited with code $CLAUDE_EXIT."
  fi
  exit "$CLAUDE_EXIT"
fi

sync_status_after=$(git -C "$repo_root" status --porcelain=v1 -- .doyaken 2>/dev/null || true)
if [[ "$READ_ONLY" -eq 1 ]]; then
  dk_info "Read-only sync complete; no file changes were expected."
elif [[ "$sync_status_before" == "$sync_status_after" ]]; then
  dk_skip "No project context, rule, guard, or durable memory changes were promoted."
  dk_info "This is normal when DKSync finds no verified drift or repo-wide lesson worth saving."
else
  dk_info "Doyaken context changes after sync:"
  git -C "$repo_root" status --short -- .doyaken | sed 's/^/  /'
fi

echo ""
dk_done "Sync complete for: $repo_name"

#!/usr/bin/env bash
# shellcheck disable=SC1091
# doyaken sync - refresh repo memory/rules from verified observations.
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

Refresh Doyaken repo memory by promoting verified observations into .doyaken/.

Options:
  --dry-run                         Explain proposed changes without writing files
  --state-dir <path>                Read raw observations/episodes from this directory
  --since <ref|date>                Limit repository/review-history scanning
  --no-pr                           Do not create or update a PR
  --trace-retrieval <prompt|path>   Explain which memories would load
  --phase <phase>                   Phase for retrieval tracing
  --include-working-tree            Allow uncommitted changes as promotion evidence
  -h, --help                        Show this help
USAGE
}

DRY_RUN=0
NO_PR=0
STATE_DIR=""
SINCE=""
TRACE_RETRIEVAL=""
PHASE=""
INCLUDE_WORKING_TREE=0

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

if [[ ! -d "$repo_root/.doyaken" ]]; then
  if [[ "$READ_ONLY" -eq 1 ]]; then
    dk_info "No .doyaken/ directory found; read-only sync will report the missing scaffold"
  else
    dk_info "No .doyaken/ directory found; creating the fresh repo scaffold first"
    bash "$DOYAKEN_DIR/bin/init.sh" --skip-analysis --skip-config
  fi
fi

if [[ ! -f "$repo_root/.doyaken/memory/index.md" ]]; then
  if [[ "$READ_ONLY" -eq 1 ]]; then
    dk_info "Read-only sync would create .doyaken/memory/index.md"
  else
    mkdir -p "$repo_root/.doyaken/memory/domains"
    cat > "$repo_root/.doyaken/memory/index.md" <<'MEMORYINDEX'
# Doyaken Memory Index

No durable repo memory has been promoted yet.

Run `/dksync` or `dk sync` after repeated review comments, CI failures,
maintenance runs, or durable workflow lessons create evidence worth preserving.

## Domains

| Domain | File | Loads For | Status |
|--------|------|-----------|--------|
MEMORYINDEX
    dk_done "Created .doyaken/memory/index.md"
  fi
fi

if ! command -v claude >/dev/null 2>&1; then
  dk_error "Claude Code CLI not found. Run /dksync inside an agent session, or install Claude Code CLI."
  exit 1
fi

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
Trace retrieval: ${TRACE_RETRIEVAL:-N/A}
Phase: ${PHASE:-N/A}
Include working tree evidence: $INCLUDE_WORKING_TREE

Follow the DKSync Memory Refresh prompt above. If Dry run is 1 or Trace
retrieval is not N/A, do not modify files.
EOF
)

SYNC_PROVIDER_SESSION_ID="sync-$(dk_unique_session_id)"
dk_provider_cleanup_session_state "$SYNC_PROVIDER_SESSION_ID"

DOYAKEN_SESSION_ID="$SYNC_PROVIDER_SESSION_ID" dk_provider_claude -p "${sync_prompt}${provider_prompt}${invocation}" \
  --model "$DK_CLAUDE_MODEL" --effort "$DK_CLAUDE_EFFORT" \
  --dangerously-skip-permissions --permission-mode bypassPermissions
CLAUDE_EXIT=$?

dk_provider_cleanup_session_state "$SYNC_PROVIDER_SESSION_ID"
SYNC_PROVIDER_SESSION_ID=""

if [[ $CLAUDE_EXIT -ne 0 ]]; then
  echo ""
  dk_error "Sync exited with code $CLAUDE_EXIT."
  exit "$CLAUDE_EXIT"
fi

echo ""
dk_done "Sync complete for: $repo_name"

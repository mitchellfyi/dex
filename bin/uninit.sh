#!/usr/bin/env bash
# shellcheck disable=SC1091
# dex uninit — remove Dex from current repo
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx uninit

Remove Dex's generated project files from the current repository.
Global Dex skills and hooks are left in place.

Options:
  -h, --help  Show this help
USAGE
}

show_help=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) show_help=1 ;;
    *)
      dx_error "Unknown uninit option: $arg"
      usage >&2
      exit 1
      ;;
  esac
done
if [[ $show_help -eq 1 ]]; then
  usage
  exit 0
fi

if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  repo_root=""
fi
if [[ -z "$repo_root" ]]; then
  echo "ERROR: Not in a git repository."
  exit 1
fi

repo_name=$(basename "$repo_root")
echo "Dex — Uninit: $repo_name"
echo ""

# 1. Remove .dex/dex.md
dex_md="$repo_root/.dex/dex.md"
if [[ -f "$dex_md" ]]; then
  rm "$dex_md"
  dx_done "Removed .dex/dex.md"
else
  dx_skip ".dex/dex.md not found"
fi

# 2. Remove .dex/AGENTS.md
dex_agents_md="$repo_root/.dex/AGENTS.md"
if [[ -f "$dex_agents_md" ]]; then
  rm "$dex_agents_md"
  dx_done "Removed .dex/AGENTS.md"
else
  dx_skip ".dex/AGENTS.md not found"
fi

# 3. Remove .dex/CLAUDE.md
dex_claude_md="$repo_root/.dex/CLAUDE.md"
if [[ -f "$dex_claude_md" ]]; then
  rm "$dex_claude_md"
  dx_done "Removed .dex/CLAUDE.md"
else
  dx_skip ".dex/CLAUDE.md not found"
fi

# 4. Note about worktrees
worktrees_dir="$repo_root/.dex/worktrees"
if [[ -d "$worktrees_dir" ]] && ls "$worktrees_dir"/*/ &>/dev/null; then
  echo ""
  dx_warn "Active worktrees exist. Clean them up with: dxrm --all"
fi

# 5. Remove generated config directories (rules/, guards/, and memory/ are created by dx init;
# hooks/ is NOT part of the per-project structure — it lives in $DEX_DIR/hooks/)
for dir in rules guards memory; do
  if [[ -d "$repo_root/.dex/$dir" ]]; then
    rm -rf "$repo_root/.dex/$dir"
    dx_done "Removed .dex/$dir/"
  fi
done

# 6. Remove .dex/.gitignore (created by init)
dex_gitignore="$repo_root/.dex/.gitignore"
if [[ -f "$dex_gitignore" ]]; then
  rm "$dex_gitignore"
  dx_done "Removed .dex/.gitignore"
fi

# 7. Clean up phase and loop state files for THIS repo's worktrees only.
# State dirs are global (~/.claude/.dex-{phases,loops}/), so we must enumerate
# this repo's worktrees rather than globbing all worktree-* files (which would
# accidentally delete state for other repos' worktrees).
# Note: if `dxrm --all` was run before uninit, it already cleaned state files.
if [[ -d "$repo_root/.dex/worktrees" ]]; then
  for wt_dir in "$repo_root/.dex/worktrees"/*/; do
    [[ -d "$wt_dir" ]] || continue
    wt_name="$(basename "$wt_dir")"
    session_id=$(dx_session_id "$wt_name")
    dx_cleanup_session "$session_id"
  done
fi
# Clean up last-session only if it belongs to this repo's worktrees
for wt_dir in "$repo_root/.dex/worktrees"/*/; do
  [[ -d "$wt_dir" ]] || continue
  dx_cleanup_last_session "$(basename "$wt_dir")"
done
dx_done "Cleaned up phase and loop state files"

# 8. Clean up .dex/ if empty
rmdir "$repo_root/.dex" 2>/dev/null && dx_done "Removed empty .dex/" || true

echo ""
echo "Uninit complete for: $repo_name"
echo "Dex hooks and skills still work globally — run 'dx uninstall' to remove those."

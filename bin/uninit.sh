#!/usr/bin/env bash
# shellcheck disable=SC1091
# doyaken uninit — remove Doyaken from current repo
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  repo_root=""
fi
if [[ -z "$repo_root" ]]; then
  echo "ERROR: Not in a git repository."
  exit 1
fi

repo_name=$(basename "$repo_root")
echo "Doyaken — Uninit: $repo_name"
echo ""

# 1. Remove .doyaken/doyaken.md
doyaken_md="$repo_root/.doyaken/doyaken.md"
if [[ -f "$doyaken_md" ]]; then
  rm "$doyaken_md"
  dk_done "Removed .doyaken/doyaken.md"
else
  dk_skip ".doyaken/doyaken.md not found"
fi

# 2. Remove .doyaken/AGENTS.md
doyaken_agents_md="$repo_root/.doyaken/AGENTS.md"
if [[ -f "$doyaken_agents_md" ]]; then
  rm "$doyaken_agents_md"
  dk_done "Removed .doyaken/AGENTS.md"
else
  dk_skip ".doyaken/AGENTS.md not found"
fi

# 3. Remove .doyaken/CLAUDE.md
doyaken_claude_md="$repo_root/.doyaken/CLAUDE.md"
if [[ -f "$doyaken_claude_md" ]]; then
  rm "$doyaken_claude_md"
  dk_done "Removed .doyaken/CLAUDE.md"
else
  dk_skip ".doyaken/CLAUDE.md not found"
fi

# 4. Note about worktrees
worktrees_dir="$repo_root/.doyaken/worktrees"
if [[ -d "$worktrees_dir" ]] && ls "$worktrees_dir"/*/ &>/dev/null; then
  echo ""
  dk_warn "Active worktrees exist. Clean them up with: dkrm --all"
fi

# 5. Remove generated config directories (rules/, guards/, and memory/ are created by dk init;
# hooks/ is NOT part of the per-project structure — it lives in $DOYAKEN_DIR/hooks/)
for dir in rules guards memory; do
  if [[ -d "$repo_root/.doyaken/$dir" ]]; then
    rm -rf "$repo_root/.doyaken/$dir"
    dk_done "Removed .doyaken/$dir/"
  fi
done

# 6. Remove .doyaken/.gitignore (created by init)
doyaken_gitignore="$repo_root/.doyaken/.gitignore"
if [[ -f "$doyaken_gitignore" ]]; then
  rm "$doyaken_gitignore"
  dk_done "Removed .doyaken/.gitignore"
fi

# 7. Clean up phase and loop state files for THIS repo's worktrees only.
# State dirs are global (~/.claude/.doyaken-{phases,loops}/), so we must enumerate
# this repo's worktrees rather than globbing all worktree-* files (which would
# accidentally delete state for other repos' worktrees).
# Note: if `dkrm --all` was run before uninit, it already cleaned state files.
if [[ -d "$repo_root/.doyaken/worktrees" ]]; then
  for wt_dir in "$repo_root/.doyaken/worktrees"/*/; do
    [[ -d "$wt_dir" ]] || continue
    wt_name="$(basename "$wt_dir")"
    session_id=$(dk_session_id "$wt_name")
    dk_cleanup_session "$session_id"
  done
fi
# Clean up last-session only if it belongs to this repo's worktrees
for wt_dir in "$repo_root/.doyaken/worktrees"/*/; do
  [[ -d "$wt_dir" ]] || continue
  dk_cleanup_last_session "$(basename "$wt_dir")"
done
dk_done "Cleaned up phase and loop state files"

# 8. Clean up .doyaken/ if empty
rmdir "$repo_root/.doyaken" 2>/dev/null && dk_done "Removed empty .doyaken/" || true

echo ""
echo "Uninit complete for: $repo_name"
echo "Doyaken hooks and skills still work globally — run 'dk uninstall' to remove those."

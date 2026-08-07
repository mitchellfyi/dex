#!/usr/bin/env bash
# shellcheck disable=SC1091
# dex uninit — remove Dex from current repo
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx uninit

Remove project files recorded as Dex-owned and restore the previous Git hook
configuration. Pre-existing and modified files are preserved. Global Dex skills
and hooks are left in place.

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
  dx_error "Not in a git repository."
  exit 1
fi

repo_name=$(basename "$repo_root")
echo "Dex — Uninit: $repo_name"
echo ""

OTHER_INIT_STATE=0
other_init_status=0
dx_project_has_other_init_state "$repo_root" || other_init_status=$?
case "$other_init_status" in
  0) OTHER_INIT_STATE=1 ;;
  1) ;;
  *)
    dx_error "Could not inspect initialized Git worktrees"
    exit "$other_init_status"
    ;;
esac

# 1. Restore the hook configuration and remove attribution files that this
# installation recorded as Dex-owned.
dx_uninstall_repo_attribution "$repo_root"

# 2. Note about worktrees
worktrees_dir="$repo_root/.dex/worktrees"
if [[ -d "$worktrees_dir" ]] && ls "$worktrees_dir"/*/ &>/dev/null; then
  echo ""
  dx_warn "Active worktrees exist. Clean them up with: dxrm --all"
fi

# 3. Keep another initialized checkout's active lifecycle intact. The final
# uninit still clears stale and already-removed worktree state repo-wide.
if [[ "$OTHER_INIT_STATE" == "1" ]]; then
  dx_cleanup_current_checkout_sessions
  dx_done "Cleaned up this checkout's phase and loop state files"
else
  dx_cleanup_repo_sessions
  dx_done "Cleaned up repo-scoped phase and loop state files"
fi

# 4. Remove only files recorded as Dex-owned. Content that changed after init,
# files that predated init, and files from legacy installs without provenance
# remain in place.
ownership_output=$(mktemp "${TMPDIR:-/tmp}/dex-uninit-ownership.XXXXXX")
ownership_status=0
dx_project_state_remove_managed "$repo_root" > "$ownership_output" || ownership_status=$?
case "$ownership_status" in
  0)
    removed_count=0
    preserved_count=0
    while IFS=$'\t' read -r action relative_path; do
      case "$action" in
        removed) removed_count=$((removed_count + 1)) ;;
        preserved)
          preserved_count=$((preserved_count + 1))
          [[ "$relative_path" == ".dex" || "$relative_path" == ".github" ]] \
            || dx_warn "Preserving modified or user-owned file: $relative_path"
          ;;
      esac
    done < "$ownership_output"
    if [[ $removed_count -gt 0 ]]; then
      dx_done "Removed $removed_count Dex-owned project path(s)"
    else
      dx_skip "No unchanged Dex-owned project files found"
    fi
    if [[ $preserved_count -gt 0 ]]; then
      dx_info "Files Dex does not own remain in place"
    fi
    ;;
  3)
    dx_warn "No project ownership record found; preserving existing .dex files"
    ;;
  *)
    rm -f "$ownership_output"
    dx_error "Could not read Dex project ownership state"
    exit "$ownership_status"
    ;;
esac
rm -f "$ownership_output"

echo ""
echo "Uninit complete for: $repo_name"
echo "Dex hooks and skills still work globally — run 'dx uninstall' to remove those."

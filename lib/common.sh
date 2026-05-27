# shellcheck shell=bash
# Dex shared library — common constants and bootstrap
#
# Source this from any script:
#   source "$DEX_DIR/lib/common.sh"
#
# Provides: DEX_DIR, DX_STATE_DIR, DX_LOOP_DIR, DX_ARTIFACT_DIR, DX_TOOL_DIR, DX_RUN_ROOT, dx_repo_root()
# Also sources: lib/git.sh, lib/session.sh, lib/output.sh, lib/worktree.sh,
# lib/provider.sh, lib/codex.sh, lib/ui-capture.sh, lib/rtk.sh, lib/events.sh,
# lib/agent-tools.sh, and lib/maintenance.sh

if [[ -z "${DEX_DIR:-}" ]]; then
  # Auto-detect from this file's location (lib/common.sh → repo root).
  # BASH_SOURCE works in bash; $0 works in zsh when sourced.
  _dx_self="${BASH_SOURCE[0]:-$0}"
  DEX_DIR="$(cd "$(dirname "$_dx_self")/.." && pwd)"
  export DEX_DIR
  unset _dx_self
fi
# shellcheck disable=SC2034  # exported by sourcing; used by dx.sh and sibling libs
DX_STATE_DIR="${DX_STATE_DIR:-$HOME/.claude/.dex-phases}"
# shellcheck disable=SC2034  # exported by sourcing; used by dx.sh and sibling libs
DX_LOOP_DIR="${DX_LOOP_DIR:-$HOME/.claude/.dex-loops}"
# shellcheck disable=SC2034  # exported by sourcing; used by UI capture helpers
DX_ARTIFACT_DIR="${DX_ARTIFACT_DIR:-$HOME/.claude/.dex-artifacts}"
# shellcheck disable=SC2034  # exported by sourcing; used by Dex-managed tools
DX_TOOL_DIR="${DX_TOOL_DIR:-$HOME/.claude/.dex-tools}"
# shellcheck disable=SC2034  # exported by sourcing; used by run event helpers
DX_RUN_ROOT="${DX_RUN_ROOT:-$HOME/.dex/runs}"

# dx_repo_root — print the *main* repo toplevel or return 1
# If cwd is inside a dex worktree (.dex/worktrees/<name>/...),
# returns the main repo root, not the worktree root. This prevents dx
# from creating nested worktrees when the user's shell is cd'd into one.
dx_repo_root() {
  local root
  if ! root=$(git rev-parse --show-toplevel 2>/dev/null); then
    root=""
  fi
  if [[ -z "$root" ]]; then
    echo "ERROR: Not in a git repository." >&2
    return 1
  fi
  # Escape worktree paths — strip /.dex/worktrees/<name> suffix
  if [[ "$root" == *"/.dex/worktrees/"* ]]; then
    root="${root%%/.dex/worktrees/*}"
  fi
  echo "$root"
}

# Source sibling libraries — guard each call so partial installs get a clear error.
__dx_require_lib() {
  local lib="$DEX_DIR/lib/$1"
  if [[ ! -f "$lib" ]]; then
    printf 'dex: missing library %s — reinstall Dex or check DEX_DIR\n' "$lib" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$lib"
}
__dx_require_lib git.sh
__dx_require_lib session.sh
__dx_require_lib output.sh
__dx_require_lib worktree.sh
__dx_require_lib provider.sh
__dx_require_lib codex.sh
__dx_require_lib ui-capture.sh
__dx_require_lib rtk.sh
__dx_require_lib events.sh
__dx_require_lib agent-tools.sh
__dx_require_lib maintenance.sh

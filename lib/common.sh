# shellcheck shell=bash
# Dex shared library — common constants and bootstrap
#
# Source this from any script:
#   source "$DEX_DIR/lib/common.sh"
#
# Provides: DEX_DIR, DX_STATE_DIR, DX_LOOP_DIR, DX_ARTIFACT_DIR, DX_TOOL_DIR, DX_RUN_ROOT, dx_repo_root()
# Also sources: lib/lock.sh, lib/git.sh, lib/session.sh, lib/output.sh, lib/worktree.sh,
# lib/provider.sh, lib/codex.sh, lib/dexcode.sh, lib/ui-capture.sh, lib/rtk.sh,
# lib/events.sh, lib/review.sh, lib/review-policy.sh, lib/review-controller.sh, lib/review-loop.sh, lib/factory.sh,
# lib/run-spec.sh, lib/agent-tools.sh, lib/maintenance.sh, lib/project-state.sh,
# lib/lifecycle-control.sh, lib/attribution.sh, and lib/worker.sh

if [[ -z "${DEX_DIR:-}" ]]; then
  # Auto-detect from this file's location (lib/common.sh → repo root).
  # BASH_SOURCE works in bash; $0 works in zsh when sourced.
  _dx_self="${BASH_SOURCE[0]:-$0}"
  DEX_DIR="$(cd "$(dirname "$_dx_self")/.." && pwd)"
  export DEX_DIR
  unset _dx_self
fi
# State dirs are exported so child processes that cannot source this file
# (python hooks, spawned CLI sessions, per-pass review waves) resolve the same
# paths as the launching shell — including any user override of these vars.
export DX_STATE_DIR="${DX_STATE_DIR:-$HOME/.claude/.dex-phases}"
export DX_LOOP_DIR="${DX_LOOP_DIR:-$HOME/.claude/.dex-loops}"
# Used by UI capture helpers
export DX_ARTIFACT_DIR="${DX_ARTIFACT_DIR:-$HOME/.claude/.dex-artifacts}"
# Used by Dex-managed tools
export DX_TOOL_DIR="${DX_TOOL_DIR:-$HOME/.claude/.dex-tools}"
# Used by run event helpers
export DX_RUN_ROOT="${DX_RUN_ROOT:-$HOME/.dex/runs}"

# Matches a ~/.zshrc line that loads Dex: the current install layout, the
# legacy dex-cli checkout name, and DEX_DIR-based source lines. Shared by
# bin/install.sh, bin/status.sh, and bin/uninstall.sh so detection and removal
# stay in lockstep.
# shellcheck disable=SC2034  # consumed by the bin/ scripts above
DX_ZSHRC_SOURCE_PATTERN='dex(-cli)?/dx\.sh|DEX_DIR.*/dx\.sh'

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
# Fast paths that only read state can name the modules they need in
# DX_COMMON_MODULES (space-separated, without the .sh suffix, in load order).
# The status line runs on every TUI render, and loading all of lib/ — including
# the ~90KB review and dexcode modules — dominated its budget. The variable is
# deliberately not exported: a child process gets the full set unless it opts
# out for itself.
if [[ -n "${DX_COMMON_MODULES:-}" ]]; then
  # Split on whitespace explicitly: zsh does not word-split an unquoted
  # parameter, so a bare ${DX_COMMON_MODULES} loop would treat the whole
  # list as one module name there.
  while IFS= read -r _dx_module; do
    [[ -n "$_dx_module" ]] || continue
    __dx_require_lib "${_dx_module}.sh"
  done <<EOF
$(printf '%s\n' "$DX_COMMON_MODULES" | tr ' ' '\n')
EOF
  unset _dx_module
  return 0 2>/dev/null || true
fi

__dx_require_lib lock.sh
__dx_require_lib git.sh
__dx_require_lib session.sh
__dx_require_lib output.sh
__dx_require_lib worktree.sh
__dx_require_lib provider.sh
__dx_require_lib codex.sh
__dx_require_lib dexcode.sh
__dx_require_lib ui-capture.sh
__dx_require_lib rtk.sh
__dx_require_lib events.sh
__dx_require_lib review.sh
__dx_require_lib review-policy.sh
__dx_require_lib review-controller.sh
__dx_require_lib review-loop.sh
__dx_require_lib factory.sh
__dx_require_lib run-spec.sh
__dx_require_lib agent-tools.sh
__dx_require_lib maintenance.sh
__dx_require_lib project-state.sh
__dx_require_lib lifecycle-control.sh
__dx_require_lib attribution.sh
__dx_require_lib worker.sh

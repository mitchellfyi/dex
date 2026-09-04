# shellcheck shell=bash
# Dex shared library — common constants and bootstrap
#
# Source this from any script:
#   source "$DEX_DIR/lib/common.sh"
#
# Provides: DEX_DIR, DX_STATE_DIR, DX_LOOP_DIR, DX_ARTIFACT_DIR, DX_TOOL_DIR, DX_RUN_ROOT, dx_repo_root()
# Also sources: lib/lock.sh, lib/git.sh, lib/session.sh, lib/override.sh, lib/completion.sh,
# lib/session-runtime.sh, lib/session-catalog.sh, lib/output.sh, lib/worktree.sh,
# lib/provider.sh, lib/codex.sh, lib/dexcode.sh, lib/ui-capture.sh, lib/rtk.sh,
# lib/events.sh, lib/review.sh, lib/review-capacity.sh, lib/review-policy.sh,
# lib/review-controller.sh, lib/review-loop.sh, lib/factory.sh,
# lib/run-spec.sh, lib/agent-tools.sh, lib/maintenance.sh, lib/project-state.sh,
# lib/lifecycle-control.sh, lib/session-management.sh, lib/attribution.sh, and
# lib/worker.sh

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

# The same reference, but only where it can actually run: a line whose first
# non-blank character is not `#`. Commenting the source line out is how people
# turn Dex off, and asking the bare pattern then answers "already installed"
# for a line the shell never executes — so install adds nothing, status reports
# integration that is not there, and uninstall claims a removal it did not do.
# shellcheck disable=SC2034  # consumed by the bin/ scripts above
DX_ZSHRC_SOURCE_ACTIVE_PATTERN="^[[:space:]]*[^#[:space:]].*(${DX_ZSHRC_SOURCE_PATTERN})"

# __dx_path_metadata <mode|mtime> <path>
# Python's lstat contract is the same on macOS and Linux. Native stat flags
# are not: GNU stat accepts BSD's -f flag as a different successful command.
__dx_path_metadata() {
  local field="$1" target="$2"
  python3 - "$field" "$target" <<'PY'
import os
import stat
import sys

field, target = sys.argv[1:]
try:
    metadata = os.lstat(target)
except OSError:
    raise SystemExit(1)

if field == "mode":
    print(format(stat.S_IMODE(metadata.st_mode), "o"))
elif field == "mtime":
    print(int(metadata.st_mtime))
else:
    raise SystemExit(2)
PY
}

# dx_path_mode <path> — print the path's octal permission bits.
dx_path_mode() {
  __dx_path_metadata mode "$1"
}

# dx_path_mtime <path> — print the path's modification time as epoch seconds.
dx_path_mtime() {
  __dx_path_metadata mtime "$1"
}

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
__dx_require_lib override.sh
__dx_require_lib completion.sh
__dx_require_lib session-runtime.sh
__dx_require_lib session-catalog.sh
__dx_require_lib output.sh
__dx_require_lib worktree.sh
__dx_require_lib provider.sh
__dx_require_lib codex.sh
__dx_require_lib dexcode.sh
__dx_require_lib ui-capture.sh
__dx_require_lib rtk.sh
__dx_require_lib events.sh
__dx_require_lib review.sh
__dx_require_lib review-capacity.sh
__dx_require_lib review-policy.sh
__dx_require_lib review-controller.sh
__dx_require_lib review-loop.sh
__dx_require_lib factory.sh
__dx_require_lib run-spec.sh
__dx_require_lib agent-tools.sh
__dx_require_lib maintenance.sh
__dx_require_lib project-state.sh
__dx_require_lib lifecycle-control.sh
__dx_require_lib session-management.sh
__dx_require_lib attribution.sh
__dx_require_lib worker.sh

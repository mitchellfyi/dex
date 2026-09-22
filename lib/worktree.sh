# shellcheck shell=bash
# Dex shared library — worktree helpers
#
# Bash/zsh-compatible utilities for worktree management and state cleanup.
# Used by dx.sh (dxrm, dxls, dxclean, __dx_show_header) and bin/uninit.sh.
# Depends on: DX_STATE_DIR (from lib/common.sh)

# dx_wt_branch <wt_dir> [fallback]
# Get the current branch of a worktree. Returns empty or fallback for
# detached HEAD or query failure.
dx_wt_branch() {
  local wt_dir="$1"
  local fallback="${2:-}"
  local branch
  branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    echo "$fallback"
  else
    echo "$branch"
  fi
}

# dx_wt_is_registered <repo_root> <wt_dir>
# Confirm a directory is a linked worktree of the expected repository. A plain
# directory below .dex/worktrees can otherwise resolve Git commands against the
# main checkout and defeat lifecycle isolation.
dx_wt_is_registered() {
  local repo_root="$1" wt_dir="$2" target_path top_level line listed_path listed_resolved
  [[ -d "$repo_root" && -d "$wt_dir" ]] || return 1

  target_path=$(cd "$wt_dir" 2>/dev/null && pwd -P) || return 1
  top_level=$(git -C "$wt_dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  top_level=$(cd "$top_level" 2>/dev/null && pwd -P) || return 1
  [[ "$top_level" == "$target_path" ]] || return 1

  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        listed_path=${line#worktree }
        listed_resolved=$(cd "$listed_path" 2>/dev/null && pwd -P) || continue
        [[ "$listed_resolved" == "$target_path" ]] && return 0
        ;;
    esac
  done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null)

  return 1
}

# ─── Project worktree lifecycle hooks ───────────────────────────────────────
#
# A worktree costs a repository more than a directory. It may need a database,
# a port, a container, a build cache — and none of that is something Dex can
# guess for an arbitrary codebase. A project declares the commands in a fenced
# YAML block under `## Worktree Hooks` in its `.dex/dex.md`:
#
#   after_create: bin/dex-worktree up
#   before_remove: bin/dex-worktree down
#   on_session_end: bin/dex-worktree release-ports
#   orphan_resources: bin/dex-worktree orphans
#
# Each value is one shell command string. Dex runs it in the worktree with
# DX_WORKTREE_NAME, DX_WORKTREE_PATH, DX_TICKET and DX_REPO_ROOT exported,
# under a DEX_WORKTREE_HOOK_TIMEOUT deadline, carrying the session ownership
# token so anything the hook leaves running is still the session's to reap.
#
# A missing section, a missing key, a failing hook and a hook that runs long
# are all survivable: each one warns at most and the worktree operation
# continues. A teardown command must never be the reason a worktree cannot be
# removed — that is how a repository ends up with both the resource and the
# directory it was supposed to free.

# Seconds one hook may run. 300 is long enough to create or drop a database
# and short enough that a hung hook does not hold a removal open.
DEX_WORKTREE_HOOK_TIMEOUT_DEFAULT=300

# __dx_worktree_hook_timeout — the deadline in seconds; 0 means no deadline
#
# DX_WORKTREE_HOOK_CEILING is the call site's own budget, not the project's:
# a caller that is itself running under someone else's clock — the SessionEnd
# hook has ten seconds from the host — cannot offer the project more time than
# it has. It lowers the deadline and never raises it, and it overrides the
# "0 means forever" spelling, because forever is not on offer there. It is
# internal; a project tunes DEX_WORKTREE_HOOK_TIMEOUT.
__dx_worktree_hook_timeout() {
  local configured="${DEX_WORKTREE_HOOK_TIMEOUT:-$DEX_WORKTREE_HOOK_TIMEOUT_DEFAULT}"
  local ceiling="${DX_WORKTREE_HOOK_CEILING:-}"
  if [[ ! "$configured" =~ ^[0-9]+$ ]] || [[ ${#configured} -gt 6 ]]; then
    configured="$DEX_WORKTREE_HOOK_TIMEOUT_DEFAULT"
  fi
  if [[ "$ceiling" =~ ^[1-9][0-9]*$ ]] && [[ ${#ceiling} -le 6 ]]; then
    if [[ "$configured" -eq 0 ]] || [[ "$configured" -gt "$ceiling" ]]; then
      configured="$ceiling"
    fi
  fi
  printf '%s\n' "$configured"
}

# __dx_worktree_hook_command <repo_root> <hook-name>
# The declared command, or nothing. Prints a warning for a contract Dex can
# read the shape of but not the contents — a malformed block and a list where
# a command belongs are both worth saying out loud, once, where they happen.
__dx_worktree_hook_command() {
  local hook_repo="$1" hook_name="$2" hook_command="" hook_read=0
  hook_command=$(dx_project_worktree_hook "$hook_repo" "$hook_name" 2>/dev/null) \
    || hook_read=$?
  if [[ "$hook_read" -eq 2 ]]; then
    dx_warn "Ignoring '## Worktree Hooks' in ${hook_repo}/.dex/dex.md: it is not a flat mapping of shell commands."
    return 1
  fi
  [[ "$hook_read" -eq 0 && -n "$hook_command" ]] || return 1
  if [[ "$hook_command" == *$'\n'* ]]; then
    dx_warn "Ignoring the ${hook_name} worktree hook: each hook is one shell command, not a list."
    return 1
  fi
  printf '%s\n' "$hook_command"
}

# __dx_worktree_hook_exec <hook-name> <repo_root> <wt_dir> <name> <ticket> <command>
# Run one declared command with the documented environment. Returns its exit
# status, or 124 when the deadline stopped it.
__dx_worktree_hook_exec() {
  local hook_name="$1" hook_repo="$2" hook_dir="$3" hook_label="$4"
  local hook_ticket="$5" hook_command="$6" hook_cwd hook_seconds hook_result=0

  # Run in the worktree. A before_remove for an orphan whose directory is
  # already gone still has a database or a port to free, so fall back to the
  # repository root rather than skipping the teardown entirely.
  hook_cwd="$hook_dir"
  [[ -d "$hook_cwd" ]] || hook_cwd="$hook_repo"
  [[ -d "$hook_cwd" ]] || return 0

  hook_seconds=$(__dx_worktree_hook_timeout)
  # Not `cd` in this shell: the caller is mid-removal and its working
  # directory is its own business.
  dx_run_with_timeout "$hook_seconds" env \
    DX_WORKTREE_NAME="$hook_label" \
    DX_WORKTREE_PATH="$hook_dir" \
    DX_TICKET="$hook_ticket" \
    DX_REPO_ROOT="$hook_repo" \
    bash -c 'cd "$1" || exit 1; shift; eval "$1"' \
    dex-worktree-hook "$hook_cwd" "$hook_command" || hook_result=$?
  return "$hook_result"
}

# dx_worktree_hook_run <after_create|before_remove|on_session_end> <repo_root>
#   <wt_dir> [wt_name] [ticket]
#
# Always returns 0 when the arguments are well formed: whether the project
# declared the hook, whether it succeeded, and whether it finished in time are
# all things the caller carries on past. Returns 2 only for a name that is not
# a hook or a missing repository — a Dex bug, not a project's business.
dx_worktree_hook_run() {
  local hook_name="${1:-}" hook_repo="${2:-}" hook_dir="${3:-}"
  local hook_label="${4:-}" hook_ticket="${5:-}"
  local hook_command="" hook_seconds hook_result=0

  case "$hook_name" in
    after_create | before_remove | on_session_end) ;;
    *) return 2 ;;
  esac
  [[ -n "$hook_repo" && -n "$hook_dir" ]] || return 2
  # A caller that loaded only part of lib/ gets a no-op, not a failure.
  command -v dx_run_with_timeout >/dev/null 2>&1 || return 0

  hook_command=$(__dx_worktree_hook_command "$hook_repo" "$hook_name") || return 0

  # Dex's own worktree names carry the ticket, and a project keys its
  # resources on one or the other, so derive both rather than making every
  # call site remember to pass them.
  [[ -n "$hook_label" ]] || hook_label="${hook_dir##*/}"
  if [[ -z "$hook_ticket" ]]; then
    case "$hook_label" in
      ticket-?*) hook_ticket="${hook_label#ticket-}" ;;
    esac
  fi

  hook_seconds=$(__dx_worktree_hook_timeout)
  dx_info "Running this project's ${hook_name} worktree hook for ${hook_label}."
  __dx_worktree_hook_exec "$hook_name" "$hook_repo" "$hook_dir" "$hook_label" \
    "$hook_ticket" "$hook_command" || hook_result=$?

  if [[ "$hook_result" -eq 124 ]]; then
    dx_warn "This project's ${hook_name} worktree hook for ${hook_label} passed ${hook_seconds}s and was stopped. Continuing."
  elif [[ "$hook_result" -ne 0 ]]; then
    dx_warn "This project's ${hook_name} worktree hook for ${hook_label} failed (exit ${hook_result}). Continuing."
  fi
  return 0
}

# dx_worktree_orphan_resources <repo_root>
# Print what the project's orphan_resources probe reports, one orphan per line.
#
#   0  the probe ran and reported these lines
#   1  this project declares no usable probe
#   2  the probe ran and failed, or the deadline stopped it
#   3  the probe ran and reported nothing
#
# A crashed probe and an absent one used to be the same answer, which let a
# broken probe read as "this repository is clean". They are different facts
# and only one of them is reassuring, so the caller gets to say which it is.
dx_worktree_orphan_resources() {
  local hook_repo="${1:-}" probe_command="" probe_seconds probe_output="" probe_result=0
  [[ -n "$hook_repo" && -d "$hook_repo" ]] || return 1
  command -v dx_run_with_timeout >/dev/null 2>&1 || return 1
  probe_command=$(__dx_worktree_hook_command "$hook_repo" orphan_resources) || return 1

  probe_seconds=$(__dx_worktree_hook_timeout)
  probe_output=$(dx_run_with_timeout "$probe_seconds" env \
    DX_REPO_ROOT="$hook_repo" \
    bash -c 'cd "$1" || exit 1; shift; eval "$1"' \
    dex-worktree-orphans "$hook_repo" "$probe_command") || probe_result=$?
  if [[ "$probe_result" -eq 124 ]]; then
    dx_warn "This project's orphan_resources probe passed ${probe_seconds}s and was stopped; Dex cannot say what it would have reported."
    return 2
  fi
  if [[ "$probe_result" -ne 0 ]]; then
    dx_warn "This project's orphan_resources probe failed (exit ${probe_result}); Dex cannot say what it would have reported."
    return 2
  fi
  [[ -n "$probe_output" ]] || return 3
  printf '%s\n' "$probe_output"
}

# ─── Which worktrees this repository still accounts for ────────────────────
#
# A project's orphan_resources probe cannot know which worktrees are checked
# out right now — it looks at databases, ports and containers, not at git. So
# whatever it names, Dex compares against this before offering to tear it
# down. `dx worktree audit --apply` and `dxclean --apply` both go through
# these two functions so one rule decides for both.

# __dx_worktree_live_key <name-or-path> — the spelling the comparison uses
#
# Trailing slashes off, and folded to lower case unconditionally. macOS and
# Windows volumes are case-insensitive, so `Ticket-142` and `ticket-142` are
# one directory there and a guard that reads them as two will delete a live
# checkout. Folding everywhere makes a case-sensitive host slightly
# over-cautious instead, and over-cautious here means declining to act.
__dx_worktree_live_key() {
  local raw="${1:-}"
  while [[ "$raw" == */ && ${#raw} -gt 1 ]]; do
    raw="${raw%/}"
  done
  printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]'
}

# dx_worktree_live_names <repo_root>
# Every spelling of a worktree this repository still accounts for, one per
# line: the basename and the full path of each directory under
# .dex/worktrees/ and of each worktree git has registered, in both the
# recorded and the physically resolved form, through __dx_worktree_live_key.
#
# Both forms matter. A probe may print `/var/…` where git recorded
# `/private/var/…`, and a registration whose directory is gone has no
# resolved form at all but is still a name Dex is about to handle itself.
dx_worktree_live_names() {
  local repo_root="${1:-}" worktrees_dir live_line candidate live_resolved
  local listing="" listed=0
  [[ -n "$repo_root" && -d "$repo_root" ]] || return 1
  worktrees_dir="$repo_root/.dex/worktrees"

  # A working `git worktree list` always prints the main checkout, so a
  # listing that fails or names nothing is not "no worktrees" — it is "cannot
  # tell". That answer is exit 2 with nothing printed, and
  # dx_worktree_name_is_live reads it as everything being live.
  listing=$(git -C "$repo_root" worktree list --porcelain 2>/dev/null) || return 2
  while IFS= read -r live_line; do
    case "$live_line" in
      "worktree "*) candidate="${live_line#worktree }" ;;
      *) continue ;;
    esac
    [[ -n "$candidate" ]] || continue
    listed=$((listed + 1))
    __dx_worktree_live_key "$candidate"
    __dx_worktree_live_key "${candidate##*/}"
    live_resolved=$(cd "$candidate" 2>/dev/null && pwd -P) || live_resolved=""
    [[ -z "$live_resolved" ]] || __dx_worktree_live_key "$live_resolved"
  done <<EOF_LISTING
$listing
EOF_LISTING
  [[ "$listed" -gt 0 ]] || return 2

  [[ -d "$worktrees_dir" ]] || return 0
  while IFS= read -r candidate; do
    [[ -n "$candidate" && -d "$candidate" ]] || continue
    __dx_worktree_live_key "$candidate"
    __dx_worktree_live_key "${candidate##*/}"
    live_resolved=$(cd "$candidate" 2>/dev/null && pwd -P) || live_resolved=""
    [[ -z "$live_resolved" ]] || __dx_worktree_live_key "$live_resolved"
  done < <(find "$worktrees_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  return 0
}

# dx_worktree_name_is_live <repo_root> <entry>
# Does <entry> — a name or a path, however a probe chose to spell it — refer
# to a worktree this repository still accounts for? Exit 0 means yes, so do
# not tear it down. It is also the answer when git cannot list the worktrees:
# "cannot tell" is never a licence to remove.
#
# Recomputes the list per call rather than caching it: a caller classifies
# every candidate before it removes anything, and a cache that went stale
# mid-removal would answer "gone, go ahead" for something already torn down.
dx_worktree_name_is_live() {
  local repo_root="${1:-}" entry="${2:-}"
  local entry_key entry_path entry_resolved="" live_names known_name
  [[ -n "$repo_root" && -n "$entry" ]] || return 1
  entry_key=$(__dx_worktree_live_key "$entry")
  [[ -n "$entry_key" ]] || return 1
  # A probe spells a relative path from the checkout it ran in, which is
  # repo_root — not wherever this caller happens to be standing.
  entry_path="$entry"
  [[ "$entry" == /* ]] || entry_path="$repo_root/$entry"
  if [[ -d "$entry_path" ]]; then
    entry_resolved=$(cd "$entry_path" 2>/dev/null && pwd -P) || entry_resolved=""
    [[ -z "$entry_resolved" ]] || entry_resolved=$(__dx_worktree_live_key "$entry_resolved")
  fi
  # No list means Dex cannot tell which worktrees are live, and the only safe
  # reading of "cannot tell" is "live": declining to act is recoverable, a
  # torn-down live checkout is not.
  live_names=$(dx_worktree_live_names "$repo_root") || return 0
  [[ -n "$live_names" ]] || return 0
  while IFS= read -r known_name; do
    [[ -n "$known_name" ]] || continue
    if [[ "$known_name" == "$entry_key" ]]; then
      return 0
    fi
    if [[ -n "$entry_resolved" && "$known_name" == "$entry_resolved" ]]; then
      return 0
    fi
  done <<EOF
$live_names
EOF
  return 1
}

# __dx_wt_repo_root <wt_dir> — the checkout a .dex/worktrees path belongs to
__dx_wt_repo_root() {
  local wt_dir="${1:-}"
  case "$wt_dir" in
    */.dex/worktrees/?*) printf '%s\n' "${wt_dir%/.dex/worktrees/*}" ;;
    .dex/worktrees/?*) printf '%s\n' "$PWD" ;;
    *) return 1 ;;
  esac
}

# dx_wt_remove <wt_dir> [repo_root]
# Force-remove a worktree. Tries git worktree remove first, falls back to rm -rf.
#
# The fallback runs whenever git declines, including when the target is not a
# linked worktree at all — so the target has to be checked here rather than
# trusted. In-place mode keeps the repository root in a variable named much
# like this argument, and `rm -rf` on a repository root is not recoverable.
# The worktrees directory itself is refused too: only a directory inside it.
#
# The project's before_remove hook runs from here rather than from each
# caller. dxrm, dxrm --all and dxclean all arrive on this line, and a teardown
# a new removal path can forget to call is a teardown that eventually does not
# run. repo_root is derived from the path when the caller does not pass it.
dx_wt_remove() {
  local wt_dir="${1:-}" repo_root="${2:-}"
  case "$wt_dir" in
    *"/../"* | *"/..") wt_dir="" ;;
    */.dex/worktrees/?* | .dex/worktrees/?*) ;;
    *) wt_dir="" ;;
  esac
  if [[ -z "$wt_dir" ]]; then
    dx_error "Refusing to remove '${1:-}': not a path inside .dex/worktrees/"
    return 1
  fi
  if [[ -z "$repo_root" ]]; then
    repo_root=$(__dx_wt_repo_root "$wt_dir" 2>/dev/null) || repo_root=""
  fi
  [[ -z "$repo_root" ]] || dx_worktree_hook_run before_remove "$repo_root" "$wt_dir"
  git worktree remove "$wt_dir" --force 2>/dev/null || rm -rf "$wt_dir"
}

# dx_cleanup_last_session <wt_name>
# Remove the last-session pointer if it references the given worktree name.
dx_cleanup_last_session() {
  local wt_name="$1"
  local last_session_file="$DX_STATE_DIR/last-session"
  [[ -f "$last_session_file" ]] || return 0
  local last_info
  last_info=$(cat "$last_session_file" 2>/dev/null) || return 0
  if [[ "${last_info%%:*}" == "$wt_name" ]]; then
    rm -f "$last_session_file"
  fi
}

# dx_claude_project_dir <absolute_path>
# Returns the ~/.claude/projects/ directory name for a given path.
# Claude Code encodes project paths by replacing / and . with -.
dx_claude_project_dir() {
  echo "$HOME/.claude/projects/$(echo "$1" | tr '/.' '--')"
}

# dx_exclude_claude_artifacts <wt_dir>
# Keep Dex-managed Claude config links out of worktree status output.
dx_exclude_claude_artifacts() {
  local wt_dir="$1" exclude_file
  exclude_file=$(git -C "$wt_dir" rev-parse --git-path info/exclude 2>/dev/null || true)
  [[ -n "$exclude_file" ]] || return 0
  mkdir -p "$(dirname "$exclude_file")" 2>/dev/null || return 0

  touch "$exclude_file" 2>/dev/null || return 0
  grep -Fxq ".claude" "$exclude_file" 2>/dev/null || printf '%s\n' ".claude" >> "$exclude_file"
  grep -Fxq ".claude/*" "$exclude_file" 2>/dev/null || printf '%s\n' ".claude/*" >> "$exclude_file"
}

# dx_link_claude_to_worktree <repo_root> <wt_dir>
# For Claude-backed sessions, share .claude/ config and MCP auth with the main
# repo. Codex keeps its own project data, so it does not need these links.
# Idempotent and non-fatal.
dx_link_claude_to_worktree() {
  local repo_root="$1" wt_dir="$2"

  [[ "${DX_PROVIDER_ENGINE:-}" != "codex-plugin" ]] || return 0

  dx_exclude_claude_artifacts "$wt_dir"

  # 1. Symlink .claude/ (settings.local.json and project-local Claude config)
  if [[ -d "$repo_root/.claude" ]] && [[ ! -e "$wt_dir/.claude" ]]; then
    if ln -s "$repo_root/.claude" "$wt_dir/.claude" 2>/dev/null; then
      dx_info "Linked .claude/ from main repo"
    else
      dx_warn "Failed to symlink .claude/ into worktree"
    fi
  fi

  # 2. Symlink ~/.claude/projects/ so worktree shares MCP OAuth tokens
  local repo_proj wt_proj
  repo_proj=$(dx_claude_project_dir "$repo_root")
  wt_proj=$(dx_claude_project_dir "$wt_dir")
  if [[ -d "$repo_proj" ]] && [[ ! -e "$wt_proj" ]]; then
    if ln -s "$repo_proj" "$wt_proj" 2>/dev/null; then
      dx_info "Linked Claude project data for MCP auth"
    else
      dx_warn "Failed to symlink Claude project data"
    fi
  fi
}

# __dx_exclude_worktree_path <wt_dir> <pattern>
# Append one pattern to the repository's info/exclude file, once.
__dx_exclude_worktree_path() {
  local wt_dir="$1" pattern="$2" exclude_file
  exclude_file=$(git -C "$wt_dir" rev-parse --git-path info/exclude 2>/dev/null || true)
  [[ -n "$exclude_file" ]] || return 0
  mkdir -p "$(dirname "$exclude_file")" 2>/dev/null || return 0
  touch "$exclude_file" 2>/dev/null || return 0
  grep -Fxq -- "$pattern" "$exclude_file" 2>/dev/null \
    || printf '%s\n' "$pattern" >> "$exclude_file"
}

# dx_link_build_caches_to_worktree <repo_root> <wt_dir>
# A fresh worktree starts with no dependency or build tree, so every lifecycle
# pays a cold install and a cold build, and the host pays for six of them at
# once. Link the main checkout's ignored cache directories into the worktree
# instead. Only directories git already ignores in the worktree are linked, so
# a link can never be committed. Cargo serialises builds on a shared target
# directory, which also keeps concurrent lifecycles from compiling the same
# dependency tree side by side. DEX_WORKTREE_SHARED_DIRS overrides the list;
# set it empty to disable. Idempotent and non-fatal.
dx_link_build_caches_to_worktree() {
  local repo_root="$1" wt_dir="$2" name linked=0
  local shared_dirs="${DEX_WORKTREE_SHARED_DIRS-node_modules target .venv vendor .next .nuxt}"
  [[ -n "$shared_dirs" ]] || return 0
  [[ -d "$repo_root" && -d "$wt_dir" ]] || return 0
  # Split explicitly: zsh does not word-split an unquoted parameter.
  while IFS= read -r name; do
    case "$name" in
      ''|*/*|.|..) continue ;;
    esac
    [[ -d "$repo_root/$name" ]] || continue
    [[ ! -e "$wt_dir/$name" && ! -L "$wt_dir/$name" ]] || continue
    # The directory does not exist in the worktree yet, so ask about it as a
    # directory: a `name/` ignore pattern does not match a bare `name`.
    git -C "$wt_dir" check-ignore -q -- "$name/" 2>/dev/null || continue
    if ln -s "$repo_root/$name" "$wt_dir/$name" 2>/dev/null; then
      linked=$((linked + 1))
      # A `name/` ignore pattern matches a directory, not the symlink that now
      # stands in for it, so the link would show as untracked. Exclude it by
      # name; the exclude file is shared with the main checkout, where the
      # real directory is ignored already.
      __dx_exclude_worktree_path "$wt_dir" "/$name"
    else
      dx_warn "Failed to link $name into the worktree"
    fi
  done <<EOF
$(printf '%s\n' "$shared_dirs" | tr ' ' '\n')
EOF
  [[ "$linked" -eq 0 ]] \
    || dx_info "Linked $linked shared cache directories from the main checkout"
  return 0
}

# dx_unlink_claude_from_worktree <wt_dir>
# Remove the ~/.claude/projects/ symlink for a worktree.
# Only removes symlinks, never real directories.
# The .claude/ symlink inside the worktree is removed by dx_wt_remove.
dx_unlink_claude_from_worktree() {
  local wt_dir="$1"
  local wt_proj
  wt_proj=$(dx_claude_project_dir "$wt_dir")
  if [[ -L "$wt_proj" ]]; then
    rm -f "$wt_proj"
  fi
}

# dx_cleanup_stale_files <dir> <extensions> <max_age_days>
# Find and delete files matching "*.ext" older than max_age_days.
# extensions is space-separated (e.g., "state complete active").
# Prints the count of deleted files to stdout.
dx_cleanup_stale_files() {
  local dir="$1"
  local extensions="$2"
  local max_age="$3"
  [[ -d "$dir" ]] || { echo "0"; return 0; }
  [[ -n "$extensions" ]] || { echo "0"; return 0; }

  local find_args=()
  local first=1
  local ext
  while IFS= read -r ext; do
    [[ -n "$ext" ]] || continue
    if [[ $first -eq 1 ]]; then
      find_args+=(-name "*.${ext}")
      first=0
    else
      find_args+=(-o -name "*.${ext}")
    fi
  done < <(printf '%s\n' "$extensions" | tr ' ' '\n')

  # Single find pass: count deleted files via -print + -delete
  local count
  count=$(find "$dir" \( "${find_args[@]}" \) -mtime +"$max_age" -delete -print 2>/dev/null | wc -l | tr -d ' ')
  echo "${count:-0}"
}

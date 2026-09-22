#!/usr/bin/env bash
# shellcheck disable=SC1091
# dx worktree — what exists, according to Dex, according to git, and according
# to the project itself.
#
# Three catalogues drift apart: the directories under .dex/worktrees/, the
# worktrees git has registered, and whatever the repository stood up alongside
# them — a database, a port, a container. Only the repository can enumerate the
# third, which it does with the orphan_resources probe in `## Worktree Hooks`.
# This command puts all three side by side and changes nothing until --apply.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx worktree audit [--apply]
       dx worktree add-baseline <path> <commit>
       dx worktree remove-baseline <path>

audit            Compare the directories under .dex/worktrees/, the worktrees
                 git has registered, and what this project's orphan_resources
                 probe reports. A reported name that matches a worktree Dex
                 or git still lists is shown as live and never acted on.
                 Read-only.
  --apply        Run the project's before_remove hook for each entry listed
                 as an orphan, remove the unregistered directories, and prune
                 the stale git registrations. Nothing outside .dex/worktrees/
                 is removed. Each remaining orphan_resources line is handed
                 back to before_remove verbatim as DX_WORKTREE_NAME.

add-baseline     Cut a detached worktree at <commit> and run the project's
                 after_create hook in it. For a temporary before-state
                 checkout; <path> must not be inside .dex/worktrees/.
remove-baseline  Run the project's before_remove hook in <path>, then remove
                 that worktree. Refuses the main checkout, an unregistered
                 directory, and anything inside .dex/worktrees/.

A project declares these commands in a fenced YAML block under
`## Worktree Hooks` in .dex/dex.md. With no such section every path here still
works and runs nothing. See docs/worktree-hooks.md.

Options:
  -h, --help     Show this help
USAGE
}

# __dx_worktree_physical <dir> — the resolved path, or nothing
__dx_worktree_physical() {
  local target="${1:-}"
  [[ -n "$target" && -d "$target" ]] || return 1
  (cd "$target" 2>/dev/null && pwd -P) || return 1
}

# __dx_worktree_main_checkout <dir> — the checkout a linked worktree belongs to
#
# Derived from the worktree itself rather than from the caller's cwd: an agent
# that is standing in a temporary baseline checkout still means "this repo".
__dx_worktree_main_checkout() {
  local target="${1:-}" common_dir main_root
  common_dir=$(git -C "$target" rev-parse --path-format=absolute \
    --git-common-dir 2>/dev/null) || return 1
  main_root=$(git -C "$common_dir/.." rev-parse --show-toplevel 2>/dev/null) || return 1
  (cd "$main_root" 2>/dev/null && pwd -P) || return 1
}

# __dx_worktree_registered_paths <repo_root> — every path git has registered
__dx_worktree_registered_paths() {
  local repo_root="$1" line
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) printf '%s\n' "${line#worktree }" ;;
    esac
  done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null)
}

__dx_worktree_require_repo() {
  DX_WT_REPO_ROOT=$(dx_repo_root) || exit 1
  DX_WT_REPO_ROOT=$(__dx_worktree_physical "$DX_WT_REPO_ROOT") || {
    dx_error "Could not resolve the repository root."
    exit 1
  }
  DX_WT_WORKTREES_DIR="$DX_WT_REPO_ROOT/.dex/worktrees"
}

# ─── audit ──────────────────────────────────────────────────────────────────

__dx_worktree_audit() {
  local apply=0 arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        usage
        exit 0
        ;;
      --apply) apply=1 ;;
      *)
        dx_error "Unknown worktree audit option: $arg"
        usage >&2
        exit 1
        ;;
    esac
  done

  __dx_worktree_require_repo
  local work_dir
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dex-worktree-audit.XXXXXX") || {
    dx_error "Could not create temporary space for the audit."
    exit 1
  }
  # shellcheck disable=SC2064  # the path is fixed at trap time on purpose
  trap "command rm -rf '$work_dir'" EXIT

  local registered="$work_dir/registered" unregistered="$work_dir/unregistered"
  local stale="$work_dir/stale" resources="$work_dir/resources"
  local reported_live="$work_dir/reported-live"
  : > "$registered"
  : > "$unregistered"
  : > "$stale"
  : > "$resources"
  : > "$reported_live"

  printf '%s\n\n' "Dex — worktree audit: $DX_WT_REPO_ROOT"

  # Whether git can list the worktrees at all. A working listing always
  # includes the main checkout, so a failed or empty one means Dex cannot tell
  # a live worktree from an orphan — and then nothing below may be removed.
  local can_tell=1
  dx_worktree_live_names "$DX_WT_REPO_ROOT" >/dev/null 2>&1 || can_tell=0
  [[ "$can_tell" -eq 1 ]] \
    || dx_warn "git could not list this repository's worktrees; every name below is treated as live and --apply removes nothing."

  # 1. What git has registered, and whether each directory is still there.
  local raw resolved listed_count=0
  printf '%s\n' "Worktrees git has registered:"
  while IFS= read -r raw; do
    [[ -n "$raw" ]] || continue
    listed_count=$((listed_count + 1))
    resolved=$(__dx_worktree_physical "$raw") || resolved=""
    if [[ -z "$resolved" ]]; then
      printf '  %-58s %s\n' "$raw" "directory is gone"
      case "$raw" in
        "$DX_WT_WORKTREES_DIR"/?*) printf '%s\n' "$raw" >> "$stale" ;;
      esac
      continue
    fi
    printf '%s\n' "$resolved" >> "$registered"
    if [[ "$resolved" == "$DX_WT_REPO_ROOT" ]]; then
      printf '  %-58s %s\n' "$resolved" "main checkout"
    elif [[ "$resolved" == "$DX_WT_WORKTREES_DIR"/* ]]; then
      printf '  %-58s %s\n' "$resolved" "Dex lifecycle worktree"
    else
      printf '  %-58s %s\n' "$resolved" "outside .dex/worktrees/"
    fi
  done < <(__dx_worktree_registered_paths "$DX_WT_REPO_ROOT")
  [[ "$listed_count" -gt 0 ]] || printf '  %s\n' "(none)"
  printf '\n'

  # 2. What Dex has on disk, and whether git agrees.
  local entry name dex_count=0
  printf '%s\n' "Directories under .dex/worktrees/:"
  if [[ -d "$DX_WT_WORKTREES_DIR" ]]; then
    while IFS= read -r entry; do
      [[ -n "$entry" && -d "$entry" ]] || continue
      dex_count=$((dex_count + 1))
      name="${entry##*/}"
      resolved=$(__dx_worktree_physical "$entry") || resolved="$entry"
      if grep -Fxq -- "$resolved" "$registered" 2>/dev/null; then
        printf '  %-58s %s\n' "$name" "registered with git"
      else
        printf '  %-58s %s\n' "$name" "git does not know it"
        printf '%s\n' "$entry" >> "$unregistered"
      fi
    done < <(find "$DX_WT_WORKTREES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort)
  fi
  [[ "$dex_count" -gt 0 ]] || printf '  %s\n' "(none)"
  printf '\n'

  # 3. What only the project can see, measured against the two catalogues
  # above. A probe cannot be expected to know which worktrees are live, so
  # Dex is the one that has to check before it offers to tear anything down.
  local probe_result=0 reported="$work_dir/reported"
  printf '%s\n' "Orphans this project reports (orphan_resources):"
  # No 2>/dev/null: a probe that failed says so through dx_warn, and that
  # warning is the difference between "clean" and "Dex could not tell".
  dx_worktree_orphan_resources "$DX_WT_REPO_ROOT" > "$reported" || probe_result=$?
  : > "$resources"
  case "$probe_result" in
    0)
      while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        # dx_worktree_name_is_live owns this comparison so `dxclean --apply`
        # in dx.sh reaches the same verdict for the same probe line. It
        # matches basenames and full paths, recorded and resolved, folded to
        # lower case. Every line is classified here, before anything below
        # removes a directory, so the answer cannot go stale mid-sweep.
        if dx_worktree_name_is_live "$DX_WT_REPO_ROOT" "$entry"; then
          printf '  %-58s %s\n' "$entry" "reported, but Dex still has this worktree — not touched"
          printf '%s\n' "$entry" >> "$reported_live"
        else
          printf '  %s\n' "$entry"
          printf '%s\n' "$entry" >> "$resources"
        fi
      done < "$reported"
      ;;
    2) printf '  %s\n' "(the probe failed; Dex cannot tell whether this project is clean)" ;;
    3) printf '  %s\n' "(the probe ran and reported nothing)" ;;
    *) printf '  %s\n' "(this project declares no orphan_resources probe)" ;;
  esac
  printf '\n'

  local unregistered_count stale_count resource_count live_count total
  unregistered_count=$(grep -c . "$unregistered" 2>/dev/null || true)
  stale_count=$(grep -c . "$stale" 2>/dev/null || true)
  resource_count=$(grep -c . "$resources" 2>/dev/null || true)
  live_count=$(grep -c . "$reported_live" 2>/dev/null || true)
  unregistered_count="${unregistered_count:-0}"
  stale_count="${stale_count:-0}"
  resource_count="${resource_count:-0}"
  live_count="${live_count:-0}"
  total=$((unregistered_count + stale_count + resource_count))

  [[ "$live_count" -eq 0 ]] || dx_info "$(printf \
    '%s reported name(s) belong to a worktree Dex or git still lists; --apply leaves those alone' \
    "$live_count")"

  if [[ "$total" -eq 0 ]]; then
    if [[ "$can_tell" -eq 0 ]]; then
      dx_warn "git did not list this repository's worktrees, so this is not a clean bill of health."
      return 0
    fi
    if [[ "$probe_result" -eq 2 ]]; then
      dx_warn "Dex and git agree, but this project's probe did not answer, so this is not a clean bill of health."
      return 0
    fi
    dx_ok "Dex, git and this project agree. Nothing to clean up."
    return 0
  fi

  dx_info "$(printf '%s unregistered director(ies), %s stale git registration(s), %s reported orphan(s)' \
    "$unregistered_count" "$stale_count" "$resource_count")"

  if [[ "$apply" -eq 0 ]]; then
    dx_info "Nothing was removed. Re-run as 'dx worktree audit --apply' to run this project's before_remove hook for those entries and remove them."
    return 0
  fi
  if [[ "$can_tell" -eq 0 ]]; then
    dx_error "git could not list this repository's worktrees, so Dex cannot tell which of these are live. Nothing was removed."
    return 1
  fi

  # --apply acts only on what was printed above, and only inside
  # .dex/worktrees/. A registration outside it belongs to whoever made it.
  # dx_wt_remove reaches git through the working directory, so stand in the
  # checkout whose worktrees these are.
  cd "$DX_WT_REPO_ROOT" || {
    dx_error "Could not enter $DX_WT_REPO_ROOT"
    exit 1
  }
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    dx_info "Removing unregistered worktree directory: ${entry##*/}"
    dx_wt_remove "$entry" "$DX_WT_REPO_ROOT" \
      || dx_warn "Could not remove $entry"
  done < "$unregistered"

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    dx_info "Tearing down the stale registration: ${entry##*/}"
    dx_worktree_hook_run before_remove "$DX_WT_REPO_ROOT" "$entry" "${entry##*/}"
  done < "$stale"

  # A reported orphan has no directory left to run in, so the hook runs from
  # the repository root with the reported line as DX_WORKTREE_NAME, verbatim.
  # The project wrote both the probe and the hook, so it is the project that
  # decides what that line says — see docs/worktree-hooks.md.
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    dx_info "Tearing down the reported orphan: $entry"
    dx_worktree_hook_run before_remove "$DX_WT_REPO_ROOT" \
      "$DX_WT_WORKTREES_DIR/$entry" "$entry"
  done < "$resources"

  git -C "$DX_WT_REPO_ROOT" worktree prune 2>/dev/null || true
  dx_done "Worktree cleanup applied."
}

# ─── add-baseline ───────────────────────────────────────────────────────────

__dx_worktree_add_baseline() {
  local target="" commit="" arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        dx_error "Unknown worktree add-baseline option: $arg"
        usage >&2
        exit 1
        ;;
      *)
        if [[ -z "$target" ]]; then
          target="$arg"
        elif [[ -z "$commit" ]]; then
          commit="$arg"
        else
          dx_error "worktree add-baseline takes a path and a commit."
          usage >&2
          exit 1
        fi
        ;;
    esac
  done
  [[ -n "$target" && -n "$commit" ]] || {
    dx_error "worktree add-baseline requires <path> and <commit>."
    usage >&2
    exit 1
  }

  __dx_worktree_require_repo
  if [[ -e "$target" ]]; then
    dx_error "Refusing to create a baseline checkout at an existing path: $target"
    exit 1
  fi
  case "$target" in
    *"/../"* | *"/..")
      dx_error "Refusing a baseline path that walks upward: $target"
      exit 1
      ;;
  esac

  local parent resolved_parent
  parent="${target%/*}"
  [[ "$parent" != "$target" ]] || parent="."
  mkdir -p "$parent" 2>/dev/null || true
  resolved_parent=$(__dx_worktree_physical "$parent") || {
    dx_error "Could not resolve the directory for $target"
    exit 1
  }
  local resolved="$resolved_parent/${target##*/}"
  if [[ "$resolved" == "$DX_WT_WORKTREES_DIR"/* ]]; then
    dx_error "A baseline checkout does not belong in .dex/worktrees/; Dex lifecycle removal owns that directory."
    exit 1
  fi

  git -C "$DX_WT_REPO_ROOT" worktree add --detach "$resolved" "$commit" >/dev/null || {
    dx_error "Could not create a baseline worktree at $resolved from $commit"
    exit 1
  }
  dx_ok "Baseline checkout at $resolved ($commit)"
  dx_worktree_hook_run after_create "$DX_WT_REPO_ROOT" "$resolved" "${resolved##*/}"
  printf '%s\n' "$resolved"
}

# ─── remove-baseline ────────────────────────────────────────────────────────

__dx_worktree_remove_baseline() {
  local target="" arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        dx_error "Unknown worktree remove-baseline option: $arg"
        usage >&2
        exit 1
        ;;
      *)
        if [[ -z "$target" ]]; then
          target="$arg"
        else
          dx_error "worktree remove-baseline takes one path."
          usage >&2
          exit 1
        fi
        ;;
    esac
  done
  [[ -n "$target" ]] || {
    dx_error "worktree remove-baseline requires <path>."
    usage >&2
    exit 1
  }

  local resolved main_root worktrees_dir
  resolved=$(__dx_worktree_physical "$target") || {
    dx_error "No such baseline checkout: $target"
    exit 1
  }
  main_root=$(__dx_worktree_main_checkout "$resolved") || {
    dx_error "$resolved is not a checkout of any repository."
    exit 1
  }
  if [[ "$resolved" == "$main_root" ]]; then
    dx_error "Refusing to remove the main checkout: $resolved"
    exit 1
  fi
  worktrees_dir="$main_root/.dex/worktrees"
  if [[ "$resolved" == "$worktrees_dir"/* ]]; then
    dx_error "$resolved is a Dex lifecycle worktree. Remove it with dxrm."
    exit 1
  fi
  if ! dx_wt_is_registered "$main_root" "$resolved"; then
    dx_error "$resolved is not a registered worktree of $main_root; Dex will not remove it."
    exit 1
  fi

  dx_worktree_hook_run before_remove "$main_root" "$resolved" "${resolved##*/}"
  if ! git -C "$main_root" worktree remove --force "$resolved" >/dev/null 2>&1; then
    command rm -rf "$resolved" || {
      dx_error "Could not remove the baseline checkout; it is still at $resolved"
      exit 1
    }
    git -C "$main_root" worktree prune 2>/dev/null || true
  fi
  rmdir "${resolved%/*}" 2>/dev/null || true
  dx_done "Removed the baseline checkout at $resolved"
}

main() {
  case "${1:-}" in
    audit)
      shift
      __dx_worktree_audit "$@"
      ;;
    add-baseline)
      shift
      __dx_worktree_add_baseline "$@"
      ;;
    remove-baseline)
      shift
      __dx_worktree_remove_baseline "$@"
      ;;
    -h | --help | "")
      usage
      ;;
    *)
      dx_error "Unknown worktree command: $1"
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"

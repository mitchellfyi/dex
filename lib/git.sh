# shellcheck shell=bash
# Dex shared library — git helpers

# dx_default_branch [git_dir]
# Detect the default branch for the given repo.
# Prefer the remote's symbolic default, then conventional remote/local names,
# the configured init.defaultBranch, and finally the current local branch.
# Optional git_dir: pass a path to run git commands against a specific worktree.
dx_default_branch() {
  local git_args=()
  [[ -n "${1:-}" ]] && git_args=(-C "$1")
  local branch
  # ${arr[@]+...} idiom: expands to nothing when the array is empty. Required because
  # bash 3.2 (macOS default) treats "${arr[@]}" as "unbound variable" under set -u.
  branch=$(git ${git_args[@]+"${git_args[@]}"} symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)
  branch="${branch#refs/remotes/origin/}"
  if [[ -z "$branch" ]]; then
    local candidate configured_default
    for candidate in main master trunk develop; do
      if git ${git_args[@]+"${git_args[@]}"} show-ref --verify --quiet "refs/remotes/origin/${candidate}" 2>/dev/null; then
        branch="$candidate"
        break
      fi
    done
    configured_default=$(git ${git_args[@]+"${git_args[@]}"} config --get init.defaultBranch 2>/dev/null || true)
    if [[ -z "$branch" && -n "$configured_default" ]] \
      && git ${git_args[@]+"${git_args[@]}"} show-ref --verify --quiet "refs/heads/${configured_default}" 2>/dev/null; then
      branch="$configured_default"
    fi
    if [[ -z "$branch" ]]; then
      for candidate in main master trunk develop; do
        if git ${git_args[@]+"${git_args[@]}"} show-ref --verify --quiet "refs/heads/${candidate}" 2>/dev/null; then
          branch="$candidate"
          break
        fi
      done
    fi
    if [[ -z "$branch" ]]; then
      branch=$(git ${git_args[@]+"${git_args[@]}"} symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    fi
    [[ -n "$branch" ]] || branch="main"
  fi
  echo "$branch"
}

# dx_default_branch_base_ref [git_dir] [default_branch] [fetch|no-fetch]
# Resolve the immutable starting point Dex should branch from for new lifecycle
# work. This intentionally ignores the caller's current branch: prefer the
# default branch's configured upstream, then origin/<default>, then
# upstream/<default>, and only then a local default branch.
dx_default_branch_base_ref() {
  local git_dir="${1:-}" default_branch="${2:-}" fetch_mode="${3:-fetch}"
  local git_args=() upstream_ref upstream_remote upstream_branch

  [[ -n "$git_dir" ]] && git_args=(-C "$git_dir")
  [[ -n "$default_branch" ]] || default_branch=$(dx_default_branch "$git_dir")
  if [[ -z "$default_branch" ]]; then
    printf 'ERROR: Could not resolve the default branch.\n' >&2
    return 1
  fi

  if git ${git_args[@]+"${git_args[@]}"} show-ref --verify --quiet "refs/heads/${default_branch}" 2>/dev/null; then
    upstream_ref=$(git ${git_args[@]+"${git_args[@]}"} rev-parse --abbrev-ref "${default_branch}@{upstream}" 2>/dev/null || true)
  fi

  if [[ "$fetch_mode" != "no-fetch" ]]; then
    if [[ "$upstream_ref" == */* ]]; then
      upstream_remote="${upstream_ref%%/*}"
      upstream_branch="${upstream_ref#*/}"
      git ${git_args[@]+"${git_args[@]}"} fetch "$upstream_remote" "$upstream_branch" --quiet 2>/dev/null || true
    fi
    if git ${git_args[@]+"${git_args[@]}"} remote get-url origin >/dev/null 2>&1; then
      git ${git_args[@]+"${git_args[@]}"} fetch origin "$default_branch" --quiet 2>/dev/null || true
    fi
  fi

  if [[ -n "$upstream_ref" ]] && git ${git_args[@]+"${git_args[@]}"} rev-parse --verify --quiet "$upstream_ref" >/dev/null 2>&1; then
    printf '%s\n' "$upstream_ref"
    return 0
  fi

  if git ${git_args[@]+"${git_args[@]}"} show-ref --verify --quiet "refs/remotes/origin/${default_branch}" 2>/dev/null; then
    printf 'origin/%s\n' "$default_branch"
    return 0
  fi

  if git ${git_args[@]+"${git_args[@]}"} show-ref --verify --quiet "refs/remotes/upstream/${default_branch}" 2>/dev/null; then
    printf 'upstream/%s\n' "$default_branch"
    return 0
  fi

  if git ${git_args[@]+"${git_args[@]}"} show-ref --verify --quiet "refs/heads/${default_branch}" 2>/dev/null; then
    printf '%s\n' "$default_branch"
    return 0
  fi

  printf 'ERROR: Could not resolve a starting ref for default branch %s. Fetch its upstream or create the local default branch before starting Dex work.\n' "$default_branch" >&2
  return 1
}

# __dx_checkpoint_canonical_git_dir <wt_dir> <git-dir|git-common-dir>
# Resolve Git's administrative directory so linked worktrees can be identified
# without depending on their branch name.
__dx_checkpoint_canonical_git_dir() {
  local wt_dir="$1" mode="$2" root raw_dir
  root=$(git -C "$wt_dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  raw_dir=$(git -C "$root" rev-parse "--${mode}" 2>/dev/null) || return 1
  (cd "$root" && cd "$raw_dir" && pwd -P)
}

# __dx_checkpoint_workspace_namespace <wt_dir>
# Return a ref-safe namespace that is stable across linked-worktree branch
# renames. In-place checkouts include the branch so separate lifecycles do not
# share checkpoints in the main worktree.
__dx_checkpoint_workspace_namespace() {
  local wt_dir="$1" git_dir common_dir identity label branch slug digest
  git_dir=$(__dx_checkpoint_canonical_git_dir "$wt_dir" git-dir) || return 1
  common_dir=$(__dx_checkpoint_canonical_git_dir "$wt_dir" git-common-dir) || return 1

  if [[ "$git_dir" != "$common_dir" ]]; then
    identity="linked:${git_dir#"$common_dir"/}"
    label="worktree-${git_dir##*/}"
  else
    branch=$(git -C "$wt_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [[ -n "$branch" ]] || branch="detached"
    identity="in-place:${branch}"
    label="branch-${branch}"
  fi

  slug=$(dx_slugify "$label")
  [[ -n "$slug" ]] || slug="workspace"
  slug=$(printf '%.48s' "$slug")
  digest=$(printf '%s' "$identity" | git -C "$wt_dir" hash-object --stdin 2>/dev/null) || return 1
  [[ -n "$digest" ]] || return 1
  printf '%s-%s\n' "$slug" "$digest"
}

# dx_checkpoint_ref <step> <wt_dir>
# Return the full, workspace-scoped ref for a phase checkpoint.
dx_checkpoint_ref() {
  local step="$1" wt_dir="$2" namespace
  [[ "$step" =~ ^[0-9]+$ ]] || return 1
  namespace=$(__dx_checkpoint_workspace_namespace "$wt_dir") || return 1
  printf 'refs/tags/dx-checkpoint/%s/phase-%s\n' "$namespace" "$step"
}

# __dx_legacy_checkpoint_is_safe <ref> <wt_dir>
# Legacy refs were shared by every worktree. Accept one only when the target is
# on this checkout's history and no other registered checkout can own it.
__dx_legacy_checkpoint_is_safe() {
  local ref="$1" wt_dir="$2" target current_root worktrees line other_root other_head
  target=$(git -C "$wt_dir" rev-parse --verify "${ref}^{commit}" 2>/dev/null) || return 1
  git -C "$wt_dir" merge-base --is-ancestor "$target" HEAD 2>/dev/null || return 1

  current_root=$(git -C "$wt_dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  current_root=$(cd "$current_root" && pwd -P) || return 1
  worktrees=$(git -C "$wt_dir" worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    [[ "$line" == worktree\ * ]] || continue
    other_root="${line#worktree }"
    other_root=$(cd "$other_root" 2>/dev/null && pwd -P) || return 1
    [[ "$other_root" != "$current_root" ]] || continue
    other_head=$(git -C "$other_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
    if git -C "$wt_dir" merge-base --is-ancestor "$target" "$other_head" 2>/dev/null; then
      return 1
    fi
  done <<< "$worktrees"
  return 0
}

# __dx_checkpoint_ref_for_phase <step> <wt_dir>
# Prefer the scoped ref, with a guarded fallback for checkpoints made by older
# Dex versions.
__dx_checkpoint_ref_for_phase() {
  local step="$1" wt_dir="$2" ref legacy_ref
  ref=$(dx_checkpoint_ref "$step" "$wt_dir") || return 1
  if git -C "$wt_dir" show-ref --verify --quiet "$ref" 2>/dev/null; then
    printf '%s\n' "$ref"
    return 0
  fi

  legacy_ref="refs/tags/dx-checkpoint/phase-${step}"
  if git -C "$wt_dir" show-ref --verify --quiet "$legacy_ref" 2>/dev/null \
    && __dx_legacy_checkpoint_is_safe "$legacy_ref" "$wt_dir"; then
    printf '%s\n' "$legacy_ref"
    return 0
  fi
  return 1
}

# dx_checkpoint_tag <step> <wt_dir>
# Create or update this workspace's lightweight checkpoint at the current HEAD.
dx_checkpoint_tag() {
  local step="$1" wt_dir="$2" ref target
  ref=$(dx_checkpoint_ref "$step" "$wt_dir") || return 0
  target=$(git -C "$wt_dir" rev-parse --verify HEAD 2>/dev/null) || return 0
  # A failed checkpoint used to be silent, surfacing much later as
  # "No checkpoint found for phase N" when someone tried to revert.
  git -C "$wt_dir" update-ref "$ref" "$target" >/dev/null 2>&1 ||
    dx_warn "Could not record the phase ${step} checkpoint; revert will not be available for it"
}

# dx_latest_checkpoint_phase <wt_dir>
# Print the highest checkpoint phase owned by this workspace.
dx_latest_checkpoint_phase() {
  local wt_dir="$1" namespace tags tag phase legacy_ref
  namespace=$(__dx_checkpoint_workspace_namespace "$wt_dir") || return 1
  tags=$(git -C "$wt_dir" tag -l "dx-checkpoint/${namespace}/phase-*" --sort=-version:refname 2>/dev/null)
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    phase="${tag##*-}"
    if [[ "$phase" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$phase"
      return 0
    fi
  done <<< "$tags"

  tags=$(git -C "$wt_dir" tag -l 'dx-checkpoint/phase-*' --sort=-version:refname 2>/dev/null)
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    phase="${tag##*-}"
    [[ "$phase" =~ ^[0-9]+$ ]] || continue
    legacy_ref="refs/tags/${tag}"
    if __dx_legacy_checkpoint_is_safe "$legacy_ref" "$wt_dir"; then
      printf '%s\n' "$phase"
      return 0
    fi
  done <<< "$tags"
  return 1
}

# dx_revert_to_checkpoint <step> <wt_dir>
# Reset the worktree to its checkpoint for the given phase.
dx_revert_to_checkpoint() {
  local step="$1" wt_dir="$2" ref legacy_ref
  if ! ref=$(__dx_checkpoint_ref_for_phase "$step" "$wt_dir"); then
    legacy_ref="refs/tags/dx-checkpoint/phase-${step}"
    if git -C "$wt_dir" show-ref --verify --quiet "$legacy_ref" 2>/dev/null; then
      printf 'The phase %s checkpoint uses the old shared format and cannot be assigned safely to this worktree.\n' "$step"
    else
      printf 'No checkpoint found for phase %s.\n' "$step"
    fi
    return 1
  fi
  git -C "$wt_dir" reset --hard "$ref"
  git -C "$wt_dir" clean -fd
}

# dx_cleanup_checkpoints <wt_dir>
# Delete checkpoints owned by this workspace. Safe legacy refs are cleaned up
# for compatibility; ambiguous shared refs are left untouched.
dx_cleanup_checkpoints() {
  local wt_dir="$1" namespace tags tag legacy_ref
  namespace=$(__dx_checkpoint_workspace_namespace "$wt_dir") || return 0
  tags=$(git -C "$wt_dir" tag -l "dx-checkpoint/${namespace}/phase-*" 2>/dev/null)
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    git -C "$wt_dir" tag -d "$tag" >/dev/null 2>&1 || true
  done <<< "$tags"

  tags=$(git -C "$wt_dir" tag -l 'dx-checkpoint/phase-*' 2>/dev/null)
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    legacy_ref="refs/tags/${tag}"
    if __dx_legacy_checkpoint_is_safe "$legacy_ref" "$wt_dir"; then
      git -C "$wt_dir" tag -d "$tag" >/dev/null 2>&1 || true
    fi
  done <<< "$tags"
}

# dx_slugify <string>
# Lowercase, replace non-alphanumeric with dashes, collapse double dashes, trim edges.
# Works in both bash and zsh.
dx_slugify() {
  local slug
  slug=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  slug=$(printf '%s' "$slug" | LC_ALL=C sed 's/[^a-z0-9]/-/g')  # replace non-alphanumeric → dashes (locale-safe)
  while [[ "$slug" == *--* ]]; do slug="${slug//--/-}"; done  # collapse consecutive dashes
  slug="${slug#-}"   # trim leading dash
  slug="${slug%-}"   # trim trailing dash
  echo "$slug"
}

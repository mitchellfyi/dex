# shellcheck shell=bash
# Dex shared library — git helpers

# dx_default_branch [git_dir]
# Detect the default branch (main/master) for the given repo.
# Tries: origin/HEAD symbolic ref → origin/main exists → origin/master exists → "main" fallback.
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
    if git ${git_args[@]+"${git_args[@]}"} show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
      branch="main"
    elif git ${git_args[@]+"${git_args[@]}"} show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
      branch="master"
    else
      branch="main"
    fi
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

# dx_checkpoint_tag <step> <wt_dir>
# Create a lightweight local git tag at the current HEAD as a phase checkpoint.
# Uses --force so re-running a phase overwrites the previous checkpoint.
dx_checkpoint_tag() {
  local step="$1" wt_dir="$2"
  git -C "$wt_dir" tag "dx-checkpoint/phase-${step}" --force 2>/dev/null || true
}

# dx_revert_to_checkpoint <step> <wt_dir>
# Reset the worktree to the checkpoint tag for the given phase.
# Returns 1 if the checkpoint tag doesn't exist.
dx_revert_to_checkpoint() {
  local step="$1" wt_dir="$2"
  local tag="dx-checkpoint/phase-${step}"
  if ! git -C "$wt_dir" rev-parse --verify "$tag" &>/dev/null; then
    echo "No checkpoint found for phase ${step}."
    return 1
  fi
  git -C "$wt_dir" reset --hard "$tag"
  git -C "$wt_dir" clean -fd
}

# dx_cleanup_checkpoints <wt_dir>
# Delete all dx-checkpoint tags in the worktree.
dx_cleanup_checkpoints() {
  local wt_dir="$1"
  local tags
  tags=$(git -C "$wt_dir" tag -l 'dx-checkpoint/*' 2>/dev/null)
  if [[ -n "$tags" ]]; then
    echo "$tags" | xargs -I{} git -C "$wt_dir" tag -d {} 2>/dev/null
  fi
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

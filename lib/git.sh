# shellcheck shell=bash
# Doyaken shared library — git helpers

# dk_default_branch [git_dir]
# Detect the default branch (main/master) for the given repo.
# Tries: origin/HEAD symbolic ref → origin/main exists → origin/master exists → "main" fallback.
# Optional git_dir: pass a path to run git commands against a specific worktree.
dk_default_branch() {
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

# dk_checkpoint_tag <step> <wt_dir>
# Create a lightweight local git tag at the current HEAD as a phase checkpoint.
# Uses --force so re-running a phase overwrites the previous checkpoint.
dk_checkpoint_tag() {
  local step="$1" wt_dir="$2"
  git -C "$wt_dir" tag "dk-checkpoint/phase-${step}" --force 2>/dev/null || true
}

# dk_revert_to_checkpoint <step> <wt_dir>
# Reset the worktree to the checkpoint tag for the given phase.
# Returns 1 if the checkpoint tag doesn't exist.
dk_revert_to_checkpoint() {
  local step="$1" wt_dir="$2"
  local tag="dk-checkpoint/phase-${step}"
  if ! git -C "$wt_dir" rev-parse --verify "$tag" &>/dev/null; then
    echo "No checkpoint found for phase ${step}."
    return 1
  fi
  git -C "$wt_dir" reset --hard "$tag"
  git -C "$wt_dir" clean -fd
}

# dk_cleanup_checkpoints <wt_dir>
# Delete all dk-checkpoint tags in the worktree.
dk_cleanup_checkpoints() {
  local wt_dir="$1"
  local tags
  tags=$(git -C "$wt_dir" tag -l 'dk-checkpoint/*' 2>/dev/null)
  if [[ -n "$tags" ]]; then
    echo "$tags" | xargs -I{} git -C "$wt_dir" tag -d {} 2>/dev/null
  fi
}

# dk_slugify <string>
# Lowercase, replace non-alphanumeric with dashes, collapse double dashes, trim edges.
# Works in both bash and zsh.
dk_slugify() {
  local slug
  slug=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  slug=$(printf '%s' "$slug" | LC_ALL=C sed 's/[^a-z0-9]/-/g')  # replace non-alphanumeric → dashes (locale-safe)
  while [[ "$slug" == *--* ]]; do slug="${slug//--/-}"; done  # collapse consecutive dashes
  slug="${slug#-}"   # trim leading dash
  slug="${slug%-}"   # trim trailing dash
  echo "$slug"
}

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

# Run a remote operation through Dex's portable timeout supervisor when the
# full shared library is loaded. Direct lib/git.sh consumers still work.
__dx_ticket_branch_run() {
  local timeout_seconds="$1"
  shift
  if command -v dx_run_with_timeout >/dev/null 2>&1; then
    dx_run_with_timeout "$timeout_seconds" "$@"
  else
    "$@"
  fi
}

__dx_ticket_branch_gh() {
  local repo_dir="$1"
  shift
  (cd "$repo_dir" && gh "$@")
}

# Print the worktree that currently owns a local branch, if any.
__dx_ticket_branch_worktree() {
  local repo_dir="$1" branch_name="$2" worktree_dir="" record_line
  while IFS= read -r record_line; do
    case "$record_line" in
      worktree\ *) worktree_dir="${record_line#worktree }" ;;
      "branch refs/heads/${branch_name}")
        printf '%s\n' "$worktree_dir"
        return 0
        ;;
    esac
  done < <(git -C "$repo_dir" worktree list --porcelain 2>/dev/null)
  return 1
}

# Return success only when replacing the current branch cannot discard work.
__dx_ticket_branch_placeholder_safe() {
  local repo_dir="$1" current_branch="$2" current_oid="$3"
  local session_id="${DEX_SESSION_ID:-}" original_branch="" original_head=""
  local default_branch base_ref base_oid upstream_ref

  if [[ -n "$session_id" ]] && command -v dx_meta_read >/dev/null 2>&1; then
    original_branch=$(dx_meta_read "$session_id" original_branch)
    original_head=$(dx_meta_read "$session_id" original_head)
    if [[ -n "$original_branch" && -n "$original_head" ]]; then
      [[ "$original_branch" == "$current_branch" \
        && "$original_head" == "$current_oid" ]]
      return $?
    fi
    # Older Phase 0 sessions recorded only original_branch. Keep their guarded
    # default-tip fallback instead of making the upgrade path unusable.
    [[ -z "$original_head" ]] || return 1
    [[ -z "$original_branch" || "$original_branch" == "$current_branch" ]] \
      || return 1
  fi

  case "$current_branch" in
    worktree-ticket-*|worktree-task-*) ;;
    *) return 1 ;;
  esac
  upstream_ref=$(git -C "$repo_dir" rev-parse --abbrev-ref \
    --symbolic-full-name '@{u}' 2>/dev/null || true)
  [[ -z "$upstream_ref" ]] || return 1
  default_branch=$(dx_default_branch "$repo_dir") || return 1
  base_ref=$(dx_default_branch_base_ref "$repo_dir" "$default_branch" no-fetch) \
    || return 1
  base_oid=$(git -C "$repo_dir" rev-parse --verify "${base_ref}^{commit}" \
    2>/dev/null) || return 1
  [[ "$current_oid" == "$base_oid" ]]
}

# Print OPEN, NONE, or HISTORICAL for pull requests whose head is branch_name.
__dx_ticket_branch_pr_kind() {
  local repo_dir="$1" branch_name="$2" timeout_seconds="$3"
  local open_count="" any_count="" pr_result=0

  if ! command -v gh >/dev/null 2>&1; then
    printf 'ERROR: Remote branch %s exists, but GitHub CLI is unavailable; Dex cannot verify whether its pull request is still open.\n' \
      "$branch_name" >&2
    return 1
  fi

  open_count=$(__dx_ticket_branch_run "$timeout_seconds" \
    __dx_ticket_branch_gh "$repo_dir" pr list --state open \
    --head "$branch_name" --limit 1 --json number --jq length 2>/dev/null) \
    || pr_result=$?
  if [[ "$pr_result" -ne 0 || ! "$open_count" =~ ^[0-9]+$ ]]; then
    if [[ "$pr_result" -eq 124 ]]; then
      printf 'ERROR: Timed out while checking open pull requests for remote branch %s.\n' \
        "$branch_name" >&2
    else
      printf 'ERROR: Could not check pull requests for remote branch %s. Confirm GitHub CLI authentication, then try again.\n' \
        "$branch_name" >&2
    fi
    return 1
  fi
  if [[ "$open_count" -gt 0 ]]; then
    printf 'OPEN\n'
    return 0
  fi

  pr_result=0
  any_count=$(__dx_ticket_branch_run "$timeout_seconds" \
    __dx_ticket_branch_gh "$repo_dir" pr list --state all \
    --head "$branch_name" --limit 1 --json number --jq length 2>/dev/null) \
    || pr_result=$?
  if [[ "$pr_result" -ne 0 || ! "$any_count" =~ ^[0-9]+$ ]]; then
    if [[ "$pr_result" -eq 124 ]]; then
      printf 'ERROR: Timed out while checking pull-request history for remote branch %s.\n' \
        "$branch_name" >&2
    else
      printf 'ERROR: Could not check pull-request history for remote branch %s. Confirm GitHub CLI authentication, then try again.\n' \
        "$branch_name" >&2
    fi
    return 1
  fi
  if [[ "$any_count" -eq 0 ]]; then
    printf 'NONE\n'
  else
    printf 'HISTORICAL\n'
  fi
}

__dx_ticket_branch_record() {
  local repo_dir="$1" branch_name="$2" branch_source="$3"
  local remote_oid="${4:-}" pr_kind="${5:-}" session_id="${DEX_SESSION_ID:-}"
  local remote_name=""
  [[ -n "$session_id" ]] || return 0
  [[ "$branch_source" == "remote" ]] && remote_name="origin"

  if command -v dx_record_session_branch >/dev/null 2>&1; then
    if ! dx_record_session_branch "$session_id" "$repo_dir"; then
      printf 'ERROR: Branch %s is ready, but Dex could not update the saved lifecycle branch.\n' \
        "$branch_name" >&2
      return 1
    fi
  fi
  if command -v dx_meta_write >/dev/null 2>&1; then
    if ! dx_meta_write "$session_id" \
      "current_branch=${branch_name}" \
      "ticket_branch_source=${branch_source}" \
      "ticket_branch_remote=${remote_name}" \
      "ticket_branch_remote_oid=${remote_oid}" \
      "ticket_branch_pr_kind=${pr_kind}"; then
      printf 'ERROR: Branch %s is ready, but Dex could not update its session metadata.\n' \
        "$branch_name" >&2
      return 1
    fi
  fi
}

# dx_ticket_branch_prepare <tracker_branch> [repo_dir]
# Adopt an eligible origin branch, reuse a compatible local branch, or rename
# the untouched lifecycle placeholder. Prints remote, local, or new.
dx_ticket_branch_prepare() {
  local branch_name="${1:-}" repo_dir="${2:-.}" remote_name="origin"
  local current_branch current_oid dirty_output remote_line="" remote_result=0
  local remote_oid="" remote_ref="" pr_kind="" fetch_result=0
  local local_oid="" owning_worktree="" branch_source="" original_branch=""
  local remote_timeout_seconds=60 pr_timeout_seconds=30

  if [[ -z "$branch_name" ]] \
    || ! git check-ref-format "refs/heads/${branch_name}" >/dev/null 2>&1 \
    || ! git check-ref-format --branch "$branch_name" >/dev/null 2>&1; then
    printf 'ERROR: Tracker branch name is missing or invalid: %s\n' \
      "${branch_name:-<empty>}" >&2
    return 1
  fi
  if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'ERROR: Ticket branch setup requires a Git worktree: %s\n' \
      "$repo_dir" >&2
    return 1
  fi
  if ! git -C "$repo_dir" remote get-url "$remote_name" >/dev/null 2>&1; then
    printf 'ERROR: Ticket branch setup requires the %s remote.\n' \
      "$remote_name" >&2
    return 1
  fi

  current_branch=$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD \
    2>/dev/null || true)
  if [[ -z "$current_branch" ]]; then
    printf 'ERROR: Ticket branch setup cannot run from a detached HEAD.\n' >&2
    return 1
  fi
  current_oid=$(git -C "$repo_dir" rev-parse --verify 'HEAD^{commit}' \
    2>/dev/null) || return 1
  dirty_output=$(git -C "$repo_dir" status --porcelain 2>/dev/null) || {
    printf 'ERROR: Could not inspect the ticket worktree before branch setup.\n' >&2
    return 1
  }
  # A dirty tree blocks only the paths below that move the working tree —
  # ff-merge, branch switch, and hard reset. Pure bookkeeping (recording
  # state on the current branch, or renaming it in place) must tolerate
  # local changes: in-place mode explicitly proceeds with a dirty checkout
  # and carries those changes into the lifecycle scope.
  local tree_dirty=0
  [[ -n "$dirty_output" ]] && tree_dirty=1

  remote_line=$(__dx_ticket_branch_run "$remote_timeout_seconds" \
    git -C "$repo_dir" ls-remote --heads --exit-code "$remote_name" \
    "refs/heads/${branch_name}" 2>/dev/null) || remote_result=$?
  case "$remote_result" in
    0)
      remote_oid="${remote_line%%[[:space:]]*}"
      if [[ ! "$remote_oid" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
        printf 'ERROR: Remote branch %s returned an invalid commit ID.\n' \
          "$branch_name" >&2
        return 1
      fi
      ;;
    2) remote_oid="" ;;
    124)
      printf 'ERROR: Timed out while checking origin for ticket branch %s.\n' \
        "$branch_name" >&2
      return 1
      ;;
    *)
      printf 'ERROR: Could not check origin for ticket branch %s. Dex will not treat a remote failure as a missing branch.\n' \
        "$branch_name" >&2
      return 1
      ;;
  esac

  remote_ref="refs/remotes/${remote_name}/${branch_name}"
  if [[ -n "$remote_oid" ]]; then
    __dx_ticket_branch_run "$remote_timeout_seconds" \
      git -C "$repo_dir" fetch --quiet --no-tags "$remote_name" \
      "+refs/heads/${branch_name}:${remote_ref}" 2>/dev/null \
      || fetch_result=$?
    if [[ "$fetch_result" -ne 0 ]]; then
      if [[ "$fetch_result" -eq 124 ]]; then
        printf 'ERROR: Timed out while fetching ticket branch %s from origin.\n' \
          "$branch_name" >&2
      else
        printf 'ERROR: Failed to fetch ticket branch %s from origin.\n' \
          "$branch_name" >&2
      fi
      return 1
    fi
    remote_oid=$(git -C "$repo_dir" rev-parse --verify "${remote_ref}^{commit}" \
      2>/dev/null) || return 1
    pr_kind=$(__dx_ticket_branch_pr_kind "$repo_dir" "$branch_name" \
      "$pr_timeout_seconds") || return 1
    if [[ "$pr_kind" == "HISTORICAL" ]]; then
      printf 'ERROR: Remote branch %s has only closed or merged pull requests. Dex will not resume it automatically. Reopen the pull request or choose a new branch.\n' \
        "$branch_name" >&2
      return 1
    fi
    branch_source="remote"
  fi

  if [[ "$current_branch" == "$branch_name" ]]; then
    if [[ -n "$remote_oid" ]]; then
      local_oid="$current_oid"
      if git -C "$repo_dir" merge-base --is-ancestor "$local_oid" \
          "$remote_oid" 2>/dev/null; then
        if [[ "$tree_dirty" -eq 1 ]]; then
          printf 'ERROR: Cannot prepare ticket branch %s with uncommitted changes. Commit, stash, or discard them, then try again.\n' \
            "$branch_name" >&2
          return 1
        fi
        git -C "$repo_dir" merge --ff-only --quiet "$remote_ref" || return 1
      elif git -C "$repo_dir" merge-base --is-ancestor "$remote_oid" \
          "$local_oid" 2>/dev/null; then
        : # Preserve local commits that are already based on the remote branch.
      else
        printf 'ERROR: Local branch %s has diverged from origin. Resolve it before resuming Dex.\n' \
          "$branch_name" >&2
        return 1
      fi
      git -C "$repo_dir" branch --set-upstream-to="${remote_name}/${branch_name}" \
        "$branch_name" >/dev/null || return 1
    else
      branch_source=""
      if command -v dx_meta_read >/dev/null 2>&1; then
        branch_source=$(dx_meta_read "${DEX_SESSION_ID:-}" \
          ticket_branch_source 2>/dev/null || true)
      fi
      [[ "$branch_source" == "new" || "$branch_source" == "local" ]] \
        || branch_source="local"
      git -C "$repo_dir" branch --unset-upstream "$branch_name" \
        >/dev/null 2>&1 || true
    fi
    __dx_ticket_branch_record "$repo_dir" "$branch_name" "$branch_source" \
      "$remote_oid" "$pr_kind" || return 1
    printf '%s\n' "$branch_source"
    return 0
  fi

  if git -C "$repo_dir" show-ref --verify --quiet \
      "refs/heads/${branch_name}" 2>/dev/null; then
    owning_worktree=$(__dx_ticket_branch_worktree "$repo_dir" "$branch_name" \
      2>/dev/null || true)
    if [[ -n "$owning_worktree" ]]; then
      printf 'ERROR: Ticket branch %s is already checked out at %s. Resume that workspace instead.\n' \
        "$branch_name" "$owning_worktree" >&2
      return 1
    fi
    if ! __dx_ticket_branch_placeholder_safe "$repo_dir" "$current_branch" \
        "$current_oid"; then
      printf 'ERROR: Dex will not leave branch %s because it no longer matches the untouched lifecycle starting point.\n' \
        "$current_branch" >&2
      return 1
    fi
    local_oid=$(git -C "$repo_dir" rev-parse --verify \
      "refs/heads/${branch_name}^{commit}" 2>/dev/null) || return 1
    if [[ -n "$remote_oid" ]]; then
      if git -C "$repo_dir" merge-base --is-ancestor "$local_oid" \
          "$remote_oid" 2>/dev/null; then
        git -C "$repo_dir" branch -f "$branch_name" "$remote_ref" \
          >/dev/null || return 1
      elif git -C "$repo_dir" merge-base --is-ancestor "$remote_oid" \
          "$local_oid" 2>/dev/null; then
        : # Keep compatible local commits ahead of origin.
      else
        printf 'ERROR: Existing local branch %s has diverged from origin. Dex preserved both branches for manual reconciliation.\n' \
          "$branch_name" >&2
        return 1
      fi
    else
      branch_source="local"
    fi
    if [[ "$tree_dirty" -eq 1 ]]; then
      printf 'ERROR: Cannot prepare ticket branch %s with uncommitted changes. Commit, stash, or discard them, then try again.\n' \
        "$branch_name" >&2
      return 1
    fi
    git -C "$repo_dir" switch --quiet "$branch_name" || return 1
    case "$current_branch" in
      worktree-ticket-*|worktree-task-*)
        git -C "$repo_dir" branch -D "$current_branch" >/dev/null || return 1
        ;;
    esac
  elif [[ -n "$remote_oid" ]]; then
    if ! __dx_ticket_branch_placeholder_safe "$repo_dir" "$current_branch" \
        "$current_oid"; then
      printf 'ERROR: Dex will not replace branch %s because it no longer matches the untouched lifecycle starting point.\n' \
        "$current_branch" >&2
      return 1
    fi
    if [[ "$tree_dirty" -eq 1 ]]; then
      printf 'ERROR: Cannot prepare ticket branch %s with uncommitted changes. Commit, stash, or discard them, then try again.\n' \
        "$branch_name" >&2
      return 1
    fi
    original_branch="$current_branch"
    git -C "$repo_dir" branch -m "$branch_name" || return 1
    if ! git -C "$repo_dir" reset --hard --quiet "$remote_ref"; then
      git -C "$repo_dir" branch -m "$original_branch" 2>/dev/null || true
      return 1
    fi
  else
    git -C "$repo_dir" branch -m "$branch_name" || return 1
    branch_source="new"
  fi

  if [[ -n "$remote_oid" ]]; then
    git -C "$repo_dir" branch --set-upstream-to="${remote_name}/${branch_name}" \
      "$branch_name" >/dev/null || return 1
  else
    git -C "$repo_dir" branch --unset-upstream "$branch_name" \
      >/dev/null 2>&1 || true
  fi
  __dx_ticket_branch_record "$repo_dir" "$branch_name" "$branch_source" \
    "$remote_oid" "$pr_kind" || return 1
  printf '%s\n' "$branch_source"
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

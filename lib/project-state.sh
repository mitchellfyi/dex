# shellcheck shell=bash
# Dex shared library - project file ownership tracking

dx_project_state_file() {
  local repo_root="$1"
  local git_dir

  if ! git_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --absolute-git-dir 2>/dev/null); then
    return 1
  fi
  printf '%s\n' "$git_dir/dex-project-state.json"
}

dx_project_state_begin() {
  local repo_root="$1"
  local state_file

  state_file=$(dx_project_state_file "$repo_root") || return 1
  python3 "$DEX_DIR/scripts/project-state.py" project-begin "$repo_root" "$state_file"
}

dx_project_state_finalize() {
  local repo_root="$1"
  local state_file

  state_file=$(dx_project_state_file "$repo_root") || return 1
  python3 "$DEX_DIR/scripts/project-state.py" project-finalize "$repo_root" "$state_file"
}

dx_project_state_remove_managed() {
  local repo_root="$1"
  local state_file

  state_file=$(dx_project_state_file "$repo_root") || return 1
  [[ -f "$state_file" ]] || return 3
  python3 "$DEX_DIR/scripts/project-state.py" project-remove "$repo_root" "$state_file"
}

dx_project_has_other_init_state() {
  local repo_root="$1"
  local current_git_dir line worktree_path candidate_git_dir worktree_output git_status

  if current_git_dir=$(git -C "$repo_root" rev-parse --path-format=absolute \
    --absolute-git-dir 2>/dev/null); then
    :
  else
    git_status=$?
    return "$git_status"
  fi
  if worktree_output=$(git -C "$repo_root" worktree list --porcelain 2>/dev/null); then
    :
  else
    git_status=$?
    return "$git_status"
  fi
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        worktree_path=${line#worktree }
        if candidate_git_dir=$(git -C "$worktree_path" rev-parse --path-format=absolute \
          --absolute-git-dir 2>/dev/null); then
          :
        else
          git_status=$?
          return "$git_status"
        fi
        if [[ "$candidate_git_dir" != "$current_git_dir" ]] \
          && [[ -f "$candidate_git_dir/dex-project-state.json" ]]; then
          return 0
        fi
        ;;
    esac
  done < <(printf '%s\n' "$worktree_output")
  return 1
}

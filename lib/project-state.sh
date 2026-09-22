# shellcheck shell=bash
# Dex shared library - project file ownership tracking and the machine-readable
# half of the `.dex/dex.md` project contract.

# dx_project_contract_values <repo-dir> <section> <key>
# Read one key out of the fenced block under `## <section>` in the repository's
# `.dex/dex.md`, one value per line.
#
# This is the only entry point for the machine-readable part of the project
# contract, so every section that grows one — `## Resources` and
# `## Worktree Hooks` today — parses the same way and a caller never
# re-implements the reading. The parser is
# scripts/project-contract.py: stdlib only, a flat mapping of scalars and lists.
#
# Returns 0 with the value, 1 when the file, the section, the block or the key
# is absent — which every caller must treat as "this project declared nothing"
# and carry on — and 2 when the block exists but is not a flat mapping, with
# the reason on stderr.
dx_project_contract_values() {
  [[ $# -eq 3 ]] || return 2
  local repo_dir="$1" contract_section="$2" contract_key="$3" contract_file
  [[ -n "$repo_dir" && -n "$contract_section" && -n "$contract_key" ]] || return 2
  contract_file="$repo_dir/.dex/dex.md"
  [[ -f "$contract_file" ]] || return 1
  python3 "$DEX_DIR/scripts/project-contract.py" "$contract_file" \
    "$contract_section" "$contract_key"
}

# dx_project_worktree_hook <repo-dir> <hook-name>
# The shell command a project declared for one worktree lifecycle hook, from
# the fenced block under `## Worktree Hooks` in its `.dex/dex.md`.
#
# The same parser and the same return codes as dx_project_contract_values,
# which this is a named front door for. The difference is the closed key set:
# a misspelled hook name is a Dex bug, so it returns 2 here instead of looking
# like a project that declared nothing.
dx_project_worktree_hook() {
  [[ $# -eq 2 ]] || return 2
  local hook_repo="$1" hook_key="$2"
  case "$hook_key" in
    after_create | before_remove | on_session_end | orphan_resources) ;;
    *) return 2 ;;
  esac
  dx_project_contract_values "$hook_repo" "Worktree Hooks" "$hook_key"
}

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
        # A worktree whose directory was deleted without `git worktree prune`
        # still appears in the porcelain listing. It is not an active checkout,
        # so skip it rather than aborting uninit and attribution restore.
        [[ -d "$worktree_path" ]] || continue
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

#!/usr/bin/env bash
# Run Dex's own checks or verify the current project through its provider.
set -euo pipefail

# shellcheck source=lib/common.sh
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: dx test [dex|project] [filters...]

Run Dex's own checks or verify the current project with its selected provider.

Modes:
  dex       Run tests/check.sh, then tests/run-all.sh with optional filters
  project   Run the dxverify workflow for the current project; filters are invalid

Default: dex in the Dex checkout, project in any other Git repository.
EOF
}

git_common_dir() {
  local work_root="$1" common_dir
  common_dir=$(git -C "$work_root" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common_dir" in
    /*) ;;
    *) common_dir="$work_root/$common_dir" ;;
  esac
  (cd "$common_dir" 2>/dev/null && pwd -P)
}

current_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

run_dex_tests() {
  local dex_root
  dex_root=$(cd "$DEX_DIR" 2>/dev/null && pwd -P) || {
    dx_error "Dex installation directory is not readable: $DEX_DIR"
    return 1
  }
  if [[ ! -f "$dex_root/tests/check.sh" || ! -f "$dex_root/tests/run-all.sh" ]]; then
    dx_error "Dex test scripts were not found under $dex_root/tests."
    return 1
  fi

  dx_info "Running Dex static checks"
  (
    cd "$dex_root"
    bash tests/check.sh
    dx_info "Running Dex tests"
    bash tests/run-all.sh "$@"
  )
}

run_project_tests() {
  local repo_root dex_config provider_context verify_prompt provider_payload
  local provider_exit=0
  local provider_args=()

  repo_root=$(current_repo_root) || {
    dx_error "Not in a git repository."
    return 1
  }
  dex_config="$repo_root/.dex/dex.md"
  if [[ ! -f "$dex_config" || ! -r "$dex_config" ]]; then
    dx_error ".dex/dex.md not found or unreadable. Run 'dx init' first."
    return 1
  fi
  if ! grep -q '^## Quality Gates[[:space:]]*$' "$dex_config"; then
    dx_error ".dex/dex.md has no Quality Gates section. Run 'dx init' to refresh it."
    return 1
  fi

  cd "$repo_root"
  dx_provider_apply || provider_exit=$?
  if [[ $provider_exit -ne 0 ]]; then
    dx_error "Could not resolve the verification provider."
    return "$provider_exit"
  fi

  dx_provider_agent_ready_check || provider_exit=$?
  if [[ $provider_exit -ne 0 ]]; then
    dx_error "The selected verification provider is not ready."
    return "$provider_exit"
  fi

  provider_context=$(dx_provider_prompt) || provider_exit=$?
  if [[ $provider_exit -ne 0 ]]; then
    dx_error "Could not prepare the verification provider prompt."
    return "$provider_exit"
  fi
  verify_prompt=$(cat <<'EOF'
Use the dxverify skill to verify this repository. Read .dex/dex.md first and
treat its Quality Gates section as authoritative. Run every required gate,
fix valid failures, and rerun the affected checks. Report the exact results;
do not claim success while a required gate is failing.
EOF
)
  provider_payload="${verify_prompt}"$'\n'"${provider_context}"
  provider_args=(-p "$provider_payload")
  [[ -n "${DX_CLAUDE_MODEL:-}" ]] && provider_args+=(--model "$DX_CLAUDE_MODEL")
  [[ -n "${DX_CLAUDE_EFFORT:-}" ]] && provider_args+=(--effort "$DX_CLAUDE_EFFORT")
  provider_args+=(--dangerously-skip-permissions --permission-mode bypassPermissions)

  dx_info "Launching verification provider: ${DX_PROVIDER_PROFILE_RESOLVED:-unknown} (${DX_PROVIDER_ENGINE:-unknown})"
  provider_exit=0
  dx_provider_claude "${provider_args[@]}" || provider_exit=$?
  if [[ $provider_exit -ne 0 ]]; then
    dx_error "Verification provider exited with code $provider_exit."
    return "$provider_exit"
  fi
  dx_done "Project verification provider completed."
}

mode=""
case "${1:-}" in
  -h|--help|help)
    [[ $# -eq 1 ]] || {
      dx_error "Usage: dx test --help"
      exit 1
    }
    usage
    exit 0
    ;;
  dex|project)
    mode="$1"
    shift
    ;;
  "") ;;
  -*)
    dx_error "Unknown test option: $1"
    usage >&2
    exit 1
    ;;
  *)
    dx_error "Unknown test mode: $1"
    usage >&2
    exit 1
    ;;
esac

if [[ -z "$mode" ]]; then
  repo_root=$(current_repo_root) || {
    dx_error "Not in a git repository. Choose 'dx test dex' to test the Dex installation."
    exit 1
  }
  repo_common=$(git_common_dir "$repo_root") || {
    dx_error "Could not resolve the current repository."
    exit 1
  }
  dex_common=$(git_common_dir "$DEX_DIR" 2>/dev/null || true)
  if [[ -n "$dex_common" && "$repo_common" == "$dex_common" ]]; then
    mode="dex"
  else
    mode="project"
  fi
fi

case "$mode" in
  dex)
    run_dex_tests "$@"
    ;;
  project)
    if [[ $# -gt 0 ]]; then
      dx_error "dx test project does not accept filters."
      usage >&2
      exit 1
    fi
    run_project_tests
    ;;
esac

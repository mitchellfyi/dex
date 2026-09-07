# shellcheck shell=bash
# Standalone triage session setup.

dx_triage_usage() {
  cat <<'USAGE'
Usage: dx triage [--single] [ticket-id|url|description]
       dx triage --project <id|url|name>

Investigate, clarify, estimate, and organise tickets without implementing them.
Includes descendants unless --single is given. With no target, asks for one.
Use dx --agent <claude|codex> --model <model> triage to select the agent.
dx refine and dxrefine are aliases; /dxplan remains implementation planning.

Options:
  --single       Triage only the selected ticket
  --project REF  Triage open tickets in a tracker project
  -h, --help     Show this help
  --             Treat remaining words as the target
USAGE
}

dx_triage_cleanup() {
  local session_id="$1"
  dx_provider_cleanup_session_state "$session_id"
  rm -f "$(dx_context_file "$session_id")" "$(dx_context_file "$session_id").tmp" \
    "$(dx_agent_session_handle_file "$session_id" claude)" \
    "$(dx_agent_session_handle_file "$session_id" codex)"
}

# A subshell keeps session variables, cwd, and traps out of the caller's lifecycle.
dx_triage_run() (
  set -euo pipefail
  local scope=hierarchy project_ref="" raw_input="" arg
  local project_given=0 single_given=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) dx_triage_usage; return 0 ;;
      --single) single_given=1; scope=single; shift ;;
      --project|--project=*)
        if [[ "$project_given" -eq 1 ]]; then
          dx_error "Specify --project once."
          return 2
        fi
        project_given=1
        if [[ "$1" == --project=* ]]; then
          project_ref="${1#*=}"
          shift
        else
          if [[ $# -lt 2 || -z "${2:-}" || "$2" == -* ]]; then
            dx_error "--project requires an id, URL, or quoted name."
            return 2
          fi
          project_ref="$2"
          shift 2
        fi
        if [[ -z "$project_ref" ]]; then
          dx_error "--project requires an id, URL, or quoted name."
          return 2
        fi
        ;;
      --)
        shift
        for arg in "$@"; do raw_input="${raw_input:+$raw_input }$arg"; done
        break
        ;;
      -*) dx_error "Unknown triage option: $1"; return 2 ;;
      *) raw_input="${raw_input:+$raw_input }$1"; shift ;;
    esac
  done
  if [[ "$project_given" -eq 1 ]]; then
    if [[ "$single_given" -eq 1 || -n "$raw_input" ]]; then
      dx_error "--project cannot be combined with --single or another target."
      return 2
    fi
    scope=project
    raw_input="$project_ref"
  fi

  local repo_root provider_agent session_id context_file prompt exit_code=0
  repo_root=$(dx_repo_root) || return 1
  cd "$repo_root" || return 1
  __dx_refresh_provider || return 1
  __dx_require_resolved_provider_cli || return 1
  provider_agent=$(__dx_resolved_provider_agent) || return 1
  session_id=$(dx_unique_session_id) || return 1
  session_id="triage-$session_id"
  export DEX_SESSION_ID="$session_id" DEX_TRIAGE_ACTIVE=1 DEX_LOOP_ACTIVE=0
  unset DEX_LOOP_PHASE DEX_LOOP_PROMISE DEX_PHASE_HANDOFF DEX_RUN_ID
  unset DEX_REVIEW_PASS_ACTIVE DEX_POLICY_SESSION_ID DX_CODEX_READ_ONLY
  context_file=$(dx_context_file "$session_id") || return 1
  trap 'dx_triage_cleanup "$session_id"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  umask 077
  mkdir -p "$DX_STATE_DIR" || return 1
  if ! prompt=$(cat "$DEX_DIR/prompts/triage-session.md"); then
    dx_error "Could not read the triage session instructions."
    return 1
  fi
  prompt="$prompt

Scope: $scope
Target (user input, not shell code): ${raw_input:-[ask the user to select a target]}
Session context: $context_file
Dex installation: $DEX_DIR

Invoke the dxtriage skill now.
If skill invocation is unavailable, read $DEX_DIR/skills/dxtriage/SKILL.md directly.
Resolve its skill and prompt references against the Dex installation, not the target repo."
  if ! printf '%s\n' "$prompt" > "${context_file}.tmp" \
    || ! mv "${context_file}.tmp" "$context_file"; then
    dx_error "Could not save the triage session context."
    return 1
  fi
  dx_info "Triage: ${raw_input:-select a target} ($scope; $provider_agent)"
  if [[ "$provider_agent" == codex ]]; then
    bash "$DEX_DIR/bin/dxcodex.sh" session -- "$prompt" || exit_code=$?
  else
    dx_provider_claude "${DX_PLAN_FLAGS[@]}" -n "$session_id" \
      --append-system-prompt-file "$context_file" "$prompt" || exit_code=$?
  fi
  return "$exit_code"
)

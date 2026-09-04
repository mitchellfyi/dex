#!/usr/bin/env bash
# shellcheck disable=SC1091
# Dex-safe Codex CLI delegation wrapper.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  printf '%s\n' "Usage: dxcodex.sh exec [--] [prompt]"
  printf '%s\n' "       dxcodex.sh session [--resume <session-id>|--resume-last] [--] [prompt]"
  printf '%s\n' "       dxcodex.sh review [--uncommitted|--base <branch>|--commit <sha>] [prompt]"
}

reject_owned_option() {
  local command_name="$1" arg="$2"
  if [[ "$arg" == -* ]]; then
    dx_error "dxcodex ${command_name} does not accept Codex options: $arg"
    dx_info "Pass task instructions as prompt text; Dex owns Codex config, model, sandbox, and provider flags."
    return 1
  fi
}

# Codex's persistent app-server can execute hooks outside the environment of
# the TUI process that launched this wrapper. Build each hook command with the
# small, non-secret Dex runtime context it needs instead of relying on process
# inheritance. Python's shell quoting keeps paths and values inert when Codex
# later invokes the command through the platform shell.
build_codex_hook_command() {
  local script_path="$1"
  shift
  python3 - "$script_path" "$@" <<'PY'
import shlex
import sys

script_path, *environment = sys.argv[1:]
command = ["env", *environment, "bash", script_path]
print(" ".join(shlex.quote(part) for part in command))
PY
}

build_codex_hook_config() {
  local event_name="$1" command_value="$2" timeout="$3" status_message="$4"
  python3 - "$event_name" "$command_value" "$timeout" "$status_message" <<'PY'
import json
import sys

event_name, command, timeout, status_message = sys.argv[1:]
print(
    f"hooks.{event_name}="
    "[{hooks=[{type=\"command\",command="
    f"{json.dumps(command)},timeout={int(timeout)},"
    f"statusMessage={json.dumps(status_message)}"
    "}]}]"
)
PY
}

build_codex_environment_config() {
  local assignment="$1" variable_name variable_value
  variable_name="${assignment%%=*}"
  variable_value="${assignment#*=}"
  python3 - "$variable_name" "$variable_value" <<'PY'
import json
import sys

name, value = sys.argv[1:]
print(f"shell_environment_policy.set.{name}={json.dumps(value)}")
PY
}

subcmd="${1:-}"
if [[ -z "$subcmd" ]]; then
  usage >&2
  exit 2
fi
shift

case "$subcmd" in
  help|--help|-h)
    usage
    exit 0
    ;;
esac

# Re-resolve from the selected provider profile. Keep DX_MODEL_OVERRIDE intact
# so `dx --agent codex --model <model>` reaches this wrapper through Claude.
# Any provider profile may delegate through this wrapper; codex-plugin profiles
# resolve a codex_model override, other engines use the Codex session default.
unset DX_CODEX_MODEL
unset DX_CODEX_EFFORT
dx_provider_apply

dx_provider_codex_read_only_mode_valid || exit 2
dx_provider_codex_ready_check

codex_policy_args=(--ignore-user-config)
if dx_provider_codex_read_only_enabled; then
  codex_policy_args+=(--sandbox read-only --ephemeral)
else
  codex_policy_args+=(--dangerously-bypass-approvals-and-sandbox)
fi

case "$subcmd" in
  session)
    if dx_provider_codex_read_only_enabled; then
      dx_error "Interactive Dex Codex sessions cannot use read-only delegation mode."
      exit 2
    fi
    dx_provider_codex_interactive_required_flags_check

    resume_session=0
    resume_handle=""
    if [[ "${1:-}" == "--resume" ]]; then
      resume_session=1
      if [[ $# -lt 2 ]] || ! dx_agent_session_handle_valid "${2:-}"; then
        dx_error "dxcodex session --resume requires a valid session ID."
        exit 2
      fi
      resume_handle="$2"
      shift 2
    elif [[ "${1:-}" == "--resume-last" ]]; then
      resume_session=1
      shift
    fi
    allow_dash_prompt=0
    if [[ "${1:-}" == "--" ]]; then
      allow_dash_prompt=1
      shift
    fi
    if [[ $# -gt 0 && $allow_dash_prompt -eq 0 ]]; then
      reject_owned_option session "$1" || exit 2
    fi
    if [[ $# -gt 1 ]]; then
      dx_error "dxcodex session accepts a single prompt argument."
      usage >&2
      exit 2
    fi

    codex_hook_environment=(
      "DEX_DIR=$DEX_DIR"
      "DX_STATE_DIR=$DX_STATE_DIR"
      "DX_LOOP_DIR=$DX_LOOP_DIR"
      "DX_RUN_ROOT=$DX_RUN_ROOT"
      "DEX_SESSION_ID=${DEX_SESSION_ID:-}"
      "DX_PROVIDER_ENGINE=codex-plugin"
    )
    [[ -z "${DEX_RUN_ID:-}" ]] \
      || codex_hook_environment+=("DEX_RUN_ID=$DEX_RUN_ID")
    [[ -z "${DEX_LOOP_ACTIVE:-}" ]] \
      || codex_hook_environment+=("DEX_LOOP_ACTIVE=$DEX_LOOP_ACTIVE")
    [[ -z "${DEX_LOOP_PROMISE:-}" ]] \
      || codex_hook_environment+=("DEX_LOOP_PROMISE=$DEX_LOOP_PROMISE")
    [[ -z "${DEX_LOOP_PHASE:-}" ]] \
      || codex_hook_environment+=("DEX_LOOP_PHASE=$DEX_LOOP_PHASE")
    [[ -z "${DEX_PHASE_HANDOFF:-}" ]] \
      || codex_hook_environment+=("DEX_PHASE_HANDOFF=$DEX_PHASE_HANDOFF")
    [[ -z "${DEX_LOOP_MAX_ITERATIONS:-}" ]] \
      || codex_hook_environment+=("DEX_LOOP_MAX_ITERATIONS=$DEX_LOOP_MAX_ITERATIONS")
    [[ -z "${DEX_LOOP_MIN_AUDITS:-}" ]] \
      || codex_hook_environment+=("DEX_LOOP_MIN_AUDITS=$DEX_LOOP_MIN_AUDITS")
    [[ -z "${DEX_LOOP_STALL_ESCALATE:-}" ]] \
      || codex_hook_environment+=("DEX_LOOP_STALL_ESCALATE=$DEX_LOOP_STALL_ESCALATE")
    [[ -z "${DEX_LOOP_STALL_TIMEOUT:-}" ]] \
      || codex_hook_environment+=("DEX_LOOP_STALL_TIMEOUT=$DEX_LOOP_STALL_TIMEOUT")
    [[ -z "${DEX_REVIEW_PASS_TIMEOUT:-}" ]] \
      || codex_hook_environment+=("DEX_REVIEW_PASS_TIMEOUT=$DEX_REVIEW_PASS_TIMEOUT")
    [[ -z "${DEX_REVIEW_PASS_RECHECK_SECONDS:-}" ]] \
      || codex_hook_environment+=("DEX_REVIEW_PASS_RECHECK_SECONDS=$DEX_REVIEW_PASS_RECHECK_SECONDS")
    [[ -z "${DEX_COMPLETE_MAX_CYCLES:-}" ]] \
      || codex_hook_environment+=("DEX_COMPLETE_MAX_CYCLES=$DEX_COMPLETE_MAX_CYCLES")
    [[ -z "${DEX_COMPLETE_WAIT_MINUTES:-}" ]] \
      || codex_hook_environment+=("DEX_COMPLETE_WAIT_MINUTES=$DEX_COMPLETE_WAIT_MINUTES")

    codex_start_hook_command=$(build_codex_hook_command \
      "$DEX_DIR/hooks/capture-provider-session.sh" \
      "${codex_hook_environment[@]}")
    codex_stop_hook_command=$(build_codex_hook_command \
      "$DEX_DIR/hooks/phase-loop.sh" \
      "${codex_hook_environment[@]}")
    codex_start_hook_config=$(build_codex_hook_config SessionStart \
      "$codex_start_hook_command" 30 "Saving Dex session")
    codex_stop_hook_config=$(build_codex_hook_config Stop \
      "$codex_stop_hook_command" 1800 "Running Dex phase audit")

    codex_session_policy_args=(
      --dangerously-bypass-approvals-and-sandbox
      --dangerously-bypass-hook-trust
      -c features.hooks=true
      -c "$codex_start_hook_config"
      -c "$codex_stop_hook_config"
    )
    for codex_hook_assignment in "${codex_hook_environment[@]}"; do
      codex_session_policy_args+=(
        -c "$(build_codex_environment_config "$codex_hook_assignment")"
      )
    done
    if [[ $resume_session -eq 1 ]]; then
      if [[ -n "$resume_handle" ]]; then
        codex_args=(resume "$resume_handle" "${codex_session_policy_args[@]}")
      else
        codex_args=(resume --last "${codex_session_policy_args[@]}")
      fi
    else
      codex_args=("${codex_session_policy_args[@]}")
    fi
    if [[ -n "${DX_CODEX_MODEL:-}" ]]; then
      codex_args+=(-m "$DX_CODEX_MODEL")
    fi
    if [[ -n "${DX_CODEX_EFFORT:-}" ]]; then
      codex_args+=(-c "model_reasoning_effort=$DX_CODEX_EFFORT")
    fi
    if [[ $# -eq 1 ]]; then
      if [[ $resume_session -eq 1 ]]; then
        codex_args+=("$1")
      else
        codex_args+=(-- "$1")
      fi
    fi
    DX_PROVIDER_CODEX_WRAPPER=interactive \
      dx_provider_codex "${codex_args[@]}"
    ;;
  exec)
    codex_args=(exec "${codex_policy_args[@]}")
    case "${DX_CODEX_JSON:-0}" in
      1) codex_args+=(--json) ;;
      0|"") ;;
      *)
        dx_error "DX_CODEX_JSON must be 0 or 1."
        exit 2
        ;;
    esac
    if [[ -n "${DX_CODEX_OUTPUT_LAST_MESSAGE:-}" ]]; then
      codex_args+=(-o "$DX_CODEX_OUTPUT_LAST_MESSAGE")
    fi
    if [[ -n "${DX_CODEX_MODEL:-}" ]]; then
      codex_args+=(-m "$DX_CODEX_MODEL")
    fi
    if [[ -n "${DX_CODEX_EFFORT:-}" ]]; then
      codex_args+=(-c "model_reasoning_effort=$DX_CODEX_EFFORT")
    fi
    allow_dash_prompt=0
    if [[ "${1:-}" == "--" ]]; then
      allow_dash_prompt=1
      shift
    fi
    if [[ $# -gt 0 && $allow_dash_prompt -eq 0 ]]; then
      reject_owned_option exec "$1" || exit 2
    fi
    if [[ $# -gt 1 ]]; then
      dx_error "dxcodex exec accepts a single prompt argument."
      usage >&2
      exit 2
    fi
    if [[ $# -eq 1 ]]; then
      codex_args+=(--)
      codex_args+=("$1")
    fi
    DX_PROVIDER_CODEX_WRAPPER=1 dx_provider_codex "${codex_args[@]}"
    ;;
  review)
    has_review_scope=0
    prompt=""
    scope_args=()
    scope_notes=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --uncommitted)
          scope_args+=(--uncommitted)
          scope_notes+=("Review uncommitted changes in the current checkout.")
          has_review_scope=1
          shift
          ;;
        --base|--commit)
          if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
            dx_error "dxcodex review requires a value for $1."
            exit 2
          fi
          scope_args+=("$1" "$2")
          scope_notes+=("Review scope: $1 $2.")
          has_review_scope=1
          shift 2
          ;;
        --)
          shift
          if [[ $# -gt 1 ]] || [[ -n "$prompt" && $# -gt 0 ]]; then
            dx_error "dxcodex review accepts a single prompt argument."
            exit 2
          fi
          # A bare trailing -- keeps a prompt that already arrived.
          [[ $# -eq 0 ]] || prompt="$1"
          shift $#
          ;;
        -*)
          dx_error "dxcodex review does not accept Codex options: $1"
          dx_info "Allowed review scope flags: --uncommitted, --base <branch>, --commit <sha>."
          exit 2
          ;;
        *)
          if [[ -n "$prompt" ]]; then
            dx_error "dxcodex review accepts a single prompt argument."
            exit 2
          fi
          prompt="$1"
          shift
          ;;
      esac
    done
    if [[ $has_review_scope -eq 0 ]]; then
      scope_args+=(--uncommitted)
      scope_notes+=("Review uncommitted changes in the current checkout.")
    fi

    if [[ -n "$prompt" ]]; then
      codex_args=(exec "${codex_policy_args[@]}")
      if [[ -n "${DX_CODEX_MODEL:-}" ]]; then
        codex_args+=(-m "$DX_CODEX_MODEL")
      fi
      if [[ -n "${DX_CODEX_EFFORT:-}" ]]; then
        codex_args+=(-c "model_reasoning_effort=$DX_CODEX_EFFORT")
      fi
      review_scope=$(
        printf '%s\n' "${scope_notes[@]}"
      )
      codex_args+=(--)
      codex_args+=("You are running a Dex review request through the safe Codex wrapper.

The current Codex CLI does not accept review scope flags together with a prompt
in \`codex exec review\`, so Dex is routing this through \`codex exec\`.
Apply the same review intent manually.

${review_scope}

${prompt}")
    else
      if dx_provider_codex_read_only_enabled; then
        # --sandbox belongs to `codex exec`, not its `review` subcommand.
        codex_args=(exec "${codex_policy_args[@]}" review)
      else
        codex_args=(exec review "${codex_policy_args[@]}")
      fi
      if [[ -n "${DX_CODEX_MODEL:-}" ]]; then
        codex_args+=(-m "$DX_CODEX_MODEL")
      fi
      codex_args+=("${scope_args[@]}")
    fi
    DX_PROVIDER_CODEX_WRAPPER=1 dx_provider_codex "${codex_args[@]}"
    ;;
  *)
    dx_error "Unknown dxcodex command: $subcmd"
    usage >&2
    exit 2
    ;;
esac

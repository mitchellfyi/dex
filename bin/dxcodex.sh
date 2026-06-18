#!/usr/bin/env bash
# shellcheck disable=SC1091
# Dex-safe Codex CLI delegation wrapper.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  printf '%s\n' "Usage: dxcodex.sh exec [--] [prompt]"
  printf '%s\n' "       dxcodex.sh review [--uncommitted|--base <branch>|--commit <sha>] [prompt]"
}

reject_exec_option() {
  local arg="$1"
  if [[ "$arg" == -* ]]; then
    dx_error "dxcodex exec does not accept Codex options: $arg"
    dx_info "Pass task instructions as prompt text; Dex owns Codex config, model, sandbox, and provider flags."
    return 1
  fi
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
dx_provider_apply

dx_provider_codex_ready_check

case "$subcmd" in
  exec)
    codex_args=(exec --ignore-user-config --dangerously-bypass-approvals-and-sandbox)
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
    allow_dash_prompt=0
    if [[ "${1:-}" == "--" ]]; then
      allow_dash_prompt=1
      shift
    fi
    if [[ $# -gt 0 && $allow_dash_prompt -eq 0 ]]; then
      reject_exec_option "$1" || exit 2
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
          if [[ $# -gt 1 ]]; then
            dx_error "dxcodex review accepts a single prompt argument."
            exit 2
          fi
          prompt="${1:-}"
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
      codex_args=(exec --ignore-user-config --dangerously-bypass-approvals-and-sandbox)
      if [[ -n "${DX_CODEX_MODEL:-}" ]]; then
        codex_args+=(-m "$DX_CODEX_MODEL")
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
      codex_args=(exec review --ignore-user-config --dangerously-bypass-approvals-and-sandbox)
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

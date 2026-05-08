#!/usr/bin/env bash
# shellcheck disable=SC1091
# Doyaken-safe Codex CLI delegation wrapper.
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

usage() {
  printf '%s\n' "Usage: dkcodex.sh exec [--] [prompt]"
  printf '%s\n' "       dkcodex.sh review [--uncommitted|--base <branch>|--commit <sha>] [prompt]"
}

reject_exec_option() {
  local arg="$1"
  if [[ "$arg" == -* ]]; then
    dk_error "dkcodex exec does not accept Codex options: $arg"
    dk_info "Pass task instructions as prompt text; Doyaken owns Codex config, model, sandbox, and provider flags."
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

unset DK_CODEX_MODEL
dk_provider_apply
if [[ "$DK_PROVIDER_ENGINE" != "codex-plugin" ]]; then
  dk_error "dkcodex requires a codex-plugin provider profile."
  dk_info "Run 'dk provider use codex-subscription' or set DK_PROVIDER_PROFILE to a configured Codex subscription profile."
  exit 2
fi

dk_provider_codex_ready_check

case "$subcmd" in
  exec)
    codex_args=(exec --ignore-user-config --dangerously-bypass-approvals-and-sandbox)
    if [[ -n "${DK_CODEX_MODEL:-}" ]]; then
      codex_args+=(-m "$DK_CODEX_MODEL")
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
      dk_error "dkcodex exec accepts a single prompt argument."
      usage >&2
      exit 2
    fi
    if [[ $# -eq 1 ]]; then
      codex_args+=(--)
      codex_args+=("$1")
    fi
    DK_PROVIDER_CODEX_WRAPPER=1 dk_provider_codex "${codex_args[@]}"
    ;;
  review)
    codex_args=(exec review --ignore-user-config --dangerously-bypass-approvals-and-sandbox)
    if [[ -n "${DK_CODEX_MODEL:-}" ]]; then
      codex_args+=(-m "$DK_CODEX_MODEL")
    fi

    has_review_scope=0
    prompt=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --uncommitted)
          codex_args+=(--uncommitted)
          has_review_scope=1
          shift
          ;;
        --base|--commit)
          if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
            dk_error "dkcodex review requires a value for $1."
            exit 2
          fi
          codex_args+=("$1" "$2")
          has_review_scope=1
          shift 2
          ;;
        --)
          shift
          if [[ $# -gt 1 ]]; then
            dk_error "dkcodex review accepts a single prompt argument."
            exit 2
          fi
          prompt="${1:-}"
          shift $#
          ;;
        -*)
          dk_error "dkcodex review does not accept Codex options: $1"
          dk_info "Allowed review scope flags: --uncommitted, --base <branch>, --commit <sha>."
          exit 2
          ;;
        *)
          if [[ -n "$prompt" ]]; then
            dk_error "dkcodex review accepts a single prompt argument."
            exit 2
          fi
          prompt="$1"
          shift
          ;;
      esac
    done
    if [[ $has_review_scope -eq 0 ]]; then
      codex_args+=(--uncommitted)
    fi

    if [[ -n "$prompt" ]]; then
      codex_args+=(--)
      codex_args+=("$prompt")
    fi
    DK_PROVIDER_CODEX_WRAPPER=1 dk_provider_codex "${codex_args[@]}"
    ;;
  *)
    dk_error "Unknown dkcodex command: $subcmd"
    usage >&2
    exit 2
    ;;
esac

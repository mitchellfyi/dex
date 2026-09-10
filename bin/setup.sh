#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2034
DX_COMMON_MODULES="output provider"
# shellcheck disable=SC1091
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  printf '%s\n' 'Usage: dx setup [--direct|--router]' '' \
    'Choose direct native agents or optional CCR subscription routing.' \
    'CCR adds multiple accounts, quota display and model fallback within Claude Code.'
}

setup_choice="${1:-}"
case "$setup_choice" in -h|--help) usage; exit 0 ;; esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }
if [[ -z "$setup_choice" ]]; then
  if [[ ! -t 0 ]]; then
    dx_info "Direct agents are available. Run dx setup --router to add optional subscription routing."
    exit 0
  fi
  dx_info "Dex works directly with Claude Code and Codex. Optional CCR adds account pools, usage display and model fallback."
  printf '%s\n' '  1. Keep direct agents' '  2. Set up optional CCR routing'
  read -r -p 'Choose [1]: ' setup_choice
  case "$setup_choice" in 2) setup_choice="--router" ;; ""|1) setup_choice="--direct" ;; *) dx_error "Choose 1 or 2."; exit 2 ;; esac
fi
case "$setup_choice" in
  --direct)
    dx_ok "Direct agents selected. CCR can be added later with dx router setup."
    ;;
  --router)
    bash "$DEX_DIR/bin/router.sh" router setup
    dx_provider_command use ccr-subscription
    ;;
  *) usage >&2; exit 2 ;;
esac

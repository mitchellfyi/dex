#!/usr/bin/env bash
# Internal bridge to Dex's process identity and run journal contracts.
set -euo pipefail
# shellcheck disable=SC2034
DX_COMMON_MODULES="lock session session-runtime output events"
# shellcheck disable=SC1091
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

case "${1:-}" in
  identity)
    [[ $# -eq 2 ]] || exit 2
    dx_session_runtime_process_identity "$2"
    ;;
  event)
    [[ $# -eq 5 ]] || exit 2
    dx_event_emit "$2" "$3" info "Subscription route update" "$4" "$5"
    ;;
  *) printf '%s\n' 'Usage: router-runtime.sh identity <pid> | event <run> <type> <phase> <json>' >&2; exit 2 ;;
esac

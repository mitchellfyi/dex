#!/usr/bin/env bash
# shellcheck disable=SC1091
# dex tools — inspect or install Claude/Codex tooling bootstrap.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx tools [command]

Inspect or install Dex's Claude/Codex tooling bootstrap.

Commands:
  bootstrap    Install Dex links, RTK, official MCPs, and safe official plugins
  doctor       Check tooling state without changing global configuration
  check        Alias for doctor
  -h, --help   Show this help
USAGE
}

if [[ $# -gt 1 ]]; then
  dx_error "dx tools accepts one command."
  usage >&2
  exit 1
fi

repo_root=""
if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  :
else
  repo_root=""
fi

cmd="${1:-doctor}"
case "$cmd" in
  bootstrap)
    echo "Dex - Tools Bootstrap"
    echo ""
    if ! dx_bootstrap_agent_tooling "$repo_root" "install"; then
      dx_warn "Tooling bootstrap finished with warnings"
      exit 1
    fi
    echo ""
    dx_done "Tooling bootstrap complete"
    ;;
  doctor|check)
    echo "Dex - Tools Doctor"
    echo ""
    if ! dx_bootstrap_agent_tooling "$repo_root" "check"; then
      dx_warn "Tooling drift detected; run 'dx tools bootstrap' to reinstall it."
      exit 1
    fi
    echo ""
    dx_done "Tooling check passed"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    dx_error "Unknown tools command: $cmd"
    usage >&2
    exit 1
    ;;
esac

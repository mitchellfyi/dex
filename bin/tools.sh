#!/usr/bin/env bash
# shellcheck disable=SC1091
# doyaken tools — inspect or repair Claude/Codex tooling bootstrap.
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dk tools [command]

Inspect or repair Doyaken's conservative Claude/Codex tooling bootstrap.

Commands:
  bootstrap    Check and repair Doyaken links, official MCPs, and safe official plugins
  doctor       Check tooling state without changing global configuration
  check        Alias for doctor
  -h, --help   Show this help
USAGE
}

repo_root=""
if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  :
else
  repo_root=""
fi

cmd="${1:-doctor}"
case "$cmd" in
  bootstrap)
    echo "Doyaken - Tools Bootstrap"
    echo ""
    if ! dk_bootstrap_agent_tooling "$repo_root" "repair"; then
      dk_warn "Tooling bootstrap finished with warnings"
      exit 1
    fi
    echo ""
    dk_done "Tooling bootstrap complete"
    ;;
  doctor|check)
    echo "Doyaken - Tools Doctor"
    echo ""
    if ! dk_bootstrap_agent_tooling "$repo_root" "check"; then
      dk_warn "Tooling drift detected; run 'dk tools bootstrap' to repair it."
      exit 1
    fi
    echo ""
    dk_done "Tooling check passed"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    dk_error "Unknown tools command: $cmd"
    usage
    exit 1
    ;;
esac

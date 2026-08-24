#!/usr/bin/env bash
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

if [[ $# -ne 2 ]]; then
  dx_error "Usage: escalate.sh <session-id> <generation>"
  exit 1
fi

dx_lifecycle_agent_escalate "$1" "$2"

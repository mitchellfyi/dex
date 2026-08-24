#!/usr/bin/env bash
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

if [[ $# -ne 4 ]]; then
  dx_error "Usage: activate-loop.sh <session-id> <mode> <purpose> <phase>"
  exit 1
fi

dx_completion_loop_activate "$1" "$2" "$3" "$4"

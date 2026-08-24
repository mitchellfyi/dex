#!/usr/bin/env bash
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

if [[ $# -ne 2 ]]; then
  dx_error "Usage: complete-receipt.sh <session-id> <generation>"
  exit 1
fi

dx_completion_write_receipt "$1" "$2"

#!/usr/bin/env bash
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx review stats [--json] [--root <dir>]
       dx review -h | --help

Report what the review loop actually did, per risk tier, from the telemetry
Dex already writes under ~/.dex/runs/*/events.jsonl.

Per tier: loops recorded, median passes and minutes per loop, how many loops
reached the clean gate and how many never did, how many passes ran after clean
credit was already banked, and how many of those found something anyway.

That last pair is the number to set a default by. Requiring a second or third
consecutive clean pass is worth its time only while confirmation passes keep
finding things; when they stop, lower the requirement and publish these numbers
in the pull request that changes it.

Options:
  --json         Emit the rows as JSON instead of a table
  --root <dir>   Read telemetry from this directory instead of ~/.dex/runs
  -h, --help     Show this help
USAGE
}

REVIEW_COMMAND="${1:-}"
[[ $# -eq 0 ]] || shift

case "$REVIEW_COMMAND" in
  -h|--help|help|"")
    usage
    exit 0
    ;;
  stats)
    python3 "$DEX_DIR/scripts/review_stats.py" "$@"
    ;;
  *)
    dx_error "Unknown review command: ${REVIEW_COMMAND}"
    usage
    exit 2
    ;;
esac

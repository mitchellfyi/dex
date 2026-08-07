#!/usr/bin/env bash
# dx log — Pretty-print structured phase execution logs.
#
# Usage:
#   dx log                  Show logs for all recent sessions
#   dx log <session_id>     Show log for a specific session
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx log [session_id]

Show structured phase execution logs, optionally filtered by session ID.

Options:
  -h, --help  Show this help
USAGE
}

format_duration() {
  local secs=$1
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=0
  if [[ $secs -lt 60 ]]; then
    echo "${secs}s"
  elif [[ $secs -lt 3600 ]]; then
    echo "$((secs / 60))m $((secs % 60))s"
  else
    echo "$((secs / 3600))h $(( (secs % 3600) / 60 ))m"
  fi
}

format_status() {
  case "$1" in
    advance)  echo "advance" ;;
    timeout)  echo "TIMEOUT" ;;
    interrupt) echo "interrupt" ;;
    crash)    echo "CRASH" ;;
    max-iter) echo "MAX-ITER" ;;
    *)        echo "$1" ;;
  esac
}

main() {
  if [[ $# -gt 1 ]]; then
    dx_error "dx log accepts at most one session ID."
    usage >&2
    return 1
  fi

  case "${1:-}" in
    -h|--help|help)
      usage
      return 0
      ;;
    -*)
      dx_error "Unknown dx log option: $1"
      usage >&2
      return 1
      ;;
  esac

  local session_filter="${1:-}"

  if [[ ! -d "$DX_STATE_DIR" ]]; then
    echo "No phase logs found."
    return 0
  fi

  local found=0

  for log_file in "$DX_STATE_DIR"/*.log; do
    [[ -f "$log_file" ]] || continue

    # Extract session_id from filename
    local local_sid
    local_sid=$(basename "$log_file" .log)

    # Filter if specified
    if [[ -n "$session_filter" ]] && [[ "$local_sid" != *"$session_filter"* ]]; then
      continue
    fi

    found=1
    echo ""
    echo "Session: $local_sid"
    echo "─────────────────────────────────────────────────────────"
    printf "  %-5s  %-18s  %-10s  %-10s  %s\n" "Phase" "Name" "Duration" "Iters" "Status"
    printf "  %-5s  %-18s  %-10s  %-10s  %s\n" "─────" "──────────────────" "──────────" "──────" "──────"

    # Skip header line, read data rows
    # Fields: session_id, phase, phase_name, start_epoch, end_epoch, duration_s, iterations, status, exit_code
    # Only phase, phase_name, dur, iters, status are displayed — others assigned to _ to suppress SC2034.
    tail -n +2 "$log_file" | while IFS=$'\t' read -r _ phase phase_name _ _ dur iters status _; do
      [[ -z "$phase" ]] && continue
      local formatted_dur formatted_status
      formatted_dur=$(format_duration "$dur")
      formatted_status=$(format_status "$status")
      printf "  %-5s  %-18s  %-10s  %-10s  %s\n" "$phase" "$phase_name" "$formatted_dur" "$iters" "$formatted_status"
    done

    # Total duration
    local first_start last_end
    first_start=$(awk -F '\t' 'NR == 2 { print $4; exit }' "$log_file")
    last_end=$(tail -1 "$log_file" | cut -f5)
    if [[ -n "$first_start" ]] && [[ -n "$last_end" ]] && [[ "$first_start" =~ ^[0-9]+$ ]] && [[ "$last_end" =~ ^[0-9]+$ ]]; then
      local total=$((last_end - first_start))
      echo ""
      echo "  Total: $(format_duration $total)"
    fi
    echo ""
  done

  if [[ $found -eq 0 ]]; then
    if [[ -n "$session_filter" ]]; then
      echo "No logs found matching '$session_filter'."
    else
      echo "No phase logs found."
    fi
  fi
}

main "$@"

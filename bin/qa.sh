#!/usr/bin/env bash
# shellcheck disable=SC1091
# Dex manual QA — record, inspect, and mark the QA report for a lifecycle.
set -euo pipefail
umask 077

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx qa <command> [options]

Commands:
  dx qa report --input FILE [--session ID]           Validate a draft and write the report
  dx qa show [--session ID] [--json]                 Print the report summary, or the JSON
  dx qa status [--session ID]                        Print the status; exit 0 fresh, 3 stale or unverifiable, 1 missing
  dx qa blocked --reason TEXT [--session ID]         Record that the pass could not run
  dx qa not-applicable --reason TEXT [--session ID]  Record that nothing runs by hand

The draft supplies one row per approved acceptance criterion and verification
requirement, each with evidence under the session's evidence directory, plus
any exploratory findings. The tool derives the status from the rows; a drafted
status is ignored. The report is advisory evidence for the reviewer.

Artifacts are temporary and are written to:
  ${DX_ARTIFACT_DIR:-~/.claude/.dex-artifacts}/qa/<session>/
USAGE
}

require_value() {
  local option_name="$1" option_count="$2"
  [[ "$option_count" -ge 2 ]] || {
    dx_error "${option_name} requires a value"
    usage >&2
    exit 2
  }
}

mode=""
if [[ $# -gt 0 ]]; then
  case "$1" in
    report|show|status|blocked|not-applicable)
      mode="$1"
      shift
      ;;
  esac
fi

input_file=""
requested_session=""
reason=""
show_json=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) require_value "$1" "$#"; input_file="$2"; shift 2 ;;
    --session) require_value "$1" "$#"; requested_session="$2"; shift 2 ;;
    --reason) require_value "$1" "$#"; reason="$2"; shift 2 ;;
    --json) show_json=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) dx_error "Unknown qa option: $1"; usage >&2; exit 2 ;;
  esac
done

[[ -n "$mode" ]] || {
  dx_error "dx qa needs a command"
  usage >&2
  exit 2
}

session_id="${requested_session:-${DEX_SESSION_ID:-$(dx_session_id)}}"
if ! dx_session_id_valid "$session_id"; then
  dx_error "Invalid QA session id: $session_id"
  exit 2
fi
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

case "$mode" in
  report)
    [[ -n "$input_file" ]] || { dx_error "report requires --input FILE"; usage >&2; exit 2; }
    dx_qa_report_write "$session_id" "$input_file" "$repo_root" || {
      dx_error "The QA draft was not accepted; the previous report, if any, is unchanged."
      exit 1
    }
    dx_qa_summary "$session_id" "$repo_root"
    ;;
  show)
    report_file=$(dx_qa_report_file "$session_id")
    if [[ "$show_json" -eq 1 ]]; then
      [[ -f "$report_file" && ! -L "$report_file" ]] || { dx_error "No QA report for session $session_id"; exit 1; }
      cat "$report_file"
    else
      dx_qa_summary "$session_id" "$repo_root"
    fi
    ;;
  status)
    qa_state=$(dx_qa_status "$session_id")
    if [[ "$qa_state" == "MISSING" ]]; then
      printf 'MISSING\n'
      exit 1
    fi
    stale_rc=0
    dx_qa_stale "$session_id" "$repo_root" || stale_rc=$?
    case "$stale_rc" in
      0) printf '%s\n' "$qa_state"; exit 0 ;;
      1) printf '%s (stale: the tree changed after the report)\n' "$qa_state"; exit 3 ;;
      *) printf '%s (fingerprint unavailable: the report could not be checked against a tree)\n' "$qa_state"; exit 3 ;;
    esac
    ;;
  blocked|not-applicable)
    [[ -n "$reason" ]] || {
      dx_error "${mode} requires --reason so reviewers can understand why the pass did not run."
      usage >&2
      exit 2
    }
    outcome="BLOCKED"
    [[ "$mode" == "not-applicable" ]] && outcome="N_A"
    dx_qa_write_terminal "$session_id" "$outcome" "$reason" "$repo_root" || exit 1
    dx_qa_summary "$session_id" "$repo_root"
    ;;
esac

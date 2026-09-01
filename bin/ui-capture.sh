#!/usr/bin/env bash
# shellcheck disable=SC1091
# Dex UI proof — capture, produce, revise, inspect, and retire walkthroughs.
set -euo pipefail
umask 077

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx ui-capture <command> [options]

Commands:
  dx ui-capture capture --url URL [--stage before|after --script FILE] [capture options]
  dx ui-capture revise --script FILE [--before-url URL] [--after-url URL] [--no-narration]
  dx ui-capture validate --script FILE
  dx ui-capture show [--session ID] [--json] [--open]
  dx ui-capture ready --manifest FILE [--video-file FILE] [--poster-file FILE] [--reason TEXT]
  dx ui-capture skip --reason TEXT [--session ID]
  dx ui-capture not-applicable --reason TEXT [--session ID]
  dx ui-capture clean [--older-than DAYS]
  dx ui-capture install

Capture options:
  --name NAME        Short artifact label
  --desktop          Capture a desktop viewport (the default)
  --mobile           Also capture a mobile viewport
  --video            Record video for an unstructured capture
  --trace            Record a Playwright trace
  --flow FILE        Run an existing Playwright flow module
  --wait-ms MS       Pause before and after the flow (default: 700)
  --out DIR          Override the run output directory
  --no-narration     Produce a captioned video without local narration

Legacy form is supported: ui-capture.sh --url URL [...]

Artifacts are temporary and are written to:
  ${DX_ARTIFACT_DIR:-~/.claude/.dex-artifacts}/ui/<session>/
USAGE
}

slugify() {
  printf '%.80s\n' "$(dx_slugify "$1")"
}

require_value() {
  local option_name="$1" option_count="$2"
  [[ "$option_count" -ge 2 ]] || {
    dx_error "${option_name} requires a value"
    usage >&2
    exit 2
  }
}

ensure_safe_output_dir() {
  local absolute_candidate="$1" repo_root
  case "$absolute_candidate" in
    /*) ;;
    *) absolute_candidate="$(pwd)/$absolute_candidate" ;;
  esac
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$repo_root" ]]; then
    case "$absolute_candidate" in
      "$repo_root"/*)
        if ! git check-ignore -q "$absolute_candidate"; then
          dx_error "UI artifact directory is inside the repo and is not ignored: $absolute_candidate"
          return 1
        fi
        ;;
    esac
  fi
  printf '%s\n' "$absolute_candidate"
}

bundle_field() {
  local bundle_file="$1" field_name="$2"
  python3 - "$bundle_file" "$field_name" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    value = json.load(fh)
field = value.get(sys.argv[2], "")
if not isinstance(field, str):
    raise SystemExit(1)
print(field)
PY
}

copy_proof_file() {
  local source_file="$1" target_file="$2" tmp_file
  [[ -f "$source_file" && ! -L "$source_file" && -s "$source_file" ]] || {
    dx_error "UI proof file is missing, empty, or a symlink: $source_file"
    return 1
  }
  mkdir -p "$(dirname "$target_file")" || return 1
  tmp_file="${target_file}.tmp.$$"
  if ! command cp "$source_file" "$tmp_file" || ! command mv -f "$tmp_file" "$target_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
}

write_in_progress_manifest() {
  local session_id="$1" storyboard_file="$2" manifest_file tmp_file
  manifest_file=$(dx_ui_capture_manifest_file "$session_id")
  tmp_file="${manifest_file}.tmp.$$"
  {
    printf '# Visual Proof\n\n'
    printf 'Status: NEEDS_REVIEW\n\n'
    printf 'The before walkthrough is captured. Capture the matching after flow to produce the final video.\n\n'
    printf -- '- Storyboard: %s\n' "$storyboard_file"
    printf -- '- Session: %s\n' "$session_id"
  } > "$tmp_file"
  command mv -f "$tmp_file" "$manifest_file"
}

record_capture_failure() {
  local failure_session="$1" failure_stage="$2" failure_storyboard="${3:-}" failure_output="${4:-}"
  local failure_dir failure_manifest failure_error failure_error_tmp failure_manifest_tmp failure_slug failure_message
  failure_dir=$(dx_ui_capture_session_dir "$failure_session")
  failure_manifest=$(dx_ui_capture_manifest_file "$failure_session")
  failure_slug=$(slugify "$failure_stage")
  [[ -n "$failure_slug" ]] || failure_slug="capture"
  failure_error="$failure_dir/${failure_slug}-error.log"
  failure_error_tmp="${failure_error}.tmp.$$"
  failure_manifest_tmp="${failure_manifest}.tmp.$$"
  failure_message="${failure_stage} failed; inspect ${failure_error} and retry the proof."

  mkdir -p "$failure_dir"
  if [[ -n "$failure_output" ]]; then
    printf '%s\n' "$failure_output" > "$failure_error_tmp"
  else
    printf '%s\n' "No detailed error output was captured. Review the terminal output and retry." > "$failure_error_tmp"
  fi
  command mv -f "$failure_error_tmp" "$failure_error"

  {
    printf '# Visual Proof\n\n'
    printf 'Status: NEEDS_REVIEW\n\n'
    printf '%s\n\n' "$failure_message"
    printf -- '- Session: %s\n' "$failure_session"
    printf -- '- Failed step: %s\n' "$failure_stage"
    [[ -n "$failure_storyboard" ]] && printf -- '- Storyboard: %s\n' "$failure_storyboard"
    printf -- '- Error log: %s\n' "$failure_error"
  } > "$failure_manifest_tmp"
  command mv -f "$failure_manifest_tmp" "$failure_manifest"

  dx_ui_capture_write_status "$failure_session" "NEEDS_REVIEW" "$failure_message" "$failure_manifest" ""
}

record_bundle_status() {
  local session_id="$1" session_dir bundle_file evidence_status message manifest_file video_file
  session_dir=$(dx_ui_capture_session_dir "$session_id")
  bundle_file="$session_dir/bundle.json"
  [[ -f "$bundle_file" && ! -L "$bundle_file" ]] || {
    dx_error "The UI proof producer did not write $bundle_file"
    return 1
  }
  evidence_status=$(bundle_field "$bundle_file" status) || return 1
  message=$(bundle_field "$bundle_file" message) || return 1
  manifest_file=$(bundle_field "$bundle_file" manifest) || return 1
  video_file=$(bundle_field "$bundle_file" video) || return 1
  dx_ui_capture_write_status "$session_id" "$evidence_status" "$message" "$manifest_file" "$video_file"
  if command -v dx_ui_capture_register_bundle >/dev/null 2>&1; then
    dx_ui_capture_register_bundle "$session_id" || dx_warn "The UI proof is local, but it could not be attached to the active Dex run."
  fi
}

append_legacy_manifest() {
  local session_id="$1" run_name="$2" url="$3" output_dir="$4" capture_output="$5"
  local manifest_file tmp_file
  manifest_file=$(dx_ui_capture_manifest_file "$session_id")
  mkdir -p "$(dirname "$manifest_file")"
  if [[ ! -f "$manifest_file" ]]; then
    tmp_file="${manifest_file}.tmp.$$"
    {
      printf '# Visual Evidence\n\n'
      printf 'Session: %s\n' "$session_id"
      printf 'PR: pending\n'
      printf 'Upload note: drag the local files into the pull request body or a comment.\n'
    } > "$tmp_file"
    command mv -f "$tmp_file" "$manifest_file"
  fi
  {
    printf '\n## Capture: %s\n\n' "$run_name"
    printf -- '- URL: `%s`\n' "$url"
    printf -- '- Directory: [%s](%s)\n\n' "$output_dir" "$output_dir"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      printf -- '- %s\n' "$line"
    done <<< "$capture_output"
  } >> "$manifest_file"
  printf 'manifest: %s\n' "$manifest_file"
}

mode="capture"
if [[ $# -gt 0 ]]; then
  case "$1" in
    capture|revise|validate|show|ready|skip|not-applicable|clean|install)
      mode="$1"
      shift
      ;;
    --install-only)
      mode="install"
      shift
      ;;
  esac
fi

url=""
before_url=""
after_url=""
name="capture"
out_dir=""
storyboard=""
stage=""
flow=""
wait_ms="700"
requested_session=""
reason=""
older_than=""
custom_manifest_file=""
custom_video_file=""
custom_poster_file=""
desktop=0
mobile=0
video=0
trace=0
narration=1
show_json=0
show_open=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) require_value "$1" "$#"; url="$2"; shift 2 ;;
    --before-url) require_value "$1" "$#"; before_url="$2"; shift 2 ;;
    --after-url) require_value "$1" "$#"; after_url="$2"; shift 2 ;;
    --name) require_value "$1" "$#"; name="$2"; shift 2 ;;
    --out) require_value "$1" "$#"; out_dir="$2"; shift 2 ;;
    --script) require_value "$1" "$#"; storyboard="$2"; shift 2 ;;
    --stage) require_value "$1" "$#"; stage="$2"; shift 2 ;;
    --flow) require_value "$1" "$#"; flow="$2"; shift 2 ;;
    --wait-ms) require_value "$1" "$#"; wait_ms="$2"; shift 2 ;;
    --session) require_value "$1" "$#"; requested_session="$2"; shift 2 ;;
    --reason) require_value "$1" "$#"; reason="$2"; shift 2 ;;
    --older-than) require_value "$1" "$#"; older_than="$2"; shift 2 ;;
    --manifest) require_value "$1" "$#"; custom_manifest_file="$2"; shift 2 ;;
    --video-file) require_value "$1" "$#"; custom_video_file="$2"; shift 2 ;;
    --poster-file) require_value "$1" "$#"; custom_poster_file="$2"; shift 2 ;;
    --desktop) desktop=1; shift ;;
    --mobile) mobile=1; shift ;;
    --video) video=1; shift ;;
    --trace) trace=1; shift ;;
    --no-narration) narration=0; shift ;;
    --json) show_json=1; shift ;;
    --open) show_open=1; shift ;;
    --install-only) mode="install"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) dx_error "Unknown ui-capture option: $1"; usage >&2; exit 2 ;;
  esac
done

if [[ "$mode" == "install" ]]; then
  dx_install_ui_capture_tooling
  exit $?
fi

session_id="${requested_session:-${DEX_SESSION_ID:-$(dx_session_id)}}"
if ! dx_session_id_valid "$session_id"; then
  dx_error "Invalid UI proof session id: $session_id"
  exit 2
fi
session_dir=$(dx_ui_capture_session_dir "$session_id")

case "$mode" in
  show)
    evidence_file=$(dx_ui_capture_evidence_file "$session_id")
    if [[ "$show_json" -eq 1 ]]; then
      if [[ -f "$evidence_file" && ! -L "$evidence_file" ]]; then
        command cat "$evidence_file"
      else
        printf '{"status":"MISSING","message":"No UI proof decision has been recorded."}\n'
      fi
    else
      dx_ui_capture_summary "$session_id"
    fi
    if [[ "$show_open" -eq 1 ]]; then
      open_target=$(python3 - "$evidence_file" <<'PY' 2>/dev/null || true
import json
import os
import sys

try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)
for key in ("video", "manifest"):
    candidate = value.get(key)
    if isinstance(candidate, str) and candidate and os.path.isfile(candidate):
        print(candidate)
        break
PY
      )
      if [[ -z "$open_target" ]]; then
        dx_warn "There is no UI proof file to open yet."
      elif command -v open >/dev/null 2>&1; then
        open "$open_target"
      elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$open_target"
      else
        dx_warn "Open this file manually: $open_target"
      fi
    fi
    exit 0
    ;;
  ready)
    [[ -n "$custom_manifest_file" ]] || {
      dx_error "ready requires --manifest"
      exit 2
    }
    mkdir -p "$session_dir"
    canonical_manifest=$(dx_ui_capture_manifest_file "$session_id")
    copy_proof_file "$custom_manifest_file" "$canonical_manifest" || exit 1
    canonical_video=""
    if [[ -n "$custom_video_file" ]]; then
      canonical_video="$session_dir/walkthrough.mp4"
      copy_proof_file "$custom_video_file" "$canonical_video" || exit 1
    fi
    if [[ -n "$custom_poster_file" ]]; then
      copy_proof_file "$custom_poster_file" "$session_dir/poster.png" || exit 1
    fi
    dx_ui_capture_write_status "$session_id" "READY" "${reason:-Custom UI proof ready}" "$canonical_manifest" "$canonical_video"
    dx_ui_capture_register_bundle "$session_id" || dx_warn "The UI proof is local, but it could not be attached to the active Dex run."
    dx_ui_capture_summary "$session_id"
    exit 0
    ;;
  skip|not-applicable)
    [[ -n "$reason" ]] || {
      dx_error "${mode} requires --reason so reviewers can understand the agent's judgment."
      exit 2
    }
    if [[ "$mode" == "skip" ]]; then
      dx_ui_capture_write_status "$session_id" "SKIPPED" "$reason" "" ""
    else
      dx_ui_capture_write_status "$session_id" "N/A" "$reason" "" ""
    fi
    dx_ui_capture_summary "$session_id"
    exit 0
    ;;
  clean)
    dx_ui_capture_cleanup "${older_than:-$(dx_ui_capture_retention_days)}"
    exit $?
    ;;
  validate)
    [[ -n "$storyboard" ]] || { dx_error "validate requires --script"; exit 2; }
    node "$DEX_DIR/scripts/ui-capture.cjs" validate --script "$storyboard"
    exit $?
    ;;
esac

if ! dx_install_ui_capture_playwright; then
  dx_error "UI capture tooling is not ready"
  if [[ "$mode" == "capture" || "$mode" == "revise" ]]; then
    record_capture_failure "$session_id" "UI capture tooling setup" "$storyboard" \
      "UI capture tooling is not ready. Review the terminal output, run 'dx ui-capture install', and retry."
    dx_ui_capture_summary "$session_id"
  fi
  exit 1
fi

canonical_storyboard=""
if [[ -n "$storyboard" ]]; then
  set +e
  validation_output=$(node "$DEX_DIR/scripts/ui-capture.cjs" validate --script "$storyboard" 2>&1)
  validation_exit=$?
  set -e
  printf '%s\n' "$validation_output"
  if [[ "$validation_exit" -ne 0 ]]; then
    record_capture_failure "$session_id" "Storyboard validation" "$storyboard" "$validation_output"
    dx_ui_capture_summary "$session_id"
    exit "$validation_exit"
  fi
  mkdir -p "$session_dir"
  canonical_storyboard=$(dx_ui_capture_storyboard_file "$session_id")
  if [[ "$storyboard" != "$canonical_storyboard" ]]; then
    storyboard_tmp="${canonical_storyboard}.tmp.$$"
    command cp "$storyboard" "$storyboard_tmp"
    command mv -f "$storyboard_tmp" "$canonical_storyboard"
  fi
fi

if [[ "$mode" == "revise" ]]; then
  [[ -n "$canonical_storyboard" ]] || { dx_error "revise requires --script"; exit 2; }
  runner_args=(revise --script "$canonical_storyboard" --session-dir "$session_dir")
  [[ -n "$before_url" ]] && runner_args+=(--before-url "$before_url")
  [[ -n "$after_url" ]] && runner_args+=(--after-url "$after_url")
  [[ "$narration" -eq 0 ]] && runner_args+=(--no-narration)
  set +e
  revision_output=$(DX_UI_CAPTURE_TOOLS_DIR="$(dx_ui_capture_tools_dir)" node "$DEX_DIR/scripts/ui-capture.cjs" "${runner_args[@]}" 2>&1)
  revision_exit=$?
  set -e
  printf '%s\n' "$revision_output"
  if [[ "$revision_exit" -ne 0 ]]; then
    record_capture_failure "$session_id" "Walkthrough revision" "$canonical_storyboard" "$revision_output"
    dx_ui_capture_summary "$session_id"
    exit "$revision_exit"
  fi
  record_bundle_status "$session_id"
  dx_ui_capture_summary "$session_id"
  exit 0
fi

[[ -n "$url" ]] || { dx_error "capture requires --url"; usage >&2; exit 2; }
if [[ -n "$canonical_storyboard" ]]; then
  case "$stage" in before|after) ;; *) dx_error "structured capture requires --stage before or --stage after"; exit 2 ;; esac
fi

run_name=$(slugify "$name")
[[ -n "$run_name" ]] || run_name="capture"
if [[ -z "$out_dir" ]]; then
  capture_label="${stage:+${stage}-}${run_name}"
  out_dir=$(dx_ui_capture_run_dir "$session_id" "$capture_label")
fi
abs_out_dir=$(ensure_safe_output_dir "$out_dir") || exit 1
mkdir -p "$abs_out_dir"

runner_args=(capture --url "$url" --name "$run_name" --out "$abs_out_dir" --wait-ms "$wait_ms")
[[ "$desktop" -eq 1 ]] && runner_args+=(--desktop)
[[ "$mobile" -eq 1 ]] && runner_args+=(--mobile)
[[ "$video" -eq 1 ]] && runner_args+=(--video)
[[ "$trace" -eq 1 ]] && runner_args+=(--trace)
[[ -n "$flow" ]] && runner_args+=(--flow "$flow")
if [[ -n "$canonical_storyboard" ]]; then
  runner_args+=(--stage "$stage" --script "$canonical_storyboard" --session-dir "$session_dir")
  [[ "$narration" -eq 0 ]] && runner_args+=(--no-narration)
fi

dx_info "Capturing ${stage:+${stage} }UI proof for ${url}"
set +e
capture_output=$(DX_UI_CAPTURE_TOOLS_DIR="$(dx_ui_capture_tools_dir)" node "$DEX_DIR/scripts/ui-capture.cjs" "${runner_args[@]}" 2>&1)
capture_exit=$?
set -e
printf '%s\n' "$capture_output"
if [[ "$capture_exit" -ne 0 ]]; then
  capture_stage="${stage:+${stage} }capture"
  record_capture_failure "$session_id" "$capture_stage" "$canonical_storyboard" "$capture_output"
  dx_ui_capture_summary "$session_id"
  exit "$capture_exit"
fi

if [[ -z "$canonical_storyboard" ]]; then
  append_legacy_manifest "$session_id" "$run_name" "$url" "$abs_out_dir" "$capture_output"
  dx_ui_capture_write_status "$session_id" "NEEDS_REVIEW" "Raw capture ready; review it and produce or explicitly skip a concise walkthrough." "$(dx_ui_capture_manifest_file "$session_id")" ""
elif [[ "$stage" == "before" ]]; then
  write_in_progress_manifest "$session_id" "$canonical_storyboard"
  dx_ui_capture_write_status "$session_id" "NEEDS_REVIEW" "Before flow captured; matching after flow is pending." "$(dx_ui_capture_manifest_file "$session_id")" ""
else
  record_bundle_status "$session_id"
fi

dx_ui_capture_summary "$session_id"

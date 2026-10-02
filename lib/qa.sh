# shellcheck shell=bash
# Dex manual QA report helpers.
#
# The Phase 2 QA pass writes one evidenced row per approved acceptance criterion
# and verification requirement, plus the exploratory findings around them. The
# report is advisory, like UI proof: the lifecycle header, `dx status` and the
# PR summarize it, and nothing in the Stop hook gates on it. Everything lives
# under DX_ARTIFACT_DIR and is never committed. scripts/qa-report.py derives the
# status from the rows; these helpers own paths, staleness, journal
# registration, and retention.

dx_qa_session_dir() {
  printf '%s\n' "$(dx_artifacts_dir)/qa/$1"
}

dx_qa_report_file() {
  printf '%s\n' "$(dx_qa_session_dir "$1")/qa-report.json"
}

dx_qa_markdown_file() {
  printf '%s\n' "$(dx_qa_session_dir "$1")/qa-report.md"
}

dx_qa_draft_file() {
  printf '%s\n' "$(dx_qa_session_dir "$1")/draft.json"
}

dx_qa_evidence_dir() {
  printf '%s\n' "$(dx_qa_session_dir "$1")/evidence"
}

# dx_qa_status <session> — PASSED, FINDINGS, BLOCKED, N_A, or MISSING.
dx_qa_status() {
  local session_id="$1" report_file
  dx_session_id_valid "$session_id" || return 2
  report_file=$(dx_qa_report_file "$session_id")
  [[ -f "$report_file" && ! -L "$report_file" ]] || {
    printf 'MISSING\n'
    return 0
  }
  python3 "$DEX_DIR/scripts/qa-report.py" status "$report_file" 2>/dev/null || printf 'MISSING\n'
}

# dx_qa_report_field <session> <field> — one top-level string field, or nothing.
dx_qa_report_field() {
  local session_id="$1" field_name="$2" report_file
  report_file=$(dx_qa_report_file "$session_id")
  [[ -f "$report_file" && ! -L "$report_file" ]] || return 1
  python3 - "$report_file" "$field_name" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], "")
if not isinstance(value, str):
    raise SystemExit(1)
print(value)
PY
}

# dx_qa_stale <session> [repo] — 0 fresh, 1 the tree moved since the report,
# 2 no usable report. The working fingerprint is the one gate receipts bind to.
dx_qa_stale() {
  local session_id="$1" repo="${2:-$PWD}" recorded current
  recorded=$(dx_qa_report_field "$session_id" working_fingerprint 2>/dev/null) || return 2
  [[ "$recorded" =~ ^[a-f0-9]{64}$ ]] || return 2
  current=$(dx_review_working_fingerprint "$repo" 2>/dev/null) || return 2
  [[ "$recorded" == "$current" ]] && return 0
  return 1
}

# dx_qa_summary <session> [repo]
dx_qa_summary() {
  local session_id="$1" repo="${2:-$PWD}" report_file qa_state qa_message stale_rc=0
  report_file=$(dx_qa_report_file "$session_id")
  qa_state=$(dx_qa_status "$session_id") || qa_state="MISSING"
  printf 'QA: %s\n' "$qa_state"
  if [[ "$qa_state" == "MISSING" ]]; then
    printf '  Run dxqa: exercise each approved criterion against the running change and record the report with dx qa report.\n'
    printf '  Report: %s\n' "$report_file"
    return 0
  fi
  qa_message=$(dx_qa_report_field "$session_id" message 2>/dev/null) || qa_message=""
  [[ -n "$qa_message" ]] && printf '  %s\n' "$qa_message"
  printf '  Report: %s\n' "$(dx_qa_markdown_file "$session_id")"
  dx_qa_stale "$session_id" "$repo" || stale_rc=$?
  [[ "$stale_rc" -eq 1 ]] && printf '  Stale: yes (the tree changed after the report)\n'
  printf '  Evidence: %s\n' "$report_file"
}

# Sets QA_APPROVAL_HASH, QA_CHECKOUT and QA_WORKING for the finalize call; each
# is empty when its source is unavailable, and the report records that.
__dx_qa_provenance() {
  local session_id="$1" repo="$2"
  QA_APPROVAL_HASH=$(dx_review_read_criteria_approval "$session_id" 2>/dev/null) || QA_APPROVAL_HASH=""
  QA_CHECKOUT=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || QA_CHECKOUT=""
  QA_WORKING=$(dx_review_working_fingerprint "$repo" 2>/dev/null) || QA_WORKING=""
}

# __dx_qa_finalize <session> <repo> <qa-report.py args…> — writes the JSON and
# Markdown through temp files so a rejected draft leaves the last report intact.
__dx_qa_finalize() {
  local session_id="$1" repo="$2" session_dir report_file markdown_file tmp_json tmp_md
  shift 2
  dx_session_id_valid "$session_id" || return 2
  session_dir=$(dx_qa_session_dir "$session_id")
  report_file=$(dx_qa_report_file "$session_id")
  markdown_file=$(dx_qa_markdown_file "$session_id")
  mkdir -p "$(dx_qa_evidence_dir "$session_id")" || return 1
  __dx_qa_provenance "$session_id" "$repo" || return 1
  tmp_json="${report_file}.tmp.$$"
  tmp_md="${markdown_file}.tmp.$$"
  if ! python3 "$DEX_DIR/scripts/qa-report.py" "$@" \
      --session-id "$session_id" --session-dir "$session_dir" \
      --out "$tmp_json" --markdown "$tmp_md" \
      --approval-hash "$QA_APPROVAL_HASH" --checkout "$QA_CHECKOUT" --working "$QA_WORKING" >/dev/null; then
    command rm -f "$tmp_json" "$tmp_md" 2>/dev/null || true
    return 1
  fi
  command mv -f "$tmp_json" "$report_file" || return 1
  command mv -f "$tmp_md" "$markdown_file" || return 1
  dx_qa_register_report "$session_id" || dx_warn "The QA report is local, but it could not be attached to the active Dex run."
}

# dx_qa_report_write <session> <draft> [repo]
dx_qa_report_write() {
  local session_id="$1" draft="$2" repo="${3:-$PWD}" criteria_file draft_copy tmp_draft
  [[ -f "$draft" && ! -L "$draft" ]] || {
    dx_error "QA draft is missing or a symlink: $draft"
    return 1
  }
  criteria_file=$(dx_review_criteria_file "$session_id") || return 2
  if [[ ! -f "$criteria_file" ]] || ! dx_review_criteria_valid "$criteria_file"; then
    dx_error "The session has no valid approved criteria file: $criteria_file"
    return 1
  fi
  __dx_qa_finalize "$session_id" "$repo" finalize "$draft" --criteria "$criteria_file" || return 1
  draft_copy=$(dx_qa_draft_file "$session_id")
  tmp_draft="${draft_copy}.tmp.$$"
  if command cp "$draft" "$tmp_draft"; then
    command mv -f "$tmp_draft" "$draft_copy" || command rm -f "$tmp_draft" 2>/dev/null || true
  fi
}

# dx_qa_write_terminal <session> <BLOCKED|N_A> <reason> [repo]
dx_qa_write_terminal() {
  local session_id="$1" outcome="$2" reason="$3" repo="${4:-$PWD}" criteria_file
  case "$outcome" in BLOCKED|N_A) ;; *) return 2 ;; esac
  [[ -n "$reason" ]] || return 2
  criteria_file=$(dx_review_criteria_file "$session_id") || return 2
  if [[ ! -f "$criteria_file" ]] || ! dx_review_criteria_valid "$criteria_file"; then
    criteria_file=""
  fi
  __dx_qa_finalize "$session_id" "$repo" terminal "$outcome" --reason "$reason" --criteria "$criteria_file"
}

__dx_qa_register_file() {
  local run_id="$1" session_id="$2" source_file="$3" rel_path="$4" artifact_type="$5" title="$6" role="$7"
  local target_file tmp_file metadata_json
  [[ -f "$source_file" && ! -L "$source_file" ]] || return 0
  target_file=$(dx_run_artifact_file "$run_id" "$rel_path") || return 1
  mkdir -p "$(dirname "$target_file")" || return 1
  tmp_file="${target_file}.tmp.$$"
  if ! command cp "$source_file" "$tmp_file" || ! command mv -f "$tmp_file" "$target_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
  metadata_json=$(printf \
    '{"producer":"dex_qa","role":"%s","session_id":"%s","temporary":true}' \
    "$role" "$session_id")
  dx_run_register_artifact "$run_id" "$artifact_type" "$rel_path" "$title" "$metadata_json"
}

# Copy the report into the active run journal, which also syncs it to DexCode
# when that run has a connection.
dx_qa_register_report() {
  local session_id="$1" run_id session_dir failed=0
  dx_session_id_valid "$session_id" || return 2
  run_id=$(dx_run_read_for_session "$session_id" 2>/dev/null || true)
  [[ -n "$run_id" ]] || return 0
  session_dir=$(dx_qa_session_dir "$session_id")
  dx_run_artifact_manifest_prepare "$run_id" || return 1
  __dx_qa_register_file "$run_id" "$session_id" "$session_dir/qa-report.json" \
    "qa/qa-report.json" "qa_report" "Manual QA report" "report" || failed=1
  __dx_qa_register_file "$run_id" "$session_id" "$session_dir/qa-report.md" \
    "qa/qa-report.md" "qa_report_markdown" "Manual QA report (Markdown)" "report_markdown" || failed=1
  return "$failed"
}

dx_qa_mark_completed() {
  local session_id="$1" report_file tmp_file completed_epoch
  dx_session_id_valid "$session_id" || return 2
  report_file=$(dx_qa_report_file "$session_id")
  [[ -f "$report_file" && ! -L "$report_file" ]] || return 0
  completed_epoch=$(date +%s)
  tmp_file="${report_file}.tmp.$$"
  if ! DX_QA_COMPLETED_EPOCH="$completed_epoch" python3 - "$report_file" "$tmp_file" <<'PY'
import json
import os
import sys

source, target = sys.argv[1:]
with open(source, encoding="utf-8") as fh:
    value = json.load(fh)
value["phase_state"] = "completed"
value["completed_epoch"] = int(os.environ["DX_QA_COMPLETED_EPOCH"])
with open(target, "w", encoding="utf-8") as fh:
    json.dump(value, fh, indent=2)
    fh.write("\n")
PY
  then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
  command mv -f "$tmp_file" "$report_file"
}

# Remove completed reports after the UI-proof retention window. Only direct,
# non-symlinked children of the QA artifact root are considered.
dx_qa_cleanup() {
  local retention_days="${1:-$(dx_ui_capture_retention_days)}" qa_root now_epoch cutoff removed_count suffix
  [[ "$retention_days" =~ ^[1-9][0-9]*$ && "$retention_days" -le 3650 ]] || return 2
  qa_root="$(dx_artifacts_dir)/qa"
  [[ -d "$qa_root" && ! -L "$qa_root" ]] || {
    dx_info "No expired QA reports."
    return 0
  }
  now_epoch=$(date +%s)
  cutoff=$((now_epoch - retention_days * 86400))
  removed_count=$(DX_QA_CLEAN_ROOT="$qa_root" DX_QA_CLEAN_CUTOFF="$cutoff" python3 - <<'PY'
import json
import os
import shutil
import stat
from pathlib import Path

root = Path(os.environ["DX_QA_CLEAN_ROOT"])
cutoff = int(os.environ["DX_QA_CLEAN_CUTOFF"])
removed = 0
for bundle in root.iterdir():
    try:
        meta = bundle.lstat()
    except OSError:
        continue
    if not stat.S_ISDIR(meta.st_mode) or stat.S_ISLNK(meta.st_mode):
        continue
    report = bundle / "qa-report.json"
    try:
        report_meta = report.lstat()
        if not stat.S_ISREG(report_meta.st_mode) or stat.S_ISLNK(report_meta.st_mode):
            continue
        value = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    completed = value.get("completed_epoch")
    if value.get("phase_state") != "completed" or not isinstance(completed, int):
        continue
    if completed <= 0 or completed > cutoff:
        continue
    shutil.rmtree(bundle)
    removed += 1

print(removed)
PY
  ) || return 1
  suffix="reports"
  [[ "$removed_count" == "1" ]] && suffix="report"
  dx_info "Removed ${removed_count} expired QA ${suffix}."
}

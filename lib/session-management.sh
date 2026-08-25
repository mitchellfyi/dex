# shellcheck shell=bash
# Strict lifecycle-session cleanup primitives. Public commands select a session;
# this module revalidates and removes the exact selected state.

__dx_session_management_artifacts() { # <validate|remove-payload|remove-brakes|assert-final> <sid>
  [[ $# -eq 2 ]] || return 3
  local operation="$1" session_id="$2"
  dx_session_id_valid "$session_id" || return 3
  python3 - "$operation" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$session_id" <<'PY'
import os
import re
import stat
import sys


operation, state_dir, loop_dir, selected_session = sys.argv[1:]
session_pattern = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$")
completion_receipt_pattern = re.compile(
    r"^(.*)\.completion-receipt\.[0-9a-f]{32}$"
)
phase_marker_pattern = re.compile(
    r"^(.*)\.phase-(?:[0-7]|prompt-loop)\."
    r"(started|ready|busy|busy-notice|busy-cancel|busy-quiesced)$"
)
watch_lock_pattern = re.compile(r"^(.*)\.(?:ci|pr)\.watch-lock$")

state_suffixes = {
    ".phase-outcomes",
    ".system-context",
    ".human-complete",
    ".terminal-commit",
    ".interventions",
    ".runtime-lock",
    ".run-id",
    ".runtime",
    ".branch",
    ".times",
    ".phase",
    ".meta",
    ".log",
}
loop_suffixes = {
    ".review-receipt.revoked",
    ".review-criteria-approval",
    ".review-selection.revoked",
    ".completion-expectation",
    ".review-criteria.json",
    ".review-evidence.json",
    ".review-selection",
    ".review-context",
    ".review-receipt",
    ".review-result",
    ".review-ledger",
    ".review-proofs",
    ".complete-state",
    ".handoff-mode",
    ".pause-state",
    ".watch-pause",
    ".completion-lock",
    ".control-lock",
    ".review-state",
    ".provider",
    ".findings",
    ".complete",
    ".control",
    ".prompt",
    ".paused",
    ".active",
    ".state",
    ".debt",
    ".owner",
    ".config",
}
all_suffixes = sorted(state_suffixes | loop_suffixes, key=len, reverse=True)
directory_suffixes = {".review-proofs", ".control-lock"}
private_lock_suffixes = {".runtime-lock", ".completion-lock"}
preserved_payload_suffixes = {
    ".runtime",
    ".runtime-lock",
    ".completion-lock",
    ".control-lock",
    ".review-receipt.revoked",
    ".review-selection.revoked",
}
brake_suffixes = {
    ".review-receipt.revoked",
    ".review-selection.revoked",
}
final_suffixes = {".runtime-lock", ".completion-lock"}


def fail(message):
    print(f"dex session cleanup: {message}", file=sys.stderr)
    raise SystemExit(3)


def owner_and_suffix(name):
    for suffix in all_suffixes:
        if name.endswith(suffix):
            owner = name[: -len(suffix)]
            return (owner, suffix) if session_pattern.fullmatch(owner) else None
    match = phase_marker_pattern.fullmatch(name)
    if match and session_pattern.fullmatch(match.group(1)):
        return match.group(1), ".phase-marker"
    match = watch_lock_pattern.fullmatch(name)
    if match and session_pattern.fullmatch(match.group(1)):
        return match.group(1), ".watch-lock"
    match = completion_receipt_pattern.fullmatch(name)
    if match and session_pattern.fullmatch(match.group(1)):
        return match.group(1), ".completion-receipt"
    return None


def validate_entry(path, suffix):
    try:
        metadata = os.lstat(path)
    except OSError as error:
        fail(f"cannot inspect {path}: {error}")
    if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) & 0o022:
        fail(f"unsafe permissions or ownership: {path}")
    if suffix in directory_suffixes:
        if not stat.S_ISDIR(metadata.st_mode):
            fail(f"expected a directory: {path}")
        for root, directories, files in os.walk(path, topdown=True, followlinks=False):
            for name in directories + files:
                child = os.path.join(root, name)
                child_metadata = os.lstat(child)
                if (
                    child_metadata.st_uid != os.geteuid()
                    or stat.S_IMODE(child_metadata.st_mode) & 0o022
                    or stat.S_ISLNK(child_metadata.st_mode)
                    or not (
                        stat.S_ISDIR(child_metadata.st_mode)
                        or (
                            stat.S_ISREG(child_metadata.st_mode)
                            and child_metadata.st_nlink == 1
                        )
                    )
                ):
                    fail(f"unsafe nested cleanup artifact: {child}")
        return
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        fail(f"unsafe cleanup artifact: {path}")
    if suffix in private_lock_suffixes and stat.S_IMODE(metadata.st_mode) != 0o600:
        fail(f"unsafe persistent lock: {path}")


entries = []
for location, directory in (("state", state_dir), ("loop", loop_dir)):
    try:
        directory_entries = list(os.scandir(directory))
    except FileNotFoundError:
        continue
    except OSError as error:
        fail(f"cannot inspect {location} directory: {error}")
    for entry in directory_entries:
        resolved = owner_and_suffix(entry.name)
        if resolved is None or resolved[0] != selected_session:
            continue
        suffix = resolved[1]
        if suffix in state_suffixes and location != "state":
            fail(f"state artifact is in the loop directory: {entry.path}")
        if suffix in loop_suffixes and location != "loop":
            fail(f"loop artifact is in the state directory: {entry.path}")
        if suffix in {".phase-marker", ".watch-lock", ".completion-receipt"} \
                and location != "loop":
            fail(f"loop marker is in the state directory: {entry.path}")
        validate_entry(entry.path, suffix)
        entries.append((entry.path, suffix))

if operation == "validate":
    raise SystemExit(0)
if operation == "remove-payload":
    for path, suffix in entries:
        if suffix in preserved_payload_suffixes:
            continue
        if suffix in directory_suffixes:
            fail(f"cleanup directory was not retired first: {path}")
        validate_entry(path, suffix)
        try:
            os.unlink(path)
        except OSError as error:
            fail(f"cannot remove {path}: {error}")
    raise SystemExit(0)
if operation == "remove-brakes":
    for path, suffix in entries:
        if suffix not in brake_suffixes:
            continue
        validate_entry(path, suffix)
        try:
            os.unlink(path)
        except OSError as error:
            fail(f"cannot remove revocation brake {path}: {error}")
    raise SystemExit(0)
if operation == "assert-final":
    unexpected = [path for path, suffix in entries if suffix not in final_suffixes]
    if unexpected:
        fail(f"session artifacts remain: {', '.join(sorted(unexpected))}")
    raise SystemExit(0)
fail("unknown inventory operation")
PY
}

__dx_session_management_plan() { # <repo-dir> <sid> <records-file>
  [[ $# -eq 3 ]] || return 3
  python3 - "$1" "$2" "$3" <<'PY'
import json
import os
import sys


repo_dir, selected_session, records_file = sys.argv[1:]
terminal_states = {"completed", "paused", "blocked", "failed", "stopped", "abandoned"}
try:
    with open(records_file, encoding="utf-8") as source:
        records = [json.loads(line) for line in source if line.strip()]
except (OSError, ValueError):
    raise SystemExit(3)
matches = [record for record in records if record.get("session_id") == selected_session]
if len(matches) != 1:
    raise SystemExit(1)
record = matches[0]
if (
    record.get("is_child") is not False
    or record.get("metadata_health") != "valid"
    or record.get("unsafe_artifacts") != []
    or record.get("consistency_issues") != []
    or record.get("runtime_health") != "dead"
    or record.get("runtime_status") not in terminal_states
    or "runtime" not in record.get("artifacts", [])
    or record.get("workspace_mode") not in {"worktree", "in-place"}
    or not isinstance(record.get("workspace"), str)
    or not os.path.isabs(record["workspace"])
):
    raise SystemExit(1)
workspace = record["workspace"]
if "\t" in workspace or "\n" in workspace or "\r" in workspace:
    raise SystemExit(3)
print(f"parent\t{selected_session}\t{workspace}\t1")
PY
}

__dx_session_management_ensure_brakes() { # <sid>
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" receipt_revocation selection_revocation
  receipt_revocation=$(dx_review_receipt_revocation_file "$session_id") || return 1
  selection_revocation=$(dx_review_selection_revocation_file "$session_id") || return 1
  dx_review_revoke_receipt "$session_id" || return 1
  dx_review_revoke_selection "$session_id" || return 1
  dx_review_receipt_authorization_absent "$session_id" || return 1
  dx_review_selection_authorization_absent "$session_id" || return 1
  [[ -f "$receipt_revocation" && ! -L "$receipt_revocation" \
    && -f "$selection_revocation" && ! -L "$selection_revocation" ]]
}

__dx_session_management_revoke_completion() { # <sid>
  [[ $# -eq 1 ]] || return 1
  local session_id="$1"
  if ! dx_completion_cleanup "$session_id" 2>/dev/null; then
    __dx_completion_recover_cleanup "$session_id" 2>/dev/null || return 1
  fi
  [[ ! -e "$(dx_completion_expectation_file "$session_id")" \
    && ! -L "$(dx_completion_expectation_file "$session_id")" ]]
}

__dx_session_management_phase_three_safe() { # <sid>
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" busy_file
  busy_file=$(dx_phase_busy_file "$session_id" 3) || return 1
  [[ -e "$busy_file" || -L "$busy_file" ]] || return 0
  dx_phase_busy_quiesced "$session_id" 3
}

__dx_session_management_retire_phase_three() { # <sid>
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" busy_file busy_token
  busy_file=$(dx_phase_busy_file "$session_id" 3) || return 1
  [[ -e "$busy_file" || -L "$busy_file" ]] || return 0
  dx_phase_busy_quiesced "$session_id" 3 || return 1
  busy_token=$(dx_phase_busy_token "$session_id" 3)
  [[ -n "$busy_token" ]] || return 1
  dx_phase_busy_finish "$session_id" 3 "$busy_token"
}

__dx_session_management_settle_failed() { # <handle-file>
  [[ $# -eq 1 ]] || return 0
  local handle_file="$1" owner_handle=""
  [[ -f "$handle_file" && ! -L "$handle_file" ]] || return 0
  owner_handle=$(<"$handle_file")
  [[ -n "$owner_handle" ]] || return 0
  dx_session_runtime_owner_finish "$owner_handle" failed \
    >/dev/null 2>&1 || true
}

__dx_session_management_remove_transaction_dir() { # <directory>
  [[ $# -eq 1 && "$1" == /*/dex-session-cleanup.* ]] || return 1
  command rm -rf -- "$1"
}

__dx_session_management_cleanup_exact() { # <repo-dir> <sid>
  [[ $# -eq 2 ]] || return 3
  local requested_repo="$1" session_id="$2" repo_dir records_file plan_file
  local transaction_dir handle_file runtime_snapshot runtime_health owner_handle
  local workspace has_runtime checkout_token="" checkout_held=0 transition_held=0
  local cleanup_result=0
  dx_session_id_valid "$session_id" || return 3
  repo_dir=$(cd "$requested_repo" 2>/dev/null && dx_session_repo_root) || return 3
  transaction_dir=$(mktemp -d "${TMPDIR:-/tmp}/dex-session-cleanup.XXXXXX") || return 3
  chmod 700 "$transaction_dir" 2>/dev/null || {
    __dx_session_management_remove_transaction_dir "$transaction_dir" 2>/dev/null || true
    return 3
  }
  records_file="$transaction_dir/records.jsonl"
  plan_file="$transaction_dir/plan.tsv"
  handle_file="$transaction_dir/${session_id}.handle"

  if ! dx_session_catalog_records --repo "$repo_dir" --include-children \
      > "$records_file" \
    || ! __dx_session_management_plan "$repo_dir" "$session_id" \
      "$records_file" > "$plan_file" \
    || ! __dx_session_management_artifacts validate "$session_id"; then
    __dx_session_management_remove_transaction_dir "$transaction_dir" 2>/dev/null || true
    return 1
  fi
  IFS=$'\t' read -r _ session_id workspace has_runtime < "$plan_file"
  [[ "$has_runtime" == "1" ]] || {
    __dx_session_management_remove_transaction_dir "$transaction_dir" 2>/dev/null || true
    return 1
  }

  runtime_snapshot=$(dx_session_runtime_read "$session_id" 2>/dev/null) \
    || cleanup_result=1
  runtime_health=$(dx_session_runtime_health "$session_id" 2>/dev/null || true)
  [[ "$cleanup_result" -eq 0 && "$runtime_health" == "dead" ]] \
    || cleanup_result=1
  if [[ "$cleanup_result" -eq 0 ]] \
    && __dx_session_runtime_owner_recovery_start \
      "$session_id" "$runtime_snapshot" >/dev/null 2>&1; then
    owner_handle="$DX_SESSION_RUNTIME_OWNER_HANDLE"
    unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
    if ! printf '%s\n' "$owner_handle" > "$handle_file" \
      || ! chmod 600 "$handle_file"; then
      cleanup_result=1
    fi
  else
    cleanup_result=1
  fi

  if [[ "$cleanup_result" -eq 0 && -d "$workspace" ]]; then
    checkout_token="cleanup-$$-${RANDOM}-$(date +%s)"
    if dx_review_lock_acquire "$workspace" "$checkout_token" "$$"; then
      checkout_held=1
    else
      cleanup_result=1
    fi
  fi
  if [[ "$cleanup_result" -eq 0 ]]; then
    if dx_lifecycle_control_lock_acquire "$session_id"; then
      transition_held=1
    else
      cleanup_result=1
    fi
  fi
  if [[ "$cleanup_result" -eq 0 ]] \
    && { ! __dx_session_management_phase_three_safe "$session_id" \
      || ! __dx_session_management_ensure_brakes "$session_id" \
      || ! __dx_session_management_revoke_completion "$session_id" \
      || ! dx_review_ledger_reset "$session_id" \
      || ! __dx_session_management_retire_phase_three "$session_id" \
      || ! __dx_session_management_artifacts remove-payload "$session_id"; }; then
    cleanup_result=1
  fi
  if [[ "$cleanup_result" -eq 0 ]]; then
    owner_handle=$(<"$handle_file")
    if __dx_session_runtime_owner_purge "$owner_handle"; then
      command rm -f "$handle_file"
    else
      cleanup_result=1
    fi
  fi

  if [[ "$transition_held" -eq 1 ]]; then
    if ! dx_lifecycle_control_lock_release_checked "$session_id"; then
      cleanup_result=1
    fi
    transition_held=0
  fi
  if [[ "$checkout_held" -eq 1 ]]; then
    if ! dx_review_lock_release_checked "$workspace" "$checkout_token"; then
      cleanup_result=1
    fi
    checkout_held=0
  fi

  if [[ "$cleanup_result" -eq 0 ]]; then
    if ! __dx_session_management_artifacts remove-brakes "$session_id" \
      || ! __dx_session_management_artifacts assert-final "$session_id"; then
      cleanup_result=1
    fi
  fi
  if [[ "$cleanup_result" -ne 0 ]]; then
    if [[ "$transition_held" -eq 1 ]]; then
      dx_lifecycle_control_lock_release_checked "$session_id" \
        >/dev/null 2>&1 || true
    fi
    if [[ "$checkout_held" -eq 1 ]]; then
      dx_review_lock_release_checked "$workspace" "$checkout_token" \
        >/dev/null 2>&1 || true
    fi
    __dx_session_management_ensure_brakes "$session_id" \
      >/dev/null 2>&1 || true
    __dx_session_management_settle_failed "$handle_file"
  fi
  __dx_session_management_remove_transaction_dir "$transaction_dir" \
    2>/dev/null || cleanup_result=1
  return "$cleanup_result"
}

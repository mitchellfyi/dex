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
children = sorted(
    (
        candidate
        for candidate in records
        if candidate.get("is_child") is True
        and candidate.get("parent_session_id") == selected_session
    ),
    key=lambda candidate: candidate.get("session_id", ""),
)
for child in children:
    child_session = child.get("session_id")
    child_workspace = child.get("workspace")
    artifacts = child.get("artifacts", [])
    has_runtime = "runtime" in artifacts
    if (
        not isinstance(child_session, str)
        or child.get("child_kind") not in {"assessment", "pass", "review"}
        or child.get("metadata_health") != "valid"
        or child.get("unsafe_artifacts") != []
        or child.get("consistency_issues") != []
        or not isinstance(child_workspace, str)
        or not os.path.isabs(child_workspace)
        or os.path.realpath(child_workspace) != os.path.realpath(workspace)
    ):
        raise SystemExit(1)
    if has_runtime:
        if (
            child.get("runtime_health") != "dead"
            or child.get("runtime_status") not in terminal_states
        ):
            raise SystemExit(1)
    elif (
        child.get("runtime_health") != "legacy-unverifiable"
        or child.get("runtime_status") is not None
    ):
        raise SystemExit(1)
    if any(character in child_workspace for character in "\t\n\r"):
        raise SystemExit(3)
    print(
        f"child\t{child_session}\t{child_workspace}\t"
        f"{1 if has_runtime else 0}"
    )
PY
}

__dx_session_management_ensure_brakes() { # <sid>
  [[ $# -eq 1 ]] || return 1
  local session_id="$1" receipt_revocation selection_revocation brake_result=0
  receipt_revocation=$(dx_review_receipt_revocation_file "$session_id") || return 1
  selection_revocation=$(dx_review_selection_revocation_file "$session_id") || return 1
  dx_review_revoke_receipt "$session_id" || brake_result=1
  dx_review_revoke_selection "$session_id" || brake_result=1
  dx_review_receipt_authorization_absent "$session_id" || brake_result=1
  dx_review_selection_authorization_revoked "$session_id" || brake_result=1
  [[ -f "$receipt_revocation" && ! -L "$receipt_revocation" ]] \
    || brake_result=1
  [[ -f "$selection_revocation" && ! -L "$selection_revocation" ]] \
    || brake_result=1
  return "$brake_result"
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

__dx_session_management_claim_runtime() { # <sid> <handle-file>
  [[ $# -eq 2 ]] || return 1
  local session_id="$1" handle_file="$2" runtime_snapshot runtime_health
  local owner_handle
  runtime_snapshot=$(dx_session_runtime_read "$session_id" 2>/dev/null) \
    || return 1
  runtime_health=$(dx_session_runtime_health "$session_id" 2>/dev/null) \
    || return 1
  [[ "$runtime_health" == "dead" ]] || return 1
  __dx_session_runtime_owner_recovery_start \
    "$session_id" "$runtime_snapshot" >/dev/null 2>&1 || return 1
  owner_handle="$DX_SESSION_RUNTIME_OWNER_HANDLE"
  unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
  if ! printf '%s\n' "$owner_handle" > "$handle_file" \
    || ! chmod 600 "$handle_file"; then
    dx_session_runtime_owner_finish "$owner_handle" failed \
      >/dev/null 2>&1 || true
    return 1
  fi
}

__dx_session_management_settle_claims_failed() { # <claim-dir>
  [[ $# -eq 1 ]] || return 0
  local claim_dir="$1" claim_file
  while IFS= read -r -d '' claim_file; do
    [[ -f "$claim_file" && ! -L "$claim_file" ]] || continue
    __dx_session_management_settle_failed "$claim_file"
  done < <(find "$claim_dir" -maxdepth 1 -type f -name '*.handle' -print0 \
    2>/dev/null)
}

__dx_session_management_plan_brakes() { # <plan-file>
  [[ $# -eq 1 ]] || return 1
  local plan_file="$1" plan_role plan_session plan_workspace plan_runtime
  local brake_result=0
  while IFS=$'\t' read -r \
      plan_role plan_session plan_workspace plan_runtime; do
    : "$plan_role" "$plan_workspace" "$plan_runtime"
    __dx_session_management_ensure_brakes "$plan_session" \
      || brake_result=1
  done < "$plan_file"
  return "$brake_result"
}

__dx_session_management_remove_one() { # <sid>
  [[ $# -eq 1 ]] || return 1
  local session_id="$1"
  __dx_session_management_phase_three_safe "$session_id" || return 1
  __dx_session_management_ensure_brakes "$session_id" || return 1
  __dx_session_management_revoke_completion "$session_id" || return 1
  dx_review_ledger_reset "$session_id" || return 1
  __dx_session_management_retire_phase_three "$session_id" || return 1
  __dx_session_management_artifacts remove-payload "$session_id"
}

__dx_session_management_purge_claim() { # <claim-file>
  [[ $# -eq 1 ]] || return 1
  local claim_file="$1" owner_handle
  [[ -f "$claim_file" && ! -L "$claim_file" ]] || return 0
  owner_handle=$(<"$claim_file")
  [[ -n "$owner_handle" ]] || return 1
  __dx_session_runtime_owner_purge "$owner_handle" || return 1
  command rm -f "$claim_file"
}

__dx_session_management_remove_transaction_dir() { # <directory>
  [[ $# -eq 1 && "$1" == /*/dex-session-cleanup.* ]] || return 1
  command rm -rf -- "$1"
}

__dx_session_management_cleanup_exact() { # <repo-dir> <sid>
  [[ $# -eq 2 ]] || return 3
  local requested_repo="$1" target_session="$2" repo_dir records_file plan_file
  local transaction_dir claim_dir handle_file workspace=""
  local plan_role plan_session plan_workspace plan_runtime
  local checkout_token="" checkout_held=0 transition_held=0
  local transition_session="" cleanup_result=0
  dx_session_id_valid "$target_session" || return 3
  repo_dir=$(cd "$requested_repo" 2>/dev/null && dx_session_repo_root) || return 3
  transaction_dir=$(mktemp -d "${TMPDIR:-/tmp}/dex-session-cleanup.XXXXXX") || return 3
  chmod 700 "$transaction_dir" 2>/dev/null || {
    __dx_session_management_remove_transaction_dir "$transaction_dir" 2>/dev/null || true
    return 3
  }
  records_file="$transaction_dir/records.jsonl"
  plan_file="$transaction_dir/plan.tsv"
  claim_dir="$transaction_dir/claims"
  mkdir "$claim_dir" || {
    __dx_session_management_remove_transaction_dir "$transaction_dir" 2>/dev/null || true
    return 3
  }
  chmod 700 "$claim_dir" 2>/dev/null || {
    __dx_session_management_remove_transaction_dir "$transaction_dir" 2>/dev/null || true
    return 3
  }

  if ! dx_session_catalog_records --repo "$repo_dir" --include-children \
      > "$records_file" \
    || ! __dx_session_management_plan "$repo_dir" "$target_session" \
      "$records_file" > "$plan_file"; then
    __dx_session_management_remove_transaction_dir "$transaction_dir" 2>/dev/null || true
    return 1
  fi
  while IFS=$'\t' read -r \
      plan_role plan_session plan_workspace plan_runtime; do
    [[ -n "$workspace" ]] || workspace="$plan_workspace"
    if ! __dx_session_management_artifacts validate "$plan_session"; then
      cleanup_result=1
      break
    fi
    [[ "$plan_runtime" == "1" ]] || continue
    handle_file="$claim_dir/${plan_session}.handle"
    if ! __dx_session_management_claim_runtime "$plan_session" "$handle_file"; then
      cleanup_result=1
      break
    fi
  done < "$plan_file"
  if [[ "$cleanup_result" -eq 0 && -d "$workspace" ]]; then
    checkout_token="cleanup-$$-${RANDOM}-$(date +%s)"
    if dx_review_lock_acquire "$workspace" "$checkout_token" "$$"; then
      checkout_held=1
    else
      cleanup_result=1
    fi
  fi
  if [[ "$cleanup_result" -eq 0 ]]; then
    if dx_lifecycle_control_lock_acquire "$target_session"; then
      transition_held=1
      transition_session="$target_session"
    else
      cleanup_result=1
    fi
  fi
  if [[ "$cleanup_result" -eq 0 ]] && {
      ! __dx_session_management_phase_three_safe "$target_session" \
      || ! __dx_session_management_ensure_brakes "$target_session" \
      || ! __dx_session_management_revoke_completion "$target_session"; \
    }; then
    cleanup_result=1
  fi
  if [[ "$transition_held" -eq 1 ]]; then
    if ! dx_lifecycle_control_lock_release_checked "$transition_session"; then
      cleanup_result=1
    fi
    transition_held=0
    transition_session=""
  fi

  if [[ "$cleanup_result" -eq 0 ]]; then
    while IFS=$'\t' read -r \
        plan_role plan_session plan_workspace plan_runtime; do
      : "$plan_workspace" "$plan_runtime"
      [[ "$plan_role" == "child" ]] || continue
      if ! dx_lifecycle_control_lock_acquire "$plan_session"; then
        cleanup_result=1
        break
      fi
      transition_held=1
      transition_session="$plan_session"
      if ! __dx_session_management_remove_one "$plan_session"; then
        cleanup_result=1
      fi
      if ! dx_lifecycle_control_lock_release_checked "$plan_session"; then
        cleanup_result=1
      fi
      transition_held=0
      transition_session=""
      [[ "$cleanup_result" -eq 0 ]] || break
    done < "$plan_file"
  fi

  if [[ "$cleanup_result" -eq 0 ]]; then
    if dx_lifecycle_control_lock_acquire "$target_session"; then
      transition_held=1
      transition_session="$target_session"
      if ! __dx_session_management_remove_one "$target_session"; then
        cleanup_result=1
      fi
      if ! dx_lifecycle_control_lock_release_checked "$target_session"; then
        cleanup_result=1
      fi
      transition_held=0
      transition_session=""
    else
      cleanup_result=1
    fi
  fi
  if [[ "$checkout_held" -eq 1 ]]; then
    if ! dx_review_lock_release_checked "$workspace" "$checkout_token"; then
      cleanup_result=1
    fi
    checkout_held=0
  fi

  if [[ "$cleanup_result" -eq 0 ]]; then
    while IFS=$'\t' read -r \
        plan_role plan_session plan_workspace plan_runtime; do
      : "$plan_workspace"
      [[ "$plan_role" == "child" ]] || continue
      [[ "$plan_runtime" == "1" ]] || continue
      __dx_session_management_purge_claim \
        "$claim_dir/${plan_session}.handle" || cleanup_result=1
      [[ "$cleanup_result" -eq 0 ]] || break
    done < "$plan_file"
  fi
  if [[ "$cleanup_result" -eq 0 ]]; then
    __dx_session_management_purge_claim \
      "$claim_dir/${target_session}.handle" || cleanup_result=1
  fi
  if [[ "$cleanup_result" -eq 0 ]]; then
    while IFS=$'\t' read -r \
        plan_role plan_session plan_workspace plan_runtime; do
      : "$plan_role" "$plan_workspace" "$plan_runtime"
      if ! __dx_session_management_artifacts remove-brakes "$plan_session" \
        || ! __dx_session_management_artifacts assert-final "$plan_session"; then
        cleanup_result=1
        break
      fi
    done < "$plan_file"
  fi
  if [[ "$cleanup_result" -ne 0 ]]; then
    if [[ "$transition_held" -eq 1 ]]; then
      dx_lifecycle_control_lock_release_checked "$transition_session" \
        >/dev/null 2>&1 || true
    fi
    if [[ "$checkout_held" -eq 1 ]]; then
      dx_review_lock_release_checked "$workspace" "$checkout_token" \
        >/dev/null 2>&1 || true
    fi
    __dx_session_management_plan_brakes "$plan_file" \
      >/dev/null 2>&1 || true
    __dx_session_management_settle_claims_failed "$claim_dir"
  fi
  __dx_session_management_remove_transaction_dir "$transaction_dir" \
    2>/dev/null || cleanup_result=1
  return "$cleanup_result"
}

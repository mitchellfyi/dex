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
    ".cleanup-journal",
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
private_lock_suffixes = {".runtime-lock", ".completion-lock", ".cleanup-journal"}
preserved_payload_suffixes = {
    ".runtime",
    ".runtime-lock",
    ".completion-lock",
    ".control-lock",
    ".cleanup-journal",
    ".review-receipt.revoked",
    ".review-selection.revoked",
}
brake_suffixes = {
    ".review-receipt.revoked",
    ".review-selection.revoked",
}
final_suffixes = {".runtime-lock", ".completion-lock", ".cleanup-journal"}


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
    if suffix == ".cleanup-journal":
        expected = f"dex-cleanup-journal-v1\t{selected_session}\n".encode("ascii")
        try:
            with open(path, "rb") as source:
                payload = source.read(1024 * 1024 + 1)
        except OSError as error:
            fail(f"cannot read cleanup journal {path}: {error}")
        if not payload.startswith(expected) or len(payload) > 1024 * 1024:
            fail(f"unsafe cleanup journal: {path}")


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
children = sorted(
    (
        candidate
        for candidate in records
        if candidate.get("is_child") is True
        and candidate.get("parent_session_id") == selected_session
    ),
    key=lambda candidate: candidate.get("session_id", ""),
)
child_prefixes = tuple(
    f"{selected_session[:120]}-{child_kind}-"
    for child_kind in ("assessment", "pass", "review")
)
for candidate in records:
    candidate_session = candidate.get("session_id")
    if (
        candidate_session != selected_session
        and isinstance(candidate_session, str)
        and candidate_session.startswith(child_prefixes)
        and not (
            candidate.get("is_child") is True
            and candidate.get("parent_session_id") == selected_session
        )
    ):
        raise SystemExit(1)
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
    runtime_snapshot = child.get("runtime_snapshot") if has_runtime else "-"
    if has_runtime and not isinstance(runtime_snapshot, str):
        raise SystemExit(1)
    print(
        f"child\t{child_session}\t{child_workspace}\t"
        f"{1 if has_runtime else 0}\t{child.get('child_kind')}\t{runtime_snapshot}"
    )
parent_snapshot = record.get("runtime_snapshot")
if not isinstance(parent_snapshot, str):
    raise SystemExit(1)
print(f"parent\t{selected_session}\t{workspace}\t1\t-\t{parent_snapshot}")
PY
}

__dx_session_management_journal() { # <operation> <journal> <parent> <repo> [args...]
  [[ $# -ge 4 ]] || return 3
  local journal_operation="$1" journal_file="$2" parent_session="$3"
  local repo_dir="$4"
  shift 4
  python3 - "$journal_operation" "$journal_file" "$DX_STATE_DIR" \
    "$parent_session" "$repo_dir" "$@" <<'PY'
import base64
import hashlib
import json
import os
import re
import stat
import sys
import tempfile


operation, journal_file, state_dir, expected_parent, expected_repo, *arguments = sys.argv[1:]
session_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$")
hash_re = re.compile(r"^[0-9a-f]{64}$")
token_re = re.compile(r"^[0-9]+-[0-9]+-[0-9]+$")
terminal_states = {"completed", "paused", "blocked", "failed", "stopped", "abandoned"}
runtime_fields = {
    "schema_version",
    "session_id",
    "pid",
    "process_start",
    "provider",
    "workspace",
    "started_at",
    "heartbeat_at",
    "finished_at",
    "status",
    "lock_generation",
    "lock_device",
    "lock_inode",
}
top_fields = {
    "version",
    "parent_session_id",
    "repo_root",
    "workspace",
    "proof",
    "prepare_lock",
    "checkout",
    "stage",
    "entries",
}
entry_fields = {
    "role",
    "session_id",
    "child_kind",
    "metadata_sha256",
    "metadata_b64",
    "initial_runtime_snapshot",
    "runtime_snapshot",
    "runtime_stage",
    "owner_handle",
    "payload_stage",
    "transition_lock",
}
lock_fields = {"stage", "pid", "token"}
proof_fields = {"kind", "snapshots", "verified"}
proof_snapshot_fields = {"label", "source_path", "content_sha256", "content_b64"}


class JournalError(Exception):
    pass


def fail():
    raise SystemExit(3)


def private_file_read(target, maximum):
    before = os.lstat(target)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.geteuid()
        or stat.S_IMODE(before.st_mode) != 0o600
        or before.st_nlink != 1
        or before.st_size < 1
        or before.st_size > maximum
    ):
        raise JournalError
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(target, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            opened.st_dev,
            opened.st_ino,
            opened.st_mode,
            opened.st_uid,
            opened.st_nlink,
        ) != (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_uid,
            before.st_nlink,
        ):
            raise JournalError
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise JournalError
        after = os.fstat(descriptor)
        named = os.lstat(target)
        expected = (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_uid, opened.st_nlink)
        if (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_uid,
            after.st_nlink,
        ) != expected or (
            named.st_dev,
            named.st_ino,
            named.st_mode,
            named.st_uid,
            named.st_nlink,
        ) != expected:
            raise JournalError
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def parse_runtime(raw_snapshot, session_id, require_terminal=True):
    if not isinstance(raw_snapshot, str) or not raw_snapshot or len(raw_snapshot) > 16384:
        raise JournalError
    try:
        snapshot = json.loads(raw_snapshot)
    except (ValueError, RecursionError):
        raise JournalError
    if not isinstance(snapshot, dict) or set(snapshot) != runtime_fields:
        raise JournalError
    if snapshot.get("session_id") != session_id:
        raise JournalError
    if require_terminal and snapshot.get("status") not in terminal_states:
        raise JournalError
    if not isinstance(snapshot.get("pid"), int) or isinstance(snapshot.get("pid"), bool):
        raise JournalError
    return snapshot


def parse_owner_handle(owner_handle, session_id):
    if not isinstance(owner_handle, str) or not 1 <= len(owner_handle) <= 8192:
        raise JournalError
    if "\n" in owner_handle or "\r" in owner_handle or "\0" in owner_handle:
        raise JournalError
    fields = owner_handle.split("\t")
    if len(fields) != 10 or fields[0] != "v1" or fields[2] != session_id:
        raise JournalError
    if not fields[3].isdigit() or not fields[4]:
        raise JournalError
    return fields


def validate_lock(lock_record, allowed_stages):
    if not isinstance(lock_record, dict) or set(lock_record) != lock_fields:
        raise JournalError
    if lock_record["stage"] not in allowed_stages:
        raise JournalError
    if lock_record["stage"] == "held":
        if (
            not isinstance(lock_record["pid"], int)
            or isinstance(lock_record["pid"], bool)
            or lock_record["pid"] < 1
            or not isinstance(lock_record["token"], str)
            or not token_re.fullmatch(lock_record["token"])
        ):
            raise JournalError
    elif lock_record["pid"] is not None or lock_record["token"] is not None:
        raise JournalError


def decode_snapshot(encoded, expected_hash, maximum):
    if not isinstance(encoded, str) or not isinstance(expected_hash, str) \
            or not hash_re.fullmatch(expected_hash):
        raise JournalError
    try:
        payload = base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError):
        raise JournalError
    if not 1 <= len(payload) <= maximum:
        raise JournalError
    if hashlib.sha256(payload).hexdigest() != expected_hash:
        raise JournalError
    return payload


def metadata_values(payload):
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        raise JournalError
    values = {}
    for raw_line in text.splitlines():
        if not raw_line or "=" not in raw_line:
            continue
        field_name, field_value = raw_line.split("=", 1)
        if field_name in values:
            raise JournalError
        values[field_name] = field_value
    return values


def validate_proof(proof):
    if not isinstance(proof, dict) or set(proof) != proof_fields:
        raise JournalError
    if proof["kind"] not in {"runtime-only", "phase3-quiesced", "terminal", "review"}:
        raise JournalError
    if not isinstance(proof["verified"], bool) or not isinstance(proof["snapshots"], list):
        raise JournalError
    expected_count = {
        "runtime-only": 0,
        "phase3-quiesced": 2,
        "terminal": 1,
        "review": 1,
    }[proof["kind"]]
    if len(proof["snapshots"]) != expected_count:
        raise JournalError
    for snapshot in proof["snapshots"]:
        if not isinstance(snapshot, dict) or set(snapshot) != proof_snapshot_fields:
            raise JournalError
        if snapshot["label"] not in {"busy", "quiesced", "terminal", "review"}:
            raise JournalError
        if not isinstance(snapshot["source_path"], str) or not os.path.isabs(snapshot["source_path"]):
            raise JournalError
        decode_snapshot(snapshot["content_b64"], snapshot["content_sha256"], 65536)


def validate_entry(entry, parent_session, workspace):
    if not isinstance(entry, dict) or set(entry) != entry_fields:
        raise JournalError
    role = entry["role"]
    session_id = entry["session_id"]
    if role not in {"child", "parent"} or not isinstance(session_id, str) \
            or not session_re.fullmatch(session_id):
        raise JournalError
    metadata = decode_snapshot(entry["metadata_b64"], entry["metadata_sha256"], 65536)
    values = metadata_values(metadata)
    if role == "parent":
        if session_id != parent_session or entry["child_kind"] is not None:
            raise JournalError
        if any(name in values for name in ("session_role", "parent_session_id", "child_kind")):
            raise JournalError
        if values.get("wt_dir") != workspace:
            raise JournalError
    else:
        if entry["child_kind"] not in {"assessment", "pass", "review"}:
            raise JournalError
        if (
            values.get("session_role") != "review-child"
            or values.get("parent_session_id") != parent_session
            or values.get("child_kind") != entry["child_kind"]
        ):
            raise JournalError
    has_runtime = entry["initial_runtime_snapshot"] is not None
    if has_runtime:
        parse_runtime(entry["initial_runtime_snapshot"], session_id)
        parse_runtime(entry["runtime_snapshot"], session_id)
        if entry["runtime_stage"] not in {"pending", "claiming", "claimed", "terminal", "purged"}:
            raise JournalError
        if entry["runtime_stage"] == "claimed" or (
            entry["runtime_stage"] == "claiming" and entry["owner_handle"] is not None
        ):
            parse_owner_handle(entry["owner_handle"], session_id)
        elif entry["owner_handle"] is not None:
            raise JournalError
    elif (
        entry["runtime_snapshot"] is not None
        or entry["runtime_stage"] != "none"
        or entry["owner_handle"] is not None
    ):
        raise JournalError
    if entry["payload_stage"] not in {"pending", "removing", "removed"}:
        raise JournalError
    validate_lock(entry["transition_lock"], {"idle", "held", "released"})


def validate_journal(journal):
    if not isinstance(journal, dict) or set(journal) != top_fields:
        raise JournalError
    if journal["version"] != 1 or journal["parent_session_id"] != expected_parent:
        raise JournalError
    if not session_re.fullmatch(expected_parent):
        raise JournalError
    if journal["repo_root"] != expected_repo or not os.path.isabs(expected_repo):
        raise JournalError
    if not isinstance(journal["workspace"], str) or not os.path.isabs(journal["workspace"]):
        raise JournalError
    if journal["stage"] not in {"prepared", "claims", "payload", "purge", "finalize"}:
        raise JournalError
    validate_proof(journal["proof"])
    validate_lock(journal["prepare_lock"], {"held", "released"})
    validate_lock(journal["checkout"], {"idle", "held", "released", "skipped"})
    entries = journal["entries"]
    if not isinstance(entries, list) or not entries:
        raise JournalError
    seen = set()
    parent_count = 0
    for index, entry in enumerate(entries):
        validate_entry(entry, expected_parent, journal["workspace"])
        if entry["session_id"] in seen:
            raise JournalError
        seen.add(entry["session_id"])
        if entry["role"] == "parent":
            parent_count += 1
            if index != len(entries) - 1:
                raise JournalError
    if parent_count != 1:
        raise JournalError
    return journal


def read_journal():
    payload = private_file_read(journal_file, 1024 * 1024)
    header = f"dex-cleanup-journal-v1\t{expected_parent}\n".encode("ascii")
    if not payload.startswith(header):
        raise JournalError
    try:
        journal = json.loads(payload[len(header):].decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise JournalError
    return validate_journal(journal)


def atomic_write(journal):
    validate_journal(journal)
    parent_dir = os.path.dirname(journal_file)
    directory_metadata = os.stat(parent_dir, follow_symlinks=False)
    if (
        not stat.S_ISDIR(directory_metadata.st_mode)
        or directory_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(directory_metadata.st_mode) & 0o022
    ):
        raise JournalError
    if os.path.lexists(journal_file):
        private_file_read(journal_file, 1024 * 1024)
    header = f"dex-cleanup-journal-v1\t{expected_parent}\n".encode("ascii")
    payload = header + json.dumps(
        journal, sort_keys=True, separators=(",", ":")
    ).encode("utf-8") + b"\n"
    descriptor, temporary_file = tempfile.mkstemp(
        prefix=f".{os.path.basename(journal_file)}.tmp.", dir=parent_dir
    )
    try:
        os.fchmod(descriptor, 0o600)
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        os.replace(temporary_file, journal_file)
        directory_descriptor = os.open(parent_dir, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except BaseException:
        try:
            os.unlink(temporary_file)
        except OSError:
            pass
        raise


def recompute_stage(journal):
    entries = journal["entries"]
    if all(entry["payload_stage"] == "removed" for entry in entries):
        if all(entry["runtime_stage"] in {"none", "purged"} for entry in entries):
            journal["stage"] = "finalize"
        else:
            journal["stage"] = "purge"
    elif any(entry["runtime_stage"] in {"claiming", "claimed", "terminal", "purged"} for entry in entries):
        journal["stage"] = "payload"
    else:
        journal["stage"] = "claims"


def find_entry(journal, session_id):
    matches = [entry for entry in journal["entries"] if entry["session_id"] == session_id]
    if len(matches) != 1:
        raise JournalError
    return matches[0]


def proof_snapshot(label, source_path):
    payload = private_file_read(source_path, 65536)
    return {
        "label": label,
        "source_path": source_path,
        "content_sha256": hashlib.sha256(payload).hexdigest(),
        "content_b64": base64.b64encode(payload).decode("ascii"),
    }


def create_journal():
    if len(arguments) != 7 or os.path.lexists(journal_file):
        raise JournalError
    workspace, plan_file, proof_kind, proof_one, proof_two, raw_pid, prepare_token = arguments
    if not os.path.isabs(workspace) or not raw_pid.isdigit() or not token_re.fullmatch(prepare_token):
        raise JournalError
    proof_paths = []
    if proof_kind == "phase3-quiesced":
        proof_paths = [("busy", proof_one), ("quiesced", proof_two)]
    elif proof_kind == "terminal":
        proof_paths = [("terminal", proof_one)]
    elif proof_kind == "review":
        proof_paths = [("review", proof_one)]
    elif proof_kind != "runtime-only" or proof_one or proof_two:
        raise JournalError
    entries = []
    with open(plan_file, encoding="utf-8") as source:
        for raw_line in source:
            fields = raw_line.rstrip("\n").split("\t")
            if len(fields) != 6:
                raise JournalError
            role, session_id, entry_workspace, runtime_flag, child_kind, runtime_snapshot = fields
            if entry_workspace != workspace or runtime_flag not in {"0", "1"}:
                raise JournalError
            metadata = private_file_read(os.path.join(state_dir, f"{session_id}.meta"), 65536)
            if runtime_flag == "1":
                parse_runtime(runtime_snapshot, session_id)
                initial_runtime = runtime_snapshot
                current_runtime = runtime_snapshot
                runtime_stage = "pending"
            else:
                if runtime_snapshot != "-":
                    raise JournalError
                initial_runtime = None
                current_runtime = None
                runtime_stage = "none"
            entries.append(
                {
                    "role": role,
                    "session_id": session_id,
                    "child_kind": None if child_kind == "-" else child_kind,
                    "metadata_sha256": hashlib.sha256(metadata).hexdigest(),
                    "metadata_b64": base64.b64encode(metadata).decode("ascii"),
                    "initial_runtime_snapshot": initial_runtime,
                    "runtime_snapshot": current_runtime,
                    "runtime_stage": runtime_stage,
                    "owner_handle": None,
                    "payload_stage": "pending",
                    "transition_lock": {"stage": "idle", "pid": None, "token": None},
                }
            )
    journal = {
        "version": 1,
        "parent_session_id": expected_parent,
        "repo_root": expected_repo,
        "workspace": workspace,
        "proof": {
            "kind": proof_kind,
            "snapshots": [proof_snapshot(label, source) for label, source in proof_paths],
            "verified": False,
        },
        "prepare_lock": {"stage": "held", "pid": int(raw_pid), "token": prepare_token},
        "checkout": {"stage": "idle", "pid": None, "token": None},
        "stage": "prepared",
        "entries": entries,
    }
    atomic_write(journal)


def verify_current(journal, records_file):
    with open(records_file, encoding="utf-8") as source:
        records = [json.loads(line) for line in source if line.strip()]
    by_session = {record.get("session_id"): record for record in records}
    if len(by_session) != len(records):
        raise JournalError
    bound_children = {
        entry["session_id"]
        for entry in journal["entries"]
        if entry["role"] == "child"
    }
    prefixes = tuple(
        f"{expected_parent[:120]}-{kind}-"
        for kind in ("assessment", "pass", "review")
    )
    for record in records:
        session_id = record.get("session_id")
        if not isinstance(session_id, str):
            raise JournalError
        if session_id.startswith(prefixes) or record.get("parent_session_id") == expected_parent:
            if session_id not in bound_children:
                raise JournalError
    for entry in journal["entries"]:
        session_id = entry["session_id"]
        record = by_session.get(session_id)
        if record is not None and (
            record.get("unsafe_artifacts") != []
            or record.get("consistency_issues") != []
        ):
            raise JournalError
        metadata_file = os.path.join(state_dir, f"{session_id}.meta")
        metadata_exists = os.path.lexists(metadata_file)
        if entry["payload_stage"] == "pending":
            if record is None or not metadata_exists or record.get("metadata_health") != "valid":
                raise JournalError
        if metadata_exists:
            metadata = private_file_read(metadata_file, 65536)
            if hashlib.sha256(metadata).hexdigest() != entry["metadata_sha256"]:
                raise JournalError
        if entry["role"] == "child" and entry["payload_stage"] == "pending":
            if not (
                record.get("is_child") is True
                and record.get("parent_session_id") == expected_parent
                and record.get("child_kind") == entry["child_kind"]
            ):
                raise JournalError
    if not journal["proof"]["verified"]:
        for snapshot in journal["proof"]["snapshots"]:
            current = private_file_read(snapshot["source_path"], 65536)
            expected = decode_snapshot(
                snapshot["content_b64"], snapshot["content_sha256"], 65536
            )
            if current != expected:
                raise JournalError


try:
    if operation == "create":
        create_journal()
        raise SystemExit(0)

    journal = read_journal()
    if operation == "validate":
        raise SystemExit(0)
    if operation == "workspace":
        print(journal["workspace"])
        raise SystemExit(0)
    if operation == "entries":
        for entry in journal["entries"]:
            print(
                "\t".join(
                    (
                        entry["role"],
                        entry["session_id"],
                        "1" if entry["initial_runtime_snapshot"] is not None else "0",
                        entry["runtime_stage"],
                        entry["payload_stage"],
                        entry["transition_lock"]["stage"],
                        entry["child_kind"] or "-",
                    )
                )
            )
        raise SystemExit(0)
    if operation in {"runtime", "handle"}:
        if len(arguments) != 1:
            raise JournalError
        entry = find_entry(journal, arguments[0])
        value = entry["runtime_snapshot"] if operation == "runtime" else entry["owner_handle"]
        if value is not None:
            print(value)
        raise SystemExit(0)
    if operation == "prepare":
        lock_record = journal["prepare_lock"]
        print(f'{lock_record["stage"]}\t{lock_record["pid"] or ""}\t{lock_record["token"] or ""}')
        raise SystemExit(0)
    if operation == "checkout":
        lock_record = journal["checkout"]
        print(f'{lock_record["stage"]}\t{lock_record["pid"] or ""}\t{lock_record["token"] or ""}')
        raise SystemExit(0)
    if operation == "entry-lock":
        if len(arguments) != 1:
            raise JournalError
        lock_record = find_entry(journal, arguments[0])["transition_lock"]
        print(f'{lock_record["stage"]}\t{lock_record["pid"] or ""}\t{lock_record["token"] or ""}')
        raise SystemExit(0)
    if operation == "verify-current":
        if len(arguments) != 1:
            raise JournalError
        verify_current(journal, arguments[0])
        raise SystemExit(0)
    if operation == "proof-verified":
        journal["proof"]["verified"] = True
    elif operation == "prepare-released":
        journal["prepare_lock"] = {"stage": "released", "pid": None, "token": None}
    elif operation == "checkout-held":
        if len(arguments) != 2 or not arguments[0].isdigit() \
                or not token_re.fullmatch(arguments[1]):
            raise JournalError
        journal["checkout"] = {
            "stage": "held",
            "pid": int(arguments[0]),
            "token": arguments[1],
        }
    elif operation in {"checkout-released", "checkout-skipped"}:
        journal["checkout"] = {
            "stage": "released" if operation == "checkout-released" else "skipped",
            "pid": None,
            "token": None,
        }
    elif operation in {
        "claim-start",
        "claim-bound",
        "claim-abort",
        "claimed",
        "claim-terminal",
        "terminal",
        "purged",
        "payload-removing",
        "payload-removed",
        "lock-held",
        "lock-released",
    }:
        if not arguments:
            raise JournalError
        entry = find_entry(journal, arguments[0])
        extra = arguments[1:]
        if operation == "claim-start":
            if extra or entry["runtime_stage"] not in {"pending", "terminal"} \
                    or entry["owner_handle"] is not None:
                raise JournalError
            entry["runtime_stage"] = "claiming"
        elif operation == "claim-bound":
            if len(extra) != 1 or entry["runtime_stage"] != "claiming" \
                    or entry["owner_handle"] is not None:
                raise JournalError
            parse_owner_handle(extra[0], entry["session_id"])
            entry["owner_handle"] = extra[0]
        elif operation == "claim-abort":
            if len(extra) != 1 or extra[0] not in {"pending", "terminal"} \
                    or entry["runtime_stage"] != "claiming" \
                    or entry["owner_handle"] is not None:
                raise JournalError
            entry["runtime_stage"] = extra[0]
        elif operation == "claimed":
            if extra or entry["runtime_stage"] != "claiming" \
                    or entry["owner_handle"] is None:
                raise JournalError
            entry["runtime_stage"] = "claimed"
        elif operation == "claim-terminal":
            if len(extra) != 2 or entry["runtime_stage"] != "claiming":
                raise JournalError
            owner_fields = parse_owner_handle(extra[0], entry["session_id"])
            if entry["owner_handle"] is not None and entry["owner_handle"] != extra[0]:
                raise JournalError
            runtime = parse_runtime(extra[1], entry["session_id"])
            if runtime["pid"] != int(owner_fields[3]) \
                    or runtime["process_start"] != owner_fields[4]:
                raise JournalError
            entry["runtime_snapshot"] = extra[1]
            entry["runtime_stage"] = "terminal"
            entry["owner_handle"] = None
        elif operation == "terminal":
            if len(extra) != 1 or entry["runtime_stage"] != "claimed":
                raise JournalError
            runtime = parse_runtime(extra[0], entry["session_id"])
            owner_fields = parse_owner_handle(entry["owner_handle"], entry["session_id"])
            if runtime["pid"] != int(owner_fields[3]) or runtime["process_start"] != owner_fields[4]:
                raise JournalError
            entry["runtime_snapshot"] = extra[0]
            entry["runtime_stage"] = "terminal"
            entry["owner_handle"] = None
        elif operation == "purged":
            if extra or entry["runtime_stage"] not in {"claimed", "terminal", "purged"}:
                raise JournalError
            entry["runtime_stage"] = "purged"
            entry["owner_handle"] = None
        elif operation == "payload-removing":
            if extra or entry["payload_stage"] not in {"pending", "removing"}:
                raise JournalError
            entry["payload_stage"] = "removing"
        elif operation == "payload-removed":
            if extra or entry["payload_stage"] not in {"removing", "removed"}:
                raise JournalError
            entry["payload_stage"] = "removed"
        elif operation == "lock-held":
            if len(extra) != 2 or not extra[0].isdigit() or not token_re.fullmatch(extra[1]):
                raise JournalError
            entry["transition_lock"] = {
                "stage": "held",
                "pid": int(extra[0]),
                "token": extra[1],
            }
        else:
            if extra:
                raise JournalError
            entry["transition_lock"] = {"stage": "released", "pid": None, "token": None}
    elif operation == "final-records":
        if len(arguments) != 1:
            raise JournalError
        with open(arguments[0], encoding="utf-8") as source:
            records = [json.loads(line) for line in source if line.strip()]
        by_session = {record.get("session_id"): record for record in records}
        if len(by_session) != len(records):
            raise JournalError
        allowed_parent = {"cleanup-journal", "runtime-lock", "completion-lock"}
        for entry in journal["entries"]:
            record = by_session.get(entry["session_id"])
            if entry["role"] == "child":
                if record is not None:
                    raise JournalError
            elif record is None or not set(record.get("artifacts", [])).issubset(allowed_parent) \
                    or "cleanup-journal" not in record.get("artifacts", []) \
                    or record.get("unsafe_artifacts") != []:
                raise JournalError
        raise SystemExit(0)
    elif operation == "remove":
        if arguments or journal["stage"] != "finalize" \
                or journal["prepare_lock"]["stage"] != "released" \
                or journal["checkout"]["stage"] == "held" \
                or any(entry["payload_stage"] != "removed" for entry in journal["entries"]) \
                or any(entry["runtime_stage"] not in {"none", "purged"} for entry in journal["entries"]) \
                or any(entry["transition_lock"]["stage"] == "held" for entry in journal["entries"]):
            raise JournalError
        before = os.lstat(journal_file)
        private_file_read(journal_file, 1024 * 1024)
        os.unlink(journal_file)
        if os.path.lexists(journal_file):
            raise JournalError
        directory_descriptor = os.open(os.path.dirname(journal_file), os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
        raise SystemExit(0)
    else:
        raise JournalError
    recompute_stage(journal)
    atomic_write(journal)
except (JournalError, OSError, ValueError, TypeError, UnicodeError):
    fail()
PY
}

__dx_session_management_phase_three_proof() { # <repo> <parent> <plan-file>
  [[ $# -eq 3 ]] || return 1
  local repo_dir="$1" parent_session="$2" plan_file="$3"
  local plan_role plan_session plan_workspace plan_runtime plan_kind plan_snapshot
  local needs_parent_proof=0 busy_file cancel_file quiesced_file
  local receipt_file receipt_raw receipt_version receipt_tier receipt_profile
  local receipt_required receipt_clean receipt_fingerprint receipt_ledger
  local receipt_binding receipt_policy receipt_extra
  while IFS=$'\t' read -r plan_role plan_session plan_workspace plan_runtime \
      plan_kind plan_snapshot; do
    : "$plan_session" "$plan_workspace" "$plan_kind" "$plan_snapshot"
    if [[ "$plan_role" == "child" && "$plan_runtime" == "0" ]]; then
      needs_parent_proof=1
    fi
  done < "$plan_file"

  busy_file=$(dx_phase_busy_file "$parent_session" 3) || return 1
  cancel_file=$(dx_phase_busy_cancel_file "$parent_session" 3) || return 1
  quiesced_file=$(dx_phase_busy_quiesced_file "$parent_session" 3) || return 1
  if [[ -e "$busy_file" || -L "$busy_file" ]]; then
    if [[ "$needs_parent_proof" -eq 0 ]] \
      && ! dx_phase_busy_quiesced "$parent_session" 3; then
      printf '%s\t\t\n' runtime-only
      return 0
    fi
    dx_phase_busy_quiesced "$parent_session" 3 || return 1
    dx_session_trusted_file_read "$busy_file" 2048 >/dev/null || return 1
    dx_session_trusted_file_read "$quiesced_file" 2048 >/dev/null || return 1
    printf '%s\t%s\t%s\n' phase3-quiesced "$busy_file" "$quiesced_file"
    return 0
  fi
  if [[ -e "$cancel_file" || -L "$cancel_file" \
    || -e "$quiesced_file" || -L "$quiesced_file" ]]; then
    [[ "$needs_parent_proof" -eq 0 ]] || return 1
  fi
  if [[ "$needs_parent_proof" -eq 0 ]]; then
    printf '%s\t\t\n' runtime-only
    return 0
  fi
  if __dx_lifecycle_terminal_commit_valid_unlocked "$parent_session"; then
    printf '%s\t%s\t\n' terminal \
      "$(dx_lifecycle_terminal_commit_file "$parent_session")"
    return 0
  fi
  receipt_file=$(dx_review_receipt_file "$parent_session") || return 1
  receipt_raw=$(dx_session_trusted_file_read "$receipt_file" 4096 \
    2>/dev/null) || return 1
  [[ "$receipt_raw" != *$'\n'* && "$receipt_raw" != *$'\r'* ]] || return 1
  IFS=$'\t' read -r receipt_version receipt_tier receipt_profile \
    receipt_required receipt_clean receipt_fingerprint receipt_ledger \
    receipt_binding receipt_policy receipt_extra <<EOF
$receipt_raw
EOF
  [[ "$receipt_version" == "5" && -z "${receipt_extra:-}" ]] || return 1
  : "$receipt_tier" "$receipt_profile" "$receipt_required" "$receipt_clean" \
    "$receipt_fingerprint" "$receipt_ledger"
  dx_review_receipt_valid "$parent_session" "$repo_dir" \
    "$receipt_binding" "$receipt_policy" || return 1
  printf '%s\t%s\t\n' review "$receipt_file"
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

__dx_session_management_claim_runtime() { # <sid> <exact-public-snapshot>
  [[ $# -eq 2 ]] || return 1
  local session_id="$1" runtime_snapshot="$2" owner_handle
  __dx_session_runtime_owner_recovery_start \
    "$session_id" "$runtime_snapshot" >/dev/null 2>&1 || return 1
  owner_handle="$DX_SESSION_RUNTIME_OWNER_HANDLE"
  unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
  [[ -n "$owner_handle" ]] || return 1
  DX_SESSION_MANAGEMENT_OWNER_HANDLE="$owner_handle"
}

__dx_session_management_record_terminal() { # <journal> <parent> <repo> <sid>
  [[ $# -eq 4 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3" session_id="$4"
  local runtime_snapshot runtime_health runtime_state
  runtime_snapshot=$(dx_session_runtime_read "$session_id" 2>/dev/null) \
    || return 1
  runtime_health=$(dx_session_runtime_health "$session_id" 2>/dev/null) \
    || return 1
  runtime_state=$(dx_session_runtime_field "$session_id" status 2>/dev/null) \
    || return 1
  [[ "$runtime_health" == "dead" ]] || return 1
  case "$runtime_state" in
    completed|paused|blocked|failed|stopped|abandoned) ;;
    *) return 1 ;;
  esac
  __dx_session_management_journal terminal "$journal_file" \
    "$parent_session" "$repo_dir" "$session_id" "$runtime_snapshot"
}

__dx_session_management_record_claim_terminal() { # <journal> <parent> <repo> <sid> <handle>
  [[ $# -eq 5 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3" session_id="$4"
  local owner_handle="$5" runtime_snapshot runtime_health runtime_state
  runtime_snapshot=$(dx_session_runtime_read "$session_id" 2>/dev/null) \
    || return 1
  runtime_health=$(dx_session_runtime_health "$session_id" 2>/dev/null) \
    || return 1
  runtime_state=$(dx_session_runtime_field "$session_id" status 2>/dev/null) \
    || return 1
  [[ "$runtime_health" == "dead" ]] || return 1
  case "$runtime_state" in
    completed|paused|blocked|failed|stopped|abandoned) ;;
    *) return 1 ;;
  esac
  __dx_session_management_journal claim-terminal "$journal_file" \
    "$parent_session" "$repo_dir" "$session_id" "$owner_handle" \
    "$runtime_snapshot"
}

__dx_session_management_reconcile_claiming() { # <journal> <parent> <repo> <sid>
  [[ $# -eq 4 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3" session_id="$4"
  local owner_handle runtime_snapshot expected_snapshot
  owner_handle=$(__dx_session_management_journal handle "$journal_file" \
    "$parent_session" "$repo_dir" "$session_id") || return 1
  if [[ -z "$owner_handle" ]]; then
    runtime_snapshot=$(dx_session_runtime_read "$session_id" 2>/dev/null) \
      || return 1
    expected_snapshot=$(__dx_session_management_journal runtime "$journal_file" \
      "$parent_session" "$repo_dir" "$session_id") || return 1
    [[ "$runtime_snapshot" == "$expected_snapshot" ]] || return 1
    __dx_session_management_journal claim-abort "$journal_file" \
      "$parent_session" "$repo_dir" "$session_id" terminal
    return
  fi
  dx_session_runtime_owner_finish "$owner_handle" failed \
    >/dev/null 2>&1 || true
  __dx_session_management_record_claim_terminal "$journal_file" \
    "$parent_session" "$repo_dir" "$session_id" "$owner_handle"
}

__dx_session_management_settle_claims_failed() { # <journal> <parent> <repo>
  [[ $# -eq 3 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3"
  local plan_role plan_session plan_runtime runtime_stage payload_stage
  local lock_stage plan_kind owner_handle finish_result settle_result=0 entries_record
  entries_record=$(__dx_session_management_journal entries "$journal_file" \
    "$parent_session" "$repo_dir") || return 1
  while IFS=$'\t' read -r \
      plan_role plan_session plan_runtime runtime_stage payload_stage \
      lock_stage plan_kind; do
    : "$plan_role" "$plan_runtime" "$payload_stage" "$lock_stage" "$plan_kind"
    [[ "$runtime_stage" == "claimed" ]] || continue
    owner_handle=$(__dx_session_management_journal handle "$journal_file" \
      "$parent_session" "$repo_dir" "$plan_session") || {
      settle_result=1
      continue
    }
    finish_result=0
    dx_session_runtime_owner_finish "$owner_handle" failed \
      >/dev/null 2>&1 || finish_result=$?
    __dx_session_management_record_terminal "$journal_file" \
      "$parent_session" "$repo_dir" "$plan_session" || settle_result=1
    [[ "$finish_result" -eq 0 ]] || settle_result=1
  done <<EOF
$entries_record
EOF
  return "$settle_result"
}

__dx_session_management_claim_pending() { # <journal> <parent> <repo>
  [[ $# -eq 3 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3"
  local plan_role plan_session plan_runtime runtime_stage payload_stage
  local lock_stage plan_kind runtime_snapshot owner_handle prior_stage entries_record
  entries_record=$(__dx_session_management_journal entries "$journal_file" \
    "$parent_session" "$repo_dir") || return 1
  while IFS=$'\t' read -r \
      plan_role plan_session plan_runtime runtime_stage payload_stage \
      lock_stage plan_kind; do
    : "$plan_role" "$payload_stage" "$lock_stage" "$plan_kind"
    [[ "$plan_runtime" == "1" ]] || continue
    case "$runtime_stage" in
      claimed|purged) continue ;;
      pending|terminal) prior_stage="$runtime_stage" ;;
      claiming)
        __dx_session_management_reconcile_claiming "$journal_file" \
          "$parent_session" "$repo_dir" "$plan_session" || return 1
        return 1
        ;;
      *) return 1 ;;
    esac
    runtime_snapshot=$(__dx_session_management_journal runtime "$journal_file" \
      "$parent_session" "$repo_dir" "$plan_session") || return 1
    __dx_session_management_journal claim-start "$journal_file" \
      "$parent_session" "$repo_dir" "$plan_session" || return 1
    if ! __dx_session_management_claim_runtime \
        "$plan_session" "$runtime_snapshot"; then
      __dx_session_management_journal claim-abort "$journal_file" \
        "$parent_session" "$repo_dir" "$plan_session" "$prior_stage" \
        >/dev/null 2>&1 || true
      return 1
    fi
    owner_handle="$DX_SESSION_MANAGEMENT_OWNER_HANDLE"
    unset DX_SESSION_MANAGEMENT_OWNER_HANDLE
    if ! __dx_session_management_journal claim-bound "$journal_file" \
        "$parent_session" "$repo_dir" "$plan_session" "$owner_handle"; then
      dx_session_runtime_owner_finish "$owner_handle" failed \
        >/dev/null 2>&1 || true
      __dx_session_management_record_claim_terminal "$journal_file" \
        "$parent_session" "$repo_dir" "$plan_session" "$owner_handle" \
        >/dev/null 2>&1 || true
      return 1
    fi
    if ! __dx_session_management_journal claimed "$journal_file" \
        "$parent_session" "$repo_dir" "$plan_session"; then
      dx_session_runtime_owner_finish "$owner_handle" failed \
        >/dev/null 2>&1 || true
      __dx_session_management_record_claim_terminal "$journal_file" \
        "$parent_session" "$repo_dir" "$plan_session" "$owner_handle" \
        >/dev/null 2>&1 || true
      return 1
    fi
  done <<EOF
$entries_record
EOF
}

__dx_session_management_journal_brakes() { # <journal> <parent> <repo>
  [[ $# -eq 3 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3"
  local plan_role plan_session plan_runtime runtime_stage payload_stage
  local lock_stage plan_kind brake_result=0 entries_record
  entries_record=$(__dx_session_management_journal entries "$journal_file" \
    "$parent_session" "$repo_dir") || return 1
  while IFS=$'\t' read -r \
      plan_role plan_session plan_runtime runtime_stage payload_stage \
      lock_stage plan_kind; do
    : "$plan_role" "$plan_runtime" "$runtime_stage" "$payload_stage" \
      "$lock_stage" "$plan_kind"
    __dx_session_management_ensure_brakes "$plan_session" || brake_result=1
  done <<EOF
$entries_record
EOF
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

__dx_session_management_lifecycle_owner_state() { # <sid> <pid> <token>
  [[ $# -eq 3 ]] || return 2
  local session_id="$1" expected_pid="$2" expected_token="$3"
  local lock_dir owner_file owner_raw owner_pid owner_epoch owner_token owner_extra
  lock_dir=$(dx_lifecycle_control_lock_dir "$session_id") || return 2
  if [[ ! -e "$lock_dir" && ! -L "$lock_dir" ]]; then
    return 1
  fi
  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 2
  owner_file="$lock_dir/owner"
  [[ -e "$owner_file" || -L "$owner_file" ]] || return 2
  owner_raw=$(dx_lifecycle_trusted_file_read "$owner_file" 512 \
    2>/dev/null) || return 2
  IFS=$'\t' read -r owner_pid owner_epoch owner_token owner_extra <<EOF
$owner_raw
EOF
  [[ "$owner_pid" =~ ^[0-9]+$ && "$owner_epoch" =~ ^[0-9]+$ \
    && "$owner_token" =~ ^[0-9]+-[0-9]+-[0-9]+$ \
    && -z "${owner_extra:-}" ]] || return 2
  [[ "$owner_pid" == "$expected_pid" && "$owner_token" == "$expected_token" ]] \
    || return 2
}

__dx_session_management_lock_guard() { # <snapshot|detach> <kind> <lock> <detached|-> <pid> <token> [identity]
  [[ $# -ge 6 && $# -le 7 ]] || return 1
  python3 - "$@" <<'PY'
import os
import re
import stat
import sys


operation, lock_kind, lock_path, detached_path, raw_pid, token, *arguments = sys.argv[1:]
token_re = re.compile(r"^[0-9]+-[0-9]+-[0-9]+$")


class LockMismatch(Exception):
    pass


def identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
    )


def trusted_directory(metadata):
    return (
        stat.S_ISDIR(metadata.st_mode)
        and metadata.st_uid == os.geteuid()
        and not stat.S_IMODE(metadata.st_mode) & 0o022
    )


def open_directory(parent_descriptor, name):
    named = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    if not trusted_directory(named):
        raise LockMismatch
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_DIRECTORY", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    opened = os.fstat(descriptor)
    if identity(opened) != identity(named):
        os.close(descriptor)
        raise LockMismatch
    return descriptor, opened


def read_owner(lock_descriptor):
    named = os.stat("owner", dir_fd=lock_descriptor, follow_symlinks=False)
    if (
        not stat.S_ISREG(named.st_mode)
        or named.st_uid != os.geteuid()
        or stat.S_IMODE(named.st_mode) & 0o022
        or named.st_nlink != 1
        or not 1 <= named.st_size <= 512
    ):
        raise LockMismatch
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open("owner", flags, dir_fd=lock_descriptor)
    try:
        opened = os.fstat(descriptor)
        if identity(opened) != identity(named):
            raise LockMismatch
        payload = b""
        while len(payload) <= 512:
            chunk = os.read(descriptor, 513 - len(payload))
            if not chunk:
                break
            payload += chunk
        after = os.fstat(descriptor)
        current = os.stat("owner", dir_fd=lock_descriptor, follow_symlinks=False)
        if len(payload) > 512 or identity(after) != identity(opened) \
                or identity(current) != identity(opened):
            raise LockMismatch
    finally:
        os.close(descriptor)
    if sorted(os.listdir(lock_descriptor)) != ["owner"]:
        raise LockMismatch
    try:
        owner_fields = payload.decode("ascii").rstrip("\n").split("\t")
    except UnicodeDecodeError:
        raise LockMismatch
    if len(owner_fields) != 3 or payload.count(b"\n") != 1 or not payload.endswith(b"\n"):
        raise LockMismatch
    if lock_kind == "lifecycle":
        owner_pid, owner_epoch, owner_token = owner_fields
    elif lock_kind == "checkout":
        owner_epoch, owner_pid, owner_token = owner_fields
    else:
        raise LockMismatch
    if not owner_pid.isdigit() or not owner_epoch.isdigit() \
            or owner_pid != raw_pid or owner_token != token:
        raise LockMismatch
    return opened


def restore_detached(parent_descriptor, lock_name, detached_name):
    try:
        os.stat(lock_name, dir_fd=parent_descriptor, follow_symlinks=False)
        return False
    except FileNotFoundError:
        pass
    try:
        os.rename(
            detached_name,
            lock_name,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
    except OSError:
        return False
    return True


try:
    if operation not in {"snapshot", "detach"} or lock_kind not in {"lifecycle", "checkout"}:
        raise LockMismatch
    if not raw_pid.isdigit() or not token_re.fullmatch(token) or not os.path.isabs(lock_path):
        raise LockMismatch
    parent_path = os.path.dirname(lock_path)
    lock_name = os.path.basename(lock_path)
    parent_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_DIRECTORY", 0)
    if hasattr(os, "O_NOFOLLOW"):
        parent_flags |= os.O_NOFOLLOW
    parent_descriptor = os.open(parent_path, parent_flags)
    try:
        if not trusted_directory(os.fstat(parent_descriptor)):
            raise LockMismatch
        if operation == "snapshot":
            if detached_path != "-" or arguments:
                raise LockMismatch
            lock_descriptor, lock_metadata = open_directory(parent_descriptor, lock_name)
            try:
                owner_metadata = read_owner(lock_descriptor)
            finally:
                os.close(lock_descriptor)
            print(",".join(str(value) for value in identity(lock_metadata) + identity(owner_metadata)))
            raise SystemExit(0)

        if len(arguments) != 1 or not os.path.isabs(detached_path) \
                or os.path.dirname(detached_path) != parent_path:
            raise LockMismatch
        detached_name = os.path.basename(detached_path)
        if detached_name != f"{lock_name}.cleanup-detached.{token}":
            raise LockMismatch
        try:
            expected_identity = tuple(int(value) for value in arguments[0].split(","))
        except ValueError:
            raise LockMismatch
        if len(expected_identity) != 10:
            raise LockMismatch
        try:
            os.stat(detached_name, dir_fd=parent_descriptor, follow_symlinks=False)
            raise LockMismatch
        except FileNotFoundError:
            pass
        os.rename(
            lock_name,
            detached_name,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        try:
            lock_descriptor, lock_metadata = open_directory(parent_descriptor, detached_name)
            try:
                owner_metadata = read_owner(lock_descriptor)
            finally:
                os.close(lock_descriptor)
            observed_identity = identity(lock_metadata) + identity(owner_metadata)
            if observed_identity != expected_identity:
                raise LockMismatch
        except (LockMismatch, OSError):
            restore_detached(parent_descriptor, lock_name, detached_name)
            raise LockMismatch

        lock_descriptor, lock_metadata = open_directory(parent_descriptor, detached_name)
        owner_quarantine = f".cleanup-owner.{token}"
        try:
            try:
                os.stat(owner_quarantine, dir_fd=lock_descriptor, follow_symlinks=False)
                raise LockMismatch
            except FileNotFoundError:
                pass
            os.rename(
                "owner",
                owner_quarantine,
                src_dir_fd=lock_descriptor,
                dst_dir_fd=lock_descriptor,
            )
            quarantined = os.stat(
                owner_quarantine, dir_fd=lock_descriptor, follow_symlinks=False
            )
            if identity(lock_metadata) != expected_identity[:5] \
                    or identity(quarantined) != expected_identity[5:]:
                try:
                    os.stat("owner", dir_fd=lock_descriptor, follow_symlinks=False)
                except FileNotFoundError:
                    os.rename(
                        owner_quarantine,
                        "owner",
                        src_dir_fd=lock_descriptor,
                        dst_dir_fd=lock_descriptor,
                    )
                raise LockMismatch
            os.unlink(owner_quarantine, dir_fd=lock_descriptor)
            os.fsync(lock_descriptor)
        except (LockMismatch, OSError):
            os.close(lock_descriptor)
            restore_detached(parent_descriptor, lock_name, detached_name)
            raise LockMismatch
        os.close(lock_descriptor)
        os.rmdir(detached_name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    finally:
        os.close(parent_descriptor)
except (LockMismatch, OSError, ValueError):
    raise SystemExit(1)
PY
}

__dx_session_management_detach_checkpoint() { # <lifecycle|checkout> <lock> <pid> <token>
  [[ $# -eq 4 ]] || return 1
  : "$1" "$2" "$3" "$4"
}

__dx_session_management_detach_lifecycle_lock() { # <sid> <pid> <token>
  [[ $# -eq 3 ]] || return 1
  local session_id="$1" expected_pid="$2" expected_token="$3"
  local lock_dir detached_dir lock_identity
  if [[ "$expected_pid" != "$$" ]] \
    && __dx_lock_pid_alive "$expected_pid"; then
    return 1
  fi
  lock_dir=$(dx_lifecycle_control_lock_dir "$session_id") || return 1
  detached_dir="${lock_dir}.cleanup-detached.${expected_token}"
  lock_identity=$(__dx_session_management_lock_guard snapshot lifecycle \
    "$lock_dir" - "$expected_pid" "$expected_token") || return 1
  __dx_session_management_detach_checkpoint lifecycle \
    "$lock_dir" "$expected_pid" "$expected_token" || return 1
  __dx_session_management_lock_guard detach lifecycle "$lock_dir" \
    "$detached_dir" "$expected_pid" "$expected_token" "$lock_identity" \
    || return 1
  if [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" \
    && "${DX_LIFECYCLE_CONTROL_LOCK_TOKEN:-}" == "$expected_token" ]]; then
    DX_LIFECYCLE_CONTROL_LOCK_SESSION=""
    DX_LIFECYCLE_CONTROL_LOCK_TOKEN=""
  fi
}

__dx_session_management_prepare_release() { # <journal> <parent> <repo>
  [[ $# -eq 3 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3"
  local lock_record lock_stage lock_pid lock_token release_result=0 owner_state=0
  lock_record=$(__dx_session_management_journal prepare "$journal_file" \
    "$parent_session" "$repo_dir") || return 1
  IFS=$'\t' read -r lock_stage lock_pid lock_token <<EOF
$lock_record
EOF
  [[ "$lock_stage" == "held" ]] || return 0
  if [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$parent_session" \
    && "${DX_LIFECYCLE_CONTROL_LOCK_TOKEN:-}" == "$lock_token" ]]; then
    dx_lifecycle_control_lock_release "$parent_session" \
      >/dev/null 2>&1 || release_result=$?
  fi
  __dx_session_management_lifecycle_owner_state \
    "$parent_session" "$lock_pid" "$lock_token" || owner_state=$?
  if [[ "$owner_state" -eq 0 && "$lock_pid" == "$$" ]]; then
    DX_LIFECYCLE_CONTROL_LOCK_SESSION="$parent_session"
    DX_LIFECYCLE_CONTROL_LOCK_TOKEN="$lock_token"
    dx_lifecycle_control_lock_release_checked "$parent_session" \
      >/dev/null 2>&1 || release_result=1
    owner_state=0
    __dx_session_management_lifecycle_owner_state \
      "$parent_session" "$lock_pid" "$lock_token" || owner_state=$?
  fi
  if [[ "$owner_state" -eq 0 ]]; then
    __dx_session_management_detach_lifecycle_lock \
      "$parent_session" "$lock_pid" "$lock_token" || return 1
    owner_state=1
  fi
  if [[ "$owner_state" -eq 1 ]]; then
    __dx_session_management_journal prepare-released "$journal_file" \
      "$parent_session" "$repo_dir" || return 1
  elif [[ "$owner_state" -ne 0 ]]; then
    return 1
  else
    return 1
  fi
  return "$release_result"
}

__dx_session_management_entry_release() { # <journal> <parent> <repo> <sid>
  [[ $# -eq 4 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3" session_id="$4"
  local lock_record lock_stage lock_pid lock_token release_result=0 owner_state=0
  lock_record=$(__dx_session_management_journal entry-lock "$journal_file" \
    "$parent_session" "$repo_dir" "$session_id") || return 1
  IFS=$'\t' read -r lock_stage lock_pid lock_token <<EOF
$lock_record
EOF
  [[ "$lock_stage" == "held" ]] || return 0
  if [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" \
    && "${DX_LIFECYCLE_CONTROL_LOCK_TOKEN:-}" == "$lock_token" ]]; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      >/dev/null 2>&1 || release_result=$?
  fi
  __dx_session_management_lifecycle_owner_state \
    "$session_id" "$lock_pid" "$lock_token" || owner_state=$?
  if [[ "$owner_state" -eq 0 && "$lock_pid" == "$$" ]]; then
    DX_LIFECYCLE_CONTROL_LOCK_SESSION="$session_id"
    DX_LIFECYCLE_CONTROL_LOCK_TOKEN="$lock_token"
    dx_lifecycle_control_lock_release_checked "$session_id" \
      >/dev/null 2>&1 || release_result=1
    owner_state=0
    __dx_session_management_lifecycle_owner_state \
      "$session_id" "$lock_pid" "$lock_token" || owner_state=$?
  fi
  if [[ "$owner_state" -eq 0 ]]; then
    __dx_session_management_detach_lifecycle_lock \
      "$session_id" "$lock_pid" "$lock_token" || return 1
    owner_state=1
  fi
  if [[ "$owner_state" -eq 1 ]]; then
    __dx_session_management_journal lock-released "$journal_file" \
      "$parent_session" "$repo_dir" "$session_id" || return 1
  elif [[ "$owner_state" -ne 0 ]]; then
    return 1
  else
    return 1
  fi
  return "$release_result"
}

__dx_session_management_entry_acquire() { # <journal> <parent> <repo> <sid>
  [[ $# -eq 4 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3" session_id="$4"
  local lock_token
  __dx_session_management_entry_release "$journal_file" \
    "$parent_session" "$repo_dir" "$session_id" || return 1
  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  lock_token="$DX_LIFECYCLE_CONTROL_LOCK_TOKEN"
  if ! __dx_session_management_journal lock-held "$journal_file" \
      "$parent_session" "$repo_dir" "$session_id" "$$" "$lock_token"; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      >/dev/null 2>&1 || true
    return 1
  fi
}

__dx_session_management_review_owner_state() { # <workspace> <pid> <token>
  [[ $# -eq 3 ]] || return 2
  local workspace="$1" expected_pid="$2" expected_token="$3"
  local lock_dir owner_file owner_raw owner_epoch owner_pid owner_token owner_extra
  lock_dir=$(dx_review_lock_dir "$workspace" 2>/dev/null) || return 2
  if [[ ! -e "$lock_dir" && ! -L "$lock_dir" ]]; then
    return 1
  fi
  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 2
  owner_file="$lock_dir/owner"
  [[ -e "$owner_file" || -L "$owner_file" ]] || return 2
  owner_raw=$(dx_lifecycle_trusted_file_read "$owner_file" 512 \
    2>/dev/null) || return 2
  IFS=$'\t' read -r owner_epoch owner_pid owner_token owner_extra <<EOF
$owner_raw
EOF
  [[ "$owner_epoch" =~ ^[0-9]+$ && "$owner_pid" =~ ^[0-9]+$ \
    && "$owner_token" =~ ^[0-9]+-[0-9]+-[0-9]+$ \
    && -z "${owner_extra:-}" ]] || return 2
  [[ "$owner_pid" == "$expected_pid" && "$owner_token" == "$expected_token" ]] \
    || return 2
}

__dx_session_management_detach_checkout_lock() { # <workspace> <pid> <token>
  [[ $# -eq 3 ]] || return 1
  local workspace="$1" expected_pid="$2" expected_token="$3"
  local lock_dir detached_dir lock_identity
  if [[ "$expected_pid" != "$$" ]] \
    && __dx_lock_pid_alive "$expected_pid"; then
    return 1
  fi
  lock_dir=$(dx_review_lock_dir "$workspace" 2>/dev/null) || return 1
  detached_dir="${lock_dir}.cleanup-detached.${expected_token}"
  lock_identity=$(__dx_session_management_lock_guard snapshot checkout \
    "$lock_dir" - "$expected_pid" "$expected_token") || return 1
  __dx_session_management_detach_checkpoint checkout \
    "$lock_dir" "$expected_pid" "$expected_token" || return 1
  __dx_session_management_lock_guard detach checkout "$lock_dir" \
    "$detached_dir" "$expected_pid" "$expected_token" "$lock_identity"
}

__dx_session_management_checkout_release() { # <journal> <parent> <repo>
  [[ $# -eq 3 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3"
  local workspace checkout_record checkout_stage checkout_pid checkout_token
  local release_result=0 owner_state=0
  workspace=$(__dx_session_management_journal workspace "$journal_file" \
    "$parent_session" "$repo_dir") || return 1
  checkout_record=$(__dx_session_management_journal checkout "$journal_file" \
    "$parent_session" "$repo_dir") || return 1
  IFS=$'\t' read -r checkout_stage checkout_pid checkout_token <<EOF
$checkout_record
EOF
  [[ "$checkout_stage" == "held" ]] || return 0
  dx_review_lock_release_checked "$workspace" "$checkout_token" \
    >/dev/null 2>&1 || release_result=$?
  __dx_session_management_review_owner_state \
    "$workspace" "$checkout_pid" "$checkout_token" || owner_state=$?
  if [[ "$owner_state" -eq 0 ]]; then
    __dx_session_management_detach_checkout_lock \
      "$workspace" "$checkout_pid" "$checkout_token" || return 1
    owner_state=1
  fi
  if [[ "$owner_state" -eq 1 ]]; then
    __dx_session_management_journal checkout-released "$journal_file" \
      "$parent_session" "$repo_dir" || return 1
  elif [[ "$owner_state" -ne 0 ]]; then
    return 1
  else
    return 1
  fi
  return "$release_result"
}

__dx_session_management_checkout_acquire() { # <journal> <parent> <repo>
  [[ $# -eq 3 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3"
  local workspace checkout_token
  __dx_session_management_checkout_release "$journal_file" \
    "$parent_session" "$repo_dir" || return 1
  workspace=$(__dx_session_management_journal workspace "$journal_file" \
    "$parent_session" "$repo_dir") || return 1
  if [[ ! -d "$workspace" ]]; then
    __dx_session_management_journal checkout-skipped "$journal_file" \
      "$parent_session" "$repo_dir"
    return
  fi
  checkout_token="$(date +%s)-$$-${RANDOM}"
  dx_review_lock_acquire "$workspace" "$checkout_token" "$$" || return 1
  if ! __dx_session_management_journal checkout-held "$journal_file" \
      "$parent_session" "$repo_dir" "$$" "$checkout_token"; then
    dx_review_lock_release_checked "$workspace" "$checkout_token" \
      >/dev/null 2>&1 || true
    return 1
  fi
}

__dx_session_management_revalidate() { # <journal> <parent> <repo> <records-file>
  [[ $# -eq 4 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3" records_file="$4"
  local entries_record plan_role plan_session plan_runtime runtime_stage
  local payload_stage lock_stage plan_kind
  dx_session_catalog_records --repo "$repo_dir" --include-children \
    > "$records_file" || return 1
  __dx_session_management_journal verify-current "$journal_file" \
    "$parent_session" "$repo_dir" "$records_file" || return 1
  entries_record=$(__dx_session_management_journal entries "$journal_file" \
    "$parent_session" "$repo_dir") || return 1
  while IFS=$'\t' read -r plan_role plan_session plan_runtime runtime_stage \
      payload_stage lock_stage plan_kind; do
    : "$plan_role" "$plan_runtime" "$runtime_stage" "$lock_stage" "$plan_kind"
    [[ "$payload_stage" != "removed" ]] || continue
    __dx_session_management_artifacts validate "$plan_session" || return 1
  done <<EOF
$entries_record
EOF
  __dx_session_management_journal proof-verified "$journal_file" \
    "$parent_session" "$repo_dir"
}

__dx_session_management_purge_claim() { # <journal> <parent> <repo> <sid>
  [[ $# -eq 4 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3" session_id="$4"
  local owner_handle purge_result=0 runtime_file
  owner_handle=$(__dx_session_management_journal handle "$journal_file" \
    "$parent_session" "$repo_dir" "$session_id") || return 1
  [[ -n "$owner_handle" ]] || return 1
  runtime_file=$(dx_session_runtime_file "$session_id") || return 1
  __dx_session_runtime_owner_purge "$owner_handle" || purge_result=$?
  if [[ ! -e "$runtime_file" && ! -L "$runtime_file" ]]; then
    __dx_session_management_journal purged "$journal_file" \
      "$parent_session" "$repo_dir" "$session_id" || return 1
  else
    __dx_session_management_record_terminal "$journal_file" \
      "$parent_session" "$repo_dir" "$session_id" || return 1
  fi
  return "$purge_result"
}

__dx_session_management_final_catalog() { # <journal> <parent> <repo> <records-file>
  [[ $# -eq 4 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3" records_file="$4"
  dx_session_catalog_records --repo "$repo_dir" --include-children \
    > "$records_file" || return 1
  __dx_session_management_journal final-records "$journal_file" \
    "$parent_session" "$repo_dir" "$records_file"
}

__dx_session_management_release_entries() { # <journal> <parent> <repo>
  [[ $# -eq 3 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3"
  local entries_record plan_role plan_session plan_runtime runtime_stage
  local payload_stage lock_stage plan_kind release_result=0
  entries_record=$(__dx_session_management_journal entries "$journal_file" \
    "$parent_session" "$repo_dir") || return 1
  while IFS=$'\t' read -r plan_role plan_session plan_runtime runtime_stage \
      payload_stage lock_stage plan_kind; do
    : "$plan_role" "$plan_runtime" "$runtime_stage" "$payload_stage" "$plan_kind"
    [[ "$lock_stage" == "held" ]] || continue
    __dx_session_management_entry_release "$journal_file" \
      "$parent_session" "$repo_dir" "$plan_session" || release_result=1
  done <<EOF
$entries_record
EOF
  return "$release_result"
}

__dx_session_management_remove_payloads() { # <journal> <parent> <repo> <records-file>
  [[ $# -eq 4 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3" records_file="$4"
  local entries_record plan_role plan_session plan_runtime runtime_stage
  local payload_stage lock_stage plan_kind remove_result=0
  __dx_session_management_checkout_acquire "$journal_file" \
    "$parent_session" "$repo_dir" || return 1
  entries_record=$(__dx_session_management_journal entries "$journal_file" \
    "$parent_session" "$repo_dir") || return 1
  while IFS=$'\t' read -r plan_role plan_session plan_runtime runtime_stage \
      payload_stage lock_stage plan_kind; do
    : "$plan_role" "$plan_runtime" "$runtime_stage" "$lock_stage" "$plan_kind"
    [[ "$payload_stage" != "removed" ]] || continue
    if ! __dx_session_management_entry_acquire "$journal_file" \
        "$parent_session" "$repo_dir" "$plan_session"; then
      remove_result=1
      break
    fi
    if ! __dx_session_management_revalidate "$journal_file" \
        "$parent_session" "$repo_dir" "$records_file" \
      || ! __dx_session_management_journal payload-removing "$journal_file" \
        "$parent_session" "$repo_dir" "$plan_session" \
      || ! __dx_session_management_remove_one "$plan_session" \
      || ! __dx_session_management_journal payload-removed "$journal_file" \
        "$parent_session" "$repo_dir" "$plan_session"; then
      remove_result=1
    fi
    if ! __dx_session_management_entry_release "$journal_file" \
        "$parent_session" "$repo_dir" "$plan_session"; then
      remove_result=1
    fi
    [[ "$remove_result" -eq 0 ]] || break
  done <<EOF
$entries_record
EOF
  if ! __dx_session_management_checkout_release "$journal_file" \
      "$parent_session" "$repo_dir"; then
    remove_result=1
  fi
  return "$remove_result"
}

__dx_session_management_purge_claims() { # <journal> <parent> <repo>
  [[ $# -eq 3 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3"
  local entries_record plan_role plan_session plan_runtime runtime_stage
  local payload_stage lock_stage plan_kind
  entries_record=$(__dx_session_management_journal entries "$journal_file" \
    "$parent_session" "$repo_dir") || return 1
  while IFS=$'\t' read -r plan_role plan_session plan_runtime runtime_stage \
      payload_stage lock_stage plan_kind; do
    : "$plan_role" "$payload_stage" "$lock_stage" "$plan_kind"
    [[ "$plan_runtime" == "1" ]] || continue
    [[ "$runtime_stage" != "purged" ]] || continue
    [[ "$runtime_stage" == "claimed" ]] || return 1
    __dx_session_management_purge_claim "$journal_file" \
      "$parent_session" "$repo_dir" "$plan_session" || return 1
  done <<EOF
$entries_record
EOF
}

__dx_session_management_finalize() { # <journal> <parent> <repo> <records-file>
  [[ $# -eq 4 ]] || return 1
  local journal_file="$1" parent_session="$2" repo_dir="$3" records_file="$4"
  local entries_record plan_role plan_session plan_runtime runtime_stage
  local payload_stage lock_stage plan_kind remove_result=0
  entries_record=$(__dx_session_management_journal entries "$journal_file" \
    "$parent_session" "$repo_dir") || return 1
  while IFS=$'\t' read -r plan_role plan_session plan_runtime runtime_stage \
      payload_stage lock_stage plan_kind; do
    : "$plan_role" "$plan_runtime" "$runtime_stage" "$payload_stage" \
      "$lock_stage" "$plan_kind"
    __dx_session_management_artifacts remove-brakes "$plan_session" || return 1
    __dx_session_management_artifacts assert-final "$plan_session" || return 1
  done <<EOF
$entries_record
EOF
  __dx_session_management_final_catalog "$journal_file" \
    "$parent_session" "$repo_dir" "$records_file" || return 1
  __dx_session_management_journal remove "$journal_file" \
    "$parent_session" "$repo_dir" || remove_result=$?
  if [[ "$remove_result" -ne 0 \
    && ( -e "$journal_file" || -L "$journal_file" ) ]]; then
    return 1
  fi
}

__dx_session_management_remove_transaction_dir() { # <directory>
  [[ $# -eq 1 && "$1" == /*/dex-session-cleanup.* ]] || return 1
  command rm -rf -- "$1"
}

__dx_session_management_cleanup_exact() { # <repo-dir> <sid>
  [[ $# -eq 2 ]] || return 3
  local requested_repo="$1" target_session="$2" repo_dir records_file plan_file
  local transaction_dir journal_file journal_state=0 cleanup_result=0
  local workspace="" proof_record proof_kind proof_one proof_two
  local plan_role plan_session plan_workspace plan_runtime plan_kind plan_snapshot
  local prepare_token="" prepare_held=0 journal_created=0
  local entries_record payload_stage runtime_stage lock_stage
  dx_session_id_valid "$target_session" || return 3
  repo_dir=$(cd "$requested_repo" 2>/dev/null && dx_session_repo_root) || return 3
  dx_session_claim_acquire "$target_session" cleanup || return 3
  transaction_dir=$(mktemp -d "${TMPDIR:-/tmp}/dex-session-cleanup.XXXXXX") || {
    if ! dx_session_claim_release_checked "$target_session"; then
      dx_error "Dex could not release the session cleanup claim safely."
    fi
    return 3
  }
  chmod 700 "$transaction_dir" 2>/dev/null || {
    __dx_session_management_remove_transaction_dir "$transaction_dir" 2>/dev/null || true
    if ! dx_session_claim_release_checked "$target_session"; then
      dx_error "Dex could not release the session cleanup claim safely."
    fi
    return 3
  }
  records_file="$transaction_dir/records.jsonl"
  plan_file="$transaction_dir/plan.tsv"
  journal_file=$(dx_session_cleanup_journal_file "$target_session") || cleanup_result=1
  if [[ "$cleanup_result" -eq 0 ]]; then
    dx_session_cleanup_journal_state "$target_session" || journal_state=$?
    case "$journal_state" in
      0)
        __dx_session_management_journal validate "$journal_file" \
          "$target_session" "$repo_dir" || cleanup_result=1
        ;;
      1)
        if dx_lifecycle_control_lock_acquire "$target_session"; then
          prepare_held=1
          prepare_token="$DX_LIFECYCLE_CONTROL_LOCK_TOKEN"
        else
          cleanup_result=1
        fi
        if [[ "$cleanup_result" -eq 0 ]] && {
            ! dx_session_catalog_records --repo "$repo_dir" --include-children \
              > "$records_file" \
            || ! __dx_session_management_plan "$repo_dir" "$target_session" \
              "$records_file" > "$plan_file"; \
          }; then
          cleanup_result=1
        fi
        if [[ "$cleanup_result" -eq 0 ]]; then
          while IFS=$'\t' read -r plan_role plan_session plan_workspace \
              plan_runtime plan_kind plan_snapshot; do
            : "$plan_role" "$plan_runtime" "$plan_kind" "$plan_snapshot"
            [[ -n "$workspace" ]] || workspace="$plan_workspace"
            if ! __dx_session_management_artifacts validate "$plan_session"; then
              cleanup_result=1
              break
            fi
          done < "$plan_file"
        fi
        if [[ "$cleanup_result" -eq 0 ]]; then
          proof_record=$(__dx_session_management_phase_three_proof \
            "$repo_dir" "$target_session" "$plan_file") || cleanup_result=1
        fi
        if [[ "$cleanup_result" -eq 0 ]]; then
          IFS=$'\t' read -r proof_kind proof_one proof_two <<EOF
$proof_record
EOF
          if __dx_session_management_journal create "$journal_file" \
              "$target_session" "$repo_dir" "$workspace" "$plan_file" \
              "$proof_kind" "${proof_one:-}" "${proof_two:-}" \
              "$$" "$prepare_token"; then
            journal_created=1
          else
            cleanup_result=1
          fi
        fi
        if [[ "$journal_created" -eq 1 ]]; then
          __dx_session_management_prepare_release "$journal_file" \
            "$target_session" "$repo_dir" || cleanup_result=1
          prepare_held=0
        elif [[ "$prepare_held" -eq 1 ]]; then
          dx_lifecycle_control_lock_release_checked "$target_session" \
            >/dev/null 2>&1 || cleanup_result=1
          prepare_held=0
        fi
        ;;
      *) cleanup_result=1 ;;
    esac
  fi
  if [[ "$cleanup_result" -eq 0 ]]; then
    __dx_session_management_prepare_release "$journal_file" \
      "$target_session" "$repo_dir" || cleanup_result=1
  fi
  if [[ "$cleanup_result" -eq 0 ]]; then
    __dx_session_management_claim_pending "$journal_file" \
      "$target_session" "$repo_dir" || cleanup_result=1
  fi
  if [[ "$cleanup_result" -eq 0 ]]; then
    entries_record=$(__dx_session_management_journal entries "$journal_file" \
      "$target_session" "$repo_dir") || cleanup_result=1
  fi
  if [[ "$cleanup_result" -eq 0 ]]; then
    while IFS=$'\t' read -r plan_role plan_session plan_runtime runtime_stage \
        payload_stage lock_stage plan_kind; do
      : "$plan_role" "$plan_session" "$plan_runtime" "$runtime_stage" \
        "$lock_stage" "$plan_kind"
      if [[ "$payload_stage" != "removed" ]]; then
        __dx_session_management_remove_payloads "$journal_file" \
          "$target_session" "$repo_dir" "$records_file" || cleanup_result=1
        break
      fi
    done <<EOF
$entries_record
EOF
  fi
  if [[ "$cleanup_result" -eq 0 ]]; then
    __dx_session_management_release_entries "$journal_file" \
      "$target_session" "$repo_dir" || cleanup_result=1
    __dx_session_management_checkout_release "$journal_file" \
      "$target_session" "$repo_dir" || cleanup_result=1
  fi
  if [[ "$cleanup_result" -eq 0 ]]; then
    __dx_session_management_purge_claims "$journal_file" \
      "$target_session" "$repo_dir" || cleanup_result=1
  fi
  if [[ "$cleanup_result" -eq 0 ]]; then
    __dx_session_management_finalize "$journal_file" \
      "$target_session" "$repo_dir" "$records_file" || cleanup_result=1
  fi
  if [[ "$cleanup_result" -ne 0 \
    && ( "$journal_created" -eq 1 || "$journal_state" -eq 0 ) ]]; then
    __dx_session_management_prepare_release "$journal_file" \
      "$target_session" "$repo_dir" >/dev/null 2>&1 || true
    __dx_session_management_release_entries "$journal_file" \
      "$target_session" "$repo_dir" >/dev/null 2>&1 || true
    __dx_session_management_checkout_release "$journal_file" \
      "$target_session" "$repo_dir" >/dev/null 2>&1 || true
    __dx_session_management_journal_brakes "$journal_file" \
      "$target_session" "$repo_dir" >/dev/null 2>&1 || true
    __dx_session_management_settle_claims_failed "$journal_file" \
      "$target_session" "$repo_dir" >/dev/null 2>&1 || true
  fi
  __dx_session_management_remove_transaction_dir "$transaction_dir" \
    2>/dev/null || true
  if ! dx_session_claim_release_checked "$target_session"; then
    cleanup_result=1
  fi
  return "$cleanup_result"
}

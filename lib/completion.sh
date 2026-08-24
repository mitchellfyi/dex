#!/usr/bin/env bash
# shellcheck shell=bash
# Generation-bound completion expectations and receipts.

dx_completion_expectation_file() {
  local session_id="${1:-}"
  dx_session_id_valid "$session_id" || return 1
  printf '%s/%s.completion-expectation\n' "$DX_LOOP_DIR" "$session_id"
}

dx_completion_receipt_file() {
  local session_id="${1:-}" generation="${2:-}"
  dx_session_id_valid "$session_id" || return 1
  [[ "$generation" =~ ^[0-9a-f]{32}$ ]] || return 1
  printf '%s/%s.completion-receipt.%s\n' "$DX_LOOP_DIR" "$session_id" "$generation"
}

dx_completion_lock_file() {
  local session_id="${1:-}"
  dx_session_id_valid "$session_id" || return 1
  printf '%s/%s.completion-lock\n' "$DX_LOOP_DIR" "$session_id"
}

__dx_completion_run() {
  local operation="$1"
  shift
  python3 - "$operation" "$DX_LOOP_DIR" "$@" <<'PY'
import fcntl
import os
import re
import secrets
import stat
import sys
import tempfile
import time
from pathlib import Path


MAX_RECORD_BYTES = 4096
SESSION_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$")
GENERATION_PATTERN = re.compile(r"^[0-9a-f]{32}$")
EPOCH_PATTERN = re.compile(r"^[0-9]{1,15}$")
EXPECTATION_KEYS = {
    "version",
    "session_id",
    "mode",
    "purpose",
    "phase",
    "generation",
    "issued_at",
}
RECEIPT_KEYS = EXPECTATION_KEYS | {"completed_at"}
VALID_CONTEXTS = {
    ("standalone", "dxloop-plan", "1"),
    ("standalone", "dxloop-prompt", "prompt-loop"),
    ("standalone", "dxcomplete", "6"),
    ("child", "review-assessment", "assessment"),
    ("child", "review-pass", "3"),
}
LOCKED_OPERATIONS = {
    "issue",
    "ensure",
    "read",
    "current",
    "write",
    "present",
    "valid",
    "consume",
    "abandon",
    "cleanup",
}
COMPLETION_LOCK_DESCRIPTOR = None


class CompletionStateError(Exception):
    pass


def validate_session(session_id):
    if not SESSION_PATTERN.fullmatch(session_id) or session_id in {".", ".."}:
        raise CompletionStateError


def validate_generation(generation):
    if not GENERATION_PATTERN.fullmatch(generation):
        raise CompletionStateError


def validate_context(completion_mode, purpose, phase):
    if completion_mode == "lifecycle" and purpose == "phase" and phase in {
        "0",
        "1",
        "2",
        "3",
        "4",
        "5",
        "6",
    }:
        return
    if (completion_mode, purpose, phase) in VALID_CONTEXTS:
        return
    raise CompletionStateError


def expectation_file(base_dir, session_id):
    return base_dir / f"{session_id}.completion-expectation"


def receipt_file(base_dir, session_id, generation):
    return base_dir / f"{session_id}.completion-receipt.{generation}"


def legacy_file(base_dir, session_id):
    return base_dir / f"{session_id}.complete"


def lock_file(base_dir, session_id):
    return base_dir / f"{session_id}.completion-lock"


def lstat_optional(target_file):
    try:
        return os.lstat(target_file)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise CompletionStateError from error


def private_regular(metadata):
    return (
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_uid == os.geteuid()
        and stat.S_IMODE(metadata.st_mode) == 0o600
    )


def same_record_snapshot(first, second):
    return (
        private_regular(first)
        and private_regular(second)
        and first.st_dev == second.st_dev
        and first.st_ino == second.st_ino
        and first.st_size == second.st_size
        and first.st_mtime_ns == second.st_mtime_ns
    )


def read_regular(target_file, expected_keys):
    metadata = lstat_optional(target_file)
    if metadata is None or not private_regular(metadata):
        raise CompletionStateError
    if metadata.st_size <= 0 or metadata.st_size > MAX_RECORD_BYTES:
        raise CompletionStateError

    open_flags = os.O_RDONLY | os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        open_flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(target_file, open_flags)
    except OSError as error:
        raise CompletionStateError from error
    try:
        opened = os.fstat(descriptor)
        if (
            not same_record_snapshot(metadata, opened)
            or opened.st_size <= 0
            or opened.st_size > MAX_RECORD_BYTES
        ):
            raise CompletionStateError
        raw = os.read(descriptor, MAX_RECORD_BYTES + 1)
        if (
            len(raw) != opened.st_size
            or len(raw) > MAX_RECORD_BYTES
            or os.read(descriptor, 1)
        ):
            raise CompletionStateError
        finished = os.fstat(descriptor)
        if not same_record_snapshot(opened, finished):
            raise CompletionStateError
    finally:
        os.close(descriptor)

    try:
        content = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise CompletionStateError from error
    if not content.endswith("\n") or "\x00" in content or "\r" in content:
        raise CompletionStateError

    record = {}
    for line in content[:-1].split("\n"):
        key, separator, value = line.partition("=")
        if not separator or not key or not value or key in record:
            raise CompletionStateError
        record[key] = value
    if set(record) != expected_keys:
        raise CompletionStateError
    return record


def validate_expectation(record):
    if record["version"] != "1":
        raise CompletionStateError
    validate_session(record["session_id"])
    validate_context(record["mode"], record["purpose"], record["phase"])
    validate_generation(record["generation"])
    if not EPOCH_PATTERN.fullmatch(record["issued_at"]):
        raise CompletionStateError
    return record


def read_expectation(base_dir, session_id):
    record = read_regular(expectation_file(base_dir, session_id), EXPECTATION_KEYS)
    validate_expectation(record)
    if record["session_id"] != session_id:
        raise CompletionStateError
    return record


def validate_receipt(record):
    validate_expectation(record)
    if not EPOCH_PATTERN.fullmatch(record["completed_at"]):
        raise CompletionStateError
    if int(record["completed_at"]) < int(record["issued_at"]):
        raise CompletionStateError
    return record


def read_receipt(base_dir, session_id, generation):
    record = read_regular(receipt_file(base_dir, session_id, generation), RECEIPT_KEYS)
    validate_receipt(record)
    if record["session_id"] != session_id or record["generation"] != generation:
        raise CompletionStateError
    return record


def records_match(expectation, receipt):
    return all(receipt[key] == value for key, value in expectation.items())


def atomic_write(target_file, lines):
    target_file.parent.mkdir(parents=True, exist_ok=True)
    current = lstat_optional(target_file)
    if current is not None and not stat.S_ISREG(current.st_mode):
        raise CompletionStateError

    descriptor = -1
    temporary_name = ""
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{target_file.name}.tmp.", dir=str(target_file.parent)
        )
        os.fchmod(descriptor, 0o600)
        payload = "".join(f"{key}={value}\n" for key, value in lines).encode("utf-8")
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, target_file)
        temporary_name = ""
    except OSError as error:
        raise CompletionStateError from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass


def completion_entries(base_dir, session_id):
    if not base_dir.exists():
        return []
    prefix = f"{session_id}.completion-receipt."
    try:
        return [
            entry
            for entry in base_dir.iterdir()
            if entry.name.startswith(prefix)
            and GENERATION_PATTERN.fullmatch(entry.name[len(prefix) :])
        ]
    except OSError as error:
        raise CompletionStateError from error


def open_completion_lock(base_dir, session_id):
    base_dir.mkdir(parents=True, exist_ok=True)
    target_file = lock_file(base_dir, session_id)
    open_flags = os.O_RDWR | os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        open_flags |= os.O_NOFOLLOW

    for _attempt in range(3):
        metadata = lstat_optional(target_file)
        descriptor = -1
        try:
            if metadata is None:
                try:
                    descriptor = os.open(
                        target_file, open_flags | os.O_CREAT | os.O_EXCL, 0o600
                    )
                except FileExistsError:
                    continue
                os.fchmod(descriptor, 0o600)
                metadata = os.fstat(descriptor)
            else:
                if not private_regular(metadata):
                    raise CompletionStateError
                try:
                    descriptor = os.open(target_file, open_flags)
                except FileNotFoundError:
                    continue

            opened = os.fstat(descriptor)
            if (
                not private_regular(metadata)
                or not private_regular(opened)
                or metadata.st_dev != opened.st_dev
                or metadata.st_ino != opened.st_ino
            ):
                raise CompletionStateError
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            current = lstat_optional(target_file)
            locked = os.fstat(descriptor)
            if (
                current is None
                or not private_regular(current)
                or not private_regular(locked)
                or current.st_dev != locked.st_dev
                or current.st_ino != locked.st_ino
            ):
                raise CompletionStateError
            return descriptor
        except (CompletionStateError, OSError):
            if descriptor >= 0:
                os.close(descriptor)
            raise
    raise CompletionStateError


def recover_completion_lock(base_dir, session_id):
    """Repair an owned regular lock, then join its existing flock queue."""
    target_file = lock_file(base_dir, session_id)
    metadata = lstat_optional(target_file)
    if (
        metadata is None
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
    ):
        raise CompletionStateError

    open_flags = os.O_RDWR | os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        open_flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(target_file, open_flags)
    except OSError as error:
        raise CompletionStateError from error
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.geteuid()
            or metadata.st_dev != opened.st_dev
            or metadata.st_ino != opened.st_ino
        ):
            raise CompletionStateError

        # Repair the inode through the verified descriptor. Waiting on this
        # same flock lets an operation that opened it earlier finish before
        # revocation, rather than racing an unlocked cleanup around it.
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        current = lstat_optional(target_file)
        locked = os.fstat(descriptor)
        if (
            current is None
            or not private_regular(current)
            or not private_regular(locked)
            or current.st_dev != locked.st_dev
            or current.st_ino != locked.st_ino
        ):
            raise CompletionStateError
        return descriptor
    except (CompletionStateError, OSError):
        os.close(descriptor)
        raise


def unlink_all(target_files):
    for target_file in target_files:
        if lstat_optional(target_file) is None:
            continue
        try:
            os.unlink(target_file)
        except OSError as error:
            raise CompletionStateError from error


def unlink_cleanup_entry(target_file):
    metadata = lstat_optional(target_file)
    if metadata is None:
        return None
    if metadata.st_uid != os.geteuid() or stat.S_ISDIR(metadata.st_mode):
        raise CompletionStateError
    try:
        os.unlink(target_file)
    except OSError as error:
        raise CompletionStateError from error
    return metadata


def cleanup_completion(base_dir, session_id, reject_unsafe_expectation=False):
    current_expectation = expectation_file(base_dir, session_id)
    cleanup_failed = False
    expectation_metadata = None

    # Revoke both authorization paths before inspecting stale receipts. A bad
    # receipt may make cleanup fail, but it must never keep a generation live.
    try:
        expectation_metadata = unlink_cleanup_entry(current_expectation)
    except CompletionStateError:
        cleanup_failed = True
    if (
        reject_unsafe_expectation
        and expectation_metadata is not None
        and not stat.S_ISREG(expectation_metadata.st_mode)
    ):
        cleanup_failed = True
    try:
        unlink_cleanup_entry(legacy_file(base_dir, session_id))
    except CompletionStateError:
        cleanup_failed = True

    try:
        stale_receipts = completion_entries(base_dir, session_id)
    except CompletionStateError:
        stale_receipts = []
        cleanup_failed = True
    for stale_receipt in stale_receipts:
        try:
            unlink_cleanup_entry(stale_receipt)
        except CompletionStateError:
            cleanup_failed = True

    if cleanup_failed:
        raise CompletionStateError


def issue(base_dir, session_id, completion_mode, purpose, phase):
    validate_context(completion_mode, purpose, phase)
    base_dir.mkdir(parents=True, exist_ok=True)
    cleanup_completion(base_dir, session_id, reject_unsafe_expectation=True)
    while True:
        generation = secrets.token_hex(16)
        if lstat_optional(receipt_file(base_dir, session_id, generation)) is None:
            break
    issued_at = str(int(time.time()))
    atomic_write(
        expectation_file(base_dir, session_id),
        [
            ("version", "1"),
            ("session_id", session_id),
            ("mode", completion_mode),
            ("purpose", purpose),
            ("phase", phase),
            ("generation", generation),
            ("issued_at", issued_at),
        ],
    )
    return generation


def matching_expectation(base_dir, session_id, completion_mode, purpose, phase):
    record = read_expectation(base_dir, session_id)
    if (
        record["mode"] != completion_mode
        or record["purpose"] != purpose
        or record["phase"] != phase
    ):
        raise CompletionStateError
    return record


def remove_legacy(base_dir, session_id):
    unlink_cleanup_entry(legacy_file(base_dir, session_id))


def main(arguments):
    global COMPLETION_LOCK_DESCRIPTOR

    if len(arguments) < 2:
        raise CompletionStateError
    operation = arguments[0]
    base_dir = Path(arguments[1])
    values = arguments[2:]

    if operation == "context":
        if len(values) != 3:
            raise CompletionStateError
        validate_context(*values)
        return

    if not values:
        raise CompletionStateError
    session_id = values[0]
    validate_session(session_id)
    if operation == "recover-cleanup":
        if len(values) != 1:
            raise CompletionStateError
        COMPLETION_LOCK_DESCRIPTOR = recover_completion_lock(base_dir, session_id)
        cleanup_completion(base_dir, session_id)
        return
    if operation in LOCKED_OPERATIONS:
        COMPLETION_LOCK_DESCRIPTOR = open_completion_lock(base_dir, session_id)

    if operation == "issue":
        if len(values) != 4:
            raise CompletionStateError
        print(issue(base_dir, *values))
        return

    if operation == "ensure":
        if len(values) != 4:
            raise CompletionStateError
        completion_mode, purpose, phase = values[1:]
        validate_context(completion_mode, purpose, phase)
        remove_legacy(base_dir, session_id)
        try:
            record = matching_expectation(
                base_dir, session_id, completion_mode, purpose, phase
            )
        except CompletionStateError:
            metadata = lstat_optional(expectation_file(base_dir, session_id))
            if metadata is not None and (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.geteuid()
            ):
                raise
            generation = issue(base_dir, session_id, completion_mode, purpose, phase)
            print(f"{generation}\tissued")
            return
        print(f"{record['generation']}\texisting")
        return

    if operation == "read":
        if len(values) != 1:
            raise CompletionStateError
        record = read_expectation(base_dir, session_id)
        print(
            "\t".join(
                record[key]
                for key in ("mode", "purpose", "phase", "generation", "issued_at")
            )
        )
        return

    if operation == "current":
        if len(values) != 4:
            raise CompletionStateError
        record = matching_expectation(base_dir, *values)
        print(record["generation"])
        return

    if operation == "write":
        if len(values) != 2:
            raise CompletionStateError
        generation = values[1]
        validate_generation(generation)
        expectation = read_expectation(base_dir, session_id)
        if expectation["generation"] != generation:
            raise CompletionStateError
        target_file = receipt_file(base_dir, session_id, generation)
        existing = lstat_optional(target_file)
        if existing is not None:
            receipt = read_receipt(base_dir, session_id, generation)
            if not records_match(expectation, receipt):
                raise CompletionStateError
            return
        completed_at = str(max(int(time.time()), int(expectation["issued_at"])))
        atomic_write(
            target_file,
            [
                ("version", "1"),
                ("session_id", expectation["session_id"]),
                ("mode", expectation["mode"]),
                ("purpose", expectation["purpose"]),
                ("phase", expectation["phase"]),
                ("generation", expectation["generation"]),
                ("issued_at", expectation["issued_at"]),
                ("completed_at", completed_at),
            ],
        )
        return

    if operation == "present":
        if len(values) != 1:
            raise CompletionStateError
        expectation = read_expectation(base_dir, session_id)
        receipt = read_receipt(base_dir, session_id, expectation["generation"])
        if not records_match(expectation, receipt):
            raise CompletionStateError
        return

    if operation in {"valid", "consume"}:
        if len(values) != 5:
            raise CompletionStateError
        completion_mode, purpose, phase = values[1:4]
        expected_generation = values[4]
        expectation = matching_expectation(
            base_dir, session_id, completion_mode, purpose, phase
        )
        validate_generation(expected_generation)
        if expectation["generation"] != expected_generation:
            raise CompletionStateError
        receipt = read_receipt(base_dir, session_id, expectation["generation"])
        if not records_match(expectation, receipt):
            raise CompletionStateError
        if operation == "consume":
            unlink_all(
                [
                    expectation_file(base_dir, session_id),
                    legacy_file(base_dir, session_id),
                    receipt_file(base_dir, session_id, expectation["generation"]),
                ]
            )
        return

    if operation in {"abandon", "cleanup"}:
        if len(values) != 1:
            raise CompletionStateError
        cleanup_completion(base_dir, session_id)
        return

    if operation == "legacy-present":
        if len(values) != 1 or lstat_optional(legacy_file(base_dir, session_id)) is None:
            raise CompletionStateError
        return

    raise CompletionStateError


try:
    main(sys.argv[1:])
except (CompletionStateError, OSError, ValueError):
    raise SystemExit(1)
finally:
    if COMPLETION_LOCK_DESCRIPTOR is not None:
        os.close(COMPLETION_LOCK_DESCRIPTOR)
PY
}

dx_completion_context_valid() {
  [[ $# -eq 3 ]] || return 2
  __dx_completion_run context "$@"
}

# dx_completion_issue <session> <mode> <purpose> <phase>
# Replace any earlier authorization and print the new generation.
dx_completion_issue() {
  [[ $# -eq 4 ]] || return 2
  dx_session_id_valid "$1" || return 1
  __dx_completion_run issue "$@"
}

# dx_completion_ensure <session> <mode> <purpose> <phase>
# Print "generation<TAB>existing|issued". A mismatched, malformed, or
# permissive current-user regular expectation is replaced. Wrong-owner and
# nonregular entries fail closed.
dx_completion_ensure() {
  [[ $# -eq 4 ]] || return 2
  dx_session_id_valid "$1" || return 1
  __dx_completion_run ensure "$@"
}

# dx_completion_expectation_read <session>
# Print "mode<TAB>purpose<TAB>phase<TAB>generation<TAB>issued_at".
dx_completion_expectation_read() {
  [[ $# -eq 1 ]] || return 2
  dx_session_id_valid "$1" || return 1
  __dx_completion_run read "$@"
}

dx_completion_current_generation() {
  [[ $# -eq 4 ]] || return 2
  dx_session_id_valid "$1" || return 1
  __dx_completion_run current "$@"
}

# The generation is intentionally an argument. Looking up the current value at
# write time would let a delayed command complete a later phase.
dx_completion_write_receipt() {
  [[ $# -eq 2 ]] || return 2
  dx_session_id_valid "$1" || return 1
  __dx_completion_run write "$@"
}

dx_completion_receipt_present() {
  [[ $# -eq 1 ]] || return 2
  dx_session_id_valid "$1" || return 1
  __dx_completion_run present "$@"
}

dx_completion_receipt_valid() {
  [[ $# -eq 5 ]] || return 2
  dx_session_id_valid "$1" || return 1
  __dx_completion_run valid "$@"
}

# The module lock prevents completion operations from interleaving. Lifecycle
# callers also hold the transition lock across consume and phase publication;
# the module lock cannot make that larger transaction atomic by itself.
dx_completion_consume() {
  [[ $# -eq 5 ]] || return 2
  dx_session_id_valid "$1" || return 1
  __dx_completion_run consume "$@"
}

dx_completion_abandon() {
  [[ $# -eq 1 ]] || return 2
  dx_session_id_valid "$1" || return 1
  __dx_completion_run abandon "$@"
}

dx_completion_cleanup() {
  [[ $# -eq 1 ]] || return 2
  dx_session_id_valid "$1" || return 1
  __dx_completion_run cleanup "$@"
}

# Repair an owned regular lock and revoke state while holding that same inode's
# flock. Unsafe or foreign lock paths stay fail closed.
__dx_completion_recover_cleanup() {
  [[ $# -eq 1 ]] || return 2
  dx_session_id_valid "$1" || return 1
  __dx_completion_run recover-cleanup "$@"
}

dx_completion_legacy_present() {
  [[ $# -eq 1 ]] || return 2
  dx_session_id_valid "$1" || return 1
  __dx_completion_run legacy-present "$@"
}

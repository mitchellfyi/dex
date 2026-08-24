# shellcheck shell=bash
# Dex shared library - durable lifecycle runtime leases.

dx_session_runtime_file() {
  local session_id="${1:-}"
  dx_session_id_valid "$session_id" || return 3
  printf '%s/%s.runtime\n' "$DX_STATE_DIR" "$session_id"
}

__dx_session_runtime_call() {
  local operation="$1"
  shift
  python3 - "$operation" "$@" <<'PY'
import ctypes
import ctypes.util
import errno
import fcntl
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time


SCHEMA_VERSION = 2
MAX_RECORD_BYTES = 16 * 1024
MAX_PROC_BYTES = 4096
MAX_TIMESTAMP = 9_223_372_036_854_775_807
MAX_FILE_ID = 18_446_744_073_709_551_615
MAX_PID = 2_147_483_647
READ_ATTEMPTS = 8
READ_RETRY_SECONDS = 0.005
ACTIVE_STATE = "running"
TERMINAL_STATES = {"completed", "paused", "blocked", "failed", "stopped", "abandoned"}
EXPECTED_FIELDS = {
    "schema_version",
    "session_id",
    "token",
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
PUBLIC_FIELDS = EXPECTED_FIELDS - {"token"}
SESSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$")
TOKEN_RE = re.compile(r"^[0-9a-f]{64}$")
LOCK_GENERATION_RE = re.compile(r"^[0-9a-f]{32}$")
PROVIDER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
OWNER_GENERATION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$")
BOOT_ID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
LINUX_ID_RE = re.compile(
    r"^linux:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}:[0-9]{1,20}$"
)
DARWIN_ID_RE = re.compile(r"^darwin:[0-9]{1,20}:[0-9]{1,6}$")
LOCK_PREFIX = b"dex-runtime-lock-v1 "


class RuntimeInputError(Exception):
    pass


class RuntimeRecordError(Exception):
    pass


class TransientReadError(Exception):
    pass


def fail(message, return_code=3):
    print(f"dex runtime: {message}", file=sys.stderr)
    raise SystemExit(return_code)


def parse_pid(raw_pid):
    if not isinstance(raw_pid, str) or not raw_pid.isdigit() or len(raw_pid) > 10:
        raise RuntimeInputError("PID must be a positive integer")
    parsed_pid = int(raw_pid, 10)
    if parsed_pid <= 0 or parsed_pid > MAX_PID or str(parsed_pid) != raw_pid:
        raise RuntimeInputError("PID must be a positive integer")
    return parsed_pid


def exact_int(value, minimum=0, maximum=MAX_TIMESTAMP):
    return type(value) is int and minimum <= value <= maximum


def valid_text(value, max_length):
    return (
        isinstance(value, str)
        and 0 < len(value) <= max_length
        and not any(ord(character) < 32 or ord(character) == 127 for character in value)
    )


def validate_record(record, expected_session):
    if not isinstance(record, dict) or set(record) != EXPECTED_FIELDS:
        raise RuntimeRecordError("runtime record fields do not match schema version 2")
    if type(record["schema_version"]) is not int or record["schema_version"] != SCHEMA_VERSION:
        raise RuntimeRecordError("unsupported runtime record schema")
    if not isinstance(record["session_id"], str) or not SESSION_RE.fullmatch(record["session_id"]):
        raise RuntimeRecordError("invalid session ID in runtime record")
    if record["session_id"] != expected_session:
        raise RuntimeRecordError("runtime record belongs to another session")
    if not isinstance(record["token"], str) or not TOKEN_RE.fullmatch(record["token"]):
        raise RuntimeRecordError("invalid runtime lease token")
    if not exact_int(record["pid"], 1, MAX_PID):
        raise RuntimeRecordError("invalid runtime PID")
    process_start = record["process_start"]
    if not isinstance(process_start, str) or not (
        LINUX_ID_RE.fullmatch(process_start) or DARWIN_ID_RE.fullmatch(process_start)
    ):
        raise RuntimeRecordError("invalid process-start identity")
    if not isinstance(record["provider"], str) or not PROVIDER_RE.fullmatch(record["provider"]):
        raise RuntimeRecordError("invalid runtime provider")
    if not valid_text(record["workspace"], 4096) or not os.path.isabs(record["workspace"]):
        raise RuntimeRecordError("runtime workspace must be an absolute path")
    for field_name in ("started_at", "heartbeat_at"):
        if not exact_int(record[field_name], 1):
            raise RuntimeRecordError(f"invalid {field_name}")
    if record["heartbeat_at"] < record["started_at"]:
        raise RuntimeRecordError("runtime heartbeat predates its start")
    runtime_state = record["status"]
    if not isinstance(runtime_state, str) or (
        runtime_state != ACTIVE_STATE and runtime_state not in TERMINAL_STATES
    ):
        raise RuntimeRecordError("invalid runtime status")
    finished_at = record["finished_at"]
    if runtime_state == ACTIVE_STATE:
        if finished_at is not None:
            raise RuntimeRecordError("running runtime record has a finish time")
    elif not exact_int(finished_at, record["heartbeat_at"]):
        raise RuntimeRecordError("finished runtime record has an invalid finish time")
    if not isinstance(record["lock_generation"], str) or not LOCK_GENERATION_RE.fullmatch(
        record["lock_generation"]
    ):
        raise RuntimeRecordError("invalid runtime lock generation")
    if not exact_int(record["lock_device"], 0, MAX_FILE_ID) or not exact_int(
        record["lock_inode"], 1, MAX_FILE_ID
    ):
        raise RuntimeRecordError("invalid runtime lock identity")
    return record


def no_duplicate_keys(pairs):
    result = {}
    for field_name, field_value in pairs:
        if field_name in result:
            raise RuntimeRecordError(f"duplicate runtime field: {field_name}")
        result[field_name] = field_value
    return result


def public_record(record):
    return {field_name: record[field_name] for field_name in PUBLIC_FIELDS}


def validate_public_snapshot(raw_snapshot, expected_session):
    if not isinstance(raw_snapshot, str):
        raise RuntimeInputError("runtime recovery snapshot is invalid")
    try:
        encoded_snapshot = raw_snapshot.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise RuntimeInputError(f"runtime recovery snapshot is invalid: {exc}")
    if not encoded_snapshot or len(encoded_snapshot) > MAX_RECORD_BYTES:
        raise RuntimeInputError("runtime recovery snapshot size is invalid")
    try:
        snapshot = json.loads(raw_snapshot, object_pairs_hook=no_duplicate_keys)
    except (ValueError, RecursionError, RuntimeRecordError) as exc:
        raise RuntimeInputError(f"runtime recovery snapshot is malformed: {exc}")
    if not isinstance(snapshot, dict) or set(snapshot) != PUBLIC_FIELDS:
        raise RuntimeInputError("runtime recovery snapshot fields do not match schema version 2")
    private_record = dict(snapshot)
    private_record["token"] = "0" * 64
    validate_record(private_record, expected_session)
    return snapshot


def stat_fingerprint(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        getattr(metadata, "st_mtime_ns", int(metadata.st_mtime * 1_000_000_000)),
    )


def lock_fingerprint(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
    )


def directory_identity(metadata):
    return (metadata.st_dev, metadata.st_ino)


def validate_private_regular(metadata, subject, allow_empty=False):
    if not stat.S_ISREG(metadata.st_mode):
        raise RuntimeRecordError(f"{subject} is not a regular file")
    if metadata.st_nlink != 1:
        raise RuntimeRecordError(f"{subject} must have exactly one link")
    if metadata.st_uid != os.geteuid():
        raise RuntimeRecordError(f"{subject} is owned by another user")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise RuntimeRecordError(f"{subject} permissions must be 0600")
    if not allow_empty and (metadata.st_size <= 0 or metadata.st_size > MAX_RECORD_BYTES):
        raise RuntimeRecordError(f"{subject} size is invalid")


def parse_file_id(raw_value, subject, minimum=0):
    if not isinstance(raw_value, str) or not raw_value.isdigit() or len(raw_value) > 20:
        raise RuntimeInputError(f"invalid {subject}")
    parsed_value = int(raw_value, 10)
    if (
        parsed_value < minimum
        or parsed_value > MAX_FILE_ID
        or str(parsed_value) != raw_value
    ):
        raise RuntimeInputError(f"invalid {subject}")
    return parsed_value


def validate_private_directory(metadata, subject):
    if not stat.S_ISDIR(metadata.st_mode):
        raise RuntimeRecordError(f"{subject} is not a directory")
    if metadata.st_uid != os.geteuid():
        raise RuntimeRecordError(f"{subject} is owned by another user")
    if stat.S_IMODE(metadata.st_mode) != 0o700:
        raise RuntimeRecordError(f"{subject} permissions must be 0700")


def open_owner_directories(
    owner_root,
    owner_directory,
    expected_root_device=None,
    expected_root_inode=None,
    expected_owner_device=None,
    expected_owner_inode=None,
):
    if (
        not valid_text(owner_root, 4096)
        or not valid_text(owner_directory, 4096)
        or not os.path.isabs(owner_root)
        or not os.path.isabs(owner_directory)
    ):
        raise RuntimeInputError("runtime owner directories must be absolute paths")
    normalized_root = os.path.abspath(owner_root)
    normalized_owner = os.path.abspath(owner_directory)
    if os.path.dirname(normalized_owner) != normalized_root:
        raise RuntimeInputError("runtime owner directory is outside its private root")
    owner_name = os.path.basename(normalized_owner)
    if not OWNER_GENERATION_RE.fullmatch(owner_name):
        raise RuntimeInputError("runtime owner directory name is invalid")

    directory_flags = os.O_RDONLY
    directory_flags |= getattr(os, "O_CLOEXEC", 0)
    directory_flags |= getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    directory_flags |= getattr(os, "O_NONBLOCK", 0)
    root_descriptor = None
    owner_descriptor = None
    try:
        try:
            root_descriptor = os.open(normalized_root, directory_flags)
            root_metadata = os.fstat(root_descriptor)
            validate_private_directory(root_metadata, "runtime owner root")
            owner_descriptor = os.open(
                owner_name, directory_flags, dir_fd=root_descriptor
            )
            owner_metadata = os.fstat(owner_descriptor)
            validate_private_directory(owner_metadata, "runtime owner directory")
        except OSError as exc:
            raise RuntimeRecordError(f"cannot open runtime owner directory safely: {exc}")

        expected_values = (
            expected_root_device,
            expected_root_inode,
            expected_owner_device,
            expected_owner_inode,
        )
        if any(value is not None for value in expected_values):
            if any(value is None for value in expected_values):
                raise RuntimeInputError("runtime owner directory identity is incomplete")
            if (root_metadata.st_dev, root_metadata.st_ino) != (
                expected_root_device,
                expected_root_inode,
            ) or (owner_metadata.st_dev, owner_metadata.st_ino) != (
                expected_owner_device,
                expected_owner_inode,
            ):
                raise RuntimeRecordError("runtime owner directory identity changed")
        return root_descriptor, owner_descriptor, root_metadata, owner_metadata
    except Exception:
        if owner_descriptor is not None:
            os.close(owner_descriptor)
        if root_descriptor is not None:
            os.close(root_descriptor)
        raise


def owner_directory_metadata(owner_root, owner_directory):
    root_descriptor, owner_descriptor, root_metadata, owner_metadata = (
        open_owner_directories(owner_root, owner_directory)
    )
    try:
        return (
            root_metadata.st_dev,
            root_metadata.st_ino,
            owner_metadata.st_dev,
            owner_metadata.st_ino,
        )
    finally:
        os.close(owner_descriptor)
        os.close(root_descriptor)


def trusted_owner_file_read(
    owner_root,
    owner_directory,
    expected_root_device,
    expected_root_inode,
    expected_owner_device,
    expected_owner_inode,
    file_name,
    maximum_bytes,
):
    if file_name not in {"ready", "result", "command", "output", "error"}:
        raise RuntimeInputError("runtime owner file name is invalid")
    root_descriptor, owner_descriptor, _, _ = open_owner_directories(
        owner_root,
        owner_directory,
        expected_root_device,
        expected_root_inode,
        expected_owner_device,
        expected_owner_inode,
    )
    file_descriptor = None
    try:
        read_flags = os.O_RDONLY
        read_flags |= getattr(os, "O_CLOEXEC", 0)
        read_flags |= getattr(os, "O_NOFOLLOW", 0)
        read_flags |= getattr(os, "O_NONBLOCK", 0)
        try:
            file_descriptor = os.open(file_name, read_flags, dir_fd=owner_descriptor)
        except FileNotFoundError:
            raise
        except OSError as exc:
            raise RuntimeRecordError(f"cannot open runtime owner file safely: {exc}")
        opened = os.fstat(file_descriptor)
        if opened.st_nlink == 2 and file_name in {"ready", "result"}:
            temporary_prefix = f".{file_name}.tmp."
            publication_in_progress = False
            try:
                directory_entries = os.listdir(owner_descriptor)
            except OSError as exc:
                raise RuntimeRecordError(
                    f"cannot inspect runtime owner publication: {exc}"
                )
            for entry_name in directory_entries:
                if not entry_name.startswith(temporary_prefix):
                    continue
                try:
                    sibling = os.stat(
                        entry_name,
                        dir_fd=owner_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    continue
                except OSError as exc:
                    raise RuntimeRecordError(
                        f"cannot inspect runtime owner publication: {exc}"
                    )
                if (
                    (sibling.st_dev, sibling.st_ino) == (opened.st_dev, opened.st_ino)
                    and stat.S_ISREG(sibling.st_mode)
                    and sibling.st_uid == os.geteuid()
                    and stat.S_IMODE(sibling.st_mode) == 0o600
                    and sibling.st_nlink == 2
                ):
                    publication_in_progress = True
                    break
            if publication_in_progress:
                raise FileNotFoundError
            opened = os.fstat(file_descriptor)
        validate_private_regular(opened, f"runtime owner {file_name}")
        if opened.st_size > maximum_bytes:
            raise RuntimeRecordError(f"runtime owner {file_name} is too large")
        chunks = []
        remaining = maximum_bytes + 1
        while remaining > 0:
            chunk = os.read(file_descriptor, min(remaining, 512))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        after = os.fstat(file_descriptor)
        if stat_fingerprint(after) != stat_fingerprint(opened):
            raise RuntimeRecordError(f"runtime owner {file_name} changed while reading")
        if len(payload) == 0 or len(payload) > maximum_bytes:
            raise RuntimeRecordError(f"runtime owner {file_name} size is invalid")
        return payload
    finally:
        if file_descriptor is not None:
            os.close(file_descriptor)
        os.close(owner_descriptor)
        os.close(root_descriptor)


def trusted_owner_file_write(
    owner_root,
    owner_directory,
    expected_root_device,
    expected_root_inode,
    expected_owner_device,
    expected_owner_inode,
    file_name,
    replace_existing,
    content,
):
    if file_name not in {"ready", "result", "command"}:
        raise RuntimeInputError("runtime owner file name is invalid")
    if (
        not isinstance(content, str)
        or not 0 < len(content) <= 4096
        or any(
            (ord(character) < 32 and character != "\t") or ord(character) == 127
            for character in content
        )
    ):
        raise RuntimeInputError("runtime owner file content is invalid")
    root_descriptor, owner_descriptor, _, _ = open_owner_directories(
        owner_root,
        owner_directory,
        expected_root_device,
        expected_root_inode,
        expected_owner_device,
        expected_owner_inode,
    )
    temporary_name = f".{file_name}.tmp.{secrets.token_hex(16)}"
    temporary_descriptor = None
    try:
        if replace_existing:
            try:
                current = os.stat(file_name, dir_fd=owner_descriptor, follow_symlinks=False)
            except FileNotFoundError:
                current = None
            except OSError as exc:
                raise RuntimeRecordError(
                    f"cannot inspect runtime owner {file_name}: {exc}"
                )
            if current is not None:
                validate_private_regular(
                    current, f"runtime owner {file_name}", allow_empty=True
                )
        write_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        write_flags |= getattr(os, "O_CLOEXEC", 0)
        write_flags |= getattr(os, "O_NOFOLLOW", 0)
        temporary_descriptor = os.open(
            temporary_name, write_flags, 0o600, dir_fd=owner_descriptor
        )
        payload = (content + "\n").encode("utf-8")
        written = 0
        while written < len(payload):
            count = os.write(temporary_descriptor, payload[written:])
            if count <= 0:
                raise RuntimeRecordError("cannot write runtime owner file")
            written += count
        os.fsync(temporary_descriptor)
        os.close(temporary_descriptor)
        temporary_descriptor = None
        if replace_existing:
            os.replace(
                temporary_name,
                file_name,
                src_dir_fd=owner_descriptor,
                dst_dir_fd=owner_descriptor,
            )
        else:
            try:
                os.link(
                    temporary_name,
                    file_name,
                    src_dir_fd=owner_descriptor,
                    dst_dir_fd=owner_descriptor,
                    follow_symlinks=False,
                )
            except FileExistsError:
                raise RuntimeRecordError(
                    f"runtime owner {file_name} was already published"
                )
            os.unlink(temporary_name, dir_fd=owner_descriptor)
        os.fsync(owner_descriptor)
    except OSError as exc:
        raise RuntimeRecordError(f"cannot publish runtime owner {file_name}: {exc}")
    finally:
        if temporary_descriptor is not None:
            os.close(temporary_descriptor)
        try:
            os.unlink(temporary_name, dir_fd=owner_descriptor)
        except FileNotFoundError:
            pass
        except OSError:
            pass
        os.close(owner_descriptor)
        os.close(root_descriptor)


def trusted_owner_cleanup(
    owner_root,
    owner_directory,
    expected_root_device,
    expected_root_inode,
    expected_owner_device,
    expected_owner_inode,
):
    root_descriptor, owner_descriptor, _, _ = open_owner_directories(
        owner_root,
        owner_directory,
        expected_root_device,
        expected_root_inode,
        expected_owner_device,
        expected_owner_inode,
    )
    owner_name = os.path.basename(os.path.abspath(owner_directory))
    try:
        for file_name in ("ready", "command", "result", "output", "error"):
            try:
                metadata = os.stat(
                    file_name, dir_fd=owner_descriptor, follow_symlinks=False
                )
            except FileNotFoundError:
                continue
            except OSError as exc:
                raise RuntimeRecordError(
                    f"cannot inspect runtime owner cleanup file: {exc}"
                )
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid():
                raise RuntimeRecordError("runtime owner cleanup target is not trusted")
            os.unlink(file_name, dir_fd=owner_descriptor)
        os.close(owner_descriptor)
        owner_descriptor = None
        os.rmdir(owner_name, dir_fd=root_descriptor)
        os.fsync(root_descriptor)
    except OSError as exc:
        raise RuntimeRecordError(f"cannot clean runtime owner directory: {exc}")
    finally:
        if owner_descriptor is not None:
            os.close(owner_descriptor)
        os.close(root_descriptor)


def trusted_read(record_file, expected_session, missing_ok=False):
    transient_error = None
    for attempt in range(READ_ATTEMPTS):
        try:
            before = os.lstat(record_file)
        except FileNotFoundError:
            if missing_ok:
                return None
            raise
        except OSError as exc:
            raise RuntimeRecordError(f"cannot inspect runtime record: {exc}")
        validate_private_regular(before, "runtime record")

        open_flags = os.O_RDONLY
        open_flags |= getattr(os, "O_CLOEXEC", 0)
        open_flags |= getattr(os, "O_NOFOLLOW", 0)
        open_flags |= getattr(os, "O_NONBLOCK", 0)
        descriptor = None
        try:
            try:
                descriptor = os.open(record_file, open_flags)
            except FileNotFoundError as exc:
                raise TransientReadError(str(exc))
            except OSError as exc:
                if exc.errno in (errno.ENOENT, errno.ESTALE):
                    raise TransientReadError(str(exc))
                raise RuntimeRecordError(f"cannot open runtime record safely: {exc}")
            opened = os.fstat(descriptor)
            if stat_fingerprint(opened) != stat_fingerprint(before):
                raise TransientReadError("runtime record changed while opening")
            chunks = []
            remaining = MAX_RECORD_BYTES + 1
            while remaining > 0:
                chunk = os.read(descriptor, min(remaining, 4096))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            payload = b"".join(chunks)
            after = os.fstat(descriptor)
            if stat_fingerprint(after) != stat_fingerprint(opened):
                raise TransientReadError("runtime record changed while reading")
        except TransientReadError as exc:
            transient_error = exc
            if attempt + 1 == READ_ATTEMPTS:
                break
            time.sleep(READ_RETRY_SECONDS)
            continue
        finally:
            if descriptor is not None:
                os.close(descriptor)
        if len(payload) > MAX_RECORD_BYTES:
            raise RuntimeRecordError("runtime record is too large")
        try:
            record = json.loads(payload.decode("utf-8"), object_pairs_hook=no_duplicate_keys)
        except (UnicodeDecodeError, ValueError, RecursionError, RuntimeRecordError) as exc:
            raise RuntimeRecordError(f"runtime record is malformed: {exc}")
        return validate_record(record, expected_session)
    raise RuntimeRecordError(f"runtime record changed repeatedly: {transient_error}")


def validate_parent(record_file):
    parent_dir = os.path.dirname(record_file)
    try:
        os.makedirs(parent_dir, mode=0o700, exist_ok=True)
        metadata = os.lstat(parent_dir)
    except OSError as exc:
        raise RuntimeRecordError(f"cannot prepare runtime directory: {exc}")
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
        raise RuntimeRecordError("runtime directory is not a trusted local directory")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise RuntimeRecordError("runtime directory is writable by another user")
    return parent_dir


def atomic_write(record_file, record):
    parent_dir = validate_parent(record_file)
    payload = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    descriptor = None
    temporary_file = None
    try:
        descriptor, temporary_file = tempfile.mkstemp(
            prefix=f".{os.path.basename(record_file)}.tmp.", dir=parent_dir
        )
        os.fchmod(descriptor, 0o600)
        written = 0
        while written < len(payload):
            written += os.write(descriptor, payload[written:])
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.replace(temporary_file, record_file)
        temporary_file = None
        final_metadata = os.lstat(record_file)
        validate_private_regular(final_metadata, "runtime record")
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        directory_descriptor = os.open(parent_dir, directory_flags)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except OSError as exc:
        raise RuntimeRecordError(f"cannot publish runtime record: {exc}")
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary_file is not None:
            try:
                os.unlink(temporary_file)
            except FileNotFoundError:
                pass


def lock_timeout_seconds():
    raw_timeout = os.environ.get("DX_SESSION_RUNTIME_LOCK_TIMEOUT_MILLISECONDS", "5000")
    if not raw_timeout.isdigit() or len(raw_timeout) > 5:
        raise RuntimeInputError("runtime lock timeout must be 1 to 60000 milliseconds")
    timeout_ms = int(raw_timeout, 10)
    if timeout_ms < 1 or timeout_ms > 60_000:
        raise RuntimeInputError("runtime lock timeout must be 1 to 60000 milliseconds")
    return timeout_ms / 1000.0


def read_lock_generation(descriptor, allow_initialize=False):
    metadata = os.fstat(descriptor)
    validate_private_regular(metadata, "runtime lock", allow_empty=True)
    if metadata.st_size == 0 and allow_initialize:
        generation = secrets.token_hex(16)
        payload = LOCK_PREFIX + generation.encode("ascii") + b"\n"
        os.lseek(descriptor, 0, os.SEEK_SET)
        os.ftruncate(descriptor, 0)
        written = 0
        while written < len(payload):
            written += os.write(descriptor, payload[written:])
        os.fsync(descriptor)
        metadata = os.fstat(descriptor)
    if metadata.st_size <= 0 or metadata.st_size > 128:
        raise RuntimeRecordError("runtime lock identity is invalid")
    os.lseek(descriptor, 0, os.SEEK_SET)
    payload = os.read(descriptor, 129)
    expected_length = len(LOCK_PREFIX) + 32 + 1
    if len(payload) != expected_length or not payload.startswith(LOCK_PREFIX) or not payload.endswith(b"\n"):
        raise RuntimeRecordError("runtime lock identity is invalid")
    try:
        generation = payload[len(LOCK_PREFIX) : -1].decode("ascii")
    except UnicodeDecodeError:
        raise RuntimeRecordError("runtime lock identity is invalid")
    if not LOCK_GENERATION_RE.fullmatch(generation):
        raise RuntimeRecordError("runtime lock identity is invalid")
    return generation


def lock_identity(descriptor):
    metadata = os.fstat(descriptor)
    return {
        "generation": read_lock_generation(descriptor),
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
    }


def acquire_mutation_lock(record_file):
    validate_parent(record_file)
    lock_file = f"{record_file}-lock"
    open_flags = os.O_RDWR | os.O_CREAT
    open_flags |= getattr(os, "O_CLOEXEC", 0)
    open_flags |= getattr(os, "O_NOFOLLOW", 0)
    open_flags |= getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(lock_file, open_flags, 0o600)
    except OSError as exc:
        raise RuntimeRecordError(f"cannot open runtime lock safely: {exc}")
    try:
        try:
            opened_metadata = os.fstat(descriptor)
            named_metadata = os.lstat(lock_file)
        except OSError as exc:
            raise RuntimeRecordError(f"cannot inspect runtime lock safely: {exc}")
        opened_fingerprint = lock_fingerprint(opened_metadata)
        if opened_fingerprint != lock_fingerprint(named_metadata):
            raise RuntimeRecordError("runtime lock changed while opening")
        validate_private_regular(opened_metadata, "runtime lock", allow_empty=True)
        deadline = time.monotonic() + lock_timeout_seconds()
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    fail("runtime lock wait timed out", 75)
                time.sleep(min(0.02, max(0.001, deadline - time.monotonic())))
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EACCES):
                    raise RuntimeRecordError(f"cannot acquire runtime lock: {exc}")
                if time.monotonic() >= deadline:
                    fail("runtime lock wait timed out", 75)
                time.sleep(min(0.02, max(0.001, deadline - time.monotonic())))
        try:
            locked_metadata = os.fstat(descriptor)
            locked_named_metadata = os.lstat(lock_file)
        except OSError as exc:
            raise RuntimeRecordError(f"cannot revalidate runtime lock: {exc}")
        if (
            lock_fingerprint(locked_metadata) != opened_fingerprint
            or lock_fingerprint(locked_named_metadata) != opened_fingerprint
        ):
            raise RuntimeRecordError("runtime lock changed before ownership was established")
        validate_private_regular(locked_metadata, "runtime lock", allow_empty=True)
        read_lock_generation(descriptor, allow_initialize=True)
        held_identity = lock_identity(descriptor)
        verify_lock_binding(descriptor, lock_file, held_identity)
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor, lock_file, held_identity


def release_mutation_lock(descriptor):
    try:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def verify_lock_binding(descriptor, lock_file, expected_identity):
    try:
        opened = os.fstat(descriptor)
        named = os.lstat(lock_file)
    except OSError as exc:
        raise RuntimeRecordError(f"cannot revalidate runtime lock: {exc}")
    validate_private_regular(opened, "runtime lock", allow_empty=True)
    validate_private_regular(named, "runtime lock", allow_empty=True)
    if lock_fingerprint(opened) != lock_fingerprint(named):
        raise RuntimeRecordError("runtime lock path was replaced")
    observed = lock_identity(descriptor)
    if observed != expected_identity:
        raise RuntimeRecordError("runtime lock identity changed")


def trusted_lock_identity(lock_file):
    transient_error = None
    for attempt in range(READ_ATTEMPTS):
        descriptor = None
        try:
            before = os.lstat(lock_file)
            validate_private_regular(before, "runtime lock", allow_empty=True)
            open_flags = os.O_RDONLY
            open_flags |= getattr(os, "O_CLOEXEC", 0)
            open_flags |= getattr(os, "O_NOFOLLOW", 0)
            open_flags |= getattr(os, "O_NONBLOCK", 0)
            descriptor = os.open(lock_file, open_flags)
            opened = os.fstat(descriptor)
            if stat_fingerprint(opened) != stat_fingerprint(before):
                raise TransientReadError("runtime lock changed while opening")
            observed = lock_identity(descriptor)
            after = os.fstat(descriptor)
            if stat_fingerprint(after) != stat_fingerprint(opened):
                raise TransientReadError("runtime lock changed while reading")
            return observed
        except FileNotFoundError as exc:
            transient_error = exc
        except OSError as exc:
            if exc.errno not in (errno.ENOENT, errno.ESTALE):
                raise RuntimeRecordError(f"cannot inspect runtime lock safely: {exc}")
            transient_error = exc
        except TransientReadError as exc:
            transient_error = exc
        finally:
            if descriptor is not None:
                os.close(descriptor)
        if attempt + 1 < READ_ATTEMPTS:
            time.sleep(READ_RETRY_SECONDS)
    raise RuntimeRecordError(f"runtime lock changed repeatedly: {transient_error}")


def record_lock_identity(record):
    return {
        "generation": record["lock_generation"],
        "device": record["lock_device"],
        "inode": record["lock_inode"],
    }


def require_record_lock(record, observed_identity):
    if record_lock_identity(record) != observed_identity:
        raise RuntimeRecordError("runtime record is bound to another lock")


def publish_record(descriptor, lock_file, held_identity, record_file, record, session_id):
    validate_record(record, session_id)
    require_record_lock(record, held_identity)
    verify_lock_binding(descriptor, lock_file, held_identity)
    atomic_write(record_file, record)
    verify_lock_binding(descriptor, lock_file, held_identity)
    published = trusted_read(record_file, session_id)
    if published != record:
        raise RuntimeRecordError("runtime record changed after publication")
    require_record_lock(published, trusted_lock_identity(lock_file))


def verify_named_runtime_directory(
    parent_descriptor, parent_dir, expected_identity
):
    try:
        parent_opened = os.fstat(parent_descriptor)
        parent_named = os.lstat(parent_dir)
    except OSError as exc:
        raise RuntimeRecordError(f"cannot revalidate runtime directory: {exc}")
    for metadata in (parent_opened, parent_named):
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or stat.S_IMODE(metadata.st_mode) & 0o022
        ):
            raise RuntimeRecordError("runtime directory is not trusted")
    if (
        directory_identity(parent_opened) != expected_identity
        or directory_identity(parent_named) != expected_identity
    ):
        raise RuntimeRecordError("runtime directory path changed during purge")


def trusted_purge_record(
    descriptor, lock_file, held_identity, record_file, expected_record, session_id
):
    verify_lock_binding(descriptor, lock_file, held_identity)
    parent_dir = validate_parent(record_file)
    record_name = os.path.basename(record_file)
    if not record_name or os.path.dirname(record_file) != parent_dir:
        raise RuntimeRecordError("runtime record path is invalid")

    parent_descriptor = None
    record_descriptor = None
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_CLOEXEC", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    record_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    record_flags |= getattr(os, "O_NOFOLLOW", 0)
    record_flags |= getattr(os, "O_NONBLOCK", 0)
    try:
        parent_before = os.lstat(parent_dir)
        parent_descriptor = os.open(parent_dir, directory_flags)
        parent_opened = os.fstat(parent_descriptor)
        parent_identity = directory_identity(parent_opened)
        if parent_identity != directory_identity(parent_before):
            raise RuntimeRecordError("runtime directory changed while opening")
        verify_named_runtime_directory(
            parent_descriptor, parent_dir, parent_identity
        )

        record_before = os.stat(
            record_name, dir_fd=parent_descriptor, follow_symlinks=False
        )
        validate_private_regular(record_before, "runtime record")
        record_descriptor = os.open(
            record_name, record_flags, dir_fd=parent_descriptor
        )
        record_opened = os.fstat(record_descriptor)
        if stat_fingerprint(record_opened) != stat_fingerprint(record_before):
            raise RuntimeRecordError("runtime record changed while opening for purge")

        observed_record = trusted_read(record_file, session_id)
        if observed_record != expected_record:
            raise RuntimeRecordError("runtime record changed before purge")
        record_named = os.stat(
            record_name, dir_fd=parent_descriptor, follow_symlinks=False
        )
        if stat_fingerprint(record_named) != stat_fingerprint(record_opened):
            raise RuntimeRecordError("runtime record path changed before purge")

        verify_lock_binding(descriptor, lock_file, held_identity)
        verify_named_runtime_directory(
            parent_descriptor, parent_dir, parent_identity
        )
        os.unlink(record_name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
        verify_named_runtime_directory(
            parent_descriptor, parent_dir, parent_identity
        )
        verify_lock_binding(descriptor, lock_file, held_identity)
        try:
            os.stat(record_name, dir_fd=parent_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise RuntimeRecordError("runtime record reappeared during purge")
        verify_named_runtime_directory(
            parent_descriptor, parent_dir, parent_identity
        )
    except OSError as exc:
        raise RuntimeRecordError(f"cannot purge runtime record safely: {exc}")
    finally:
        if record_descriptor is not None:
            os.close(record_descriptor)
        if parent_descriptor is not None:
            os.close(parent_descriptor)


def secure_proc_read(file_name):
    open_flags = os.O_RDONLY
    open_flags |= getattr(os, "O_CLOEXEC", 0)
    open_flags |= getattr(os, "O_NOFOLLOW", 0)
    open_flags |= getattr(os, "O_NONBLOCK", 0)
    descriptor = None
    try:
        descriptor = os.open(file_name, open_flags)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            return None
        payload = os.read(descriptor, MAX_PROC_BYTES + 1)
    except (OSError, ValueError):
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)
    if len(payload) > MAX_PROC_BYTES:
        return None
    return payload


def linux_process_probe(pid):
    proc_root = os.environ.get("DX_SESSION_RUNTIME_PROC_ROOT", "/proc")
    boot_payload = secure_proc_read(os.path.join(proc_root, "sys", "kernel", "random", "boot_id"))
    stat_payload = secure_proc_read(os.path.join(proc_root, str(pid), "stat"))
    if boot_payload is None or stat_payload is None:
        return None
    try:
        boot_id = boot_payload.decode("ascii").strip()
        line = stat_payload.decode("ascii").strip()
    except UnicodeDecodeError:
        return None
    if not BOOT_ID_RE.fullmatch(boot_id):
        return None
    closing_parenthesis = line.rfind(")")
    opening_parenthesis = line.find("(")
    if opening_parenthesis <= 0 or closing_parenthesis <= opening_parenthesis:
        return None
    if line[:opening_parenthesis].strip() != str(pid):
        return None
    fields = line[closing_parenthesis + 1 :].split()
    if len(fields) < 20 or len(fields[0]) != 1 or not fields[19].isdigit():
        return None
    process_state = fields[0]
    identity = f"linux:{boot_id.lower()}:{fields[19]}"
    if process_state in {"Z", "X", "x"}:
        return {"health": "dead", "identity": identity, "diagnostic": None}
    if process_state not in {"R", "S", "D", "T", "t", "W", "I", "P"}:
        return {"health": "unverifiable", "identity": None, "diagnostic": None}
    return {"health": "live", "identity": identity, "diagnostic": None}


class ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


def darwin_process_probe(pid):
    if sys.platform != "darwin" or "DX_SESSION_RUNTIME_PROC_ROOT" in os.environ:
        return None
    library_name = ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib"
    try:
        library = ctypes.CDLL(library_name, use_errno=True)
        proc_pidinfo = library.proc_pidinfo
        proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        proc_pidinfo.restype = ctypes.c_int
        process_info = ProcBSDInfo()
        result = proc_pidinfo(
            pid,
            3,
            0,
            ctypes.byref(process_info),
            ctypes.sizeof(process_info),
        )
    except (AttributeError, OSError, ValueError):
        return None
    if result != ctypes.sizeof(process_info) or process_info.pbi_pid != pid:
        return None
    identity = f"darwin:{process_info.pbi_start_tvsec}:{process_info.pbi_start_tvusec}"
    if process_info.pbi_status == 5:
        return {"health": "dead", "identity": identity, "diagnostic": None}
    if process_info.pbi_status in {1, 2, 3, 4}:
        return {"health": "live", "identity": identity, "diagnostic": None}
    return {"health": "unverifiable", "identity": None, "diagnostic": None}


def ps_diagnostic(pid):
    ps_binary = os.environ.get("DX_SESSION_RUNTIME_PS_BIN", "ps")
    if not ps_binary or "\x00" in ps_binary:
        return None
    child_env = os.environ.copy()
    child_env["LC_ALL"] = "C"
    child_env["LANG"] = "C"
    child_env["TZ"] = "UTC"
    try:
        completed = subprocess.run(
            [ps_binary, "-o", "lstart=", "-p", str(pid)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=child_env,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0 or len(completed.stdout) > MAX_PROC_BYTES:
        return None
    try:
        normalized = " ".join(completed.stdout.decode("utf-8").split())
    except UnicodeDecodeError:
        return None
    if not valid_text(normalized, 128):
        return None
    return f"ps:{normalized}"


def process_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except ProcessLookupError:
        return False
    except (OverflowError, ValueError):
        return False
    except OSError as exc:
        return exc.errno == errno.EPERM


def process_probe(pid, include_diagnostic=False):
    if not process_exists(pid):
        return {"health": "dead", "identity": None, "diagnostic": None}
    stable_probe = linux_process_probe(pid)
    if stable_probe is None:
        stable_probe = darwin_process_probe(pid)
    if stable_probe is not None:
        return stable_probe
    diagnostic = ps_diagnostic(pid) if include_diagnostic else None
    return {"health": "unverifiable", "identity": None, "diagnostic": diagnostic}


def owner_health(record, expected_token=None, expected_pid=None):
    if expected_token is not None and record["token"] != expected_token:
        return "dead"
    if expected_pid is not None and record["pid"] != expected_pid:
        return "dead"
    if record["status"] != ACTIVE_STATE:
        return "dead"
    probe = process_probe(record["pid"])
    if probe["health"] != "live":
        return probe["health"]
    if probe["identity"] != record["process_start"]:
        return "dead"
    return "live"


def token_from_fd():
    try:
        payload = os.read(3, 130)
    except OSError:
        raise RuntimeInputError("runtime lease token was not provided securely")
    if len(payload) > 129:
        raise RuntimeInputError("runtime lease token is invalid")
    if payload.endswith(b"\r\n"):
        payload = payload[:-2]
    elif payload.endswith(b"\n"):
        payload = payload[:-1]
    if b"\n" in payload or b"\r" in payload:
        raise RuntimeInputError("runtime lease token is invalid")
    try:
        token = payload.decode("ascii")
    except UnicodeDecodeError:
        raise RuntimeInputError("runtime lease token is invalid")
    return token


def recovery_snapshot_from_fd(descriptor):
    chunks = []
    remaining = MAX_RECORD_BYTES + 1
    try:
        while remaining > 0:
            chunk = os.read(descriptor, min(remaining, 4096))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
    except OSError as exc:
        raise RuntimeInputError(
            f"runtime recovery snapshot was not provided securely: {exc}"
        )
    payload = b"".join(chunks)
    if not payload or len(payload) > MAX_RECORD_BYTES:
        raise RuntimeInputError("runtime recovery snapshot size is invalid")
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RuntimeInputError(f"runtime recovery snapshot is invalid: {exc}")


def validated_public_record(record_file, session_id, missing_ok=False):
    record = trusted_read(record_file, session_id, missing_ok=missing_ok)
    if record is None:
        return None
    require_record_lock(record, trusted_lock_identity(f"{record_file}-lock"))
    return record


operation = sys.argv[1]
arguments = sys.argv[2:]
try:
    if operation == "identity":
        if len(arguments) != 1:
            raise RuntimeInputError("identity requires one PID")
        owner_pid = parse_pid(arguments[0])
        probe = process_probe(owner_pid, include_diagnostic=True)
        if probe["health"] == "live":
            print(probe["identity"])
        elif probe["diagnostic"]:
            print(probe["diagnostic"])
        else:
            raise SystemExit(1)
    elif operation == "owner-process-state":
        if len(arguments) != 2:
            raise RuntimeInputError(
                "owner-process-state requires one PID and one stable identity"
            )
        owner_pid = parse_pid(arguments[0])
        expected_identity = arguments[1]
        if not (
            LINUX_ID_RE.fullmatch(expected_identity)
            or DARWIN_ID_RE.fullmatch(expected_identity)
        ):
            raise RuntimeInputError("runtime owner process identity is invalid")
        owner_probe = process_probe(owner_pid)
        if owner_probe["health"] == "dead":
            print("dead")
        elif owner_probe["health"] != "live" or owner_probe["identity"] is None:
            print("unverifiable")
        elif owner_probe["identity"] == expected_identity:
            print("live")
        else:
            print("replaced")
    elif operation == "owner-runtime-correlation":
        if len(arguments) != 4:
            raise RuntimeInputError(
                "owner-runtime-correlation requires file, session, PID, and identity"
            )
        record_file, session_id, raw_pid, expected_identity = arguments
        if not SESSION_RE.fullmatch(session_id):
            raise RuntimeInputError("invalid session ID")
        owner_pid = parse_pid(raw_pid)
        if not (
            LINUX_ID_RE.fullmatch(expected_identity)
            or DARWIN_ID_RE.fullmatch(expected_identity)
        ):
            raise RuntimeInputError("runtime owner process identity is invalid")
        record = validated_public_record(record_file, session_id)
        if record["pid"] != owner_pid or record["process_start"] != expected_identity:
            fail("runtime record does not identify this supervisor", 2)
        print(f'{record["status"]}\t{owner_health(record)}')
    elif operation == "owner-metadata":
        if len(arguments) != 2:
            raise RuntimeInputError("owner-metadata requires root and owner directory")
        metadata_values = owner_directory_metadata(arguments[0], arguments[1])
        print("\t".join(str(value) for value in metadata_values))
    elif operation == "owner-read":
        if len(arguments) != 8:
            raise RuntimeInputError("owner-read received the wrong number of arguments")
        (
            owner_root,
            owner_directory,
            raw_root_device,
            raw_root_inode,
            raw_owner_device,
            raw_owner_inode,
            file_name,
            raw_maximum_bytes,
        ) = arguments
        root_device = parse_file_id(raw_root_device, "runtime owner root device")
        root_inode = parse_file_id(raw_root_inode, "runtime owner root inode", 1)
        owner_device = parse_file_id(raw_owner_device, "runtime owner device")
        owner_inode = parse_file_id(raw_owner_inode, "runtime owner inode", 1)
        maximum_bytes = parse_file_id(raw_maximum_bytes, "runtime owner read size", 1)
        if maximum_bytes > 4096:
            raise RuntimeInputError("runtime owner read size is too large")
        payload = trusted_owner_file_read(
            owner_root,
            owner_directory,
            root_device,
            root_inode,
            owner_device,
            owner_inode,
            file_name,
            maximum_bytes,
        )
        sys.stdout.buffer.write(payload)
    elif operation == "owner-write":
        if len(arguments) != 9:
            raise RuntimeInputError("owner-write received the wrong number of arguments")
        (
            owner_root,
            owner_directory,
            raw_root_device,
            raw_root_inode,
            raw_owner_device,
            raw_owner_inode,
            file_name,
            replace_marker,
            content,
        ) = arguments
        root_device = parse_file_id(raw_root_device, "runtime owner root device")
        root_inode = parse_file_id(raw_root_inode, "runtime owner root inode", 1)
        owner_device = parse_file_id(raw_owner_device, "runtime owner device")
        owner_inode = parse_file_id(raw_owner_inode, "runtime owner inode", 1)
        if replace_marker not in {"replace", "create"}:
            raise RuntimeInputError("runtime owner write mode is invalid")
        trusted_owner_file_write(
            owner_root,
            owner_directory,
            root_device,
            root_inode,
            owner_device,
            owner_inode,
            file_name,
            replace_marker == "replace",
            content,
        )
    elif operation == "owner-cleanup":
        if len(arguments) != 6:
            raise RuntimeInputError("owner-cleanup received the wrong number of arguments")
        owner_root, owner_directory = arguments[:2]
        root_device = parse_file_id(arguments[2], "runtime owner root device")
        root_inode = parse_file_id(arguments[3], "runtime owner root inode", 1)
        owner_device = parse_file_id(arguments[4], "runtime owner device")
        owner_inode = parse_file_id(arguments[5], "runtime owner inode", 1)
        trusted_owner_cleanup(
            owner_root,
            owner_directory,
            root_device,
            root_inode,
            owner_device,
            owner_inode,
        )
    elif operation == "recovery-context":
        if len(arguments) != 1:
            raise RuntimeInputError(
                "recovery-context requires a session"
            )
        session_id = arguments[0]
        if not SESSION_RE.fullmatch(session_id):
            raise RuntimeInputError("invalid session ID")
        raw_snapshot = recovery_snapshot_from_fd(3)
        recovery_snapshot = validate_public_snapshot(raw_snapshot, session_id)
        print(f'{recovery_snapshot["provider"]}\t{recovery_snapshot["workspace"]}')
    elif operation == "recover-start-secure":
        if len(arguments) != 3:
            raise RuntimeInputError(
                "recover-start-secure requires file, session, and PID"
            )
        record_file, session_id, raw_pid = arguments
        if not SESSION_RE.fullmatch(session_id):
            raise RuntimeInputError("invalid session ID")
        raw_snapshot = recovery_snapshot_from_fd(4)
        expected_snapshot = validate_public_snapshot(raw_snapshot, session_id)
        owner_pid = parse_pid(raw_pid)
        lock_descriptor, lock_file, held_identity = acquire_mutation_lock(record_file)
        lease_token = None
        try:
            previous = trusted_read(record_file, session_id, missing_ok=True)
            if previous is None:
                fail("runtime record is required for recovery", 2)
            require_record_lock(previous, held_identity)
            if public_record(previous) != expected_snapshot:
                fail("runtime record changed before recovery", 2)
            if owner_health(previous) != "dead":
                fail("another process may still own this session", 2)
            owner_probe = process_probe(owner_pid)
            if owner_probe["health"] != "live" or owner_probe["identity"] is None:
                raise RuntimeInputError("cannot establish a stable runtime process identity")
            now_epoch = max(int(time.time()), previous["heartbeat_at"])
            lease_token = secrets.token_hex(32)
            record = {
                "schema_version": SCHEMA_VERSION,
                "session_id": session_id,
                "token": lease_token,
                "pid": owner_pid,
                "process_start": owner_probe["identity"],
                "provider": previous["provider"],
                "workspace": previous["workspace"],
                "started_at": now_epoch,
                "heartbeat_at": now_epoch,
                "finished_at": None,
                "status": ACTIVE_STATE,
                "lock_generation": held_identity["generation"],
                "lock_device": held_identity["device"],
                "lock_inode": held_identity["inode"],
            }
            publish_record(
                lock_descriptor, lock_file, held_identity, record_file, record, session_id
            )
            token_payload = (lease_token + "\n").encode("ascii")
            token_offset = 0
            try:
                while token_offset < len(token_payload):
                    written = os.write(3, token_payload[token_offset:])
                    if written <= 0:
                        raise OSError("token pipe closed")
                    token_offset += written
            except OSError as exc:
                try:
                    publish_record(
                        lock_descriptor,
                        lock_file,
                        held_identity,
                        record_file,
                        previous,
                        session_id,
                    )
                except RuntimeRecordError as rollback_error:
                    raise RuntimeRecordError(
                        "cannot restore the previous runtime record after token "
                        f"delivery failed: {rollback_error}"
                    )
                raise RuntimeInputError(
                    f"cannot deliver runtime lease token securely: {exc}"
                )
        finally:
            release_mutation_lock(lock_descriptor)
    elif operation in {"start", "start-secure"}:
        if len(arguments) != 5:
            raise RuntimeInputError("start requires file, session, provider, workspace, and PID")
        record_file, session_id, provider, workspace, raw_pid = arguments
        if not SESSION_RE.fullmatch(session_id):
            raise RuntimeInputError("invalid session ID")
        if not PROVIDER_RE.fullmatch(provider):
            raise RuntimeInputError("invalid provider")
        if not valid_text(workspace, 4096) or not os.path.isabs(workspace):
            raise RuntimeInputError("workspace must be an absolute path")
        owner_pid = parse_pid(raw_pid)
        lock_descriptor, lock_file, held_identity = acquire_mutation_lock(record_file)
        lease_token = None
        try:
            previous = trusted_read(record_file, session_id, missing_ok=True)
            if previous is not None:
                require_record_lock(previous, held_identity)
                if previous["status"] == ACTIVE_STATE:
                    previous_health = owner_health(previous)
                    if previous_health in {"live", "unverifiable"}:
                        fail("another process may still own this session", 2)
            owner_probe = process_probe(owner_pid)
            if owner_probe["health"] != "live" or owner_probe["identity"] is None:
                raise RuntimeInputError("cannot establish a stable runtime process identity")
            now_epoch = int(time.time())
            lease_token = secrets.token_hex(32)
            record = {
                "schema_version": SCHEMA_VERSION,
                "session_id": session_id,
                "token": lease_token,
                "pid": owner_pid,
                "process_start": owner_probe["identity"],
                "provider": provider,
                "workspace": workspace,
                "started_at": now_epoch,
                "heartbeat_at": now_epoch,
                "finished_at": None,
                "status": ACTIVE_STATE,
                "lock_generation": held_identity["generation"],
                "lock_device": held_identity["device"],
                "lock_inode": held_identity["inode"],
            }
            publish_record(
                lock_descriptor, lock_file, held_identity, record_file, record, session_id
            )
        finally:
            release_mutation_lock(lock_descriptor)
        if operation == "start-secure":
            token_payload = (lease_token + "\n").encode("ascii")
            token_offset = 0
            try:
                while token_offset < len(token_payload):
                    written = os.write(3, token_payload[token_offset:])
                    if written <= 0:
                        raise OSError("token pipe closed")
                    token_offset += written
            except OSError as exc:
                raise RuntimeInputError(
                    f"cannot deliver runtime lease token securely: {exc}"
                )
        else:
            print(lease_token)
    elif operation == "purge":
        if len(arguments) != 3:
            raise RuntimeInputError("purge requires file, session, and PID")
        record_file, session_id, raw_pid = arguments
        if not SESSION_RE.fullmatch(session_id):
            raise RuntimeInputError("invalid session ID")
        owner_pid = parse_pid(raw_pid)
        lease_token = token_from_fd()
        if not TOKEN_RE.fullmatch(lease_token):
            fail("runtime lease owner did not match", 2)
        lock_descriptor, lock_file, held_identity = acquire_mutation_lock(record_file)
        try:
            record = trusted_read(record_file, session_id)
            require_record_lock(record, held_identity)
            if owner_health(record, lease_token, owner_pid) != "live":
                fail("runtime lease owner did not match", 2)
            trusted_purge_record(
                lock_descriptor,
                lock_file,
                held_identity,
                record_file,
                record,
                session_id,
            )
        finally:
            release_mutation_lock(lock_descriptor)
    elif operation in {"heartbeat", "finish"}:
        expected_count = 3 if operation == "heartbeat" else 4
        if len(arguments) != expected_count:
            raise RuntimeInputError(f"{operation} received the wrong number of arguments")
        record_file, session_id, raw_pid = arguments[:3]
        owner_pid = parse_pid(raw_pid)
        lease_token = token_from_fd()
        if not TOKEN_RE.fullmatch(lease_token):
            fail("runtime lease owner did not match", 2)
        terminal_state = None
        if operation == "finish":
            terminal_state = arguments[3]
            if terminal_state not in TERMINAL_STATES:
                raise RuntimeInputError("invalid terminal runtime status")
        lock_descriptor, lock_file, held_identity = acquire_mutation_lock(record_file)
        try:
            record = trusted_read(record_file, session_id)
            require_record_lock(record, held_identity)
            if owner_health(record, lease_token, owner_pid) != "live":
                fail("runtime lease owner did not match", 2)
            now_epoch = max(int(time.time()), record["heartbeat_at"])
            record["heartbeat_at"] = now_epoch
            if operation == "finish":
                record["status"] = terminal_state
                record["finished_at"] = now_epoch
            publish_record(
                lock_descriptor, lock_file, held_identity, record_file, record, session_id
            )
        finally:
            release_mutation_lock(lock_descriptor)
    elif operation in {"read", "field", "health"}:
        expected_count = 2 if operation == "read" else 3
        if len(arguments) != expected_count:
            raise RuntimeInputError(f"{operation} received the wrong number of arguments")
        record_file, session_id = arguments[:2]
        try:
            record = validated_public_record(
                record_file, session_id, missing_ok=(operation == "health")
            )
        except RuntimeRecordError:
            if operation == "health":
                print("corrupt")
                raise SystemExit(0)
            raise
        if record is None:
            print("legacy-unverifiable")
        elif operation == "read":
            public_record = dict(record)
            del public_record["token"]
            print(json.dumps(public_record, sort_keys=True, separators=(",", ":")))
        elif operation == "field":
            field_name = arguments[2]
            if field_name not in PUBLIC_FIELDS:
                raise RuntimeInputError("unknown or private runtime field")
            field_value = record[field_name]
            if field_value is not None:
                print(field_value)
        else:
            has_token = arguments[2]
            if has_token not in {"0", "1"}:
                raise RuntimeInputError("invalid runtime health token marker")
            expected_token = token_from_fd() if has_token == "1" else None
            if expected_token is not None and not TOKEN_RE.fullmatch(expected_token):
                print("dead")
            else:
                print(owner_health(record, expected_token))
    else:
        raise RuntimeInputError("unknown runtime operation")
except FileNotFoundError:
    raise SystemExit(1)
except RuntimeInputError as exc:
    fail(str(exc), 3)
except RuntimeRecordError as exc:
    fail(str(exc), 3)
PY
}

# dx_session_runtime_process_identity <pid>
# Print the stable process identity used in runtime records. A ps value is only diagnostic.
dx_session_runtime_process_identity() {
  [[ $# -eq 1 ]] || return 3
  __dx_session_runtime_call identity "$1"
}

# dx_session_runtime_start <session_id> <provider> <workspace> [pid]
# Start a new lease and print its token. A live or unverifiable lease cannot be replaced.
dx_session_runtime_start() {
  [[ $# -ge 3 && $# -le 4 ]] || return 3
  local session_id="$1" provider_name="$2" workspace_dir="$3" owner_pid="${4:-$$}"
  local record_file
  record_file=$(dx_session_runtime_file "$session_id") || return $?
  __dx_session_runtime_call start "$record_file" "$session_id" "$provider_name" "$workspace_dir" "$owner_pid"
}

# Internal supervisor entrypoint. FD 3 must be a private pipe owned by the
# supervisor; this path deliberately keeps the lease token off stdout.
__dx_session_runtime_start_secure() {
  [[ $# -eq 4 ]] || return 3
  local session_id="$1" provider_name="$2" workspace_dir="$3" owner_pid="$4"
  local record_file
  record_file=$(dx_session_runtime_file "$session_id") || return $?
  __dx_session_runtime_call start-secure \
    "$record_file" "$session_id" "$provider_name" "$workspace_dir" "$owner_pid"
}

# Recovery starts from a validated public snapshot and writes the new token only
# to FD 3. It can reclaim a missing workspace because the trusted runtime record,
# rather than new caller input, supplies that exact path.
__dx_session_runtime_recovery_start_secure() {
  [[ $# -eq 3 ]] || return 3
  local session_id="$1" owner_pid="$3" record_file
  record_file=$(dx_session_runtime_file "$session_id") || return $?
  __dx_session_runtime_call recover-start-secure \
    "$record_file" "$session_id" "$owner_pid" 4<<<"$2"
}

__dx_session_runtime_recovery_context() {
  [[ $# -eq 2 ]] || return 3
  __dx_session_runtime_call recovery-context "$1" 3<<<"$2"
}

# dx_session_runtime_heartbeat <session_id> <token> [pid]
dx_session_runtime_heartbeat() {
  [[ $# -ge 2 && $# -le 3 ]] || return 3
  local session_id="$1" owner_pid="${3:-$$}" record_file
  record_file=$(dx_session_runtime_file "$session_id") || return $?
  __dx_session_runtime_call heartbeat "$record_file" "$session_id" "$owner_pid" 3<<<"$2"
}

# dx_session_runtime_finish <session_id> <token> <terminal_status> [pid]
dx_session_runtime_finish() {
  [[ $# -ge 3 && $# -le 4 ]] || return 3
  local session_id="$1" terminal_state="$3" owner_pid="${4:-$$}"
  local record_file
  record_file=$(dx_session_runtime_file "$session_id") || return $?
  __dx_session_runtime_call finish "$record_file" "$session_id" "$owner_pid" "$terminal_state" 3<<<"$2"
}

# Token-authenticated runtime removal for the private owner process. The
# persistent mutation lock stays in place so a future lifecycle cannot bypass
# the same serialized ownership boundary.
__dx_session_runtime_purge() {
  [[ $# -ge 2 && $# -le 3 ]] || return 3
  local session_id="$1" owner_pid="${3:-$$}" record_file
  record_file=$(dx_session_runtime_file "$session_id") || return $?
  __dx_session_runtime_call purge \
    "$record_file" "$session_id" "$owner_pid" 3<<<"$2"
}

# dx_session_runtime_read <session_id> - print validated compact JSON without its private token.
dx_session_runtime_read() {
  [[ $# -eq 1 ]] || return 3
  local session_id="$1" record_file
  record_file=$(dx_session_runtime_file "$session_id") || return $?
  __dx_session_runtime_call read "$record_file" "$session_id"
}

# dx_session_runtime_field <session_id> <field>
dx_session_runtime_field() {
  [[ $# -eq 2 ]] || return 3
  local session_id="$1" field_name="$2" record_file
  record_file=$(dx_session_runtime_file "$session_id") || return $?
  __dx_session_runtime_call field "$record_file" "$session_id" "$field_name"
}

# dx_session_runtime_health <session_id> [token]
# Health is live, dead, unverifiable, corrupt, or legacy-unverifiable.
dx_session_runtime_health() {
  [[ $# -ge 1 && $# -le 2 ]] || return 3
  local session_id="$1" record_file
  record_file=$(dx_session_runtime_file "$session_id") || return $?
  if [[ $# -eq 2 ]]; then
    __dx_session_runtime_call health "$record_file" "$session_id" 1 3<<<"$2"
  else
    __dx_session_runtime_call health "$record_file" "$session_id" 0
  fi
}

# dx_session_runtime_matches <session_id> <token> - true only for the live owner.
dx_session_runtime_matches() {
  [[ $# -eq 2 ]] || return 3
  local health_value
  health_value=$(dx_session_runtime_health "$1" "$2" 2>/dev/null) || return $?
  [[ "$health_value" == "live" ]]
}

dx_session_runtime_owner_root() {
  printf '%s/.runtime-owners\n' "$DX_STATE_DIR"
}

__dx_session_runtime_owner_timeout() { # <environment-name> <default-ms>
  local environment_name="$1" default_milliseconds="$2" timeout_milliseconds
  timeout_milliseconds=$(printenv "$environment_name" 2>/dev/null || true)
  [[ -n "$timeout_milliseconds" ]] || timeout_milliseconds="$default_milliseconds"
  case "$timeout_milliseconds" in
    ""|*[!0-9]*) return 3 ;;
  esac
  [[ "$timeout_milliseconds" -ge 50 && "$timeout_milliseconds" -le 60000 ]] || return 3
  printf '%s\n' "$timeout_milliseconds"
}

__dx_session_runtime_owner_process_matches() { # <pid> <stable-identity>
  [[ $# -eq 2 && "$1" =~ ^[0-9]+$ ]] || return 1
  [[ "$(__dx_session_runtime_owner_process_state "$1" "$2" 2>/dev/null || true)" == "live" ]]
}

__dx_session_runtime_owner_process_state() { # <pid> <stable-identity>
  [[ $# -eq 2 && "$1" =~ ^[0-9]+$ ]] || return 3
  __dx_session_runtime_call owner-process-state "$1" "$2"
}

__dx_session_runtime_owner_runtime_correlation() { # <session> <pid> <stable-identity>
  [[ $# -eq 3 ]] || return 3
  local record_file
  record_file=$(dx_session_runtime_file "$1") || return $?
  __dx_session_runtime_call owner-runtime-correlation \
    "$record_file" "$1" "$2" "$3"
}

__dx_session_runtime_owner_reap_if_dead() { # <pid> <stable-identity>
  [[ $# -eq 2 ]] || return 3
  local process_state
  process_state=$(__dx_session_runtime_owner_process_state "$1" "$2" \
    2>/dev/null) || return 3
  [[ "$process_state" == "dead" ]] || return 1
  wait "$1" 2>/dev/null || true
}

__dx_session_runtime_owner_stop_process() { # <pid> <stable-identity>
  [[ $# -eq 2 ]] || return 3
  local owner_pid="$1" owner_identity="$2" elapsed_milliseconds=0
  __dx_session_runtime_owner_process_matches "$owner_pid" "$owner_identity" || return 0
  if __dx_session_runtime_owner_process_matches "$owner_pid" "$owner_identity"; then
    kill -CONT "$owner_pid" 2>/dev/null || true
  fi
  __dx_session_runtime_owner_process_matches "$owner_pid" "$owner_identity" || return 0
  if __dx_session_runtime_owner_process_matches "$owner_pid" "$owner_identity"; then
    kill -TERM "$owner_pid" 2>/dev/null || true
  fi
  while __dx_session_runtime_owner_process_matches "$owner_pid" "$owner_identity" \
    && [[ "$elapsed_milliseconds" -lt 1000 ]]; do
    sleep 0.05
    elapsed_milliseconds=$((elapsed_milliseconds + 50))
  done
  if __dx_session_runtime_owner_process_matches "$owner_pid" "$owner_identity"; then
    if __dx_session_runtime_owner_process_matches "$owner_pid" "$owner_identity"; then
      kill -KILL "$owner_pid" 2>/dev/null || true
    fi
    elapsed_milliseconds=0
    while __dx_session_runtime_owner_process_matches "$owner_pid" "$owner_identity" \
      && [[ "$elapsed_milliseconds" -lt 1000 ]]; do
      sleep 0.05
      elapsed_milliseconds=$((elapsed_milliseconds + 50))
    done
  fi
  ! __dx_session_runtime_owner_process_matches "$owner_pid" "$owner_identity"
}

__dx_session_runtime_owner_abort() { # <opaque-handle> <pid> <stable-identity>
  [[ $# -eq 3 ]] || return 3
  local owner_handle="$1" owner_pid="$2" owner_identity="$3"
  __dx_session_runtime_owner_stop_process "$owner_pid" "$owner_identity" \
    2>/dev/null || true
  __dx_session_runtime_owner_reap_if_dead "$owner_pid" "$owner_identity" \
    2>/dev/null || return 75
  __dx_session_runtime_owner_cleanup "$owner_handle" 2>/dev/null || return 3
}

__dx_session_runtime_owner_descriptor_clear() {
  unset __DX_RUNTIME_OWNER_DIRECTORY __DX_RUNTIME_OWNER_SESSION
  unset __DX_RUNTIME_OWNER_PID __DX_RUNTIME_OWNER_PROCESS_IDENTITY
  unset __DX_RUNTIME_OWNER_GENERATION __DX_RUNTIME_OWNER_ROOT_DEVICE
  unset __DX_RUNTIME_OWNER_ROOT_INODE __DX_RUNTIME_OWNER_DEVICE
  unset __DX_RUNTIME_OWNER_INODE
}

__dx_session_runtime_owner_descriptor_parse() { # <opaque-handle>
  local owner_descriptor="$1" descriptor_version descriptor_extra
  __dx_session_runtime_owner_descriptor_clear
  IFS=$'\t' read -r \
    descriptor_version \
    __DX_RUNTIME_OWNER_DIRECTORY \
    __DX_RUNTIME_OWNER_SESSION \
    __DX_RUNTIME_OWNER_PID \
    __DX_RUNTIME_OWNER_PROCESS_IDENTITY \
    __DX_RUNTIME_OWNER_GENERATION \
    __DX_RUNTIME_OWNER_ROOT_DEVICE \
    __DX_RUNTIME_OWNER_ROOT_INODE \
    __DX_RUNTIME_OWNER_DEVICE \
    __DX_RUNTIME_OWNER_INODE \
    descriptor_extra <<EOF
$owner_descriptor
EOF
  [[ "$descriptor_version" == "v1" && -z "${descriptor_extra:-}" ]] || return 3
  [[ "$__DX_RUNTIME_OWNER_DIRECTORY" == /* \
    && "$__DX_RUNTIME_OWNER_DIRECTORY" != *$'\n'* \
    && "$__DX_RUNTIME_OWNER_DIRECTORY" != *$'\r'* ]] || return 3
  dx_session_id_valid "$__DX_RUNTIME_OWNER_SESSION" || return 3
  [[ "$__DX_RUNTIME_OWNER_PID" =~ ^[0-9]+$ ]] || return 3
  case "$__DX_RUNTIME_OWNER_PROCESS_IDENTITY" in
    linux:*|darwin:*) ;;
    *) return 3 ;;
  esac
  [[ "$__DX_RUNTIME_OWNER_GENERATION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$ \
    && "${__DX_RUNTIME_OWNER_DIRECTORY##*/}" == "$__DX_RUNTIME_OWNER_GENERATION" ]] \
    || return 3
  [[ "$__DX_RUNTIME_OWNER_ROOT_DEVICE" =~ ^[0-9]+$ \
    && "$__DX_RUNTIME_OWNER_ROOT_INODE" =~ ^[0-9]+$ \
    && "$__DX_RUNTIME_OWNER_DEVICE" =~ ^[0-9]+$ \
    && "$__DX_RUNTIME_OWNER_INODE" =~ ^[0-9]+$ ]] || return 3
}

dx_session_runtime_owner_handle_path() { # <opaque-handle>
  [[ $# -eq 1 ]] || return 3
  local owner_directory
  __dx_session_runtime_owner_descriptor_parse "$1" || return $?
  owner_directory="$__DX_RUNTIME_OWNER_DIRECTORY"
  __dx_session_runtime_owner_descriptor_clear
  printf '%s\n' "$owner_directory"
}

__dx_session_runtime_owner_metadata() { # <root> <directory>
  [[ $# -eq 2 ]] || return 3
  __dx_session_runtime_call owner-metadata "$1" "$2"
}

__dx_session_runtime_owner_trusted_read_path() { # <root> <directory> <root-dev> <root-ino> <owner-dev> <owner-ino> <file> <max>
  [[ $# -eq 8 ]] || return 3
  __dx_session_runtime_call owner-read "$@"
}

__dx_session_runtime_owner_trusted_write_path() { # <root> <directory> <root-dev> <root-ino> <owner-dev> <owner-ino> <file> <mode> <content>
  [[ $# -eq 9 ]] || return 3
  __dx_session_runtime_call owner-write "$@"
}

__dx_session_runtime_owner_trusted_cleanup_path() { # <root> <directory> <root-dev> <root-ino> <owner-dev> <owner-ino>
  [[ $# -eq 6 ]] || return 3
  __dx_session_runtime_call owner-cleanup "$@"
}

__dx_session_runtime_owner_trusted_read() { # <opaque-handle> <file> <max>
  [[ $# -eq 3 ]] || return 3
  local owner_descriptor="$1" file_name="$2" maximum_bytes="$3"
  local owner_root owner_directory root_device root_inode owner_device owner_inode
  owner_root=$(dx_session_runtime_owner_root) || return 3
  __dx_session_runtime_owner_descriptor_parse "$owner_descriptor" || return $?
  owner_directory="$__DX_RUNTIME_OWNER_DIRECTORY"
  root_device="$__DX_RUNTIME_OWNER_ROOT_DEVICE"
  root_inode="$__DX_RUNTIME_OWNER_ROOT_INODE"
  owner_device="$__DX_RUNTIME_OWNER_DEVICE"
  owner_inode="$__DX_RUNTIME_OWNER_INODE"
  __dx_session_runtime_owner_descriptor_clear
  __dx_session_runtime_owner_trusted_read_path \
    "$owner_root" "$owner_directory" "$root_device" "$root_inode" \
    "$owner_device" "$owner_inode" "$file_name" "$maximum_bytes"
}

__dx_session_runtime_owner_handle_valid() {
  [[ $# -eq 1 ]] || return 3
  local metadata_record metadata_extra root_device root_inode owner_device owner_inode
  local owner_root owner_directory expected_root_device expected_root_inode
  local expected_owner_device expected_owner_inode
  owner_root=$(dx_session_runtime_owner_root) || return 3
  __dx_session_runtime_owner_descriptor_parse "$1" || return $?
  owner_directory="$__DX_RUNTIME_OWNER_DIRECTORY"
  expected_root_device="$__DX_RUNTIME_OWNER_ROOT_DEVICE"
  expected_root_inode="$__DX_RUNTIME_OWNER_ROOT_INODE"
  expected_owner_device="$__DX_RUNTIME_OWNER_DEVICE"
  expected_owner_inode="$__DX_RUNTIME_OWNER_INODE"
  __dx_session_runtime_owner_descriptor_clear
  metadata_record=$(__dx_session_runtime_owner_metadata \
    "$owner_root" "$owner_directory" 2>/dev/null) || return 3
  IFS=$'\t' read -r root_device root_inode owner_device owner_inode metadata_extra <<EOF
$metadata_record
EOF
  [[ -z "${metadata_extra:-}" \
    && "$root_device" == "$expected_root_device" \
    && "$root_inode" == "$expected_root_inode" \
    && "$owner_device" == "$expected_owner_device" \
    && "$owner_inode" == "$expected_owner_inode" ]]
}

__dx_session_runtime_owner_atomic_write() { # <handle> <file-name> <content>
  local owner_descriptor="$1" file_name="$2" file_content="$3"
  local owner_root owner_directory root_device root_inode owner_device owner_inode
  owner_root=$(dx_session_runtime_owner_root) || return 3
  case "$file_name" in
    command) ;;
    *) return 3 ;;
  esac
  __dx_session_runtime_owner_descriptor_parse "$owner_descriptor" || return $?
  owner_directory="$__DX_RUNTIME_OWNER_DIRECTORY"
  root_device="$__DX_RUNTIME_OWNER_ROOT_DEVICE"
  root_inode="$__DX_RUNTIME_OWNER_ROOT_INODE"
  owner_device="$__DX_RUNTIME_OWNER_DEVICE"
  owner_inode="$__DX_RUNTIME_OWNER_INODE"
  __dx_session_runtime_owner_descriptor_clear
  __dx_session_runtime_owner_trusted_write_path \
    "$owner_root" "$owner_directory" "$root_device" "$root_inode" \
    "$owner_device" "$owner_inode" command replace "$file_content"
}

__dx_session_runtime_owner_result_path() { # <root> <directory> <root-dev> <root-ino> <owner-dev> <owner-ino>
  [[ $# -eq 6 ]] || return 3
  local result_record
  [[ -e "$2/result" || -L "$2/result" ]] || return 1
  result_record=$(__dx_session_runtime_owner_trusted_read_path \
    "$@" result 512 2>/dev/null) || return $?
  [[ "$result_record" =~ ^[0-9]+$'\t'[A-Za-z0-9._-]+$'\t'(completed|paused|blocked|failed|stopped|abandoned|purged)$'\t'[A-Za-z0-9._-]+$ ]] \
    || return 3
  printf '%s\n' "$result_record"
}

__dx_session_runtime_owner_result() { # <opaque-handle>
  local owner_descriptor="$1" owner_root owner_directory
  local root_device root_inode owner_device owner_inode
  owner_root=$(dx_session_runtime_owner_root) || return 3
  __dx_session_runtime_owner_descriptor_parse "$owner_descriptor" || return $?
  owner_directory="$__DX_RUNTIME_OWNER_DIRECTORY"
  root_device="$__DX_RUNTIME_OWNER_ROOT_DEVICE"
  root_inode="$__DX_RUNTIME_OWNER_ROOT_INODE"
  owner_device="$__DX_RUNTIME_OWNER_DEVICE"
  owner_inode="$__DX_RUNTIME_OWNER_INODE"
  __dx_session_runtime_owner_descriptor_clear
  __dx_session_runtime_owner_result_path \
    "$owner_root" "$owner_directory" "$root_device" "$root_inode" \
    "$owner_device" "$owner_inode"
}

__dx_session_runtime_owner_cleanup() {
  local owner_descriptor="$1" owner_root owner_directory
  local root_device root_inode owner_device owner_inode
  owner_root=$(dx_session_runtime_owner_root) || return 3
  __dx_session_runtime_owner_descriptor_parse "$owner_descriptor" || return $?
  owner_directory="$__DX_RUNTIME_OWNER_DIRECTORY"
  root_device="$__DX_RUNTIME_OWNER_ROOT_DEVICE"
  root_inode="$__DX_RUNTIME_OWNER_ROOT_INODE"
  owner_device="$__DX_RUNTIME_OWNER_DEVICE"
  owner_inode="$__DX_RUNTIME_OWNER_INODE"
  __dx_session_runtime_owner_descriptor_clear
  __dx_session_runtime_owner_trusted_cleanup_path \
    "$owner_root" "$owner_directory" "$root_device" "$root_inode" \
    "$owner_device" "$owner_inode"
}

# Start a private supervisor as this shell's direct child. The recovery mode
# gets its exact, token-free runtime snapshot over FD 3 instead of argv.
__dx_session_runtime_owner_start_internal() {
  [[ $# -eq 5 ]] || return 3
  unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
  local session_id="$1" provider_name="$2" workspace_dir="$3" monitor_pid="$$"
  local start_mode="$4" recovery_context recovery_extra
  local monitor_identity owner_root owner_directory owner_generation owner_pid owner_identity
  local observed_owner_identity owner_process_state
  local start_timeout elapsed_milliseconds=0 metadata_record metadata_extra
  local root_device root_inode owner_device owner_inode result_record result_code
  local ready_record ready_label ready_pid ready_session ready_identity ready_generation ready_extra
  local runtime_pid runtime_identity runtime_provider runtime_workspace runtime_state runtime_health
  local failure_request cleanup_allowed=0
  dx_session_id_valid "$session_id" || return 3
  [[ "$provider_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 3
  case "$start_mode" in
    start)
      [[ -z "$5" && "$workspace_dir" == /* \
        && -d "$workspace_dir" ]] || return 3
      workspace_dir=$(cd "$workspace_dir" 2>/dev/null && pwd -P) || return 3
      ;;
    recover)
      recovery_context=$(__dx_session_runtime_recovery_context \
        "$session_id" "$5" 2>/dev/null) || return 3
      IFS=$'\t' read -r provider_name workspace_dir recovery_extra <<EOF
$recovery_context
EOF
      [[ -z "${recovery_extra:-}" && "$workspace_dir" == /* ]] || return 3
      ;;
    *) return 3 ;;
  esac
  monitor_identity=$(dx_session_runtime_process_identity "$monitor_pid" 2>/dev/null || true)
  case "$monitor_identity" in
    linux:*|darwin:*) ;;
    *)
      printf '%s\n' "dex runtime owner: cannot establish the launcher's stable process identity" >&2
      return 3
      ;;
  esac
  start_timeout=$(__dx_session_runtime_owner_timeout \
    DX_SESSION_RUNTIME_OWNER_START_TIMEOUT_MILLISECONDS 5000) || return $?
  owner_root=$(dx_session_runtime_owner_root) || return 3
  if [[ -e "$owner_root" || -L "$owner_root" ]]; then
    [[ -d "$owner_root" && ! -L "$owner_root" ]] || return 3
  else
    (umask 077 && mkdir -p "$owner_root") || return 3
  fi
  chmod 700 "$owner_root" 2>/dev/null || return 3
  [[ "$(dx_path_mode "$owner_root" 2>/dev/null || true)" == "700" ]] || return 3
  owner_directory=$(mktemp -d "$owner_root/${session_id}.XXXXXX") || return 3
  chmod 700 "$owner_directory" 2>/dev/null || {
    rmdir "$owner_directory" 2>/dev/null || true
    return 3
  }
  owner_generation="${owner_directory##*/}"
  metadata_record=$(__dx_session_runtime_owner_metadata \
    "$owner_root" "$owner_directory" 2>/dev/null) || {
    rmdir "$owner_directory" 2>/dev/null || true
    return 3
  }
  IFS=$'\t' read -r root_device root_inode owner_device owner_inode metadata_extra <<EOF
$metadata_record
EOF
  if [[ -n "${metadata_extra:-}" || ! "$root_device" =~ ^[0-9]+$ \
    || ! "$root_inode" =~ ^[0-9]+$ || ! "$owner_device" =~ ^[0-9]+$ \
    || ! "$owner_inode" =~ ^[0-9]+$ ]]; then
    rmdir "$owner_directory" 2>/dev/null || true
    return 3
  fi
  command bash "$DEX_DIR/bin/session-runtime-owner.sh" \
    "$session_id" "$provider_name" "$workspace_dir" "$monitor_pid" \
    "$monitor_identity" "$owner_directory" "$root_device" "$root_inode" \
    "$owner_device" "$owner_inode" "$start_mode" \
    3<<<"$5" \
    > "$owner_directory/output" 2> "$owner_directory/error" &
  owner_pid=$!
  chmod 600 "$owner_directory/output" "$owner_directory/error" 2>/dev/null || true
  owner_identity=$(dx_session_runtime_process_identity "$owner_pid" 2>/dev/null || true)

  while [[ "$elapsed_milliseconds" -lt "$start_timeout" ]]; do
    ready_record=""
    if [[ -e "$owner_directory/ready" || -L "$owner_directory/ready" ]]; then
      ready_record=$(__dx_session_runtime_owner_trusted_read_path \
        "$owner_root" "$owner_directory" "$root_device" "$root_inode" \
        "$owner_device" "$owner_inode" ready 512 2>/dev/null || true)
    fi
    if [[ -n "$ready_record" ]]; then
      IFS=$'\t' read -r ready_label ready_pid ready_session ready_identity \
        ready_generation ready_extra <<EOF
$ready_record
EOF
      observed_owner_identity=$(dx_session_runtime_process_identity \
        "$owner_pid" 2>/dev/null || true)
      if [[ "$ready_label" == "ready" && "$ready_pid" == "$owner_pid" \
        && "$ready_session" == "$session_id" && "$ready_identity" == "$owner_identity" \
        && "$observed_owner_identity" == "$owner_identity" \
        && "$ready_generation" == "$owner_generation" && -z "${ready_extra:-}" ]]; then
        runtime_pid=$(dx_session_runtime_field "$session_id" pid 2>/dev/null || true)
        runtime_identity=$(dx_session_runtime_field "$session_id" process_start 2>/dev/null || true)
        runtime_provider=$(dx_session_runtime_field "$session_id" provider 2>/dev/null || true)
        runtime_workspace=$(dx_session_runtime_field "$session_id" workspace 2>/dev/null || true)
        runtime_state=$(dx_session_runtime_field "$session_id" status 2>/dev/null || true)
        runtime_health=$(dx_session_runtime_health "$session_id" 2>/dev/null || true)
        if [[ "$runtime_pid" == "$owner_pid" && "$runtime_identity" == "$owner_identity" \
          && "$runtime_provider" == "$provider_name" \
          && "$runtime_workspace" == "$workspace_dir" && "$runtime_state" == "running" \
          && "$runtime_health" == "live" ]]; then
          # These are out-parameters for callers in both bash and zsh.
          # shellcheck disable=SC2034
          DX_SESSION_RUNTIME_OWNER_HANDLE=$(printf \
            'v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
            "$owner_directory" "$session_id" "$owner_pid" "$owner_identity" \
            "$owner_generation" "$root_device" "$root_inode" \
            "$owner_device" "$owner_inode")
          # shellcheck disable=SC2034
          DX_SESSION_RUNTIME_OWNER_PID="$owner_pid"
          return 0
        fi
      fi
      break
    fi
    result_record=$(__dx_session_runtime_owner_result_path \
      "$owner_root" "$owner_directory" "$root_device" "$root_inode" \
      "$owner_device" "$owner_inode" 2>/dev/null || true)
    if [[ -n "$result_record" ]] || ! kill -0 "$owner_pid" 2>/dev/null; then
      break
    fi
    sleep 0.05
    elapsed_milliseconds=$((elapsed_milliseconds + 50))
  done

  result_record=$(__dx_session_runtime_owner_result_path \
    "$owner_root" "$owner_directory" "$root_device" "$root_inode" \
    "$owner_device" "$owner_inode" 2>/dev/null || true)
  result_code="${result_record%%$'\t'*}"
  [[ "$result_code" =~ ^[0-9]+$ ]] || result_code=3
  if [[ "$result_code" -eq 2 ]]; then
    printf '%s\n' "dex runtime: another process may still own this session" >&2
  else
    printf '%s\n' "dex runtime owner: supervisor did not start" >&2
  fi
  if kill -0 "$owner_pid" 2>/dev/null; then
    failure_request=$(printf '%s\t%s' "$owner_generation" failed)
    __dx_session_runtime_owner_trusted_write_path \
      "$owner_root" "$owner_directory" "$root_device" "$root_inode" \
      "$owner_device" "$owner_inode" command replace \
      "$failure_request" 2>/dev/null || true
    case "$owner_identity" in
      linux:*|darwin:*)
        __dx_session_runtime_owner_stop_process "$owner_pid" "$owner_identity" \
          2>/dev/null || true
        owner_process_state=$(__dx_session_runtime_owner_process_state \
          "$owner_pid" "$owner_identity" 2>/dev/null || true)
        if [[ "$owner_process_state" == "dead" ]]; then
          __dx_session_runtime_owner_reap_if_dead \
            "$owner_pid" "$owner_identity" 2>/dev/null || true
          cleanup_allowed=1
        fi
        ;;
    esac
  else
    case "$owner_identity" in
      linux:*|darwin:*)
        if __dx_session_runtime_owner_reap_if_dead \
            "$owner_pid" "$owner_identity" 2>/dev/null; then
          cleanup_allowed=1
        fi
        ;;
    esac
  fi
  if [[ "$cleanup_allowed" -eq 1 ]]; then
    __dx_session_runtime_owner_trusted_cleanup_path \
      "$owner_root" "$owner_directory" "$root_device" "$root_inode" \
      "$owner_device" "$owner_inode" 2>/dev/null || true
  fi
  return "$result_code"
}

# dx_session_runtime_owner_start <session_id> <provider> <workspace>
# On success, the non-exported DX_SESSION_RUNTIME_OWNER_HANDLE and
# DX_SESSION_RUNTIME_OWNER_PID globals identify the supervisor. Its lease token
# never leaves that process.
dx_session_runtime_owner_start() {
  [[ $# -eq 3 ]] || return 3
  __dx_session_runtime_owner_start_internal "$1" "$2" "$3" start ""
}

# Recovery uses the exact public record selected by the caller. The supervisor
# owns the new lease before this function reports success, including when the
# recorded workspace no longer exists.
__dx_session_runtime_owner_recovery_start() {
  [[ $# -eq 2 ]] || return 3
  __dx_session_runtime_owner_start_internal "$1" "recovery" "/" recover "$2"
}

# Ask the supervisor for one correlated terminal action and wait within the
# configured bound. `purged` is private to structural session cleanup.
__dx_session_runtime_owner_settle() {
  [[ $# -eq 2 ]] || return 3
  local owner_handle="$1" terminal_state="$2" finish_timeout elapsed_milliseconds=0
  local owner_directory owner_session owner_pid owner_identity owner_generation
  local root_device root_inode owner_device owner_inode
  local ready_record ready_label ready_pid ready_session ready_identity ready_generation ready_extra
  local result_record="" result_read_result=0 result_code=3 result_generation
  local result_terminal result_detail result_extra owner_wait_result=0
  local runtime_pid runtime_identity runtime_state runtime_health final_result=0 command_request
  local owner_error owner_process_state cleanup_allowed=0 correlation_record correlation_extra
  case "$terminal_state" in
    completed|paused|blocked|failed|stopped|abandoned|purged) ;;
    *) return 3 ;;
  esac
  finish_timeout=$(__dx_session_runtime_owner_timeout \
    DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS 5000) || return $?
  __dx_session_runtime_owner_descriptor_parse "$owner_handle" || return $?
  owner_directory="$__DX_RUNTIME_OWNER_DIRECTORY"
  owner_session="$__DX_RUNTIME_OWNER_SESSION"
  owner_pid="$__DX_RUNTIME_OWNER_PID"
  owner_identity="$__DX_RUNTIME_OWNER_PROCESS_IDENTITY"
  owner_generation="$__DX_RUNTIME_OWNER_GENERATION"
  root_device="$__DX_RUNTIME_OWNER_ROOT_DEVICE"
  root_inode="$__DX_RUNTIME_OWNER_ROOT_INODE"
  owner_device="$__DX_RUNTIME_OWNER_DEVICE"
  owner_inode="$__DX_RUNTIME_OWNER_INODE"
  __dx_session_runtime_owner_descriptor_clear

  ready_record=$(__dx_session_runtime_owner_trusted_read \
    "$owner_handle" ready 512 2>/dev/null) || return 3
  IFS=$'\t' read -r ready_label ready_pid ready_session ready_identity \
    ready_generation ready_extra <<EOF
$ready_record
EOF
  if [[ "$ready_label" != "ready" || "$ready_pid" != "$owner_pid" \
    || "$ready_session" != "$owner_session" || "$ready_identity" != "$owner_identity" \
    || "$ready_generation" != "$owner_generation" || -n "${ready_extra:-}" ]]; then
    return 3
  fi

  correlation_record=$(__dx_session_runtime_owner_runtime_correlation \
    "$owner_session" "$owner_pid" "$owner_identity" 2>/dev/null) || return 3
  IFS=$'\t' read -r runtime_state runtime_health correlation_extra <<EOF
$correlation_record
EOF
  [[ -z "${correlation_extra:-}" ]] || return 3

  result_record=$(__dx_session_runtime_owner_result "$owner_handle" 2>/dev/null) \
    || result_read_result=$?
  if [[ "$result_read_result" -eq 1 ]]; then
    [[ "$runtime_state" == "running" && "$runtime_health" == "live" ]] \
      || return 3
    result_record=""
    command_request=$(printf '%s\t%s' "$owner_generation" "$terminal_state")
    if ! __dx_session_runtime_owner_atomic_write \
        "$owner_handle" command "$command_request"; then
      __dx_session_runtime_owner_abort \
        "$owner_handle" "$owner_pid" "$owner_identity" 2>/dev/null || true
      return 3
    fi
  elif [[ "$result_read_result" -ne 0 ]]; then
    __dx_session_runtime_owner_abort \
      "$owner_handle" "$owner_pid" "$owner_identity" 2>/dev/null || true
    return 3
  fi

  while [[ -z "$result_record" && "$elapsed_milliseconds" -lt "$finish_timeout" ]]; do
    result_read_result=0
    result_record=$(__dx_session_runtime_owner_result "$owner_handle" 2>/dev/null) \
      || result_read_result=$?
    if [[ "$result_read_result" -eq 0 && -n "$result_record" ]]; then
      break
    fi
    if [[ "$result_read_result" -ne 1 ]]; then
      final_result=3
      break
    fi
    sleep 0.05
    elapsed_milliseconds=$((elapsed_milliseconds + 50))
  done

  if [[ -z "$result_record" ]]; then
    if [[ "$final_result" -eq 0 ]]; then
      final_result=75
      printf '%s\n' "dex runtime owner: supervisor did not finish within the bounded wait" >&2
    fi
    __dx_session_runtime_owner_stop_process "$owner_pid" "$owner_identity" \
      2>/dev/null || true
    owner_error=$(__dx_session_runtime_owner_trusted_read \
      "$owner_handle" error 4096 2>/dev/null || true)
    case "$owner_error" in
      "dex runtime:"*) printf '%s\n' "$owner_error" >&2 ;;
    esac
  else
    IFS=$'\t' read -r result_code result_generation result_terminal \
      result_detail result_extra <<EOF
$result_record
EOF
    if [[ ! "$result_code" =~ ^[0-9]+$ || "$result_code" -gt 255 \
      || "$result_generation" != "$owner_generation" \
      || "$result_terminal" != "$terminal_state" || -z "$result_detail" \
      || -n "${result_extra:-}" ]]; then
      final_result=3
    elif [[ "$result_code" -ne 0 ]]; then
      final_result="$result_code"
    fi

    while __dx_session_runtime_owner_process_matches "$owner_pid" "$owner_identity" \
      && [[ "$elapsed_milliseconds" -lt "$finish_timeout" ]]; do
      sleep 0.05
      elapsed_milliseconds=$((elapsed_milliseconds + 50))
    done
    if __dx_session_runtime_owner_process_matches "$owner_pid" "$owner_identity"; then
      final_result=75
      __dx_session_runtime_owner_stop_process "$owner_pid" "$owner_identity" \
        2>/dev/null || true
    fi
  fi

  owner_process_state=$(__dx_session_runtime_owner_process_state \
    "$owner_pid" "$owner_identity" 2>/dev/null || true)
  if [[ "$owner_process_state" == "live" ]]; then
    [[ "$final_result" -ne 0 ]] || final_result=75
    __dx_session_runtime_owner_stop_process "$owner_pid" "$owner_identity" \
      2>/dev/null || true
    owner_process_state=$(__dx_session_runtime_owner_process_state \
      "$owner_pid" "$owner_identity" 2>/dev/null || true)
  fi
  if [[ "$owner_process_state" == "dead" ]]; then
    wait "$owner_pid" 2>/dev/null || owner_wait_result=$?
    cleanup_allowed=1
  else
    owner_wait_result=75
  fi
  if [[ "$owner_wait_result" -ne 0 && "$final_result" -eq 0 ]]; then
    final_result="$owner_wait_result"
  fi

  runtime_health=$(dx_session_runtime_health "$owner_session" 2>/dev/null || true)
  if [[ "$terminal_state" == "purged" ]]; then
    if [[ -e "$(dx_session_runtime_file "$owner_session")" \
      || -L "$(dx_session_runtime_file "$owner_session")" \
      || "$runtime_health" != "legacy-unverifiable" ]]; then
      [[ "$final_result" -ne 0 ]] || final_result=3
    fi
  else
    runtime_pid=$(dx_session_runtime_field "$owner_session" pid 2>/dev/null || true)
    runtime_identity=$(dx_session_runtime_field "$owner_session" process_start 2>/dev/null || true)
    runtime_state=$(dx_session_runtime_field "$owner_session" status 2>/dev/null || true)
    if [[ "$runtime_pid" != "$owner_pid" || "$runtime_identity" != "$owner_identity" \
      || "$runtime_state" != "$terminal_state" || "$runtime_health" != "dead" ]]; then
      [[ "$final_result" -ne 0 ]] || final_result=3
    fi
  fi
  if [[ "$cleanup_allowed" -eq 1 ]]; then
    __dx_session_runtime_owner_cleanup "$owner_handle" 2>/dev/null || {
      [[ "$final_result" -ne 0 ]] || final_result=3
    }
  fi
  return "$final_result"
}

# dx_session_runtime_owner_finish <handle> <terminal_status>
# Request a terminal record and wait for the supervisor within a bounded time.
dx_session_runtime_owner_finish() {
  [[ $# -eq 2 ]] || return 3
  case "$2" in
    completed|paused|blocked|failed|stopped|abandoned) ;;
    *) return 3 ;;
  esac
  __dx_session_runtime_owner_settle "$1" "$2"
}

# Remove a recovery-owned runtime record without exposing its lease token.
__dx_session_runtime_owner_purge() {
  [[ $# -eq 1 ]] || return 3
  __dx_session_runtime_owner_settle "$1" purged
}

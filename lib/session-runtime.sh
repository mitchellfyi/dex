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
    elif operation == "start":
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
        print(lease_token)
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

# dx_session_runtime_heartbeat <session_id> <token> [pid]
dx_session_runtime_heartbeat() {
  [[ $# -ge 2 && $# -le 3 ]] || return 3
  local session_id="$1" lease_token="$2" owner_pid="${3:-$$}" record_file
  record_file=$(dx_session_runtime_file "$session_id") || return $?
  __dx_session_runtime_call heartbeat "$record_file" "$session_id" "$owner_pid" 3<<<"$lease_token"
}

# dx_session_runtime_finish <session_id> <token> <terminal_status> [pid]
dx_session_runtime_finish() {
  [[ $# -ge 3 && $# -le 4 ]] || return 3
  local session_id="$1" lease_token="$2" terminal_state="$3" owner_pid="${4:-$$}"
  local record_file
  record_file=$(dx_session_runtime_file "$session_id") || return $?
  __dx_session_runtime_call finish "$record_file" "$session_id" "$owner_pid" "$terminal_state" 3<<<"$lease_token"
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
  local session_id="$1" lease_token="${2:-}" record_file
  record_file=$(dx_session_runtime_file "$session_id") || return $?
  if [[ $# -eq 2 ]]; then
    __dx_session_runtime_call health "$record_file" "$session_id" 1 3<<<"$lease_token"
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

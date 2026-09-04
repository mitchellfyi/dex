# shellcheck shell=bash
# Dex shared library - read-only lifecycle session inventory.

__dx_session_catalog_repo_context() {
  local requested_repo="${1:-${PWD:-.}}" repo_root repo_key repo_keys listed_line
  local repo_common_dir listed_dir legacy_root legacy_name legacy_slug legacy_hash legacy_key
  local candidate_root candidate_common_dir
  repo_root=$(cd "$requested_repo" 2>/dev/null && dx_session_repo_root) || return 3
  repo_common_dir=$(cd "$requested_repo" 2>/dev/null \
    && __dx_session_canonical_git_dir git-common-dir) || return 3
  case "$repo_root" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 3 ;;
  esac
  repo_key=$(cd "$repo_root" 2>/dev/null && dx_session_repo_key) || return 3
  repo_keys="$repo_key"
  while IFS= read -r listed_line; do
    case "$listed_line" in
      "worktree "*) listed_dir="${listed_line#worktree }" ;;
      *) continue ;;
    esac
    listed_dir=$(cd "$listed_dir" 2>/dev/null && pwd -P) || continue
    case "$listed_dir" in
      *$'\n'*|*$'\r'*|*$'\t'*) continue ;;
    esac
    legacy_root="$listed_dir"
    case "$legacy_root" in
      */.dex/worktrees/*)
        candidate_root="${legacy_root%%/.dex/worktrees/*}"
        candidate_common_dir=$(cd "$candidate_root" 2>/dev/null \
          && __dx_session_canonical_git_dir git-common-dir) || candidate_common_dir=""
        if [[ "$candidate_common_dir" == "$repo_common_dir" ]]; then
          legacy_root="$candidate_root"
        fi
        ;;
    esac
    legacy_name=$(basename "$legacy_root")
    legacy_slug=$(printf '%s' "$legacy_name" | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')
    [[ -n "$legacy_slug" ]] || legacy_slug="repo"
    legacy_hash=$(printf '%s' "$legacy_root" | cksum 2>/dev/null | awk '{print $1}') || continue
    legacy_key="repo-${legacy_slug}-${legacy_hash}"
    case ",${repo_keys}," in
      *",${legacy_key},"*) ;;
      *) repo_keys="${repo_keys},${legacy_key}" ;;
    esac
  done <<EOF
$(git -C "$requested_repo" worktree list --porcelain 2>/dev/null)
EOF
  printf '%s\t%s\n' "$repo_keys" "$repo_root"
}

__dx_session_catalog_call() {
  local operation="$1" repo_keys="$2" repo_root="$3" include_children="$4"
  local selector_value="${5:-}" dex_runtime_dir="${DEX_DIR:-}"
  python3 - "$operation" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$repo_keys" "$repo_root" \
    "$include_children" "$selector_value" "$dex_runtime_dir" <<'PY'
import ctypes
import ctypes.util
import errno
import json
import os
import re
import stat
import subprocess
import sys
import time


(
    operation,
    state_dir,
    loop_dir,
    repo_keys_raw,
    repo_root,
    include_raw,
    selector,
    dex_runtime_dir,
) = sys.argv[1:]
repo_keys = repo_keys_raw.split(",")
repo_key = repo_keys[0] if repo_keys else ""
include_children = include_raw == "1"
SESSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$")
CHILD_RE = re.compile(
    r"^(.*)-(pass|assessment|review)-"
    r"([0-9a-f]{32}|[0-9]{8}T[0-9]{6}Z_[0-9]+_[0-9a-f]{8}|[0-9]+-[0-9]+-[0-9]+)$"
)
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
TERMINAL_STATES = {"completed", "paused", "blocked", "failed", "stopped", "abandoned"}
RUNTIME_FIELDS = {
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
MAX_RUNTIME_BYTES = 16 * 1024
MAX_STATE_BYTES = 64 * 1024
MAX_PID = 2_147_483_647
MAX_TIMESTAMP = 9_223_372_036_854_775_807
MAX_FILE_ID = 18_446_744_073_709_551_615
MAX_PROC_BYTES = 4096
READ_ATTEMPTS = 8
READ_RETRY_SECONDS = 0.005
LOCK_PREFIX = b"dex-runtime-lock-v1 "
TERMINAL_PROOF_RE = re.compile(
    rb"version=1\nphase=7\n"
    rb"transition_token=[0-9]+-[0-9]+-[0-9]+\n"
    rb"authority=(?:[0-9a-f]{32}|[0-9]+-[0-9]+-[0-9]+)\n"
)
REVIEW_RECEIPT_RE = re.compile(
    rb"6\t(?:small\tlight|normal\tstandard|complex\tthorough)\t"
    rb"([1-9][0-9]{0,14})\t\1\t[0-9a-f]{64}\t[0-9a-f]{64}\t"
    rb"(?:standalone|[0-9a-f]{64})\t[0-9a-f]{64}\t(?:-|[0-9a-f]{64})\n"
)

EXACT_SUFFIXES = [
    (".cleanup-journal", "cleanup-journal"),
    (".claude-session", "claude-session"),
    (".codex-session", "codex-session"),
    (".review-receipt.revoked", "review-receipt-revoked"),
    (".review-criteria-approval", "review-criteria-approval"),
    (".review-selection.revoked", "review-selection-revoked"),
    (".completion-expectation", "completion-expectation"),
    (".review-criteria.json", "review-criteria"),
    (".review-evidence.json", "review-evidence"),
    (".phase-outcomes", "phase-outcomes"),
    (".review-selection", "review-selection"),
    (".review-context", "review-context"),
    (".review-receipt", "review-receipt"),
    (".review-result", "review-result"),
    (".review-ledger", "review-ledger"),
    (".review-proofs", "review-proofs"),
    (".complete-state", "complete-state"),
    (".system-context", "system-context"),
    (".handoff-mode", "handoff-mode"),
    (".pause-state", "pause-state"),
    (".watch-pause", "watch-pause"),
    (".human-complete", "human-complete"),
    (".terminal-commit", "terminal-commit"),
    (".interventions", "interventions"),
    (".completion-lock", "completion-lock"),
    (".runtime-lock", "runtime-lock"),
    (".control-lock", "control-lock"),
    (".review-state", "review-state"),
    (".run-id", "run-id"),
    (".runtime", "runtime"),
    (".provider", "provider"),
    (".findings", "findings"),
    (".complete", "complete"),
    (".control", "control"),
    (".branch", "branch"),
    (".prompt", "prompt"),
    (".paused", "paused"),
    (".active", "active"),
    (".times", "times"),
    (".phase", "phase"),
    (".state", "loop-state"),
    (".meta", "meta"),
    (".debt", "debt"),
    (".owner", "owner"),
    (".config", "config"),
    (".log", "log"),
]
PHASE_MARKER_RE = re.compile(
    r"^(.*)\.phase-(?:[0-7]|prompt-loop)\."
    r"(started|ready|busy|busy-notice|busy-cancel|busy-quiesced)$"
)
WATCH_LOCK_RE = re.compile(r"^(.*)\.(ci|pr)\.watch-lock$")
COMPLETION_RECEIPT_RE = re.compile(r"^(.*)\.completion-receipt\.[0-9a-f]{32}$")


class CatalogInputError(Exception):
    pass


class UnsafeStateError(Exception):
    pass


class TransientReadError(Exception):
    pass


def emit_error(message, return_code):
    print(f"dex sessions: {message}", file=sys.stderr)
    raise SystemExit(return_code)


def valid_text(value, max_length):
    return (
        isinstance(value, str)
        and 0 < len(value) <= max_length
        and not any(ord(character) < 32 or ord(character) == 127 for character in value)
    )


def fingerprint(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        getattr(metadata, "st_mtime_ns", int(metadata.st_mtime * 1_000_000_000)),
    )


def exact_int(value, minimum=0, maximum=MAX_TIMESTAMP):
    return type(value) is int and minimum <= value <= maximum


def validate_trusted_regular(metadata, exact_mode=None):
    if not stat.S_ISREG(metadata.st_mode):
        raise UnsafeStateError("not a regular file")
    if metadata.st_nlink != 1:
        raise UnsafeStateError("does not have exactly one link")
    if metadata.st_uid != os.geteuid():
        raise UnsafeStateError("owned by another user")
    permission_bits = stat.S_IMODE(metadata.st_mode)
    if exact_mode is not None:
        if permission_bits != exact_mode:
            raise UnsafeStateError(f"mode is not {exact_mode:04o}")
    elif permission_bits & 0o022:
        raise UnsafeStateError("writable by another user")


def trusted_read(target_file, max_bytes, exact_mode=None, return_metadata=False):
    transient_error = None
    for attempt in range(READ_ATTEMPTS):
        descriptor = None
        try:
            before = os.lstat(target_file)
            validate_trusted_regular(before, exact_mode)
            if before.st_size <= 0 or before.st_size > max_bytes:
                raise UnsafeStateError("size is invalid")
            open_flags = os.O_RDONLY
            open_flags |= getattr(os, "O_CLOEXEC", 0)
            open_flags |= getattr(os, "O_NOFOLLOW", 0)
            open_flags |= getattr(os, "O_NONBLOCK", 0)
            try:
                descriptor = os.open(target_file, open_flags)
            except FileNotFoundError as exc:
                raise TransientReadError(str(exc))
            except OSError as exc:
                if exc.errno in (errno.ENOENT, errno.ESTALE):
                    raise TransientReadError(str(exc))
                raise UnsafeStateError(str(exc))
            opened = os.fstat(descriptor)
            if fingerprint(opened) != fingerprint(before):
                raise TransientReadError("changed while opening")
            chunks = []
            remaining = max_bytes + 1
            while remaining > 0:
                chunk = os.read(descriptor, min(remaining, 4096))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            payload = b"".join(chunks)
            after = os.fstat(descriptor)
            if fingerprint(after) != fingerprint(opened):
                raise TransientReadError("changed while reading")
            try:
                named = os.lstat(target_file)
            except FileNotFoundError as exc:
                raise TransientReadError(str(exc))
            if fingerprint(named) != fingerprint(after):
                raise TransientReadError("path changed while reading")
            if len(payload) > max_bytes:
                raise UnsafeStateError("too large")
            if return_metadata:
                return payload, opened
            return payload
        except FileNotFoundError:
            raise
        except TransientReadError as exc:
            transient_error = exc
        finally:
            if descriptor is not None:
                os.close(descriptor)
        if attempt + 1 < READ_ATTEMPTS:
            time.sleep(READ_RETRY_SECONDS)
    raise UnsafeStateError(f"changed repeatedly: {transient_error}")


def trusted_private_inode(target_file, exact_mode):
    transient_error = None
    for attempt in range(READ_ATTEMPTS):
        descriptor = None
        try:
            before = os.lstat(target_file)
            validate_trusted_regular(before, exact_mode)
            open_flags = os.O_RDONLY
            open_flags |= getattr(os, "O_CLOEXEC", 0)
            open_flags |= getattr(os, "O_NOFOLLOW", 0)
            open_flags |= getattr(os, "O_NONBLOCK", 0)
            try:
                descriptor = os.open(target_file, open_flags)
            except FileNotFoundError as exc:
                raise TransientReadError(str(exc))
            except OSError as exc:
                if exc.errno in (errno.ENOENT, errno.ESTALE):
                    raise TransientReadError(str(exc))
                raise UnsafeStateError(str(exc))
            opened = os.fstat(descriptor)
            if fingerprint(opened) != fingerprint(before):
                raise TransientReadError("changed while opening")
            try:
                named = os.lstat(target_file)
            except FileNotFoundError as exc:
                raise TransientReadError(str(exc))
            if fingerprint(named) != fingerprint(opened):
                raise TransientReadError("path changed while inspecting")
            return opened
        except FileNotFoundError:
            raise
        except TransientReadError as exc:
            transient_error = exc
        finally:
            if descriptor is not None:
                os.close(descriptor)
        if attempt + 1 < READ_ATTEMPTS:
            time.sleep(READ_RETRY_SECONDS)
    raise UnsafeStateError(f"changed repeatedly: {transient_error}")


def trusted_runtime_lock_identity(lock_file):
    payload, metadata = trusted_read(
        lock_file, 128, exact_mode=0o600, return_metadata=True
    )
    expected_length = len(LOCK_PREFIX) + 32 + 1
    if (
        len(payload) != expected_length
        or not payload.startswith(LOCK_PREFIX)
        or not payload.endswith(b"\n")
    ):
        raise UnsafeStateError("runtime lock identity is invalid")
    try:
        generation = payload[len(LOCK_PREFIX) : -1].decode("ascii")
    except UnicodeDecodeError:
        raise UnsafeStateError("runtime lock identity is invalid")
    if not LOCK_GENERATION_RE.fullmatch(generation):
        raise UnsafeStateError("runtime lock identity is invalid")
    return {
        "generation": generation,
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
    }


def artifact_owner(name):
    for suffix, family in EXACT_SUFFIXES:
        if name.endswith(suffix):
            session_id = name[: -len(suffix)]
            if SESSION_RE.fullmatch(session_id):
                return session_id, family
            return None
    phase_marker = PHASE_MARKER_RE.fullmatch(name)
    if phase_marker and SESSION_RE.fullmatch(phase_marker.group(1)):
        return phase_marker.group(1), f"phase-{phase_marker.group(2)}"
    watch_lock = WATCH_LOCK_RE.fullmatch(name)
    if watch_lock and SESSION_RE.fullmatch(watch_lock.group(1)):
        return watch_lock.group(1), f"{watch_lock.group(2)}-watch-lock"
    completion_receipt = COMPLETION_RECEIPT_RE.fullmatch(name)
    if completion_receipt and SESSION_RE.fullmatch(completion_receipt.group(1)):
        return completion_receipt.group(1), "completion-receipt"
    return None


def artifact_is_unsafe(entry, family, location):
    if family == "cleanup-journal":
        if location != "loop":
            return True
        try:
            payload = trusted_read(entry.path, 1024 * 1024, exact_mode=0o600)
        except (FileNotFoundError, UnsafeStateError, OSError, ValueError):
            return True
        session_id = entry.name[: -len(".cleanup-journal")]
        header = f"dex-cleanup-journal-v1\t{session_id}\n".encode("ascii")
        return not payload.startswith(header) or len(payload) == len(header)
    if family == "completion-lock":
        if location != "loop":
            return True
        try:
            trusted_private_inode(entry.path, 0o600)
        except (FileNotFoundError, UnsafeStateError, OSError, ValueError):
            return True
        return False
    if family == "runtime-lock":
        if location != "state":
            return True
        try:
            trusted_runtime_lock_identity(entry.path)
        except (FileNotFoundError, UnsafeStateError, OSError, ValueError):
            return True
        return False
    try:
        metadata = entry.stat(follow_symlinks=False)
    except (OSError, ValueError):
        return True
    if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) & 0o022:
        return True
    directory_families = {"review-proofs", "control-lock"}
    if family in directory_families:
        return not stat.S_ISDIR(metadata.st_mode)
    return not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1


def scan_artifacts():
    grouped = {}
    repo_prefixes = tuple(
        (f"{candidate_key}-", candidate_key)
        for candidate_key in sorted(repo_keys, key=len, reverse=True)
    )
    for location, directory in (("state", state_dir), ("loop", loop_dir)):
        try:
            entries = list(os.scandir(directory))
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise CatalogInputError(f"cannot read {location} state directory: {exc}")
        for entry in entries:
            resolved = artifact_owner(entry.name)
            if resolved is None:
                continue
            session_id, family = resolved
            matched_repo_key = next(
                (
                    candidate_key
                    for candidate_prefix, candidate_key in repo_prefixes
                    if session_id.startswith(candidate_prefix)
                ),
                None,
            )
            if matched_repo_key is None:
                continue
            item = grouped.setdefault(
                session_id,
                {
                    "families": set(),
                    "locations": {},
                    "unsafe": set(),
                    "matched_repo_key": matched_repo_key,
                },
            )
            item["families"].add(family)
            item["locations"].setdefault(family, set()).add(location)
            if artifact_is_unsafe(entry, family, location):
                item["unsafe"].add(family)
    return grouped


def parse_metadata(session_id, families):
    if "meta" not in families:
        return {}, "missing"
    meta_file = os.path.join(state_dir, f"{session_id}.meta")
    try:
        payload = trusted_read(meta_file, MAX_STATE_BYTES)
        text = payload.decode("utf-8")
    except (FileNotFoundError, UnsafeStateError, UnicodeDecodeError):
        return {}, "corrupt"
    wanted = {
        "ticket_number",
        "wt_name",
        "wt_dir",
        "workspace_mode",
        "created_at",
        "updated_at",
        "session_role",
        "parent_session_id",
        "child_kind",
    }
    values = {}
    for raw_line in text.splitlines():
        if not raw_line or "=" not in raw_line:
            continue
        field_name, field_value = raw_line.split("=", 1)
        if field_name not in wanted:
            continue
        if field_name in values:
            return {}, "corrupt"
        values[field_name] = field_value
    ticket = values.get("ticket_number")
    workspace_name = values.get("wt_name")
    workspace = values.get("wt_dir")
    workspace_mode = values.get("workspace_mode")
    session_role = values.get("session_role")
    parent_session_id = values.get("parent_session_id")
    child_kind = values.get("child_kind")
    if ticket is not None and (
        not valid_text(ticket, 128) or not re.fullmatch(r"[A-Za-z0-9._-]+", ticket)
    ):
        return {}, "corrupt"
    if workspace_name is not None and not valid_text(workspace_name, 255):
        return {}, "corrupt"
    if workspace is not None and (
        not valid_text(workspace, 4096) or not os.path.isabs(workspace)
    ):
        return {}, "corrupt"
    if workspace_mode is not None and workspace_mode not in {"worktree", "in-place"}:
        return {}, "corrupt"
    child_fields = (session_role, parent_session_id, child_kind)
    if any(field_value is not None for field_value in child_fields):
        if (
            session_role != "review-child"
            or not isinstance(parent_session_id, str)
            or not SESSION_RE.fullmatch(parent_session_id)
            or child_kind not in {"pass", "assessment", "review"}
        ):
            return {}, "corrupt"
    timestamps = {}
    for field_name in ("created_at", "updated_at"):
        raw_value = values.get(field_name)
        if raw_value is None:
            continue
        if not raw_value.isdigit() or len(raw_value) > 19:
            return {}, "corrupt"
        parsed_value = int(raw_value)
        if parsed_value <= 0 or parsed_value > MAX_TIMESTAMP:
            return {}, "corrupt"
        timestamps[field_name] = parsed_value
    return {
        "ticket": ticket,
        "workspace_name": workspace_name,
        "workspace": workspace,
        "workspace_mode": workspace_mode,
        "session_role": session_role,
        "parent_session_id": parent_session_id,
        "child_kind": child_kind,
        **timestamps,
    }, "valid"


def parse_phase(session_id, families):
    if "phase" not in families:
        return None
    phase_file = os.path.join(state_dir, f"{session_id}.phase")
    try:
        raw_phase = trusted_read(phase_file, 64, exact_mode=0o600).decode("ascii").strip()
    except (FileNotFoundError, UnsafeStateError, UnicodeDecodeError):
        return None
    if not re.fullmatch(r"[0-7]", raw_phase):
        return None
    return int(raw_phase)


def parse_provider(session_id, families):
    if "provider" not in families:
        return None
    provider_file = os.path.join(loop_dir, f"{session_id}.provider")
    try:
        text = trusted_read(provider_file, 16 * 1024).decode("utf-8")
    except (FileNotFoundError, UnsafeStateError, UnicodeDecodeError):
        return None
    values = {}
    for raw_line in text.splitlines():
        if "=" not in raw_line:
            continue
        field_name, field_value = raw_line.split("=", 1)
        if field_name in {"engine", "session"} and field_name not in values:
            values[field_name] = field_value
    engine = values.get("engine")
    if values.get("session") != session_id or not isinstance(engine, str):
        return None
    if not PROVIDER_RE.fullmatch(engine):
        return None
    return engine


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
    opening_parenthesis = line.find("(")
    closing_parenthesis = line.rfind(")")
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
        return {"health": "dead", "identity": identity}
    if process_state not in {"R", "S", "D", "T", "t", "W", "I", "P"}:
        return {"health": "unverifiable", "identity": None}
    return {"health": "live", "identity": identity}


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
        return {"health": "dead", "identity": identity}
    if process_info.pbi_status in {1, 2, 3, 4}:
        return {"health": "live", "identity": identity}
    return {"health": "unverifiable", "identity": None}


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


def process_probe(pid):
    if not process_exists(pid):
        return {"health": "dead", "identity": None}
    stable_probe = linux_process_probe(pid)
    if stable_probe is None:
        stable_probe = darwin_process_probe(pid)
    if stable_probe is not None:
        return stable_probe
    return {"health": "unverifiable", "identity": None}


def no_duplicate_keys(pairs):
    result = {}
    for field_name, field_value in pairs:
        if field_name in result:
            raise UnsafeStateError("duplicate runtime field")
        result[field_name] = field_value
    return result


def validate_runtime(record, session_id):
    if not isinstance(record, dict) or set(record) != RUNTIME_FIELDS:
        raise UnsafeStateError("runtime fields do not match schema")
    if (
        type(record["schema_version"]) is not int
        or record["schema_version"] != 2
        or record["session_id"] != session_id
    ):
        raise UnsafeStateError("runtime identity does not match")
    if not isinstance(record["token"], str) or not TOKEN_RE.fullmatch(record["token"]):
        raise UnsafeStateError("runtime token is invalid")
    if not exact_int(record["pid"], 1, MAX_PID):
        raise UnsafeStateError("runtime PID is invalid")
    process_start = record["process_start"]
    if not isinstance(process_start, str) or not (
        LINUX_ID_RE.fullmatch(process_start) or DARWIN_ID_RE.fullmatch(process_start)
    ):
        raise UnsafeStateError("runtime process identity is invalid")
    if not isinstance(record["provider"], str) or not PROVIDER_RE.fullmatch(record["provider"]):
        raise UnsafeStateError("runtime provider is invalid")
    if not valid_text(record["workspace"], 4096) or not os.path.isabs(record["workspace"]):
        raise UnsafeStateError("runtime workspace is invalid")
    for field_name in ("started_at", "heartbeat_at"):
        if not exact_int(record[field_name], 1):
            raise UnsafeStateError("runtime timestamp is invalid")
    if record["heartbeat_at"] < record["started_at"]:
        raise UnsafeStateError("runtime heartbeat predates start")
    runtime_state = record["status"]
    if not isinstance(runtime_state, str):
        raise UnsafeStateError("runtime status is invalid")
    finished_at = record["finished_at"]
    if runtime_state == "running":
        if finished_at is not None:
            raise UnsafeStateError("running runtime has a finish time")
    elif runtime_state in TERMINAL_STATES:
        if not exact_int(finished_at, record["heartbeat_at"]):
            raise UnsafeStateError("runtime finish time is invalid")
    else:
        raise UnsafeStateError("runtime status is invalid")
    if not isinstance(record["lock_generation"], str) or not LOCK_GENERATION_RE.fullmatch(
        record["lock_generation"]
    ):
        raise UnsafeStateError("runtime lock generation is invalid")
    if not exact_int(record["lock_device"], 0, MAX_FILE_ID) or not exact_int(
        record["lock_inode"], 1, MAX_FILE_ID
    ):
        raise UnsafeStateError("runtime lock identity is invalid")
    return record


def runtime_lock_identity(runtime_file):
    return trusted_runtime_lock_identity(f"{runtime_file}-lock")


def runtime_details(session_id, families):
    empty = {
        "runtime_health": "legacy-unverifiable",
        "runtime_status": None,
        "runtime_pid": None,
        "provider": None,
        "workspace": None,
        "started_at": None,
        "heartbeat_at": None,
        "finished_at": None,
        "runtime_process_diagnostic": None,
        "runtime_snapshot": None,
    }
    if "runtime" not in families:
        return empty
    runtime_file = os.path.join(state_dir, f"{session_id}.runtime")
    try:
        payload = trusted_read(runtime_file, MAX_RUNTIME_BYTES, exact_mode=0o600)
        record = json.loads(payload.decode("utf-8"), object_pairs_hook=no_duplicate_keys)
        record = validate_runtime(record, session_id)
        observed_lock = runtime_lock_identity(runtime_file)
        if observed_lock != {
            "generation": record["lock_generation"],
            "device": record["lock_device"],
            "inode": record["lock_inode"],
        }:
            raise UnsafeStateError("runtime record is bound to another lock")
    except (FileNotFoundError, UnsafeStateError, UnicodeDecodeError, ValueError, RecursionError):
        return {**empty, "runtime_health": "corrupt"}
    probe = process_probe(record["pid"])
    if record["status"] != "running":
        runtime_health = "dead"
        process_diagnostic = None
    elif probe["health"] == "unverifiable":
        runtime_health = "unverifiable"
        process_diagnostic = ps_diagnostic(record["pid"])
    elif probe["health"] == "live" and probe["identity"] == record["process_start"]:
        runtime_health = "live"
        process_diagnostic = None
    else:
        runtime_health = "dead"
        process_diagnostic = None
    return {
        "runtime_health": runtime_health,
        "runtime_status": record["status"],
        "runtime_pid": record["pid"],
        "provider": record["provider"],
        "workspace": record["workspace"],
        "started_at": record["started_at"],
        "heartbeat_at": record["heartbeat_at"],
        "finished_at": record["finished_at"],
        "runtime_process_diagnostic": process_diagnostic,
        "runtime_snapshot": json.dumps(
            {field_name: value for field_name, value in record.items() if field_name != "token"},
            sort_keys=True,
            separators=(",", ":"),
        ),
    }


def registered_workspace_roots():
    roots = {os.path.realpath(repo_root)}
    child_env = os.environ.copy()
    child_env["LC_ALL"] = "C"
    try:
        completed = subprocess.run(
            ["git", "-C", repo_root, "worktree", "list", "--porcelain"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=child_env,
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return tuple(roots)
    if completed.returncode != 0 or len(completed.stdout) > MAX_STATE_BYTES:
        return tuple(roots)
    try:
        lines = completed.stdout.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        return tuple(roots)
    for raw_line in lines:
        if not raw_line.startswith("worktree "):
            continue
        workspace = raw_line[len("worktree ") :]
        if valid_text(workspace, 4096) and os.path.isabs(workspace):
            roots.add(os.path.realpath(workspace))
    return tuple(roots)


ALLOWED_WORKSPACES = registered_workspace_roots()


def workspace_belongs_here(workspace):
    if workspace is None:
        return True
    normalized = os.path.realpath(workspace)
    worktree_root = os.path.join(repo_root, ".dex", "worktrees")
    return normalized in ALLOWED_WORKSPACES or normalized.startswith(worktree_root + os.sep)


def workspace_is_registered_here(workspace):
    return workspace is not None and os.path.realpath(workspace) in ALLOWED_WORKSPACES


def terminal_commit_valid(session_id, record, families):
    if record["phase"] != 7 or "terminal-commit" not in families:
        return False
    live_families = {
        "active",
        "owner",
        "config",
        "handoff-mode",
        "control",
        "control-lock",
        "paused",
        "pause-state",
        "completion-expectation",
        "phase-busy",
        "phase-busy-cancel",
        "phase-busy-quiesced",
    }
    if families.intersection(live_families):
        return False
    terminal_file = os.path.join(state_dir, f"{session_id}.terminal-commit")
    try:
        payload = trusted_read(terminal_file, 512, exact_mode=0o600)
    except (FileNotFoundError, UnsafeStateError):
        return False
    if TERMINAL_PROOF_RE.fullmatch(payload) is None:
        return False
    if "human-complete" in families:
        human_file = os.path.join(state_dir, f"{session_id}.human-complete")
        try:
            human_payload = trusted_read(human_file, 64, exact_mode=0o600)
        except (FileNotFoundError, UnsafeStateError):
            return False
        if human_payload != b"human-complete\n":
            return False
    return True


def standalone_review_complete_valid(session_id, families):
    review_families = {
        "review-receipt",
        "review-selection",
        "review-selection-revoked",
        "review-ledger",
        "review-proofs",
        "review-criteria",
        "review-criteria-approval",
    }
    if not families.intersection(review_families):
        return None
    brake_families = {
        "review-receipt-revoked",
        "review-selection-revoked",
        "review-state",
        "paused",
        "pause-state",
        "control",
        "control-lock",
        "active",
        "owner",
        "config",
        "handoff-mode",
        "completion-expectation",
    }
    if "review-receipt" not in families or families.intersection(brake_families):
        return False
    receipt_file = os.path.join(loop_dir, f"{session_id}.review-receipt")
    try:
        payload = trusted_read(receipt_file, 4096, exact_mode=0o600)
    except (FileNotFoundError, UnsafeStateError):
        return False
    if REVIEW_RECEIPT_RE.fullmatch(payload) is None:
        return False
    try:
        fields = payload[:-1].decode("ascii").split("\t")
    except UnicodeDecodeError:
        return False
    if len(fields) != 10 or fields[7] != "standalone":
        return False
    if not os.path.isabs(dex_runtime_dir):
        return False
    validator = os.path.join(dex_runtime_dir, "lib", "common.sh")
    if not os.path.isfile(validator):
        return False
    child_env = os.environ.copy()
    child_env.update(
        {
            "DEX_DIR": dex_runtime_dir,
            "DX_STATE_DIR": state_dir,
            "DX_LOOP_DIR": loop_dir,
            "DEX_FACTORY_SYNC": "0",
        }
    )
    try:
        checked = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1" >/dev/null 2>&1 || exit 1; '
                'dx_review_receipt_valid "$2" "$3" "$4" "$5"',
                "_",
                validator,
                session_id,
                repo_root,
                fields[7],
                fields[8],
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=child_env,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return checked.returncode == 0


def lifecycle_state(record, families):
    if "cleanup-journal" in families:
        return "cleanup-in-progress"
    runtime_state = record["runtime_status"]
    runtime_health = record["runtime_health"]
    terminal_valid = terminal_commit_valid(record["session_id"], record, families)
    has_terminal_lifecycle_artifact = bool(
        families.intersection({"terminal-commit", "human-complete"})
    )
    if runtime_state == "completed":
        if record["phase"] == 7 or has_terminal_lifecycle_artifact:
            return "completed" if terminal_valid else "unknown"
        review_complete = standalone_review_complete_valid(
            record["session_id"], families
        )
        if review_complete is not None:
            return "completed" if review_complete else "unknown"
        return "completed"
    if runtime_state in TERMINAL_STATES:
        return runtime_state
    if runtime_state == "running":
        if runtime_health == "live":
            return "active"
        if runtime_health == "unverifiable":
            return "active-unverifiable"
        return "interrupted"
    if record["phase"] == 7:
        return "completed" if terminal_valid else "unknown"
    if "paused" in families or "pause-state" in families:
        return "paused"
    if "active" in families:
        return "legacy-active-unverifiable"
    return "unknown"


def build_records():
    grouped = scan_artifacts()
    records = {}
    for session_id, artifacts in grouped.items():
        if (
            artifacts["families"].issubset({"completion-lock", "runtime-lock"})
            and not artifacts["unsafe"]
        ):
            continue
        metadata, metadata_health = parse_metadata(session_id, artifacts["families"])
        child_match = CHILD_RE.fullmatch(session_id)
        is_explicit_child = bool(
            child_match
            and metadata_health == "valid"
            and metadata.get("session_role") == "review-child"
            and metadata.get("child_kind") == child_match.group(2)
            and metadata.get("parent_session_id") in grouped
            and session_id.startswith(
                f"{metadata.get('parent_session_id', '')[:120]}-"
                f"{metadata.get('child_kind', '')}-"
            )
        )
        parent_session = metadata.get("parent_session_id") if is_explicit_child else None
        child_kind = metadata.get("child_kind") if is_explicit_child else None
        runtime = runtime_details(session_id, artifacts["families"])
        if metadata_health == "valid" and not workspace_belongs_here(metadata.get("workspace")):
            continue
        if not workspace_belongs_here(runtime.get("workspace")):
            continue
        attribution_workspace = metadata.get("workspace") if metadata_health == "valid" else None
        if attribution_workspace is None:
            attribution_workspace = runtime.get("workspace")
        if artifacts["matched_repo_key"] != repo_key and (
            not workspace_is_registered_here(attribution_workspace)
        ):
            continue
        provider = runtime["provider"] or parse_provider(session_id, artifacts["families"])
        consistency_issues = []
        if (
            metadata.get("workspace") is not None
            and runtime.get("workspace") is not None
            and os.path.realpath(metadata["workspace"]) != os.path.realpath(runtime["workspace"])
        ):
            consistency_issues.append("runtime-workspace-mismatch")
        record = {
            "schema_version": 1,
            "session_id": session_id,
            "parent_session_id": parent_session,
            "is_child": is_explicit_child,
            "child_kind": child_kind,
            "ticket": metadata.get("ticket"),
            "workspace": metadata.get("workspace") or (
                runtime.get("workspace") if isinstance(runtime.get("workspace"), str) else None
            ),
            "workspace_name": metadata.get("workspace_name"),
            "workspace_mode": metadata.get("workspace_mode"),
            "phase": parse_phase(session_id, artifacts["families"]),
            "metadata_health": metadata_health,
            "provider": provider,
            "runtime_health": runtime["runtime_health"],
            "runtime_status": runtime["runtime_status"],
            "runtime_pid": runtime["runtime_pid"],
            "started_at": runtime["started_at"] or metadata.get("created_at"),
            "heartbeat_at": runtime["heartbeat_at"] or metadata.get("updated_at"),
            "finished_at": runtime["finished_at"],
            "runtime_process_diagnostic": runtime["runtime_process_diagnostic"],
            "runtime_snapshot": runtime["runtime_snapshot"],
            "artifacts": sorted(artifacts["families"]),
            "artifact_locations": {
                family: sorted(locations)
                for family, locations in sorted(artifacts["locations"].items())
            },
            "unsafe_artifacts": sorted(artifacts["unsafe"]),
            "consistency_issues": consistency_issues,
        }
        record["lifecycle_state"] = lifecycle_state(record, artifacts["families"])
        records[session_id] = record

    for record in records.values():
        parent_session = record["parent_session_id"]
        if not parent_session or parent_session not in records:
            continue
        parent = records[parent_session]
        for field_name in ("ticket", "workspace", "workspace_name", "workspace_mode"):
            if record[field_name] is None:
                record[field_name] = parent[field_name]
    return [records[session_id] for session_id in sorted(records)]


def selector_matches(record, raw_selector):
    selector_kind = None
    selector_value = raw_selector
    for prefix in ("session:", "ticket:", "workspace:"):
        if raw_selector.startswith(prefix):
            selector_kind = prefix[:-1]
            selector_value = raw_selector[len(prefix) :]
            break
    if not valid_text(selector_value, 4096):
        raise CatalogInputError("selector is empty or contains control characters")
    if selector_kind == "session":
        if not SESSION_RE.fullmatch(selector_value):
            raise CatalogInputError("session selector is invalid")
        return record["session_id"] == selector_value
    if selector_kind == "ticket":
        return record["ticket"] == selector_value
    workspace_candidates = {record["workspace_name"], record["workspace"]}
    if selector_kind == "workspace":
        if selector_value in workspace_candidates:
            return True
        if os.sep in selector_value:
            candidate = selector_value if os.path.isabs(selector_value) else os.path.join(repo_root, selector_value)
            return record["workspace"] is not None and os.path.realpath(candidate) == os.path.realpath(record["workspace"])
        return False
    if record["session_id"] == selector_value or record["ticket"] == selector_value:
        return True
    if selector_value in workspace_candidates:
        return True
    if os.sep in selector_value:
        candidate = selector_value if os.path.isabs(selector_value) else os.path.join(repo_root, selector_value)
        return record["workspace"] is not None and os.path.realpath(candidate) == os.path.realpath(record["workspace"])
    return False


try:
    if include_raw not in {"0", "1"}:
        raise CatalogInputError("invalid child-session option")
    if (
        not repo_keys
        or any(not SESSION_RE.fullmatch(candidate_key) for candidate_key in repo_keys)
        or not os.path.isabs(repo_root)
        or not ALLOWED_WORKSPACES
        or any(not os.path.isabs(workspace) for workspace in ALLOWED_WORKSPACES)
    ):
        raise CatalogInputError("invalid repository context")
    records = build_records()
    if operation == "records":
        for record in records:
            if include_children or not record["is_child"]:
                print(json.dumps(record, sort_keys=True, separators=(",", ":")))
    elif operation == "record":
        if not SESSION_RE.fullmatch(selector):
            raise CatalogInputError("invalid session ID")
        matches = [record for record in records if record["session_id"] == selector]
        if not matches:
            raise SystemExit(1)
        print(json.dumps(matches[0], sort_keys=True, separators=(",", ":")))
    elif operation == "select":
        candidates = [record for record in records if include_children or not record["is_child"]]
        matches = [record for record in candidates if selector_matches(record, selector)]
        if not matches:
            raise SystemExit(1)
        if len(matches) > 1:
            emit_error(f"selector matches {len(matches)} sessions; use a full session ID", 2)
        print(json.dumps(matches[0], sort_keys=True, separators=(",", ":")))
    else:
        raise CatalogInputError("unknown catalog operation")
except CatalogInputError as exc:
    emit_error(str(exc), 3)
PY
}

__dx_session_catalog_parse_context() {
  local repo_dir="$1" context_line repo_keys repo_root
  context_line=$(__dx_session_catalog_repo_context "$repo_dir") || return 3
  IFS=$'\t' read -r repo_keys repo_root <<EOF
$context_line
EOF
  [[ -n "$repo_keys" && -n "$repo_root" ]] || return 3
  printf '%s\t%s\n' "$repo_keys" "$repo_root"
}

# dx_session_catalog_records [--repo <dir>] [--include-children]
# Print one compact JSON object per current-repository lifecycle session.
dx_session_catalog_records() {
  local repo_dir="${PWD:-.}" include_children=0 argument context_line repo_keys repo_root
  while [[ $# -gt 0 ]]; do
    argument="$1"
    case "$argument" in
      --repo)
        [[ $# -ge 2 ]] || return 3
        repo_dir="$2"
        shift 2
        ;;
      --repo=*)
        repo_dir="${argument#--repo=}"
        shift
        ;;
      --include-children)
        include_children=1
        shift
        ;;
      *) return 3 ;;
    esac
  done
  context_line=$(__dx_session_catalog_parse_context "$repo_dir") || return 3
  IFS=$'\t' read -r repo_keys repo_root <<EOF
$context_line
EOF
  __dx_session_catalog_call records "$repo_keys" "$repo_root" "$include_children"
}

# dx_session_catalog_record <session_id> [--repo <dir>]
# Exact record lookup includes child sessions for diagnostics.
dx_session_catalog_record() {
  [[ $# -ge 1 ]] || return 3
  local session_id="$1" repo_dir="${PWD:-.}" argument context_line repo_keys repo_root
  shift
  while [[ $# -gt 0 ]]; do
    argument="$1"
    case "$argument" in
      --repo)
        [[ $# -ge 2 ]] || return 3
        repo_dir="$2"
        shift 2
        ;;
      --repo=*)
        repo_dir="${argument#--repo=}"
        shift
        ;;
      *) return 3 ;;
    esac
  done
  context_line=$(__dx_session_catalog_parse_context "$repo_dir") || return 3
  IFS=$'\t' read -r repo_keys repo_root <<EOF
$context_line
EOF
  __dx_session_catalog_call record "$repo_keys" "$repo_root" 1 "$session_id"
}

# dx_session_catalog_select <selector> [--repo <dir>] [--include-children]
# Selectors are exact session IDs, tickets, workspace names, or workspace paths.
dx_session_catalog_select() {
  [[ $# -ge 1 ]] || return 3
  local selector_value="$1" repo_dir="${PWD:-.}" include_children=0 argument
  local context_line repo_keys repo_root
  shift
  while [[ $# -gt 0 ]]; do
    argument="$1"
    case "$argument" in
      --repo)
        [[ $# -ge 2 ]] || return 3
        repo_dir="$2"
        shift 2
        ;;
      --repo=*)
        repo_dir="${argument#--repo=}"
        shift
        ;;
      --include-children)
        include_children=1
        shift
        ;;
      *) return 3 ;;
    esac
  done
  context_line=$(__dx_session_catalog_parse_context "$repo_dir") || return 3
  IFS=$'\t' read -r repo_keys repo_root <<EOF
$context_line
EOF
  __dx_session_catalog_call select "$repo_keys" "$repo_root" "$include_children" "$selector_value"
}

"""Durable wave handoff storage. Shell callers own control and proof validation."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile


FIELDS = (
    "child", "pass_id", "generation", "result", "findings", "profile", "tier",
    "required", "iteration", "clean", "total", "scope", "working", "criteria",
    "policy", "source", "reasons", "ledger_op", "findings_op", "scope_before",
    "descriptor", "branch", "head",
)
OUTPUTS = ("review-state", "review-selection", "findings", "review-ledger", "review-proofs")
CRITERIA = ("review-criteria.json", "review-criteria-approval")
MAX_FILE = 1048576
MAX_TOTAL = 41943040
MAX_ENTRIES = 256


class AcceptanceError(Exception):
    pass


def safe_name(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,179}", value):
        raise AcceptanceError("invalid session")
    return value


def directory(path):
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or info.st_mode & 0o022):
        raise AcceptanceError("unsafe directory")


def read(path):
    before = path.lstat()
    if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid()
            or before.st_nlink != 1 or before.st_mode & 0o022 or before.st_size > MAX_FILE):
        raise AcceptanceError("unsafe file")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened = os.fstat(fd)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise AcceptanceError("file changed while opening")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            content = stream.read(MAX_FILE + 1)
        after = os.fstat(fd)
        if (len(content) != opened.st_size or len(content) > MAX_FILE
                or (after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                != (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)):
            raise AcceptanceError("file changed while reading")
        return content
    finally:
        os.close(fd)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write(path, content, mode=0o600):
    directory(path.parent)
    if path.exists() or path.is_symlink():
        read(path)
    fd, temporary = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_dir(path.parent)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def inventory(root):
    """Bound every traversal and reject links before any copy or removal."""
    entries = {}
    total = 0

    def visit(path):
        nonlocal total
        if len(entries) >= MAX_ENTRIES:
            raise AcceptanceError("too many handoff files")
        relative = str(path.relative_to(root))
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            directory(path)
            entries[relative] = (stat.S_IMODE(info.st_mode), None)
            for child in sorted(path.iterdir()):
                visit(child)
        else:
            content = read(path)
            total += len(content)
            if total > MAX_TOTAL:
                raise AcceptanceError("handoff exceeds size limit")
            entries[relative] = (stat.S_IMODE(info.st_mode), content)

    visit(root)
    return entries


def remove(path):
    if not os.path.lexists(path):
        return
    entries = inventory(path)
    for relative, (_, content) in entries.items():
        if content is None:
            (path / relative).chmod(0o700)
    if entries["."][1] is None:
        shutil.rmtree(path)
    else:
        path.unlink()


def copy(source, target):
    entries = inventory(source)
    for relative, (mode, content) in entries.items():
        destination = target / relative if relative != "." else target
        if content is None:
            destination.mkdir(mode=0o700)
        else:
            write(destination, content, mode)
    for relative, (mode, content) in reversed(list(entries.items())):
        if content is None:
            destination = target / relative if relative != "." else target
            destination.chmod(mode)
            sync_dir(destination)
    sync_dir(target.parent)


def digest(root):
    value = hashlib.sha256()
    for name, (mode, content) in sorted(inventory(root).items()):
        value.update(name.encode() + b"\0" + str(mode).encode() + b"\0")
        value.update(b"directory" if content is None else hashlib.sha256(content).digest())
    return value.hexdigest()


def metadata(root, session):
    directory(root)
    data = json.loads(read(root / "record.json"))
    if (set(data) != {"version", "session", "repo", *FIELDS}
            or data["version"] != 1 or data["session"] != session):
        raise AcceptanceError("invalid handoff record")
    for field in ("child", "pass_id"):
        safe_name(data[field])
    for field in ("required", "iteration", "clean", "total"):
        if not re.fullmatch(r"0|[1-9][0-9]{0,17}", data[field]):
            raise AcceptanceError("invalid handoff counter")
    for field in ("scope", "working", "policy", "scope_before"):
        if not re.fullmatch(r"[0-9a-f]{64}", data[field]):
            raise AcceptanceError("invalid handoff binding")
    if not re.fullmatch(r"[0-9a-f]{32}", data["generation"]):
        raise AcceptanceError("invalid generation")
    for field in FIELDS:
        if (not isinstance(data[field], str) or not data[field]
                or len(data[field]) > 4096 or "\n" in data[field] or "\r" in data[field]
                or (field != "descriptor" and "\t" in data[field])):
            raise AcceptanceError("invalid handoff value")
    return data


def begin(base, session, repo, values):
    if len(values) != len(FIELDS):
        raise AcceptanceError("wrong handoff arity")
    target = base / (session + ".review-acceptance")
    if os.path.lexists(target):
        raise AcceptanceError("a handoff is already pending")
    temporary = Path(tempfile.mkdtemp(prefix=".review-acceptance-", dir=base))
    try:
        data = dict(zip(FIELDS, values), version=1, session=session, repo=str(Path(repo).resolve()))
        write(temporary / "record.json", json.dumps(data, sort_keys=True).encode())
        metadata(temporary, session)
        sync_dir(temporary)
        os.rename(temporary, target)
        sync_dir(base)
        capture_inputs(target, base, session, data)
    finally:
        remove(temporary)


def capture_inputs(root, base, session, data):
    # No parent state changes before inputs are sealed. A crash while copying
    # can therefore resume from the still-live child and untouched parent.
    if any(os.path.lexists(root / name) for name in ("stage", "stage.sha256", "committed")):
        raise AcceptanceError("missing inputs for a staged handoff")
    for name in ("before", "evidence.json", "context.md", "authorization"):
        remove(root / name)
    (root / "before").mkdir(mode=0o700)
    for suffix in (*OUTPUTS, *CRITERIA):
        source = base / (session + "." + suffix)
        if os.path.lexists(source):
            copy(source, root / "before" / source.name)
    child = safe_name(data["child"])
    for name, suffix in (("evidence.json", "review-evidence.json"), ("context.md", "review-context")):
        copy(base / (child + "." + suffix), root / name)
    authorization = root / "authorization"
    authorization.mkdir(mode=0o700)
    for suffix in ("completion-expectation", "completion-receipt." + data["generation"]):
        copy(base / (child + "." + suffix), authorization / (child + "." + suffix))
    write(authorization / (child + ".completion-lock"), b"")
    hashes = (digest(root / name) for name in (
        "before", "evidence.json", "context.md", "authorization", "record.json"))
    write(root / "inputs.sha256", "\n".join(hashes).encode())


def validate_inputs(root):
    expected = "\n".join(digest(root / name) for name in (
        "before", "evidence.json", "context.md", "authorization", "record.json"))
    if read(root / "inputs.sha256").decode() != expected:
        raise AcceptanceError("handoff inputs changed")


def run(operation, base, session, *args):
    base = Path(base)
    directory(base)
    safe_name(session)
    root = base / (session + ".review-acceptance")
    if operation == "begin":
        begin(base, session, args[0], args[1:])
        return
    if operation == "remove":
        remove(root)
        sync_dir(base)
        return
    data = metadata(root, session)
    if not os.path.lexists(root / "inputs.sha256"):
        capture_inputs(root, base, session, data)
    validate_inputs(root)
    if operation == "committed":
        if not os.path.lexists(root / "committed"):
            raise SystemExit(3)
        if read(root / "committed") != read(root / "stage.sha256"):
            raise AcceptanceError("invalid committed handoff")
        return
    if operation == "read":
        print("\t".join(data[field] for field in args))
    elif operation == "stage":
        if os.path.lexists(root / "committed"):
            raise AcceptanceError("committed handoff cannot be restaged")
        remove(root / "stage")
        copy(root / "before", root / "stage")
    elif operation == "seal":
        write(root / "stage.sha256", digest(root / "stage").encode())
    elif operation in ("validate", "commit", "install"):
        if read(root / "stage.sha256").decode() != digest(root / "stage"):
            raise AcceptanceError("handoff checkpoint changed")
        if operation == "commit":
            write(root / "committed", read(root / "stage.sha256"))
        elif operation == "install":
            if read(root / "committed") != read(root / "stage.sha256"):
                raise AcceptanceError("handoff is not committed")
            for suffix in OUTPUTS:
                source = root / "stage" / (session + "." + suffix)
                target = base / source.name
                # Reinstalling a complete checkpoint is idempotent, including
                # an interruption between proof publication and ledger write.
                remove(target)
                if os.path.lexists(source):
                    copy(source, target)
                sync_dir(base)
    else:
        raise AcceptanceError("unknown handoff operation")


if __name__ == "__main__":
    try:
        run(*sys.argv[1:])
    except (AcceptanceError, OSError, ValueError, TypeError, KeyError, IndexError) as error:
        print("Review handoff: " + str(error), file=sys.stderr)
        raise SystemExit(1)

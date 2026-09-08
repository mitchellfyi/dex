"""Mechanical inputs and receipts for reusable review checks."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile


class CheckError(ValueError):
    """The check's reusable inputs or receipt cannot be established."""


# Remove orchestration metadata from the command as well as its fingerprint.
# An unknown variable remains an input, including user-defined DEX_* settings.
CONTROL_ENV = {
    "CODEX_THREAD_ID", "CODEX_SESSION_ID", "CLAUDE_CODE_SESSION_ID",
    "_", "SHLVL", "OLDPWD", "DEX_SESSION_ID", "DEX_POLICY_SESSION_ID",
    "DEX_RUN_ID", "DEX_PHASE_HANDOFF", "DEX_LOOP_ACTIVE", "DEX_LOOP_PHASE",
    "DEX_LOOP_PROMISE", "DEX_LOOP_PROMPT", "DEX_REVIEW_PASS_ACTIVE",
    "DEX_REVIEW_ASSESSMENT_ACTIVE", "DEX_REVIEW_TIER", "DEX_REVIEW_PROFILE",
    "DEX_REVIEW_SCOPE_FINGERPRINT", "DEX_REVIEW_WORKING_FINGERPRINT",
    "DEX_REVIEW_CRITERIA_BINDING", "DEX_REVIEW_CRITERIA_FILE",
    "DEX_REVIEW_POLICY_BINDING", "DEX_REVIEW_PASS_ID", "DEX_REVIEW_PASS_BINDING",
    "DEX_REVIEW_BASELINE_FILE", "DEX_REVIEW_BASELINE_MODE",
    "DEX_REVIEW_BASELINE_BINDING", "DEX_REVIEW_METRICS_FILE",
    "DEX_REVIEW_BUSY_TOKEN", "DEX_REVIEW_WAVE_NUMBER", "DEX_REVIEW_CLEAN_BEFORE",
    "DEX_REVIEW_REQUIRED_CLEAN", "DEX_REVIEW_CONTEXT_FILE",
    "DEX_REVIEW_INPUT_FILE", "DEX_REVIEW_CHECK_CACHE_SESSION",
}


def execution_environment(environment, reusable=True):
    """Keep check inputs stable without exposing review-child control state."""
    if not reusable:
        return dict(environment)
    return {key: value for key, value in environment.items() if key not in CONTROL_ENV}


def regular_json(filename, maximum=262144):
    """Read a bounded regular file without following its final symlink."""
    descriptor = os.open(filename, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= maximum:
            raise CheckError("Expected a bounded regular JSON file")
        return json.loads(stream.read(maximum + 1))


def validate_spec(spec):
    """Validate a command and its declared non-checkout inputs."""
    if not isinstance(spec, dict) or set(spec) != {"name", "argv", "cache", "inputs", "tools"}:
        raise CheckError("Check spec needs name, argv, cache, inputs, and tools")
    if (not isinstance(spec["name"], str) or not 1 <= len(spec["name"]) <= 160
            or spec["name"] != spec["name"].strip()
            or any(ord(char) < 32 or ord(char) == 127 for char in spec["name"])
            or spec["cache"] not in ("never", "snapshot")):
        raise CheckError("Invalid check name or cache mode")
    for field, minimum, maximum in [("argv", 1, 256), ("inputs", 0, 256), ("tools", 0, 32)]:
        values = spec[field]
        if (not isinstance(values, list) or not minimum <= len(values) <= maximum
                or any(not isinstance(value, str) or not value or "\0" in value
                       or len(value) > 32768 for value in values)):
            raise CheckError("Invalid check arguments, inputs, or tools")
    return spec


def digest_path(filename, digest, ancestors=(), budget=None):
    """Hash file bytes, modes, symlink destinations, and directory entries."""
    budget = budget if budget is not None else [100000, 1024 * 1024 * 1024]
    target = Path(filename)
    budget[0] -= 1
    if budget[0] < 0:
        raise CheckError("Declared inputs exceed the cache fingerprint limit; use cache=never")
    try:
        info = target.lstat()
        identity = (info.st_dev, info.st_ino)
        if identity in ancestors:
            raise CheckError("Cyclic declared input")
        header = [str(target), info.st_mode, info.st_size if stat.S_ISREG(info.st_mode) else None]
        encoded = json.dumps(header, ensure_ascii=True).encode()
        digest.update(len(encoded).to_bytes(8, "big") + encoded)
        if stat.S_ISLNK(info.st_mode):
            destination = os.readlink(target)
            digest.update(os.fsencode(destination) + b"\0")
            digest_path(target.parent / destination, digest, ancestors + (identity,), budget)
        elif stat.S_ISDIR(info.st_mode):
            children = sorted(target.iterdir())
            digest.update(len(children).to_bytes(8, "big"))
            for child in children:
                digest_path(child, digest, ancestors + (identity,), budget)
            after = target.lstat()
            if (after.st_ino, after.st_mtime_ns, after.st_ctime_ns) != (
                    info.st_ino, info.st_mtime_ns, info.st_ctime_ns):
                raise CheckError("Declared directory changed during fingerprinting")
        elif stat.S_ISREG(info.st_mode):
            budget[1] -= info.st_size
            if budget[1] < 0:
                raise CheckError("Declared inputs exceed the cache byte limit; use cache=never")
            descriptor = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, "rb") as stream:
                opened = os.fstat(stream.fileno())
                if (opened.st_dev, opened.st_ino) != identity or not stat.S_ISREG(opened.st_mode):
                    raise CheckError("Declared input changed during fingerprinting")
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
                after = os.fstat(stream.fileno())
                if (after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (
                        info.st_size, info.st_mtime_ns, info.st_ctime_ns):
                    raise CheckError("Declared input changed during fingerprinting")
        else:
            raise CheckError("Declared input is not a file or directory")
    except OSError as exc:
        raise CheckError("Declared input is missing or unreadable") from exc


def digest_checkout(digest, budget):
    """Check actual source bytes, including files hidden by Git index hints."""
    def git(*args):
        completed = subprocess.run(["git", *args], check=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        if len(completed.stdout) > 16 * 1024 * 1024:
            raise CheckError("Checkout inventory exceeds the reuse limit")
        return completed.stdout

    try:
        root = Path(os.fsdecode(git("rev-parse", "--show-toplevel").rstrip(b"\n")))
        entries = git("-C", str(root), "ls-files", "--stage", "-z").split(b"\0")
        if any(entry.startswith(b"160000 ") for entry in entries):
            raise CheckError("Submodule checkouts run without cache reuse")
        paths = git("-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
        for raw in sorted(set(paths) - {b""}):
            target = root / os.fsdecode(raw)
            if not target.exists() and not target.is_symlink():
                digest.update(b"MISSING\0" + len(raw).to_bytes(8, "big") + raw)
            else:
                digest_path(target, digest, budget=budget)
    except subprocess.SubprocessError as exc:
        raise CheckError("Could not fingerprint the complete checkout") from exc


def fingerprint(spec, bindings, environment, include_checkout=False):
    """Bind a check to its command, checkout, tools, and effective environment."""
    validate_spec(spec)
    if len(bindings) != 4 or any(not re.fullmatch(
            r"[a-f0-9]{64}|standalone" if index == 2 else r"[a-f0-9]{64}", item)
            for index, item in enumerate(bindings)):
        raise CheckError("Invalid checkout or review bindings")
    if spec["cache"] == "never":
        return "never"
    effective = execution_environment(environment)
    # This supervisor token identifies descendants for cancellation; checks
    # must not treat it as application data. Keep it on the launched process.
    effective.pop("DX_TIMEOUT_PROCESS_TOKEN", None)
    payload = ["dex-review-check-v1", os.getcwd(), bindings, spec, effective,
               list(os.uname())]
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=True).encode())
    budget = [100000, 1024 * 1024 * 1024]
    if include_checkout:
        digest_checkout(digest, budget)
    for filename in sorted(set(spec["inputs"])):
        digest_path(Path(filename).absolute(), digest, budget=budget)
    for name in sorted(set([spec["argv"][0]] + spec["tools"])):
        executable = shutil.which(name, path=environment.get("PATH", os.defpath))
        if not executable:
            # A declared tool path need not itself have an executable bit.
            executable = name if os.path.isfile(name) else None
        if not executable:
            raise CheckError("Declared tool is unavailable")
        digest_path(Path(executable).absolute(), digest, budget=budget)
    return digest.hexdigest()


def cached(filename, key):
    """Return the duration only for a matching, private passing receipt."""
    try:
        info = os.lstat(filename)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            return None
        payload = regular_json(filename, 4096)
        if (not isinstance(payload, dict) or set(payload) != {
                "version", "key", "status", "duration_seconds"}
                or type(payload["version"]) is not int or payload["version"] != 1
                or payload["key"] != key or payload["status"] != "pass"
                or type(payload["duration_seconds"]) is not int
                or not 0 <= payload["duration_seconds"] <= 999999999999999):
            return None
        return payload["duration_seconds"]
    except (OSError, ValueError):
        return None


def record(filename, key, duration):
    """Atomically record success without storing command or environment values."""
    target = Path(filename)
    if not re.fullmatch(r"[a-f0-9]{64}", key) or type(duration) is not int or duration < 0:
        raise CheckError("Invalid check receipt")
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise CheckError("Unsafe check receipt target")
    if target.parent.is_symlink() or not target.parent.is_dir():
        raise CheckError("Unsafe check cache directory")
    scratch = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=target.parent,
                                         prefix=".check-", delete=False) as stream:
            scratch = Path(stream.name)
            json.dump({"version": 1, "key": key, "status": "pass",
                       "duration_seconds": duration}, stream, sort_keys=True)
        os.replace(scratch, target)
    finally:
        if scratch is not None:
            scratch.unlink(missing_ok=True)


def main(arguments):
    """Internal shell-runner interface; command arguments are never evaluated."""
    try:
        operation, *args = arguments
        if operation in ("name", "slot", "key", "execute"):
            spec = validate_spec(regular_json(args[0]))
        if operation == "name":
            print(spec["name"])
        elif operation == "slot":
            print(hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest())
        elif operation == "key":
            print(fingerprint(spec, args[1:], os.environ, include_checkout=True))
        elif operation == "execute":
            # Preserve the supervisor's inherited descriptor for descendant
            # cancellation on macOS, and avoid an extra process around tests.
            os.execvpe(spec["argv"][0], spec["argv"],
                       execution_environment(os.environ, reusable=spec["cache"] == "snapshot"))
        elif operation == "cached":
            duration = cached(args[0], args[1])
            if duration is None:
                return 1
            print(duration)
        elif operation == "record":
            record(args[0], args[1], int(args[2]))
        else:
            raise CheckError("Unknown review check operation")
        return 0
    except (OSError, ValueError, IndexError) as exc:
        print(f"review-check: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Create and verify portable DX maintenance publication bundles."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import stat
import sys
from pathlib import Path, PurePosixPath


FORMAT_VERSION = "1"
MAX_STATE_BYTES = 64 * 1024
MAX_PATCH_BYTES = 64 * 1024 * 1024
MAX_REPORT_BYTES = 8 * 1024 * 1024
MAX_VALUE_BYTES = 4096

METADATA_FIELDS = {
    "publish": (
        "repo_root",
        "branch",
        "mode",
        "run_id",
        "base_sha",
    ),
    "response": (
        "repo_root",
        "pr_num",
        "run_id",
        "base_sha",
        "expected_branch",
        "expected_sha",
        "allowed_categories",
        "trusted_ref",
    ),
}

FINAL_FIELDS = {
    kind: (
        "format_version",
        *metadata,
        "report_file_rel",
        "patch_file",
        "patch_sha256",
        "patch_size",
    )
    for kind, metadata in METADATA_FIELDS.items()
}


class StateError(ValueError):
    pass


def fail(message: str) -> None:
    raise StateError(message)


def has_control(value: str) -> bool:
    return any(ord(char) < 32 or ord(char) == 127 for char in value)


def validate_path_text(path: Path, label: str) -> None:
    value = str(path)
    if has_control(value):
        fail(f"{label} contains control characters")
    if len(value.encode("utf-8")) > MAX_VALUE_BYTES:
        fail(f"{label} exceeds the {MAX_VALUE_BYTES}-byte path limit")


def read_regular_file(path: Path, limit: int, label: str) -> bytes:
    try:
        info = path.lstat()
    except OSError as exc:
        fail(f"cannot inspect {label}: {exc}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail(f"{label} must be a regular file, not a link or special file")
    if info.st_size > limit:
        fail(f"{label} exceeds the {limit}-byte limit")

    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        fail(f"cannot open {label} safely: {exc}")
    try:
        with os.fdopen(descriptor, "rb") as handle:
            data = handle.read(limit + 1)
    except OSError as exc:
        fail(f"cannot read {label}: {exc}")
    if len(data) > limit:
        fail(f"{label} exceeds the {limit}-byte limit")
    return data


def parse_fields(path: Path, expected: tuple[str, ...], label: str) -> dict[str, str]:
    raw = read_regular_file(path, MAX_STATE_BYTES, label)
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        fail(f"{label} is not valid UTF-8")

    fields: dict[str, str] = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        if line.count("\t") != 1:
            fail(f"{label} line {line_number} must contain one tab separator")
        key, value = line.split("\t", 1)
        if not re.fullmatch(r"[a-z][a-z0-9_]*", key):
            fail(f"{label} line {line_number} has an invalid key")
        if key in fields:
            fail(f"{label} repeats field {key}")
        if not value:
            fail(f"{label} field {key} is empty")
        if has_control(value):
            fail(f"{label} field {key} contains control characters")
        if len(value.encode("utf-8")) > MAX_VALUE_BYTES:
            fail(f"{label} field {key} exceeds the {MAX_VALUE_BYTES}-byte limit")
        fields[key] = value

    expected_set = set(expected)
    actual_set = set(fields)
    missing = sorted(expected_set - actual_set)
    extra = sorted(actual_set - expected_set)
    if missing:
        fail(f"{label} is missing fields: {', '.join(missing)}")
    if extra:
        fail(f"{label} has unexpected fields: {', '.join(extra)}")
    return fields


def validate_metadata(kind: str, fields: dict[str, str]) -> None:
    repo_root = fields["repo_root"]
    if not os.path.isabs(repo_root):
        fail("repo_root must be absolute")
    run_id = fields["run_id"]
    if not re.fullmatch(r"maintain-[A-Za-z0-9._-]{1,180}", run_id) or ".." in run_id:
        fail("run_id is not a safe maintenance run id")

    sha_fields = ["base_sha"]
    if kind == "response":
        sha_fields.extend(("expected_sha", "trusted_ref"))
        if not re.fullmatch(r"[1-9][0-9]{0,9}", fields["pr_num"]):
            fail("pr_num must be a positive decimal integer")
    elif fields["mode"] not in {"propose", "fix-scoped"}:
        fail("mode must be propose or fix-scoped")

    for key in sha_fields:
        if not re.fullmatch(r"[0-9A-Fa-f]{40,64}", fields[key]):
            fail(f"{key} must be a 40-64 character hexadecimal object id")


def validated_relative_path(value: str, label: str) -> PurePosixPath:
    if value in {"", ".", ".."} or "\\" in value or value.startswith("/"):
        fail(f"{label} must be a relative POSIX path")
    relative = PurePosixPath(value)
    if str(relative) != value or any(part in {"", ".", ".."} for part in relative.parts):
        fail(f"{label} is not canonical")
    return relative


def require_safe_tree_path(path: Path, root: Path, limit: int, label: str) -> bytes:
    root_path = root.absolute()
    resolved_root = root_path.resolve(strict=True)
    path = path.absolute()
    current = root_path
    try:
        relative = path.relative_to(root_path)
    except ValueError:
        fail(f"{label} escapes the maintenance bundle")
    for part in relative.parts:
        current = current / part
        try:
            info = current.lstat()
        except OSError as exc:
            fail(f"cannot inspect {label}: {exc}")
        if stat.S_ISLNK(info.st_mode):
            fail(f"{label} must not contain symlinks")
    try:
        resolved_path = path.resolve(strict=True)
    except OSError as exc:
        fail(f"cannot resolve {label}: {exc}")
    try:
        resolved_path.relative_to(resolved_root)
    except ValueError:
        fail(f"{label} escapes the maintenance bundle")
    return read_regular_file(path, limit, label)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_exclusive(parent_fd: int, name: str, data: bytes, mode: int = 0o600) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(name, flags, mode, dir_fd=parent_fd)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            os.unlink(name, dir_fd=parent_fd)
        except OSError:
            pass
        raise


def serialize(fields: dict[str, str], order: tuple[str, ...]) -> bytes:
    return "".join(f"{key}\t{fields[key]}\n" for key in order).encode("utf-8")


def seal(args: argparse.Namespace) -> None:
    state_path = Path(args.state).absolute()
    artifact_root = Path(args.artifact_root).absolute()
    metadata_path = Path(args.metadata).absolute()
    patch_staging = Path(args.patch).absolute()
    report_path = Path(args.report).absolute()
    for path, label in (
        (state_path, "publication state path"),
        (artifact_root, "maintenance artifact root"),
        (metadata_path, "state metadata path"),
        (patch_staging, "maintenance patch path"),
        (report_path, "maintenance report path"),
    ):
        validate_path_text(path, label)

    try:
        root_info = artifact_root.lstat()
    except OSError as exc:
        fail(f"cannot inspect maintenance artifact root: {exc}")
    if stat.S_ISLNK(root_info.st_mode) or not stat.S_ISDIR(root_info.st_mode):
        fail("maintenance artifact root must be a real directory")
    resolved_artifact_root = artifact_root.resolve(strict=True)

    try:
        state_parent = state_path.parent.resolve(strict=True)
    except OSError as exc:
        fail(f"cannot resolve publication state directory: {exc}")
    if state_parent != resolved_artifact_root:
        fail("publication state must be written directly inside the maintenance artifact root")
    if state_path.name in {"", ".", ".."} or "/" in state_path.name:
        fail("publication state filename is invalid")

    metadata = parse_fields(metadata_path, METADATA_FIELDS[args.kind], "state metadata")
    validate_metadata(args.kind, metadata)
    patch_data = read_regular_file(patch_staging, MAX_PATCH_BYTES, "maintenance patch")
    require_safe_tree_path(report_path, artifact_root, MAX_REPORT_BYTES, "maintenance report")

    report_relative = report_path.relative_to(artifact_root)
    report_rel_text = report_relative.as_posix()
    validated_relative_path(report_rel_text, "report_file_rel")
    if report_rel_text != f"{metadata['run_id']}/report.md":
        fail("maintenance report path does not match the run id")

    patch_name = f"{state_path.name}.patch"
    final_fields = {
        "format_version": FORMAT_VERSION,
        **metadata,
        "report_file_rel": report_rel_text,
        "patch_file": patch_name,
        "patch_sha256": sha256(patch_data),
        "patch_size": str(len(patch_data)),
    }
    state_data = serialize(final_fields, FINAL_FIELDS[args.kind])

    directory_flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        directory_flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        directory_flags |= os.O_NOFOLLOW
    try:
        parent_fd = os.open(state_parent, directory_flags)
    except OSError as exc:
        fail(f"cannot open publication state directory safely: {exc}")
    try:
        write_exclusive(parent_fd, patch_name, patch_data)
        try:
            write_exclusive(parent_fd, state_path.name, state_data)
        except BaseException:
            os.unlink(patch_name, dir_fd=parent_fd)
            raise
        os.fsync(parent_fd)
    except FileExistsError:
        fail("publication state or patch already exists; refusing to overwrite it")
    finally:
        os.close(parent_fd)


def verify(args: argparse.Namespace) -> None:
    state_path = Path(args.state).absolute()
    validate_path_text(state_path, "publication state path")
    fields = parse_fields(state_path, FINAL_FIELDS[args.kind], "publication state")
    if fields["format_version"] != FORMAT_VERSION:
        fail(f"unsupported publication state format: {fields['format_version']}")
    validate_metadata(args.kind, fields)

    bundle_root = state_path.parent.resolve(strict=True)
    report_relative = validated_relative_path(fields["report_file_rel"], "report_file_rel")
    patch_relative = validated_relative_path(fields["patch_file"], "patch_file")
    if len(patch_relative.parts) != 1:
        fail("patch_file must name a direct bundle member")
    if patch_relative.name != f"{state_path.name}.patch":
        fail("patch_file does not match the publication state filename")
    expected_report = f"{fields['run_id']}/report.md"
    if fields["report_file_rel"] != expected_report:
        fail("report_file_rel does not match the maintenance run id")

    report_path = bundle_root.joinpath(*report_relative.parts)
    patch_path = bundle_root.joinpath(*patch_relative.parts)
    validate_path_text(report_path, "maintenance report path")
    validate_path_text(patch_path, "maintenance patch path")
    require_safe_tree_path(report_path, bundle_root, MAX_REPORT_BYTES, "maintenance report")
    patch_data = require_safe_tree_path(patch_path, bundle_root, MAX_PATCH_BYTES, "maintenance patch")

    if not re.fullmatch(r"[0-9a-f]{64}", fields["patch_sha256"]):
        fail("patch_sha256 must be a lowercase SHA-256 digest")
    if not re.fullmatch(r"0|[1-9][0-9]{0,9}", fields["patch_size"]):
        fail("patch_size must be a canonical non-negative integer")
    if int(fields["patch_size"]) != len(patch_data):
        fail("maintenance patch size does not match its receipt")
    if fields["patch_sha256"] != sha256(patch_data):
        fail("maintenance patch digest does not match its receipt")

    emitted = dict(fields)
    emitted["report_file"] = str(report_path)
    emitted["patch_file_resolved"] = str(patch_path)
    output_order = (*FINAL_FIELDS[args.kind], "report_file", "patch_file_resolved")
    sys.stdout.buffer.write(serialize(emitted, output_order))


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subcommands = root.add_subparsers(dest="command", required=True)

    seal_parser = subcommands.add_parser("seal", help="write a new state and patch bundle")
    seal_parser.add_argument("--kind", choices=sorted(METADATA_FIELDS), required=True)
    seal_parser.add_argument("--state", required=True)
    seal_parser.add_argument("--metadata", required=True)
    seal_parser.add_argument("--patch", required=True)
    seal_parser.add_argument("--report", required=True)
    seal_parser.add_argument("--artifact-root", required=True)
    seal_parser.set_defaults(handler=seal)

    verify_parser = subcommands.add_parser("verify", help="validate and resolve a state bundle")
    verify_parser.add_argument("--kind", choices=sorted(FINAL_FIELDS), required=True)
    verify_parser.add_argument("--state", required=True)
    verify_parser.set_defaults(handler=verify)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
    except StateError as exc:
        print(f"maintenance state error: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"maintenance state error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

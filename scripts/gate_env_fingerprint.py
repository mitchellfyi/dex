#!/usr/bin/env python3
"""Fingerprint the environment a heavy gate runs in.

A gate receipt (lib/host-budget.sh, `dx_gate_receipt_write`) is keyed by the
checkout and working-tree fingerprints, which say which *tree* a result is
about. They say nothing about what produced it: which interpreter answered on
PATH, how many test workers the host budget allowed, whether the dependency
manifests the toolchain resolves from have moved. This script hashes those,
so a later phase reuses a receipt only when the same environment would run
the same check.

The shape follows `fingerprint()` in scripts/review_checks.py, which binds a
review check to its command, checkout, resolved tools and effective
environment. Two things differ, deliberately. The environment is a short
allowlist rather than everything minus control variables, because a gate
receipt has to survive a provider relaunch and the host snapshot (`DX_HOST_*`)
changes on every one. And the fingerprint does not include the gate's own
command: the receipt records the command verbatim and is keyed by gate name,
and the reader that asks "may I reuse this?" (bin/gate-receipt.sh) has the
name but not the command. What stands in for the command's executable is the
identity of every toolchain binary on PATH from a fixed list.

Tool identity is path, size and mtime — what `stat` returns — and no
`--version` is run: probing a dozen binaries on every tool call is not cheap,
and an upgrade moves the stat anyway.

Output is JSON so the inputs are auditable:

    {"schema_version": 1, "env_fingerprint": "<sha256>", "inputs": {...}}

`--hash-only` prints the fingerprint alone. Exit 2 for arguments it will not
act on. Standard library only.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys

SCHEMA_VERSION = 1
PAYLOAD_MARKER = "dex-gate-env-v1"

# Variables that change how a test suite or build behaves. DX_TEST_JOBS and
# the runner names are the budget lib/host-budget.sh exports
# (dx_host_budget_env); the rest are framework mode switches.
ENV_NAMES = (
    "DX_TEST_JOBS",
    "VITEST_MAX_THREADS",
    "VITEST_MAX_FORKS",
    "PYTEST_XDIST_AUTO_NUM_WORKERS",
    "CARGO_BUILD_JOBS",
    "RUST_TEST_THREADS",
    "GOFLAGS",
    "MAKEFLAGS",
    "NODE_ENV",
    "RAILS_ENV",
    "PYTHONPATH",
)

# Toolchain binaries whose identity on PATH is recorded when present.
TOOL_NAMES = (
    "bash", "sh", "node", "npm", "pnpm", "yarn", "python3", "python", "ruby",
    "bundle", "cargo", "rustc", "go", "java", "make",
)

# Dependency manifests at the repository root, when present.
MANIFEST_NAMES = (
    "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
    "Gemfile.lock", "poetry.lock", "Cargo.lock", "go.sum",
)
MANIFEST_GLOB = re.compile(r"^requirements[^/]*\.txt$")
MANIFEST_MAX_BYTES = 64 * 1024 * 1024

ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def sha256_file(filename):
    """Content hash of a bounded regular file, or a size marker past the bound."""
    digest = hashlib.sha256()
    with open(filename, "rb") as handle:
        info = os.fstat(handle.fileno())
        if info.st_size > MANIFEST_MAX_BYTES:
            return f"oversized:{info.st_size}"
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifest_inputs(repo):
    manifests = {}
    try:
        names = sorted(os.listdir(repo))
    except OSError:
        return manifests
    for name in names:
        if name not in MANIFEST_NAMES and not MANIFEST_GLOB.match(name):
            continue
        target = os.path.join(repo, name)
        if not os.path.isfile(target):
            continue
        try:
            manifests[name] = sha256_file(target)
        except OSError:
            manifests[name] = "unreadable"
    return manifests


def tool_inputs(search_path):
    tools = {}
    for name in TOOL_NAMES:
        executable = shutil.which(name, path=search_path)
        if not executable:
            continue
        try:
            info = os.stat(executable)
        except OSError:
            continue
        tools[name] = {
            "path": os.path.realpath(executable),
            "size": info.st_size,
            "mtime_ns": info.st_mtime_ns,
        }
    return tools


def env_inputs(environment, overrides):
    values = {}
    for name in ENV_NAMES:
        if name in environment:
            values[name] = environment[name]
    values.update(overrides)
    return values


def collect(repo, environment, overrides):
    uname = os.uname()
    search_path = environment.get("PATH", os.defpath)
    return {
        "platform": f"{uname.sysname} {uname.machine}",
        "path_sha256": hashlib.sha256(search_path.encode("utf-8", "replace")).hexdigest(),
        "env": env_inputs(environment, overrides),
        "tools": tool_inputs(search_path),
        "manifests": manifest_inputs(repo),
    }


def fingerprint(inputs):
    payload = json.dumps([PAYLOAD_MARKER, inputs], sort_keys=True,
                         separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def parse_set(values):
    overrides = {}
    for item in values:
        name, separator, value = item.partition("=")
        if not separator or not ENV_NAME.match(name):
            raise SystemExit(f"gate_env_fingerprint: --set needs NAME=VALUE with an environment "
                             f"variable name: {item!r}")
        overrides[name] = value
    return overrides


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="gate_env_fingerprint.py",
        description="Hash the environment a heavy gate runs in.",
    )
    parser.add_argument("--repo", default=os.getcwd(),
                        help="repository root whose manifests are read (default: cwd)")
    parser.add_argument("--set", dest="overrides", action="append", default=[],
                        metavar="NAME=VALUE",
                        help="bind this value in place of the inherited one; repeatable")
    parser.add_argument("--hash-only", action="store_true",
                        help="print the fingerprint alone instead of the JSON record")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        raise SystemExit(2 if exc.code else 0) from None
    repo = os.path.abspath(args.repo)
    if not os.path.isdir(repo):
        print(f"gate_env_fingerprint: not a directory: {args.repo}", file=sys.stderr)
        return 2
    try:
        overrides = parse_set(args.overrides)
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        return 2
    inputs = collect(repo, os.environ, overrides)
    digest = fingerprint(inputs)
    if args.hash_only:
        print(digest)
        return 0
    record = {
        "schema_version": SCHEMA_VERSION,
        "env_fingerprint": digest,
        "inputs": inputs,
    }
    json.dump(record, sys.stdout, sort_keys=True, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Verify that the inclusive retry limit permits its boundary attempt."""

from pathlib import Path
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: oracle.py WORKSPACE", file=sys.stderr)
        return 2

    workspace = Path(sys.argv[1]).resolve()
    script = r"""
const assert = require('node:assert/strict');
const { canAttempt } = require('./src/retry-policy');

assert.equal(canAttempt(4, 4), true);
assert.equal(canAttempt(1, 1), true);
"""
    result = subprocess.run(
        ["node", "-e", script],
        cwd=workspace,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr or result.stdout)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())

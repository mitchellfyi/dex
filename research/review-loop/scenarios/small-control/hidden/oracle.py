#!/usr/bin/env python3
"""Verify the candidate handles canonically equivalent Unicode labels."""

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
const { normalizeLabel } = require('./src/normalize-label');

const composed = normalizeLabel('  CAF\u00c9  ');
const decomposed = normalizeLabel('cafe\u0301');
assert.equal(composed, 'caf\u00e9');
assert.equal(decomposed, composed);
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

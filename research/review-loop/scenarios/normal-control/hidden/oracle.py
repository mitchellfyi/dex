#!/usr/bin/env python3
"""Verify the two-module refactor preserves the full public behavior."""

from pathlib import Path
import subprocess
import sys
import traceback


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: oracle.py WORKSPACE", file=sys.stderr)
        return 2

    workspace = Path(sys.argv[1]).resolve()
    script = r"""
const assert = require('node:assert/strict');
const { createAccountSource } = require('./src/account-source');
const { renderAccountCard } = require('./src/account-card');

const source = createAccountSource([{ id: 'acct-1', name: 'Zo\u00eb \ud83d\ude80' }]);
assert.equal(renderAccountCard(source, 'acct-1'), 'Account: Zo\u00eb \ud83d\ude80');
assert.equal(renderAccountCard(source, 'missing'), 'Account unavailable');
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
    try:
        status = main()
    except Exception:
        # Exit 1 is the harness's "the defect is still present". An oracle that
        # crashed has established nothing, and saying "still present" scores it
        # against the agent. 2 is "invalid", which stops the evaluation instead.
        traceback.print_exc()
        status = 2
    raise SystemExit(status)

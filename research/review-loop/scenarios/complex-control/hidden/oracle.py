#!/usr/bin/env python3
"""Verify the public parser extension handles boundaries without side effects."""

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
const { parseExportArgs } = require('./bin/parse-export-args');

const args = ['--format=csv', '--output=reports/daily=latest.csv'];
assert.deepEqual(parseExportArgs(args), {
  format: 'csv',
  output: 'reports/daily=latest.csv',
});
assert.deepEqual(args, ['--format=csv', '--output=reports/daily=latest.csv']);
assert.throws(() => parseExportArgs(['--format=']), /missing value/);
assert.throws(() => parseExportArgs(['--format', 'xml']), /unsupported format/);
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
